// C entry points for driving official Pikafish NNUE in-process over UCI.
//
// The engine is a main() program that speaks UCI on stdin/stdout. This bridge
// gives it a pair of pipes instead and runs it on a background thread, so the
// host process can exchange UCI text with it through ordinary function calls.
//
// Lifetime: the engine can be started exactly once per process. Pikafish holds
// global state that is not designed to be torn down and re-initialised, so
// there is no stop-and-restart. Send "quit" only at process shutdown.

#ifndef PIKAFISH_BRIDGE_H
#define PIKAFISH_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// `used` complements default visibility for Apple builds, where the symbols
// are resolved via DynamicLibrary.process().
#define PIKAFISH_EXPORT \
  __attribute__((visibility("default"))) __attribute__((used))

#define PIKAFISH_OK               0
#define PIKAFISH_ERR_ALREADY     -1  // start() called twice
#define PIKAFISH_ERR_NOT_STARTED -2  // read/write before a successful start()
#define PIKAFISH_ERR_INVALID     -3  // null buffer or non-positive capacity
#define PIKAFISH_ERR_PIPE        -4  // pipe()/dup2() failed
#define PIKAFISH_ERR_THREAD      -5  // pthread_create() failed
#define PIKAFISH_ERR_IO          -6  // read()/write() failed

// Starts the engine. Returns PIKAFISH_OK or a negative error code.
//
// NOTE: this redirects the calling process's STDIN and STDOUT onto the engine
// pipes, and fd 1 becomes the *write* end of the engine-to-host pipe. So
// anything the host writes to stdout after this call resurfaces in
// pikafish_read() as if the engine had said it. Host diagnostics must go to
// stderr, and the line consumer must ignore anything it does not recognise.
// Symmetrically, the host must not read fd 0: that would steal commands
// destined for the engine.
PIKAFISH_EXPORT int pikafish_start(void);

// Non-zero while the engine loop is running.
PIKAFISH_EXPORT int pikafish_is_running(void);

// Sends one UCI command. A trailing newline is appended when absent.
PIKAFISH_EXPORT int pikafish_write(const char* command);

// Blocking read of engine output. Returns bytes read, 0 at EOF (the engine has
// exited), or a negative error code. Output is a raw byte stream: the caller
// assembles lines.
PIKAFISH_EXPORT int pikafish_read(char* buffer, int capacity);

#ifdef __cplusplus
}
#endif
#endif  // PIKAFISH_BRIDGE_H
