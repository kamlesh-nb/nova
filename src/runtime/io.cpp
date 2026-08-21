
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
#include <mswsock.h> // WSAID_CONNECTEX / LPFN_CONNECTEX, for nova_wsa_connectex below
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
#include <sys/stat.h> // mkdir — pulled in transitively on macOS, but NOT on Linux (iso_setup_rootfs)
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

enum NovaIsoNs
{
  NOVA_NS_PID = 1,
  NOVA_NS_MOUNT = 2,
  NOVA_NS_UTS = 4,
  NOVA_NS_IPC = 8,
  NOVA_NS_NET = 16,
  NOVA_NS_USER = 32,
};

extern "C"
{

  // File and directory I/O (nova_file_*/nova_dir_*) was retired in M5: it now lives in Nova over
  // the raw POSIX syscalls in os/sys (src/std/io/file.nova, src/std/io/dir.nova). The blocking socket
  // layer moved to Nova over os/socket (M14.2); what remains here is process spawn. TLS is pure Nova.

  // Length of a Nova string (its 4-byte header at s-4). Shared with compress.cpp in the unity build.
  namespace
  {
    inline int nova_str_len(const char *s)
    {
      return s ? *reinterpret_cast<const int *>(s - 4) : 0;
    }
  }

  struct ProcessContext
  {
    long pid;
    int in_fd;
    int out_fd;
    int exit_code;
    bool reaped;
  };

#ifndef _WIN32

  static std::vector<char *> nova_build_argv(const char *cmd, const char *args_str,
                                             std::vector<std::string> &storage)
  {
    storage.clear();
    storage.emplace_back(cmd ? cmd : "");
    if (args_str && *args_str)
    {
      std::string cur;
      for (const char *p = args_str; *p; ++p)
      {
        if (*p == '\n')
        {
          storage.emplace_back(cur);
          cur.clear();
        }
        else
        {
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

  ProcessContext *nova_process_spawn(const char *cmd, const char *args_str)
  {
    char *c_cmd = nova_to_cstr(cmd);
    char *c_args = nova_to_cstr(args_str);

    int in_pipe[2] = {-1, -1};
    int out_pipe[2] = {-1, -1};
    if (::pipe(in_pipe) != 0 || ::pipe(out_pipe) != 0)
    {
      if (in_pipe[0] >= 0)
        ::close(in_pipe[0]);
      if (in_pipe[1] >= 0)
        ::close(in_pipe[1]);
      if (out_pipe[0] >= 0)
        ::close(out_pipe[0]);
      if (out_pipe[1] >= 0)
        ::close(out_pipe[1]);
      nova_free_cstr(cmd, c_cmd);
      nova_free_cstr(args_str, c_args);
      return nullptr;
    }

    pid_t pid = ::fork();
    if (pid < 0)
    {
      ::close(in_pipe[0]);
      ::close(in_pipe[1]);
      ::close(out_pipe[0]);
      ::close(out_pipe[1]);
      nova_free_cstr(cmd, c_cmd);
      nova_free_cstr(args_str, c_args);
      return nullptr;
    }

    if (pid == 0)
    {

      ::dup2(in_pipe[0], STDIN_FILENO);
      ::dup2(out_pipe[1], STDOUT_FILENO);
      ::close(in_pipe[0]);
      ::close(in_pipe[1]);
      ::close(out_pipe[0]);
      ::close(out_pipe[1]);
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

  struct IsoChildArgs
  {
    char **argv;
    int in_fd, out_fd;
    long ns_flags;
    const char *rootfs;
    const char *hostname;
    int drop_caps, no_new_privs, seccomp_deny;
  };

  static void iso_drop_caps()
  {
    for (int cap = 0; cap <= 63; ++cap)
      ::prctl(PR_CAPBSET_DROP, cap, 0, 0, 0);
    struct __user_cap_header_struct hdr = {_LINUX_CAPABILITY_VERSION_3, 0};
    struct __user_cap_data_struct data[2];
    std::memset(data, 0, sizeof(data));
    ::syscall(SYS_capset, &hdr, data);
  }

  static int iso_install_seccomp()
  {
#if defined(SECCOMP_SET_MODE_FILTER) && defined(AUDIT_ARCH_X86_64)
    struct sock_filter filter[] = {

        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
#define DENY(NR)                                   \
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

  static int iso_setup_rootfs(const char *rootfs)
  {
    if (::mount("", "/", nullptr, MS_REC | MS_PRIVATE, nullptr) != 0)
      return -1;
    if (::mount(rootfs, rootfs, nullptr, MS_BIND | MS_REC, nullptr) != 0)
      return -1;
    if (::chdir(rootfs) != 0)
      return -1;
    ::mkdir(".old_root", 0700);
    if (::syscall(SYS_pivot_root, ".", ".old_root") != 0)
      return -1;
    if (::chdir("/") != 0)
      return -1;
    ::umount2("/.old_root", MNT_DETACH);
    ::rmdir("/.old_root");
    return 0;
  }

  static int iso_child_entry(void *arg)
  {
    IsoChildArgs *a = reinterpret_cast<IsoChildArgs *>(arg);
    ::dup2(a->in_fd, STDIN_FILENO);
    ::dup2(a->out_fd, STDOUT_FILENO);
    ::close(a->in_fd);
    ::close(a->out_fd);

    if ((a->ns_flags & NOVA_NS_UTS) && a->hostname && a->hostname[0])
      ::sethostname(a->hostname, std::strlen(a->hostname));

    if (a->ns_flags & NOVA_NS_MOUNT)
    {
      if (a->rootfs && a->rootfs[0])
      {
        if (iso_setup_rootfs(a->rootfs) != 0)
          _exit(125);
      }
      else
      {
        ::mount("", "/", nullptr, MS_REC | MS_PRIVATE, nullptr);
      }

      if (a->ns_flags & NOVA_NS_PID)
        ::mount("proc", "/proc", "proc", 0, nullptr);
    }

    if (a->no_new_privs)
      ::prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    if (a->drop_caps)
      iso_drop_caps();
    if (a->seccomp_deny)
      iso_install_seccomp();

    ::execvp(a->argv[0], a->argv);
    _exit(127);
  }
#endif

  ProcessContext *nova_process_spawn_isolated(const char *cmd, const char *args_str, long ns_flags,
                                              const char *rootfs, const char *hostname, int drop_caps,
                                              int no_new_privs, int seccomp_deny)
  {
#if defined(__linux__)
    char *c_cmd = nova_to_cstr(cmd);
    char *c_args = nova_to_cstr(args_str);
    char *c_rootfs = nova_to_cstr(rootfs);
    char *c_host = nova_to_cstr(hostname);

    int in_pipe[2] = {-1, -1}, out_pipe[2] = {-1, -1};
    if (::pipe(in_pipe) != 0 || ::pipe(out_pipe) != 0)
    {
      if (in_pipe[0] >= 0)
      {
        ::close(in_pipe[0]);
        ::close(in_pipe[1]);
      }
      if (out_pipe[0] >= 0)
      {
        ::close(out_pipe[0]);
        ::close(out_pipe[1]);
      }
      nova_free_cstr(cmd, c_cmd);
      nova_free_cstr(args_str, c_args);
      nova_free_cstr(rootfs, c_rootfs);
      nova_free_cstr(hostname, c_host);
      return nullptr;
    }

    static thread_local std::vector<std::string> storage;
    std::vector<char *> argv = nova_build_argv(c_cmd ? c_cmd : "", c_args, storage);

    int clone_flags = SIGCHLD;
    if (ns_flags & NOVA_NS_PID)
      clone_flags |= CLONE_NEWPID;
    if (ns_flags & NOVA_NS_MOUNT)
      clone_flags |= CLONE_NEWNS;
    if (ns_flags & NOVA_NS_UTS)
      clone_flags |= CLONE_NEWUTS;
    if (ns_flags & NOVA_NS_IPC)
      clone_flags |= CLONE_NEWIPC;
    if (ns_flags & NOVA_NS_NET)
      clone_flags |= CLONE_NEWNET;
    if (ns_flags & NOVA_NS_USER)
      clone_flags |= CLONE_NEWUSER;

    IsoChildArgs cargs{argv.data(), in_pipe[0], out_pipe[1], ns_flags,
                       c_rootfs ? c_rootfs : "", c_host ? c_host : "",
                       drop_caps, no_new_privs, seccomp_deny};

    const size_t STACK = 1 << 20;
    void *stack = ::mmap(nullptr, STACK, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK, -1, 0);
    pid_t pid = -1;
    if (stack != MAP_FAILED)
      pid = ::clone(iso_child_entry, (char *)stack + STACK, clone_flags, &cargs);

    if (pid < 0)
    {
      if (stack != MAP_FAILED)
        ::munmap(stack, STACK);
      ::close(in_pipe[0]);
      ::close(in_pipe[1]);
      ::close(out_pipe[0]);
      ::close(out_pipe[1]);
      nova_free_cstr(cmd, c_cmd);
      nova_free_cstr(args_str, c_args);
      nova_free_cstr(rootfs, c_rootfs);
      nova_free_cstr(hostname, c_host);
      return nullptr;
    }

    ::close(in_pipe[0]);
    ::close(out_pipe[1]);
    nova_free_cstr(cmd, c_cmd);
    nova_free_cstr(args_str, c_args);
    nova_free_cstr(rootfs, c_rootfs);
    nova_free_cstr(hostname, c_host);

    return new ProcessContext{(long)pid, in_pipe[1], out_pipe[0], 0, false};
#else
    (void)ns_flags;
    (void)rootfs;
    (void)hostname;
    (void)drop_caps;
    (void)no_new_privs;
    (void)seccomp_deny;
    return nova_process_spawn(cmd, args_str);
#endif
  }

  int nova_process_write_stdin(ProcessContext *ctx, const char *data)
  {
    if (!ctx || ctx->in_fd < 0 || !data)
      return -1;
    int len = *reinterpret_cast<const int *>(data - 4);
    if (len < 0 || len > 64 * 1024 * 1024)
      len = (int)std::strlen(data);
    ssize_t n = ::write(ctx->in_fd, data, (size_t)len);
    return (int)n;
  }

  int nova_process_read_stdout(ProcessContext *ctx, char *buf, int max_len)
  {
    if (!ctx || ctx->out_fd < 0 || !buf || max_len <= 0)
      return -1;
    ssize_t n = ::read(ctx->out_fd, buf, (size_t)max_len);
    return (int)n;
  }

  int nova_process_wait(ProcessContext *ctx)
  {
    if (!ctx)
      return -1;
    if (ctx->reaped)
      return ctx->exit_code;

    if (ctx->in_fd >= 0)
    {
      ::close(ctx->in_fd);
      ctx->in_fd = -1;
    }
    int status = 0;
    pid_t r;
    do
    {
      r = ::waitpid((pid_t)ctx->pid, &status, 0);
    } while (r < 0 && errno == EINTR);
    if (r < 0)
      return -1;
    ctx->reaped = true;
    ctx->exit_code = WIFEXITED(status)     ? WEXITSTATUS(status)
                     : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                           : -1;
    return ctx->exit_code;
  }

  long long nova_process_pid(ProcessContext *ctx)
  {
    return ctx ? (long long)ctx->pid : 0;
  }

  int nova_process_try_wait(ProcessContext *ctx)
  {
    if (!ctx)
      return -1;
    if (ctx->reaped)
      return ctx->exit_code;
    if (ctx->pid <= 0)
      return -1;
    int status = 0;
    pid_t r;
    do
    {
      r = ::waitpid((pid_t)ctx->pid, &status, WNOHANG);
    } while (r < 0 && errno == EINTR);
    if (r == 0)
      return -2;
    if (r < 0)
      return -1;
    ctx->reaped = true;
    ctx->exit_code = WIFEXITED(status)     ? WEXITSTATUS(status)
                     : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                           : -1;
    return ctx->exit_code;
  }

  int nova_process_kill(ProcessContext *ctx, int sig)
  {
    if (!ctx || ctx->pid <= 0)
      return -1;
    return ::kill((pid_t)ctx->pid, sig) == 0 ? 0 : -1;
  }

  void nova_process_free(ProcessContext *ctx)
  {
    if (!ctx)
      return;
    if (ctx->in_fd >= 0)
      ::close(ctx->in_fd);
    if (ctx->out_fd >= 0)
      ::close(ctx->out_fd);

    if (!ctx->reaped && ctx->pid > 0)
    {
      int status = 0;
      ::waitpid((pid_t)ctx->pid, &status, WNOHANG);
    }
    delete ctx;
  }
#else

  ProcessContext *nova_process_spawn(const char *cmd, const char *args_str)
  {
    (void)cmd;
    (void)args_str;
    return nullptr;
  }
  ProcessContext *nova_process_spawn_isolated(const char *cmd, const char *args_str, long ns_flags,
                                              const char *rootfs, const char *hostname, int drop_caps,
                                              int no_new_privs, int seccomp_deny)
  {
    (void)cmd;
    (void)args_str;
    (void)ns_flags;
    (void)rootfs;
    (void)hostname;
    (void)drop_caps;
    (void)no_new_privs;
    (void)seccomp_deny;
    return nullptr;
  }
  int nova_process_write_stdin(ProcessContext *ctx, const char *data)
  {
    (void)ctx;
    (void)data;
    return -1;
  }
  int nova_process_read_stdout(ProcessContext *ctx, char *buf, int max_len)
  {
    (void)ctx;
    (void)buf;
    (void)max_len;
    return -1;
  }
  int nova_process_wait(ProcessContext *ctx)
  {
    (void)ctx;
    return -1;
  }
  long long nova_process_pid(ProcessContext *ctx)
  {
    (void)ctx;
    return 0;
  }
  int nova_process_try_wait(ProcessContext *ctx)
  {
    (void)ctx;
    return -1;
  }
  int nova_process_kill(ProcessContext *ctx, int sig)
  {
    (void)ctx;
    (void)sig;
    return -1;
  }
  void nova_process_free(ProcessContext *ctx) { (void)ctx; }
#endif
  WatcherContext *nova_fs_watcher_create(const char *path)
  {
    (void)path;
    return nullptr;
  }
  const char *nova_fs_watcher_next_event(WatcherContext *ctx)
  {
    (void)ctx;
    return nullptr;
  }
  void nova_fs_watcher_free_event(const char *ptr) { (void)ptr; }
  void nova_fs_watcher_close(WatcherContext *ctx) { (void)ctx; }

#ifdef _WIN32
  // Overlapped connect for the IOCP reactor.
  //
  // This is the ONE piece of the Windows port that cannot be a Nova `extern("c")` binding, and the
  // reason is Winsock's own design rather than a preference: AcceptEx is a real export of mswsock.lib
  // and so binds by name, but ConnectEx is deliberately NOT exported — it is only reachable by asking
  // a socket for its address at runtime via WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER). Nova's FFI
  // binds named symbols and has no way to call a pointer obtained at runtime, so the WSAIoctl + the
  // indirect call are done here and exposed under a stable name that Nova CAN bind.
  //
  // The pointer is per-provider, not per-socket, so one resolution serves the process; the socket
  // argument to WSAIoctl is only used to pick the provider. Returns 0 when the connect is under way
  // (inline or pending — either way the completion lands on the port), -1 otherwise.
  int nova_wsa_connectex(long long s, void *addr, int addrlen, void *overlapped)
  {
    static LPFN_CONNECTEX fn = nullptr;
    if (!fn)
    {
      GUID guid = WSAID_CONNECTEX;
      DWORD got = 0;
      if (::WSAIoctl((SOCKET)s, SIO_GET_EXTENSION_FUNCTION_POINTER, &guid, sizeof(guid), &fn,
                     sizeof(fn), &got, nullptr, nullptr) == SOCKET_ERROR)
      {
        return -1;
      }
    }
    // ConnectEx requires an explicitly BOUND socket, unlike connect(). Binding to the wildcard
    // address/port is what connect() does implicitly; a socket that is already bound just fails here
    // harmlessly, so this needs no "have I bound it" bookkeeping.
    struct sockaddr_in any;
    std::memset(&any, 0, sizeof(any));
    any.sin_family = AF_INET;
    any.sin_addr.s_addr = INADDR_ANY;
    any.sin_port = 0;
    ::bind((SOCKET)s, (struct sockaddr *)&any, (int)sizeof(any));

    BOOL ok = fn((SOCKET)s, (const struct sockaddr *)addr, addrlen, nullptr, 0, nullptr,
                 (LPOVERLAPPED)overlapped);
    if (ok)
      return 0;
    return (::WSAGetLastError() == WSA_IO_PENDING) ? 0 : -1;
  }
#endif
}
