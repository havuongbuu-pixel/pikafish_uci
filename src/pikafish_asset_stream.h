// Reading the NNUE network straight out of the Android APK.
//
// The selected release loads a ZIP-compressed NNUE. Its asset adapter supplies
// bounded reads and seeks for a streaming ZIP decoder. Neither a copy in app
// storage nor a complete decompressed serialization buffer is needed.
//
// Every function is a no-op returning failure off Android, where the host
// keeps handing over a real path because the asset already is a real file.

#ifndef PIKAFISH_ASSET_STREAM_H
#define PIKAFISH_ASSET_STREAM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PIKAFISH_ASSET_SCHEME "asset:"
#define PIKAFISH_ASSET_SCHEME_LEN 6

// Hands over the app's AssetManager, as an AAssetManager* the host obtained
// from AAssetManager_fromJava. Passing NULL forgets it again.
//
// Returns 1 when this build can read assets at all, 0 otherwise - so a caller
// on a platform without them can tell "declined" from "failed".
int pikafish_asset_manager_set(void* asset_manager);

// Whether a path names an asset rather than a file.
int pikafish_asset_is_asset_path(const char* path);

// Opens the asset named by a PIKAFISH_ASSET_SCHEME path. One at a time: the
// engine loads exactly one network, on one thread, before it searches.
// Returns 1 on success.
int pikafish_asset_open(const char* path);

// Reads up to `capacity` bytes. Returns the count, 0 at the end, or -1 on
// error. Mirrors what an ifstream read gives the caller it replaces.
int pikafish_asset_read(char* buffer, int capacity);
// Length and absolute seek; -1 on failure. Used by the ZIP reader callback.
int64_t pikafish_asset_size(void);
int64_t pikafish_asset_seek(int64_t offset);

void pikafish_asset_close(void);

// Whether the engine can read its network out of the package right now, i.e.
// this is Android and an AssetManager has been handed over. The host asks
// before deciding whether to point EvalFile at an asset or to fall back to
// copying the network to disk.
__attribute__((visibility("default"))) __attribute__((used)) int
pikafish_can_read_assets(void);

#ifdef __cplusplus
}
#endif
#endif  // PIKAFISH_ASSET_STREAM_H
