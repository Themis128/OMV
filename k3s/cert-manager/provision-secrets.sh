#!/usr/bin/env bash
#
# provision-secrets.sh — apply the cert-manager credentials Secrets and
# ClusterIssuers to the running k3s cluster.
#
# Run directly on either Pi node (sudo is handled automatically).
# Does not require the repo to be cloned on the target machine — the YAML
# is embedded below via heredocs.
#
# Usage:
#   sudo ./provision-secrets.sh --cloudflare-token <token>
#   sudo ./provision-secrets.sh --cloudflare-token <token> --skip-issuer
#
# Options:
#   --cloudflare-token TOKEN   Cloudflare API token (Zone→DNS→Edit) — no longer needed
#                              (cloudless.online retired; cloudless.gr uses Route 53)
#   --skip-issuer              Apply the Secret only, skip ClusterIssuer update
#   --dry-run                  Print the manifests without applying
#
# The Route 53 secret is NOT updated by this script — it was provisioned
# separately and should already exist in the cluster.

set -euo pipefail

CLOUDFLARE_TOKEN=""
SKIP_ISSUER=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --cloudflare-token) CLOUDFLARE_TOKEN="$2"; shift 2 ;;
        --skip-issuer)      SKIP_ISSUER=1; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$CLOUDFLARE_TOKEN" ]; then
    echo "Usage: $0 --cloudflare-token <token> [--skip-issuer] [--dry-run]" >&2
    echo "" >&2
    echo "Get a token at: Cloudflare → My Profile → API Tokens → Create Token" >&2
    echo "Required permission: Zone → DNS → Edit" >&2
    exit 1
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

KUBECTL="${SUDO} kubectl"
# --validate=false skips OpenAPI schema download which can fail on k3s agent
# nodes or when the API server is temporarily unable to serve the schema.
APPLY="${KUBECTL} apply --validate=false -f -"
[ "$DRY_RUN" -eq 1 ] && APPLY="cat"

# --- Cloudflare API token Secret -------------------------------------------
echo "[cert-manager] applying cloudflare-api-token Secret"
$APPLY <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: "${CLOUDFLARE_TOKEN}"
EOF

if [ "$SKIP_ISSUER" -eq 1 ]; then
    echo "[cert-manager] --skip-issuer set; skipping ClusterIssuer update"
    exit 0
fi

# --- ClusterIssuer (production) --------------------------------------------
echo "[cert-manager] applying letsencrypt-route53 ClusterIssuer"
$APPLY <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-route53
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: tbaltzakis@cloudless.gr
    privateKeySecretRef:
      name: letsencrypt-route53-account
    solvers:
      - selector:
          dnsZones:
            - cloudless.gr
        dns01:
          route53:
            region: us-east-1
            hostedZoneID: Z079608614L53CC4EAZM3
            accessKeyIDSecretRef:
              name: route53-credentials
              key: access-key-id
            secretAccessKeySecretRef:
              name: route53-credentials
              key: secret-access-key
EOF

# --- ClusterIssuer (staging) -----------------------------------------------
echo "[cert-manager] applying letsencrypt-route53-staging ClusterIssuer"
$APPLY <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-route53-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: tbaltzakis@cloudless.gr
    privateKeySecretRef:
      name: letsencrypt-route53-staging-account
    solvers:
      - selector:
          dnsZones:
            - cloudless.gr
        dns01:
          route53:
            region: us-east-1
            hostedZoneID: Z079608614L53CC4EAZM3
            accessKeyIDSecretRef:
              name: route53-credentials
              key: access-key-id
            secretAccessKeySecretRef:
              name: route53-credentials
              key: secret-access-key
EOF

# --- Verify ----------------------------------------------------------------
echo ""
echo "[cert-manager] current ClusterIssuer status:"
${KUBECTL} get clusterissuer letsencrypt-route53 letsencrypt-route53-staging \
    -o custom-columns='NAME:.metadata.name,READY:.status.conditions[0].status,REASON:.status.conditions[0].reason' \
    2>/dev/null || echo "  (could not list ClusterIssuers — try: sudo kubectl get clusterissuer)"

echo ""
echo "[cert-manager] cloudflare-api-token Secret:"
${KUBECTL} get secret cloudflare-api-token -n cert-manager \
    -o custom-columns='NAME:.metadata.name,TYPE:.type,CREATED:.metadata.creationTimestamp' \
    2>/dev/null || echo "  (could not list Secret — try: sudo kubectl get secret cloudflare-api-token -n cert-manager)"
