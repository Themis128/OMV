Poll a GitHub Actions workflow run until it completes, then report results.

Usage: /watch-run <run_id>
       /watch-run                 ← polls the most recent run across all workflows

## Steps

1. If no run_id given, call mcp__github__actions_list with:
   - method: list_workflow_runs
   - owner: themis128 / repo: omv
   - per_page: 1
   Find the most recent run (first element). Use its id.

2. Call mcp__github__actions_get with:
   - method: get_workflow_run
   - owner: themis128 / repo: omv
   - resource_id: <run_id>

3. If status is "in_progress" or "queued":
   - Call mcp__github__actions_list method: list_workflow_jobs with resource_id: <run_id>
   - Report which step is currently running and how long it has been running
     (current time minus step started_at)
   - Tell the user: "Still running — ask me again in a minute to re-check."
   - STOP — do not loop or sleep.

4. If status is "completed":
   a. Report conclusion (success / failure / cancelled) and total duration
      (updated_at minus run_started_at).
   b. If conclusion is "failure":
      - Call mcp__github__get_job_logs with run_id, failed_only: true,
        return_content: true, tail_lines: 80
      - Diagnose the error. Common patterns:
        * "dial tcp 127.0.0.1:6443: connection refused" → k3s API down → run /trigger recover-standby
        * "SSH connection refused / timeout" → omv unreachable → check Tailscale / run /ssh-setup
        * "No such file or directory" on a manifest → missing kustomization file
        * "ImagePullBackOff / unauthorized" → ECR credentials stale → run /trigger rotate-k3s-credentials
      - Propose the fix.
   c. If conclusion is "success":
      - For omv-report runs: offer to run /omv-report to read the published inventory.
      - For apply-cluster-manifests: confirm manifests applied and offer /omv-report to verify pods.
      - For recover-standby: confirm k3s is back; offer to re-trigger apply-cluster-manifests.
