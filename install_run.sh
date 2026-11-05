#!/bin/bash
# ==========================================================
# Cipher VPN Installer for Ubuntu
# Installation via Zabbix Remote Command
#
# Automatic answers:
#   License: Y
#   Configuration: 2 (Global)
#
# No EXPECT required. Uses Python PTY.
# ==========================================================

set -Eeuo pipefail

# ---------------- CONFIGURATION ----------------

FILE_ID="1UbER3HjbqUKTG-m2lzlHkWpAQp9V9xCo"

APP_NAME="cipher_vpn"
CACHE_DIR="/var/cache/${APP_NAME}"
INSTALLER="${CACHE_DIR}/installer.run"
LOG_FILE="/var/log/${APP_NAME}-install.log"
MARKER="/var/lib/${APP_NAME}.installed"

VENV="/opt/gdown-venv"

TIMEOUT=1800

# ------------------------------------------------

mkdir -p "$CACHE_DIR" /var/lib
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    log "[ERROR] $*"
    exit 1
}

trap 'error "Script failed at line $LINENO"' ERR

# Root check
if [[ "$EUID" -ne 0 ]]; then
    error "Run this script as root"
fi

log "=========================================="
log "Starting Cipher VPN installation"
log "=========================================="

# ---------------- CHECK OS ----------------

if [[ ! -f /etc/os-release ]]; then
    error "Cannot determine operating system"
fi

source /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    error "This script supports Ubuntu only"
fi

log "Ubuntu version: ${VERSION_ID}"

# ---------------- CHECK EXISTING INSTALLATION ----------------

if systemctl is-active --quiet civpnsvc; then
    log "Cipher VPN service is already running"

    # Ensure GUI dependency is present
    apt-get update
    apt-get install -y libxcb-cursor0

    touch "$MARKER"

    log "Installation already completed"
    exit 0
fi

# ---------------- SYSTEM DEPENDENCIES ----------------

log "Installing system dependencies"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    python3 \
    python3-venv \
    wget \
    ca-certificates \
    libxcb-cursor0

log "System dependencies installed"

# ---------------- PYTHON VENV ----------------

if [[ ! -x "${VENV}/bin/gdown" ]]; then

    log "Creating Python virtual environment"

    rm -rf "$VENV"

    python3 -m venv "$VENV"

    log "Installing gdown"

    "$VENV/bin/pip" install --upgrade pip
    "$VENV/bin/pip" install gdown

fi

# ---------------- DOWNLOAD INSTALLER ----------------

if [[ ! -s "$INSTALLER" ]]; then

    log "Downloading Cipher VPN installer"

    "$VENV/bin/gdown" \
        "https://drive.google.com/uc?id=${FILE_ID}" \
        -O "$INSTALLER"

    [[ -s "$INSTALLER" ]] || error "Installer download failed"

    log "Download completed"

else

    log "Using previously downloaded installer"

fi

chmod 700 "$INSTALLER"

# ---------------- CHECK INSTALLER ----------------

if ! file "$INSTALLER" | grep -qi "Makeself"; then
    error "Downloaded file is not a valid Makeself installer"
fi

# ---------------- AUTOMATIC INSTALLATION ----------------

log "Starting automated installation"
log "License answer: Y"
log "Configuration answer: 2 (Global)"

python3 - "$INSTALLER" "$TIMEOUT" <<'PY'

import os
import sys
import pty
import select
import time
import signal
import re

installer = sys.argv[1]
timeout = int(sys.argv[2])

pid, fd = pty.fork()

if pid == 0:
    os.execv(installer, [installer])

buffer = b""
license_sent = False
global_sent = False

deadline = time.time() + timeout
exit_status = None

try:

    while True:

        if time.time() > deadline:
            print("\n[ERROR] Installer timeout", flush=True)
            os.kill(pid, signal.SIGTERM)
            time.sleep(2)

            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

            os.waitpid(pid, 0)
            sys.exit(124)

        ready, _, _ = select.select([fd], [], [], 1)

        if ready:

            try:
                data = os.read(fd, 4096)
            except OSError:
                break

            if not data:
                break

            os.write(1, data)

            buffer += data

            # Limit memory usage
            buffer = buffer[-16384:]

            # Accept license
            if not license_sent:

                if re.search(
                    rb'Please type\s+"?Y"?\s+to accept',
                    buffer,
                    re.IGNORECASE
                ):

                    os.write(fd, b"Y\r")
                    license_sent = True

                    print(
                        "\n[AUTOMATION] License accepted",
                        flush=True
                    )

                    buffer = b""

            # Select global configuration
            if license_sent and not global_sent:

                if re.search(
                    rb'\[2\]\s*Globally for all users on the system',
                    buffer,
                    re.IGNORECASE
                ):

                    os.write(fd, b"2\r")
                    global_sent = True

                    print(
                        "\n[AUTOMATION] Global installation selected",
                        flush=True
                    )

                    buffer = b""

        result = os.waitpid(pid, os.WNOHANG)

        if result[0] != 0:
            exit_status = result[1]
            break

    if exit_status is None:
        _, exit_status = os.waitpid(pid, 0)

    if not license_sent:
        print("[ERROR] License prompt was not detected")
        sys.exit(1)

    if not global_sent:
        print("[ERROR] Global configuration prompt was not detected")
        sys.exit(1)

    if not os.WIFEXITED(exit_status):
        print("[ERROR] Installer terminated abnormally")
        sys.exit(1)

    code = os.WEXITSTATUS(exit_status)

    if code != 0:
        print(f"[ERROR] Installer exit code: {code}")
        sys.exit(code)

    print("[SUCCESS] Installer completed successfully")

except KeyboardInterrupt:
    os.kill(pid, signal.SIGTERM)
    sys.exit(130)

PY

RESULT=$?

if [[ "$RESULT" -ne 0 ]]; then
    error "Cipher VPN installer failed. Exit code: $RESULT"
fi

# ---------------- SERVICE CHECK ----------------

log "Checking Cipher VPN service"

systemctl daemon-reload

if ! systemctl list-unit-files | grep -q '^civpnsvc.service'; then
    error "civpnsvc.service was not found"
fi

systemctl enable civpnsvc
systemctl restart civpnsvc

sleep 3

if ! systemctl is-active --quiet civpnsvc; then
    systemctl status civpnsvc --no-pager || true
    error "Cipher VPN service is not running"
fi

# ---------------- VERIFY CLIENT ----------------

if ! command -v civpnclient >/dev/null 2>&1; then
    log "[WARNING] civpnclient command was not found in PATH"
else
    log "Cipher VPN client found: $(command -v civpnclient)"
fi

# ---------------- MARK SUCCESS ----------------

touch "$MARKER"

log "=========================================="
log "CIPHER VPN INSTALLATION SUCCESSFUL"
log "Service: civpnsvc"
log "Status: $(systemctl is-active civpnsvc)"
log "GUI dependency: libxcb-cursor0 installed"
log "=========================================="

exit 0
