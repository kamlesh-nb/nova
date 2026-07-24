// runtime.cpp — Nova C++20 runtime unity build.
//
// Compiled per `nova build` (like the old C runtime.c) with clang++ -std=c++20.
// Every Nova-facing symbol has C linkage (extern "C") so the LLVM codegen's
// unmangled calls resolve. See nova_abi.h for the frozen contract.
//
// v0 scope: full ARC allocator (arena-faithful), all core subsystems, real
// file/dir I/O, SYNCHRONOUS concurrency shim. TODO (next M3 steps): replace the
// concurrency shim with Boost.Asio io_context + Boost.Context stackful fibers;
// implement sockets/TLS on asio::ssl (verify_peer); real process/watcher.
#include "alloc.cpp"
#include "core.cpp"
#include "decimal.cpp"
// concurrency.cpp (Boost.Asio) is included BEFORE io.cpp (wolfSSL) so Asio's
// platform/threads detection resolves before wolfSSL's options.h defines any macros
// that would confuse it (they share one preprocessor state in this unity build).
#include "concurrency.cpp"
#include "io.cpp"
// crypto.cpp (wolfCrypt) AFTER io.cpp so wolfSSL's options.h/ssl.h are already
// sequenced relative to Asio.
#include "crypto.cpp"
// compress.cpp (zlib gzip) AFTER io.cpp — it uses io.cpp's inline nova_str_len.
#include "compress.cpp"
