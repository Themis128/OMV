# Claude Code Instructions for Themis128/OMV

## Workflow

- When fixing issues: fix, test, and **merge directly to `main`** — do not create pull requests.

## Notion — Manual Config Tasks

Whenever a task or issue is identified that requires **manual configuration** (GitHub secrets,
repo variables, SSH keys, OAuth credentials, cloud console actions, DNS changes, etc.) and
cannot be automated from Claude Code, **always create a Notion task before ending the turn**:

- Database: Tasks (`collection://58a87b58-e972-4324-9b22-728672b61a95`)
- Properties: `Status=To Do`, `Type=Chore`, `Priority` (Urgent/High/Medium), `Labels` as appropriate
- Content: full step-by-step instructions so the task is self-contained

## Triggering GitHub Actions workflows

The GitHub MCP server has no `workflow_dispatch` tool. Instead, push an update to the
corresponding dispatch file under `.github/dispatches/` — the workflow triggers on that push.

To trigger a workflow, update `triggered_at` in the JSON file and push to main:

| Dispatch file | Workflow | Notes |
|---|---|---|
| `.github/dispatches/provision-cert-manager.json` | provision-cert-manager | Uses `CLOUDFLARE_API_TOKEN` secret |
| `.github/dispatches/apply-cluster-manifests.json` | apply-cluster-manifests | No inputs |
| `.github/dispatches/recover-standby.json` | recover-standby | Set `apply/etcd_recover/omv_ha_prep/node_cleanup/k3s_rejoin/demote_ha_to_agent` |
| `.github/dispatches/configure-cloudflared.json` | configure-cloudflared | Set `hostnames/tunnel_name` |
| `.github/dispatches/rotate-k3s-credentials.json` | rotate-k3s-credentials | Uses `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` secrets |
| `.github/dispatches/setup-cloudflare.json` | setup-cloudflare | Uses `CLOUDFLARE_API_TOKEN` secret |
| `.github/dispatches/cleanup-branches.json` | cleanup-branches | Set `branches` or leave empty for default list |
| `.github/dispatches/authorize-ssh-key.json` | authorize-ssh-key | Set `public_key` to full pub key string |
| `.github/dispatches/setup-tailscale-oauth.json` | setup-tailscale-oauth | Requires `TS_API_KEY` repo secret (Tailscale personal API key) |
| `.github/dispatches/deploy-cloudflare-worker.json` | deploy-cloudflare-worker | Requires `CLOUDFLARE_API_TOKEN` secret + `CLOUDFLARE_ACCOUNT_ID` + `AWS_CLOUDFRONT_HOST` variables |
| `.github/dispatches/cleanup-disk.json` | cleanup-disk | Docker prune + logrotate fix + monit fix + unattended-upgrades + reset failed units on omv |
| `.github/dispatches/tune-k3s-config.json` | tune-k3s-config | Apply kubelet GC, log rotation, eviction, etcd retention to k3s config |
| `.github/dispatches/configure-workloads.json` | configure-workloads | Patch ntfy + alertmanager resource limits on the live cluster |
| `.github/dispatches/install-cloudflared-ha.json` | install-cloudflared-ha | Install cloudflared on omv-ha + copy tunnel credentials from omv |
| `.github/dispatches/restart-runners.json` | restart-runners | Set `OMV2_SSH_HOST` + `OMV3_SSH_HOST` repo vars first; skips nodes with unset vars |
| `.github/dispatches/provision-cognito-admin.json` | provision-cognito-admin | Set `email` + optional `group`; requires `AdminCreateUser`+`AdminAddUserToGroup` IAM first; posts temp password to issue #66 |
| `.github/dispatches/apply-github-secrets-from-ssm.json` | apply-github-secrets-from-ssm | Reads `cloudless-ops` keys from SSM `/sst/cloudless/github/*` via OIDC → stores as GitHub secrets. Requires OIDC trust policy fix + SSM params (see Notion) |
| `.github/dispatches/sync-cognito-config.json` | sync-cognito-config | Reads pool-id + client-id from SSM `/cloudless/production/cognito/*` via OIDC → patches `cloudless-app-config` k8s secret + restarts deployment. Requires IAM `ssm:GetParameter` on that path (see Notion) |

**Custom slash commands** (`.claude/commands/`):
- `/trigger <workflow>` — update the dispatch file and push to trigger a workflow
- `/ssh-setup` — walk through adding a local public key to omv's authorized_keys
- `/workflow-status` — how to check a workflow run result and re-trigger after a fix
- `/watch-run [run_id]` — poll a workflow run until complete and diagnose failures
- `/omv-report [ha|both]` — read latest inventory from omv-reports branch with disk + service summary

## Architecture

- **`cloudless.gr` on the Pi k3s cluster**: served via Cloudflare Tunnel (`cloudflared`) → Traefik :18443.
  Public TLS is handled by Cloudflare Universal SSL automatically; the origin leg uses
  `noTLSVerify: true`, so Traefik's default self-signed cert is fine and **cert-manager is
  not required**. No port forwarding, no Route 53 DNS-based failover, no direct WAN IP
  exposure. HA is intra-cluster: keepalived VIP + k3s agent on omv-ha.
- **AWS serverless app (cloudless.gr CloudFront + Lambda, SST-managed)**: stays as it is — out of
  scope for this repo. The Pi cluster is the active origin for `cloudless.gr`; the AWS
  serverless stack is the failover origin via the Cloudflare Worker.
- **Cloudflare Worker failover** (`cloudflare/worker-failover.js`): deployed at `cloudless.gr/*`.
  Proxies to Pi cluster via `pi-origin.cloudless.gr` (CF Tunnel backend). On 5xx/timeout falls
  back to `AWS_FALLBACK_HOST` (CloudFront). Worker is NOT yet live — needs `CLOUDFLARE_ACCOUNT_ID`
  and `AWS_CLOUDFRONT_HOST` repo variables set first, then trigger `deploy-cloudflare-worker`.
- **k3s cluster topology**: omv (Pi 5, 8GB) = server + worker. omv-ha (Pi 4, 1GB) = agent only
  (demoted from server 2026-05-24 — fixes 2-node etcd quorum problem). NFS-backed workloads
  (ntfy, alertmanager) stay pinned to omv-ha via `nodeSelector: kubernetes.io/hostname: omv-ha`
  (Pi 5 kernel 6.12 has broken NFS RPC; Pi 4 kernel works fine).
