#!/usr/bin/env bash
#
# omv-inventory.sh — read-only inventory of an OpenMediaVault host.
#
# Prints a full picture of the system: hardware, OS, OMV version, storage
# (disks, partitions, filesystems, RAID, mergerfs, ZFS, SMART), network,
# services, containers, shares, users, and installed OMV plugins.
#
# Read-only — it never changes system state.
#
# Usage:
#   ./omv-inventory.sh                 # print report
#   ./omv-inventory.sh > inventory.txt # save report to a file

set -u

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

section() { printf '\n========== %s ==========\n' "$1"; }
sub()     { printf '\n--- %s ---\n' "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }

# show <label> <command...> — run a command, or note it is unavailable.
show() {
    local label="$1"; shift
    sub "$label"
    if "$@" 2>/dev/null; then :; else echo "(unavailable)"; fi
}

printf 'OMV Inventory — %s — %s\n' "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- Hardware --------------------------------------------------------------
section "Hardware"
sub "Model"
cat /proc/device-tree/model 2>/dev/null && echo || echo "(unknown)"
sub "Serial"
awk -F': ' '/Serial/{print $2}' /proc/cpuinfo 2>/dev/null | tail -1
sub "CPU"
have lscpu && lscpu | grep -E 'Model name|^CPU\(s\)|Architecture' || nproc
sub "Memory"
free -h

# --- Operating system -----------------------------------------------------
section "Operating system"
sub "Distribution"
[ -f /etc/os-release ] && grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release
sub "Kernel"
uname -a
sub "Uptime"
uptime

# --- OpenMediaVault --------------------------------------------------------
section "OpenMediaVault"
sub "Package version"
dpkg-query -W -f='${Version}\n' openmediavault 2>/dev/null || echo "(not installed)"
sub "Engine daemon"
systemctl is-active openmediavault-engined 2>/dev/null
sub "Installed OMV plugins"
dpkg-query -W -f='${Package} ${Version}\n' 'openmediavault-*' 2>/dev/null \
    | grep -v '^openmediavault ' || echo "(none)"

# --- Storage ---------------------------------------------------------------
section "Storage"
show "Block devices (lsblk)" lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT,LABEL,MODEL
show "Filesystem usage (df)" df -hT -x tmpfs -x devtmpfs -x overlay
show "Partition/FS UUIDs (blkid)" $SUDO blkid
show "Mounts (fstab)" grep -vE '^\s*#|^\s*$' /etc/fstab

sub "RAID (mdadm)"
if [ -f /proc/mdstat ] && grep -q 'md' /proc/mdstat 2>/dev/null; then
    cat /proc/mdstat
else
    echo "(no Linux software RAID)"
fi

sub "mergerfs pools"
if mount 2>/dev/null | grep -q 'fuse.mergerfs'; then
    mount | grep 'fuse.mergerfs'
else
    echo "(no mergerfs mounts)"
fi

sub "ZFS pools"
if have zpool; then
    $SUDO zpool list 2>/dev/null && $SUDO zpool status 2>/dev/null
else
    echo "(ZFS not installed)"
fi

sub "LVM"
if have pvs; then
    $SUDO pvs 2>/dev/null; $SUDO vgs 2>/dev/null; $SUDO lvs 2>/dev/null
else
    echo "(LVM not installed)"
fi

sub "SMART health"
if have smartctl; then
    for dev in /dev/sd? /dev/nvme?n? /dev/hd?; do
        [ -e "$dev" ] || continue
        printf '%s: ' "$dev"
        $SUDO smartctl -H "$dev" 2>/dev/null \
            | grep -iE 'overall-health|SMART Health' | head -1 \
            | sed 's/^.*: //' || echo "(unreadable)"
    done
    ls /dev/sd? /dev/nvme?n? /dev/hd? >/dev/null 2>&1 || echo "(no SATA/NVMe/IDE disks)"
else
    echo "(smartctl not installed)"
fi

# --- Network ---------------------------------------------------------------
section "Network"
show "Interfaces and addresses" ip -brief address
show "Routing table" ip route
sub "Listening services (ports)"
$SUDO ss -tulnp 2>/dev/null || ss -tuln 2>/dev/null || echo "(unavailable)"

# --- Services --------------------------------------------------------------
section "Services"
sub "File-sharing and NAS services"
for svc in smbd nmbd nfs-server rpcbind proftpd vsftpd \
           openmediavault-engined nginx php8.4-fpm \
           fail2ban monit postfix rrdcached rrdcached \
           ssh docker containerd tailscaled; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 \
       && systemctl cat "${svc}.service" >/dev/null 2>&1; then
        printf '  %-26s %s\n' "$svc" "$(systemctl is-active "${svc}.service" 2>/dev/null)"
    fi
done
sub "Failed units"
$SUDO systemctl --failed --no-pager --no-legend 2>/dev/null || echo "(none)"

# --- Shares ----------------------------------------------------------------
section "Shares"
sub "Samba shares"
if [ -f /etc/samba/smb.conf ]; then
    grep -E '^\[' /etc/samba/smb.conf | grep -viE '\[global\]|\[printers\]|\[print\$\]' \
        || echo "(no shares defined)"
else
    echo "(Samba not configured)"
fi
sub "NFS exports"
[ -f /etc/exports ] && grep -vE '^\s*#|^\s*$' /etc/exports || echo "(no NFS exports)"

# --- Containers ------------------------------------------------------------
section "Containers"
sub "Docker containers"
if have docker; then
    $SUDO docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null \
        || echo "(docker not running)"
else
    echo "(docker not installed)"
fi
sub "Podman containers"
if have podman; then
    $SUDO podman ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null \
        || echo "(podman not running)"
else
    echo "(podman not installed)"
fi
sub "Docker Compose projects"
if have docker; then
    $SUDO docker compose ls 2>/dev/null || echo "(none / compose plugin absent)"
fi

# --- Users -----------------------------------------------------------------
section "Users"
sub "Human accounts (UID >= 1000)"
awk -F: '$3 >= 1000 && $3 < 65534 {printf "  %s (uid %s, %s)\n", $1, $3, $7}' /etc/passwd
sub "Samba users"
have pdbedit && $SUDO pdbedit -L 2>/dev/null || echo "(none / pdbedit unavailable)"

printf '\n========== End of inventory ==========\n'
