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
| `.github/dispatches/recover-standby.json` | recover-standby | **Historical** — no standby node exists (single-node since 2026-08-08). Kept for reference only |
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
| `.github/dispatches/install-cloudflared-ha.json` | install-cloudflared-ha | **Historical for k3s HA** — omv-ha is a mail host now; its cloudflared serves webmail.cloudless.gr, not cluster failover |
| `.github/dispatches/restart-runners.json` | restart-runners | Set `OMV2_SSH_HOST` + `OMV3_SSH_HOST` repo vars first; skips nodes with unset vars |
| `.github/dispatches/provision-cognito-admin.json` | provision-cognito-admin | **Historical** — Cognito retired; auth is Cloudflare D1 (`user-auth-db`). Use `POST /api/admin/users` promote flow instead |
| `.github/dispatches/apply-github-secrets-from-ssm.json` | apply-github-secrets-from-ssm | Reads `cloudless-ops` keys from SSM `/sst/cloudless/github/*` via OIDC → stores as GitHub secrets. Requires OIDC trust policy fix + SSM params (see Notion) |
| `.github/dispatches/stabilize-tailscale.json` | stabilize-tailscale | OOM hardening + Restart=always. "Both nodes" = omv (k3s) + omv-ha (mail host, host-level only — not a cluster peer). Set `apply=true/false`, `skip_omv_ha=true` if omv-ha unreachable. Requires `OMV_HA_SSH_HOST` repo var + `OMV_HA_SSH_KEY` secret |
| `.github/dispatches/register-tailscale-nodes.json` | register-tailscale-nodes | Migrate omv + omv-ha to themis128.github tailnet (omv-ha = mail host). Verify tailnet state before re-running — likely already done. Requires `TS_AUTHKEY` + `TS_NEW_AUTHKEY` secrets |
| `.github/dispatches/generate-ts-authkey.json` | generate-ts-authkey | Generate `TS_NEW_AUTHKEY` via Tailscale API + auto-trigger register-tailscale-nodes. Requires `TS_API_KEY` + `GH_PAT` secrets |
| `.github/dispatches/approve-tailscale-subnet-route.json` | approve-tailscale-subnet-route | Enable 192.168.1.0/24 subnet route for omv via Tailscale API. Requires `TS_API_KEY` secret (personal API access token from https://login.tailscale.com/admin/settings/keys) |

**Custom slash commands** (`.claude/commands/`):
- `/trigger <workflow>` — update the dispatch file and push to trigger a workflow
- `/ssh-setup` — walk through adding a local public key to omv's authorized_keys
- `/workflow-status` — how to check a workflow run result and re-trigger after a fix
- `/watch-run [run_id]` — poll a workflow run until complete and diagnose failures
- `/omv-report [ha|both]` — read latest inventory from omv-reports branch with disk + service summary

## Git and GitHub Push

- **Direct `git push` returns HTTP 403** in this environment — all pushes must use `mcp__github__push_files`
- After every MCP push, sync local: `git fetch origin main && git reset --hard origin/main`
- **`github.token` + `id-token: write` = 403** on issue comments — pass `GH_PAT` via the `token` input on `.github/actions/post-status`

## Architecture

- **`cloudless.gr` on the Pi k3s cluster**: served via Cloudflare Tunnel (`cloudflared`) → Traefik :18443.
  Public TLS is handled by Cloudflare Universal SSL automatically; the origin leg uses
  `noTLSVerify: true`, so Traefik's default self-signed cert is fine and **cert-manager is
  not required**. No port forwarding, no Route 53 DNS-based failover, no direct WAN IP
  exposure. **Single-node since 2026-08-08** — no intra-cluster HA; the
  keepalived/etcd-peer docs in `docs/` are historical.
- **AWS serverless app (cloudless.gr CloudFront + Lambda, SST-managed)**: stays as it is — out of
  scope for this repo. The Pi cluster is the active origin for `cloudless.gr`; the AWS
  serverless stack is the failover origin via the Cloudflare Worker.
- **Cloudflare Worker failover** (`cloudflare/worker-failover.js`): proxies to Pi cluster via
  `pi-origin.cloudless.gr` (CF Tunnel backend) → k3s `cloudless-app` on omv. Live edge is the
  `cloudless2` Worker (reverse proxy only, no app secrets) per cloudless.gr repo rules.
- **k3s cluster topology (current)**: omv (Pi 5, 8GB) is the ONLY k3s node — server + worker,
  embedded etcd single-member. `omv-ha` (Pi 4) was drained and removed from k3s on 2026-08-08
  and repurposed as a dedicated mail host (webmail.cloudless.gr). All former omv-ha workloads
  (traefik, tailscale operator, postiz-redis, ntfy, alertmanager, etc.) now run on omv;
  local-path PVCs are omv-local. The Nextcloud workspace (cloud/office/signal.cloudless.gr)
  is plain Docker Compose on omv's sdb1 data SSD — NOT k3s; sources in
  `Themis128/cloudless-nextcloud`.
