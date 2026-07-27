// io.cpp — Nova C++20 runtime: file & directory I/O (real), plus socket / TLS /
// process / filesystem-watcher STUBS. The stubs return safe error defaults so
// the runtime links for any program; real Boost.Asio (sockets/TLS) and process/
// watcher implementations replace them in a later M3 step. Nova-facing strings
// use the (s-4) length-prefix convention (runtime_str.h).
#include "nova_abi.h"
#include "runtime_str.h"
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

// M3-D-5: real TCP sockets (blocking POSIX / Winsock) + TLS via wolfSSL.
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
using socklen_t = int;
static inline int nova_close_fd(int fd) { return ::closesocket(fd); }
#else
#include <arpa/inet.h>
#include <csignal>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
static inline int nova_close_fd(int fd) { return ::close(fd); }
#endif

// wolfSSL is optional at compile time: build.zig defines NOVA_HAVE_WOLFSSL and adds
// the include/link when the vendored deps/wolfssl is built. Without it, TLS stays
// stubbed (sockets still work). options.h MUST precede any other wolfSSL header.
#ifdef NOVA_HAVE_WOLFSSL
#include <wolfssl/options.h>
#include <wolfssl/ssl.h>
#endif

namespace fs = std::filesystem;

extern "C" {

// ===== File I/O (real, portable via stdio) =================================
static thread_local char g_file_err[256] = {0};
const char *nova_file_error(void) { return g_file_err; }

void *nova_file_open(const char *path, const char *mode) {
  char *p = nova_to_cstr(path), *m = nova_to_cstr(mode);
  FILE *fp = (p && m) ? std::fopen(p, m) : nullptr;
  if (!fp)
    std::snprintf(g_file_err, sizeof(g_file_err), "cannot open file");
  nova_free_cstr(path, p);
  nova_free_cstr(mode, m);
  return fp;
}
int nova_file_close(void *fp) { return fp ? std::fclose((FILE *)fp) : -1; }
int nova_file_read(void *fp, char *buf, int size) {
  if (!fp)
    return -1;
  // EINTR-safe: a signal (e.g. SIGCHLD when a supervised child dies) can make fread return short with
  // ferror/EINTR. Retry from where it left off so a manifest read isn't silently truncated mid-reconcile.
  FILE *f = (FILE *)fp;
  size_t total = 0;
  while (total < (size_t)size) {
    size_t n = std::fread(buf + total, 1, (size_t)size - total, f);
    total += n;
    if (n == 0) {
      if (std::feof(f))
        break;
      if (std::ferror(f) && errno == EINTR) {
        clearerr(f);
        continue;
      }
      break;
    }
  }
  return (int)total;
}
int nova_file_read_all(void *fp, char *buf, int size) {
  return nova_file_read(fp, buf, size);
}
int nova_file_write(void *fp, const char *buf, int size) {
  return fp ? (int)std::fwrite(buf, 1, (size_t)size, (FILE *)fp) : -1;
}
int nova_file_write_all(void *fp, const char *buf, int size) {
  return nova_file_write(fp, buf, size);
}
int nova_file_seek(void *fp, long offset, int whence) {
  return fp ? std::fseek((FILE *)fp, offset, whence) : -1;
}
long nova_file_tell(void *fp) { return fp ? std::ftell((FILE *)fp) : -1; }
int nova_file_eof(void *fp) { return fp ? std::feof((FILE *)fp) : 1; }
int nova_file_flush(void *fp) { return fp ? std::fflush((FILE *)fp) : -1; }
int nova_file_exists(const char *path) {
  char *p = nova_to_cstr(path);
  std::error_code ec;
  int r = (p && fs::exists(p, ec)) ? 1 : 0;
  nova_free_cstr(path, p);
  return r;
}
int nova_file_stat(const char *path, NovaFileStat *out) {
  char *p = nova_to_cstr(path);
  std::error_code ec;
  auto st = p ? fs::status(p, ec) : fs::file_status{};
  int r = (p && !ec && fs::exists(st)) ? 0 : -1;
  if (r == 0 && out) {
    out->size = (long)fs::file_size(p, ec);
    if (ec) out->size = 0;
    out->mode = 0;
    // std::filesystem exposes only last-write-time portably.
    auto mt = fs::last_write_time(p, ec);
    long secs = ec ? 0 : (long)std::chrono::duration_cast<std::chrono::seconds>(mt.time_since_epoch()).count();
    out->atime = secs; out->mtime = secs; out->ctime = secs;
    out->is_dir = fs::is_directory(st) ? 1 : 0;
    out->is_reg = fs::is_regular_file(st) ? 1 : 0;
    out->is_symlink = fs::is_symlink(st) ? 1 : 0;
  }
  nova_free_cstr(path, p);
  return r;
}

// ===== Directory ops (real, portable via std::filesystem) ==================
static thread_local char g_dir_err[256] = {0};
const char *nova_dir_error(void) { return g_dir_err; }

namespace {
struct DirHandle {
  fs::directory_iterator it;
  fs::directory_iterator end;
};
} // namespace

void *nova_dir_open(const char *path) {
  char *p = nova_to_cstr(path);
  void *result = nullptr;
  if (p) {
    std::error_code ec;
    fs::directory_iterator it(p, ec);
    if (!ec) {
      auto *d = new DirHandle();
      d->it = it;
      result = d;
    }
  }
  nova_free_cstr(path, p);
  return result;
}
int nova_dir_close(void *dir) {
  delete reinterpret_cast<DirHandle *>(dir);
  return 0;
}
const char *nova_dir_read(void *dir) {
  if (!dir) return nullptr;
  auto *d = reinterpret_cast<DirHandle *>(dir);
  if (d->it == d->end) return nullptr;
  std::string name = d->it->path().filename().string();
  std::error_code ec;
  d->it.increment(ec);
  return nova_from_cstr(name.c_str());
}
int nova_dir_create(const char *path, int mode) {
  (void)mode;
  char *p = nova_to_cstr(path);
  std::error_code ec;
  int r = (p && fs::create_directory(p, ec) && !ec) ? 0 : -1;
  nova_free_cstr(path, p);
  return r;
}
int nova_dir_remove(const char *path) {
  char *p = nova_to_cstr(path);
  std::error_code ec;
  int r = (p && fs::remove(p, ec) && !ec) ? 0 : -1;
  nova_free_cstr(path, p);
  return r;
}
int nova_dir_rename(const char *op, const char *np) {
  char *a = nova_to_cstr(op), *b = nova_to_cstr(np);
  std::error_code ec;
  int r = -1;
  if (a && b) { fs::rename(a, b, ec); r = ec ? -1 : 0; }
  nova_free_cstr(op, a);
  nova_free_cstr(np, b);
  return r;
}
int nova_dir_exists(const char *path) {
  char *p = nova_to_cstr(path);
  std::error_code ec;
  int r = (p && fs::is_directory(p, ec)) ? 1 : 0;
  nova_free_cstr(path, p);
  return r;
}
int nova_dir_is_dir(const char *path) { return nova_dir_exists(path); }
char *nova_dir_getcwd(void) {
  std::error_code ec;
  std::string cwd = fs::current_path(ec).string();
  return ec ? nullptr : const_cast<char *>(nova_from_cstr(cwd.c_str()));
}
int nova_dir_chdir(const char *path) {
  char *p = nova_to_cstr(path);
  std::error_code ec;
  int r = -1;
  if (p) { fs::current_path(p, ec); r = ec ? -1 : 0; }
  nova_free_cstr(path, p);
  return r;
}
int nova_dir_walk(const char *root, nova_dir_walk_callback cb, void *userdata) {
  (void)root; (void)cb; (void)userdata;
  return -1;
}

// ===== TCP sockets (blocking POSIX / Winsock) ==============================
namespace {
// Nova string byte length (int32 at s-4).
inline int nova_str_len(const char *s) {
  return s ? *reinterpret_cast<const int *>(s - 4) : 0;
}
#ifdef _WIN32
void nova_net_init() {
  static bool done = false;
  if (!done) {
    WSADATA w;
    WSAStartup(MAKEWORD(2, 2), &w);
    done = true;
  }
}
#else
inline void nova_net_init() {}
#endif
} // namespace

int nova_socket_connect(const char *host, int port) {
  nova_net_init();
  char *h = nova_to_cstr(host);
  if (!h) return -1;
  char portstr[16];
  std::snprintf(portstr, sizeof(portstr), "%d", port);

  struct addrinfo hints;
  std::memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *res = nullptr;
  int gai = ::getaddrinfo(h, portstr, &hints, &res);
  nova_free_cstr(host, h);
  if (gai != 0 || !res) return -1;

  int fd = -1;
  for (struct addrinfo *p = res; p; p = p->ai_next) {
    fd = (int)::socket(p->ai_family, p->ai_socktype, p->ai_protocol);
    if (fd < 0) continue;
    if (::connect(fd, p->ai_addr, (socklen_t)p->ai_addrlen) == 0) break;
    nova_close_fd(fd);
    fd = -1;
  }
  ::freeaddrinfo(res);
  return fd;
}

// D6: apply a receive + send timeout (in milliseconds) to an already-connected socket.
// A DB driver's `readAll` is a blocking `recv`; a hung-but-not-closed server would block
// the client indefinitely. With SO_RCVTIMEO set, a stalled `recv`/`send` returns -1 with
// errno EAGAIN/EWOULDBLOCK after `ms`, so the driver can surface a timeout instead of
// hanging forever. `ms <= 0` clears the timeout (blocking forever, the previous default).
// Returns 0 on success, -1 on error.
int nova_socket_set_timeout(int fd, int ms) {
  if (fd < 0) return -1;
#ifdef _WIN32
  DWORD tv = (ms > 0) ? (DWORD)ms : 0;
  int r1 = ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof(tv));
  int r2 = ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, (const char *)&tv, sizeof(tv));
#else
  struct timeval tv;
  tv.tv_sec = (ms > 0) ? (ms / 1000) : 0;
  tv.tv_usec = (ms > 0) ? ((ms % 1000) * 1000) : 0;
  int r1 = ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  int r2 = ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#endif
  return (r1 == 0 && r2 == 0) ? 0 : -1;
}

// D6: connect with a bounded wall-clock deadline (milliseconds). A blocking `connect` to a
// black-hole/firewalled host can hang for the OS default (~75s+); this puts the socket in
// non-blocking mode, starts the connect, and `select`s for writability with a `ms` timeout —
// returning -1 (and closing the fd) if the peer doesn't accept in time. On success the socket
// is switched back to BLOCKING mode (drivers then layer their own recv timeout on top). A
// `ms <= 0` falls back to the plain blocking connect.
int nova_socket_connect_timeout(const char *host, int port, int ms) {
  if (ms <= 0) return nova_socket_connect(host, port);
  nova_net_init();
  char *h = nova_to_cstr(host);
  if (!h) return -1;
  char portstr[16];
  std::snprintf(portstr, sizeof(portstr), "%d", port);
  struct addrinfo hints;
  std::memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo *res = nullptr;
  int gai = ::getaddrinfo(h, portstr, &hints, &res);
  nova_free_cstr(host, h);
  if (gai != 0 || !res) return -1;

  int fd = -1;
  for (struct addrinfo *p = res; p; p = p->ai_next) {
    fd = (int)::socket(p->ai_family, p->ai_socktype, p->ai_protocol);
    if (fd < 0) continue;
#ifdef _WIN32
    u_long nb = 1;
    ::ioctlsocket(fd, FIONBIO, &nb);
#else
    int flags = ::fcntl(fd, F_GETFL, 0);
    ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#endif
    int cr = ::connect(fd, p->ai_addr, (socklen_t)p->ai_addrlen);
    if (cr == 0) {
      // Immediate connect (loopback): restore blocking and return.
#ifdef _WIN32
      u_long bl = 0;
      ::ioctlsocket(fd, FIONBIO, &bl);
#else
      ::fcntl(fd, F_SETFL, flags);
#endif
      break;
    }
#ifdef _WIN32
    int inprog = (WSAGetLastError() == WSAEWOULDBLOCK);
#else
    int inprog = (errno == EINPROGRESS);
#endif
    if (inprog) {
      fd_set wset;
      FD_ZERO(&wset);
      FD_SET(fd, &wset);
      struct timeval tv;
      tv.tv_sec = ms / 1000;
      tv.tv_usec = (ms % 1000) * 1000;
      int sr = ::select(fd + 1, nullptr, &wset, nullptr, &tv);
      if (sr > 0) {
        int soerr = 0;
        socklen_t elen = sizeof(soerr);
        if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, (char *)&soerr, &elen) == 0 && soerr == 0) {
          // Connected in time — restore blocking mode.
#ifdef _WIN32
          u_long bl = 0;
          ::ioctlsocket(fd, FIONBIO, &bl);
#else
          ::fcntl(fd, F_SETFL, flags);
#endif
          break;
        }
      }
    }
    nova_close_fd(fd);
    fd = -1;
  }
  ::freeaddrinfo(res);
  return fd;
}

int nova_socket_listen(int port) {
  nova_net_init();
  int fd = (int)::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  int yes = 1;
  ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof(yes));
  struct sockaddr_in addr;
  std::memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port = htons((unsigned short)port);
  if (::bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
      ::listen(fd, 128) != 0) {
    nova_close_fd(fd);
    return -1;
  }
  return fd;
}

int nova_socket_accept(int server_fd) {
  int fd = (int)::accept(server_fd, nullptr, nullptr);
  return fd < 0 ? -1 : fd;
}

int nova_socket_send(int fd, const char *data) {
  int len = nova_str_len(data);
  if (len <= 0) return 0;
  int total = 0;
  while (total < len) {
    int n = (int)::send(fd, data + total, (size_t)(len - total), 0);
    if (n <= 0) return total > 0 ? total : -1;
    total += n;
  }
  return total;
}

// Length-aware binary send: sends exactly `len` raw bytes from `data`, ignoring the
// Nova string header. `nova_socket_send` derives its length from the [ptr-4] header and
// stops at that boundary — fine for text, but a binary wire frame (BTreeDB/Postgres/…)
// contains embedded NUL/arbitrary bytes and its length is decided by the protocol, not
// the allocation. This is the primitive every binary driver sends through. `data` may
// point into the middle of a buffer (partial writes), so it must NOT read the header.
int nova_socket_send_n(int fd, const char *data, int len) {
  if (len <= 0) return 0;
  int total = 0;
  while (total < len) {
    int n = (int)::send(fd, data + total, (size_t)(len - total), 0);
    if (n <= 0) return total > 0 ? total : -1;
    total += n;
  }
  return total;
}

int nova_socket_recv(int fd, char *buf, int max_len) {
  int n = (int)::recv(fd, buf, (size_t)max_len, 0);
  return n < 0 ? -1 : n;
}

// ===== TLS via wolfSSL (blocking, verify_peer) =============================
#ifdef NOVA_HAVE_WOLFSSL
struct TlsContext {
  WOLFSSL_CTX *ctx;
  WOLFSSL *ssl;
};

namespace {
void nova_wolfssl_init() {
  static bool done = false;
  if (!done) {
    wolfSSL_Init();
    done = true;
  }
}
} // namespace

// Create a client TLS context over an already-connected socket `fd`, verifying the
// peer certificate (WOLFSSL_VERIFY_PEER) against the system trust store. `hostname`
// is used for SNI and certificate name validation. Returns null on failure — the
// SECURE default (no silent verify-off).
TlsContext *nova_tls_new(int fd, const char *hostname) {
  nova_wolfssl_init();
  WOLFSSL_CTX *ctx = wolfSSL_CTX_new(wolfSSLv23_client_method());
  if (!ctx) return nullptr;
  wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_PEER, nullptr);
  // Load the OS trust store so verification has a CA set. If unavailable, the
  // handshake will fail verification (fail-closed) rather than trusting blindly.
  wolfSSL_CTX_load_system_CA_certs(ctx);

  WOLFSSL *ssl = wolfSSL_new(ctx);
  if (!ssl) {
    wolfSSL_CTX_free(ctx);
    return nullptr;
  }
  wolfSSL_set_fd(ssl, fd);
  char *hn = nova_to_cstr(hostname);
  if (hn) {
    wolfSSL_UseSNI(ssl, WOLFSSL_SNI_HOST_NAME, hn, (unsigned short)std::strlen(hn));
    wolfSSL_check_domain_name(ssl, hn); // verify cert matches hostname
    nova_free_cstr(hostname, hn);
  }
  TlsContext *tc = new TlsContext{ctx, ssl};
  return tc;
}

int nova_tls_handshake(TlsContext *ctx) {
  if (!ctx || !ctx->ssl) return -1;
  return wolfSSL_connect(ctx->ssl) == WOLFSSL_SUCCESS ? 0 : -1;
}

int nova_tls_write(TlsContext *ctx, const char *data) {
  if (!ctx || !ctx->ssl) return -1;
  int len = nova_str_len(data);
  if (len <= 0) return 0;
  return wolfSSL_write(ctx->ssl, data, len);
}

int nova_tls_read(TlsContext *ctx, char *buf, int max_len) {
  if (!ctx || !ctx->ssl) return -1;
  int n = wolfSSL_read(ctx->ssl, buf, max_len);
  return n < 0 ? -1 : n;
}

void nova_tls_free(TlsContext *ctx) {
  if (!ctx) return;
  if (ctx->ssl) wolfSSL_free(ctx->ssl);
  if (ctx->ctx) wolfSSL_CTX_free(ctx->ctx);
  delete ctx;
}

// ===== TDS-tunneled TLS (MS SQL Server) ====================================
// TDS carries the TLS HANDSHAKE records inside TDS PRELOGIN (0x12) packets; once the
// handshake completes, TLS runs RAW over the socket and the LOGIN7/SQLBatch TDS packets
// become the plaintext that TLS encrypts. Custom wolfSSL I/O callbacks do the wrapping.
struct TdsTlsCtx {
  WOLFSSL_CTX *ctx;
  WOLFSSL *ssl;
  int fd;
  bool handshake_done;
  int cur_remaining;             // bytes left in the current inbound TDS packet's payload
  std::vector<unsigned char> ob; // handshake send buffer: coalesce a whole flight into ONE packet
};

static int tds_read_exact(int fd, unsigned char *buf, int n) {
  int total = 0;
  while (total < n) {
    int r = (int)::recv(fd, buf + total, (size_t)(n - total), 0);
    if (r <= 0) return -1;
    total += r;
  }
  return total;
}
static int tds_write_all(int fd, const unsigned char *buf, int n) {
  int total = 0;
  while (total < n) {
    int r = (int)::send(fd, buf + total, (size_t)(n - total), 0);
    if (r <= 0) return -1;
    total += r;
  }
  return total;
}

// Flush the buffered handshake flight as ONE PRELOGIN packet. SQL Server 2022 rejects a TLS
// flight split across multiple PRELOGIN packets, so all of wolfSSL's sends between two reads
// (a full flight: e.g. ClientKeyExchange+ChangeCipherSpec+Finished) must go out together.
static int nova_tds_flush(TdsTlsCtx *c) {
  if (c->ob.empty()) return 0;
  int total = 8 + (int)c->ob.size();
  unsigned char hdr[8] = {0x12, 0x01, (unsigned char)((total >> 8) & 0xFF),
                          (unsigned char)(total & 0xFF), 0, 0, 1, 0};
  if (tds_write_all(c->fd, hdr, 8) < 0) return -1;
  if (tds_write_all(c->fd, c->ob.data(), (int)c->ob.size()) < 0) return -1;
  c->ob.clear();
  return 0;
}

// wolfSSL SEND: BUFFER the TLS bytes during the handshake (flushed as one flight on the next
// read); once the handshake completes, TLS runs raw over the socket.
static int nova_tds_io_send(WOLFSSL *ssl, char *buf, int sz, void *p) {
  (void)ssl;
  TdsTlsCtx *c = (TdsTlsCtx *)p;
  if (c->handshake_done) {
    return tds_write_all(c->fd, (const unsigned char *)buf, sz) < 0 ? WOLFSSL_CBIO_ERR_GENERAL : sz;
  }
  c->ob.insert(c->ob.end(), (const unsigned char *)buf, (const unsigned char *)buf + sz);
  return sz;
}

// wolfSSL RECV: unwrap TDS 0x12 packet payloads during the handshake; raw after.
static int nova_tds_io_recv(WOLFSSL *ssl, char *buf, int sz, void *p) {
  (void)ssl;
  TdsTlsCtx *c = (TdsTlsCtx *)p;
  if (c->handshake_done) {
    int n = (int)::recv(c->fd, buf, (size_t)sz, 0);
    if (n == 0) return WOLFSSL_CBIO_ERR_CONN_CLOSE;
    return n < 0 ? WOLFSSL_CBIO_ERR_GENERAL : n;
  }
  // wolfSSL is about to read: the current outgoing flight is complete — flush it as one packet.
  if (nova_tds_flush(c) < 0) return WOLFSSL_CBIO_ERR_GENERAL;
  while (c->cur_remaining <= 0) {
    unsigned char hdr[8];
    if (tds_read_exact(c->fd, hdr, 8) < 0) return WOLFSSL_CBIO_ERR_GENERAL;
    c->cur_remaining = ((hdr[2] << 8) | hdr[3]) - 8; // TDS length is big-endian, incl. header
    if (c->cur_remaining < 0) return WOLFSSL_CBIO_ERR_GENERAL;
  }
  int want = sz < c->cur_remaining ? sz : c->cur_remaining;
  int n = (int)::recv(c->fd, buf, (size_t)want, 0);
  if (n == 0) return WOLFSSL_CBIO_ERR_CONN_CLOSE;
  if (n < 0) return WOLFSSL_CBIO_ERR_GENERAL;
  c->cur_remaining -= n;
  return n;
}

// Create a TDS-tunneled TLS client over an already-connected socket `fd`. The peer cert is
// NOT verified (SQL Server ships a self-signed cert; drivers use TrustServerCertificate by
// default — verification/pinning is a follow-on). Returns an opaque handle or null.
void *nova_tds_tls_new(int fd) {
  nova_wolfssl_init();
  // TLS 1.2 (SQL Server's TDS-tunneled handshake is 1.2). LIVE-VERIFIED against SQL Server 2022.
  // Two things were load-bearing: (1) wolfSSL built with WOLFSSL_SECURE_RENEGOTIATION so the
  // ClientHello carries renegotiation_info (Schannel requires it), and (2) coalescing each TLS
  // FLIGHT into ONE PRELOGIN packet (nova_tds_flush) — the server rejects a flight split across
  // packets, which wolfSSL's per-record sends would otherwise do.
  WOLFSSL_CTX *ctx = wolfSSL_CTX_new(wolfTLSv1_2_client_method());
  if (!ctx) return nullptr;
  wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_NONE, nullptr);
  wolfSSL_CTX_SetIORecv(ctx, nova_tds_io_recv);
  wolfSSL_CTX_SetIOSend(ctx, nova_tds_io_send);
  WOLFSSL *ssl = wolfSSL_new(ctx);
  if (!ssl) { wolfSSL_CTX_free(ctx); return nullptr; }
  // SQL Server 2022 (Schannel-family) requires the renegotiation_info extension (RFC 5746);
  // wolfSSL must be built with WOLFSSL_SECURE_RENEGOTIATION (see build.zig) for this to link.
  wolfSSL_UseSecureRenegotiation(ssl);
  TdsTlsCtx *c = new TdsTlsCtx{ctx, ssl, fd, false, 0, {}};
  wolfSSL_SetIOReadCtx(ssl, c);
  wolfSSL_SetIOWriteCtx(ssl, c);
  return c;
}

int nova_tds_tls_handshake(void *p) {
  TdsTlsCtx *c = (TdsTlsCtx *)p;
  if (!c || !c->ssl) return -1;
  int r = wolfSSL_connect(c->ssl);
  if (r == WOLFSSL_SUCCESS) { c->handshake_done = true; return 0; }
  return -1;
}
int nova_tds_tls_write(void *p, const char *data, int len) {
  TdsTlsCtx *c = (TdsTlsCtx *)p;
  if (!c || !c->ssl || len <= 0) return 0;
  return wolfSSL_write(c->ssl, data, len);
}
int nova_tds_tls_read(void *p, char *buf, int max_len) {
  TdsTlsCtx *c = (TdsTlsCtx *)p;
  if (!c || !c->ssl) return -1;
  int n = wolfSSL_read(c->ssl, buf, max_len);
  return n < 0 ? -1 : n;
}
void nova_tds_tls_free(void *p) {
  TdsTlsCtx *c = (TdsTlsCtx *)p;
  if (!c) return;
  if (c->ssl) wolfSSL_free(c->ssl);
  if (c->ctx) wolfSSL_CTX_free(c->ctx);
  delete c;
}

// ===== Async memory-BIO TLS (driver-agnostic, non-blocking) ================
// wolfSSL runs against in-memory ciphertext queues instead of a socket fd; the Nova async
// pump (net/asynctls.nova) does the REAL socket I/O over AsyncStream WITH coroutine parking.
// This is what gives every DB driver non-blocking TLS while keeping ALL cryptography and X.509
// certificate verification inside wolfSSL — only the record I/O loop moves to Nova on the
// async-first seam. The contract with the Nova pump:
//   handshake/read/write drive wolfSSL; when wolfSSL wants bytes it returns "want-io".
//   The pump then PULLs any produced ciphertext (flush to socket) and, on want-read, awaits
//   more ciphertext from the socket and FEEDs it back — parking the coroutine across each wait.
struct MemTlsCtx {
  WOLFSSL_CTX *ctx;
  WOLFSSL *ssl;
  std::vector<unsigned char> in;  // ciphertext received from the socket, feeding wolfSSL recv
  size_t in_pos;                  // read cursor into `in` (compacted when fully drained)
  std::vector<unsigned char> out; // ciphertext wolfSSL produced, awaiting a socket flush
  bool in_closed;                 // the peer closed the underlying socket (EOF)
  bool is_server;                 // server side drives wolfSSL_accept, not wolfSSL_connect
};

// wolfSSL RECV callback: hand it bytes from the input queue, or WANT_READ when it is empty
// (so wolfSSL_connect/read return want-io and the Nova pump can await more ciphertext).
static int nova_mtls_io_recv(WOLFSSL *ssl, char *buf, int sz, void *p) {
  (void)ssl;
  MemTlsCtx *c = (MemTlsCtx *)p;
  size_t avail = c->in.size() - c->in_pos;
  if (avail == 0) return c->in_closed ? WOLFSSL_CBIO_ERR_CONN_CLOSE : WOLFSSL_CBIO_ERR_WANT_READ;
  int n = sz < (int)avail ? sz : (int)avail;
  std::memcpy(buf, c->in.data() + c->in_pos, (size_t)n);
  c->in_pos += (size_t)n;
  if (c->in_pos == c->in.size()) { c->in.clear(); c->in_pos = 0; }
  return n;
}
// wolfSSL SEND callback: append produced ciphertext to the output queue (the pump flushes it).
static int nova_mtls_io_send(WOLFSSL *ssl, char *buf, int sz, void *p) {
  (void)ssl;
  MemTlsCtx *c = (MemTlsCtx *)p;
  c->out.insert(c->out.end(), (const unsigned char *)buf, (const unsigned char *)buf + sz);
  return sz;
}

// Create a client memory-BIO TLS context. `verify != 0` = verify the peer cert against the
// system trust store and validate `hostname` (the SECURE default); `verify == 0` = no
// verification (only for self-signed dev servers, e.g. SQL Server's default cert). Negotiates
// TLS 1.2/1.3 (wolfSSLv23_client_method). Returns an opaque handle or null.
void *nova_mtls_new(const char *hostname, int verify) {
  nova_wolfssl_init();
  WOLFSSL_CTX *ctx = wolfSSL_CTX_new(wolfSSLv23_client_method());
  if (!ctx) return nullptr;
  if (verify) {
    wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_PEER, nullptr);
    wolfSSL_CTX_load_system_CA_certs(ctx);
  } else {
    wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_NONE, nullptr);
  }
  wolfSSL_CTX_SetIORecv(ctx, nova_mtls_io_recv);
  wolfSSL_CTX_SetIOSend(ctx, nova_mtls_io_send);
  WOLFSSL *ssl = wolfSSL_new(ctx);
  if (!ssl) { wolfSSL_CTX_free(ctx); return nullptr; }
  if (hostname && hostname[0]) {
    wolfSSL_UseSNI(ssl, WOLFSSL_SNI_HOST_NAME, hostname, (unsigned short)std::strlen(hostname));
    if (verify) wolfSSL_check_domain_name(ssl, (char *)hostname); // cert must match hostname
  }
  MemTlsCtx *c = new MemTlsCtx{ctx, ssl, {}, 0, {}, false, false};
  wolfSSL_SetIOReadCtx(ssl, c);
  wolfSSL_SetIOWriteCtx(ssl, c);
  return c;
}

// Create a SERVER memory-BIO TLS context from a PEM certificate + private key (both in memory).
// Used to stand up an in-process TLS peer (tests) and, later, Nova TLS servers. Returns null on
// failure (bad cert/key).
void *nova_mtls_new_server(const char *cert, int cert_len, const char *key, int key_len) {
  nova_wolfssl_init();
  WOLFSSL_CTX *ctx = wolfSSL_CTX_new(wolfSSLv23_server_method());
  if (!ctx) return nullptr;
  if (wolfSSL_CTX_use_certificate_buffer(ctx, (const unsigned char *)cert, cert_len,
                                         WOLFSSL_FILETYPE_PEM) != WOLFSSL_SUCCESS ||
      wolfSSL_CTX_use_PrivateKey_buffer(ctx, (const unsigned char *)key, key_len,
                                        WOLFSSL_FILETYPE_PEM) != WOLFSSL_SUCCESS) {
    wolfSSL_CTX_free(ctx);
    return nullptr;
  }
  wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_NONE, nullptr); // no client-cert (mutual TLS is later)
  wolfSSL_CTX_SetIORecv(ctx, nova_mtls_io_recv);
  wolfSSL_CTX_SetIOSend(ctx, nova_mtls_io_send);
  WOLFSSL *ssl = wolfSSL_new(ctx);
  if (!ssl) { wolfSSL_CTX_free(ctx); return nullptr; }
  MemTlsCtx *c = new MemTlsCtx{ctx, ssl, {}, 0, {}, false, true};
  wolfSSL_SetIOReadCtx(ssl, c);
  wolfSSL_SetIOWriteCtx(ssl, c);
  return c;
}

// Drive the handshake one step. 0 = complete, 1 = want-io (flush out, feed more in), -1 = error.
int nova_mtls_handshake(void *p) {
  MemTlsCtx *c = (MemTlsCtx *)p;
  if (!c || !c->ssl) return -1;
  int r = c->is_server ? wolfSSL_accept(c->ssl) : wolfSSL_connect(c->ssl);
  if (r == WOLFSSL_SUCCESS) return 0;
  int e = wolfSSL_get_error(c->ssl, r);
  if (e == WOLFSSL_ERROR_WANT_READ || e == WOLFSSL_ERROR_WANT_WRITE) return 1;
  return -1;
}

// Feed received ciphertext (raw bytes, `len` of them) into the input queue.
void nova_mtls_feed(void *p, const char *data, int len) {
  MemTlsCtx *c = (MemTlsCtx *)p;
  if (!c || len <= 0) return;
  c->in.insert(c->in.end(), (const unsigned char *)data, (const unsigned char *)data + len);
}
// Mark the underlying socket as closed (EOF) so a subsequent empty recv is CONN_CLOSE, not want-read.
void nova_mtls_mark_closed(void *p) { MemTlsCtx *c = (MemTlsCtx *)p; if (c) c->in_closed = true; }

// Copy up to `max` bytes of pending outbound ciphertext into `buf`. Returns bytes copied (0 = none).
int nova_mtls_pull(void *p, char *buf, int max) {
  MemTlsCtx *c = (MemTlsCtx *)p;
  if (!c || max <= 0 || c->out.empty()) return 0;
  int n = (int)c->out.size() < max ? (int)c->out.size() : max;
  std::memcpy(buf, c->out.data(), (size_t)n);
  c->out.erase(c->out.begin(), c->out.begin() + n);
  return n;
}
int nova_mtls_pending_out(void *p) { MemTlsCtx *c = (MemTlsCtx *)p; return c ? (int)c->out.size() : 0; }

// Encrypt `len` plaintext bytes → output queue. Returns bytes accepted or -1.
int nova_mtls_write(void *p, const char *data, int len) {
  MemTlsCtx *c = (MemTlsCtx *)p;
  if (!c || !c->ssl || len <= 0) return 0;
  int r = wolfSSL_write(c->ssl, data, len);
  return r < 0 ? -1 : r;
}
// Decrypt from the input queue → `buf` (up to `max`). >0 = plaintext bytes, 0 = want-read (need
// more ciphertext fed), -1 = error / clean TLS close.
int nova_mtls_read(void *p, char *buf, int max) {
  MemTlsCtx *c = (MemTlsCtx *)p;
  if (!c || !c->ssl) return -1;
  int r = wolfSSL_read(c->ssl, buf, max);
  if (r > 0) return r;
  int e = wolfSSL_get_error(c->ssl, r);
  if (e == WOLFSSL_ERROR_WANT_READ || e == WOLFSSL_ERROR_WANT_WRITE) return 0;
  return -1;
}
void nova_mtls_free(void *p) {
  MemTlsCtx *c = (MemTlsCtx *)p;
  if (!c) return;
  if (c->ssl) wolfSSL_free(c->ssl);
  if (c->ctx) wolfSSL_CTX_free(c->ctx);
  delete c;
}
#else
// wolfSSL not compiled in — TLS unavailable (sockets still work).
struct TlsContext {
  int unused;
};
TlsContext *nova_tls_new(int fd, const char *hostname) {
  (void)fd;
  (void)hostname;
  return nullptr;
}
int nova_tls_handshake(TlsContext *ctx) {
  (void)ctx;
  return -1;
}
int nova_tls_write(TlsContext *ctx, const char *data) {
  (void)ctx;
  (void)data;
  return -1;
}
int nova_tls_read(TlsContext *ctx, char *buf, int max_len) {
  (void)ctx;
  (void)buf;
  (void)max_len;
  return -1;
}
void nova_tls_free(TlsContext *ctx) { (void)ctx; }
// TDS-tunneled TLS stubs (wolfSSL not compiled in).
void *nova_tds_tls_new(int fd) { (void)fd; return nullptr; }
int nova_tds_tls_handshake(void *p) { (void)p; return -1; }
int nova_tds_tls_write(void *p, const char *data, int len) { (void)p; (void)data; (void)len; return -1; }
int nova_tds_tls_read(void *p, char *buf, int max_len) { (void)p; (void)buf; (void)max_len; return -1; }
void nova_tds_tls_free(void *p) { (void)p; }
// Async memory-BIO TLS stubs (wolfSSL not compiled in).
void *nova_mtls_new(const char *hostname, int verify) { (void)hostname; (void)verify; return nullptr; }
void *nova_mtls_new_server(const char *cert, int cert_len, const char *key, int key_len) { (void)cert; (void)cert_len; (void)key; (void)key_len; return nullptr; }
int nova_mtls_handshake(void *p) { (void)p; return -1; }
void nova_mtls_feed(void *p, const char *data, int len) { (void)p; (void)data; (void)len; }
void nova_mtls_mark_closed(void *p) { (void)p; }
int nova_mtls_pull(void *p, char *buf, int max) { (void)p; (void)buf; (void)max; return 0; }
int nova_mtls_pending_out(void *p) { (void)p; return 0; }
int nova_mtls_write(void *p, const char *data, int len) { (void)p; (void)data; (void)len; return -1; }
int nova_mtls_read(void *p, char *buf, int max) { (void)p; (void)buf; (void)max; return -1; }
void nova_mtls_free(void *p) { (void)p; }
#endif

// ===== Process primitives (R1) =============================================
// The dumb, identity-free exec layer the orchestrator/reverse-proxy build on: spawn a BINARY, talk to
// its stdio, wait, signal it. Identity here is the kernel PID (unique by construction) — no names, no
// pools, no scaling logic (that all lives up in the Nova "service" tier). POSIX fork/execvp/pipe/waitpid;
// Windows gets stubs (the orchestrator targets Linux).
struct ProcessContext {
  long pid;      // child PID (long, not the 32-bit `int` — a PID must never truncate). 0 after reap.
  int in_fd;     // parent's WRITE end of the child's stdin (-1 if closed)
  int out_fd;    // parent's READ end of the child's stdout (-1 if closed)
  int exit_code; // cached WEXITSTATUS once reaped
  bool reaped;   // wait() already collected the exit status
};

#ifndef _WIN32
// Split the newline-joined args_str (process.nova builds it) into a NUL-terminated argv, with cmd as
// argv[0]. Returned pointers borrow `storage` (which owns the byte copies) — keep it alive until execvp.
static std::vector<char *> nova_build_argv(const char *cmd, const char *args_str,
                                           std::vector<std::string> &storage) {
  storage.clear();
  storage.emplace_back(cmd ? cmd : "");
  if (args_str && *args_str) {
    std::string cur;
    for (const char *p = args_str; *p; ++p) {
      if (*p == '\n') {
        storage.emplace_back(cur);
        cur.clear();
      } else {
        cur.push_back(*p);
      }
    }
    storage.emplace_back(cur); // trailing arg (no terminating '\n')
  }
  std::vector<char *> argv;
  argv.reserve(storage.size() + 1);
  for (auto &s : storage)
    argv.push_back(const_cast<char *>(s.c_str()));
  argv.push_back(nullptr);
  return argv;
}

ProcessContext *nova_process_spawn(const char *cmd, const char *args_str) {
  char *c_cmd = nova_to_cstr(cmd);
  char *c_args = nova_to_cstr(args_str);

  int in_pipe[2] = {-1, -1};  // parent writes -> child stdin
  int out_pipe[2] = {-1, -1}; // child stdout -> parent reads
  if (::pipe(in_pipe) != 0 || ::pipe(out_pipe) != 0) {
    if (in_pipe[0] >= 0) ::close(in_pipe[0]);
    if (in_pipe[1] >= 0) ::close(in_pipe[1]);
    if (out_pipe[0] >= 0) ::close(out_pipe[0]);
    if (out_pipe[1] >= 0) ::close(out_pipe[1]);
    nova_free_cstr(cmd, c_cmd);
    nova_free_cstr(args_str, c_args);
    return nullptr;
  }

  pid_t pid = ::fork();
  if (pid < 0) {
    ::close(in_pipe[0]); ::close(in_pipe[1]);
    ::close(out_pipe[0]); ::close(out_pipe[1]);
    nova_free_cstr(cmd, c_cmd);
    nova_free_cstr(args_str, c_args);
    return nullptr;
  }

  if (pid == 0) {
    // Child: wire stdin/stdout to the pipes, close every stray fd, exec the binary.
    ::dup2(in_pipe[0], STDIN_FILENO);
    ::dup2(out_pipe[1], STDOUT_FILENO);
    ::close(in_pipe[0]); ::close(in_pipe[1]);
    ::close(out_pipe[0]); ::close(out_pipe[1]);
    std::vector<std::string> storage;
    std::vector<char *> argv = nova_build_argv(c_cmd, c_args, storage);
    ::execvp(argv[0], argv.data());
    _exit(127); // execvp only returns on failure (matches shell "command not found")
  }

  // Parent: keep the write-to-child and read-from-child ends; close the child's copies.
  ::close(in_pipe[0]);
  ::close(out_pipe[1]);
  nova_free_cstr(cmd, c_cmd);
  nova_free_cstr(args_str, c_args);

  ProcessContext *ctx = new ProcessContext{(long)pid, in_pipe[1], out_pipe[0], 0, false};
  return ctx;
}

int nova_process_write_stdin(ProcessContext *ctx, const char *data) {
  if (!ctx || ctx->in_fd < 0 || !data)
    return -1;
  int len = *reinterpret_cast<const int *>(data - 4); // canonical Nova string length (binary-safe)
  if (len < 0 || len > 64 * 1024 * 1024)
    len = (int)std::strlen(data); // fallback for a non-canonical/C string
  ssize_t n = ::write(ctx->in_fd, data, (size_t)len);
  return (int)n;
}

int nova_process_read_stdout(ProcessContext *ctx, char *buf, int max_len) {
  if (!ctx || ctx->out_fd < 0 || !buf || max_len <= 0)
    return -1;
  ssize_t n = ::read(ctx->out_fd, buf, (size_t)max_len); // blocks until data or EOF (0)
  return (int)n;
}

int nova_process_wait(ProcessContext *ctx) {
  if (!ctx)
    return -1;
  if (ctx->reaped)
    return ctx->exit_code;
  // Closing the child's stdin first lets a filter that reads-to-EOF finish instead of deadlocking.
  if (ctx->in_fd >= 0) { ::close(ctx->in_fd); ctx->in_fd = -1; }
  int status = 0;
  pid_t r;
  do {
    r = ::waitpid((pid_t)ctx->pid, &status, 0);
  } while (r < 0 && errno == EINTR);
  if (r < 0)
    return -1;
  ctx->reaped = true;
  ctx->exit_code = WIFEXITED(status) ? WEXITSTATUS(status)
                   : WIFSIGNALED(status) ? 128 + WTERMSIG(status) // shell convention
                                         : -1;
  return ctx->exit_code;
}

// I2 addition: the child's kernel PID (for cgroup.procs attach + observability). 0 if none.
long long nova_process_pid(ProcessContext *ctx) {
  return ctx ? (long long)ctx->pid : 0;
}

// R1/I2 addition: NON-BLOCKING exit poll (waitpid WNOHANG). Returns the exit code if the child has
// exited (reaping it so it never becomes a zombie), -2 if it is still running, or -1 on error / no such
// child. This is what the orchestrator's async reconcile loop needs — kill(pid,0) can't tell a live
// process from an unreaped zombie, and nova_process_wait blocks. Exit-code convention matches
// nova_process_wait (128+signal for a killed child).
int nova_process_try_wait(ProcessContext *ctx) {
  if (!ctx)
    return -1;
  if (ctx->reaped)
    return ctx->exit_code;
  if (ctx->pid <= 0)
    return -1;
  int status = 0;
  pid_t r;
  do {
    r = ::waitpid((pid_t)ctx->pid, &status, WNOHANG);
  } while (r < 0 && errno == EINTR);
  if (r == 0)
    return -2; // still running
  if (r < 0)
    return -1; // error (e.g. ECHILD)
  ctx->reaped = true;
  ctx->exit_code = WIFEXITED(status) ? WEXITSTATUS(status)
                   : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                         : -1;
  return ctx->exit_code;
}

// R1 addition: signal the child (SIGTERM=15 graceful, SIGKILL=9 hard). The scale-down / restart-on-crash
// primitive the orchestrator needs. Returns 0 on success, -1 on error.
int nova_process_kill(ProcessContext *ctx, int sig) {
  if (!ctx || ctx->pid <= 0)
    return -1;
  return ::kill((pid_t)ctx->pid, sig) == 0 ? 0 : -1;
}

void nova_process_free(ProcessContext *ctx) {
  if (!ctx)
    return;
  if (ctx->in_fd >= 0) ::close(ctx->in_fd);
  if (ctx->out_fd >= 0) ::close(ctx->out_fd);
  // Best-effort reap so a finished child does not linger as a zombie (non-blocking — never stalls free).
  if (!ctx->reaped && ctx->pid > 0) {
    int status = 0;
    ::waitpid((pid_t)ctx->pid, &status, WNOHANG);
  }
  delete ctx;
}
#else
// Windows: process control is unimplemented (the orchestrator targets Linux). Stubs keep the PE build linking.
ProcessContext *nova_process_spawn(const char *cmd, const char *args_str) {
  (void)cmd; (void)args_str; return nullptr;
}
int nova_process_write_stdin(ProcessContext *ctx, const char *data) { (void)ctx; (void)data; return -1; }
int nova_process_read_stdout(ProcessContext *ctx, char *buf, int max_len) {
  (void)ctx; (void)buf; (void)max_len; return -1;
}
int nova_process_wait(ProcessContext *ctx) { (void)ctx; return -1; }
long long nova_process_pid(ProcessContext *ctx) { (void)ctx; return 0; }
int nova_process_try_wait(ProcessContext *ctx) { (void)ctx; return -1; }
int nova_process_kill(ProcessContext *ctx, int sig) { (void)ctx; (void)sig; return -1; }
void nova_process_free(ProcessContext *ctx) { (void)ctx; }
#endif
WatcherContext *nova_fs_watcher_create(const char *path) {
  (void)path;
  return nullptr;
}
const char *nova_fs_watcher_next_event(WatcherContext *ctx) {
  (void)ctx;
  return nullptr;
}
void nova_fs_watcher_free_event(const char *ptr) { (void)ptr; }
void nova_fs_watcher_close(WatcherContext *ctx) { (void)ctx; }

} // extern "C"
