
#!/bin/bash
# =====================================================
# Google Drive RUN Installer for Ubuntu via Zabbix
# Answers: Y -> 2
# =====================================================

set -Eeuo pipefail

# Google Drive file
FILE_ID="1UbER3HjbqUKTG-m2lzlHkWpAQp9V9xCo"

# Configuration
APP_NAME="custom_app"
INSTALL_DIR="/opt/${APP_NAME}"
CACHE_DIR="/var/cache/${APP_NAME}"
INSTALLER="${CACHE_DIR}/installer.run"
LOG_FILE="/var/log/${APP_NAME}-install.log"
MARKER="${INSTALL_DIR}/.installed"

VENV="/opt/gdown-venv"

MODE="${1:-install}"

# Logging
mkdir -p "$CACHE_DIR" "$INSTALL_DIR"
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
    error "Run script as root"
fi

log "========================================"
log "Starting RUN installer"
log "Mode: $MODE"
log "========================================"

# Check already installed
if [[ -f "$MARKER" && "$MODE" != "--force" ]]; then
    log "Application already installed."
    log "Skipping installation."
    exit 0
fi

# Check dependencies
if ! command -v python3 >/dev/null 2>&1; then
    log "Installing Python3"
    apt-get update
    apt-get install -y python3 python3-venv
fi

if ! python3 -m venv --help >/dev/null 2>&1; then
    log "Installing python3-venv"
    apt-get update
    apt-get install -y python3-venv
fi

# Install gdown
if [[ ! -x "${VENV}/bin/gdown" ]]; then
    log "Installing gdown"

    python3 -m venv "$VENV"

    "$VENV/bin/pip" install --upgrade pip
    "$VENV/bin/pip" install gdown
fi

# Download installer
if [[ ! -s "$INSTALLER" || "$MODE" == "--force-download" ]]; then

    log "Downloading installer from Google Drive"

    rm -f "$INSTALLER"

    "$VENV/bin/gdown" \
        "https://drive.google.com/uc?id=${FILE_ID}" \
        -O "$INSTALLER"

    [[ -s "$INSTALLER" ]] || error "Downloaded file is empty"

    log "Download completed"
else
    log "Using cached installer"
fi

chmod 700 "$INSTALLER"

# Download only mode
if [[ "$MODE" == "--download-only" ]]; then
    log "Download-only mode completed"
    exit 0
fi

# Installer existence
[[ -s "$INSTALLER" ]] || error "Installer not found"

# Run installer
log "Starting automated installation"
log "Sending answers: Y and 2"

# Timeout: 30 minutes
if timeout 1800 bash -c '
    printf "Y\n2\n" | "$1"
' _ "$INSTALLER"; then

    log "Installer returned exit code 0"

    touch "$MARKER"

    log "========================================"
    log "INSTALLATION SUCCESSFUL"
    log "========================================"

else
    RESULT=$?

    error "Installer failed. Exit code: $RESULT"
fi
