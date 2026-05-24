#!/usr/bin/env bash
#
# omv-apply-fixes.sh — apply the OMV host maintenance fixes.
#
# Reproduces the changes made during the OMV maintenance session. Every fix is
# idempotent: re-running the script only acts where a fix is still needed.
#
# Fixes applied:
#   1. Comment out the dead packages.openmediavault.org APT repository.
#   2. Mask systemd-networkd-wait-online.service (nothing for it to wait on;
#      all interfaces are managed outside systemd-networkd).
#   3. Defer apt-daily / apt-daily-upgrade timers off the boot path.
#   4. Remove the duplicate fail2ban.log stanza from omv-nas-logs
#      (fail2ban ships its own logrotate config).
#   5. Clear future-dated Salt cache files that slow openmediavault-issue.
#   6. Reset failed systemd units.
#
# Usage:
#   sudo ./omv-apply-fixes.sh             # apply fixes
#   sudo ./omv-apply-fixes.sh --dry-run   # show what would change, change nothing
#
# Exit code: 0 on success, 1 if any fix errored.

set -u

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ "$(id -u)" -ne 0 ]; then
    echo "This script changes system state — run it with sudo." >&2
    exit 1
fi

APPLIED=0
SKIPPED=0
ERRORS=0

c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_blue()  { printf '\033[34m%s\033[0m' "$1"; }

applied() { APPLIED=$((APPLIED+1)); printf '  [%s] %s\n' "$(c_green APPLIED)" "$1"; }
skipped() { SKIPPED=$((SKIPPED+1)); printf '  [%s]    %s\n' "$(c_blue SKIP)" "$1"; }
errored() { ERRORS=$((ERRORS+1));  printf '  [%s]   %s\n' "$(c_red ERROR)" "$1"; }
section() { printf '\n=== %s ===\n' "$1"; }

# run <description> <command...> — execute, or just describe under --dry-run.
run() {
    local desc="$1"; shift
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [%s]  would: %s\n' "$(c_blue DRY)" "$desc"
        return 0
    fi
    if "$@"; then
        return 0
    else
        errored "$desc"
        return 1
    fi
}

printf 'OMV Apply Fixes — %s — %s\n' "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
[ "$DRY_RUN" -eq 1 ] && printf '(dry run — no changes will be made)\n'

# --- Fix 1: dead OMV APT repository ---------------------------------------
section "Fix 1: dead OMV APT repository"
OMV_LIST="/etc/apt/sources.list.d/openmediavault.list"
if [ ! -f "$OMV_LIST" ]; then
    skipped "$OMV_LIST not present"
elif grep -qE '^deb .*packages\.openmediavault\.org' "$OMV_LIST"; then
    if run "comment out packages.openmediavault.org lines" \
        sed -i 's|^deb \(.*packages\.openmediavault\.org.*\)|# deb \1|g' "$OMV_LIST"; then
        [ "$DRY_RUN" -eq 0 ] && applied "dead OMV repo commented out"
    fi
else
    skipped "no active packages.openmediavault.org repo line"
fi

# --- Fix 2: mask systemd-networkd-wait-online -----------------------------
section "Fix 2: systemd-networkd-wait-online.service"
if systemctl is-enabled systemd-networkd-wait-online.service 2>/dev/null | grep -qx masked; then
    skipped "service already masked"
else
    if run "mask systemd-networkd-wait-online.service" \
        systemctl mask systemd-networkd-wait-online.service; then
        [ "$DRY_RUN" -eq 0 ] && applied "systemd-networkd-wait-online.service masked"
    fi
fi

# --- Fix 3: defer apt-daily timers off the boot path ----------------------
section "Fix 3: apt-daily timer scheduling"
write_timer_override() {
    local timer="$1" boot_delay="$2"
    local dir="/etc/systemd/system/${timer}.d"
    local file="${dir}/override.conf"
    local content="[Timer]
OnCalendar=
OnBootSec=${boot_delay}
OnUnitActiveSec=1d
RandomizedDelaySec=5min"

    if [ -f "$file" ] && [ "$(cat "$file" 2>/dev/null)" = "$content" ]; then
        skipped "${timer} override already in place"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [%s]  would: write %s (OnBootSec=%s)\n' "$(c_blue DRY)" "$file" "$boot_delay"
        return 0
    fi
    if mkdir -p "$dir" && printf '%s\n' "$content" > "$file"; then
        [ "$DRY_RUN" -eq 0 ] && applied "${timer} deferred to OnBootSec=${boot_delay}"
    else
        errored "writing ${file}"
    fi
}
write_timer_override "apt-daily.timer" "15min"
write_timer_override "apt-daily-upgrade.timer" "30min"
if [ "$DRY_RUN" -eq 0 ]; then
    systemctl daemon-reload 2>/dev/null || errored "systemctl daemon-reload"
fi

# --- Fix 4: duplicate fail2ban.log logrotate stanza -----------------------
section "Fix 4: logrotate duplicate fail2ban.log stanza"
NAS_LOGS="/etc/logrotate.d/omv-nas-logs"
if [ ! -f "$NAS_LOGS" ]; then
    skipped "$NAS_LOGS not present"
elif [ ! -f /etc/logrotate.d/fail2ban ]; then
    skipped "no /etc/logrotate.d/fail2ban — not a duplicate"
elif ! grep -qE '^[[:space:]]*/var/log/fail2ban\.log[[:space:]]*\{' "$NAS_LOGS"; then
    skipped "no active fail2ban.log stanza in omv-nas-logs"
else
    # Remove the "/var/log/fail2ban.log { ... }" block and an immediately
    # preceding "# fail2ban" comment line.
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  [%s]  would: remove fail2ban.log stanza from %s\n' "$(c_blue DRY)" "$NAS_LOGS"
    else
        tmp=$(mktemp)
        awk '
            /^[[:space:]]*#.*[Ff]ail2ban/ { hold = $0; next }
            /^[[:space:]]*\/var\/log\/fail2ban\.log[[:space:]]*\{/ { skip = 1; hold = ""; next }
            skip {
                if ($0 ~ /^[[:space:]]*\}/) skip = 0
                next
            }
            { if (hold != "") { print hold; hold = "" } print }
            END { if (hold != "") print hold }
        ' "$NAS_LOGS" > "$tmp"
        if [ -s "$tmp" ] && ! grep -qE '^[[:space:]]*/var/log/fail2ban\.log[[:space:]]*\{' "$tmp"; then
            cp "$NAS_LOGS" "${NAS_LOGS}.bak.$(date +%Y%m%d%H%M%S)"
            # Write back via redirection so the file keeps its original
            # owner and permissions (mktemp files are mode 600).
            cat "$tmp" > "$NAS_LOGS"
            rm -f "$tmp"
            applied "removed duplicate fail2ban.log stanza (backup saved)"
        else
            rm -f "$tmp"
            errored "could not safely rewrite $NAS_LOGS — left unchanged"
        fi
    fi
fi

# --- Fix 5: clear future-dated Salt cache ---------------------------------
section "Fix 5: stale Salt cache"
if [ -d /var/cache/salt ]; then
    future=$(find /var/cache/salt -type f -newermt now 2>/dev/null | wc -l)
    if [ "${future:-0}" -eq 0 ]; then
        skipped "no future-dated Salt cache files"
    elif run "delete $future future-dated Salt cache file(s)" \
        find /var/cache/salt -type f -newermt now -delete; then
        [ "$DRY_RUN" -eq 0 ] && applied "$future stale Salt cache file(s) removed"
    fi
else
    skipped "/var/cache/salt not present"
fi

# --- Fix 6: reset failed units --------------------------------------------
section "Fix 6: reset failed systemd units"
failed=$(systemctl --failed --no-legend --no-pager 2>/dev/null | grep -c . || true)
if [ "${failed:-0}" -eq 0 ]; then
    skipped "no failed units to reset"
elif run "reset $failed failed unit(s)" systemctl reset-failed; then
    [ "$DRY_RUN" -eq 0 ] && applied "$failed failed unit(s) reset"
fi

# --- Summary ---------------------------------------------------------------
section "Summary"
printf '  %s applied, %s skipped, %s errors\n' \
    "$(c_green "$APPLIED")" "$(c_blue "$SKIPPED")" "$(c_red "$ERRORS")"
if [ "$DRY_RUN" -eq 0 ] && [ "$APPLIED" -gt 0 ]; then
    printf '  Reboot to confirm boot-time improvements: sudo reboot\n'
fi

[ "$ERRORS" -gt 0 ] && exit 1
exit 0
