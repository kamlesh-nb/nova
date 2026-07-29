
#include "nova_abi.h"
#include "runtime_str.h"
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

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

#if defined(__linux__)
#include <linux/sched.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <linux/audit.h>
#include <linux/capability.h>
#ifndef _LINUX_CAPABILITY_VERSION_3
#define _LINUX_CAPABILITY_VERSION_3 0x20080522
#endif
#endif

enum NovaIsoNs {
  NOVA_NS_PID  = 1,
  NOVA_NS_MOUNT = 2,
  NOVA_NS_UTS  = 4,
  NOVA_NS_IPC  = 8,
  NOVA_NS_NET  = 16,
  NOVA_NS_USER = 32,
};

#ifdef NOVA_HAVE_WOLFSSL
#include <wolfssl/options.h>
#include <wolfssl/ssl.h>
#endif

extern "C" {

// File and directory I/O (nova_file_*/nova_dir_*) was retired in M5: it now lives in Nova over
// the raw POSIX syscalls in os/sys (src/std/io/file.nova, src/std/io/dir.nova). What remains in
// this file is the blocking socket connect and the wolfSSL memory-BIO TLS pump.

namespace {

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
}

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
}

TlsContext *nova_tls_new(int fd, const char *hostname) {
  nova_wolfssl_init();
  WOLFSSL_CTX *ctx = wolfSSL_CTX_new(wolfSSLv23_client_method());
  if (!ctx) return nullptr;
  wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_PEER, nullptr);

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
    wolfSSL_check_domain_name(ssl, hn);
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

struct TdsTlsCtx {
  WOLFSSL_CTX *ctx;
  WOLFSSL *ssl;
  int fd;
  bool handshake_done;
  int cur_remaining;
  std::vector<unsigned char> ob;
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

static int nova_tds_io_send(WOLFSSL *ssl, char *buf, int sz, void *p) {
  (void)ssl;
  TdsTlsCtx *c = (TdsTlsCtx *)p;
  if (c->handshake_done) {
    return tds_write_all(c->fd, (const unsigned char *)buf, sz) < 0 ? WOLFSSL_CBIO_ERR_GENERAL : sz;
  }
  c->ob.insert(c->ob.end(), (const unsigned char *)buf, (const unsigned char *)buf + sz);
  return sz;
}

static int nova_tds_io_recv(WOLFSSL *ssl, char *buf, int sz, void *p) {
  (void)ssl;
  TdsTlsCtx *c = (TdsTlsCtx *)p;
  if (c->handshake_done) {
    int n = (int)::recv(c->fd, buf, (size_t)sz, 0);
    if (n == 0) return WOLFSSL_CBIO_ERR_CONN_CLOSE;
    return n < 0 ? WOLFSSL_CBIO_ERR_GENERAL : n;
  }

  if (nova_tds_flush(c) < 0) return WOLFSSL_CBIO_ERR_GENERAL;
  while (c->cur_remaining <= 0) {
    unsigned char hdr[8];
    if (tds_read_exact(c->fd, hdr, 8) < 0) return WOLFSSL_CBIO_ERR_GENERAL;
    c->cur_remaining = ((hdr[2] << 8) | hdr[3]) - 8;
    if (c->cur_remaining < 0) return WOLFSSL_CBIO_ERR_GENERAL;
  }
  int want = sz < c->cur_remaining ? sz : c->cur_remaining;
  int n = (int)::recv(c->fd, buf, (size_t)want, 0);
  if (n == 0) return WOLFSSL_CBIO_ERR_CONN_CLOSE;
  if (n < 0) return WOLFSSL_CBIO_ERR_GENERAL;
  c->cur_remaining -= n;
  return n;
}

void *nova_tds_tls_new(int fd) {
  nova_wolfssl_init();

  WOLFSSL_CTX *ctx = wolfSSL_CTX_new(wolfTLSv1_2_client_method());
  if (!ctx) return nullptr;
  wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_NONE, nullptr);
  wolfSSL_CTX_SetIORecv(ctx, nova_tds_io_recv);
  wolfSSL_CTX_SetIOSend(ctx, nova_tds_io_send);
  WOLFSSL *ssl = wolfSSL_new(ctx);
  if (!ssl) { wolfSSL_CTX_free(ctx); return nullptr; }

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

struct MemTlsCtx {
  WOLFSSL_CTX *ctx;
  WOLFSSL *ssl;
  std::vector<unsigned char> in;
  size_t in_pos;
  std::vector<unsigned char> out;
  bool in_closed;
  bool is_server;
};

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

static int nova_mtls_io_send(WOLFSSL *ssl, char *buf, int sz, void *p) {
  (void)ssl;
  MemTlsCtx *c = (MemTlsCtx *)p;
  c->out.insert(c->out.end(), (const unsigned char *)buf, (const unsigned char *)buf + sz);
  return sz;
}

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
    if (verify) wolfSSL_check_domain_name(ssl, (char *)hostname);
  }
  MemTlsCtx *c = new MemTlsCtx{ctx, ssl, {}, 0, {}, false, false};
  wolfSSL_SetIOReadCtx(ssl, c);
  wolfSSL_SetIOWriteCtx(ssl, c);
  return c;
}

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
  wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_NONE, nullptr);
  wolfSSL_CTX_SetIORecv(ctx, nova_mtls_io_recv);
  wolfSSL_CTX_SetIOSend(ctx, nova_mtls_io_send);
  WOLFSSL *ssl = wolfSSL_new(ctx);
  if (!ssl) { wolfSSL_CTX_free(ctx); return nullptr; }
  MemTlsCtx *c = new MemTlsCtx{ctx, ssl, {}, 0, {}, false, true};
  wolfSSL_SetIOReadCtx(ssl, c);
  wolfSSL_SetIOWriteCtx(ssl, c);
  return c;
}

int nova_mtls_handshake(void *p) {
  MemTlsCtx *c = (MemTlsCtx *)p;
  if (!c || !c->ssl) return -1;
  int r = c->is_server ? wolfSSL_accept(c->ssl) : wolfSSL_connect(c->ssl);
  if (r == WOLFSSL_SUCCESS) return 0;
  int e = wolfSSL_get_error(c->ssl, r);
  if (e == WOLFSSL_ERROR_WANT_READ || e == WOLFSSL_ERROR_WANT_WRITE) return 1;
  return -1;
}

void nova_mtls_feed(void *p, const char *data, int len) {
  MemTlsCtx *c = (MemTlsCtx *)p;
  if (!c || len <= 0) return;
  c->in.insert(c->in.end(), (const unsigned char *)data, (const unsigned char *)data + len);
}

void nova_mtls_mark_closed(void *p) { MemTlsCtx *c = (MemTlsCtx *)p; if (c) c->in_closed = true; }

int nova_mtls_pull(void *p, char *buf, int max) {
  MemTlsCtx *c = (MemTlsCtx *)p;
  if (!c || max <= 0 || c->out.empty()) return 0;
  int n = (int)c->out.size() < max ? (int)c->out.size() : max;
  std::memcpy(buf, c->out.data(), (size_t)n);
  c->out.erase(c->out.begin(), c->out.begin() + n);
  return n;
}
int nova_mtls_pending_out(void *p) { MemTlsCtx *c = (MemTlsCtx *)p; return c ? (int)c->out.size() : 0; }

int nova_mtls_write(void *p, const char *data, int len) {
  MemTlsCtx *c = (MemTlsCtx *)p;
  if (!c || !c->ssl || len <= 0) return 0;
  int r = wolfSSL_write(c->ssl, data, len);
  return r < 0 ? -1 : r;
}

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

void *nova_tds_tls_new(int fd) { (void)fd; return nullptr; }
int nova_tds_tls_handshake(void *p) { (void)p; return -1; }
int nova_tds_tls_write(void *p, const char *data, int len) { (void)p; (void)data; (void)len; return -1; }
int nova_tds_tls_read(void *p, char *buf, int max_len) { (void)p; (void)buf; (void)max_len; return -1; }
void nova_tds_tls_free(void *p) { (void)p; }

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

struct ProcessContext {
  long pid;
  int in_fd;
  int out_fd;
  int exit_code;
  bool reaped;
};

#ifndef _WIN32

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
    storage.emplace_back(cur);
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

  int in_pipe[2] = {-1, -1};
  int out_pipe[2] = {-1, -1};
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

    ::dup2(in_pipe[0], STDIN_FILENO);
    ::dup2(out_pipe[1], STDOUT_FILENO);
    ::close(in_pipe[0]); ::close(in_pipe[1]);
    ::close(out_pipe[0]); ::close(out_pipe[1]);
    std::vector<std::string> storage;
    std::vector<char *> argv = nova_build_argv(c_cmd, c_args, storage);
    ::execvp(argv[0], argv.data());
    _exit(127);
  }

  ::close(in_pipe[0]);
  ::close(out_pipe[1]);
  nova_free_cstr(cmd, c_cmd);
  nova_free_cstr(args_str, c_args);

  ProcessContext *ctx = new ProcessContext{(long)pid, in_pipe[1], out_pipe[0], 0, false};
  return ctx;
}

#if defined(__linux__)

struct IsoChildArgs {
  char **argv;
  int in_fd, out_fd;
  long ns_flags;
  const char *rootfs;
  const char *hostname;
  int drop_caps, no_new_privs, seccomp_deny;
};

static void iso_drop_caps() {
  for (int cap = 0; cap <= 63; ++cap)
    ::prctl(PR_CAPBSET_DROP, cap, 0, 0, 0);
  struct __user_cap_header_struct hdr = {_LINUX_CAPABILITY_VERSION_3, 0};
  struct __user_cap_data_struct data[2];
  std::memset(data, 0, sizeof(data));
  ::syscall(SYS_capset, &hdr, data);
}

static int iso_install_seccomp() {
#if defined(SECCOMP_SET_MODE_FILTER) && defined(AUDIT_ARCH_X86_64)
  struct sock_filter filter[] = {

    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
#define DENY(NR) \
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (NR), 0, 1), \
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
    DENY(SYS_unshare)
    DENY(SYS_setns)
    DENY(SYS_mount)
    DENY(SYS_pivot_root)
#ifdef SYS_ptrace
    DENY(SYS_ptrace)
#endif
#undef DENY
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  struct sock_fprog prog = {(unsigned short)(sizeof(filter) / sizeof(filter[0])), filter};
  return (int)::syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog);
#else
  return -1;
#endif
}

static int iso_setup_rootfs(const char *rootfs) {
  if (::mount("", "/", nullptr, MS_REC | MS_PRIVATE, nullptr) != 0) return -1;
  if (::mount(rootfs, rootfs, nullptr, MS_BIND | MS_REC, nullptr) != 0) return -1;
  if (::chdir(rootfs) != 0) return -1;
  ::mkdir(".old_root", 0700);
  if (::syscall(SYS_pivot_root, ".", ".old_root") != 0) return -1;
  if (::chdir("/") != 0) return -1;
  ::umount2("/.old_root", MNT_DETACH);
  ::rmdir("/.old_root");
  return 0;
}

static int iso_child_entry(void *arg) {
  IsoChildArgs *a = reinterpret_cast<IsoChildArgs *>(arg);
  ::dup2(a->in_fd, STDIN_FILENO);
  ::dup2(a->out_fd, STDOUT_FILENO);
  ::close(a->in_fd);
  ::close(a->out_fd);

  if ((a->ns_flags & NOVA_NS_UTS) && a->hostname && a->hostname[0])
    ::sethostname(a->hostname, std::strlen(a->hostname));

  if (a->ns_flags & NOVA_NS_MOUNT) {
    if (a->rootfs && a->rootfs[0]) {
      if (iso_setup_rootfs(a->rootfs) != 0) _exit(125);
    } else {
      ::mount("", "/", nullptr, MS_REC | MS_PRIVATE, nullptr);
    }

    if (a->ns_flags & NOVA_NS_PID)
      ::mount("proc", "/proc", "proc", 0, nullptr);
  }

  if (a->no_new_privs) ::prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
  if (a->drop_caps) iso_drop_caps();
  if (a->seccomp_deny) iso_install_seccomp();

  ::execvp(a->argv[0], a->argv);
  _exit(127);
}
#endif

ProcessContext *nova_process_spawn_isolated(const char *cmd, const char *args_str, long ns_flags,
                                            const char *rootfs, const char *hostname, int drop_caps,
                                            int no_new_privs, int seccomp_deny) {
#if defined(__linux__)
  char *c_cmd = nova_to_cstr(cmd);
  char *c_args = nova_to_cstr(args_str);
  char *c_rootfs = nova_to_cstr(rootfs);
  char *c_host = nova_to_cstr(hostname);

  int in_pipe[2] = {-1, -1}, out_pipe[2] = {-1, -1};
  if (::pipe(in_pipe) != 0 || ::pipe(out_pipe) != 0) {
    if (in_pipe[0] >= 0) { ::close(in_pipe[0]); ::close(in_pipe[1]); }
    if (out_pipe[0] >= 0) { ::close(out_pipe[0]); ::close(out_pipe[1]); }
    nova_free_cstr(cmd, c_cmd); nova_free_cstr(args_str, c_args);
    nova_free_cstr(rootfs, c_rootfs); nova_free_cstr(hostname, c_host);
    return nullptr;
  }

  static thread_local std::vector<std::string> storage;
  std::vector<char *> argv = nova_build_argv(c_cmd ? c_cmd : "", c_args, storage);

  int clone_flags = SIGCHLD;
  if (ns_flags & NOVA_NS_PID)   clone_flags |= CLONE_NEWPID;
  if (ns_flags & NOVA_NS_MOUNT) clone_flags |= CLONE_NEWNS;
  if (ns_flags & NOVA_NS_UTS)   clone_flags |= CLONE_NEWUTS;
  if (ns_flags & NOVA_NS_IPC)   clone_flags |= CLONE_NEWIPC;
  if (ns_flags & NOVA_NS_NET)   clone_flags |= CLONE_NEWNET;
  if (ns_flags & NOVA_NS_USER)  clone_flags |= CLONE_NEWUSER;

  IsoChildArgs cargs{argv.data(), in_pipe[0], out_pipe[1], ns_flags,
                     c_rootfs ? c_rootfs : "", c_host ? c_host : "",
                     drop_caps, no_new_privs, seccomp_deny};

  const size_t STACK = 1 << 20;
  void *stack = ::mmap(nullptr, STACK, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK, -1, 0);
  pid_t pid = -1;
  if (stack != MAP_FAILED)
    pid = ::clone(iso_child_entry, (char *)stack + STACK, clone_flags, &cargs);

  if (pid < 0) {
    if (stack != MAP_FAILED) ::munmap(stack, STACK);
    ::close(in_pipe[0]); ::close(in_pipe[1]); ::close(out_pipe[0]); ::close(out_pipe[1]);
    nova_free_cstr(cmd, c_cmd); nova_free_cstr(args_str, c_args);
    nova_free_cstr(rootfs, c_rootfs); nova_free_cstr(hostname, c_host);
    return nullptr;
  }

  ::close(in_pipe[0]);
  ::close(out_pipe[1]);
  nova_free_cstr(cmd, c_cmd); nova_free_cstr(args_str, c_args);
  nova_free_cstr(rootfs, c_rootfs); nova_free_cstr(hostname, c_host);

  return new ProcessContext{(long)pid, in_pipe[1], out_pipe[0], 0, false};
#else
  (void)ns_flags; (void)rootfs; (void)hostname; (void)drop_caps; (void)no_new_privs; (void)seccomp_deny;
  return nova_process_spawn(cmd, args_str);
#endif
}

int nova_process_write_stdin(ProcessContext *ctx, const char *data) {
  if (!ctx || ctx->in_fd < 0 || !data)
    return -1;
  int len = *reinterpret_cast<const int *>(data - 4);
  if (len < 0 || len > 64 * 1024 * 1024)
    len = (int)std::strlen(data);
  ssize_t n = ::write(ctx->in_fd, data, (size_t)len);
  return (int)n;
}

int nova_process_read_stdout(ProcessContext *ctx, char *buf, int max_len) {
  if (!ctx || ctx->out_fd < 0 || !buf || max_len <= 0)
    return -1;
  ssize_t n = ::read(ctx->out_fd, buf, (size_t)max_len);
  return (int)n;
}

int nova_process_wait(ProcessContext *ctx) {
  if (!ctx)
    return -1;
  if (ctx->reaped)
    return ctx->exit_code;

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
                   : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                         : -1;
  return ctx->exit_code;
}

long long nova_process_pid(ProcessContext *ctx) {
  return ctx ? (long long)ctx->pid : 0;
}

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
    return -2;
  if (r < 0)
    return -1;
  ctx->reaped = true;
  ctx->exit_code = WIFEXITED(status) ? WEXITSTATUS(status)
                   : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                         : -1;
  return ctx->exit_code;
}

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

  if (!ctx->reaped && ctx->pid > 0) {
    int status = 0;
    ::waitpid((pid_t)ctx->pid, &status, WNOHANG);
  }
  delete ctx;
}
#else

ProcessContext *nova_process_spawn(const char *cmd, const char *args_str) {
  (void)cmd; (void)args_str; return nullptr;
}
ProcessContext *nova_process_spawn_isolated(const char *cmd, const char *args_str, long ns_flags,
                                            const char *rootfs, const char *hostname, int drop_caps,
                                            int no_new_privs, int seccomp_deny) {
  (void)cmd; (void)args_str; (void)ns_flags; (void)rootfs; (void)hostname;
  (void)drop_caps; (void)no_new_privs; (void)seccomp_deny; return nullptr;
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

}
