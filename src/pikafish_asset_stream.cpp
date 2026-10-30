#include "pikafish_asset_stream.h"
#include "pikafish_dispatch.h"

#include <string.h>
#include <stdio.h>

#if defined(__ANDROID__)
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <jni.h>
#endif

namespace {

#if defined(__ANDROID__)
AAssetManager* g_manager = nullptr;
AAsset* g_asset = nullptr;
#endif

}  // namespace

extern "C" {

int pikafish_asset_manager_set(void* asset_manager) {
#if defined(__ANDROID__)
  g_manager = static_cast<AAssetManager*>(asset_manager);
  return 1;
#else
  (void)asset_manager;
  return 0;
#endif
}

int pikafish_asset_is_asset_path(const char* path) {
  if (path == nullptr) return 0;
  return strncmp(path, PIKAFISH_ASSET_SCHEME, PIKAFISH_ASSET_SCHEME_LEN) == 0;
}

int pikafish_asset_open(const char* path) {
#if defined(__ANDROID__)
  if (g_manager == nullptr || !pikafish_asset_is_asset_path(path)) return 0;
  pikafish_asset_close();
  // AASSET_MODE_STREAMING, not BUFFER: buffering would materialise the whole
  // network in memory, which is the cost this exists to avoid.
  g_asset = AAssetManager_open(g_manager, path + PIKAFISH_ASSET_SCHEME_LEN,
                               AASSET_MODE_STREAMING);
  return g_asset != nullptr ? 1 : 0;
#else
  (void)path;
  return 0;
#endif
}

int pikafish_asset_read(char* buffer, int capacity) {
#if defined(__ANDROID__)
  if (g_asset == nullptr || buffer == nullptr || capacity <= 0) return -1;
  return AAsset_read(g_asset, buffer, static_cast<size_t>(capacity));
#else
  (void)buffer;
  (void)capacity;
  return -1;
#endif
}

int64_t pikafish_asset_size(void) {
#if defined(__ANDROID__)
  return g_asset ? AAsset_getLength64(g_asset) : -1;
#else
  return -1;
#endif
}

int64_t pikafish_asset_seek(int64_t offset) {
#if defined(__ANDROID__)
  return g_asset && offset >= 0 ? AAsset_seek64(g_asset, offset, SEEK_SET) : -1;
#else
  (void)offset;
  return -1;
#endif
}

int pikafish_can_read_assets(void) {
#if defined(PIKAFISH_RUNTIME_DISPATCH)
  if (const auto* backend = pikafish_selected_backend()) return backend->can_read_assets();
#endif
#if defined(__ANDROID__)
  return g_manager != nullptr ? 1 : 0;
#else
  return 0;
#endif
}

void pikafish_asset_close(void) {
#if defined(__ANDROID__)
  if (g_asset != nullptr) {
    AAsset_close(g_asset);
    g_asset = nullptr;
  }
#endif
}

#if defined(__ANDROID__)
// Called once from the host's Activity, which is the only party holding a
// Context. The name is the JNI spelling of
// com.hocviencotuong.pikafish_uci.PikafishAssets.register - the `_1` stands
// for the underscore in `pikafish_uci`. Rename either side and the other stops
// binding, silently, so they are kept together in this package.
JNIEXPORT jboolean JNICALL
Java_com_hocviencotuong_pikafish_1uci_PikafishAssets_register(
    JNIEnv* env, jclass clazz, jobject asset_manager) {
#if defined(PIKAFISH_RUNTIME_DISPATCH)
  if (const auto* backend = pikafish_selected_backend())
    return backend->register_assets(env, clazz, asset_manager);
#else
  (void)clazz;
#endif
  if (asset_manager == nullptr) {
    pikafish_asset_manager_set(nullptr);
    return JNI_FALSE;
  }
  AAssetManager* manager = AAssetManager_fromJava(env, asset_manager);
  if (manager == nullptr) return JNI_FALSE;
  // The AAssetManager stays valid while the AssetManager object it came from
  // is alive. The caller is the Activity, whose assets outlive the engine.
  pikafish_asset_manager_set(manager);
  return JNI_TRUE;
}
#endif

}  // extern "C"
