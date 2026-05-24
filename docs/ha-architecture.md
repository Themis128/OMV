# HA architecture

```
                          Route 53 (cloudless.gr)
                          ┌────────────────────────┐
                          │  failover record       │
                          │  health check on /api/health │
                          └─────────┬──────────────┘
            primary healthy │       │ primary unhealthy
                            ▼       ▼
                  CloudFront alias         APIGW HTTP API → Lambda pi-proxy
                  (cloudless.gr SST)       (forwards toward the Cloudflare ingress)
                                             │
                                             ▼
                          Cloudflare → Pi cluster ingress
                            (also fronts cloudless.online direct)
                                             │
                                             ▼
                  k3s cluster on the LAN — 2 control-plane servers, embedded etcd
                  ┌─────────────────────────────┬─────────────────────────────┐
                  │ omv  (Pi 5,  192.168.1.128) │ omv-ha (Pi 4, 192.168.1.130)│
                  │ k3s server, etcd member     │ k3s server, etcd member     │
                  └─────────────────────────────┴─────────────────────────────┘
                                │
                                ▼
                          Traefik :18443  (Service / Ingress)
                                │
                                ▼
                          Deployment cloudless-app
                          (2 replicas, PDB minAvailable=1, HPA → 2)
                          (image from ECR, env from cloudless-app-config Secret)
```

The Pi runs the app continuously — it's an active/standby model where the standby is always live, just not pointed at by DNS until the primary fails.

## Components

- **Primary:** CloudFront + Lambda, deployed by SST in `cloudless.gr` repo.
- **Standby:** k3s on two Pis (`omv` + `omv-ha`), manifests in this repo (`OMV`). Both nodes run as control-plane servers with embedded etcd, so cluster state is replicated. **Note:** 2-member etcd has zero failure tolerance (Raft needs majority); losing one node makes the survivor's API effectively read-only until the other returns. See [ha-control-plane-promotion.md](ha-control-plane-promotion.md) > *Failure tolerance* for the math and options for true HA.
- **External ingress:** Cloudflare fronts `cloudless.online` directly and is also the destination of the `cloudless.gr` SECONDARY (failover) path. Live response headers on 2026-05-12 confirm `server: cloudflare`, `cf-ray: …`, with no AWS markers in the response chain for `cloudless.online`. The previously-documented Tailscale Funnel chain (`omv.tail8eb71.ts.net → socat → Traefik`) is decommissioned — the Funnel hostname returns `404 page not found` at the Tailscale edge. Exact Cloudflare integration on the Pi side (Cloudflare Tunnel via `cloudflared` vs Origin Pull) should be verified and added to this entry.
- **VIP on the LAN:** keepalived holds `192.168.1.200` across both Pis; on `omv` failure it moves to `omv-ha` within seconds. Verified end-to-end on 2026-05-11 (`cloudless.online` and `manage.cloudless.online` kept serving traffic; the kubectl API went read-only as expected for 2-member etcd).
- **etcd backup:** S3 snapshots to `cloudless-etcd-snapshots` every 6h (IAM `omv-main-cli`). Replaces the previously-considered EC2 etcd-witness plan — restore path is "snapshot from S3 + `k3s server --cluster-reset --cluster-reset-restore-path=…` on the survivor".
- **DNS authority:** `cloudless.gr` on Route 53 (Z079608614L53CC4EAZM3, SST-managed). `cloudless.online` has been migrated to **Cloudflare DNS** — the `.online` TLD now delegates to `fay.ns.cloudflare.com` / `jihoon.ns.cloudflare.com`, and its A/AAAA resolve to Cloudflare anycast (`104.21.76.32` / `172.67.186.64`, `2606:4700:…`; verified 2026-05-15). The old Route 53 zone `Z04620301I2V4SU2RF1RV` is no longer authoritative.
- **TLS:** cert-manager + Let's Encrypt DNS-01 via Route 53 for `cloudless.gr`. Works behind NAT/CGNAT because no inbound port 80 challenge is needed. `cloudless.online` is now Cloudflare-terminated — the in-cluster cert-manager ClusterIssuer (`letsencrypt-route53`) still points its DNS-01 solver at Route 53 zone `Z04620301I2V4SU2RF1RV`, which is no longer authoritative for `cloudless.online`. Certificate renewal for `cloudless.online` will fail until the solver is updated to use the Cloudflare DNS-01 provider (cert-manager `cloudflare` issuer) and the Cloudflare API token is provisioned. **TODO:** update `k3s/cert-manager/cluster-issuer.yaml` + provision `cloudflare-api-token` Secret.
- **Image registry:** ECR `cloudless-pi-app` in us-east-1. Pulled via dockerconfigjson Secret refreshed by an in-cluster CronJob.
- **DDNS for the Pi's WAN IP:** API Gateway HTTP API + Lambda (planned in build-state Phase 3) — Pi cron pings it every 5min. Original design updated a Route 53 A record for `cloudless.online`, but `cloudless.online` has since migrated to Cloudflare DNS and Route 53 is no longer authoritative. **TODO:** update the Lambda to use the Cloudflare API to update the A record, or retire DDNS in favour of a Cloudflare Tunnel (which does not require a dynamic IP update at all).
- **Failover monitor:** Lambda + EventBridge (Phase 3) checks the primary every 5min and alerts via SNS.

## Why k3s instead of plain Docker

- k8s manifests are portable. The same YAML applies to a future multi-node setup or a managed cluster (EKS, k3d, kind).
- cert-manager and standard Ingress patterns are simpler in k8s than rigging Caddy/Nginx + acme-dns by hand.
- The Pi's existing Docker stack (homepage, portainer, pihole, uptime-kuma) stays on Docker — no migration needed.
- 2-node embedded etcd gives control-plane HA without a separate datastore tier.
