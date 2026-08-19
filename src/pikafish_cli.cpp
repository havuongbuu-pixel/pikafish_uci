// Desktop entry point for the patched engine core.
//
// patches/0001-rename-main.patch renames Pikafish's main() to pikafish_main()
// so the same objects can be linked into a shared library for FFI. This shim
// gives the desktop build an entry point again, which is what
// tools/bench_parity.sh drives.

int pikafish_main(int argc, char* argv[]);

int main(int argc, char* argv[]) { return pikafish_main(argc, argv); }
