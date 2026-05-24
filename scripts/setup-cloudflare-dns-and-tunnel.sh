#!/usr/bin/env bash
# Bootstrap the Cloudflare side of the cloudless.gr migration:
#   1. ensure the cloudless.gr zone exists in Cloudflare (creates it if not)
#   2. print the Cloudflare-assigned name servers (you set these at the registrar)
#   3. create the "cloudless" Tunnel via the API and write the credentials JSON
#      to /etc/cloudflared/<uuid>.json — fully scripted, no `cloudflared login`,
#      no browser OAuth, idempotent (reuses the tunnel if it already exists)
#   4. optionally wait for NS delegation to propagate
#
# Required env:
#   CF_API_TOKEN     Cloudflare API token with permissions:
#                      Account → Cloudflare Tunnel : Edit
#                      Account → Account Settings  : Read   (to list account id)
#                      Zone    → Zone              : Edit   (Include all zones)
#                      Zone    → DNS               : Edit   (Include cloudless.gr)
#
# Optional env (defaults shown):
#   ZONE             cloudless.gr
#   TUNNEL_NAME      cloudless
#   CRED_DIR         /etc/cloudflared
#   WAIT_NS          1   — poll until the registrar delegates to Cloudflare
#   WAIT_NS_TIMEOUT  1800 (seconds)
#
# Run as root on omv (so the credentials JSON lands in /etc/cloudflared):
#   sudo CF_API_TOKEN=… ./scripts/setup-cloudflare-dns-and-tunnel.sh
#
# Output: writes <uuid>.json under /etc/cloudflared, prints the tunnel UUID
# and the NS values to set at the registrar (Papaki / Top.Host / whichever
# manages .gr for you). Once delegation has propagated, run:
#   sudo ./scripts/configure-cloudflared.sh

set -euo pipefail

: "${CF_API_TOKEN:?CF_API_TOKEN must be set}"
ZONE="${ZONE:-cloudless.gr}"
TUNNEL_NAME="${TUNNEL_NAME:-cloudless}"
CRED_DIR="${CRED_DIR:-/etc/cloudflared}"
WAIT_NS="${WAIT_NS:-1}"
WAIT_NS_TIMEOUT="${WAIT_NS_TIMEOUT:-1800}"

API="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")

log()  { printf '\033[1;36m[cf-bootstrap]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[cf-bootstrap] ✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[cf-bootstrap] ✗\033[0m %s\n' "$*" >&2; exit 1; }

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || fail "$bin is required but not installed"
done

cf() { curl -fsS "${AUTH[@]}" "$@"; }

# --- 1. Resolve the account id ---------------------------------------------
log "looking up Cloudflare account"
ACCOUNT_ID="$(cf "${API}/accounts" | jq -r '.result[0].id // empty')"
[[ -n "${ACCOUNT_ID}" ]] || fail "no accounts visible to this token (need Account:Read)"
ACCOUNT_NAME="$(cf "${API}/accounts/${ACCOUNT_ID}" | jq -r '.result.name')"
ok "account: ${ACCOUNT_NAME} (${ACCOUNT_ID})"

# --- 2. Ensure the zone exists ---------------------------------------------
log "ensuring zone ${ZONE} exists"
ZONE_JSON="$(cf "${API}/zones?name=${ZONE}")"
ZONE_ID="$(echo "${ZONE_JSON}" | jq -r '.result[0].id // empty')"

if [[ -z "${ZONE_ID}" ]]; then
  log "zone not found — creating it"
  ZONE_JSON="$(cf -X POST "${API}/zones" \
    --data "$(jq -n --arg n "${ZONE}" --arg a "${ACCOUNT_ID}" \
      '{name:$n, account:{id:$a}, type:"full"}')")"
  ZONE_ID="$(echo "${ZONE_JSON}" | jq -r '.result.id')"
  [[ -n "${ZONE_ID}" && "${ZONE_ID}" != "null" ]] || fail "zone create failed: $(echo "${ZONE_JSON}" | jq -r '.errors')"
  ok "created zone ${ZONE} (${ZONE_ID})"
else
  ok "zone ${ZONE} already exists (${ZONE_ID})"
fi

mapfile -t NS_LIST < <(cf "${API}/zones/${ZONE_ID}" | jq -r '.result.name_servers[]')

# --- 3. Create / reuse the tunnel ------------------------------------------
log "ensuring Cloudflare Tunnel '${TUNNEL_NAME}' exists"
TUNNELS_JSON="$(cf "${API}/accounts/${ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false")"
TUNNEL_ID="$(echo "${TUNNELS_JSON}" | jq -r '.result[0].id // empty')"

if [[ -z "${TUNNEL_ID}" ]]; then
  log "tunnel not found — creating it"
  # 32-byte random secret, base64-encoded (Cloudflare requirement)
  TUNNEL_SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  CREATE_JSON="$(cf -X POST "${API}/accounts/${ACCOUNT_ID}/cfd_tunnel" \
    --data "$(jq -n --arg n "${TUNNEL_NAME}" --arg s "${TUNNEL_SECRET}" \
      '{name:$n, tunnel_secret:$s}')")"
  TUNNEL_ID="$(echo "${CREATE_JSON}" | jq -r '.result.id')"
  [[ -n "${TUNNEL_ID}" && "${TUNNEL_ID}" != "null" ]] || fail "tunnel create failed: $(echo "${CREATE_JSON}" | jq -r '.errors')"
  ok "created tunnel ${TUNNEL_NAME} (${TUNNEL_ID})"
else
  ok "tunnel ${TUNNEL_NAME} already exists (${TUNNEL_ID})"
  # Reusing an existing tunnel — we don't have its secret. Rotate it so we
  # can write a fresh credentials JSON. (Safe: this invalidates any other
  # cloudflared process running with the old secret for this tunnel.)
  log "rotating tunnel secret so we can produce a fresh credentials file"
  TUNNEL_SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  ROTATE_JSON="$(cf -X PATCH "${API}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}" \
    --data "$(jq -n --arg s "${TUNNEL_SECRET}" '{tunnel_secret:$s}')")"
  echo "${ROTATE_JSON}" | jq -e '.success == true' >/dev/null \
    || fail "tunnel secret rotation failed: $(echo "${ROTATE_JSON}" | jq -r '.errors')"
  ok "tunnel secret rotated"
fi

# --- 4. Write the credentials JSON -----------------------------------------
install -d -m 0755 "${CRED_DIR}"
CRED_FILE="${CRED_DIR}/${TUNNEL_ID}.json"
log "writing ${CRED_FILE}"
umask 077
jq -n --arg a "${ACCOUNT_ID}" --arg s "${TUNNEL_SECRET}" --arg t "${TUNNEL_ID}" \
  '{AccountTag:$a, TunnelSecret:$s, TunnelID:$t}' > "${CRED_FILE}"
chmod 0600 "${CRED_FILE}"
ok "wrote ${CRED_FILE} (mode 600)"

# --- 5. Print the NS values for the registrar ------------------------------
cat <<EOF

=== ACTION REQUIRED at your registrar ===

Set the nameservers for ${ZONE} to:

$(printf '    %s\n' "${NS_LIST[@]}")

Where to do this (your registrar's control panel):
  * Papaki:    https://www.papaki.com/cp2/   → Domains → ${ZONE} → Name Servers
  * Top.Host:  https://www.top.host/cpanel/  → Domains → ${ZONE} → DNS
  * Other:    find the "Nameservers" / "DNS" section for ${ZONE}.

It can take 5-60 minutes for the registrar's change to propagate.
EOF

# --- 6. Wait for NS delegation ---------------------------------------------
if [[ "${WAIT_NS}" == "1" ]]; then
  log "waiting up to ${WAIT_NS_TIMEOUT}s for NS delegation to propagate"
  deadline=$(( $(date +%s) + WAIT_NS_TIMEOUT ))
  CURRENT_NS=""
  while (( $(date +%s) < deadline )); do
    # Query a public resolver, not the local one (which may cache the old NS)
    CURRENT_NS="$(dig +short NS "${ZONE}" @1.1.1.1 2>/dev/null | sort | tr '\n' ' ' || true)"
    if printf '%s' "${CURRENT_NS}" | grep -qi cloudflare; then
      ok "NS delegated to Cloudflare: ${CURRENT_NS}"
      break
    fi
    printf '  current NS: %s — retrying in 30s\r' "${CURRENT_NS:-none}"
    sleep 30
  done
  if ! printf '%s' "${CURRENT_NS}" | grep -qi cloudflare; then
    fail "NS delegation did not propagate within ${WAIT_NS_TIMEOUT}s — last seen: ${CURRENT_NS:-none}"
  fi
fi

cat <<EOF

=== Done ===

Tunnel UUID  : ${TUNNEL_ID}
Credentials  : ${CRED_FILE}

Next step (apply ingress rules + restart cloudflared):
  sudo TUNNEL_NAME=${TUNNEL_NAME} ./scripts/configure-cloudflared.sh
EOF
