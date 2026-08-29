#!/usr/bin/env bash
# Gate C (native half): cross-builds every shipped ABI and verifies each one.
#
# Three checks per ABI:
#   1. DEFINE SET, exact, against upstream's own Makefile run with COMP=ndk.
#      This is the architecture gate -- stage A established that node counts
#      are invariant to these flags, so nothing else catches a wrong ABI.
#   2. 16 KB PAGE ALIGNMENT of the shipped .so. Google Play rejects unaligned
#      native libraries for apps targeting Android 15+. Verified on the
#      artifact, never assumed from the toolchain version.
#   3. EXPORTED SYMBOLS, exactly the five FFI functions and nothing else.
#   4. STRIPPED SIZE, recorded so APK growth is a number and not a guess.
#
# Requires ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) pointing at an NDK r27+.
#
# Not covered here: running the engine. That needs a device or emulator, and is
# the remaining half of gate C.
set -euo pipefail

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
[ -n "$NDK" ] || { echo "set ANDROID_NDK_HOME to an NDK r27+" >&2; exit 1; }
[ -d "$NDK" ] || { echo "no such NDK: $NDK" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB="$ROOT/third_party/Pikafish"
OUT="${OUT_DIR:-$(mktemp -d)}"
API="${ANDROID_API:-21}"
TOOLS="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -d "$TOOLS" ] || TOOLS="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"

cleanup() {
  [ -n "${OUT_DIR:-}" ] || rm -rf "$OUT"
}
trap cleanup EXIT

jobs="$( (nproc || sysctl -n hw.ncpu || echo 2) 2>/dev/null )"
# Upstream reference sources, unpatched, for the `make -n` define query.
mkdir -p "$OUT/ref"
git -C "$SUB" archive HEAD src | tar -x -C "$OUT/ref"

# ABI -> the upstream Makefile ARCH that corresponds to it.
# Upstream has no Android x86_64 target; the emulator ABI mirrors the desktop
# modern-x86 configuration, which is what pikafish_arch.cmake produces.
abi_arch() {
  case "$1" in
    arm64-v8a)   echo "armv8 ndk" ;;
    armeabi-v7a) echo "armv7-neon ndk" ;;
    x86_64)      echo "x86-64-sse41-popcnt host" ;;
  esac
}

status=0
# The ABI list comes from android/build.gradle rather than being repeated here.
# Keeping a second copy is how a Gradle build ends up compiling an ABI the gate
# never checked -- which is exactly how 32-bit x86 slipped through once.
ABIS="$(sed -n "s/.*abiFilters \(.*\)/\1/p" "$ROOT/android/build.gradle" \
  | tr -d \"\' | tr ',' ' ')"
[ -n "$ABIS" ] || { echo "could not read abiFilters from android/build.gradle" >&2; exit 1; }
echo "abis from android/build.gradle: $ABIS"
echo
printf '%-14s %-10s %-12s %-10s %s\n' ABI DEFINES ALIGNMENT EXPORTS "STRIPPED SIZE"

for abi in $ABIS; do
  read -r arch comp <<<"$(abi_arch "$abi")"
  [ -n "$arch" ] || { echo "$abi: no Makefile ARCH mapping in abi_arch()"; status=1; continue; }

  # `make -n` is redirected to a file rather than piped: `grep -m1` exits early,
  # make dies of SIGPIPE, and pipefail would turn that into a script failure.
  if [ "$comp" = ndk ]; then
    PATH="$TOOLS:$PATH" make -C "$OUT/ref/src" -n build ARCH="$arch" COMP=ndk \
      >"$OUT/$abi.ref" 2>/dev/null || true
  else
    make -C "$OUT/ref/src" -n build ARCH="$arch" >"$OUT/$abi.ref" 2>/dev/null || true
  fi
  ref="$(grep -m1 'evaluate\.cpp' "$OUT/$abi.ref" | tr ' ' '\n' \
    | { grep -E '^-D' || true; } | sort -u | tr '\n' ' ')"

  build="$OUT/$abi"
  cmake -S "$ROOT/src" -B "$build" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$API" \
    -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON >"$build.log" 2>&1 \
    && cmake --build "$build" -j"$jobs" >>"$build.log" 2>&1 \
    || { echo "$abi: BUILD FAILED"; tail -25 "$build.log"; status=1; continue; }

  python3 -c '
import json, sys
for e in json.load(open(sys.argv[1])):
    if e["file"].endswith("evaluate.cpp"):
        print(e.get("command") or " ".join(e["arguments"])); break
' "$build/compile_commands.json" > "$build.cmd"
  # The NDK's own cmake toolchain injects -DANDROID and -D_FORTIFY_SOURCE=2.
  # Neither configures Pikafish -- upstream's Makefile never sets them because
  # it does not go through that toolchain file -- so they are filtered by an
  # explicit allowlist. Deliberately an allowlist and not a subset test: a
  # subset test would happily accept a stray -DUSE_NEON=7 on arm64.
  got="$(tr " " "\n" < "$build.cmd" | { grep -E "^-D" || true; } \
    | grep -Ev "^-D(ANDROID|_FORTIFY_SOURCE(=.*)?)$" | sort -u | tr "\n" " ")"

  defines=PASS
  if [ -z "$ref" ] || [ "$got" != "$ref" ]; then
    defines=FAIL
    status=1
  fi

  so="$build/libpikafish_uci.so"
  align="$("$TOOLS/llvm-readelf" -l "$so" | awk '/LOAD/ {print $NF; exit}')"
  alignment=PASS
  [ "$align" = "0x4000" ] || { alignment="FAIL($align)"; status=1; }

  # The dynamic symbol table must contain exactly the FFI surface. A static
  # libc++ re-exported through this library is a classic Android symbol-collision
  # bug, and it is invisible until some other plugin misbehaves at runtime.
  # Defined globals only. Undefined entries in .dynsym are imports from libc,
  # not exports, and counting them was the first version's mistake.
  syms="$("$TOOLS/llvm-readelf" --dyn-syms "$so" \
    | awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" {print $8}' \
    | sort -u | tr '\n' ' ')"
  expected="pikafish_is_running pikafish_physical_memory_mb pikafish_read pikafish_start pikafish_write "
  exports=PASS
  [ "$syms" = "$expected" ] || { exports="FAIL"; status=1; }

  "$TOOLS/llvm-strip" -o "$so.stripped" "$so"
  size="$(du -h "$so.stripped" | cut -f1)"

  printf '%-14s %-10s %-12s %-10s %s\n' "$abi" "$defines" "$alignment" "$exports" "$size"
  if [ "$exports" = FAIL ]; then
    echo "    expected exports: $expected"
    echo "    actual exports  : ${syms:-<none>}"
  fi
  if [ "$defines" = FAIL ]; then
    echo "    expected: ${ref:-<none>}"
    echo "    actual  : ${got:-<none>}"
  fi
done

echo
[ "$status" -eq 0 ] && echo "GATE C (native) PASS" || echo "GATE C (native) FAIL"
exit "$status"
