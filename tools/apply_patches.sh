#!/usr/bin/env bash
# Applies packages/pikafish_uci/patches/*.patch to the Pikafish-HCE submodule.
# Idempotent: safe to re-run, and a no-op when the patch is already applied.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB="$ROOT/third_party/Pikafish-HCE"

if [ ! -f "$SUB/src/main.cpp" ]; then
  echo "error: submodule not checked out. Run:" >&2
  echo "  git submodule update --init --recursive" >&2
  exit 1
fi

for patch in "$ROOT"/patches/*.patch; do
  [ -e "$patch" ] || continue
  name="$(basename "$patch")"
  if git -C "$SUB" apply --reverse --check "$patch" 2>/dev/null; then
    echo "already applied: $name"
  elif git -C "$SUB" apply --check "$patch" 2>/dev/null; then
    git -C "$SUB" apply "$patch"
    echo "applied:         $name"
  else
    echo "error: $name applies neither forward nor in reverse." >&2
    echo "The submodule may be at an unexpected commit. Check:" >&2
    echo "  git -C $SUB rev-parse HEAD" >&2
    exit 1
  fi
done
