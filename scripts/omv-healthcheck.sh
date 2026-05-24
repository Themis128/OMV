#!/usr/bin/env bash
#
# omv-healthcheck.sh — read-only health report for an OpenMediaVault host.
#
# Runs a series of non-destructive checks and prints a pass/warn/fail summary.
# Safe to run anytime; it never changes system state.
#
# Usage:
#   ./omv-healthcheck.sh            # full report
#   ./omv-healthcheck.sh --quiet    # summary only, skip detailed sections
#
# Exit code: 0 if no failures, 1 if any check failed.

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

PASS=0
WARN=0
FAIL=0

c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_yellow(){ printf '\033[33m%s\033[0m' "$1"; }

ok()   { PASS=$((PASS+1)); printf '  [%s] %s\n' "$(c_green PASS)" "$1"; }
warn() { WARN=$((WARN+1)); printf '  [%s] %s\n' "$(c_yellow WARN)" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  [%s] %s\n' "$(c_red FAIL)" "$1"; }

section() { printf '\n=== %s ===\n' "$1"; }

detail() {
    [ "$QUIET" -eq 1 ] && return
    while IFS= read -r line; do printf '      %s\n' "$line"; done
}

# Use sudo only when not already root.
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

printf 'OMV Health Check — %s — %s\n' "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- OMV engine ------------------------------------------------------------
section "OMV engine daemon"
if ! dpkg-query -W -f='${db:Status-Abbrev}' openmediavault 2>/dev/null | grep -q '^ii'; then
    ok "OpenMediaVault not installed on this host — skipping OMV checks"
elif systemctl is-active --quiet openmediavault-engined; then
    ok "openmediavault-engined is running"
else
    fail "openmediavault-engined is not running"
    $SUDO systemctl status openmediavault-engined --no-pager 2>&1 | head -10 | detail
fi

# --- Failed systemd units --------------------------------------------------
section "Failed systemd units"
failed_units=$($SUDO systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $1}')
if [ -z "$failed_units" ]; then
    ok "no failed units"
else
    fail "$(echo "$failed_units" | wc -l) failed unit(s)"
    echo "$failed_units" | detail
fi

# --- Journal errors this boot ----------------------------------------------
section "Journal errors (this boot)"
err_count=$($SUDO journalctl -q -p err -b --no-pager 2>/dev/null | grep -c . || true)
if [ "${err_count:-0}" -eq 0 ]; then
    ok "no error-level journal entries"
elif [ "${err_count:-0}" -lt 10 ]; then
    warn "$err_count error-level journal entries"
    $SUDO journalctl -q -p err -b --no-pager 2>/dev/null | tail -10 | detail
else
    warn "$err_count error-level journal entries (showing last 10)"
    $SUDO journalctl -q -p err -b --no-pager 2>/dev/null | tail -10 | detail
fi

# --- Kernel errors ---------------------------------------------------------
section "Kernel messages (errors and worse)"
dmesg_err=$($SUDO dmesg --level=err,crit,alert,emerg 2>/dev/null | grep -c . || true)
if [ "${dmesg_err:-0}" -eq 0 ]; then
    ok "no kernel error messages"
else
    warn "$dmesg_err kernel error message(s)"
    $SUDO dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -10 | detail
fi

# --- Disk usage ------------------------------------------------------------
section "Disk usage"
while IFS= read -r line; do
    use=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    [ -z "${use:-}" ] && continue
    case "$use" in (*[!0-9]*) continue;; esac
    if [ "$use" -ge 90 ]; then
        fail "$mount is ${use}% full"
    elif [ "$use" -ge 80 ]; then
        warn "$mount is ${use}% full"
    else
        ok "$mount is ${use}% full"
    fi
done < <(df -hP -x tmpfs -x devtmpfs -x overlay 2>/dev/null | tail -n +2)

# --- Memory ----------------------------------------------------------------
section "Memory"
mem_line=$(free -m | awk '/^Mem:/{print $2, $7}')
mem_total=$(echo "$mem_line" | awk '{print $1}')
mem_avail=$(echo "$mem_line" | awk '{print $2}')
if [ -n "${mem_total:-}" ] && [ "${mem_total:-0}" -gt 0 ]; then
    avail_pct=$(( mem_avail * 100 / mem_total ))
    if [ "$avail_pct" -lt 10 ]; then
        fail "only ${avail_pct}% memory available (${mem_avail}MB / ${mem_total}MB)"
    elif [ "$avail_pct" -lt 20 ]; then
        warn "${avail_pct}% memory available (${mem_avail}MB / ${mem_total}MB)"
    else
        ok "${avail_pct}% memory available (${mem_avail}MB / ${mem_total}MB)"
    fi
fi

# --- Load average ----------------------------------------------------------
section "Load average"
cores=$(nproc)
load5=$(awk '{print $2}' /proc/loadavg)
load5_int=${load5%.*}
if [ "${load5_int:-0}" -ge $(( cores * 2 )) ]; then
    fail "5-min load ${load5} (>= 2x ${cores} cores)"
elif [ "${load5_int:-0}" -ge "$cores" ]; then
    warn "5-min load ${load5} (>= ${cores} cores)"
else
    ok "5-min load ${load5} (${cores} cores)"
fi

# --- Power / undervoltage (Raspberry Pi) -----------------------------------
section "Power"
if command -v vcgencmd >/dev/null 2>&1; then
    throttled=$(vcgencmd get_throttled 2>/dev/null | sed 's/.*=//')
    tval=$(( ${throttled:-0} ))
    if [ "$tval" -eq 0 ]; then
        ok "no undervoltage or throttling"
    else
        if (( tval & 0x1 )); then
            fail "under-voltage right now (get_throttled=$throttled) — check PSU/cable"
        elif (( tval & 0x10000 )); then
            warn "under-voltage has occurred since boot (get_throttled=$throttled)"
        fi
        if (( tval & 0x4 )); then
            warn "CPU is currently throttled (get_throttled=$throttled)"
        elif (( tval & 0x40000 )); then
            warn "throttling has occurred since boot (get_throttled=$throttled)"
        fi
    fi
else
    ok "vcgencmd not available — skipping power check"
fi

# --- APT repositories ------------------------------------------------------
section "APT repositories"
apt_out=$($SUDO apt-get update -qq 2>&1)
if echo "$apt_out" | grep -qiE 'error|no longer has a Release file'; then
    fail "apt update reported errors"
    echo "$apt_out" | grep -iE 'error|Release file' | detail
else
    ok "apt update is clean"
fi

upgradable=$(apt list --upgradable 2>/dev/null | grep -c '\[upgradable from' || true)
if [ "${upgradable:-0}" -gt 0 ]; then
    warn "$upgradable package(s) upgradable"
else
    ok "all packages up to date"
fi

# --- Logrotate -------------------------------------------------------------
section "Logrotate"
lr_out=$($SUDO logrotate -d /etc/logrotate.conf 2>&1)
if echo "$lr_out" | grep -qi 'error:'; then
    fail "logrotate configuration has errors"
    echo "$lr_out" | grep -i 'error:' | detail
else
    ok "logrotate configuration is valid"
fi

# --- Time sync -------------------------------------------------------------
section "Time synchronisation"
if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes; then
        ok "system clock is NTP-synchronised"
    else
        warn "system clock is not NTP-synchronised"
    fi
fi

# --- SMART disk health -----------------------------------------------------
section "SMART disk health"
if command -v smartctl >/dev/null 2>&1; then
    found=0
    for dev in /dev/sd? /dev/nvme?n?; do
        [ -e "$dev" ] || continue
        found=1
        health=$($SUDO smartctl -H "$dev" 2>/dev/null | grep -iE 'overall-health|SMART Health' | head -1)
        if echo "$health" | grep -qi 'PASSED\|OK'; then
            ok "$dev SMART health: PASSED"
        elif [ -n "$health" ]; then
            fail "$dev SMART health: $health"
        else
            warn "$dev SMART status unreadable"
        fi
    done
    [ "$found" -eq 0 ] && ok "no SATA/NVMe disks present (SD-card boot)"
else
    warn "smartctl not installed — skipping SMART checks"
fi

# --- Summary ---------------------------------------------------------------
section "Summary"
printf '  %s passed, %s warnings, %s failures\n' \
    "$(c_green "$PASS")" "$(c_yellow "$WARN")" "$(c_red "$FAIL")"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
