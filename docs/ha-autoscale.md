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
| ResourceQuota | `resourcequota.yaml` | Cloudless namespace capped at 5 GiB / 3 CPU / 10 pods total — protects Docker stack on same host |
| PodDisruptionBudget | `pdb.yaml` | Always at least 1 pod running |
| Traefik rate-limit middleware | `middleware-ratelimit.yaml` | 50 req/s sustained, 100 burst, 200 in-flight |
| Pod resources | `deployment.yaml` | requests 200m / 384Mi, limits 1500m / 1.5Gi |
| Pod anti-affinity | `deployment.yaml` | Soft preference to spread across nodes (no-op on 1 node, future-ready) |

## Capacity envelope

Pi 5: 4 cores, 8 GB RAM. Total budget allocation:

| Consumer | RAM | CPU |
|---|---|---|
| cloudless ns (HPA peak: 4 × 1.5 GiB) | up to 5 GiB | up to 3 cores |
| kube-system (k3s control + Traefik + cert-manager + metrics-server) | ~600 MiB | ~0.3 cores |
| Docker stack (homepage, portainer, pihole, uptime-kuma) | ~600 MiB | ~0.2 cores |
| OS overhead | ~300 MiB | ~0.1 cores |
| Headroom | ~500 MiB | ~0.4 cores |

## What this does NOT solve

- **Hard ceiling**: a Pi 5 saturates around ~200-400 req/s for SSR Next.js depending on page complexity. Above that, Traefik returns 429 to additional callers — they get a proper "service degraded" rather than a hung connection or crash.
- **Geographic latency**: requests still cross the public internet to your home IP. CloudFront's edge network is gone during failover. Expect 50-200 ms higher response times for non-EU clients.
- **Database bottlenecks**: if the app talks to RDS / DynamoDB / Cognito, the Pi → AWS round-trip latency dominates SSR time. Phase 4 should consider read-through caching at the Pi.
- **True elastic spillover**: not solved. The architecturally clean answer is to keep CloudFront cache fronting *both* primary and standby (origin failover at CloudFront level), or to point the failover at a Lambda warm-pool. Both are larger projects.

## When to add a 2nd Pi as a worker node

Only when sustained Pi CPU during failover exceeds 80% for >10 min. At that point:

```bash
# On the new Pi:
curl -sfL https://get.k3s.io | K3S_URL=https://omv:6443 \
  K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token-from-omv) \
  sh -

# On omv:
kubectl get nodes
kubectl label node <new-pi> ha-tier=standby
```

The pod anti-affinity in `deployment.yaml` will start spreading replicas across both nodes immediately. HPA `maxReplicas` and the namespace ResourceQuota may need bumping (current cap is 2 replicas, governed by the 3 CPU / 5 GiB `limits.*` quota).

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

If the Pi has headroom and you want better latency:

```bash
# Bump max replicas if quota allows
kubectl -n cloudless patch hpa cloudless-app --type=merge -p '{"spec":{"maxReplicas":6}}'
kubectl -n cloudless patch resourcequota cloudless-quota --type=merge \
  -p '{"spec":{"hard":{"limits.memory":"6Gi","pods":"15"}}}'
```

All these are reversible.

## Observability

- HPA decisions: `kubectl -n cloudless describe hpa cloudless-app` shows current replicas + scaling history
- Rate-limit hits: `kubectl -n kube-system logs deploy/traefik | grep -i 429`
- Pod resource pressure: `kubectl -n cloudless top pods` (needs metrics-server, included in k3s)
- App-side: `/ha logs` and `/ha status` already cover this
