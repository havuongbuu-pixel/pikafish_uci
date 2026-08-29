#!/usr/bin/env bash
# Reproducible Apple-silicon comparison for the app's baseline ARMv8 NNUE build.
#
# Compares O2, O3, O3+full/ThinLTO and upstream's O3+full-LTO+PGO recipe on
# identical sources, network, hash, threads and bench depth. The explicit
# `arch=arm64` works around upstream's Linux-oriented `-arch armv8` spelling
# while retaining the same ARMv8/NEON defines shipped by the iOS/macOS pods.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE="$ROOT/third_party/Pikafish"
NETWORK="${PIKAFISH_NNUE:-$ROOT/../../assets/engine/pikafish.nnue}"
RUNS="${RUNS:-5}"
JOBS="${JOBS:-3}"

[ "$(uname -s)" = Darwin ] || {
  echo "this benchmark requires Apple's clang toolchain on macOS" >&2
  exit 1
}
[ -f "$NETWORK" ] || { echo "missing NNUE network: $NETWORK" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pikafish-apple-bench.XXXXXX")"
touch "$WORK/.pikafish-benchmark-owned"
cleanup() {
  if [ "${KEEP_BENCH:-0}" != 1 ] &&
     [ -f "$WORK/.pikafish-benchmark-owned" ]; then
    rm -rf "$WORK"
  else
    echo "artifacts: $WORK" >&2
  fi
}
trap cleanup EXIT

git -C "$SUBMODULE" archive HEAD | tar -x -C "$WORK"
cp "$NETWORK" "$WORK/src/pikafish.nnue"

variants="o2 o3 o3_full o3_thin pgo_full"
for variant in $variants; do
  cp -R "$WORK/src" "$WORK/$variant"
done

# Mechanical edits affect disposable archive copies only.
sed -i.bak 's/-O3 -funroll-loops/-O2 -funroll-loops/' "$WORK/o2/Makefile"
for variant in o2 o3; do
  sed -i.bak 's/CXXFLAGS += -flto=full/CXXFLAGS +=/' "$WORK/$variant/Makefile"
done
sed -i.bak 's/-flto=full/-flto=thin/g' "$WORK/o3_thin/Makefile"

for variant in o2 o3 o3_full o3_thin; do
  echo "building $variant" >&2
  make -C "$WORK/$variant" -j"$JOBS" build \
    ARCH=armv8 arch=arm64 COMP=clang >"$WORK/$variant.build.log" 2>&1
  cp "$WORK/$variant/pikafish" "$WORK/pikafish-$variant"
done

echo "building pgo_full" >&2
make -C "$WORK/pgo_full" -j"$JOBS" profile-build \
  ARCH=armv8 arch=arm64 COMP=clang >"$WORK/pgo_full.build.log" 2>&1
cp "$WORK/pgo_full/pikafish" "$WORK/pikafish-pgo_full"

: >"$WORK/results.txt"
for variant in $variants; do
  for run in $(seq 1 "$RUNS"); do
    printf 'setoption name EvalFile value %s\nbench 32 1 13 default depth\nquit\n' \
      "$WORK/src/pikafish.nnue" |
      "$WORK/pikafish-$variant" 2>&1 |
      awk -v variant="$variant" -v run="$run" '
        /Nodes\/second/ {
          line=$0
          sub(/^.*Nodes\/second[[:space:]]*:[[:space:]]*/, "", line)
          gsub(/[^0-9]/, "", line)
          print variant, run, line
        }
      ' | tee -a "$WORK/results.txt"
  done
done

printf '\n%-12s %12s\n' variant median_nps
for variant in $variants; do
  median="$({ awk -v variant="$variant" '$1 == variant {print $3}' \
    "$WORK/results.txt" | sort -n; } | awk '
      { values[NR]=$1 }
      END { print values[int((NR + 1) / 2)] }
    ')"
  printf '%-12s %12s\n' "$variant" "$median"
done
