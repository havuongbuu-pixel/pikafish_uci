#!/usr/bin/env bash
# Gate B: the FFI bridge and the Dart transport, both on the host.
#
# Two halves. The native smoke test drives the C entry points directly; the
# Dart gate drives PikafishTransport the way the stage-D session will and
# measures that the blocking native read stays off the calling isolate.
#
# Deliberately host-only: a pipe deadlock is debuggable here and miserable over
# adb. Stage C runs the same transport on a device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB="$ROOT/third_party/Pikafish-HCE"
BUILD="${BUILD_DIR:-$(mktemp -d)}"

PATCH_WAS_APPLIED=no
if git -C "$SUB" apply --reverse --check "$ROOT/patches/0001-rename-main.patch" 2>/dev/null; then
  PATCH_WAS_APPLIED=yes
fi
cleanup() {
  [ -n "${BUILD_DIR:-}" ] || rm -rf "$BUILD"
  if [ "$PATCH_WAS_APPLIED" = no ]; then
    git -C "$SUB" checkout -- src/main.cpp 2>/dev/null || true
  fi
}
trap cleanup EXIT

jobs="$( (nproc || sysctl -n hw.ncpu || echo 2) 2>/dev/null )"

echo "==> build"
"$ROOT/tools/apply_patches.sh" >/dev/null
cmake -S "$ROOT/src" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release >"$BUILD/cmake.log" 2>&1 \
  && cmake --build "$BUILD" -j"$jobs" >>"$BUILD/cmake.log" 2>&1 \
  || { echo "build failed:"; tail -30 "$BUILD/cmake.log"; exit 1; }

echo "==> native bridge"
"$BUILD/pikafish_bridge_smoke"

echo "==> dart transport"
if ! command -v dart >/dev/null 2>&1; then
  echo "  SKIPPED: no dart on PATH (the native half above still gates the bridge)"
  exit 0
fi
lib="$(ls "$BUILD"/libpikafish_uci.* 2>/dev/null | head -1)"
[ -n "$lib" ] || { echo "  FAIL: no shared library was built" >&2; exit 1; }

if ! ( cd "$ROOT/tools/dart_gate" && dart pub get >/dev/null 2>&1 ); then
  echo "  SKIPPED: dart pub get failed (needs network for package:ffi)"
  exit 0
fi
( cd "$ROOT/tools/dart_gate" && dart run bin/gate_b.dart "$lib" )
