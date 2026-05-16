# OMV

Tooling and notes for an [OpenMediaVault](https://www.openmediavault.org/) NAS
running on a Raspberry Pi 5.

## Getting Started

Clone the repository:

```bash
git clone https://github.com/Themis128/OMV.git
cd OMV
```

## Health Check

`scripts/omv-healthcheck.sh` runs a read-only diagnostic sweep of the OMV host
and prints a pass/warn/fail summary. It never changes system state.

Copy it to the Pi and run it:

```bash
scp scripts/omv-healthcheck.sh tbaltzakis@<pi-host>:~
ssh tbaltzakis@<pi-host> 'bash ~/omv-healthcheck.sh'
```

Or run it locally on the Pi:

```bash
./scripts/omv-healthcheck.sh           # full report
./scripts/omv-healthcheck.sh --quiet   # summary only
```

It checks: the OMV engine daemon, failed systemd units, journal and kernel
errors, disk usage, memory, load average, APT repositories, logrotate config,
time synchronisation, and SMART disk health. Exit code is non-zero if any
check fails.

## Inventory

`scripts/omv-inventory.sh` prints a full read-only inventory of the OMV host —
hardware, OS, OMV version and plugins, storage (disks, filesystems, RAID,
mergerfs, ZFS, LVM, SMART), network, services, shares, containers, and users.

```bash
./scripts/omv-inventory.sh                  # print report
./scripts/omv-inventory.sh > inventory.txt  # save to a file
```

## Publish Reports to GitHub

`scripts/omv-report-to-github.sh` runs the health check and inventory on the
Pi and pushes the results to a dedicated `omv-reports` branch, so the Pi's
state can be reviewed from GitHub without SSH access to the Pi.

One-time setup on the Pi:

```bash
git clone git@github.com:Themis128/OMV.git ~/OMV
cat ~/.ssh/id_ed25519.pub   # add as a deploy key with write access
~/OMV/scripts/omv-report-to-github.sh
```

Reports land on the `omv-reports` branch under `reports/`, with both
timestamped files and `latest-*` copies. Add a cron entry to run it on a
schedule. See the script header for full setup notes.

## Apply Maintenance Fixes

`scripts/omv-apply-fixes.sh` applies the maintenance fixes from the OMV tune-up:

1. Comments out the dead `packages.openmediavault.org` APT repository.
2. Masks `systemd-networkd-wait-online.service` (no networkd-managed links).
3. Defers the `apt-daily` / `apt-daily-upgrade` timers off the boot path.
4. Removes the duplicate `fail2ban.log` stanza from `omv-nas-logs`.
5. Clears future-dated Salt cache files that slow `openmediavault-issue`.
6. Resets failed systemd units.

Every fix is idempotent — re-running only acts where a fix is still needed.

```bash
sudo ./scripts/omv-apply-fixes.sh --dry-run   # preview, change nothing
sudo ./scripts/omv-apply-fixes.sh             # apply
```

## Repository Layout

- `README.md` — project overview
- `LICENSE` — MIT license
- `.gitignore` — common ignore patterns (OS, editors, Node, Python, env files)
- `scripts/omv-healthcheck.sh` — read-only OMV host health check
- `scripts/omv-inventory.sh` — read-only full OMV host inventory
- `scripts/omv-report-to-github.sh` — publish health/inventory reports to the repo
- `scripts/omv-apply-fixes.sh` — idempotent OMV host maintenance fixes

## License

Released under the [MIT License](LICENSE).
