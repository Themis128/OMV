# Claude Code Instructions for Themis128/OMV

## Workflow

- When fixing issues: fix, test, and **merge directly to `main`** — do not create pull requests.

## Triggering GitHub Actions workflows

The GitHub MCP server has no `workflow_dispatch` tool. Instead, push an update to the
corresponding dispatch file under `.github/dispatches/` — the workflow triggers on that push.

To trigger a workflow, update `triggered_at` in the JSON file and push to main:

| Dispatch file | Workflow | Notes |
|---|---|---|
| `.github/dispatches/provision-cert-manager.json` | provision-cert-manager | Uses `CLOUDFLARE_API_TOKEN` secret |
| `.github/dispatches/apply-cluster-manifests.json` | apply-cluster-manifests | No inputs |
| `.github/dispatches/recover-standby.json` | recover-standby | Set `apply/etcd_recover/omv_ha_prep` |
| `.github/dispatches/configure-cloudflared.json` | configure-cloudflared | Set `hostnames/tunnel_name` |
| `.github/dispatches/rotate-k3s-credentials.json` | rotate-k3s-credentials | Uses `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` secrets |
| `.github/dispatches/setup-cloudflare.json` | setup-cloudflare | Uses `CLOUDFLARE_API_TOKEN` secret |
| `.github/dispatches/cleanup-branches.json` | cleanup-branches | Set `branches` or leave empty for default list |
| `.github/dispatches/authorize-ssh-key.json` | authorize-ssh-key | Set `public_key` to full pub key string |
| `.github/dispatches/setup-tailscale-oauth.json` | setup-tailscale-oauth | Requires `TS_API_KEY` repo secret (Tailscale personal API key) |

**Custom slash commands** (`.claude/commands/`):
- `/trigger <workflow>` — update the dispatch file and push to trigger a workflow
- `/ssh-setup` — walk through adding a local public key to omv's authorized_keys
- `/workflow-status` — how to check a workflow run result and re-trigger after a fix

## Architecture

- **`cloudless.gr` on the Pi k3s cluster**: served via Cloudflare Tunnel (`cloudflared`) → Traefik :18443.
  Public TLS is handled by Cloudflare Universal SSL automatically; the origin leg uses
  `noTLSVerify: true`, so Traefik's default self-signed cert is fine and **cert-manager is
  not required**. No port forwarding, no Route 53 DNS-based failover, no direct WAN IP
  exposure. HA is intra-cluster: keepalived VIP + 2-node embedded etcd.
- **AWS serverless app (cloudless.gr CloudFront + Lambda, SST-managed)**: stays as it is — out of
  scope for this repo. The Pi cluster is the active origin for `cloudless.gr`; the AWS
  serverless stack is the user's separate concern and is not touched by changes in this repo.
