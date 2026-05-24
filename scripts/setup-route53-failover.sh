#!/usr/bin/env bash
# Configure Route 53 health-checked failover for cloudless.gr (Phase 2).
#
# Creates:
#   1. A Route 53 health check on https://cloudless.gr/api/health
#   2. A SECONDARY failover A record → Pi WAN IP (150.228.63.192)
#
# The PRIMARY A/ALIAS record for cloudless.gr is managed by SST (the
# cloudless.gr repo). After running this script you must also update the
# SST stack to tag that record with:
#   failover: "PRIMARY"
#   healthCheck: <health-check-id printed by this script>
# See the "SST changes required" section at the bottom of this script.
#
# Prerequisites:
#   aws CLI configured with a profile that has Route 53 write access
#   (the 'cloudless' profile, or set AWS_PROFILE / AWS_DEFAULT_PROFILE)
#
# Usage:
#   ./scripts/setup-route53-failover.sh [--dry-run]
#
# Env (all have defaults):
#   ZONE_ID          Z079608614L53CC4EAZM3
#   DOMAIN           cloudless.gr
#   PI_WAN_IP        150.228.63.192  (update if your home IP has changed)
#   HEALTH_PATH      /api/health
#   AWS_PROFILE      cloudless
#   TTL              60

set -euo pipefail

ZONE_ID="${ZONE_ID:-Z079608614L53CC4EAZM3}"
DOMAIN="${DOMAIN:-cloudless.gr}"
PI_WAN_IP="${PI_WAN_IP:-150.228.63.192}"
HEALTH_PATH="${HEALTH_PATH:-/api/health}"
TTL="${TTL:-60}"
AWS_PROFILE="${AWS_PROFILE:-cloudless}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# When running in CI with env-var credentials, AWS_PROFILE="" disables profile
# lookup so the script uses AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY directly.
if [[ -n "${AWS_PROFILE}" ]]; then
  export AWS_DEFAULT_PROFILE="${AWS_PROFILE}"
fi

log()  { printf '\033[1;36m[r53-failover]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[r53-failover] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[r53-failover] !\033[0m %s\n' "$*"; }
dry()  { printf '\033[1;35m[r53-failover] DRY-RUN\033[0m %s\n' "$*"; }

aws_cmd() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    dry "aws $*"
    echo '{"HealthCheck":{"Id":"DRY-RUN-ID"},"ChangeInfo":{"Id":"DRY-RUN"}}'
  else
    aws "$@"
  fi
}

log "=== Route 53 failover setup for ${DOMAIN} ==="
[[ "${DRY_RUN}" -eq 1 ]] && warn "DRY-RUN mode — no changes will be made"

# --- Verify the zone exists -------------------------------------------------
log "1/4  verifying hosted zone ${ZONE_ID}"
zone_name="$(aws route53 get-hosted-zone --id "${ZONE_ID}" \
  --query 'HostedZone.Name' --output text 2>/dev/null || echo "")"
if [[ -z "${zone_name}" ]]; then
  echo "Cannot read zone ${ZONE_ID} — check AWS credentials and profile." >&2
  exit 1
fi
ok "zone ${ZONE_ID} → ${zone_name}"

# --- Verify the Pi WAN IP is reachable --------------------------------------
log "2/4  checking Pi WAN IP ${PI_WAN_IP}"
if curl -fsS --max-time 8 "https://${DOMAIN}${HEALTH_PATH}" >/dev/null 2>&1; then
  ok "https://${DOMAIN}${HEALTH_PATH} → 200 (primary is healthy)"
else
  warn "primary health check failed — proceeding anyway (failover setup is still valid)"
fi

# --- Create or reuse the health check ---------------------------------------
log "3/4  creating Route 53 health check"

# Check if a health check for this domain already exists (avoid duplicates).
EXISTING_HC="$(aws route53 list-health-checks \
  --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='${DOMAIN}' \
    && HealthCheckConfig.ResourcePath=='${HEALTH_PATH}'].Id" \
  --output text 2>/dev/null | head -1 || true)"

if [[ -n "${EXISTING_HC}" && "${EXISTING_HC}" != "None" ]]; then
  HC_ID="${EXISTING_HC}"
  ok "reusing existing health check ${HC_ID}"
else
  CALLER_REF="cloudless-gr-primary-$(date +%s)"
  HC_JSON="$(aws_cmd route53 create-health-check \
    --caller-reference "${CALLER_REF}" \
    --health-check-config "{
      \"Type\": \"HTTPS\",
      \"FullyQualifiedDomainName\": \"${DOMAIN}\",
      \"ResourcePath\": \"${HEALTH_PATH}\",
      \"Port\": 443,
      \"RequestInterval\": 30,
      \"FailureThreshold\": 3,
      \"EnableSNI\": true,
      \"Regions\": [\"us-east-1\", \"eu-west-1\", \"ap-southeast-1\"]
    }" \
    --output json)"
  HC_ID="$(printf '%s' "${HC_JSON}" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["HealthCheck"]["Id"])')"

  # Tag it for easy identification
  aws_cmd route53 change-tags-for-resource \
    --resource-type healthcheck \
    --resource-id "${HC_ID}" \
    --add-tags \
      "Key=Name,Value=cloudless-gr-primary" \
      "Key=ManagedBy,Value=setup-route53-failover.sh" >/dev/null

  ok "created health check ${HC_ID}"
fi

# --- Create the SECONDARY failover A record ---------------------------------
log "4/4  upserting SECONDARY failover A record → ${PI_WAN_IP}"

CHANGE_BATCH="{
  \"Comment\": \"Managed by setup-route53-failover.sh\",
  \"Changes\": [{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"${DOMAIN}.\",
      \"Type\": \"A\",
      \"SetIdentifier\": \"pi-standby\",
      \"Failover\": \"SECONDARY\",
      \"TTL\": ${TTL},
      \"ResourceRecords\": [{\"Value\": \"${PI_WAN_IP}\"}]
    }
  }]
}"

CHANGE_OUT="$(aws_cmd route53 change-resource-record-sets \
  --hosted-zone-id "${ZONE_ID}" \
  --change-batch "${CHANGE_BATCH}" \
  --output json)"
CHANGE_ID="$(printf '%s' "${CHANGE_OUT}" | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["ChangeInfo"]["Id"])' 2>/dev/null || echo "DRY-RUN")"
ok "SECONDARY record upserted (change ${CHANGE_ID})"

# --- Summary + SST instructions ---------------------------------------------
cat <<EOF

=== Done ===

Health check ID : ${HC_ID}
SECONDARY record: ${DOMAIN} A ${PI_WAN_IP} (Failover=SECONDARY, TTL=${TTL})

=== ACTION REQUIRED: SST changes ===

The PRIMARY record for ${DOMAIN} is managed by the cloudless.gr SST stack.
You must update it to use failover routing and attach the health check above.

In your SST config (cloudless.gr repo), find the Route 53 record resource and
add:

  failover: "PRIMARY"
  healthCheck: "${HC_ID}"

Then deploy: cd cloudless.gr && npx sst deploy --stage production

Until the PRIMARY is updated, Route 53 sees two A records (one with failover
routing, one without) and will serve BOTH — harmless but not proper failover.

=== Verify after SST deploy ===

  # Both records present with failover routing:
  aws route53 list-resource-record-sets --hosted-zone-id ${ZONE_ID} \\
    --query "ResourceRecordSets[?Name=='${DOMAIN}.']"

  # Health check passing:
  aws route53 get-health-check-status --health-check-id ${HC_ID} \\
    --query 'HealthCheckObservations[].StatusReport.Status'

  # DNS failover test (disable primary health check temporarily):
  dig +short ${DOMAIN}   # should show CloudFront IP normally
  # → after disabling health check → should show ${PI_WAN_IP}

=== DDNS note ===

The SECONDARY record is a static A record at ${PI_WAN_IP}.
If your home IP changes, update it:
  PI_WAN_IP=<new-ip> ./scripts/setup-route53-failover.sh
Or implement Phase 3 DDNS (see ha-architecture.md).
EOF
