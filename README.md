# pikafish_uci

Official Pikafish with NNUE packaged for Flutter over FFI. Xiangqi engine,
GPL-3.

Staging note: this package currently lives inside the HocVienCoTuong repo while
it is built out. The plan is a standalone repo consumed by git ref; extracting
it is a `git subtree split`, and nothing here depends on the location.

## Status

| Stage | Scope | State |
| --- | --- | --- |
| A | submodule, patch, CMake, desktop parity | done |
| B | FFI bridge, Dart bindings, isolate transport | done |
| C | Android build | pending device verification for the NNUE source update |
| D | iOS/macOS CocoaPods build and in-app NNUE smoke | done on macOS |

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
third_party/Pikafish      official git submodule, pinned
patches/                  build-time generated modifications
tools/                    apply_patches.sh, bench_parity.sh, gate_b.sh
```

## Careful: starting the engine takes over stdout

`pikafish_start()` points fd 0 and fd 1 at the engine's pipes. fd 1 becomes the
*write* end of the engine-to-host pipe, so anything the host prints to stdout
afterwards comes back out of `pikafish_read` looking like engine output. Host
diagnostics must go to stderr, and consumers must ignore lines they do not
recognise. The engine also starts only once per process and cannot be
restarted.

Official Pikafish requires an external `pikafish.nnue`. The Flutter app
verifies the bundled network hash, materialises it into Application Support,
then sends its absolute path through the UCI `EvalFile` option before the first
search. The reviewed embedded-host patch turns a missing network into
`PIKAFISH_NNUE_LOAD_FAILED` instead of letting upstream call `exit()` inside the
app process.

## Build and verify

```sh
git submodule update --init --recursive
tools/apply_patches.sh           # validates generated patches; never edits the submodule
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
   architecture flags. That measurement is why check 1 exists.
3. **NPS, advisory.** Too load-sensitive to gate on.

## Working with the patch

The official submodule always remains pristine. CMake writes patched copies to
its build directory; CocoaPods writes ignored forwarders and patched copies to
`ios/generated` or `macos/generated`. `apply_patches.sh` is retained as a
compatibility command that validates those generators.

To move to a newer upstream commit: check the submodule out at the new commit,
update the network manifest when required, then run `apply_patches.sh`,
`bench_parity.sh`, and the Flutter integration smoke before committing.

## Difficulty calibration

The app measures packaged-engine throughput once on first acquisition and sends
both node and wall-clock limits, so fast devices keep a stable strength ceiling
while throttled devices remain responsive. The deterministic calibration tool
mirrors the app's Easy, Normal, Hard, and Master budgets and MultiPV selector:

```sh
tools/calibrate_strength.py /path/to/pikafish_nnue /path/to/pikafish.nnue \
  --positions 96 --reference-movetime 3000
```

Use `--device-nps N` to exercise the exact adaptive budgets used at a slower
measured throughput. The result is centipawn-loss evidence against a stronger
reference search, not a human Elo estimate.

## License

Pikafish is GPL-3. `patches/` holds every modification made to it, the submodule
pins the exact upstream commit, and `assets/engine/pikafish_nnue_manifest.json`
pins the network bytes used by the app.
