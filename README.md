# OMV — k3s cluster for cloudless.gr

This repository holds the infrastructure-as-code and runbooks for the **Pi 5 / OMV** node (and its `omv-ha` peer) that serves [cloudless.gr](https://cloudless.gr) via a 2-node k3s cluster.

External ingress is **Cloudflare Tunnel** (`cloudflared` on omv → Traefik :18443) — outbound-only, no router port-forward, no WAN-IP exposure. Public TLS is handled by Cloudflare Universal SSL; the origin leg uses `noTLSVerify`, so no cert-manager / Let's Encrypt / Cloudflare API token is required on the cluster. Intra-cluster HA is keepalived VIP + embedded etcd across both Pis. The AWS serverless app (Lambda + CloudFront, SST-managed in the `cloudless.gr` repo) is a separate concern and is not configured by this repo.

## Layout

```
k3s/
├── install.sh                 # one-shot k3s installer (idempotent, primary node)
├── join-as-server.sh          # promote omv-ha from worker → control-plane server
├── traefik-config.yaml        # Traefik HelmChartConfig — binds 18080/18443
├── cloudless-app/             # the cloudless workload (Deployment/Service/Ingress + sync infra)
│   ├── namespace.yaml
│   ├── resourcequota.yaml          # cap cloudless ns at 6 GiB / 5 CPU / 10 pods
│   ├── ecr-cred-refresher.yaml     # CronJob */6h — refreshes regcred-ecr (ECR token 12h TTL)
│   ├── image-sync.yaml             # CronJob */1min — rollout on ECR digest diff
│   ├── config-sync.yaml            # CronJob */5min — rebuild Secret on SSM diff
│   ├── sync-webhook/               # HMAC webhook that fires one-off image-sync Jobs (~5s drift)
│   ├── middleware-ratelimit.yaml   # Traefik 50 req/s + 200 in-flight (fail-fast 429)
│   ├── app-config.example.yaml
│   ├── deployment.yaml
│   ├── hpa.yaml                    # 1 → 2 replicas, CPU 60% target
│   ├── pdb.yaml                    # always ≥1 pod through rollouts
│   ├── service.yaml
│   ├── ingress.yaml
│   └── kustomization.yaml
└── cert-manager/              # optional — only if you need a real origin cert
    ├── install.sh
    ├── cloudflare-api-token.example.yaml
    └── cluster-issuer.yaml

docs/
├── ha-architecture.md             # how the failover works
├── ha-autoscale.md                # capacity model + HPA + tuning levers
├── ha-control-plane-promotion.md  # runbook: promote omv-ha → control-plane
├── branch-cleanup.md              # how the cleanup-branches workflow works
├── port-map.md                    # what's listening on what port
├── phase1-acceptance.md           # 2026-05-02 end-to-end test results
└── runbook-failover.md            # operational procedures

scripts/
├── promote-omv-ha.sh          # orchestrates worker → control-plane promotion
├── verify-ha.sh               # nodes Ready, etcd healthy, pods Running
├── failover-test.sh           # simulate omv outage, assert omv-ha takes over
├── omv-healthcheck.sh         # read-only OMV host health check
├── omv-inventory.sh           # read-only full OMV host inventory
├── omv-report-to-github.sh    # publish health/inventory reports to a branch
├── omv-apply-fixes.sh         # idempotent OMV host maintenance fixes
├── omv-repair.sh              # diagnose/repair a broken OMV control plane
├── omv-install.sh             # install OpenMediaVault on the omv NAS node
├── omv-ha-k3s-prep.sh         # keep omv-ha a lean, stable k3s node
├── cloudflared-login.sh       # cloudflared OAuth login + tunnel creation
├── configure-cloudflared.sh   # write /etc/cloudflared/config.yml + restart daemon
├── configure-k3s.sh           # write k3s config from env vars (etcd S3 snapshots)
├── install-keepalived.sh      # keepalived VIP setup on both Pis
├── etcd-recover.sh            # single-member etcd cluster-reset + optional rejoin
└── setup-cloudflare-dns-and-tunnel.sh  # API-token based Cloudflare bootstrap
```

## GitHub Actions workflows

All workflows run on **GitHub-hosted runners** (`ubuntu-latest`) — free because the
repo is public. They SSH to `omv` via **Tailscale** using the `TS_AUTHKEY` and
`OMV_SSH_KEY` repository secrets. Trigger any of them from the
[Actions tab](https://github.com/Themis128/OMV/actions).

| Workflow | Trigger | What it does |
|---|---|---|
| `cloudflared-login` | manual | OAuth login → create tunnel → configure cloudflared → apply Ingress → verify |
| `recover-standby` | manual | Diagnose/restart omv services; optionally etcd cluster-reset |
| `configure-cloudflared` | manual | Write config.yml + restart cloudflared (tunnel already exists) |
| `apply-cluster-manifests` | manual | `kubectl apply -f` the Ingress on the cluster |
| `rotate-k3s-credentials` | manual | Update etcd S3 AWS key in k3s config |
| `setup-cloudflare` | manual | API-token Cloudflare bootstrap (zone + tunnel, no OAuth click) |
| `omv-report` | manual / schedule | Push health + inventory report to `omv-reports` branch |
| `lint` | push / PR | yamllint, kubeconform, shellcheck, JS syntax |
| `cleanup-branches` | schedule | Delete merged branches older than 7 days |

## Quick start (on a fresh OMV Pi)

```bash
# 1) install k3s with Traefik on alt ports
sudo k3s/install.sh

# 2) bring up the cloudless namespace + ECR pull credential refresher
kubectl apply -f k3s/cloudless-app/namespace.yaml
kubectl -n cloudless create secret generic pi-standby-aws-creds \
  --from-env-file=/etc/cloudless/pi-standby.env
kubectl apply -f k3s/cloudless-app/ecr-cred-refresher.yaml
kubectl -n cloudless create job --from=cronjob/ecr-cred-refresher ecr-bootstrap

# 3) bring up the Cloudflare Tunnel for cloudless.gr (one OAuth click in browser):
#    GitHub Actions → cloudflared-login → Run workflow
#    Click the URL printed in the workflow log → pick cloudless.gr in Cloudflare.
#    The workflow creates the tunnel, routes DNS, configures cloudflared, and
#    applies the Ingress. No API token needed.

# 4) populate the app config secret (env vars — see app-config.example.yaml)
# then deploy the cloudless app:
kubectl apply -k k3s/cloudless-app/
```

## OMV host maintenance

Beyond the k3s cluster, the Pi runs OpenMediaVault. These scripts manage the
OMV host itself; all are read-only except `omv-apply-fixes.sh`.

### Health check

`scripts/omv-healthcheck.sh` runs a read-only diagnostic sweep — OMV engine
daemon, failed units, journal and kernel errors, disk usage, memory, load
average, APT repositories, logrotate, time sync, and SMART. It prints a
pass/warn/fail summary and exits non-zero if any check fails.

```bash
./scripts/omv-healthcheck.sh           # full report
./scripts/omv-healthcheck.sh --quiet   # summary only
```

### Inventory

`scripts/omv-inventory.sh` prints a full read-only inventory of the host —
hardware, OS, OMV version and plugins, storage (disks, filesystems, RAID,
mergerfs, ZFS, LVM, SMART), network, services, shares, containers, and users.

```bash
./scripts/omv-inventory.sh > inventory.txt
```

### Publish reports to GitHub

`scripts/omv-report-to-github.sh` runs the health check and inventory on the
Pi and pushes the results to a dedicated `omv-reports` branch, so the Pi's
state can be reviewed from GitHub without SSH access. Reports land under
`reports/` with timestamped and `latest-*` copies; schedule it via cron. See
the script header for the one-time deploy-key setup.

### Apply maintenance fixes

`scripts/omv-apply-fixes.sh` applies host maintenance fixes — dead APT repo
removal, `systemd-networkd-wait-online` masking, `apt-daily` timer deferral,
duplicate `fail2ban.log` logrotate stanza removal, stale Salt cache cleanup,
and failed-unit reset. Every fix is idempotent.

```bash
sudo ./scripts/omv-apply-fixes.sh --dry-run   # preview, change nothing
sudo ./scripts/omv-apply-fixes.sh             # apply
```

### Install OpenMediaVault

`scripts/omv-install.sh` installs OpenMediaVault on the `omv` NAS node. It
**refuses to run on `omv-ha`** (a 1 GB k3s/etcd node, where OMV would
OOM-kill etcd) and on any host with under 3 GiB RAM. Diagnose-only by
default.

```bash
sudo ./scripts/omv-install.sh           # diagnose, change nothing
sudo ./scripts/omv-install.sh --apply   # install OpenMediaVault
```

### Repair a broken control plane

`scripts/omv-repair.sh` diagnoses and repairs the case where the
`openmediavault` package is installed but its service units
(`openmediavault-engined`, `nginx`, `php-fpm`, `rrdcached`) are missing, so
the web UI and engine are down. It is diagnose-only by default.

```bash
sudo ./scripts/omv-repair.sh            # diagnose, change nothing
sudo ./scripts/omv-repair.sh --apply    # reinstall openmediavault and restart
```

### Prepare the HA node for k3s

`scripts/omv-ha-k3s-prep.sh` keeps `omv-ha` (a 1 GB Pi 3 running the k3s
control plane and an etcd member) lean and stable — without installing
OpenMediaVault, which would consume the RAM k3s needs. It reports power
state, memory pressure, swap, journal size, etcd snapshots and pending
upgrades; under `--apply` it caps the systemd journal (less SD-card wear)
and adds a sysctl drop-in tuned for a memory-constrained k3s node.

```bash
sudo ./scripts/omv-ha-k3s-prep.sh           # diagnose, change nothing
sudo ./scripts/omv-ha-k3s-prep.sh --apply   # apply the safe tunes
```

## Cluster facts

- k3s version: v1.35.4+k3s1 (channel: stable)
- Data dir: `/srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s` (sda1)
- Ingress controller: Traefik (default)
- Traefik listens on **18080 / 18443** (host 80/443/8080 are taken — see `docs/port-map.md`)
- Internal IP: 192.168.1.128 (LAN), 100.113.41.119 (tailnet)

## Hard rules

- Don't touch the existing Docker stack (`homepage`, `portainer`, `pihole`, `uptime-kuma`).
- Don't bind anything to host port 80, 443, or 8080.
- Don't use the AWS admin profile inside the cluster — only the scoped `cloudless-pi-standby` IAM user.
- Never commit secrets — only `.example.yaml` templates.
