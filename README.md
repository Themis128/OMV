# OMV — HA standby for cloudless.gr

This repository holds the infrastructure-as-code and runbooks for the **Pi 5 / OMV** node that serves as the HA standby for [cloudless.gr](https://cloudless.gr) at the domain `cloudless.online`.

The primary site (`cloudless.gr`) runs on AWS Lambda + CloudFront. The standby is a single-node **k3s** cluster on an OMV-managed Raspberry Pi 5. Route 53 health checks flip DNS to the Pi when the primary is unhealthy.

## Layout

```
k3s/
├── install.sh                 # one-shot k3s installer (idempotent)
├── traefik-config.yaml        # Traefik HelmChartConfig — binds 18080/18443
├── cloudless-app/             # the cloudless workload (Deployment/Service/Ingress)
│   ├── namespace.yaml
│   ├── ecr-cred-refresher.yaml
│   ├── app-config.example.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   └── kustomization.yaml
└── cert-manager/              # Let's Encrypt via Route 53 DNS-01
    ├── install.sh
    ├── route53-credentials.example.yaml
    └── cluster-issuer.yaml

docs/
├── ha-architecture.md         # how the failover works
├── port-map.md                # what's listening on what port
└── runbook-failover.md        # operational procedures

scripts/                       # ad-hoc helpers
```

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

# 3) install cert-manager and the Route 53 ClusterIssuer
sudo k3s/cert-manager/install.sh
# populate route53-credentials.yaml from SSM, then:
kubectl apply -f k3s/cert-manager/route53-credentials.yaml
kubectl apply -f k3s/cert-manager/cluster-issuer.yaml

# 4) populate the app config secret (env vars — see app-config.example.yaml)
# then deploy the cloudless app:
kubectl apply -k k3s/cloudless-app/
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
