Trigger a GitHub Actions workflow by updating its dispatch file and pushing to main.

Usage: /trigger <workflow-name> [key=value ...]

Available workflows and their inputs:

| Workflow | Dispatch file | Key inputs |
|---|---|---|
| provision-cert-manager | .github/dispatches/provision-cert-manager.json | skip_issuer (default: false) |
| apply-cluster-manifests | .github/dispatches/apply-cluster-manifests.json | none |
| recover-standby | .github/dispatches/recover-standby.json | apply (default: true), etcd_recover (default: false), omv_ha_prep (default: false) |
| configure-cloudflared | .github/dispatches/configure-cloudflared.json | hostnames (default: cloudless.gr,manage.cloudless.gr), tunnel_name (default: cloudless) |
| rotate-k3s-credentials | .github/dispatches/rotate-k3s-credentials.json | verify_snapshot (default: false) — keys come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY secrets |
| setup-cloudflare | .github/dispatches/setup-cloudflare.json | zone, tunnel_name, wait_for_ns — token from CLOUDFLARE_API_TOKEN secret |
| cleanup-branches | .github/dispatches/cleanup-branches.json | branches (comma-separated, empty = use default stale list) |
| authorize-ssh-key | .github/dispatches/authorize-ssh-key.json | public_key (required — paste full pub key contents) |

Steps:
1. Read the dispatch file for the requested workflow.
2. Update `triggered_at` to the current ISO timestamp.
3. Update any `inputs` fields the user specified.
4. Commit the change with message `chore: trigger <workflow-name> workflow`.
5. Push to main — the workflow will start within seconds.

Never store sensitive values (tokens, passwords) in dispatch files. Sensitive inputs come from repo secrets automatically.
