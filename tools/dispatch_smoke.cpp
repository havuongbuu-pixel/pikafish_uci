// Link the production selector against deterministic loader/HWCAP test doubles.
// Each case runs in a fresh process because selection is intentionally final.
// Compile both sources with -Dgetauxval=pikafish_test_getauxval and equivalent
// dlopen/dlsym/dlclose substitutions, so libc++ startup uses the real system API.
#include "pikafish_dispatch.h"
#include <asm/hwcap.h>
#include <sys/auxv.h>
#include <cassert>
#include <atomic>
#include <cstring>
#include <thread>
#include <vector>

namespace {
const char* scenario = "unsupported";
std::atomic<int> opens{0}, resolves{0}, closes{0};
int status() { return 42; }
int64_t memory() { return 3773; }
int write_command(const char*) { return 0; }
int read_output(char*, int) { return 0; }
jboolean register_assets(JNIEnv*, jclass, jobject) { return JNI_TRUE; }
}
extern "C" unsigned long getauxval(unsigned long type) {
  // libc++ may query auxiliary entries before main as well as the selector.
  if (type != AT_HWCAP) return 0;
  return HWCAP_ASIMD | (std::strcmp(scenario, "unsupported") == 0 ? 0 : HWCAP_ASIMDDP);
}
extern "C" void* dlopen(const char* path, int) {
  opens++;
  assert(std::strcmp(path, "libpikafish_uci_dotprod.so") == 0);
  return std::strcmp(scenario, "missing") == 0 ? nullptr : reinterpret_cast<void*>(1);
}
extern "C" int dlclose(void*) { closes++; return 0; }
extern "C" void* dlsym(void*, const char* name) {
  resolves++;
  if (std::strcmp(scenario, "incomplete") == 0 && std::strcmp(name, "pikafish_read") == 0)
    return nullptr;
  if (std::strcmp(name, "pikafish_physical_memory_mb") == 0)
    return reinterpret_cast<void*>(&memory);
  if (std::strcmp(name, "pikafish_write") == 0) return reinterpret_cast<void*>(&write_command);
  if (std::strcmp(name, "pikafish_read") == 0) return reinterpret_cast<void*>(&read_output);
  if (std::strstr(name, "Assets_register")) return reinterpret_cast<void*>(&register_assets);
  return reinterpret_cast<void*>(&status);
}
int main(int argc, char** argv) {
  assert(argc == 2);
  scenario = argv[1];
  const bool success = std::strcmp(scenario, "complete") == 0;
  std::vector<std::thread> callers;
  for (int i = 0; i < 16; ++i) callers.emplace_back([=] {
    for (int n = 0; n < 100; ++n) {
      const auto* backend = pikafish_selected_backend();
      assert((backend != nullptr) == success);
      if (backend) {
        assert(backend->start() == 42);
        assert(backend->physical_memory_mb() == 3773);
        assert(backend->register_assets(nullptr, nullptr, nullptr) == JNI_TRUE);
      }
    }
  });
  for (auto& caller : callers) caller.join();
  assert(opens == (std::strcmp(scenario, "unsupported") == 0 ? 0 : 1));
  assert(closes == (std::strcmp(scenario, "incomplete") == 0 ? 1 : 0));
  if (success) assert(resolves == 7);
  return 0;
}
