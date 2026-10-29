#!/usr/bin/env bash
# Backwards-compatible validation entry point.
#
# The official Pikafish submodule stays pristine. CMake and CocoaPods generate
# patched translation units in their own build directories, so this command now
# validates those generators instead of editing third_party in place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB="$ROOT/third_party/Pikafish"

if [ ! -f "$SUB/src/main.cpp" ]; then
  echo "error: official Pikafish submodule not checked out. Run:" >&2
  echo "  git submodule update --init --recursive" >&2
  exit 1
fi

ruby -c "$ROOT/src/generate_pikafish_sources.rb" >/dev/null
ruby -e \
  'require ARGV[0]; PikafishSources.generate!(File.expand_path(ARGV[1]))' \
  "$ROOT/src/generate_pikafish_sources.rb" \
  "$ROOT/macos"

grep -q 'int pikafish_main(' "$ROOT/macos/generated/upstream/src/main.cpp"
grep -q 'PIKAFISH_NNUE_LOAD_FAILED' "$ROOT/macos/generated/upstream/src/nnue/network.cpp"

echo "generated Pikafish patches validated; submodule left pristine"
