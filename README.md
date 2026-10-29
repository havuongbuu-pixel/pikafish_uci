# pikafish_uci

Official Pikafish 2024-08-31 with its matching release NNUE, packaged for
Flutter over FFI. Engine code: GPL-3. Network: the separate NNUE licence in
that release (commercial use requires permission).

Staging note: this package currently lives inside the HocVienCoTuong repo while
it is built out. The plan is a standalone repo consumed by git ref; extracting
it is a `git subtree split`, and nothing here depends on the location.

## Pinned engine / network pair

- Engine commit: `e0c6f068dfef32c64add074eec604eab65613198`.
- Official release archive: https://github.com/official-pikafish/Pikafish/releases/download/Pikafish-2024-08-31/Pikafish.2024-08-31.7z
- Archive SHA-256: `57f2ae2242fce6d4e789942011e086001ebb44f3ac8e308d9abebf12ba01bda5`.
- Network entry: `pikafish.nnue`, 22758893 bytes.
- Network SHA-256: `bdcdb210349fbca6c8b15435a1e25c19fc2754ac4cc338f18ffd68fffce1b985`.
- Network terms: `NNUE-README.md` in that archive. Legal use only;
  commercial use requires permission. The GPL covers the engine code.

## Licence, and why this directory is published

Pikafish is GPL-3, and this package links it: `src/pikafish_bridge.cpp` is
compiled together with the engine's own objects and calls its `main()`. The
bridge, the CMake configuration and the patches are therefore part of the
engine's work, and this package is offered under the GPL-3 in `LICENSE`.

Distributing an application that carries this engine obliges the distributor to
offer the *corresponding source*: the pinned upstream commit **plus** the
modifications made to it. Upstream is already public; the modifications are
here. That is the whole reason this directory is published on its own -
a recipient of the app can obtain the engine's source without the application
around it being open.

    third_party/Pikafish   upstream, pinned by submodule
    patches/               every modification made to it
    src/                   build configuration and the FFI bridge

`third_party/Pikafish-HCE` is a different thing and is **not** part of what any
application ships. It is a hand-crafted-evaluation variant built by
`scripts/puzzle_verify/build_pikafish_hce.sh` to check puzzles offline, where no
NNUE file is wanted. Keep the distinction: the app's licence notice names the
official engine and its commit, and would be wrong if HCE ever shipped.

When the engine or the network is upgraded, the pinned commit, the network
SHA-256, the notice in `assets/legal/pikafish_notice.txt` and
`EngineComplianceInfo` all move together, and this repository has to be
republished to match. A release whose corresponding source is not public, or
does not match the binary, does not satisfy the licence.

### Publishing it

Published at https://github.com/havuongbuu-pixel/pikafish_uci, as a generated
mirror of this directory:

    git push --force https://github.com/havuongbuu-pixel/pikafish_uci.git "$(git subtree split --prefix=packages/pikafish_uci)":main

`--force` is not carelessness here. Every split re-derives its commits from
this directory's history, so a fresh one shares no commit ids with what is
already published even when the content is identical. The mirror is generated,
never committed to directly, and force is how a generated thing is replaced.
Naming a branch instead - `subtree split -b <name>` - fails the second time it
is run, because the branch it made is not an ancestor of the new split.

The split carries `.gitmodules` from this directory, which is why that file
sits here: it is inert while this package lives inside the application repo,
and becomes the real one when the split makes this directory a root. Without
it the pointers under `third_party` name a commit with no URL to fetch it from.

Re-publish after every engine or patch change. A shipped binary whose
corresponding source is not on that mirror, or does not match it, is a
release the licence does not permit.

## Status

| Stage | Scope | State |
| --- | --- | --- |
| A | submodule, patch, CMake, desktop parity | done |
| B | FFI bridge, Dart bindings, isolate transport | done |
| C | Android build | done; network read from the package, verified on device |
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
  src/bindings.dart       FFI and asset-capability lookups
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

Official Pikafish requires an external `pikafish.nnue`. The app pins the
network bytes, hash, archive entry and source URL in its NNUE manifest. Android
reads it from the signed APK when AssetManager is available; other launches
materialise a hash-verified copy. Missing or incompatible networks produce
`PIKAFISH_NNUE_LOAD_FAILED` and skip search/eval/perft without exiting the app.

## Build dependencies and source preparation

Both build paths require Git. CMake's `prepare_pikafish_sources.cmake` and
CocoaPods' `generate_pikafish_sources.rb` copy the pinned source into an ignored
build directory, normalize checkout line endings, and apply the same three
canonical patches. The complete header/implementation tree is patched together;
the upstream submodule remains untouched. A patch mismatch fails the build.

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
alignment, and that it exports the explicit FFI and asset-registration allowlist. It reads the
ABI list from `build.gradle` on purpose: a second hand-maintained list is how a
Gradle build ends up shipping an architecture the gate never saw. Run the Gradle
half too â€” it exercises the packaging path, which is where that bug showed up.

`bench_parity.sh` builds the engine twice -- once with upstream's own Makefile
from pristine sources, once through our CMake -- and compares them. It runs
three checks and each exists for a different reason:

1. **Define set, exact.** The real architecture gate.
2. **Node count, exact.** Behavioural gate: catches a wrong source list, an
   unapplied patch, a drifted submodule. It does **not** catch wrong
   architecture flags. That measurement is why check 1 exists.
3. **NPS, advisory.** Too load-sensitive to gate on.

## Working with the patches

The source snapshot applies:
- `0001-rename-main.patch`: in-process entry point.
- `0002-embedded-nnue-failure.patch`: boolean verification and guarded callers.
- `0003-android-asset-network.patch`: a bounded, asset-aware ZIP network reader.

To change upstream, update its pointer, the reviewed patches, CMake/CocoaPods
source lists, the network manifest, runtime identity and legal notices together.
Run `apply_patches.sh`, `bench_parity.sh` and device smoke checks before shipping.

## Giving the engine its network on Android

This release stores NNUE parameters in a one-entry ZIP. The asset patch reads
the compressed bytes through `pikafish_asset_stream.cpp`, opens a memory-backed
ZIP and decodes into the parameter stream. Both archive and entry are bounded
to 256 MiB, invalid ZIP/CRC data fails loading, and there is no materialised copy
in app storage. The decoder still allocates compressed/expanded buffers; this
is not a zero-copy or constant-memory claim. Ordinary filesystem paths retain
the upstream raw-network fallback.

The host has to hand over an `AssetManager`, because only a `Context` has one:

```kotlin
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PikafishAssets.install(assets)
    }
}
```

Then ask `PikafishTransport.canReadAssets()` before choosing what to set
`EvalFile` to. Skip the call and it answers false, and the host must materialise
a real file instead â€” which still works, and is what every other platform does,
their assets already being files.

Two failures here compile cleanly and only show on a device. The JNI entry point
must be built into the shared library rather than the engine archive, because
`--exclude-libs,ALL` hides everything an archive brings; and the generated
`misc.cpp` must be checked to carry the patch, because an unpatched one builds,
then reads an empty network and answers every position with `(none)`.

## Difficulty calibration

On a device without a valid profile, the app measures packaged-engine
throughput automatically after the first rendered frame and stores the selected
Threads, Hash and baseline NPS locally. Later launches reuse that profile; it is
invalidated by device/runtime, native build, engine, calibration algorithm or
NNUE changes. Interactive searches preempt an unfinished benchmark and use safe
limits, so calibration never blocks a requested move. Every search sends both
node and wall-clock limits, keeping a stable strength ceiling on fast devices
and responsiveness on throttled devices. The deterministic calibration tool
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
