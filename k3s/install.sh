#!/usr/bin/env bash
# Install k3s on the OMV Pi for the cloudless HA standby.
# Idempotent: safe to re-run.
#
# Usage:  sudo ./install.sh
#
# Outcome:
#   - k3s server (single-node, embedded etcd, channel: stable)
#   - data-dir on sda1 (so heavy IO stays off the SD card)
#   - default Traefik ingress, but bound to host ports 18080/18443
#     (because OMV nginx owns 80+8080 and pihole-FTL owns 443)
#   - kubeconfig copied to ~tbaltzakis/.kube/config (mode 600)
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "must run as root (use sudo)" >&2
  exit 1
fi

DATA_DIR="/srv/dev-disk-by-uuid-a9a5a108-8095-4b7b-8011-716889995cd7/k3s"
TARGET_USER="${SUDO_USER:-tbaltzakis}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"

if ! command -v k3s >/dev/null 2>&1; then
  echo "[install] k3s not found — installing"
  install -d -m 0700 "${DATA_DIR}"
  curl -sfL https://get.k3s.io \
    | INSTALL_K3S_CHANNEL=stable sh -s - server \
        --data-dir "${DATA_DIR}" \
        --write-kubeconfig-mode=600
else
  echo "[install] k3s already installed — skipping installer"
fi

echo "[install] waiting for node Ready"
KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  kubectl wait --for=condition=Ready node --all --timeout=180s

echo "[install] applying Traefik port override (18080/18443)"
install -d -m 0755 "${DATA_DIR}/server/manifests"
cat > "${DATA_DIR}/server/manifests/traefik-config.yaml" <<'YAML'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        port: 18080
        exposedPort: 18080
      websecure:
        port: 18443
        exposedPort: 18443
YAML

echo "[install] copying kubeconfig to ${TARGET_HOME}/.kube/config"
install -d -m 0700 -o "${TARGET_USER}" -g "${TARGET_USER}" "${TARGET_HOME}/.kube"
install -m 0600 -o "${TARGET_USER}" -g "${TARGET_USER}" \
  /etc/rancher/k3s/k3s.yaml "${TARGET_HOME}/.kube/config"

if ! grep -q '^export KUBECONFIG=' "${TARGET_HOME}/.bashrc" 2>/dev/null; then
  # shellcheck disable=SC2016 # we want $HOME to be literal in .bashrc, not resolved here
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "${TARGET_HOME}/.bashrc"
fi

echo "[install] done. Verify: sudo -u ${TARGET_USER} kubectl get nodes"
