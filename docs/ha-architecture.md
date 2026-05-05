# HA architecture

```
                          Route 53 (cloudless.gr)
                          ┌────────────────────────┐
                          │  failover record       │
                          │  health check on /api/health │
                          └─────────┬──────────────┘
            primary healthy │       │ primary unhealthy
                            ▼       ▼
                  CloudFront alias         A record → home WAN IP
                  (cloudless.gr SST)         │
                                             ▼
                          home router (NAT)
                            external 443 ─→ 192.168.1.128:18443
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
- **DNS authority:** Route 53 zones — `cloudless.gr` (Z079608614L53CC4EAZM3, SST-managed) and `cloudless.online` (Z04620301I2V4SU2RF1RV, this project).
- **TLS:** cert-manager + Let's Encrypt DNS-01 via Route 53. Works behind NAT/CGNAT because no inbound port 80 challenge is needed.
- **Image registry:** ECR `cloudless-pi-app` in us-east-1. Pulled via dockerconfigjson Secret refreshed by an in-cluster CronJob.
- **DDNS for the Pi's WAN IP:** API Gateway HTTP API + Lambda (planned in build-state Phase 3) — Pi cron pings it every 5min, Lambda updates the Route 53 A record for `cloudless.online`.
- **Failover monitor:** Lambda + EventBridge (Phase 3) checks the primary every 5min and alerts via SNS.

## Why k3s instead of plain Docker

- k8s manifests are portable. The same YAML applies to a future multi-node setup or a managed cluster (EKS, k3d, kind).
- cert-manager and standard Ingress patterns are simpler in k8s than rigging Caddy/Nginx + acme-dns by hand.
- The Pi's existing Docker stack (homepage, portainer, pihole, uptime-kuma) stays on Docker — no migration needed.
- 2-node embedded etcd gives control-plane HA without a separate datastore tier.
