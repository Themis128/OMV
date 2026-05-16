#!/usr/bin/env bash
# Recover the cloudless.online standby when it returns 5xx / Cloudflare 530.
#
# Walks the ingress stack from the outside in — node reachability, host
# services (k3s / cloudflared / tailscaled), then the k3s workloads
# (Traefik, cloudless-app) — and applies the cheapest fix at each layer.
#
# A Cloudflare 530 means the tunnel has no origin connection at all; a 502
# means the origin answered badly. Both resolve to "something on the Pi is
# down" — this script finds which layer and restarts it.
#
# Run from any host with SSH to omv (Tailscale MagicDNS works fine).
#
# Usage:
#   ./scripts/recover-standby.sh          # diagnose only, change nothing
#   ./scripts/recover-standby.sh --yes    # diagnose AND restart/roll back
#
# Env (with defaults):
#   OMV_HOST      tbaltzakis@omv
#   STANDBY_URL   https://cloudless.online/api/health
set -euo pipefail

OMV_HOST="${OMV_HOST:-tbaltzakis@omv}"
STANDBY_URL="${STANDBY_URL:-https://cloudless.online/api/health}"
APPLY=0
[[ "${1:-}" == "--yes" ]] && APPLY=1

log()  { printf '\033[1;36m[recover]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[recover] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[recover] !\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[recover] ✗\033[0m %s\n' "$*" >&2; }

sshx()  { ssh -o BatchMode=yes -o ConnectTimeout=8 "${OMV_HOST}" "$@"; }
probe() { curl -s -o /dev/null -w '%{http_code}' --max-time 12 "${STANDBY_URL}" 2>/dev/null || echo "000"; }

log "1/6  probe ${STANDBY_URL}"
code="$(probe)"
if [[ "${code}" == "200" ]]; then
  ok "standby already healthy (HTTP 200) — nothing to do"
  exit 0
fi
warn "standby returned HTTP ${code} — diagnosing"
[[ "${APPLY}" -eq 1 ]] || warn "diagnosis-only mode — re-run with --yes to apply fixes"

log "2/6  SSH reachability to ${OMV_HOST}"
if ! sshx 'echo ok' >/dev/null 2>&1; then
  fail "cannot SSH to ${OMV_HOST}."
  fail "if omv is also unreachable via Tailscale/LAN, the Pi itself is down —"
  fail "power-cycle it; k3s + cloudflared are enabled services and rejoin on boot."
  exit 1
fi
ok "omv reachable over SSH"

log "3/6  host services — k3s / cloudflared / tailscaled"
for svc in k3s cloudflared tailscaled; do
  state="$(sshx "systemctl is-active ${svc}" 2>/dev/null || true)"
  if [[ "${state}" == "active" ]]; then
    ok "${svc}: active"
  else
    warn "${svc}: ${state:-unknown}"
    if [[ "${APPLY}" -eq 1 ]]; then
      log "  restarting ${svc}"
      if sshx "sudo systemctl restart ${svc}"; then ok "  ${svc} restarted"; else fail "  ${svc} restart failed"; fi
    fi
  fi
done

log "4/6  k3s node + cloudless-app state"
sshx 'sudo k3s kubectl get nodes' 2>/dev/null || warn "kubectl get nodes failed — k3s API may be down"
app_ready="$(sshx 'sudo k3s kubectl -n cloudless get deploy cloudless-app -o jsonpath={.status.readyReplicas}' 2>/dev/null || echo "")"
log "  cloudless-app readyReplicas: ${app_ready:-0}"

log "5/6  remediate workloads"
if [[ "${APPLY}" -eq 1 ]]; then
  if [[ -z "${app_ready}" || "${app_ready}" == "0" ]]; then
    warn "  cloudless-app has no ready replicas — rolling it"
    sshx 'sudo k3s kubectl -n cloudless rollout restart deploy/cloudless-app' || true
    if ! sshx 'sudo k3s kubectl -n cloudless rollout status deploy/cloudless-app --timeout=180s'; then
      warn "  rollout did not converge — rolling back to the previous ReplicaSet"
      sshx 'sudo k3s kubectl -n cloudless rollout undo deploy/cloudless-app' || true
      sshx 'sudo k3s kubectl -n cloudless rollout status deploy/cloudless-app --timeout=180s' || true
    fi
  else
    ok "  cloudless-app already has ready replicas — leaving it alone"
  fi
else
  warn "  skipped (diagnosis-only)"
fi

log "6/6  re-probe ${STANDBY_URL}"
for _ in $(seq 1 12); do
  code="$(probe)"
  if [[ "${code}" == "200" ]]; then
    ok "standby recovered — HTTP 200"
    exit 0
  fi
  sleep 10
done
fail "standby still returning HTTP ${code} after remediation"
fail "next steps on omv:"
fail "  journalctl -u cloudflared -u k3s -n 100 --no-pager"
fail "  sudo k3s kubectl -n cloudless describe pod -l app.kubernetes.io/name=cloudless-app"
exit 1
