// Gate B (native half): drives the FFI bridge exactly the way the Dart isolate
// will, and fails loudly instead of hanging.
//
// A reader thread accumulates output while the main thread waits with
// timeouts, mirroring the Dart design where one isolate owns the blocking
// read. Diagnostics go to stderr because pikafish_start() redirects stdout
// into the engine's input pipe.

#include "../src/pikafish_bridge.h"

#include <pthread.h>
#include <unistd.h>
#include <ctime>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
std::vector<std::string> g_lines;
std::string g_partial;
bool g_eof = false;
int g_failures = 0;

void* reader(void*) {
  char buf[4096];
  for (;;) {
    const int n = pikafish_read(buf, static_cast<int>(sizeof(buf)));
    pthread_mutex_lock(&g_mutex);
    if (n <= 0) {
      g_eof = true;
      pthread_cond_broadcast(&g_cond);
      pthread_mutex_unlock(&g_mutex);
      return nullptr;
    }
    g_partial.append(buf, static_cast<size_t>(n));
    size_t nl;
    while ((nl = g_partial.find('\n')) != std::string::npos) {
      std::string line = g_partial.substr(0, nl);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      g_lines.push_back(line);
      g_partial.erase(0, nl + 1);
    }
    pthread_cond_broadcast(&g_cond);
    pthread_mutex_unlock(&g_mutex);
  }
}

// Waits for a line starting with `prefix`. Returns it, or "" on timeout/EOF.
std::string await_line(const char* prefix, int timeout_ms) {
  timespec deadline{};
  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += timeout_ms / 1000;
  deadline.tv_nsec += static_cast<long>(timeout_ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec += 1;
    deadline.tv_nsec -= 1000000000L;
  }

  const size_t plen = ::strlen(prefix);
  pthread_mutex_lock(&g_mutex);
  size_t next = 0;
  for (;;) {
    while (next < g_lines.size()) {
      const std::string line = g_lines[next++];
      if (line.compare(0, plen, prefix) == 0) {
        pthread_mutex_unlock(&g_mutex);
        return line;
      }
    }
    if (g_eof || pthread_cond_timedwait(&g_cond, &g_mutex, &deadline) != 0) {
      pthread_mutex_unlock(&g_mutex);
      return std::string();
    }
  }
}

void check(const char* what, bool ok, const std::string& detail = "") {
  fprintf(stderr, "  %-46s %s%s%s\n", what, ok ? "PASS" : "FAIL",
          detail.empty() ? "" : "  ", detail.c_str());
  if (!ok) ++g_failures;
}

}  // namespace

int main() {
  fprintf(stderr, "bridge smoke test\n");

  if (pikafish_start() != PIKAFISH_OK) {
    fprintf(stderr, "  pikafish_start failed\n");
    return 1;
  }
  pthread_t tid;
  pthread_create(&tid, nullptr, reader, nullptr);

  check("start reports running", pikafish_is_running() == 1);
  check("second start is rejected", pikafish_start() == PIKAFISH_ERR_ALREADY);

  pikafish_write("uci");
  const std::string id = await_line("id name", 5000);
  check("uci -> id name", !id.empty(), id);
  check("uci -> uciok", !await_line("uciok", 5000).empty());

  pikafish_write("isready");
  check("isready -> readyok", !await_line("readyok", 5000).empty());

  // Unbuffered output check: a short reply must arrive well under the 4 KB
  // that full buffering would otherwise wait for.
  pikafish_write("position startpos");
  pikafish_write("go depth 8");
  const std::string bm = await_line("bestmove", 20000);
  check("go depth 8 -> bestmove", !bm.empty(), bm);
  check("bestmove is a uci move",
        bm.size() >= 13 && bm[9] >= 'a' && bm[9] <= 'i' && bm[10] >= '0' &&
            bm[10] <= '9' && bm[11] >= 'a' && bm[11] <= 'i');

  // Cancellation: a deep search must answer promptly once stopped. This is the
  // path the Dart session depends on, since the in-process model has no kill.
  pikafish_write("go depth 60");
  usleep(300 * 1000);
  pikafish_write("stop");
  check("stop -> bestmove within 3s", !await_line("bestmove", 3000).empty());

  pikafish_write("quit");
  for (int i = 0; i < 50 && !g_eof; ++i) usleep(100 * 1000);
  check("quit -> eof", g_eof);

  fprintf(stderr, g_failures == 0 ? "GATE B (native) PASS\n"
                                  : "GATE B (native) FAIL\n");
  return g_failures == 0 ? 0 : 1;
}
