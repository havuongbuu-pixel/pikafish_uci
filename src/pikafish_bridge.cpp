#include "pikafish_bridge.h"
#include "pikafish_dispatch.h"

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/sysctl.h>
#elif defined(__linux__) || defined(__ANDROID__)
#include <sys/sysinfo.h>
#endif

// Renamed from main() by patches/0001-rename-main.patch. C++ linkage, matching
// the declaration in the engine's own main.cpp.
int pikafish_main(int argc, char* argv[]);

namespace {

int g_to_engine_write = -1;    // host -> engine stdin
int g_from_engine_read = -1;   // engine stdout -> host
int g_saved_stdout = -1;       // kept for host-side debugging
bool g_started = false;  // owned by the calling thread

// Read by the caller, cleared by the engine thread. `volatile` would not
// order those accesses; an atomic does.
std::atomic<bool> g_running{false};

void close_fd(int& fd) {
  if (fd >= 0) {
    ::close(fd);
    fd = -1;
  }
}

bool write_all(int fd, const char* data, size_t len) {
  size_t sent = 0;
  while (sent < len) {
    const ssize_t n = ::write(fd, data + sent, len - sent);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    sent += static_cast<size_t>(n);
  }
  return true;
}

void* engine_thread(void*) {
  static char arg0[] = "pikafish";
  char* argv[] = {arg0, nullptr};

  // g_running is set by pikafish_start() before this thread is created, so a
  // caller never observes "not running" in the window before it is scheduled.
  pikafish_main(1, argv);
  g_running.store(false);

  // The engine returned, on `quit` or on EOF. Close the write end of its output
  // pipe so a consumer blocked in pikafish_read() sees EOF rather than hanging
  // forever. STDOUT_FILENO is the only remaining handle on it.
  ::close(STDOUT_FILENO);
  return nullptr;
}

}  // namespace

extern "C" {

int pikafish_start(void) {
#if defined(PIKAFISH_RUNTIME_DISPATCH)
  if (const auto* backend = pikafish_selected_backend()) return backend->start();
#endif
  if (g_started) return PIKAFISH_ERR_ALREADY;

  int to_engine[2] = {-1, -1};
  int from_engine[2] = {-1, -1};
  if (::pipe(to_engine) != 0) return PIKAFISH_ERR_PIPE;
  if (::pipe(from_engine) != 0) {
    close_fd(to_engine[0]);
    close_fd(to_engine[1]);
    return PIKAFISH_ERR_PIPE;
  }

  g_saved_stdout = ::dup(STDOUT_FILENO);
  if (::dup2(to_engine[0], STDIN_FILENO) < 0 ||
      ::dup2(from_engine[1], STDOUT_FILENO) < 0) {
    close_fd(to_engine[0]);
    close_fd(to_engine[1]);
    close_fd(from_engine[0]);
    close_fd(from_engine[1]);
    return PIKAFISH_ERR_PIPE;
  }

  // STDIN_FILENO and STDOUT_FILENO now hold these ends; the originals would
  // otherwise keep the pipes open and defeat EOF detection on both sides.
  close_fd(to_engine[0]);
  close_fd(from_engine[1]);

  g_to_engine_write = to_engine[1];
  g_from_engine_read = from_engine[0];

  // When stdout is a pipe rather than a terminal, libc switches to full
  // buffering and short UCI replies sit unsent until 4 KB accumulates, which
  // looks exactly like a hung engine. The engine never calls
  // sync_with_stdio(false), so std::cout writes through C stdout and this one
  // call covers both streams.
  ::setvbuf(stdout, nullptr, _IONBF, 0);

  pthread_t thread;
  g_running.store(true);
  if (::pthread_create(&thread, nullptr, engine_thread, nullptr) != 0) {
    g_running.store(false);
    close_fd(g_to_engine_write);
    close_fd(g_from_engine_read);
    return PIKAFISH_ERR_THREAD;
  }
  ::pthread_detach(thread);

  g_started = true;
  return PIKAFISH_OK;
}

int pikafish_is_running(void) {
#if defined(PIKAFISH_RUNTIME_DISPATCH)
  if (const auto* backend = pikafish_selected_backend()) return backend->is_running();
#endif
  return g_running.load() ? 1 : 0;
}

int64_t pikafish_physical_memory_mb(void) {
#if defined(PIKAFISH_RUNTIME_DISPATCH)
  if (const auto* backend = pikafish_selected_backend()) return backend->physical_memory_mb();
#endif
#if defined(__APPLE__)
  uint64_t bytes = 0;
  size_t size = sizeof(bytes);
  if (::sysctlbyname("hw.memsize", &bytes, &size, nullptr, 0) != 0) return 0;
  return static_cast<int64_t>(bytes / (1024ULL * 1024ULL));
#elif defined(__linux__) || defined(__ANDROID__)
  struct sysinfo info {};
  if (::sysinfo(&info) != 0) return 0;
  const uint64_t bytes =
      static_cast<uint64_t>(info.totalram) * info.mem_unit;
  return static_cast<int64_t>(bytes / (1024ULL * 1024ULL));
#else
  return 0;
#endif
}

int pikafish_write(const char* command) {
#if defined(PIKAFISH_RUNTIME_DISPATCH)
  if (const auto* backend = pikafish_selected_backend()) return backend->write(command);
#endif
  if (!g_started || g_to_engine_write < 0) return PIKAFISH_ERR_NOT_STARTED;
  if (command == nullptr) return PIKAFISH_ERR_INVALID;

  const size_t len = ::strlen(command);
  if (!write_all(g_to_engine_write, command, len)) return PIKAFISH_ERR_IO;
  if (len == 0 || command[len - 1] != '\n') {
    if (!write_all(g_to_engine_write, "\n", 1)) return PIKAFISH_ERR_IO;
  }
  return PIKAFISH_OK;
}

int pikafish_read(char* buffer, int capacity) {
#if defined(PIKAFISH_RUNTIME_DISPATCH)
  if (const auto* backend = pikafish_selected_backend()) return backend->read(buffer, capacity);
#endif
  if (!g_started || g_from_engine_read < 0) return PIKAFISH_ERR_NOT_STARTED;
  if (buffer == nullptr || capacity <= 0) return PIKAFISH_ERR_INVALID;

  ssize_t n;
  do {
    n = ::read(g_from_engine_read, buffer, static_cast<size_t>(capacity));
  } while (n < 0 && errno == EINTR);

  if (n < 0) return PIKAFISH_ERR_IO;
  return static_cast<int>(n);
}

}  // extern "C"
