#!/usr/bin/env bash
# Install a GitHub Actions self-hosted runner on a cluster Pi as a systemd
# service, so cluster-recovery workflows (.github/workflows/recover-standby.yml)
# can be triggered from the GitHub UI — phone included — with no SSH, laptop,
# or Tailscale.
#
# Run this ON the target Pi. Recommended host: omv-ha — a runner there
# survives an omv outage. Trade-off: omv-ha is a 1 GB Pi 4 and an idle runner
# is ~100-150 MB; if that's too tight, install on omv instead (it then can't
# help when omv itself is down).
#
# The runner is a HOST systemd service, NOT a k8s pod — on purpose: it must
# stay up when k3s itself is down.
#
# Prerequisites:
#   - RUNNER_TOKEN: a runner *registration* token (not a PAT), from
#     <REPO_URL>/settings/actions/runners/new — valid ~1h.
#   - The runner user needs passwordless SSH to omv (recover-standby.sh sshes
#     there to restart host services).
#
# Usage (on the Pi):
#   sudo RUNNER_TOKEN=XXXXXXXX ./install-cluster-runner.sh
#
# Env (with defaults):
#   REPO_URL        https://github.com/Themis128/OMV
#   RUNNER_LABELS   self-hosted,omv-recovery
#   RUNNER_USER     ${SUDO_USER:-tbaltzakis}
#   RUNNER_DIR      /opt/actions-runner
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Themis128/OMV}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,omv-recovery}"
RUNNER_USER="${RUNNER_USER:-${SUDO_USER:-tbaltzakis}}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"

: "${RUNNER_TOKEN:?RUNNER_TOKEN must be set — get one at ${REPO_URL}/settings/actions/runners/new}"

if [[ ${EUID} -ne 0 ]]; then
  echo "must run as root (sudo) — this installs a systemd service" >&2
  exit 1
fi

case "$(uname -m)" in
  aarch64|arm64) RUNNER_ARCH="arm64" ;;
  x86_64)        RUNNER_ARCH="x64" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

echo "[runner] resolving latest actions/runner release"
TAG="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')"
[[ -n "${TAG}" ]] || { echo "could not resolve runner version" >&2; exit 1; }
echo "[runner] version ${TAG}, arch ${RUNNER_ARCH}, host $(hostname)"

install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" "${RUNNER_DIR}"
cd "${RUNNER_DIR}"

if [[ ! -x ./config.sh ]]; then
  TARBALL="actions-runner-linux-${RUNNER_ARCH}-${TAG}.tar.gz"
  echo "[runner] downloading ${TARBALL}"
  curl -fsSL -o "${TARBALL}" \
    "https://github.com/actions/runner/releases/download/v${TAG}/${TARBALL}"
  sudo -u "${RUNNER_USER}" tar xzf "${TARBALL}"
  rm -f "${TARBALL}"
fi

# Re-running re-registers cleanly (token rotates each time).
if [[ -f .runner ]]; then
  echo "[runner] existing registration found — replacing"
fi

echo "[runner] registering with ${REPO_URL}"
sudo -u "${RUNNER_USER}" ./config.sh \
  --url "${REPO_URL}" \
  --token "${RUNNER_TOKEN}" \
  --name "$(hostname)-recovery" \
  --labels "${RUNNER_LABELS}" \
  --unattended --replace

echo "[runner] installing + starting systemd service"
./svc.sh install "${RUNNER_USER}"
./svc.sh start

echo "[runner] done — labels '${RUNNER_LABELS}' active on $(hostname)"
echo "[runner] trigger recovery: ${REPO_URL}/actions/workflows/recover-standby.yml"
