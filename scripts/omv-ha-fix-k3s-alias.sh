#!/usr/bin/env bash
#
# omv-ha-fix-k3s-alias.sh — create a k3s.service alias on omv-ha.
#
# After demoting omv-ha from k3s server to k3s agent, the service is named
# k3s-agent.service. OMV's monit monitor still watches k3s.service (configured
# in the OMV web UI) and sends hourly "k3s.service is not running" emails.
#
# Fix: install a simple systemd alias unit so that k3s.service is a no-op
# wrapper that starts/stops/reports the real k3s-agent.service underneath.
# OMV monit sees k3s.service as "active" and stops alerting.
#
# Safe to re-run — idempotent.
#
# Usage (run as root on omv-ha):
#   sudo ./omv-ha-fix-k3s-alias.sh

set -euo pipefail

UNIT=/etc/systemd/system/k3s.service

if systemctl is-active --quiet k3s.service 2>/dev/null; then
    echo "[SKIP] k3s.service is already active — no alias needed."
    exit 0
fi

if ! systemctl is-active --quiet k3s-agent.service 2>/dev/null; then
    echo "[WARN] k3s-agent.service is not active either — starting it first."
    systemctl start k3s-agent.service
fi

echo "[APPLY] Writing k3s.service alias → k3s-agent.service"
cat > "${UNIT}" <<'EOF'
# Managed by omv-ha-fix-k3s-alias.sh
# Alias unit: makes k3s.service a transparent proxy for k3s-agent.service.
# OMV monit watches k3s.service; this keeps the monitor happy after the
# omv-ha demotion from server to agent.
[Unit]
Description=k3s agent (alias for OMV monit compatibility)
BindsTo=k3s-agent.service
After=k3s-agent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'systemctl is-active --quiet k3s-agent.service || systemctl start k3s-agent.service'
ExecStop=/bin/sh -c 'true'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable k3s.service
systemctl start k3s.service

echo "[OK] k3s.service alias installed and active."
echo "     OMV monit will now see k3s.service as running."
echo ""
echo "Verify:"
echo "  systemctl is-active k3s.service    # should say: active"
echo "  systemctl is-active k3s-agent.service  # should say: active"
