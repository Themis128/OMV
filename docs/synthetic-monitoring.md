# Synthetic monitoring (playwright)

End-to-end checks against both the AWS main (`cloudless.gr`) and the Pi
standby (`cloudless.online`). Runs every 30 minutes on the Pi via a user
systemd timer. Silent on success; pages by SES email on failure.

## What it covers

[`test/playwright/run.js`](../test/playwright/run.js) — 30 assertions across:

- **Backend (5×2)** — `/api/health` returns 200 with `{status:'ok', timestamp, version}`; `/` returns `307 → /en`.
- **Frontend (8×2)** — page loads on `/en`, has `<title>`, body renders text, no console errors, no first-party request failures, screenshot captured.
- **Infra (1×2)** — TLS handshake (inferred from successful HTTPS GETs).
- **HA parity (2)** — `version` and `<title>` must match across main and standby.

Filtered noise: 3rd-party widgets (Sentry/HubSpot/Stripe/Facebook/typekit) and benign Next.js `_rsc=` prefetch aborts on `networkidle`.

## How it runs

| Component | Path | Purpose |
|---|---|---|
| Test suite | [`test/playwright/run.js`](../test/playwright/run.js) | The actual playwright assertions. |
| Wrapper | [`test/playwright/run-and-mail.sh`](../test/playwright/run-and-mail.sh) | Runs the suite, retries once on failure, emails via SES on persistent failure. |
| Timer | `~/.config/systemd/user/cloudless-playwright-synthetic.timer` | `OnCalendar=*:0/30`, `Persistent=true`, `RandomizedDelaySec=60`. |
| Service | `~/.config/systemd/user/cloudless-playwright-synthetic.service` | `Type=oneshot`, `SuccessExitStatus=0 1` (wrapper owns notification). |
| Logs | `~/.cache/cloudless-playwright/run-*.log` | Last 50 runs retained; rotation in the wrapper. |

The wrapper retries the suite once after 30s on the first failure — guards against transient `ERR_NETWORK_CHANGED` (Starlink/Tailscale interface flaps) and one-shot 5xx blips. Only escalates if **both** runs fail.

SES creds are pulled at runtime from SSM (`/cloudless/production/mailer/aws-{access-key-id,secret-access-key}`). Nothing on disk. Sender + recipient: `system-info@cloudless.gr`. Subject: `[cloudless-ha] playwright synthetic FAILED`. Body includes the failed assertion lines and the last 80 lines of stdout.

## Operate

```bash
# State
systemctl --user list-timers cloudless-playwright-synthetic.timer
systemctl --user status cloudless-playwright-synthetic.{timer,service}

# Pause / resume
systemctl --user stop cloudless-playwright-synthetic.timer
systemctl --user start cloudless-playwright-synthetic.timer

# Disable permanently
systemctl --user disable --now cloudless-playwright-synthetic.timer

# Run on demand
~/OMV/test/playwright/run-and-mail.sh

# Run on demand without sending an SES email (for testing the fail path)
SES_DRY_RUN=1 ~/OMV/test/playwright/run-and-mail.sh
# → constructed message lands at ~/.cache/cloudless-playwright/last-dryrun-msg.json
```

## Test the alert path

```bash
# Temporarily point the suite at an invalid host, then dry-run.
sed -i.bak 's|cloudless\.gr|cloudless.gr.invalid|; s|cloudless\.online|cloudless.online.invalid|' \
  ~/OMV/test/playwright/run.js
SES_DRY_RUN=1 ~/OMV/test/playwright/run-and-mail.sh
mv ~/OMV/test/playwright/run.js.bak ~/OMV/test/playwright/run.js
cat ~/.cache/cloudless-playwright/last-dryrun-msg.json | python3 -m json.tool
```

To send a real test email, drop `SES_DRY_RUN=1`. The SES sender (`system-info@cloudless.gr`) is verified; recipient is the same address.

## Failure modes & response

| Symptom | Cause | Response |
|---|---|---|
| Email: `health reachable: ENOTFOUND` for both targets | DNS / Starlink down | Check Pi WAN; verify Tailscale (`tailscale status`). |
| Email: `health reachable` for **standby only** | Cloudflare/origin path broken, or Pi k3s app crashed | `curl -I https://cloudless.online/api/health`, `kubectl -n cloudless get pods,ing`, check `cloudflared` on `omv` if used. See [runbook-failover.md](runbook-failover.md). |
| Email: `health reachable` for **main only** | AWS Lambda / CloudFront issue | Check AWS console; HA failover may already be active. |
| Email: HA parity (version mismatch) | Pi standby out of date — image-sync stuck | `kubectl -n cloudless get cronjob image-sync`, `kubectl -n cloudless logs job/$(kubectl -n cloudless get jobs ... )` |
| Email: HA parity (title mismatch) | One side serving a different build/branch | Same as above; check sync-webhook + last config-sync run. |
| `SES send-email failed` in stderr (visible in `journalctl --user -u cloudless-playwright-synthetic`) | SSM creds missing or SES revoked | `aws ssm get-parameter --name /cloudless/production/mailer/aws-access-key-id --profile cloudless`; verify `cloudless-mailer` IAM user still active. |

## Cost

Zero direct cost. SES emails ~0–48/day at most (only on failures). Well under the SES free tier. Compute is local on the Pi.

## Why a Pi systemd timer (not a remote agent)

The cloud `RemoteTrigger` routine system has a 1-hour minimum cadence and no path to reach the Pi from outside the tailnet. A user systemd timer on the Pi with `loginctl enable-linger` survives logout/reboot, fires every 30 min, and runs as the same user that owns the suite — simpler and faster.
