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
| B | FFI bridge, Dart bindings, isolate transport | done |
| C | Android build | done, except running on a device |

This is a pure Dart package today, on purpose: nothing in `lib/` needs Flutter,
so the transport can be exercised by the plain Dart VM. Stage C turns it into a
Flutter FFI plugin.

## Layout

```
src/                      one native tree, every platform reads it
  CMakeLists.txt          engine core, FFI library, desktop CLI
  pikafish_arch.cmake     ABI -> -D flags; mirrors upstream's ARCH blocks
  pikafish_bridge.{h,cpp} pipes + dup2 + pthread; the FFI surface
  pikafish_cli.cpp        desktop entry point (main() was renamed away)
lib/
  src/bindings.dart       four hand-written C lookups
  src/uci_transport.dart  the interface everything above depends on
  src/ffi_uci_transport.dart  reader isolate + line assembly
third_party/Pikafish-HCE  git submodule, pinned
patches/                  applied to the submodule after checkout
tools/                    apply_patches.sh, bench_parity.sh, gate_b.sh
```

## Careful: starting the engine takes over stdout

`pikafish_start()` points fd 0 and fd 1 at the engine's pipes. fd 1 becomes the
*write* end of the engine-to-host pipe, so anything the host prints to stdout
afterwards comes back out of `pikafish_read` looking like engine output. Host
diagnostics must go to stderr, and consumers must ignore lines they do not
recognise. The engine also starts only once per process and cannot be
restarted.

## Build and verify

```sh
git submodule update --init --recursive
tools/apply_patches.sh
tools/bench_parity.sh            # gate A: build matches upstream
tools/gate_b.sh                  # gate B: bridge and transport work
```

`gate_b.sh` builds, runs the native bridge smoke test, then runs the Dart
transport gate. It skips the Dart half with a message when `dart` is not on
PATH; the native half still gates the bridge.

For Android:

```sh
ANDROID_NDK_HOME=/path/to/ndk tools/android_build.sh   # gate C, portable half
gradle :pikafish_uci:assembleRelease                   # gate C, packaging half
```

`android_build.sh` cross-builds every ABI named in `android/build.gradle` and
checks each one's define set against upstream's Makefile, its 16 KB page
alignment, and that it exports exactly the four bridge functions. It reads the
ABI list from `build.gradle` on purpose: a second hand-maintained list is how a
Gradle build ends up shipping an architecture the gate never saw. Run the Gradle
half too — it exercises the packaging path, which is where that bug showed up.

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
