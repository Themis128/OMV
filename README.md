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

## Repository Layout

- `README.md` — project overview
- `LICENSE` — MIT license
- `.gitignore` — common ignore patterns (OS, editors, Node, Python, env files)
- `scripts/omv-healthcheck.sh` — read-only OMV host health check

## License

Released under the [MIT License](LICENSE).
