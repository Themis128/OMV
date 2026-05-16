#!/usr/bin/env bash
#
# omv-report-to-github.sh — run the OMV health check + inventory and publish
# the results to the GitHub repository.
#
# Run this ON THE PI. It generates plain-text reports and pushes them to a
# dedicated 'omv-reports' branch, so the Pi's state can be reviewed from
# GitHub without anyone needing SSH access to the Pi.
#
# ---------------------------------------------------------------------------
# One-time setup on the Pi
# ---------------------------------------------------------------------------
#   1. Clone the repo:
#        git clone git@github.com:Themis128/OMV.git ~/OMV
#
#   2. Give the Pi push access. Easiest is a deploy key reusing the Pi's
#      existing SSH key:
#        cat ~/.ssh/id_ed25519.pub
#      Add that key at:  GitHub repo -> Settings -> Deploy keys -> Add deploy
#      key -> tick "Allow write access".
#      (Make sure the clone uses the SSH URL, as in step 1.)
#
#   3. Run this script from inside the clone:
#        ~/OMV/scripts/omv-report-to-github.sh
#
# To run it automatically, add a cron entry, e.g. daily at 07:00:
#   0 7 * * * /home/tbaltzakis/OMV/scripts/omv-report-to-github.sh >> \
#             /var/log/omv-report.log 2>&1
#
# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
#   OMV_REPORT_BRANCH   branch to publish reports to (default: omv-reports)
#
# Exit code: 0 on success, non-zero on failure.

set -u

BRANCH="${OMV_REPORT_BRANCH:-omv-reports}"
TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname)"

# ESC byte for stripping ANSI colour codes from the captured reports.
ESC="$(printf '\033')"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_DIR" ]; then
    echo "ERROR: not inside a git clone of the OMV repo." >&2
    echo "See the one-time setup notes at the top of this script." >&2
    exit 1
fi

ORIGIN_URL="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)"
if [ -z "$ORIGIN_URL" ]; then
    echo "ERROR: the repo has no 'origin' remote to push to." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Generate the reports --------------------------------------------------
echo "Generating health check..."
bash "$SCRIPT_DIR/omv-healthcheck.sh" 2>&1 | sed "s/${ESC}\[[0-9;]*m//g" \
    > "$WORK/healthcheck.txt"

echo "Generating inventory..."
bash "$SCRIPT_DIR/omv-inventory.sh" 2>&1 | sed "s/${ESC}\[[0-9;]*m//g" \
    > "$WORK/inventory.txt"

# --- Publish to the reports branch -----------------------------------------
echo "Publishing to branch '$BRANCH'..."
CLONE="$WORK/repo"
if ! git clone --quiet "$ORIGIN_URL" "$CLONE"; then
    echo "ERROR: could not clone $ORIGIN_URL — check the Pi's push access." >&2
    exit 1
fi
cd "$CLONE"

if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    # Branch exists — check it out and add to it.
    git checkout --quiet "$BRANCH"
else
    # First run — create an orphan branch holding only reports.
    git checkout --quiet --orphan "$BRANCH"
    git rm -rf --quiet . >/dev/null 2>&1 || true
fi

mkdir -p reports
cp "$WORK/healthcheck.txt" "reports/healthcheck-$TS.txt"
cp "$WORK/inventory.txt"   "reports/inventory-$TS.txt"
cp "$WORK/healthcheck.txt" "reports/latest-healthcheck.txt"
cp "$WORK/inventory.txt"   "reports/latest-inventory.txt"

git add reports
if git diff --cached --quiet; then
    echo "No changes since the last report — nothing to publish."
    exit 0
fi

git -c user.name="omv-reporter" -c user.email="omv-reporter@${HOST}" \
    commit --quiet -m "OMV report ${TS} from ${HOST}"

if ! git push --quiet origin "$BRANCH"; then
    echo "ERROR: push to origin/$BRANCH failed — check the Pi's write access." >&2
    exit 1
fi

echo "Done. Reports published to the '$BRANCH' branch:"
echo "  reports/latest-healthcheck.txt"
echo "  reports/latest-inventory.txt"
echo "  reports/healthcheck-$TS.txt"
echo "  reports/inventory-$TS.txt"
