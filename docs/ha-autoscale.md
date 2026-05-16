# HA standby — autoscale & capacity model

## Goal

When DNS failover sends production traffic from the AWS primary (CloudFront + Lambda — effectively unbounded) to the **single-Pi k3s standby**, the Pi has to absorb the surge without crashing or losing data.

The Pi cannot match Lambda's elastic scale — it's one physical box. But within its envelope it can:

1. Spin more `cloudless-app` replicas as load rises (HPA)
2. Refuse to overcommit the host (ResourceQuota)
3. Shed excess load gracefully with HTTP 429 instead of crashing (Traefik rate-limit)
4. Keep at least one replica healthy through rollouts (PDB)

## What's deployed

| Resource | File | Effect |
|---|---|---|
| HPA | `hpa.yaml` | 1 → 2 replicas, 60% CPU target, fast scale-up (15s), slow scale-down (5min) |
| ResourceQuota | `resourcequota.yaml` | Cloudless namespace capped at 6 GiB / 5 CPU / 10 pods total — protects Docker stack on same host |
| PodDisruptionBudget | `pdb.yaml` | Always at least 1 pod running |
| Traefik rate-limit middleware | `middleware-ratelimit.yaml` | 50 req/s sustained, 100 burst, 200 in-flight |
| Pod resources | `deployment.yaml` | requests 200m / 384Mi, limits 1500m / 1.5Gi |
| Pod anti-affinity | `deployment.yaml` | Soft preference to spread replicas across nodes — but `cloudless-app` realistically runs only on `omv`; `omv-ha` (1 GB) can't host a 1.5 GiB-limit pod |

## Capacity envelope

`cloudless-app` runs on **`omv`** (Pi 5: 4 cores, 8 GB RAM). The cluster's
second node, `omv-ha` (Pi 4, ~1 GB), is a control-plane / etcd peer plus
light NFS-backed workloads — it is too small to host a 1.5 GiB-limit app
pod, so the app capacity model below is `omv`-only.

`omv` budget allocation:

| Consumer | RAM | CPU |
|---|---|---|
| cloudless ns (HPA peak: 2 × cloudless-app + sync jobs) | ~3.5 GiB (quota cap 6 GiB) | ~3 cores (quota cap 5) |
| kube-system (k3s control + Traefik + cert-manager + metrics-server) | ~600 MiB | ~0.3 cores |
| Docker stack (homepage, portainer, pihole, uptime-kuma) | ~600 MiB | ~0.2 cores |
| OS overhead | ~300 MiB | ~0.1 cores |
| Headroom | ~3 GiB | ~0.4 cores |

The `ResourceQuota` `limits.cpu` of 5 deliberately exceeds the 4 physical
cores — `limits` are burst ceilings, not reservations; the kernel CFS
throttles under contention.

## What this does NOT solve

- **Hard ceiling**: a Pi 5 saturates around ~200-400 req/s for SSR Next.js depending on page complexity. Above that, Traefik returns 429 to additional callers — they get a proper "service degraded" rather than a hung connection or crash.
- **Geographic latency**: requests still cross the public internet to your home IP. CloudFront's edge network is gone during failover. Expect 50-200 ms higher response times for non-EU clients.
- **Database bottlenecks**: if the app talks to RDS / DynamoDB / Cognito, the Pi → AWS round-trip latency dominates SSR time. Phase 4 should consider read-through caching at the Pi.
- **True elastic spillover**: not solved. The architecturally clean answer is to keep CloudFront cache fronting *both* primary and standby (origin failover at CloudFront level), or to point the failover at a Lambda warm-pool. Both are larger projects.

## Scaling cloudless-app across nodes

The cluster already has a second node — `omv-ha` — but it is a ~1 GB Pi 4
serving as a control-plane / etcd peer; it cannot host `cloudless-app`
(384 Mi request / 1.5 GiB limit per pod). So `cloudless-app` is single-node
on `omv`, and `maxReplicas: 2` is bounded by `omv`'s **4 physical cores**
(2 SSR pods × 1.5 CPU), not by the ResourceQuota — the quota (6 GiB / 5 CPU)
has room for more. See the `hpa.yaml` header comment.

To scale the app horizontally across nodes you need a *third*, app-capable
worker (≥ 4 GB RAM). Add it only when sustained `omv` CPU during failover
exceeds 80% for >10 min:

```bash
# On the new worker Pi:
curl -sfL https://get.k3s.io | K3S_URL=https://omv:6443 \
  K3S_TOKEN="$(ssh omv 'sudo cat /srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s/server/node-token')" \
  sh -s - agent

# On omv:
kubectl get nodes
kubectl label node <new-pi> ha-tier=standby
```

The soft anti-affinity in `deployment.yaml` then spreads replicas onto it;
raise HPA `maxReplicas` to match the added core count.

## Tuning levers (knobs to turn during real failover)

If the Pi is hot:

```bash
# Lower HPA target → spawn more pods sooner
kubectl -n cloudless patch hpa cloudless-app --type=merge \
  -p '{"spec":{"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":50}}}]}}'

# Tighter rate limit → shed more
kubectl -n cloudless patch middleware cloudless-app-ratelimit --type=merge \
  -p '{"spec":{"rateLimit":{"average":30,"burst":60}}}'
```

More capacity is **not** an HPA knob: at peak the 2 SSR pods already use
~3 of `omv`'s 4 cores, so raising `maxReplicas` alone just causes CPU
contention. The real lever is hardware — add an app-capable worker node
(see "Scaling cloudless-app across nodes" above), then raise `maxReplicas`
to match. The ResourceQuota (6 GiB / 5 CPU / 10 pods) already has headroom
and rarely needs bumping.

All the hot-Pi knobs above are reversible.

## Observability

- HPA decisions: `kubectl -n cloudless describe hpa cloudless-app` shows current replicas + scaling history
- Rate-limit hits: `kubectl -n kube-system logs deploy/traefik | grep -i 429`
- Pod resource pressure: `kubectl -n cloudless top pods` (needs metrics-server, included in k3s)
- App-side: `/ha logs` and `/ha status` already cover this
