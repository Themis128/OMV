Check the status of a recent GitHub Actions workflow run.

The GitHub MCP server does not have a workflow-runs API tool, so status cannot be
fetched programmatically. Guide the user to check directly:

1. Open: https://github.com/themis128/omv/actions
2. Find the workflow by name in the left sidebar.
3. Click the most recent run to see logs.

If the user pastes a failure log, diagnose and fix the issue:
- SSH connection refused → run /ssh-setup to authorize the key
- kubectl error → check if cert-manager namespace exists: sudo k3s kubectl get ns
- Tailscale timeout → check TS_OAUTH_CLIENT_ID / TS_OAUTH_SECRET secrets are set
- Secret not found → verify the secret name in Settings → Secrets → Actions

To re-trigger a workflow after fixing an issue, use /trigger <workflow-name>.
