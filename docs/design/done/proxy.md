# Building a High-Performance L4 Proxy in Kyte — Control/Data-Plane Split

**Status:** design note (not scheduled — captured for reference).
**Date:** 2026-07-19.
**Question it answers:** *Can Kyte build an HAProxy-class proxy with load-balancing + PID auto-scaling,
and how should it be structured?*

---

## 1. Verdict

**Yes — provided the L4 data path lives in the C++ runtime, not in Kyte.** This is not a workaround; it
is the correct **control-plane / data-plane split** that every serious proxy uses (Envoy, Pingora,
HAProxy internally). It plays each layer to its strength:

- **Data plane (bytes) → C++ runtime.** Pure byte-forwarding at wire speed, with kernel zero-copy. No
  ARC, no Kyte heap object ever touches a payload byte.
- **Control plane (logic) → Kyte.** Backend selection policy, health, config, and the PID auto-scaler —
  all low-frequency, exactly where a safe high-level language belongs.

This split **removes the two structural concerns** that otherwise keep a managed language below HAProxy
on L4:

| Concern (if L4 were in Kyte) | Resolved by the split |
|---|---|
| ARC retain/release on the hot path | The hot path never enters managed code — nothing to refcount. |
| No zero-copy (`splice`/`sendfile`/`io_uring`) | The data plane is C++, so kernel zero-copy is available. |

The remaining gap is **maturity**, not capability (see §9).

---

## 2. Core principle

> **The payload path is mechanism (C++). The routing decision is policy (Kyte). They meet at a
> lock-free snapshot, never on the per-byte path.**

Kyte computes *what the policy is*. The runtime *executes* it. A byte being proxied crosses zero
language boundaries; a policy change crosses exactly one (an atomic pointer swap).

---

## 3. Architecture

```
            ┌──────────────────────────── Kyte (control plane) ────────────────────────────┐
            │                                                                               │
            │   Backend registry ──► LB policy      Health checker      PID auto-scaler      │
            │   (addr, weight,        (round-robin,  (async probes,      (target metric →    │
            │    healthy, conns)       least-conn,    mark up/down)       desired capacity)   │
            │        │                 hash, p2c)         │                    │             │
            │        └──────────────┬──────────────────────┴────────────────────┘            │
            │                       ▼                                                         │
            │              build immutable SNAPSHOT  ──►  kyte_l4_policy_publish()            │
            └───────────────────────────────────────────────│─────────────────────────────┘
                                                             │  atomic ptr swap (RCU)
            ┌────────────────────────────────────────────────▼────────────────────────────┐
            │                        C++ runtime (data plane)                               │
            │                                                                               │
            │   Asio io_context (epoll/kqueue) · N threads · per-connection strand          │
            │                                                                               │
            │   accept ─► read snapshot (lockless) ─► pick backend ─► connect ─►            │
            │              splice(client_fd ⇄ backend_fd)  [zero-copy, no ARC]  ─► close    │
            └───────────────────────────────────────────────────────────────────────────────┘
```

Everything below the swap line is C++ that already largely exists (`concurrency.cpp` has the Asio
io_context, multi-threaded pool, and per-socket strands). Everything above it is ordinary Kyte.

---

## 4. Data plane — a C++ runtime primitive

The L4 forwarder is added to the runtime in the same style as the existing `kyte_socket_*` primitives.
It is the only new C++ of substance.

### Responsibilities
- Accept connections on the io_context (async, across the thread pool).
- Read the current policy **snapshot** locklessly and select a backend (or invoke a per-connection Kyte
  callback — see §6).
- Connect to the backend; **splice bytes bidirectionally** until either side closes.
- Track per-connection/backend counters (active conns, bytes) for the control plane to read.

### Zero-copy options (in preference order)
1. **`splice()`** (Linux) — kernel pipe between the two sockets; payload never enters userspace.
2. **`io_uring`** — batched, lowest syscall overhead; best throughput, more code.
3. **`sendfile`** — narrower applicability.
4. **Userspace copy** via a pooled `bytes` buffer — the portable fallback (macOS/dev); still fine,
   just not zero-copy.

Because this is runtime C++, all four are on the table. **No FFI is needed** — extending the runtime is
always C++; FFI is only for *user* Kyte code binding external C.

### Proposed runtime ABI (called from Kyte by name, like every `kyte_*` primitive)
```c
// Listener / server lifecycle.
long long kyte_l4_listen(const char *bind_addr, int port);      // -> listener handle, or -1
void      kyte_l4_serve(long long listener, long long policy);   // async accept loop on the io_context

// Policy handle: holds an atomically-swappable pointer to the current snapshot.
long long kyte_l4_policy_new(void);                              // -> policy handle
void      kyte_l4_policy_publish(long long policy,               // atomic swap-in a new snapshot;
                                 long long snapshot_ptr, int n);  //   old one retired after a grace period

// Telemetry the control plane reads (per backend index).
long long kyte_l4_active_conns(long long policy, int backend_idx);
long long kyte_l4_total_bytes(long long policy, int backend_idx);
```

### No ARC on the byte path — the rule
The splice loop uses raw fds and (if a userspace fallback) raw `bytes.alloc` buffers pooled and reused.
It must **never** allocate or refcount a Kyte heap object per connection or per read. ARC is for the
control plane's data structures only.

---

## 5. Control plane — Kyte

Low-frequency, expressive, safe. This is the part that is genuinely "written in Kyte."

### 5.1 Backend registry & LB policy
A plain Kyte structure the control plane owns and mutates:
```
struct Backend { pub addr: string; pub port: int; pub weight: int; pub healthy: bool; }
```
Load-balancing algorithms are pure compute (structs + maps + math) — all straightforward in Kyte:
- **Round-robin** / **weighted round-robin**
- **Least-connections** (reads `kyte_l4_active_conns`)
- **Power-of-two-choices (P2C)** — pick 2 at random, take the less loaded; near-optimal, cheap
- **Consistent hashing** (ketama / maglev) for session stickiness
- **Latency-aware / EWMA** using the telemetry counters

The algorithm runs either (a) once, to *rank* backends into the snapshot the C++ side selects from, or
(b) per-connection via a callback (§6). Prefer (a) for throughput.

### 5.2 Health checks
Async probes (TCP connect / HTTP GET) on the existing Asio runtime — Kyte `async fn` + timers. Mark
`healthy` up/down; a state change triggers a new snapshot publish. This is exactly the kind of periodic
async logic the runtime already supports.

### 5.3 PID auto-scaler
A textbook discrete PID controller — a handful of floats and a timer loop. Kyte has `f64`/`decimal`,
`math`, and Asio timers, so this is trivial and a genuinely nice fit.

**Loop (every `dt`):**
```
error      = setpoint - measured            // e.g. target p99 latency, target conns/backend, target CPU%
integral   = clamp(integral + error * dt,   // anti-windup: clamp the accumulator
                   i_min, i_max)
derivative = (error - prev_error) / dt       // optionally low-pass filtered
output     = Kp*error + Ki*integral + Kd*derivative
output     = clamp(output, out_min, out_max) // e.g. desired backend count / connection limit
prev_error = error
```

**Actuation** (the "auto-scaling"):
- **In-process:** adjust backend weights / connection caps → just republish the snapshot. Instant, trivial.
- **Process-level:** spin backends up/down via `kyte_process_spawn` (exists).
- **Orchestrator:** call a k8s / cloud API — Kyte has HTTP client + JSON + TLS (wolfSSL).

Anti-windup, derivative filtering, and setpoint choice are algorithmic and language-agnostic.

### 5.4 Config
Parse + hot-reload config in Kyte (JSON/YAML both present in stdlib). A reload rebuilds the registry and
publishes a new snapshot — the data plane picks it up on the next connection without a restart.

---

## 6. The seam — lock-free policy snapshot

This is the one genuinely interesting piece of design. The C++ data plane must read the policy on the
io_context threads **without a lock and without a managed call per byte**.

### Snapshot = a plain, non-ARC buffer
Kyte builds an immutable array of `{addr, port, weight, healthy, rank}` in a raw `bytes` buffer (not ARC
objects), then hands its pointer to `kyte_l4_policy_publish`.

### Publish = atomic pointer swap (RCU-style)
```
    Kyte: build new snapshot ──► kyte_l4_policy_publish(policy, ptr, n)
    C++:  old = atomic_exchange(policy.current, new)      // readers see old-or-new, never torn
          defer_free(old)                                 // freed after a grace period (no reader holds it)
```
Readers on the data plane do a single relaxed/acquire atomic load of `policy.current` per connection —
no lock, no contention. Writers are rare (config/health/PID changes), so the swap cost is irrelevant.

### Selection: two models
1. **C++ selects from the snapshot (recommended for throughput).** Kyte ranks backends into the
   snapshot; C++ does the final pick (round-robin index, P2C, hash) from the plain array. **Zero Kyte
   calls on the connection path.**
2. **Kyte callback per connection.** C++ calls a Kyte function returning a backend index. One managed
   call per *connection* (not per byte) — thousands/sec is negligible — if you want the full algorithm
   in Kyte. Costs a boundary crossing per connection; fine for most workloads, avoid for extreme conn
   rates.

Start with model 1; drop to model 2 only where the policy is too dynamic to precompute.

---

## 7. Why this reaches the performance target

- **Native codegen (LLVM), no GC** — deterministic dealloc, no pause-induced tail latency. Kyte is in
  the C/C++/Rust tier, not Go/Java.
- **Hot path is C++ + Asio + kernel zero-copy** — the same substrate high-end C++ proxies use. Kyte
  never touches a payload byte, so ARC cost on that path is *zero by construction*.
- **Control plane is cheap** — runs per-connection at most, usually periodic; ARC overhead there is
  irrelevant.

The realistic ceiling is **Pingora-class** (Cloudflare's Rust proxy that replaced nginx): a modern
native language + async runtime + manual memory where it counts. Kyte's model is analogous.

---

## 8. Prerequisites & gaps

| Item | Why it's needed | State / effort |
|---|---|---|
| **Binary-safe socket send** | `kyte_socket_send` uses `strlen` → truncates at the first null byte. A proxy moves arbitrary bytes. | Add `kyte_socket_send_n(fd, ptr, len)`. ~½ day. **Hard prerequisite.** |
| **Async socket path exposed** | The data plane needs async accept/read/write on the io_context, not the blocking `kyte_socket_*`. Confirm/expose the Asio path to the L4 primitive. | Verify; likely wiring, not new architecture. |
| **`kyte_l4_*` runtime primitive** | The splice loop + policy handle (§4). | New runtime C++, moderate. |
| **Zero-copy (`splice`/`io_uring`)** | L4 throughput parity with HAProxy. | Runtime C++; incremental (userspace-copy fallback works first). |
| **Snapshot RCU publish** | The lock-free seam (§6). | Standard but real; the interesting design bit. |
| **Proxy machinery** | Graceful reload, conn draining, backpressure, timeouts, PROXY protocol, stats socket. | All incremental; none hard. |

---

## 9. L4 vs L7 — a spectrum, not a binary

The "keep it in C++" move is cleanest for **L4 / pure passthrough**, where the proxy never looks at the
payload. The moment you move to **L7** (HTTP routing, header rewrite, TLS termination with inspection),
the bytes must reach logic:

- **Terminate + inspect in C++, route via Kyte policy** — parse headers in the runtime, cross to Kyte
  only for the routing decision (per request, not per byte). Keeps most of the cost in C++.
- **Hand the request to Kyte** — full flexibility (write handlers in Kyte), pay the managed cost per
  request. Fine for moderate rates; this is where Kyte's web stack (`web/`) already lives.

How much sits in C++ vs Kyte is a **per-feature tradeoff**, decided by that feature's request rate and
how much logic it needs. L4 = all-mechanism-in-C++; a rich L7 gateway = more-in-Kyte.

---

## 10. Honest caveats

- **The L4 data plane is C++, not Kyte.** "Written in Kyte" applies to the control plane. Normal for
  proxies (Envoy's data plane is C++), but it reframes the story: **Kyte orchestrates a C++ data
  plane** for L4.
- **Maturity is the real risk.** Kyte's ARC foundation was stabilized recently; the compiler is
  Alpha/Beta. A proxy — long-running, million-connection, adversarial input — is exactly the workload
  that surfaces latent compiler/runtime bugs. The control plane is where Kyte code runs continuously;
  it needs soak testing. Nothing is *architecturally* blocking, but *capable ≠ proven at scale*.
- **Seam discipline.** The no-ARC-on-the-byte-path and lock-free-publish rules are invariants a
  reviewer must enforce; the language won't stop you from accidentally allocating on the hot path.
- **Threading.** Data-plane work runs on io_context threads under strands; control-plane updates must
  publish safely (the RCU swap) — don't share ARC objects across that boundary.

---

## 11. Phased build sketch (illustrative — not a roadmap commitment)

1. **Prereq:** binary-safe socket send; confirm the async socket path.
2. **Data plane v0:** `kyte_l4_listen`/`kyte_l4_serve` with a *userspace-copy* splice loop (portable),
   static single backend. Prove end-to-end forwarding.
3. **Policy seam:** `kyte_l4_policy_new`/`publish` + the RCU snapshot; C++-side round-robin selection.
4. **Control plane:** Kyte backend registry + LB algorithms (RR → least-conn → P2C) building snapshots.
5. **Health checks:** async probes → snapshot republish on state change.
6. **PID auto-scaler:** the control loop + in-process weight actuation, then process/orchestrator.
7. **Zero-copy:** swap the userspace loop for `splice()` / `io_uring` on Linux.
8. **Hardening:** draining, backpressure, timeouts, stats socket, config hot-reload.

Each phase is independently testable; steps 2–3 are the ones that prove the architecture.

---

## References
- Control/data-plane split & xDS-style policy push: Envoy.
- Native-language async proxy replacing nginx: Cloudflare **Pingora** (Rust).
- Kyte substrate: `src/runtime/concurrency.cpp` (Asio io_context, strands), `src/std/net/tcp/*`
  (socket/client/server), `foundation-pending.md` (foundation is safe to build on),
  `feature-roadmap.md` (Tier 1 runtime is done; binary socket-send is the shared prerequisite).
