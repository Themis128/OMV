#!/usr/bin/env bash
#
# omv-install.sh — install OpenMediaVault on the omv NAS node.
#
# omv (the Raspberry Pi 5, 8 GB) is the NAS host — OpenMediaVault belongs
# there. This script (re)installs it.
#
# DO NOT run this on omv-ha: that node is a 1 GB Raspberry Pi 3 running the
# k3s control plane and an etcd member; OMV would OOM-kill etcd. The script
# refuses to run on a host that looks like the HA node or that has too
# little RAM.
#
# Diagnose-only by default; pass --apply to install.
#
# Usage (run on omv):
#   sudo ./omv-install.sh           # diagnose, change nothing
#   sudo ./omv-install.sh --apply   # install OpenMediaVault
#
# After install, if ports 80/443 are held by another service (Pi-hole on
# this host holds 80), set the OMV web UI to a free port:
#   sudo omv-firstaid   ->  "Configure the web control panel"

set -u

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo." >&2
    exit 1
fi

sec() { printf '\n=== %s ===\n' "$1"; }

# --- Host guard — never install OMV on the k3s/etcd HA node ----------------
sec "Host guard"
host=$(hostname)
echo "  hostname  : $host"
if printf '%s' "$host" | grep -qi 'omv-ha'; then
    echo "  REFUSING: this is the k3s HA node (omv-ha)." >&2
    echo "  Installing OMV on a 1 GB etcd node risks OOM-killing etcd." >&2
    exit 1
fi
mem_mb=$(free -m | awk '/^Mem:/{print $2}')
echo "  total RAM : ${mem_mb} MiB"
if [ "${mem_mb:-0}" -lt 3000 ]; then
    echo "  REFUSING: under 3 GiB RAM — not enough headroom for OMV." >&2
    echo "  This guards against running on the 1 GB omv-ha node." >&2
    exit 1
fi

# --- Current state ---------------------------------------------------------
sec "OpenMediaVault status"
if dpkg-query -W -f='${db:Status-Abbrev}' openmediavault 2>/dev/null | grep -q '^ii'; then
    echo "  openmediavault is already installed."
    echo "  Use scripts/omv-repair.sh if it is broken — nothing to do here."
    exit 0
fi
echo "  openmediavault is not installed — this script will install it."

omv_list="/etc/apt/sources.list.d/openmediavault.list"
if [ -f "$omv_list" ] && grep -qE '^deb ' "$omv_list"; then
    echo "  OMV apt repository: present (will install via apt)"
    repo_present=1
else
    echo "  OMV apt repository: absent (will use the official installer)"
    repo_present=0
fi

sec "Ports 80 / 443 (OMV web UI)"
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

Diagnose-only run — nothing changed. Re-run with --apply to install.

If ports 80/443 are in use (Pi-hole holds 80 on this host), set the OMV
web UI to a free port after install:
  sudo omv-firstaid  ->  "Configure the web control panel"
EOF
    exit 0
fi

# --- Install ---------------------------------------------------------------
if [ "$repo_present" -eq 1 ]; then
    sec "Install: apt (OMV repository already configured)"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y openmediavault
else
    sec "Install: official OpenMediaVault installer"
    tmp=$(mktemp)
    url="https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install"
    if ! curl -fsSL "$url" -o "$tmp"; then
        echo "Could not download the OMV install script." >&2
        rm -f "$tmp"
        exit 1
    fi
    bash "$tmp"
    rm -f "$tmp"
fi

sec "Result"
systemctl is-active openmediavault-engined nginx 2>/dev/null || true
cat <<'EOF'

OpenMediaVault install finished.

Next steps:
  * If nginx failed to bind, ports 80/443 are taken (Pi-hole). Set a free
    web UI port:  sudo omv-firstaid  ->  "Configure the web control panel"
  * Re-add your shared folders / SMB shares from the OMV web UI.
  * Run scripts/omv-healthcheck.sh to confirm the engine is active.
EOF
