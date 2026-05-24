#!/usr/bin/env bash
# Recover the k3s cluster when omv can't reach omv-ha and etcd loses quorum.
#
# Symptom: omv's etcd loops "became pre-candidate" / "authentication handshake
# failed" — the 2-member cluster lost quorum and writes are blocked.
#
# Strategy: force omv into a single-member etcd cluster (--cluster-reset),
# bring it back as a healthy standalone control-plane, then optionally
# re-join omv-ha.
#
# Run on omv (the primary Pi, 192.168.1.128) as root:
#   sudo ./scripts/etcd-recover.sh
#
# Env (all have defaults):
#   OMV_HA_HOST    tbaltzakis@192.168.1.130
#   DATA_DIR       /srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s
#   REJOIN         1  — after recovery, re-join omv-ha as a server (default: prompt)
#
# WARNING: --cluster-reset discards the multi-member etcd state. Any writes
# that were in-flight while the peer was unreachable are lost (the last
# committed snapshot is the recovery point). Kubernetes objects (Deployments,
# Secrets, etc.) that were committed before the split are preserved.

set -euo pipefail

OMV_HA_HOST="${OMV_HA_HOST:-tbaltzakis@192.168.1.130}"
DATA_DIR="${DATA_DIR:-/srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s}"
REJOIN="${REJOIN:-}"

log()  { printf '\033[1;36m[etcd-recover]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[etcd-recover] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[etcd-recover] !\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[etcd-recover] ✗\033[0m %s\n' "$*" >&2; }

if [[ ${EUID} -ne 0 ]]; then
  fail "run as root (sudo)"; exit 1
fi

if [[ "$(hostname -s)" == "omv-ha" ]]; then
  fail "this script must run on omv (the primary), not omv-ha"; exit 1
fi

log "=== etcd cluster recovery ==="
warn "This will reset etcd to a single-member cluster on $(hostname -s)."
warn "In-flight writes since the last committed entry will be lost."
warn "Kubernetes objects that were committed are preserved."

if [[ -z "${REJOIN}" ]]; then
  read -r -p "[etcd-recover] Proceed? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || { log "aborted"; exit 0; }
fi

# --- 1. Stop omv-ha k3s (best-effort — may already be down) ---
log "1/6  stopping k3s on omv-ha (${OMV_HA_HOST})"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "${OMV_HA_HOST}" \
    'sudo systemctl stop k3s 2>/dev/null; echo stopped' 2>/dev/null; then
  ok "omv-ha k3s stopped"
else
  warn "could not SSH to omv-ha — assuming it is already down"
fi

# --- 2. Stop k3s on this node ---
log "2/6  stopping k3s on $(hostname -s)"
systemctl stop k3s
ok "k3s stopped"

# --- 3. Snapshot etcd data before reset (best-effort) ---
log "3/6  snapshotting etcd data dir before reset"
SNAP_DIR="/var/lib/rancher/k3s-reset-backup-$(date +%Y%m%dT%H%M%S)"
if [[ -d "${DATA_DIR}/server/db" ]]; then
  cp -a "${DATA_DIR}/server/db" "${SNAP_DIR}" && ok "snapshot saved to ${SNAP_DIR}"
else
  warn "db dir not found at ${DATA_DIR}/server/db — skipping snapshot"
fi

# --- 4. Cluster-reset ---
log "4/6  running k3s server --cluster-reset (this takes ~10 s)"
K3S_DATA_DIR="${DATA_DIR}" k3s server \
  --cluster-reset \
  --cluster-reset-restore-path="" \
  --data-dir "${DATA_DIR}" \
  2>&1 | grep -v "^$" || true
# k3s exits after printing the reset notice; non-zero exit is expected
ok "cluster-reset complete"

# --- 5. Restart k3s ---
log "5/6  starting k3s"
systemctl start k3s

log "  waiting up to 120 s for node Ready"
deadline=$(( $(date +%s) + 120 ))
while true; do
  if k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; then
    break
  fi
  if (( $(date +%s) > deadline )); then
    fail "node did not become Ready within 120 s"
    fail "check: journalctl -u k3s -n 50 --no-pager"
    exit 1
  fi
  sleep 5
done
ok "node Ready"

log "6/6  verifying workloads"
k3s kubectl get nodes
k3s kubectl -n cloudless get pods 2>/dev/null || warn "cloudless namespace not yet ready"

# --- 6. Optionally re-join omv-ha ---
if [[ "${REJOIN:-}" == "1" ]]; then
  rejoin=y
else
  echo
  read -r -p "[etcd-recover] Re-join omv-ha as a control-plane server now? [y/N] " rejoin
fi

if [[ "${rejoin,,}" == "y" ]]; then
  log "fetching node-token for omv-ha re-join"
  TOKEN="$(cat "${DATA_DIR}/server/node-token")"
  log "SSHing to omv-ha to run join-as-server.sh"
  REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  ssh -o BatchMode=yes "${OMV_HA_HOST}" \
    "sudo K3S_URL=https://192.168.1.128:6443 K3S_TOKEN='${TOKEN}' bash -s" \
    < "${REPO_ROOT}/k3s/join-as-server.sh"
  log "waiting for omv-ha to appear in node list"
  sleep 20
  k3s kubectl get nodes
  ok "re-join complete"
else
  log "skipping re-join — run scripts/promote-omv-ha.sh later to re-add omv-ha"
fi

ok "recovery complete"
log "next: verify cloudless-app is serving: curl -fsS https://cloudless.gr/api/health"
