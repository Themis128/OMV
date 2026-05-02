#!/usr/bin/env bash
# cloudless-playwright-synthetic — runs the playwright HA suite and emails on failure via SES.
# Wired by systemd timer cloudless-playwright-synthetic.timer (every 30 min).
# Silent on success (cron-style); on failure, sends one email to system-info@cloudless.gr.

set -u
set -o pipefail

SUITE_DIR="/home/tbaltzakis/OMV/test/playwright"
LOG_DIR="/home/tbaltzakis/.cache/cloudless-playwright"
mkdir -p "$LOG_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$LOG_DIR/run-$TS.log"

cd "$SUITE_DIR" || exit 2

# One-time install (idempotent, ~instant if node_modules exists).
if [ ! -d node_modules/playwright ]; then
  npm install --silent >>"$OUT" 2>&1 || {
    echo "npm install failed" >>"$OUT"
  }
fi

# Run the suite. Capture combined output.
node run.js >>"$OUT" 2>&1
RC=$?

# One retry on failure — guards against transient network blips
# (Starlink/Tailscale ERR_NETWORK_CHANGED, single-shot 5xx, etc.).
# Only escalate to SES if BOTH runs fail.
if [ "$RC" -ne 0 ]; then
  echo "--- attempt 1 failed (rc=$RC), retrying in 30s ---" >>"$OUT"
  sleep 30
  node run.js >>"$OUT" 2>&1
  RC=$?
fi

# Trim old logs (keep last 50 runs).
ls -1t "$LOG_DIR"/run-*.log 2>/dev/null | tail -n +51 | xargs -r rm -f

if [ "$RC" -eq 0 ]; then
  exit 0
fi

# Failure path — email via SES using cloudless-mailer creds (pulled from SSM).
export AWS_PROFILE=cloudless
export AWS_DEFAULT_REGION=us-east-1

AKID="$(aws ssm get-parameter --name /cloudless/production/mailer/aws-access-key-id \
  --query Parameter.Value --output text 2>/dev/null)"
SAK="$(aws ssm get-parameter --name /cloudless/production/mailer/aws-secret-access-key \
  --with-decryption --query Parameter.Value --output text 2>/dev/null)"

if [ -z "$AKID" ] || [ -z "$SAK" ]; then
  echo "could not fetch mailer creds; suite RC=$RC; log=$OUT" >&2
  exit "$RC"
fi

# Extract failed assertion lines.
FAILS="$(grep -E '^\s*\[FAIL\]' "$OUT" || true)"
[ -z "$FAILS" ] && FAILS="(no [FAIL] lines captured; suite exit=$RC; see full log)"

TAIL="$(tail -n 80 "$OUT")"

BODY_FILE="/tmp/cloudless-pw-body.$$"
{
  echo "cloudless-ha playwright synthetic FAILED at $TS UTC."
  echo
  echo "Host: $(hostname)"
  echo "Suite: $SUITE_DIR"
  echo "Exit code: $RC"
  echo "Log: $OUT"
  echo
  echo "Failed assertions:"
  echo "$FAILS"
  echo
  echo "--- last 80 lines of stdout ---"
  echo "$TAIL"
} >"$BODY_FILE"

python3 - "$BODY_FILE" >/tmp/cloudless-pw-msg.json <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    body = f.read()
print(json.dumps({
    "Subject": {"Data": "[cloudless-ha] playwright synthetic FAILED", "Charset": "UTF-8"},
    "Body": {"Text": {"Data": body, "Charset": "UTF-8"}},
}))
PYEOF
rm -f "$BODY_FILE"

if [ -n "${SES_DRY_RUN:-}" ]; then
  # Test mode: write the constructed message + log path, do NOT call SES.
  cp /tmp/cloudless-pw-msg.json "$LOG_DIR/last-dryrun-msg.json"
  echo "DRY-RUN: would email; msg at $LOG_DIR/last-dryrun-msg.json; suite RC=$RC; log=$OUT" >&2
else
  AWS_ACCESS_KEY_ID="$AKID" AWS_SECRET_ACCESS_KEY="$SAK" \
    aws ses send-email \
      --region us-east-1 \
      --from 'system-info@cloudless.gr' \
      --destination 'ToAddresses=system-info@cloudless.gr' \
      --message file:///tmp/cloudless-pw-msg.json >/dev/null 2>&1 || {
        echo "SES send-email failed; suite RC=$RC; log=$OUT" >&2
      }
fi

rm -f /tmp/cloudless-pw-msg.json
exit "$RC"
