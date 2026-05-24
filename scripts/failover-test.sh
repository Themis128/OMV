#!/usr/bin/env bash
# Simulate an omv (primary control-plane) outage and verify omv-ha keeps the
# cluster API alive and the cloudless app reachable. Restart omv afterwards.
#
# Run from a workstation with kubectl access (KUBECONFIG should NOT point at
# omv-only — use a kubeconfig whose server is the omv-ha API or a load-balanced
# VIP, otherwise stopping omv kills your client too).
#
# Steps:
#   1. Snapshot kubectl get nodes / pods.
#   2. SSH omv: sudo systemctl stop k3s.
#   3. Switch local KUBECONFIG to omv-ha API endpoint, wait for kubectl to
#      respond (omv-ha promotes itself to leader).
#   4. Curl the app to confirm traffic still flows (klipper-lb survives a
#      control-plane stop because dataplane is independent).
#   5. SSH omv: sudo systemctl start k3s. Wait for both nodes Ready.
#   6. Verify quorum reformed.
set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:-tbaltzakis@192.168.1.128}"
SECONDARY_API="${SECONDARY_API:-https://192.168.1.130:6443}"
APP_URL="${APP_URL:-https://cloudless.gr/api/health}"
PRIMARY_NODE="${PRIMARY_NODE:-omv}"
SECONDARY_NODE="${SECONDARY_NODE:-omv-ha}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '\033[1;36m[failover]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[failover]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" != "--yes" ]]; then
  cat >&2 <<EOF
This will stop k3s on ${PRIMARY_NODE} for ~2 minutes.

WARNING — 2-member etcd has zero failure tolerance. With only ${PRIMARY_NODE} +
${SECONDARY_NODE} as etcd members, stopping ${PRIMARY_NODE} causes etcd on
${SECONDARY_NODE} to lose quorum: the API server stays up but goes effectively
read-only (no scheduling, no rollouts) until ${PRIMARY_NODE} comes back.

The cloudless-app data plane keeps serving traffic during the outage because
running pods don't need API writes. This script verifies that — it does NOT
prove control-plane HA, because 2-member etcd cannot provide it. See
docs/ha-control-plane-promotion.md > "Failure tolerance" for context.

Re-run with: $0 --yes
EOF
  exit 1
fi

log "1/6 baseline"
kubectl get nodes
kubectl -n cloudless get pods -o wide

log "2/6 stopping k3s on ${PRIMARY_NODE}"
ssh -o BatchMode=yes "${PRIMARY_HOST}" 'sudo systemctl stop k3s'

# Build a temporary kubeconfig pointing at the secondary API so we don't lose
# control when the primary goes down.
TMP_KUBECONFIG="$(mktemp)"
trap 'rm -f "${TMP_KUBECONFIG}"' EXIT
kubectl config view --flatten --minify > "${TMP_KUBECONFIG}"
# After --minify there is exactly one cluster entry; rewrite its server URL.
# (Note: set-cluster takes a cluster *name*, not a context name.)
CLUSTER_NAME="$(kubectl --kubeconfig="${TMP_KUBECONFIG}" config view -o jsonpath='{.clusters[0].name}')"
kubectl --kubeconfig="${TMP_KUBECONFIG}" config set-cluster \
  "${CLUSTER_NAME}" --server="${SECONDARY_API}" >/dev/null

log "3/6 waiting for kubectl via ${SECONDARY_API}"
ok=0
for _ in $(seq 1 60); do
  if kubectl --kubeconfig="${TMP_KUBECONFIG}" get --raw=/readyz >/dev/null 2>&1; then
    ok=1; break
  fi
  sleep 5
done
[[ "${ok}" -eq 1 ]] || fail "kubectl never came back via ${SECONDARY_API}"
log "  ${SECONDARY_NODE} is serving the API"

log "4/6 hitting ${APP_URL}"
if curl -fsS --max-time 10 "${APP_URL}" >/dev/null; then
  log "  app reachable during outage"
else
  log "  WARNING: app not reachable. Investigate before continuing."
fi

log "5/6 restarting k3s on ${PRIMARY_NODE}"
ssh -o BatchMode=yes "${PRIMARY_HOST}" 'sudo systemctl start k3s'

log "  waiting for ${PRIMARY_NODE} Ready"
for _ in $(seq 1 60); do
  if kubectl --kubeconfig="${TMP_KUBECONFIG}" get node "${PRIMARY_NODE}" \
       -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
       | grep -q True; then
    break
  fi
  sleep 5
done

log "6/6 final verify"
KUBECONFIG="${TMP_KUBECONFIG}" "${REPO_ROOT}/scripts/verify-ha.sh"

log "failover test complete"
