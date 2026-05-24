# Phase 1 — acceptance test (2026-05-02)

End-to-end verification that the cloudless HA standby is up on the Pi 5 and serving over real Let's Encrypt TLS.

## Verdict — ✅ Phase 1 complete (LAN)

Cluster, image registry, app, ingress, TLS, DNS, and backup integration all green. The only thing not yet exercised is **external HTTPS** — that's gated on the home router forwarding ports 80/443 to the Pi (a manual one-time admin action, see [Outstanding](#outstanding)).

## Components and what was tested

### k3s cluster

| Check | Result |
|---|---|
| `kubectl get nodes` | `omv` Ready, k3s v1.35.4+k3s1 |
| Control-plane pods | coredns, traefik, svclb-traefik, metrics-server, local-path-provisioner all Running |
| Traefik ingress ports | 18080 / 18443 (host 80/443/8080 untouched — owned by OMV nginx + pihole-FTL) |
| cgroup v2 | active |
| Data-dir | `/srv/dev-disk-by-uuid-a9a5a108-…/k3s` (sda) |

### Storage

| Check | Result |
|---|---|
| HA-dedicated subtree | `/srv/cloudless-ha/{k8s-pv,etcd-snapshots,manifests-snapshot}` exists |
| Default `local-path` StorageClass repointed | `nodePathMap[0].paths == ["/srv/cloudless-ha/k8s-pv"]` |
| Existing Docker stack on sda | homepage, portainer, pihole, uptime-kuma all Up + healthy |
| nas-backup integration | `/srv/cloudless-ha/` (16 K) and `k3s-db` (23 M) snapshotted to sdb1 `Backups/` |

### ECR + image pull

| Check | Result |
|---|---|
| ECR repo | `278585680617.dkr.ecr.us-east-1.amazonaws.com/cloudless-pi-app` |
| Image | `latest` + sha `09995aed214b`, ~72 MB, arm64, pushed 2026-05-02 09:26 Athens |
| Pull credential refresher CronJob | `0 */8 * * *`, last run Complete in 6 s |
| In-cluster pull | container running with `Image ID: …@sha256:b2af1e9a…` |
| IAM behind the pulls | `cloudless-pi-standby` (least-privilege: ECR pull on this repo only + token grant) |

### Application

| Check | Result |
|---|---|
| Deployment | `cloudless-app` 1/1 Ready, 0 restarts |
| Pod resources | requests 200 m / 384 Mi, limits 1500 m / 1536 Mi *(updated during HPA tuning post-acceptance)* |
| Probes | readiness + liveness on `/api/health` |
| Service | ClusterIP `10.43.104.90:80` → containerPort 3000 |
| Config Secret | `cloudless-app-config`, 68 keys (sourced from SSM `/cloudless/production/*`) |

### Ingress + TLS

| Check | Result |
|---|---|
| Ingress | `cloudless-app` (class `traefik`, host `cloudless.online`) |
| ClusterIssuers | `letsencrypt-route53` + `letsencrypt-route53-staging` both Ready=True |
| Certificate | `cloudless-online-tls` Ready=True |
| Cert details | `CN=cloudless.online`, issuer Let's Encrypt R12, valid `2026-05-02 → 2026-07-31` |
| Cert-manager IAM | `cloudless-cert-manager` (TXT-only on Z04620301I2V4SU2RF1RV) |

### DNS

| Check | Result |
|---|---|
| `.online` TLD authoritative NS | ~~the 4 ns-*.awsdns-* records~~ **migrated to Cloudflare** — now `fay.ns.cloudflare.com` / `jihoon.ns.cloudflare.com` (verified 2026-05-15; see ha-architecture.md) |
| `cloudless.online` A | `150.228.63.192` (Pi WAN, TTL 300) |
| `www.cloudless.online` A | `150.228.63.192` |

### End-to-end

| Path | Result |
|---|---|
| `curl --resolve cloudless.online:18443:192.168.1.128 https://cloudless.online:18443/api/health` | `{"status":"ok","timestamp":"…","version":"0.1.0"}` (real LE cert validated) |
| `curl https://cloudless.online/api/health` (public internet) | timeout (router forward not configured yet) |

### Existing OMV services (regression check)

| Service | State |
|---|---|
| homepage | Up 13 h healthy |
| portainer | Up 13 h |
| pihole | Up 13 h healthy |
| uptime-kuma | Up 13 h healthy |
| smbd / monit / tailscaled | unchanged |
| OMV nginx admin UI | bound to 80 / 8080 — unchanged |

## Background routines

| Routine | Cadence | Behaviour |
|---|---|---|
| `cloudless DNS watcher` (`trig_01E9jkFKTYK7TyR4WkEU4HQs`) | hourly | snapshots NS/A/AAAA/MX/TXT for both domains, emails on diff only |
| `cloudless.online NS propagation check` (`trig_01KArorGrVotibbh8bAknxo9`) | one-shot, re-armed | last verdict was PENDING; latest manual probe shows TLD now correct — this routine is now redundant, can be retired |

## Outstanding

| Item | Owner | Notes |
|---|---|---|
| **Home router port-forward** 80→18080 + 443→18443 to 192.168.1.128 | user (one-time, gateway admin UI) | Last gate before public HTTPS |
| **uptime-kuma monitor** for `https://cloudless.online/api/health` | user (uptime-kuma UI; v1.x has no monitor-CRUD API) | Add via http://192.168.1.128:3001 — type HTTPS, interval 60 s, expect 200 |
| **Phase 2** Route 53 health-checked failover | next | Once the public HTTPS path is up, wire CloudFront primary + Pi secondary as failover records on cloudless.gr |
| **Phase 3** DDNS Lambda for the Pi WAN IP | future | Replaces the manual A record |

## Skills available for ongoing ops

`/ha status | deploy [tag] | rollback | logs | restart | config-sync | cert-status | failover-test | exec` — see `~/.claude/commands/ha.md`.

## Related

- Build state: `/home/tbaltzakis/cloudless-build-state.md`
- Architecture: [`docs/ha-architecture.md`](ha-architecture.md)
- Port map: [`docs/port-map.md`](port-map.md)
- Failover runbook: [`docs/runbook-failover.md`](runbook-failover.md)
