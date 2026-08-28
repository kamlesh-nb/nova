# 23. Deploying with the orchestrator

You have a NovaDB-backed web service (Chapter 18). This chapter runs it in production shape: several
replicas behind a load balancer, supervised and kept at their desired count, with configuration held in
NovaDB. Nova ships a small orchestrator for exactly this. It is a container-free, Kubernetes-style
control plane that runs your workloads as ordinary native binaries (no images, no container runtime),
split into a handful of binaries that mirror the Kubernetes control-plane / data-plane split.

The orchestrator lives in `packages/nova-orchestrator`; its `README.md` and `docs/runbooks.md` are the
operator references. `lang/docs/guide/examples/run-live.sh` runs everything in this chapter against the
real binaries.

## The binaries

`build.sh` builds these binaries, each from its own entry file in `bin/`. Because each entry point pulls
only its slice of the package through the import graph, dead-code elimination drops the tiers it does not
reference, so the binaries come out naturally separated.

| Binary      | Plane / role  | Entry file            |
|-------------|---------------|-----------------------|
| `service`   | data plane: an L7/L4 reverse proxy and load balancer in front of your app replicas, and the fd-handoff gateway. | `bin/service.nova` |
| `orchd`     | control plane: reconciles desired vs actual replicas, runs health probes, publishes service discovery, runs the HA leader lease, writes metrics. | `bin/orchd.nova` |
| `orchctl`   | operations: an offline CLI over a config-store dump. Inspect it, manage cluster membership, print a rolling-upgrade plan. | `bin/orchctl.nova` |
| `artifactd` | the content-addressed artifact origin: a blob server that distributes deploy binaries by hash. | `bin/artifactd.nova` |
| `orchweb`   | an optional, best-effort control-plane web UI. | `webui/src/main.nova` |

The core set is `service`, `orchd`, `orchctl`, and `artifactd`. `orchweb` is a fifth, optional UI: the
build script only attempts it when `webui/src/main.nova` is present, and a build failure there never
fails the core stack.

`artifactd` and the blob store behind it are the subject of the next chapter (Chapter 24, artifact
delivery); this chapter focuses on running and balancing your replicas.

Build them all with the package's script:

```sh
cd packages/nova-orchestrator
./build.sh                        # debug build  -> build/debug/bin/
./build.sh --release              # optimised    -> build/release/bin/
./build.sh --release --target linux-arm64   # cross-compile -> build/release/linux-arm64/bin/
```

Native builds go through `nova build --file <src> -o <out>`; cross builds use the single-file compile
mode, `nova <src> -o <out> --target <triple>`. The supported cross triples are `linux-x86_64`,
`linux-arm64`, `macos-x86_64`, `macos-arm64`, `windows-x86_64`, and `windows-arm64`.

## The shape of a deployment

```
                        service  (:8090, round-robin, health checks)
                        /     \
        app replica A (:8080)  app replica B (:8081)     <- your NovaDB-backed web app
                        \     /
                         NovaDB (:3009)                  <- app data AND orchestrator config
                           ^
                         orchd  (reconciles replicas, writes the discovery file service reads)
```

The same NovaDB instance holds two things: your application data (the `products` table) and the
orchestrator's own configuration store (cluster membership, workload definitions). That is why the
config store speaks the `novadb://` connection string you met in Chapter 18.

## service: the data plane

`service` reads a JSON config and load-balances across a set of backends. It reads its config path from
`SERVICE_CONFIG` (default `service.json`), and `NOVA_PORT` overrides the listen port. The minimal config:

```json
{
  "listenHost": "127.0.0.1", "listenPort": 8090, "strategy": "roundrobin",
  "health": { "enabled": true, "path": "/", "intervalMs": 2000, "timeoutMs": 1000, "rise": 1, "fall": 3 },
  "backends": [ { "host": "127.0.0.1", "port": 8080, "weight": 1 },
                { "host": "127.0.0.1", "port": 8081, "weight": 1 } ]
}
```

Run it, or lint the config without serving:

```sh
service service.json --check     # validate, print backend count + strategy, exit
service service.json             # serve; NOVA_PORT overrides listenPort
```

Strategies are `roundrobin`, `weighted`, `leastconn`, and `consistenthash`. Active health checks poll
the health path; a backend is taken out after `fall` consecutive failures and returned after `rise`
successes. `service` refuses to start with zero live backends, so a misconfigured pool fails loudly
instead of silently black-holing traffic.

Your app already supports running many replicas on one host: `main_novadb.nova` honours `NOVA_PORT`, so
`NOVA_PORT=8080 ./webapp` and `NOVA_PORT=8081 ./webapp` give you two replicas for service to balance.

> **Note.** `service` runs on the reactor-native socket path (the same one the web server uses in
> Chapter 17): it binds, accepts, forwards to a backend, and streams the response back, load-balancing
> across the replicas. It keeps a **keep-alive pool of backend connections** (per reactor) and reuses a
> warm one per request instead of a fresh TCP handshake, which is the main throughput lever; health
> probes share the same pool. To use more cores, run N single-reactor `service` instances behind
> SO_REUSEPORT.

## orchd: the control plane

Where `service` moves traffic, `orchd` keeps the replicas alive. It reconciles the actual set of running
replicas against the desired count on a fixed loop, runs async health probes, and, when configured,
publishes a service-discovery file that `service` reads instead of a static backend list, plus a
Prometheus metrics file. It reads its config from `ORCHD_CONFIG` (default `orchd.json`) and has no listen
port of its own.

```json
{
  "manifestsDir": "manifests", "reconcileMs": 2000, "nodeId": "node-1",
  "discoveryFile": "discovery.txt", "metricsFile": "metrics.prom",
  "store": { "enabled": true, "addr": "127.0.0.1:3009", "user": "admin", "dbname": "nova" }
}
```

```sh
orchd orchd.json --check       # validate and exit
orchd orchd.json               # run the reconcile loop
```

The `store.enabled` flag chooses orchd's mode. With the store disabled it runs standalone: it reconciles
from a local manifest directory with no config store and no leader lease. With the store enabled it runs
the HA path: it connects to NovaDB, takes the leader lease, and reconciles desired state read from the
store. Both are covered below.

## The declarative manifest

The workload you want orchd to run is described declaratively. There are two schemas in the package, and
it is worth knowing which is which.

The current schema is a **YAML manifest**, parsed by `src/orch/manifest.nova`. The canonical example is
`examples/manifests/shop.yaml`:

```yaml
apiVersion: nova/v1
kind: App
metadata:
  name: shop
workload:
  binary: ./build/release/bin/webapp
  args:
    - --config
    - prod
  restartPolicy: always      # always | on-failure | never
replicas:
  min: 2
  max: 6
autoscale:
  enabled: true
  metric: inflight           # inflight (gateway load) | cpu (cgroup, Linux)
  setpoint: 8
  kp: 0.8
  ki: 0.1
  kd: 0.0
  intervalMs: 2000
lb:
  strategy: roundrobin       # roundrobin | weighted | leastconn | consistenthash
  handoff: true              # fd-passing data path; app has no public TCP port
health:
  path: /healthz
  intervalMs: 2000
  timeoutMs: 1000
  rise: 2
  fall: 3
network:
  expose: gateway-only       # gateway-only (handoff on mac/win, veth on linux) | public
routes:
  - /api/products
  - /api/orders
resources:
  cpuMilli: 500
  memMaxBytes: 268435456
  pidsMax: 128
```

`manifest.nova` gives you `parseManifest(text)`, `validateManifest(m)` (returns `""` when valid),
`toYaml(m)` (round-trips), and `toSpec(m)`, which lowers a manifest to the internal run spec the
supervisor acts on.

There is also a **legacy JSON `Spec`** schema in `src/orch/spec.nova`, parsed by `parseSpec(text)`. It
carries the same intent in a flatter, older shape (`name`, `binaryPath`, `args`, `restartPolicy`,
`replicas`, cgroup limits, probe settings, handoff settings, and an `artifact` field for hash-addressed
binaries, which the next chapter covers). New manifests should use the YAML form; the JSON `Spec` is
still parsed for existing deployments.

## The NovaDB-backed config store

When `store.enabled` is set, the `store` block is turned into a NovaDB connection string by the
orchestrator's `storeConnectionString` helper (in `src/cfg/config.nova`). It produces exactly the
`novadb://user:password@host:port?db=...&tls=...` URL the driver from Chapter 18 parses, so the same
NovaDB instance and the same DSN shape serve both your app data and the control plane's state. TLS
options follow the driver: `tls=verify` verifies the server certificate against a CA file, `tls=true`
encrypts without verifying. The `StoreConfig` validation enforces that verify implies a CA file and that
verify implies TLS.

orchd opens the store in its HA path like this:

```
let dsn = config.storeConnectionString(c.store);
let conn = await novadb.NovaDriver().connect(dsn);
let store = sqlconfig.SqlConfigStore(conn);
let _s = await store.ensureSchema();
```

`SqlConfigStore` (in `src/store/sqlconfig.nova`) is an etcd-shaped key-value store on top of NovaDB: a
monotonic global revision, a per-key modification revision, prefix listing, compare-and-swap on a
revision, delete, and a poll-based watch. It keeps two tables, `config` and `config_meta`. The keys it
persists are worth knowing:

- desired workload state under the `workloads/` prefix,
- the leader lease under `leases/orchd`,
- cluster membership under `members/<id>`.

There is also an in-memory sibling, `ConfigStore` in `src/store/config.nova`, which is what the offline
`orchctl` and the backup tooling operate on.

## Discovery file to load balancing

orchd and service meet through a small discovery file rather than a shared socket.

The writer side is orchd's nativelet (`src/orch/nativelet.nova`). Each reconcile tick it renders one
`name=host:port` line per replica and atomically writes the discovery file. With `basePort` set on a
workload, replica `i` advertises as `host:(basePort + i)`; otherwise replicas share the probe port.

The reader side is `service`. Given a discovery file and a service name, it reads back every
`name=host:port` line for that name and adds each `host:port` to its proxy pool. So a `service`
configured with `discoveryService: "web"` load-balances across whatever replicas orchd currently
advertises, and scaling up or losing a replica reshapes the pool without editing service's config.

The division of labour is deliberate: orchd advertises the desired topology, and the data plane owns
liveness. service's own active health checks prune any advertised endpoint that stops serving, so a
replica that has died but not yet been removed from the file still gets taken out of rotation.

## Health, metrics, and readiness

This is a place where the earlier revision of this chapter drifted, so read it carefully.

`orchd` does **not** serve `/healthz` and `/readyz` as HTTP routes. It has no listen port. Instead,
`src/orch/health.nova` computes health as plain data:

- `healthy()` is true when the config store is reachable.
- `ready()` is true when the store is reachable and the node's role is one of leader, standby, or
  standalone.
- `healthzText()` renders `"ok"` or `"degraded"`; `readyzText()` renders `"ready"` or `"not ready"`.

These are report strings a process computes, useful for a supervisor or a probe wrapper, not endpoints a
daemon listens on. What orchd actually emits is the `/metrics` surface, and it emits it as a **file**:
`renderMetrics` produces Prometheus text that orchd writes to the path in `metricsFile`, for a
node_exporter textfile collector to pick up. The metrics include `orch_up`, `orch_ready`,
`orch_store_reachable`, `orch_leader_epoch`, `orch_workloads_total`, `orch_running_total`,
`orch_under_provisioned`, `orch_reconcile_latency_ms`, and per-workload
`orch_workload_running/desired/restarts`.

If the store becomes unreachable, the HA reconcile tick sets `storeReachable` false, the node steps down,
and the health report flips `ready()` to false, so a load balancer or supervisor watching readiness stops
sending it work.

`service`'s own health checks, described earlier, are a separate mechanism: they decide which backends
receive traffic.

## Rolling upgrades and high availability

There are two rolling mechanisms at two levels.

**Workload-level replica replacement** happens inside a node. The supervisor
(`src/orch/supervisor.nova`) can retire the oldest replica gracefully (SIGTERM, then a timed grace
window, then SIGKILL) and spawn a fresh one, and it can swap in a changed spec without restarting
replicas that are already running the right thing. On a detected spec change the nativelet replaces one
replica per grace window until the roll is complete, so a config change rolls through the replicas rather
than bouncing them all at once.

**Node-level rolling upgrade** happens across nodes, driven by the leader lease. `src/orch/rollout.nova`
walks the nodes one at a time: if a node is the live leader, it releases the lease and promotes a peer
*before* the upgrade so leadership is never lost; it upgrades the node; the node rejoins as a standby; and
a failed upgrade rolls back and stops the roll. `orchctl upgrade-plan <file>` prints this node order so
you can review it before it touches a live cluster.

**The HA leader lease** underneath all this is in `src/orch/asynclease.nova` (`AsyncLeaderLease`; there is
a synchronous sibling in `lease.nova`). orchd builds it in its HA path against the `leases/orchd` key with
a TTL of `max(reconcileMs * 5, 15000)` ms. The lease value encodes `holder|epoch|deadlineMs`. Acquisition
is a compare-and-swap on the lease key, and the epoch is bumped on every takeover. Safety rests on that
**fencing epoch**, not on wall-clock time: the CAS guarantees exactly one winner per epoch, and a new
leader raises the store's write fence (`SET FENCE EPOCH n`) so a stale former leader's writes are
rejected. Each reconcile tick renews or acquires the lease, guards against a degraded store by stepping
down when it is unreachable, and only the confirmed leader reads `workloads/` and reconciles from it.

## Zero-downtime fd-handoff

The `handoff: true` line in the manifest selects a zero-copy data path that lets you replace an app
replica without dropping in-flight connections. It is POSIX-only by design.

In handoff mode `service` is an out-of-path L4 gateway. It binds an **AF_UNIX** rendezvous socket
alongside the front TCP port. Each backend app connects to the rendezvous as a control channel. On a new
client connection, `service` picks a backend and passes the client socket file descriptor to that app
over the control channel using **`SCM_RIGHTS`** ancillary data (`socket.sendFd`), then closes its own
copy. The app receives the descriptor with `socket.recvFd`, owns the socket, and replies to the client
directly. `service` is out of the data path entirely, so restarting or replacing a replica does not sever
connections the other replica is already serving.

Two details that look like bugs if you get them wrong:

- The rendezvous path is `/tmp/nova-<name>.sock`, and the **short path is deliberate**. AF_UNIX
  `sun_path` caps at roughly 104 bytes on macOS and 108 on Linux. Do not "portably" swap `/tmp` for
  `$TMPDIR` or `dir.tempDir()`; `/var/folders/...` overflows `sun_path` and breaks the macOS bind.
  `NOVA_HANDOFF_SOCK` overrides the path when you need to, and the default in `bin/service.nova` is
  `/tmp/nova-service.sock`.
- It is same-host by design. Passing a file descriptor cannot cross a kernel, so the handoff fits
  co-resident replicas on one node, not replicas spread across machines.

On Windows the `socket.sendFd`/`socket.recvFd` stubs return -1: the handoff compiles but does not run
there. The mechanism has no direct Windows equivalent (`SCM_RIGHTS` hands a descriptor to whoever holds
the other end, whereas `WSADuplicateSocket` prepares a duplicate for a process named by PID), so a
Windows port is explicitly not planned. Treat the orchestrator as a Linux and macOS production concern,
with Windows as a development host.

## orchctl: operating the config store offline

`orchctl` is deliberately offline. It works on a backup dump of the config store, a `key<TAB>value` file,
so you can inspect and repair cluster state without a running control plane. Its real subcommands are:

```sh
orchctl inspect store.dump                 # count + list keys
orchctl members store.dump                 # list cluster members
orchctl member add store.dump node-4 10.0.0.4:7004
orchctl member remove store.dump node-2
orchctl upgrade-plan store.dump            # print the safe rolling-upgrade node order
```

`upgrade-plan` prints the per-node order described above: it drains a node if it is the leader, upgrades
it, then lets it rejoin, so a rolling upgrade never takes down the quorum.

Backup and restore are a supported operation, though they are not a distinct `orchctl` subcommand.
`src/orch/backup.nova` provides `dump(store, prefix)` (line-oriented, escaped `key<TAB>value`) and
`restore(store, data)` (re-applies each entry, last write wins). `orchctl` is the operator surface over
such a dump: loading a file is a restore into an in-memory store, saving it is a dump. Physical
btree-tier backup and restore of the underlying NovaDB is a NovaDB operation, documented in the
orchestrator's `docs/runbooks.md`.

## The whole loop end to end

`lang/docs/guide/examples/run-live.sh` puts it together against the real binaries. It:

1. builds and starts NovaDB on `127.0.0.1:3009`, and seeds a `products` table over NovaDB's HTTP SQL
   endpoint,
2. builds the NovaDB-backed web app (`main_novadb.nova`) and starts two replicas on 8080 and 8081 via
   `NOVA_PORT`,
3. exercises the app directly: a `POST /api/products` write through to NovaDB and a
   `GET /api/products/1` read back,
4. builds the orchestrator with `./build.sh`, writes a `service.json` for the two replicas, validates it
   with `service --check`, starts `service` on 8090, and curls `GET /api/products/1` through the proxy
   three times so you can watch the round-robin,
5. seeds a config-store dump (members plus a workload) and runs `orchctl inspect`, `orchctl members`, and
   `orchctl upgrade-plan` over it.

Run it from anywhere; it builds what it needs and cleans up every process on exit:

```sh
lang/docs/guide/examples/run-live.sh
```

## Where to go next

- Chapter 17 for the web app and the reactor-native server this deploys.
- Chapter 18 for the NovaDB-backed app and the `novadb://` connection string the config store reuses.
- Chapter 24 for artifact delivery: `artifactd`, the content-addressed blob store, and pulling a deploy
  binary by hash.
- `packages/nova-orchestrator/README.md` and `docs/runbooks.md` for the full operator reference,
  including leader loss, split-brain, and store-outage runbooks.
