Check the result of recent GitHub Actions workflow runs by reading the status board issue.

Every workflow posts a pass/fail comment to issue #66 after each run.

Steps:
1. Call mcp__github__issue_read with:
   - owner: themis128
   - repo: omv
   - issue_number: 66
   - method: get_comments
   - perPage: 10  (most recent 10 results)

2. Show the user the most recent comments, newest first (reverse the list).

3. If a workflow failed, diagnose from the comment and offer to fix:
   - SSH error → run /ssh-setup
   - kubectl / cert-manager error → re-trigger after fixing the root cause
   - Tailscale timeout → check TS_OAUTH_CLIENT_ID / TS_OAUTH_SECRET secrets
   - Secret not found → check Settings → Secrets → Actions

4. To re-trigger a fixed workflow, use /trigger <workflow-name>.
