# Runbook — promote `omv-ha` to a k3s control-plane server

Mirrors the Notion project *"k3s HA — omv-ha → Control Plane"*. Goal: form a
2-member etcd quorum so the cluster API survives the loss of `omv`.

## Topology

| | before | after |
|--|--|--|
| `omv` (Pi 5) | server, embedded etcd | server, etcd member |
| `omv-ha` (Pi 4) | agent (worker) | server, etcd member |

User traffic is unaffected throughout: CloudFront → Lambda is the primary
path, and `cloudless-app` runs with 2 replicas + PDB `minAvailable=1`.

## Failure tolerance — important caveat

Embedded etcd uses Raft, which requires a majority of members to elect a
leader and accept writes. The math is `(N/2)+1`:

| etcd members | quorum | failures tolerated |
|--|--|--|
| 1            | 1 | 0 |
| **2**        | **2** | **0** |
| 3            | 2 | 1 |
| 5            | 3 | 2 |

**A 2-member etcd cluster tolerates zero failures.** Promoting `omv-ha` to a
control-plane gives you etcd state replicated across both Pis (faster recovery
from a destroyed `omv` SD card, restorable from `omv-ha`), but it does **not**
give you "API stays up if one node dies" — the survivor will sit in a
no-quorum state with the API server effectively read-only until the other
node returns or you manually run `k3s server --cluster-reset` on the
survivor.

If true control-plane HA matters, add a third member. Cheapest options:

- A third Pi (Zero 2 W is enough for an etcd member if you stay below ~50
  pods).
- A small VM (1 vCPU / 1 GB) on the LAN or in the same AWS account, joined
  via Tailscale.
- Run `omv-ha` as a server *with* `--disable-apiserver --disable-controller-manager --disable-scheduler` to make it an etcd-only voter — saves RAM but still requires a third for true HA.

Until then, `failover-test.sh` is a *data-plane* test (does the app keep
serving traffic during a primary outage?), not a control-plane HA test.

## Pre-flight (one time)

1. **Confirm embedded etcd is the datastore on `omv`** — not the default
   sqlite. Look for `<data-dir>/server/db/etcd`:
   ```bash
   ssh omv 'sudo ls -d /srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s/server/db/etcd'
   ```
   If that directory does not exist, **stop**: `omv` was installed without
   `--cluster-init` and is on sqlite. Migrate to etcd first (separate runbook).

2. **Fetch the cluster join token** from `omv`:
   ```bash
   export K3S_TOKEN="$(ssh omv 'sudo cat /srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s/server/node-token')"
   ```

3. **Sanity-check pod distribution** so the drain in step 1 below won't take
   the app down:
   ```bash
   kubectl get pods -A -o wide
   ```
   `cloudless-app` should have at least one replica on `omv` (not exclusively
   on `omv-ha`).

## One-shot orchestration

```bash
# from a workstation with kubectl + ssh to both pis
export K3S_TOKEN="$(ssh omv 'sudo cat /srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s/server/node-token')"
./scripts/promote-omv-ha.sh
```

The orchestrator runs the manual steps below in sequence.

## Manual steps (if you want to run them by hand)

1. **Drain `omv-ha`**:
   ```bash
   kubectl cordon omv-ha
   kubectl drain omv-ha --ignore-daemonsets --delete-emptydir-data --timeout=180s
   ```

2. **On `omv-ha`**: replace agent with server, joining etcd:
   ```bash
   scp k3s/join-as-server.sh omv-ha:/tmp/
   ssh omv-ha "sudo K3S_URL=https://192.168.1.128:6443 K3S_TOKEN='${K3S_TOKEN}' bash /tmp/join-as-server.sh"
   ```
   The script:
   - runs `k3s-agent-uninstall.sh` if a worker install is present,
   - installs k3s as `server --server <PRIMARY_URL>` (joins etcd),
   - waits for node Ready, copies kubeconfig.

3. **Uncordon and verify**:
   ```bash
   kubectl uncordon omv-ha
   ./scripts/verify-ha.sh
   ```
   Expected:
   - `kubectl get nodes` → both nodes show `control-plane,master` role.
   - All pods `Running`/`Completed`.
   - `cloudless-app` ready replicas == desired.

## Failover test

```bash
./scripts/failover-test.sh --yes
```

This stops `k3s` on `omv` for ~2 min, switches a temp kubeconfig to `omv-ha`'s
API endpoint, hits `cloudless.online/api/health`, then restarts `omv` and
confirms quorum reformed.

## Rollback

If etcd fails to form quorum on `omv-ha`:

```bash
ssh omv-ha 'sudo /usr/local/bin/k3s-uninstall.sh'
ssh omv-ha "sudo K3S_URL=https://192.168.1.128:6443 K3S_TOKEN='${K3S_TOKEN}' \
  curl -sfL https://get.k3s.io | sh -s - agent"
kubectl uncordon omv-ha
```

That puts `omv-ha` back to the pre-promotion worker state. The remaining etcd
member on `omv` continues to serve.

## Known constraints to watch

- **`omv-ha` has 1 GB RAM.** etcd is small, but the second control plane plus
  the existing agent workloads make memory tight. `kubectl top node omv-ha`
  before/after; if pressure shows, taint `omv-ha` to repel non-critical pods.
- **Traefik / klipper-lb on host ports.** The first time klipper-lb tries to
  bind 18080/18443 on `omv-ha`, those ports must be free on the Pi 4. Check
  with `ss -tlnp` before promotion.
- **Kubeconfig server URL.** Most operator kubeconfigs point at
  `https://192.168.1.128:6443` (omv). After promotion, that still works, but
  in a real failure of `omv`, you need a kubeconfig pointing at
  `https://192.168.1.130:6443` (or a VIP). Keep both around.
