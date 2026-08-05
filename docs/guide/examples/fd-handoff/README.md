# Fire-and-forget proxy prototype: fd-passing connection handoff

This is a prototype of a proxy design where the proxy gets **out of the response path**. Instead of
reading the request, dialling a backend, and shuttling every byte both ways (the shape `proxyd` uses
today), the proxy hands the client's **socket** to the app process, and the app writes the response
straight to the client. The proxy never sees the response.

It works by passing the open file descriptor over a connected `AF_UNIX` socket using `SCM_RIGHTS`,
the standard POSIX mechanism for handing a descriptor to another process. The kernel duplicates the
descriptor into the receiving process, so the app ends up with a working socket to the original
client.

## The two roles

- `router.nova` (the proxy role) binds a TCP port and a named `AF_UNIX` rendezvous socket, waits for
  the workers to connect, then accepts TCP clients. For each client it reads the request prefix (as an
  L7 proxy would, to route on it), then passes the client fd plus that prefix to a worker and closes
  its own copy. With `WORKERS=2` it round-robins across two workers, the proxy to N replicas shape.
- `worker.nova` (the app role) connects to the rendezvous socket and loops receiving handed-off client
  sockets. For each one it writes an HTTP response directly to the client and closes it.

## Run it

```sh
./run.sh
```

You will see the six requests alternate between `app-A` and `app-B`, each with its own request
counter, proving the router round-robined the handoff and each app served its own connections
directly.

## What it demonstrates and what it does not

It demonstrates the handoff **mechanic** end to end: a client socket accepted in one process is
served by another process, load-balanced across workers, with the router out of the data path. It is
a **synchronous, blocking** prototype, so its request rate is not a throughput comparison against the
reactor path.

The runtime primitive it is built on is small and general: `nova_send_fd` / `nova_recv_fd` in the C++
runtime (they build the `msghdr` / `cmsghdr` ancillary block, which is why they are C shims rather
than raw FFI), surfaced in Nova as `os.socket.sendFd` / `os.socket.recvFd` plus the `AF_UNIX`
helpers (`newUnix`, `unixPair`, `makeSockaddrUn`). POSIX only for now: Windows fd-passing needs
`WSADuplicateSocket` and a different protocol.

## The same handoff wired into the real proxyd + web app

`router.nova` / `worker.nova` are the minimal illustration. The real thing is now wired into the
production pieces and is exercised by `run-proxyd.sh`:

- **proxyd** gains a handoff mode: set `NOVA_HANDOFF_SOCK` and it binds a TCP front port plus that
  `AF_UNIX` rendezvous, and hands each accepted client socket to a backend app round-robin instead of
  forwarding bytes (`proxy.serveHandoffOnReactor`). It does not parse HTTP or copy responses, so this
  is effectively an L4 accept-and-pass. The keep-alive backend pool is not used in this mode (the proxy
  holds no backend TCP connections at all).
- **the web app** gains a handoff receiver: set `NOVA_HANDOFF_SOCK` and `app.run` connects to the
  rendezvous and serves the sockets proxyd hands it, on its reactor, with the identical request
  pipeline (`reactorHandoffBody` + the reactor's new `OP_RECVFD` op).

Run it:

```sh
./run-proxyd.sh
```

### Measured (single 8-core dev box, load generator co-resident)

Head-to-head, one app, identical work, only the proxy differs:

| Proxy mode | req/s | p50 | p99 |
|---|---|---|---|
| fd-handoff (out of path) | 47,941 | 0.63 ms | 1.39 ms |
| classic byte-copy L7     | 39,028 | 0.77 ms | 1.61 ms |

That is **+23% throughput with lower latency at both p50 and p99**, purely from removing the proxy from
the response path. With two apps behind the handoff proxy the stack sustained **62,685 req/s at 100%
success** (c=64, all requests served, zero proxy errors); POST writes ran at 48,532 req/s, all `200`.

### The trade-offs

The proxy no longer sees responses, so **edge gzip, response-header rewriting, response buffering**
(which actually lowers the tail latency in the classic path), and **per-request load balancing across a
keep-alive connection** all move to the app or are given up. Selection is per-connection round-robin,
not path-based. And it is a **same-host** technique (fd-passing cannot cross a kernel), which fits the
common orchd topology where `proxyd` and the app replicas are co-resident on a node. On Linux it runs
on the epoll backend; io_uring and Windows do not support the handoff op (they degrade to "no handoff").
