# pikafish_uci

Pikafish HCE packaged for Flutter over FFI. Xiangqi engine, GPL-3.

Staging note: this package currently lives inside the HocVienCoTuong repo while
it is built out. The plan is a standalone repo consumed by git ref, the way
`hvengine` already is; extracting it is a `git subtree split`, and nothing here
depends on the location.

## Status

| Stage | Scope | State |
| --- | --- | --- |
| A | submodule, patch, CMake, desktop parity | done |
| B | FFI bridge, Dart bindings, isolate transport | not started |
| C | Android build | not started |

The Dart package (`pubspec.yaml`, `lib/`) arrives in stage B. Stage A is a
native build only, so there is deliberately no Dart code yet.

## Layout

```
src/                      one native tree, every platform reads it
  CMakeLists.txt          engine core; mirrors upstream's SRCS list
  pikafish_arch.cmake     ABI -> -D flags; mirrors upstream's ARCH blocks
  pikafish_cli.cpp        desktop entry point (main() was renamed away)
third_party/Pikafish-HCE  git submodule, pinned
patches/                  applied to the submodule after checkout
tools/                    apply_patches.sh, bench_parity.sh
```

## Build and verify

```sh
git submodule update --init --recursive
tools/apply_patches.sh
tools/bench_parity.sh            # the gate
```

`bench_parity.sh` builds the engine twice -- once with upstream's own Makefile
from pristine sources, once through our CMake -- and compares them. It runs
three checks and each exists for a different reason:

1. **Define set, exact.** The real architecture gate.
2. **Node count, exact.** Behavioural gate: catches a wrong source list, an
   unapplied patch, a drifted submodule. It does **not** catch wrong
   architecture flags -- `ARCH=general-64` and `ARCH=x86-64-modern` both bench
   1146389 nodes. That measurement is why check 1 exists.
3. **NPS, advisory.** Too load-sensitive to gate on.

## Working with the patch

`apply_patches.sh` edits the submodule's working tree, so after running it
`git status` in the parent repo reports the submodule as having modified
content. That is expected: only the submodule *commit pointer* is tracked, the
patch is applied at build time, and re-applying is a no-op.

`bench_parity.sh` cleans up after itself — it restores the submodule unless you
had already patched it yourself — so running the gate leaves the tree clean.

To move to a newer upstream commit: check the submodule out at the new commit,
re-run `apply_patches.sh`, and re-run `bench_parity.sh` before committing the
new pointer.

## License

Pikafish HCE is GPL-3. `patches/` holds every modification made to it, and the
submodule pins the exact upstream commit, so the corresponding source for any
binary built here is fully determined by this directory.
