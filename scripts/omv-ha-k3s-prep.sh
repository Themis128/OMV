#!/usr/bin/env bash
#
# omv-ha-k3s-prep.sh — keep omv-ha a lean, stable k3s control-plane node.
#
# omv-ha is a 1 GB Raspberry Pi 3 running k3s + an embedded etcd member.
# This script supports that role WITHOUT installing OpenMediaVault: it
# reports the things that matter for a constrained k3s node and applies a
# couple of safe, idempotent, reversible tunes.
#
# Diagnose-only by default; pass --apply to apply the tunes.
#
# Usage (run on omv-ha):
#   sudo ./omv-ha-k3s-prep.sh           # diagnose, change nothing
#   sudo ./omv-ha-k3s-prep.sh --apply   # apply the safe tunes
#
# --apply makes only these changes (both reversible by deleting the file):
#   * caps the systemd journal size  (/etc/systemd/journald.conf.d/) so
#     logging stops steadily wearing the SD card
#   * a sysctl drop-in (/etc/sysctl.d/) — favours fast zram swap over a
#     hard OOM that would kill etcd, and keeps the FS cache warm
#
# Power, RAM-hungry processes, package upgrades and moving etcd off the SD
# card are reported as recommendations — never changed automatically.

set -u

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"
if [ "$APPLY" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo for --apply." >&2
    exit 1
fi

sec()  { printf '\n=== %s ===\n' "$1"; }
note() { printf '  -> %s\n' "$1"; }

# --- Host ------------------------------------------------------------------
sec "Host"
echo "  hostname : $(hostname)"
if [ -r /proc/device-tree/model ]; then
    echo "  model    : $(tr -d '\0' < /proc/device-tree/model)"
else
    echo "  model    : (unknown)"
fi
free -h | awk '/^Mem:/{print "  memory   : " $2 " total, " $7 " available"}'

# --- Power (undervoltage is fatal for etcd integrity) ----------------------
sec "Power / throttling"
if command -v vcgencmd >/dev/null 2>&1; then
    raw=$(vcgencmd get_throttled 2>/dev/null | sed 's/.*=//')
    val=$(( raw ))
    echo "  vcgencmd get_throttled = ${raw:-unknown}"
    if [ "$val" -eq 0 ]; then
        echo "  [OK] no undervoltage or throttling"
    else
        (( val & 0x1 ))     && note "UNDER-VOLTAGE right now — fix the PSU/cable"
        (( val & 0x4 ))     && note "CPU is being throttled right now"
        (( val & 0x10000 )) && note "under-voltage has occurred since boot"
        (( val & 0x40000 )) && note "throttling has occurred since boot"
    fi
else
    echo "  vcgencmd not available — cannot read power state"
fi

# --- Memory pressure -------------------------------------------------------
sec "Top memory consumers (RSS)"
ps -eo rss,pid,user,comm --sort=-rss 2>/dev/null | head -8 \
    | awk 'NR==1{print "  "$0} NR>1{printf "  %6.1f MiB  %s  %s\n",$1/1024,$3,$4}'
echo "  (non-k3s hogs such as a remote-IDE agent can be closed to free RAM)"

# --- Swap ------------------------------------------------------------------
sec "Swap devices (zram should out-prioritise any disk swap)"
swapon --show 2>/dev/null || echo "  (no swap configured)"

# --- Journal size on the SD card -------------------------------------------
sec "systemd journal on disk"
journalctl --disk-usage 2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"

# --- etcd snapshots --------------------------------------------------------
sec "k3s etcd snapshots"
snapdir="/var/lib/rancher/k3s/server/db/snapshots"
if $SUDO test -d "$snapdir" 2>/dev/null; then
    count=$($SUDO sh -c "ls -1 '$snapdir' 2>/dev/null | wc -l")
    newest=$($SUDO sh -c "ls -t '$snapdir' 2>/dev/null | head -1")
    echo "  snapshot dir : $snapdir"
    echo "  snapshots    : ${count:-0}"
    echo "  newest       : ${newest:-none}"
    [ "${count:-0}" -eq 0 ] && note "no etcd snapshots — enable k3s automatic snapshots"
else
    echo "  $snapdir not found — k3s embedded etcd snapshots not present"
fi

# --- Pending package upgrades ----------------------------------------------
sec "Pending package upgrades"
up=$(apt list --upgradable 2>/dev/null | grep -c '\[upgradable from' || true)
echo "  ${up:-0} package(s) upgradable"
[ "${up:-0}" -gt 0 ] && note "upgrade with 'sudo apt full-upgrade' — but only once power is stable"

if [ "$APPLY" -eq 0 ]; then
    cat <<'EOF'

Diagnose-only run — nothing changed. Re-run with --apply to apply the
journal-size cap and the sysctl drop-in.

Reported but never auto-changed (deliberate):
  * Power: undervoltage needs a proper PSU/cable — hardware only.
  * RAM-hungry non-k3s processes: close them yourself.
  * Package upgrades: run after power is confirmed stable.
  * Moving etcd off the SD card to a USB SSD: a manual change.
EOF
    exit 0
fi

# --- Apply: cap the journal so it stops wearing the SD card ----------------
sec "Apply: cap the systemd journal size"
jdir="/etc/systemd/journald.conf.d"
mkdir -p "$jdir"
cat > "$jdir/omv-ha-k3s.conf" <<'EOF'
# Managed by omv-ha-k3s-prep.sh — cap the journal so logging does not
# steadily wear the SD card on this k3s node.
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
systemctl restart systemd-journald
echo "  journal capped at 200M and journald restarted"

# --- Apply: sysctl tuning for a 1 GB zram-equipped k3s node ----------------
sec "Apply: sysctl drop-in"
cat > /etc/sysctl.d/90-omv-ha-k3s.conf <<'EOF'
# Managed by omv-ha-k3s-prep.sh.
# Favour fast compressed zram swap over a hard OOM that would kill etcd,
# and keep the filesystem cache warm on a memory-constrained node.
vm.swappiness = 100
vm.vfs_cache_pressure = 50
EOF
sysctl --system >/dev/null 2>&1
echo "  sysctl drop-in written and loaded (swappiness=100, vfs_cache_pressure=50)"

sec "Done"
echo "  Tunes applied. Power, RAM hogs and package upgrades still need"
echo "  your attention — see the recommendations above."
