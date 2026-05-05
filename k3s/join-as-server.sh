#!/usr/bin/env bash
# Join this node to the existing cloudless k3s cluster as an additional
# control-plane server (embedded etcd). Designed to run on omv-ha as part of
# the worker -> control-plane promotion. Idempotent.
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

TARGET_USER="${SUDO_USER:-tbaltzakis}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"

if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
  echo "[join] k3s-agent install detected — running k3s-agent-uninstall.sh"
  /usr/local/bin/k3s-agent-uninstall.sh
fi

if systemctl is-active --quiet k3s 2>/dev/null; then
  echo "[join] k3s server already active on this node — nothing to do"
  exit 0
fi

echo "[join] installing k3s as server, joining ${K3S_URL}"
curl -sfL https://get.k3s.io \
  | INSTALL_K3S_CHANNEL=stable \
    K3S_TOKEN="${K3S_TOKEN}" \
    sh -s - server \
        --server "${K3S_URL}" \
        --write-kubeconfig-mode=644

echo "[join] waiting for local node Ready"
KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  kubectl wait --for=condition=Ready node --all --timeout=180s

echo "[join] copying kubeconfig to ${TARGET_HOME}/.kube/config"
install -d -m 0700 -o "${TARGET_USER}" -g "${TARGET_USER}" "${TARGET_HOME}/.kube"
install -m 0600 -o "${TARGET_USER}" -g "${TARGET_USER}" \
  /etc/rancher/k3s/k3s.yaml "${TARGET_HOME}/.kube/config"

if ! grep -q '^export KUBECONFIG=' "${TARGET_HOME}/.bashrc" 2>/dev/null; then
  # shellcheck disable=SC2016 # we want $HOME to be literal in .bashrc, not resolved here
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "${TARGET_HOME}/.bashrc"
fi

echo "[join] done. From either node:  kubectl get nodes -o wide"
echo "[join] etcd members:  sudo k3s kubectl -n kube-system exec -it \$(k3s kubectl -n kube-system get pod -l app=etcd -o name | head -1) -- etcdctl member list"
