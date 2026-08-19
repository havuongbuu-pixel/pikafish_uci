#!/usr/bin/env bash
# Gate A / Gate C: proves the CMake build compiles the same engine, with the
# same architecture flags, as upstream's own Makefile.
#
# Three checks, because no single one is sufficient:
#
#   1. DEFINE SET (exact).  The real architecture gate. Compares the -D flags
#      the two builds actually pass to the compiler.
#   2. NODE COUNT (exact).  Behavioural gate: catches a wrong source list, an
#      unapplied patch, a drifted submodule, a modified evaluation.
#      Measured fact: node count is INVARIANT to the architecture defines --
#      ARCH=general-64 and ARCH=x86-64-modern both bench 1146389 -- so this
#      check alone would NOT catch a misconfigured arch. Hence check 1.
#   3. NPS (advisory).  Throughput is what the arch flags actually buy. Same
#      measurement showed ~957k vs ~889k nps for the two ARCHs above. Reported,
#      not enforced: it is load-sensitive and not reproducible enough to gate.
#
# Usage: tools/bench_parity.sh [MAKEFILE_ARCH]     (default: x86-64-modern)
set -euo pipefail

ARCH="${1:-x86-64-modern}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB="$ROOT/third_party/Pikafish-HCE"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

jobs="$( (nproc || sysctl -n hw.ncpu || echo 2) 2>/dev/null )"

# Sorted, de-duplicated -D flags from a recorded compile command for
# evaluate.cpp. Never parses build-tool output: the reference comes from
# `make -n`, the CMake side from compile_commands.json, so both are stable
# across generators and make versions.
defines_from() { tr ' ' '\n' < "$1" | { grep -E '^-D' || true; } | sort -u | tr '\n' ' '; }

echo "==> reference build (Makefile, ARCH=$ARCH)"
mkdir -p "$WORK/ref"
git -C "$SUB" archive HEAD src | tar -x -C "$WORK/ref"
make -C "$WORK/ref/src" -n build ARCH="$ARCH" 2>/dev/null \
  | grep -m1 'evaluate\.cpp' > "$WORK/ref.cmd" || true
make -C "$WORK/ref/src" -j"$jobs" build ARCH="$ARCH" >"$WORK/ref.log" 2>&1 \
  || { echo "reference build failed:"; tail -30 "$WORK/ref.log"; exit 1; }

echo "==> cmake build"
"$ROOT/tools/apply_patches.sh" >/dev/null
cmake -S "$ROOT/src" -B "$WORK/cmake" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON >"$WORK/cm.log" 2>&1 \
  && cmake --build "$WORK/cmake" -j"$jobs" >>"$WORK/cm.log" 2>&1 \
  || { echo "cmake build failed:"; tail -30 "$WORK/cm.log"; exit 1; }
python3 -c '
import json, sys
db = json.load(open(sys.argv[1]))
for e in db:
    if e["file"].endswith("evaluate.cpp"):
        print(e.get("command") or " ".join(e["arguments"])); break
' "$WORK/cmake/compile_commands.json" > "$WORK/cmake.cmd"

ref_defs="$(defines_from "$WORK/ref.cmd")"
cmake_defs="$(defines_from "$WORK/cmake.cmd")"

bench() { "$1" bench 2>&1 | tail -20; }
bench "$WORK/ref/src/pikafish"       > "$WORK/ref.bench"
bench "$WORK/cmake/pikafish_cli"     > "$WORK/cmake.bench"
field() { sed -n "s/^$2 *: *//p" "$1" | tail -1; }

ref_nodes="$(field "$WORK/ref.bench"   'Nodes searched')"
cmk_nodes="$(field "$WORK/cmake.bench" 'Nodes searched')"
ref_nps="$(field "$WORK/ref.bench"     'Nodes\/second')"
cmk_nps="$(field "$WORK/cmake.bench"   'Nodes\/second')"

status=0
echo
echo "1. defines"
echo "   makefile : ${ref_defs:-<none>}"
echo "   cmake    : ${cmake_defs:-<none>}"
if [ -z "$ref_defs" ] || [ "$ref_defs" != "$cmake_defs" ]; then
  echo "   FAIL: define sets differ -- fix src/pikafish_arch.cmake" >&2
  status=1
else
  echo "   PASS"
fi

echo "2. node count"
echo "   makefile : ${ref_nodes:-<none>}   cmake: ${cmk_nodes:-<none>}"
if [ -z "$ref_nodes" ] || [ "$ref_nodes" != "$cmk_nodes" ]; then
  echo "   FAIL: node counts differ -- not the same engine" >&2
  status=1
else
  echo "   PASS"
fi

echo "3. nps (advisory)"
echo "   makefile : ${ref_nps:-?}   cmake: ${cmk_nps:-?}"
if [ -n "$ref_nps" ] && [ -n "$cmk_nps" ] && [ "$ref_nps" -gt 0 ]; then
  pct=$(( cmk_nps * 100 / ref_nps ))
  echo "   cmake is ${pct}% of reference throughput"
  [ "$pct" -lt 85 ] && echo "   WARNING: >15% slower; check arch flags." || true
fi

echo
[ "$status" -eq 0 ] && echo "GATE PASS" || echo "GATE FAIL"
exit "$status"
