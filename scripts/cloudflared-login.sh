#!/usr/bin/env bash
# Run `cloudflared tunnel login` on this host, surface the auth URL clearly
# (so a remote operator can click it from a CI log), wait for cert.pem to
# appear, then create the tunnel and route DNS for the requested hostnames.
#
# End-to-end: after this finishes there is a tunnel named "${TUNNEL_NAME}",
# its credentials JSON is in /etc/cloudflared/, and CNAMEs exist in
# Cloudflare DNS pointing the hostnames at the tunnel. Next step:
# `scripts/configure-cloudflared.sh` to write the ingress config and start
# the systemd service.
#
# Idempotent — skips each step if it has already been done.
#
# Env (defaults shown):
#   TUNNEL_NAME      cloudless
#   HOSTNAMES        cloudless.gr,manage.cloudless.gr
#   CERT             /etc/cloudflared/cert.pem
#   CRED_DIR         /etc/cloudflared
#   LOGIN_TIMEOUT    600  (seconds to wait for the OAuth click)

set -euo pipefail

TUNNEL_NAME="${TUNNEL_NAME:-cloudless}"
HOSTNAMES="${HOSTNAMES:-cloudless.gr,manage.cloudless.gr}"
CERT="${CERT:-/etc/cloudflared/cert.pem}"
CRED_DIR="${CRED_DIR:-/etc/cloudflared}"
LOGIN_TIMEOUT="${LOGIN_TIMEOUT:-600}"

log()  { printf '\033[1;36m[cf-login]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[cf-login] ✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[cf-login] ✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root (sudo)"
command -v cloudflared >/dev/null 2>&1 || fail "cloudflared is not installed"

install -d -m 0755 "${CRED_DIR}"

# --- 1. cloudflared tunnel login (if cert.pem missing) ---------------------
if [[ -f "${CERT}" ]]; then
  ok "cert already present at ${CERT}"
else
  log "starting 'cloudflared tunnel login' — capturing the auth URL"

  LOG_FILE="$(mktemp)"
  cloudflared tunnel login >"${LOG_FILE}" 2>&1 &
  LOGIN_PID=$!

  # Wait up to 30s for the URL to be printed
  AUTH_URL=""
  for _ in $(seq 1 30); do
    AUTH_URL="$(grep -oE 'https://dash\.cloudflare\.com/argotunnel\?[^[:space:]]+' "${LOG_FILE}" 2>/dev/null | head -1 || true)"
    [[ -n "${AUTH_URL}" ]] && break
    sleep 1
  done

  if [[ -z "${AUTH_URL}" ]]; then
    log "could not extract auth URL — full cloudflared output:"
    cat "${LOG_FILE}"
    kill "${LOGIN_PID}" 2>/dev/null || true
    fail "no URL found"
  fi

  cat <<EOF

==================================================================
 OPEN THIS URL IN A BROWSER (signed in to Cloudflare):

   ${AUTH_URL}

 Pick the cloudless.gr zone when prompted. This workflow will
 continue automatically once Cloudflare sends back the cert.
==================================================================

EOF

  # Cloudflared writes cert.pem to ~/.cloudflared/cert.pem by default;
  # when running as root that is /root/.cloudflared/cert.pem. Move it to
  # /etc/cloudflared so the systemd service can find it.
  ROOT_CERT="/root/.cloudflared/cert.pem"
  deadline=$(( $(date +%s) + LOGIN_TIMEOUT ))
  log "waiting up to ${LOGIN_TIMEOUT}s for the OAuth click"
  while (( $(date +%s) < deadline )); do
    if [[ -f "${ROOT_CERT}" ]]; then
      install -m 0600 "${ROOT_CERT}" "${CERT}"
      ok "received cert and placed at ${CERT}"
      break
    fi
    if [[ -f "${CERT}" ]]; then
      ok "cert appeared at ${CERT}"
      break
    fi
    sleep 5
  done

  kill "${LOGIN_PID}" 2>/dev/null || true
  wait "${LOGIN_PID}" 2>/dev/null || true
  [[ -f "${CERT}" ]] || fail "timed out waiting for cert.pem"
fi

# --- 2. Create the tunnel (if absent) --------------------------------------
# Tell cloudflared to use the system-wide cert location.
export TUNNEL_ORIGIN_CERT="${CERT}"

TUNNEL_UUID="$(cloudflared tunnel list 2>/dev/null \
  | awk -v n="${TUNNEL_NAME}" '$2==n {print $1; exit}' || true)"

if [[ -z "${TUNNEL_UUID}" ]]; then
  log "creating tunnel '${TUNNEL_NAME}'"
  # `tunnel create` writes the credentials JSON to ~/.cloudflared/<uuid>.json
  CREATE_OUT="$(cloudflared tunnel create "${TUNNEL_NAME}" 2>&1)"
  echo "${CREATE_OUT}"
  TUNNEL_UUID="$(printf '%s' "${CREATE_OUT}" \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | head -1)"
  [[ -n "${TUNNEL_UUID}" ]] || fail "could not parse tunnel UUID from create output"
  ok "created tunnel ${TUNNEL_NAME} (${TUNNEL_UUID})"
else
  ok "tunnel ${TUNNEL_NAME} already exists (${TUNNEL_UUID})"
fi

# Move the credentials JSON to /etc/cloudflared so the systemd service finds it
SRC_CRED="/root/.cloudflared/${TUNNEL_UUID}.json"
DST_CRED="${CRED_DIR}/${TUNNEL_UUID}.json"
if [[ -f "${SRC_CRED}" && ! -f "${DST_CRED}" ]]; then
  install -m 0600 "${SRC_CRED}" "${DST_CRED}"
  ok "moved credentials to ${DST_CRED}"
elif [[ -f "${DST_CRED}" ]]; then
  ok "credentials already at ${DST_CRED}"
else
  log "credentials JSON not found in /root/.cloudflared — assuming present at ${DST_CRED}"
fi

# --- 3. Route DNS for each hostname ----------------------------------------
IFS=',' read -ra HOSTS <<<"${HOSTNAMES}"
for h in "${HOSTS[@]}"; do
  log "routing DNS ${h} → ${TUNNEL_UUID}.cfargotunnel.com"
  if cloudflared tunnel route dns "${TUNNEL_NAME}" "${h}" 2>&1 \
      | tee /dev/stderr \
      | grep -qE 'created|already|exists|Added|added'; then
    ok "DNS route ${h} present"
  else
    log "(continuing — DNS route may already exist or need manual creation)"
  fi
done

cat <<EOF

=== Done ===

Tunnel UUID  : ${TUNNEL_UUID}
Credentials  : ${DST_CRED}
Hostnames    : ${HOSTNAMES}

Next step (write /etc/cloudflared/config.yml and start the daemon):
  sudo TUNNEL_NAME=${TUNNEL_NAME} HOSTNAMES='${HOSTNAMES}' \\
    ./scripts/configure-cloudflared.sh
EOF
