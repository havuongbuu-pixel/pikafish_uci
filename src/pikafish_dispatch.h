#ifndef PIKAFISH_DISPATCH_H
#define PIKAFISH_DISPATCH_H

#if defined(PIKAFISH_RUNTIME_DISPATCH)
#include <stdint.h>
#include <jni.h>

// Only C entry points cross the DSO boundary. NNUE layouts and C++ globals
// belong entirely to the selected engine and are never shared between builds.
struct PikafishBackend {
  int (*start)();
  int (*is_running)();
  int64_t (*physical_memory_mb)();
  int (*write)(const char*);
  int (*read)(char*, int);
  int (*can_read_assets)();
  jboolean (*register_assets)(JNIEnv*, jclass, jobject);
};

// A stable process-wide choice. nullptr means use the local NEON engine.
const PikafishBackend* pikafish_selected_backend();
#endif

#endif
