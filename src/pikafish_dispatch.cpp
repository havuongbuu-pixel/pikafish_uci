#include "pikafish_dispatch.h"

#if defined(PIKAFISH_RUNTIME_DISPATCH)
#if !defined(__ANDROID__) || !defined(__aarch64__)
#error Runtime dot-product dispatch is only supported on Android ARM64.
#endif

#include <asm/hwcap.h>
#include <dlfcn.h>
#include <sys/auxv.h>
#include <mutex>

namespace {
std::once_flag selection;
PikafishBackend backend{};
bool selected = false;

template <typename Function>
bool resolve(void* library, const char* name, Function& target) {
  target = reinterpret_cast<Function>(dlsym(library, name));
  return target != nullptr;
}

void select_backend() {
  // arm64-v8a alone does not imply dot-product. Do not even load the DSO on
  // unsupported CPUs: its initializers may contain specialized instructions.
  if ((getauxval(AT_HWCAP) & HWCAP_ASIMDDP) == 0) return;
  void* library = dlopen("libpikafish_uci_dotprod.so", RTLD_NOW | RTLD_LOCAL);
  if (!library) return;
  const bool complete =
      resolve(library, "pikafish_start", backend.start) &&
      resolve(library, "pikafish_is_running", backend.is_running) &&
      resolve(library, "pikafish_physical_memory_mb", backend.physical_memory_mb) &&
      resolve(library, "pikafish_write", backend.write) &&
      resolve(library, "pikafish_read", backend.read) &&
      resolve(library, "pikafish_can_read_assets", backend.can_read_assets) &&
      resolve(library,
              "Java_com_hocviencotuong_pikafish_1uci_PikafishAssets_register",
              backend.register_assets);
  if (!complete) {
    backend = {};
    dlclose(library);
    return;
  }
  // Keep the handle for the process lifetime. Function pointers and the
  // running engine thread must remain valid after the caller returns.
  selected = true;
}
}  // namespace

const PikafishBackend* pikafish_selected_backend() {
  std::call_once(selection, select_backend);
  return selected ? &backend : nullptr;
}
#endif
