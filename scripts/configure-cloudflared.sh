#!/usr/bin/env bash
# Configure cloudflared on this Pi to serve cloudless.gr via Cloudflare
# Tunnel → local Traefik :18443. Idempotent.
#
# The tunnel is an outbound-only WireGuard-like connection from the Pi to
# Cloudflare's edge — no router port-forward is needed, the Pi's WAN IP is
# never exposed, and there is no DDNS to maintain.
#
# Pre-requisites:
#   * cloudflared installed and the tunnel created (one-time, via the
#     Cloudflare dashboard or `cloudflared tunnel login && cloudflared tunnel create`).
#   * The tunnel's credentials JSON in /etc/cloudflared/<tunnel-uuid>.json.
#   * `cloudless.gr` zone delegated to Cloudflare DNS (NS change at the
#     registrar — out of scope for this script).
#
# Run as root on omv (and on omv-ha if you want both nodes to register the
# tunnel — only one needs to, the other can rely on the keepalived VIP):
#   sudo ./scripts/configure-cloudflared.sh
#
# Env (all have defaults):
#   TUNNEL_NAME      cloudless                (Cloudflare Tunnel name)
#   HOSTNAMES        cloudless.gr,manage.cloudless.gr
#   ORIGIN_SERVICE   https://localhost:18443  (Traefik websecure entrypoint)
#   CONFIG_FILE      /etc/cloudflared/config.yml
#   ROUTE_DNS        1   — also create the Cloudflare DNS CNAME records
#                         (requires `cloudflared` logged in with edit-DNS perms)

set -euo pipefail

TUNNEL_NAME="${TUNNEL_NAME:-cloudless}"
HOSTNAMES="${HOSTNAMES:-cloudless.gr,manage.cloudless.gr}"
ORIGIN_SERVICE="${ORIGIN_SERVICE:-https://localhost:18443}"
CONFIG_FILE="${CONFIG_FILE:-/etc/cloudflared/config.yml}"
ROUTE_DNS="${ROUTE_DNS:-1}"

log()  { printf '\033[1;36m[cloudflared]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[cloudflared] ✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[cloudflared] ✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root (sudo)"
command -v cloudflared >/dev/null 2>&1 || fail "cloudflared is not installed"

# Resolve the tunnel UUID. The 3rd column of `cloudflared tunnel list` is the
# name; the 1st is the UUID.
TUNNEL_UUID="$(cloudflared tunnel list 2>/dev/null \
  | awk -v n="${TUNNEL_NAME}" '$2==n {print $1; exit}')"
[[ -n "${TUNNEL_UUID}" ]] || fail "tunnel '${TUNNEL_NAME}' not found — create it first"
ok "tunnel ${TUNNEL_NAME} = ${TUNNEL_UUID}"

CREDS_FILE="/etc/cloudflared/${TUNNEL_UUID}.json"
[[ -f "${CREDS_FILE}" ]] || fail "credentials file ${CREDS_FILE} missing"

# --- Write the config -------------------------------------------------------
log "writing ${CONFIG_FILE}"
install -d -m 0755 "$(dirname "${CONFIG_FILE}")"
[[ -f "${CONFIG_FILE}" ]] && cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%dT%H%M%S)"

{
  printf 'tunnel: %s\n' "${TUNNEL_UUID}"
  printf 'credentials-file: %s\n' "${CREDS_FILE}"
  printf 'no-autoupdate: true\n'
  printf '\ningress:\n'
  IFS=',' read -ra HOSTS <<<"${HOSTNAMES}"
  for h in "${HOSTS[@]}"; do
    printf '  - hostname: %s\n' "${h}"
    printf '    service: %s\n' "${ORIGIN_SERVICE}"
    printf '    originRequest:\n'
    printf '      noTLSVerify: true\n'
    printf '      connectTimeout: 30s\n'
  done
  printf '  - service: http_status:404\n'
} > "${CONFIG_FILE}"
chmod 0644 "${CONFIG_FILE}"
ok "wrote ${CONFIG_FILE}"

# --- Create Cloudflare DNS CNAMEs for each hostname -------------------------
if [[ "${ROUTE_DNS}" == "1" ]]; then
  IFS=',' read -ra HOSTS <<<"${HOSTNAMES}"
  for h in "${HOSTS[@]}"; do
    log "ensuring DNS route ${h} → ${TUNNEL_UUID}.cfargotunnel.com"
    if cloudflared tunnel route dns "${TUNNEL_NAME}" "${h}" 2>&1 \
        | grep -qE 'created|already|exists'; then
      ok "DNS route ${h} present"
    else
      printf '[cloudflared] ! DNS route %s may need manual creation\n' "${h}"
    fi
  done
fi

# --- Restart the cloudflared service ----------------------------------------
if systemctl list-unit-files cloudflared.service >/dev/null 2>&1; then
  log "restarting cloudflared.service"
  systemctl restart cloudflared
  systemctl is-active --quiet cloudflared && ok "cloudflared is active"
else
  log "cloudflared.service not installed — install with: cloudflared service install"
fi

log "done. Verify: curl -fsS https://cloudless.gr/api/health"
