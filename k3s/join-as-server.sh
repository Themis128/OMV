#!/usr/bin/env bash
# Join this node to the existing cloudless k3s cluster as an additional
# control-plane server (embedded etcd). Designed to run on omv-ha as part of
# the worker -> control-plane promotion. Idempotent.
#
# Modes:
#   default  full server: apiserver + scheduler + controller-manager + etcd.
#   ETCD_ONLY=1
#            etcd-only voter: same etcd membership, but apiserver / scheduler /
#            controller-manager are disabled to save RAM. Only useful as the
#            *third* member of a 3-node etcd quorum (alongside two full
#            servers). On a 2-node cluster, do NOT use this — you'd lose the
#            ability to schedule pods to this node and still have no HA.
#
# Sequence:
#   1. Refuse to run unless K3S_URL + K3S_TOKEN are set.
#   2. If a k3s-agent install is present, run k3s-agent-uninstall.sh.
#   3. If a k3s server is already running, leave it alone.
#   4. Otherwise, install k3s as `server --server $K3S_URL`, joining etcd.
#   5. Wait for node Ready and copy kubeconfig to the SUDO_USER.
#
# Usage:
#   sudo K3S_URL=https://192.168.1.128:6443 K3S_TOKEN=<node-token> \
#     ./join-as-server.sh
#
#   # Etcd-only voter (only for 3+-member clusters):
#   sudo ETCD_ONLY=1 K3S_URL=https://192.168.1.128:6443 K3S_TOKEN=<node-token> \
#     ./join-as-server.sh
#
# Get the token on the existing server:
#   sudo cat /var/lib/rancher/k3s/server/node-token
#   # or, if you moved data-dir per k3s/install.sh:
#   sudo cat /srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s/server/node-token
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "must run as root (use sudo)" >&2
  exit 1
fi

: "${K3S_URL:?K3S_URL must be set, e.g. https://192.168.1.128:6443}"
: "${K3S_TOKEN:?K3S_TOKEN must be set (node-token from existing server)}"

ETCD_ONLY="${ETCD_ONLY:-0}"
TARGET_USER="${SUDO_USER:-tbaltzakis}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"

# Robust k3s-agent cleanup: handle both a normal worker install and a stale
# unit left by a partially-completed earlier uninstall (typical cause of a
# "k3s-agent.service has failed" alert on a node that's already a server).
if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
  echo "[join] k3s-agent install detected — running k3s-agent-uninstall.sh"
  /usr/local/bin/k3s-agent-uninstall.sh
elif [[ -e /etc/systemd/system/k3s-agent.service ]]; then
  echo "[join] stale k3s-agent.service unit found without uninstall script — removing"
  systemctl stop k3s-agent.service 2>/dev/null || true
  systemctl disable k3s-agent.service 2>/dev/null || true
  rm -f /etc/systemd/system/k3s-agent.service \
        /etc/systemd/system/k3s-agent.service.env
  systemctl daemon-reload
  systemctl reset-failed k3s-agent.service 2>/dev/null || true
fi

if systemctl is-active --quiet k3s 2>/dev/null; then
  echo "[join] k3s server already active on this node — nothing to do"
  exit 0
fi

extra_flags=()
if [[ "${ETCD_ONLY}" == "1" ]]; then
  echo "[join] ETCD_ONLY=1 — installing as etcd voter only (no apiserver/scheduler/controller-manager)"
  extra_flags+=(--disable-apiserver --disable-controller-manager --disable-scheduler)
fi

echo "[join] installing k3s as server, joining ${K3S_URL}"
curl -sfL https://get.k3s.io \
  | INSTALL_K3S_CHANNEL=stable \
    K3S_TOKEN="${K3S_TOKEN}" \
    sh -s - server \
        --server "${K3S_URL}" \
        --write-kubeconfig-mode=644 \
        "${extra_flags[@]}"

echo "[join] waiting for local node Ready"
KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  kubectl wait --for=condition=Ready node --all --timeout=180s

if [[ "${ETCD_ONLY}" != "1" ]]; then
  echo "[join] copying kubeconfig to ${TARGET_HOME}/.kube/config"
  install -d -m 0700 -o "${TARGET_USER}" -g "${TARGET_USER}" "${TARGET_HOME}/.kube"
  install -m 0600 -o "${TARGET_USER}" -g "${TARGET_USER}" \
    /etc/rancher/k3s/k3s.yaml "${TARGET_HOME}/.kube/config"

  if ! grep -q '^export KUBECONFIG=' "${TARGET_HOME}/.bashrc" 2>/dev/null; then
    # shellcheck disable=SC2016 # we want $HOME to be literal in .bashrc, not resolved here
    echo 'export KUBECONFIG=$HOME/.kube/config' >> "${TARGET_HOME}/.bashrc"
  fi
else
  echo "[join] etcd-only mode — skipping kubeconfig copy (no apiserver on this node)"
fi

echo "[join] done. From a full-server node:  kubectl get nodes -o wide"
echo "[join] etcd members:  sudo k3s kubectl -n kube-system exec -it \$(k3s kubectl -n kube-system get pod -l app=etcd -o name | head -1) -- etcdctl member list"
