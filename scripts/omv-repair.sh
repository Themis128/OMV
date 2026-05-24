#!/usr/bin/env bash
#
# omv-repair.sh — diagnose and repair a broken OpenMediaVault control plane.
#
# Addresses the case where the openmediavault package is installed but its
# service units (openmediavault-engined, nginx, php-fpm, rrdcached) are
# missing — the web UI and engine are down and monit floods the journal
# retrying them.
#
# Diagnose-only by default; pass --apply to perform the repair. The repair
# reinstalls the openmediavault package: its postinst regenerates the
# configuration and apt restores any missing dependencies.
#
# Usage (run on the Pi):
#   sudo ./omv-repair.sh            # diagnose, change nothing
#   sudo ./omv-repair.sh --apply    # reinstall openmediavault and restart
#
# If the engine still will not start, use the official interactive tool:
#   sudo omv-firstaid

set -euo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo — this changes system state when --apply is given." >&2
    exit 1
fi

sec() { printf '\n=== %s ===\n' "$1"; }

# --- Diagnose --------------------------------------------------------------
sec "openmediavault package"
dpkg-query -W -f='${Package} ${Version}\n' openmediavault 2>/dev/null \
    || echo "openmediavault is NOT installed"

sec "OMV service units"
for unit in openmediavault-engined nginx php8.4-fpm rrdcached collectd; do
    if systemctl cat "${unit}.service" >/dev/null 2>&1; then
        printf '  %-22s present — %s\n' "$unit" \
            "$(systemctl is-active "$unit" 2>/dev/null)"
    else
        printf '  %-22s MISSING (unit file not found)\n' "$unit"
    fi
done

sec "Ports 80 / 443 (the OMV web UI needs these, or a custom port)"
for p in 80 443; do
    holder=$(ss -ltnp "( sport = :$p )" 2>/dev/null | awk 'NR==2')
    if [ -n "$holder" ]; then
        echo "  port $p IN USE:$holder"
    else
        echo "  port $p free"
    fi
done

if [ "$APPLY" -eq 0 ]; then
    cat <<'EOF'

Diagnose-only run — nothing changed. Re-run with --apply to repair.

If ports 80/443 are held by another service (e.g. Pi-hole), the OMV web
UI port must be changed after repair (System > Workbench in the UI, or
via omv-firstaid) so nginx does not conflict on start.
EOF
    exit 0
fi

# --- Repair ----------------------------------------------------------------
sec "Repair: apt update"
apt-get update

sec "Repair: reinstall openmediavault (regenerates config, restores deps)"
DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y openmediavault

sec "Repair: configure any half-installed packages"
DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y
dpkg --configure -a

sec "Repair: enable and (re)start the OMV stack"
for unit in rrdcached php8.4-fpm nginx openmediavault-engined; do
    if ! systemctl cat "${unit}.service" >/dev/null 2>&1; then
        echo "  ${unit}: still missing after reinstall"
        continue
    fi
    systemctl enable "$unit" >/dev/null 2>&1 || true
    if systemctl restart "$unit" 2>/dev/null; then
        echo "  ${unit}: $(systemctl is-active "$unit")"
    else
        echo "  ${unit}: failed — check 'systemctl status ${unit}'"
    fi
done

sec "Result"
systemctl is-active openmediavault-engined nginx php8.4-fpm rrdcached 2>/dev/null || true
cat <<'EOF'

If openmediavault-engined is not 'active', run: sudo omv-firstaid
If nginx failed to start, ports 80/443 are likely taken — change the OMV
web UI port (System > Workbench) and restart nginx.
EOF
