#!/usr/bin/env bash
# Install the cloudless playwright synthetic monitoring timer for the current user.
#
# Requires: loginctl enable-linger (so the timer survives logout)
#           npm + node available
#           playwright browsers installed (npx playwright install chromium)
#
# Usage:
#   ./test/playwright/systemd/install.sh
#
# To uninstall:
#   systemctl --user disable --now cloudless-playwright-synthetic.timer
#   rm ~/.config/systemd/user/cloudless-playwright-synthetic.{service,timer}
#   systemctl --user daemon-reload

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"

install -d "${UNIT_DIR}"
cp "${SCRIPT_DIR}/cloudless-playwright-synthetic.service" "${UNIT_DIR}/"
cp "${SCRIPT_DIR}/cloudless-playwright-synthetic.timer"   "${UNIT_DIR}/"

systemctl --user daemon-reload
systemctl --user enable --now cloudless-playwright-synthetic.timer

echo "timer installed and started"
systemctl --user list-timers cloudless-playwright-synthetic.timer
