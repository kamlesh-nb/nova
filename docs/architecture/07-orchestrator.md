# The Orchestrator, Architecture

`nova-orchestrator` is a native, container free orchestration stack written **in Nova**. It is a
Kubernetes style control plane that runs workloads as **native binaries, and not containers**. It is an
*application* built upon the Nova language and runtime, and it is therefore **not** a part of the standard
library; it ships as a separate published package (`github.com/kamlesh-nb/nova-orchestrator`), fetched via
`nova get`, in the same manner as the database drivers. Only the runtime *seams* upon which it depends
reside in the language.

> This document is a navigable overview of the package. It complements the Nova language architecture set;
> the orchestrator's own repository carries its README and tests (gates 167 and 178 to 183).

## The Tiers (I1 to I4)

The stack was built in four tiers, and each tier corresponds to a module or two.

| Tier | Module(s) | What it provides |
|------|-----------|------------------|
| **I1** | `net/proxy`, `net/autoscale` | An L7 reverse proxy and load balancer, and a PID driven backend autoscaler. |
| **I2** | `orch/spec`, `orch/supervisor`, `orch/nativelet`, `orch/isolation`, `orch/autoscaler` | The native "k8s" control plane: a reconcile loop node agent, replica supervision, cgroups limits, and workload autoscaling. |
| **I3** | `net/service` | Kubernetes Service style virtual endpoints (VIPs) over the I1 proxy. |
| **I4** | `os/sandbox` | Container grade isolation via native kernel primitives (namespaces, private rootfs, dropped capabilities, seccomp). |

## The Data Path, `net/proxy`

`net/proxy` is an L7 reverse proxy on the async runtime. Its heart is the `Pool`, a set of `Backend`
entries with a pluggable load balancing strategy (`LbStrategy`: round robin, weighted, least connections,
or consistent hash). All the strategies are lock free under the share nothing model, since each reactor
advances its own per-reactor cursor and reads its own per-reactor in flight counts. The pool maintains a
**HAProxy style per-reactor connection pool** (a backend connection is reused only by the reactor that owns
it, hence no lock is required), and it is **share nothing multi core** by way of the runtime's SO_REUSEPORT
accept fan out (please see [03-runtime.md](03-runtime.md)).

The pool also performs **active health checking**: it probes each backend (a TCP connect, or an HTTP GET of
a configured path), and applies rise and fall hysteresis, so that a backend is drained out of every
strategy after a run of failed probes, and returned to rotation only after a run of successful ones.
`Proxy.run` holds all reactors alive and then serves the front port for the lifetime of the process.

## Autoscaling, `net/autoscale`

`net/autoscale` provides a general `PidController` (with anti windup, output and integral clamping, and
direct or reverse acting modes), and a proxy autoscaler built upon it. The autoscaler reads a live in
flight metric from the proxy, drives the controller, and thereby spawns or kills backend processes (through
the R1 process primitives) so as to track the target; it drains a backend before killing it. This is what
took a live proxy from eight backends down to four (and then to one) under falling load, purely from the
measured metric.

## The Control Plane, `orch/`

### The Workload Specification, `orch/spec`

`Spec` is the workload manifest: the binary path, the arguments, the desired replica count, the restart
policy, the resource limits (cpu milli, memory bytes, pids), the isolation level and rootfs, and an
optional health probe. `parseSpec` reads it from JSON; `specsEqual` performs change detection between the
desired and the observed spec; and `shouldRestart` encodes the restart policy logic.

### Replica Supervision, `orch/supervisor`

A `Supervisor` keeps one workload's replica set running. `ensureReplicas` spawns up to the desired count;
`poll` observes each replica (through the non blocking `nova_process_try_wait`, with WNOHANG) and **restarts
on crash** as per the policy; and `stopAll` performs a graceful stop (a SIGTERM followed, if required, by a
SIGKILL). The identity of a replica is its kernel PID.

### The Node Agent, `orch/nativelet`

The `Nativelet` is the reconcile loop node agent. It watches a directory of `*.json` workload manifests;
`scan` reads the directory into a set of `Manifest` and `Job` entries (keyed by file name, so that a
transient read error does not tear down and recreate a running workload); and `reconcile` drives the
desired state towards the observed state: it starts new workloads, replaces changed ones, polls the running
ones (including async HTTP `/healthz` probes, restarting an unhealthy replica), and stops the removed ones.
One async coroutine drives the whole loop; there is no thread per workload.

### Resource Limits, `orch/isolation`

`orch/isolation` applies **cgroups v2** limits (cpu, memory, pids) by writing to the cgroup filesystem, and
reads a CPU utilisation metric (`cpuUsageUsec`) that the autoscaler consumes. This is a Linux only facility;
`available` reports whether it is usable on the host.

### Workload Autoscaling, `orch/autoscaler`

`WorkloadScaler` applies the same `PidController` at the workload level: `tick` (or `tickCpu`, which uses
the cgroup CPU metric) `decide`s a target replica count and adjusts the supervisor accordingly.

## Isolation, `os/sandbox`

`os/sandbox` exposes an **isolation dial** with levels 0, 1, and 3. It is a thin surface over the runtime
primitive `nova_process_spawn_isolated` (see [03-runtime.md](03-runtime.md)), which, on Linux, does a
`clone()` into the PID, mount, UTS, IPC, net, and user namespaces, then a `pivot_root` into a private
rootfs, then drops all capabilities, then installs a seccomp BPF filter, and finally `execve`s the target.
`IsolationSpec` describes the desired level and rootfs, and `spawn` launches under it. The I2 supervisor
wires a workload's `isolationLevel` and `rootfs` through to this. Off Linux, the whole facility degrades
cleanly to a plain process spawn, so that the orchestrator still runs (albeit without isolation).

## Service Virtual Endpoints, `net/service`

`net/service` provides Kubernetes Service style **virtual endpoints**. A `Service` is a stable front
address (a VIP) that load balances to backend replicas on ephemeral ports, over the I1 proxy, with health
gated membership. It maintains a name to endpoint registry and a discovery file (in the manner of
`/etc/hosts`), and it binds the specific VIP through the runtime's `nova_aserver_listen_addr` (which binds a
particular address rather than INADDR_ANY). The kernel tier (network namespaces, veth pairs, overlays,
IPVS, or eBPF) is deliberately deferred; the present implementation is the userspace tier over the proxy.

## The Runtime Seams It Relies Upon

The orchestrator is pure Nova, yet it stands upon a small set of runtime seams that were added in the
language expressly for it, and which remain in the language while the orchestrator itself is a package:

- `nova_process_spawn`, `nova_process_try_wait`, `nova_process_pid`, and `nova_process_spawn_isolated`, that
  is, the process and isolation primitives.
- `nova_aserver_listen_addr`, for binding a specific service VIP.
- The async socket and timer primitives (`net/asyncio`), and the `process`, `io/file`, `io/dir`, and
  `serde/json` standard library modules.

## Platform Notes

The cgroups limits, the cgroup CPU autoscaling, and the `os/sandbox` isolation (namespaces, rootfs, seccomp)
require a **Linux host** (with root or CAP_SYS_ADMIN). On macOS they degrade cleanly to plain process
supervision, so that the orchestrator still runs and load balances, though without the kernel level
isolation and limits. The isolation tier has been verified on native arm64 under Docker; kindly note that
the complex `clone()` with namespaces fails under amd64 emulation, so a native architecture is to be used
for testing it.
