#!/usr/bin/env bash
#
# stabilize-tailscale.sh — protect tailscaled and sshd from the OOM killer.
#
# When k3s is restarted repeatedly (e.g. during credential rotation) the Pi
# can exhaust memory.  The OOM killer then terminates tailscaled or sshd,
# cutting off all remote access.  This script makes them OOM-resistant and
# auto-restarting so a transient memory spike does not cause a full lockout.
#
# Works on both omv (Pi 5, server) and omv-ha (Pi 4, agent).
# Diagnose-only by default; pass --apply to write the changes.
#
# Usage (run as root on the target node):
#   sudo ./stabilize-tailscale.sh           # diagnose, change nothing
#   sudo ./stabilize-tailscale.sh --apply   # apply the hardening
#
# --apply writes four systemd overrides (all reversible by deleting the file):
#   tailscaled  OOMScoreAdjust=-900, Restart=always, RestartSec=3
#   sshd        OOMScoreAdjust=-800, Restart=always, RestartSec=5
#   k3s         OOMScoreAdjust=-500 (if k3s is installed; matches omv-ha-k3s-prep)
#   k3s-agent   OOMScoreAdjust=-500 (if k3s-agent is installed)

set -euo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

if [ "$APPLY" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo for --apply." >&2
    exit 1
fi

sec()  { printf '\n=== %s ===\n' "$1"; }
note() { printf '  -> %s\n' "$1"; }
ok()   { printf '  [OK] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }

# --- System info -------------------------------------------------------------
sec "Host"
echo "  hostname : $(hostname)"
if [ -r /proc/device-tree/model ]; then
    echo "  model    : $(tr -d '\0' < /proc/device-tree/model)"
fi
free -h | awk '/^Mem:/{print "  memory   : " $2 " total, " $7 " available"}'

# --- Current OOM scores ------------------------------------------------------
sec "OOM scores (lower = more protected; -1000 = never killed)"
for svc in tailscaled sshd k3s k3s-agent; do
    pid=$(pgrep -x "$svc" 2>/dev/null | head -1 || true)
    if [ -n "$pid" ]; then
        score=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null || echo "?")
        printf '  %-12s pid=%-6s oom_score_adj=%s\n' "$svc" "$pid" "$score"
    else
        printf '  %-12s not running\n' "$svc"
    fi
done

# --- Current systemd Restart settings ----------------------------------------
sec "Restart policy"
for svc in tailscaled ssh sshd k3s k3s-agent; do
    unit_file=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2)
    if [ -n "$unit_file" ] && [ -f "$unit_file" ]; then
        restart=$(grep -E '^Restart=' "$unit_file" 2>/dev/null | head -1 || echo "Restart=<default>")
        printf '  %-12s %s\n' "$svc" "$restart"
    fi
done

# --- Existing overrides -------------------------------------------------------
sec "Existing systemd overrides"
for svc in tailscaled ssh sshd k3s k3s-agent; do
    override_dir="/etc/systemd/system/${svc}.service.d"
    if [ -d "$override_dir" ]; then
        echo "  $override_dir:"
        ls "$override_dir" | sed 's/^/    /'
    fi
done

if [ "$APPLY" -eq 0 ]; then
    cat <<'EOF'

Diagnose-only run — nothing changed. Re-run with --apply to harden OOM scores
and restart policies for tailscaled, sshd, and k3s.
EOF
    exit 0
fi

# --- Apply: tailscaled -------------------------------------------------------
sec "Apply: tailscaled OOM protection + auto-restart"
mkdir -p /etc/systemd/system/tailscaled.service.d
cat > /etc/systemd/system/tailscaled.service.d/oom-protect.conf <<'EOF'
# Managed by stabilize-tailscale.sh
[Service]
OOMScoreAdjust=-900
Restart=always
RestartSec=3
EOF
ok "tailscaled: OOMScoreAdjust=-900, Restart=always, RestartSec=3"

# Apply to running process without restart
TS_PID=$(pgrep -x tailscaled 2>/dev/null | head -1 || true)
if [ -n "$TS_PID" ]; then
    echo -900 > "/proc/$TS_PID/oom_score_adj" 2>/dev/null || true
    ok "  applied to running pid $TS_PID"
fi

# --- Apply: sshd -------------------------------------------------------------
sec "Apply: sshd OOM protection + auto-restart"
# sshd can be named "ssh" or "sshd" depending on distro
SSH_SVC="sshd"
if systemctl list-unit-files ssh.service &>/dev/null 2>&1 && \
   ! systemctl list-unit-files sshd.service &>/dev/null 2>&1; then
    SSH_SVC="ssh"
fi
mkdir -p "/etc/systemd/system/${SSH_SVC}.service.d"
cat > "/etc/systemd/system/${SSH_SVC}.service.d/oom-protect.conf" <<'EOF'
# Managed by stabilize-tailscale.sh
[Service]
OOMScoreAdjust=-800
Restart=always
RestartSec=5
EOF
ok "sshd (${SSH_SVC}): OOMScoreAdjust=-800, Restart=always, RestartSec=5"

SSHD_PID=$(pgrep -x sshd 2>/dev/null | head -1 || true)
if [ -n "$SSHD_PID" ]; then
    echo -800 > "/proc/$SSHD_PID/oom_score_adj" 2>/dev/null || true
    ok "  applied to running pid $SSHD_PID"
fi

# --- Apply: k3s / k3s-agent --------------------------------------------------
sec "Apply: k3s OOM protection"
for svc in k3s k3s-agent; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
        mkdir -p "/etc/systemd/system/${svc}.service.d"
        # Only write if not already set (omv-ha-k3s-prep may have done it already)
        override="/etc/systemd/system/${svc}.service.d/oom-protect.conf"
        if [ ! -f "$override" ] || ! grep -q 'OOMScoreAdjust' "$override" 2>/dev/null; then
            cat > "$override" <<'EOF'
# Managed by stabilize-tailscale.sh
[Service]
OOMScoreAdjust=-500
EOF
            ok "${svc}: OOMScoreAdjust=-500 written"
        else
            ok "${svc}: OOMScoreAdjust already set (skipped)"
        fi
        K3S_PID=$(pgrep -x "${svc}" 2>/dev/null | head -1 || true)
        if [ -n "$K3S_PID" ]; then
            echo -500 > "/proc/$K3S_PID/oom_score_adj" 2>/dev/null || true
            ok "  applied to running pid $K3S_PID"
        fi
    fi
done

# --- Reload systemd ----------------------------------------------------------
sec "Reload systemd"
systemctl daemon-reload
ok "daemon-reload complete"

# --- Verify ------------------------------------------------------------------
sec "Verification"
echo "  Tailscale:"
tailscale status 2>/dev/null | head -5 | sed 's/^/    /' || warn "tailscale status failed"

echo
echo "  OOM scores after hardening:"
for svc in tailscaled sshd k3s k3s-agent; do
    pid=$(pgrep -x "$svc" 2>/dev/null | head -1 || true)
    if [ -n "$pid" ]; then
        score=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null || echo "?")
        printf '    %-12s pid=%-6s oom_score_adj=%s\n' "$svc" "$pid" "$score"
    fi
done

sec "Done"
echo "  tailscaled  OOMScoreAdjust=-900  Restart=always  RestartSec=3"
echo "  sshd        OOMScoreAdjust=-800  Restart=always  RestartSec=5"
echo "  k3s/agent   OOMScoreAdjust=-500  (if installed)"
echo
echo "  These overrides survive reboots and k3s upgrades."
echo "  To undo: rm /etc/systemd/system/{tailscaled,${SSH_SVC},k3s,k3s-agent}.service.d/oom-protect.conf"
echo "           systemctl daemon-reload"
