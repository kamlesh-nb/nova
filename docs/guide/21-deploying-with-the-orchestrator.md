# 21. Deploying with the orchestrator

You have a NovaDB-backed web service (Chapter 18). This chapter runs it in production shape: several
replicas behind a load balancer, supervised and kept at their desired count, with configuration held in
NovaDB. Nova ships a small orchestrator for exactly this, split into three binaries that mirror the
Kubernetes control-plane / data-plane split:

| Binary    | Plane        | Job |
|-----------|--------------|-----|
| `service`  | data plane   | An L7 reverse proxy and load balancer in front of your app replicas. |
| `orchd`   | control plane| The node agent: reconciles desired vs actual replicas, runs health probes, publishes service discovery, writes metrics. |
| `orchctl` | operations   | An offline CLI over the config store: inspect it, manage cluster membership, print a rolling-upgrade plan. |

They live in `packages/nova-orchestrator`; its `README.md` and `docs/runbooks.md` are the operator
references. `examples/run-live.sh` runs everything below against the real binaries.

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

`service` reads a JSON config and load-balances across a set of backends. The minimal config:

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
`healthPath`; a backend is taken out after `fall` consecutive failures and returned after `rise`
successes. `service` refuses to start with zero live backends, so a misconfigured pool fails loudly
instead of silently black-holing traffic.

Your app already supports running many replicas on one host: `main_novadb.nova` honours `NOVA_PORT`, so
`NOVA_PORT=8080 ./webapp` and `NOVA_PORT=8081 ./webapp` give you two replicas for service to balance.

## orchd: the control plane

Where `service` moves traffic, `orchd` keeps the replicas alive. It watches a manifest directory and
reconciles the actual set of running replicas against the desired count on a fixed loop, runs async
health probes, and, when configured, publishes a service-discovery file that `service` reads instead of a
static backend list, and writes a Prometheus metrics file with crash-loop alerts.

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

The `store` block is turned into a NovaDB connection string by the orchestrator's `storeConnectionString`
helper, which produces exactly the `novadb://user:password@host:port?db=...&tls=...` URL the driver
parses. With `discoveryFile` set, orchd writes lines like `web=127.0.0.1:8080,127.0.0.1:8081`; a `service`
configured with `discoveryService: "web"` then load-balances across whatever replicas orchd currently
has healthy, so scaling up or losing a replica reshapes the pool without editing service's config.

## orchctl: operating the config store

`orchctl` is deliberately offline. It works on a backup dump of the config store (a `key<TAB>value`
file), so you can inspect and repair cluster state without a running control plane:

```sh
orchctl inspect store.dump                 # count + list keys
orchctl members store.dump                 # list cluster members
orchctl member add store.dump node-4 10.0.0.4:7004
orchctl member remove store.dump node-2
orchctl upgrade-plan store.dump            # print the safe rolling-upgrade node order
```

`upgrade-plan` prints a per-node order that drains a node if it is the leader, upgrades it, then lets it
rejoin, so a rolling upgrade never takes down the quorum. The full backup and restore flow, plus the
leader-lease and fencing details behind high availability, are in `packages/nova-orchestrator/docs/runbooks.md`.

## The whole loop

`examples/run-live.sh` puts it together end to end: it starts NovaDB, builds and starts two replicas of
the NovaDB-backed web app on 8080 and 8081, exercises the app directly (a write through to NovaDB and a
read back), then starts `service` on 8090 and curls the app through the proxy three times so you can see
the round-robin. It finishes with `orchctl` inspecting a seeded config-store dump and printing an upgrade
plan. Run it from `lang/docs/guide/examples/`:

```sh
./run-live.sh
```

It builds what it needs (the NovaDB server, the app, the orchestrator binaries) and cleans up every
process on exit.

> **Note.** `service` runs on the reactor-native socket path (the same one the web server uses): it
> binds, accepts, forwards to a backend, and streams the response back, load-balancing across the
> replicas. It keeps a **keep-alive pool of backend connections** (per reactor) and reuses a warm one
> per request instead of a fresh TCP handshake, which is the main throughput lever; health probes share
> the same pool. To use more cores, run N single-reactor `service` instances behind SO_REUSEPORT.

## Health, metrics, and upgrades in production

- **Health.** `orchd` exposes liveness and readiness (`/healthz`, `/readyz`) and a Prometheus
  `/metrics` surface with alert lines for crash loops. `service`'s own health checks decide which
  backends receive traffic.
- **Rolling upgrade.** Drain, promote a standby if the node was the leader, upgrade, rejoin, with
  rollback if a step fails. `orchctl upgrade-plan` gives you the order.
- **High availability.** Membership, a leader lease with fencing epochs, and backup/restore of the
  config store are all in the orchestrator package; the runbooks cover leader loss, split-brain, and a
  store outage.

## Where to go next

- Chapter 18 for the NovaDB-backed app this chapter deploys.
- Chapter 20 for building and cross-compiling the binaries you deploy.
- `packages/nova-orchestrator/README.md` and `docs/runbooks.md` for the full operator reference.
