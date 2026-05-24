# HA architecture

```
                           DNS (cloudless.gr → Cloudflare)
                                       │
                                       ▼
                          Cloudflare edge (proxied / orange-cloud)
                                       │
                                       ▼  outbound-only WireGuard-style tunnel
                          cloudflared on omv (systemd)
                                       │
                                       ▼
                          Traefik :18443 (k3s Ingress)
                                       │
                                       ▼
                          Deployment cloudless-app
                          (2 replicas, PDB minAvailable=1, HPA → 2)

                  k3s cluster on the LAN — 2 control-plane servers, embedded etcd
                  ┌─────────────────────────────┬─────────────────────────────┐
                  │ omv  (Pi 5,  192.168.1.128) │ omv-ha (Pi 4, 192.168.1.130)│
                  │ k3s server, etcd member     │ k3s server, etcd member     │
                  │ cloudflared (active)        │ cloudflared (standby OK)    │
                  └─────────────────────────────┴─────────────────────────────┘
                                │
                                ▼
                  keepalived VIP 192.168.1.200 (LAN, MASTER=omv)
```

## Components

- **External ingress:** `cloudless.gr` is served from the Pi cluster via
  **Cloudflare Tunnel** (`cloudflared` on omv → Traefik :18443). The tunnel is
  outbound-only — no router port-forward, no WAN-IP exposure, no DDNS. Config
  is managed by `scripts/configure-cloudflared.sh`. The previously-documented
  Tailscale Funnel chain is decommissioned; the previously-documented Route 53
  health-checked failover to a direct WAN IP is decommissioned.
- **DNS authority:** `cloudless.gr` on **Cloudflare DNS** (NS delegated from the
  registrar). This repo only manages the cluster-side configuration; the
  Cloudflare zone, the AWS serverless app (CloudFront + Lambda, SST-managed in
  the cloudless.gr repo), and any failover/routing between them is out of
  scope here.
- **TLS:** cert-manager + Let's Encrypt DNS-01 with the **Cloudflare solver**
  (zone `cloudless.gr`). Prerequisite: a `cloudflare-api-token` Secret in the
  `cert-manager` namespace (see
  `k3s/cert-manager/cloudflare-api-token.example.yaml`).
- **k3s cluster:** 2 control-plane servers (`omv` + `omv-ha`) with embedded
  etcd, so cluster state is replicated. **Note:** 2-member etcd has zero
  failure tolerance (Raft needs majority); losing one node makes the
  survivor's API effectively read-only until the other returns. See
  [ha-control-plane-promotion.md](ha-control-plane-promotion.md) > *Failure
  tolerance* for the math and options for true HA.
- **VIP on the LAN:** keepalived holds `192.168.1.200` across both Pis; on
  `omv` failure it moves to `omv-ha` within seconds. Useful for LAN-side
  workloads (kubectl, local services, the omv-ha cloudflared standby).
- **Operator access:** Tailscale for SSH and the GitHub Actions
  recover/rotate workflows — no public SSH exposure. See
  `.github/workflows/recover-standby.yml`,
  `.github/workflows/configure-cloudflared.yml`,
  `.github/workflows/rotate-k3s-credentials.yml`.
- **etcd backup:** S3 snapshots to `cloudless-etcd-snapshots` every 6h (IAM
  `omv-main-cli`). Restore: snapshot from S3 + `k3s server --cluster-reset
  --cluster-reset-restore-path=…` on the survivor.
- **Image registry:** ECR `cloudless-pi-app` in us-east-1. Pulled via
  dockerconfigjson Secret refreshed by an in-cluster CronJob.

## Why k3s instead of plain Docker

- k8s manifests are portable. The same YAML applies to a future multi-node setup or a managed cluster (EKS, k3d, kind).
- cert-manager and standard Ingress patterns are simpler in k8s than rigging Caddy/Nginx + acme-dns by hand.
- The Pi's existing Docker stack (homepage, portainer, pihole, uptime-kuma) stays on Docker — no migration needed.
- 2-node embedded etcd gives control-plane HA without a separate datastore tier.
