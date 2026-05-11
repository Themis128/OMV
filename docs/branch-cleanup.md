# Runbook — branch cleanup

The `cleanup-branches` GitHub Actions workflow
(`.github/workflows/cleanup-branches.yml`) keeps stale branches off origin
without needing a shell on your laptop. It uses the auto-issued
`GITHUB_TOKEN` (`contents: write`), so no PATs and no AWS Secrets Manager
fetch are involved.

## What it covers

| Case | How it gets deleted |
|---|---|
| Branch was the head of a merged PR | Auto-deleted on PR merge |
| Branch was an orphan (no PR) on the default stale list | Auto-deleted when the workflow first lands on main, and on any future edit of the workflow file |
| Any branch you want gone right now | Manual: Actions → cleanup-branches → Run workflow, paste a comma list |

It refuses to delete `main`, `develop`, or any `release/*` branch.

## Manual cleanup from the web

1. Open
   [`Actions → cleanup-branches`](https://github.com/Themis128/OMV/actions/workflows/cleanup-branches.yml).
2. Click **Run workflow**.
3. (Optional) Paste a comma-separated branch list, e.g.
   `claude/fix-foo,claude/old-experiment`. Empty input falls back to the
   default stale list at the top of the workflow file.

This works from any browser, including GitHub mobile — no SSH or PC access
needed.

## Updating the default stale list

The default list of orphan branches lives in the `DEFAULT=` line of the
`bulk-cleanup` job. To add or remove entries:

1. Edit `.github/workflows/cleanup-branches.yml`.
2. Open a PR and merge.

The `push: paths: [...]` trigger fires on the merge and the new list runs
through cleanup automatically.

## How the bootstrap run works

The push trigger is path-filtered to the workflow file itself. So the
first time the workflow lands on main (this PR's merge), the file gets
modified on main, which fires the push event, which runs `bulk-cleanup`
with the default list. That clears the 7 stale branches that accumulated
before this workflow existed.

After that, the push trigger only fires on subsequent edits of the workflow
file — never on unrelated pushes.
