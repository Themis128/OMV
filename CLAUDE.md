# Claude Code Instructions for Themis128/OMV

## Workflow

- When fixing issues: fix, test, and **merge directly to `main`** — do not create pull requests.

## Architecture

- **`cloudless.gr` on the Pi k3s cluster**: served via Cloudflare Tunnel (`cloudflared`) → Traefik :18443.
  Public TLS is handled by Cloudflare Universal SSL automatically; the origin leg uses
  `noTLSVerify: true`, so Traefik's default self-signed cert is fine and **cert-manager is
  not required**. No port forwarding, no Route 53 DNS-based failover, no direct WAN IP
  exposure. HA is intra-cluster: keepalived VIP + 2-node embedded etcd.
- **AWS serverless app (cloudless.gr CloudFront + Lambda, SST-managed)**: stays as it is — out of
  scope for this repo. The Pi cluster is the active origin for `cloudless.gr`; the AWS
  serverless stack is the user's separate concern and is not touched by changes in this repo.
