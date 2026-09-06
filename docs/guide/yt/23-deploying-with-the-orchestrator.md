# Video 23: Deploying with Kynator

- Chapter: [23-deploying-with-the-orchestrator.md](../23-deploying-with-the-orchestrator.md)
- Estimated length: ~14 minutes
- You will need: Kyte installed, a PostgreSQL server, curl, and the guide's `examples/` folder. Watching Video 18 on data access first is essential, since we deploy that PostgreSQL-backed app.

## Hook (0:00)

**Say:** You have a PostgreSQL-backed web service. In this video we run it the way you would in production: several replicas behind a load balancer, supervised and kept at their desired count. Kyte ships Kynator, a small orchestrator, for exactly this. The parts we use here are three binaries that mirror the Kubernetes control-plane and data-plane split, service, kynatord, and kynatorctl; a fourth binary, artifactd, delivers the actual application binaries and hosts Kynator's own config store. By the end of this one you will have curled your app through a real load balancer and operated its config store from the command line.

## What we will cover (0:30)

**On screen:**
```
- The three binaries: service, kynatord, kynatorctl
- service: the data plane, load-balancing your replicas
- kynatord: the control plane, keeping replicas alive + service discovery
- kynatorctl: operating the config store offline
- The whole loop, end to end, with run-live.sh
```

## Segment: The shape of a deployment (1:00)

**Say:** Here is the picture. Two replicas of your app, a proxy in front of them, a control-plane agent keeping them alive, PostgreSQL holding your application data, and artifactd holding Kynator's own config store.

**On screen:**
```
                service  (:8090, round-robin, health checks)
                /     \
  app replica A (:8080)  app replica B (:8081)     <- your PostgreSQL-backed web app
                \     /
                 PostgreSQL (:5432)                 <- your app's data (products table)
                   ^
                 kynatord  (reconciles replicas, writes the discovery file service reads)
                   |
                 artifactd (:8135)                  <- deploy blobs + Kynator config store
```

**Say:** Notice the split: PostgreSQL holds your products table, and artifactd holds Kynator's config store, its cluster membership and workload definitions, over a small `/cfg/*` HTTP surface snapshotted to a `config.snap` file. Kynator does not run a database of its own.

## Segment: The three binaries (2:15)

**On screen:**
```
service    data plane      An L7 reverse proxy and load balancer in front of your replicas.
kynatord     control plane   Reconciles desired vs actual replicas, health probes, service discovery.
kynatorctl   operations      Offline CLI over the config store: inspect, membership, upgrade plan.
```

**Say:** They ship with Kynator. service moves traffic, kynatord keeps replicas alive, and kynatorctl is a command-line tool for operating the config store without a running control plane.

## Segment: service, the data plane (3:15)

**Say:** service reads a JSON config and load-balances across a set of backends. Here is a minimal config for our two replicas.

**On screen:**
```json
{
  "listenHost": "127.0.0.1", "listenPort": 8090, "strategy": "roundrobin",
  "health": { "enabled": true, "path": "/", "intervalMs": 2000, "timeoutMs": 1000, "rise": 1, "fall": 3 },
  "backends": [ { "host": "127.0.0.1", "port": 8080, "weight": 1 },
                { "host": "127.0.0.1", "port": 8081, "weight": 1 } ]
}
```

**Run it:**
```sh
service service.json --check     # validate the config, print backends + strategy, exit
service service.json             # serve
```

**Say:** Strategies are round-robin, weighted, least-connections, and consistent-hash. Health checks poll the path you give; a backend drops out after `fall` failures and comes back after `rise` successes. service refuses to start with zero live backends, so a bad pool fails loudly instead of black-holing traffic. And because our app honours `KYTE_PORT`, we can run two replicas of the same binary on one host, on 8080 and 8081, for service to balance.

## Segment: kynatord, the control plane (5:30)

**Say:** Where service moves traffic, kynatord keeps the replicas alive. It watches a manifest directory, reconciles the running replicas against the desired count on a loop, runs health probes, and can publish a discovery file that service reads instead of a static backend list.

**On screen:**
```json
{
  "manifestsDir": "manifests", "reconcileMs": 2000, "nodeId": "node-1",
  "discoveryFile": "discovery.txt", "metricsFile": "metrics.prom",
  "store": { "enabled": true, "addr": "127.0.0.1:8135", "token": "", "tls": false }
}
```

**Say:** That `store` block points kynatord at artifactd's config store. The `storeBaseUrl` helper turns it into the base URL `http://127.0.0.1:8135`, and `HttpConfigStore` appends the `/cfg/*` routes; `addr` is artifactd's host and port, `token` is the same deploy bearer token artifactd guards its routes with, and `tls` selects https. With a discovery file configured, kynatord writes lines like `web=127.0.0.1:8080,127.0.0.1:8081`, and a service set to that discovery file load-balances across whatever replicas kynatord currently has healthy. Scale up or lose a replica, and the pool reshapes without editing service's config.

## Segment: kynatorctl, operating the store (7:45)

**Say:** kynatorctl is deliberately offline. It works on a backup dump of the config store, a key-tab-value file, so you can inspect and repair cluster state without a running control plane.

**On screen:**
```sh
kynatorctl inspect store.dump                 # count + list keys
kynatorctl members store.dump                 # list cluster members
kynatorctl member add store.dump node-4 10.0.0.4:7004
kynatorctl upgrade-plan store.dump            # the safe rolling-upgrade node order
```

**Say:** `upgrade-plan` prints an order that drains a node if it is the leader, upgrades it, then lets it rejoin, so a rolling upgrade never takes down the quorum. The backup and restore flow and the leader-lease details are in Kynator's runbooks.

## Segment: The whole loop (9:15)

**Say:** Let us run all of it. The guide's `run-live.sh` starts PostgreSQL, builds and starts two replicas of the app on 8080 and 8081, exercises the app directly, then starts service on 8090 and curls the app through the proxy three times so you see the round-robin. It finishes by inspecting a config-store dump with kynatorctl.

**Run it:**
```sh
cd docs/guide/examples && ./run-live.sh
```

**On screen:**
```
== 3/5  exercise the app directly (write -> PostgreSQL -> read back)
== 4/5  put the app behind service (data plane, load-balancing the two replicas)
   GET through service on :8090 three times (round-robins across the two replicas)
== 5/5  operate the config store with kynatorctl (offline ops CLI)
```

**Say:** It builds everything it needs, the app and Kynator binaries, connects to PostgreSQL, and cleans up every process on exit. That is a full deployment on one machine.

## Segment: Production concerns (11:30)

**Say:** Three things you get for production. Health: kynatord exposes liveness and readiness and a Prometheus metrics surface with crash-loop alerts, and service's own health checks decide which backends get traffic. Rolling upgrades: drain, promote a standby if the node was the leader, upgrade, rejoin, with rollback, and kynatorctl gives you the order. And high availability: membership, a leader lease with fencing, and backup and restore of the config store, all covered in the runbooks.

## Recap (12:45)

**Say:** Let us recap.

- Kynator's core is three binaries: service the data plane, kynatord the control plane, kynatorctl the offline ops CLI. A fourth, artifactd, delivers binaries and is the next video.
- service load-balances your app replicas with health checks and several strategies.
- kynatord keeps replicas at their desired count and can publish service discovery for service.
- The config store lives in artifactd, over its `/cfg/*` HTTP routes and a `config.snap` snapshot, not in a database. Your app's own data stays in PostgreSQL.
- kynatorctl inspects and repairs that store and plans safe rolling upgrades, all offline.

## Outro (14:00)

**Say:** So far the manifest pointed at a binary already sitting on disk. In the final video we close that gap: how the binary gets to each node in the first place, with artifactd and the content-addressed blob store. See you there.

**On screen:**
```
Next: Video 24, Artifact delivery: the blob store
```
