#!/usr/bin/env bash
# Orchestrate the promotion of omv-ha from k3s worker -> control-plane server.
#
# Run from a workstation that has:
#   - kubectl access to the cluster (KUBECONFIG pointing at omv)
#   - SSH (passwordless sudo) to OMV_HA_HOST
#
# Steps:
#   1. Pre-flight: kubectl reachable, both nodes Ready, etcd is the datastore.
#   2. cordon + drain omv-ha (cloudless-app PDB minAvailable=1 keeps app up).
#   3. ssh omv-ha and run k3s/join-as-server.sh.
#   4. Wait for omv-ha to come back as control-plane,master.
#   5. uncordon.
#   6. Verify 2 control-plane nodes Ready and all pods Running.
#
# This script is idempotent enough for a redo: each step probes state first.
# It does NOT modify primary-node config and does NOT change Route 53.
#
# Required env / args:
#   K3S_TOKEN        node-token from omv (see below)
# Optional env (with defaults):
#   PRIMARY_URL      https://192.168.1.128:6443
#   OMV_HA_HOST      tbaltzakis@192.168.1.130
#   OMV_HA_NODE      omv-ha
#
# How to fetch K3S_TOKEN from omv:
#   ssh omv 'sudo cat /srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s/server/node-token'
set -euo pipefail

PRIMARY_URL="${PRIMARY_URL:-https://192.168.1.128:6443}"
PRIMARY_HOST="${PRIMARY_HOST:-tbaltzakis@192.168.1.128}"
PRIMARY_DATA_DIR="${PRIMARY_DATA_DIR:-/srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s}"
OMV_HA_HOST="${OMV_HA_HOST:-tbaltzakis@192.168.1.130}"
OMV_HA_NODE="${OMV_HA_NODE:-omv-ha}"

: "${K3S_TOKEN:?K3S_TOKEN must be set; fetch via: ssh omv 'sudo cat <data-dir>/server/node-token'}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOIN_SCRIPT="${REPO_ROOT}/k3s/join-as-server.sh"

if [[ ! -f "${JOIN_SCRIPT}" ]]; then
  echo "join script not found at ${JOIN_SCRIPT}" >&2
  exit 1
fi

log() { printf '\033[1;36m[promote]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[promote]\033[0m %s\n' "$*" >&2; exit 1; }

log "1/6 pre-flight: checking kubectl, node roles, datastore"
kubectl version --request-timeout=5s >/dev/null || fail "kubectl unreachable"

if ! kubectl get node "${OMV_HA_NODE}" >/dev/null 2>&1; then
  fail "node ${OMV_HA_NODE} not found in cluster"
fi

ROLES_OMVHA="$(kubectl get node "${OMV_HA_NODE}" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}')"
if [[ "${ROLES_OMVHA}" == "true" ]]; then
  log "  ${OMV_HA_NODE} is already a control-plane — skipping promotion"
  exit 0
fi

# Datastore check: embedded etcd on the primary writes to <data-dir>/server/db/etcd.
# If that directory does not exist, the primary is on SQLite and the join will
# fail with "starting kubernetes: preparing server: bootstrap data already found
# and encrypted with different token" or similar — bail early instead.
if ! ssh -o BatchMode=yes "${PRIMARY_HOST}" \
      "sudo test -d '${PRIMARY_DATA_DIR}/server/db/etcd'" 2>/dev/null; then
  fail "embedded etcd dir not found on primary (${PRIMARY_DATA_DIR}/server/db/etcd); migrate from sqlite first"
fi

log "2/6 cordon + drain ${OMV_HA_NODE}"
kubectl cordon "${OMV_HA_NODE}"
kubectl drain "${OMV_HA_NODE}" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=180s

log "3/6 ssh ${OMV_HA_HOST}: copy + run join-as-server.sh"
scp "${JOIN_SCRIPT}" "${OMV_HA_HOST}:/tmp/join-as-server.sh"
# shellcheck disable=SC2029  # intentional: substitute K3S_TOKEN/URL on the local side
ssh "${OMV_HA_HOST}" \
  "sudo K3S_URL='${PRIMARY_URL}' K3S_TOKEN='${K3S_TOKEN}' bash /tmp/join-as-server.sh"

log "4/6 waiting for ${OMV_HA_NODE} to report control-plane role"
for _ in $(seq 1 60); do
  R="$(kubectl get node "${OMV_HA_NODE}" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || true)"
  if [[ "${R}" == "true" ]]; then
    break
  fi
  sleep 5
done
if [[ "${R:-}" != "true" ]]; then
  fail "${OMV_HA_NODE} did not become control-plane within 5 minutes"
fi

log "5/6 uncordon ${OMV_HA_NODE}"
kubectl uncordon "${OMV_HA_NODE}"

log "6/6 verify"
"${REPO_ROOT}/scripts/verify-ha.sh"

log "done. ${OMV_HA_NODE} is now a control-plane server."
