#!/bin/bash
# ==========================================================
# Cipher VPN Installer / Updater for Ubuntu
# Запуск через Zabbix Remote Command (Manual host action)
#
# - Ставить/оновлює, якщо встановлена версія != TARGET_VERSION
# - Сам переходить у фон (Zabbix не чекає і не обриває за таймаутом)
# - Захист від паралельного запуску (flock)
# - Автовідповіді інсталятору: ліцензія "Y", конфігурація "2" (Global)
#
# Лог:    /var/log/cipher_vpn-install.log
# Версія: /var/lib/cipher_vpn.version
# ==========================================================

set -Eeuo pipefail

# ---------------- CONFIGURATION ----------------

# При виході нової версії змінюєш ці два рядки (+ FILE_ID)
TARGET_VERSION="1.1.0.10"
FILE_ID="1UbER3HjbqUKTG-m2lzlHkWpAQp9V9xCo"

# Необов'язково: sha256 інсталятора. Порожньо = не перевіряти.
EXPECTED_SHA256=""

APP_NAME="cipher_vpn"
CACHE_DIR="/var/cache/${APP_NAME}"
INSTALLER="${CACHE_DIR}/installer-${TARGET_VERSION}.run"
LOG_FILE="/var/log/${APP_NAME}-install.log"
VERSION_FILE="/var/lib/${APP_NAME}.version"
LOCK_FILE="/var/lock/${APP_NAME}.lock"
SELF_COPY="/var/lib/${APP_NAME}-run.sh"
VENV="/opt/gdown-venv"

MIN_SIZE=20000000     # інсталятор ~69 МБ; менше = це HTML-помилка від Google
TIMEOUT=1800          # таймаут інсталятора, сек
SERVICE="civpnsvc"

# ---------------- HELPERS ----------------

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Конфіг VPN: створюється лише якщо його ще немає (існуючий не чіпаємо)
CONFIG_DIR="/etc/xdg/Cipher/CiVPN_Client/Configs"
CONFIG_FILE="${CONFIG_DIR}/DSNS.ovpn"

ensure_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "VPN config already exists: $CONFIG_FILE"
        return 0
    fi

    log "VPN config not found, creating $CONFIG_FILE"
    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<'EOF'
dev tun
proto tcp
remote-random
resolv-retry 0
remote 194.0.148.90 6290
auth-nocache
route-delay 3
client
ca dsns.p7b
tls-client
tls-cipher ECDHE-DSTU-GOST89-GOST95
persist-key
comp-lzo
cipher dstu8845-512
auth dstu7564-256
ecdh-curve secp384r1
tun-mtu 1500
tun-mtu-extra 32
#ocsp-check
mssfix 1450
ping-restart 0
ping 0
verb 3
mute-replay-warnings
reneg-sec 0
auth-retry interact
key-direction 1
pkcs12 "/home/user/Стільниця/Pankiv_Andrii_Stepanovich.pfx"
EOF

    chmod 755 /etc/xdg/Cipher /etc/xdg/Cipher/CiVPN_Client "$CONFIG_DIR" 2>/dev/null || true
    chmod 644 "$CONFIG_FILE"
    log "VPN config created"
}

error() {
    log "[ERROR] $*"
    exit 1
}

# ---------------- ROOT CHECK ----------------

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Run this script as root" >&2
    exit 1
fi

mkdir -p "$CACHE_DIR" /var/lib /var/lock
touch "$LOG_FILE"

# ---------------- ПЕРЕХІД У ФОН ----------------
# Zabbix обриває команди за таймаутом, тому першим запуском лише
# стартуємо фоновий процес і одразу повертаємо керування.
# Копія скрипта потрібна, бо /tmp/install_run.sh може бути перезаписаний
# наступним wget під час роботи (bash читає скрипт по ходу виконання).

if [[ "${CIPHER_CHILD:-0}" != "1" ]]; then
    cp -f "$(readlink -f "$0")" "$SELF_COPY"
    chmod 700 "$SELF_COPY"
    CIPHER_CHILD=1 setsid nohup bash "$SELF_COPY" >>"$LOG_FILE" 2>&1 </dev/null &
    echo "Cipher VPN install/update started in background (target ${TARGET_VERSION})."
    echo "Log: ${LOG_FILE}"
    exit 0
fi

# ---------------- ДАЛІ ПРАЦЮЄ ФОНОВИЙ ПРОЦЕС ----------------

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another installation is already running, exiting"
    exit 0
fi

trap 'error "Script failed at line $LINENO"' ERR

log "=========================================="
log "Cipher VPN install/update, target ${TARGET_VERSION}"
log "=========================================="

# ---------------- CHECK OS ----------------

[[ -f /etc/os-release ]] || error "Cannot determine operating system"
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == "ubuntu" ]] || error "This script supports Ubuntu only"
log "Ubuntu version: ${VERSION_ID}"

# ---------------- CHECK VERSION ----------------

INSTALLED_VERSION="$(cat "$VERSION_FILE" 2>/dev/null || true)"
log "Installed version: ${INSTALLED_VERSION:-none}"

if systemctl is-active --quiet "$SERVICE" && [[ "$INSTALLED_VERSION" == "$TARGET_VERSION" ]]; then
    log "Already on ${TARGET_VERSION} and service is running."
    ensure_config
    exit 0
fi

# ---------------- SYSTEM DEPENDENCIES ----------------

log "Installing system dependencies"
export DEBIAN_FRONTEND=noninteractive

apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 install -y \
    python3 \
    python3-venv \
    wget \
    ca-certificates \
    libxcb-cursor0

# ---------------- PYTHON VENV + GDOWN ----------------

if [[ ! -x "${VENV}/bin/gdown" ]]; then
    log "Creating Python virtual environment and installing gdown"
    rm -rf "$VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet gdown
fi

# ---------------- DOWNLOAD INSTALLER ----------------

# Прибираємо кеш інших версій
find "$CACHE_DIR" -maxdepth 1 -name 'installer*.run' ! -name "$(basename "$INSTALLER")" -delete 2>/dev/null || true

check_installer() {
    local f="$1" size
    [[ -s "$f" ]] || return 1
    size=$(stat -c%s "$f")
    (( size >= MIN_SIZE )) || { log "File too small (${size} bytes), probably not the installer"; return 1; }
    head -c 4096 "$f" | grep -aq 'Makeself' || { log "Makeself header not found"; return 1; }
    if [[ -n "$EXPECTED_SHA256" ]]; then
        echo "${EXPECTED_SHA256}  ${f}" | sha256sum -c --quiet - || { log "SHA256 mismatch"; return 1; }
    fi
    return 0
}

if check_installer "$INSTALLER"; then
    log "Using cached installer: $INSTALLER"
else
    rm -f "$INSTALLER"
    ok=0
    for attempt in 1 2 3; do
        log "Downloading installer (attempt ${attempt}/3)"
        "$VENV/bin/gdown" "https://drive.google.com/uc?id=${FILE_ID}" -O "$INSTALLER" || true
        if check_installer "$INSTALLER"; then
            ok=1
            break
        fi
        rm -f "$INSTALLER"
        sleep $((attempt * 20))
    done
    [[ "$ok" -eq 1 ]] || error "Installer download failed or file is invalid (Google Drive quota / access?)"
    log "Download completed"
fi

chmod 700 "$INSTALLER"

# ---------------- AUTOMATIC INSTALLATION ----------------

log "Starting automated installation (license: Y, configuration: 2 Global)"

if ! python3 - "$INSTALLER" "$TIMEOUT" <<'PY'
import os, sys, pty, select, time, signal, re, fcntl, termios, struct

installer = sys.argv[1]
timeout = int(sys.argv[2])

ANSI = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]')

pid, fd = pty.fork()
if pid == 0:
    # Zabbix не задає TERM: без нього падають tput/seq, а пейджер просить Enter
    os.environ["TERM"] = "xterm"
    os.environ["PAGER"] = "cat"
    os.environ["MANPAGER"] = "cat"
    os.environ["SYSTEMD_PAGER"] = ""
    os.environ["LESS"] = "-FX"
    os.execv(installer, [installer])

# Розмір терміналу: 24 рядки x 200 колонок
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 200, 0, 0))

buffer = b""
license_sent = False
global_sent = False
return_count = 0
deadline = time.time() + timeout
exit_status = None


def kill_child():
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(2)
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


try:
    while True:
        if time.time() > deadline:
            print("\n[ERROR] Installer timeout. Last output:", flush=True)
            print(buffer.decode(errors="replace")[-1500:], flush=True)
            kill_child()
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
            buffer = (buffer + ANSI.sub(b"", data))[-16384:]

            if not license_sent and re.search(
                rb'type\s+"?Y"?\s+to accept|\(Y/N\)|\[y/N\]', buffer, re.I
            ):
                time.sleep(0.5)
                os.write(fd, b"Y\r")
                license_sent = True
                print("\n[AUTOMATION] License accepted", flush=True)
                buffer = b""

            elif license_sent and not global_sent and re.search(
                rb'Globally for all users', buffer, re.I
            ):
                time.sleep(1)
                os.write(fd, b"2\r")
                global_sent = True
                print("\n[AUTOMATION] Global installation selected", flush=True)
                buffer = b""

            if global_sent and return_count < 20 and re.search(
                rb'Press RETURN to continue', buffer, re.I
            ):
                time.sleep(0.5)
                os.write(fd, b"\r")
                return_count += 1
                print("\n[AUTOMATION] Sent RETURN", flush=True)
                buffer = b""

        res = os.waitpid(pid, os.WNOHANG)
        if res[0] != 0:
            exit_status = res[1]
            break

    if exit_status is None:
        _, exit_status = os.waitpid(pid, 0)

except KeyboardInterrupt:
    kill_child()
    sys.exit(130)

if not license_sent:
    print("[ERROR] License prompt was not detected")
    print(buffer.decode(errors="replace")[-1500:])
    sys.exit(1)
if not global_sent:
    print("[ERROR] Global configuration prompt was not detected")
    print(buffer.decode(errors="replace")[-1500:])
    sys.exit(1)
if not os.WIFEXITED(exit_status):
    print("[ERROR] Installer terminated abnormally")
    sys.exit(1)

code = os.WEXITSTATUS(exit_status)
if code != 0:
    print(f"[ERROR] Installer exit code: {code}")
    sys.exit(code)

print("[SUCCESS] Installer completed successfully")
PY
then
    error "Cipher VPN installer failed"
fi

# ---------------- SERVICE CHECK ----------------

log "Checking Cipher VPN service"

systemctl daemon-reload

systemctl list-unit-files | grep -q "^${SERVICE}.service" || error "${SERVICE}.service was not found"

systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
sleep 3

if ! systemctl is-active --quiet "$SERVICE"; then
    systemctl status "$SERVICE" --no-pager || true
    error "Cipher VPN service is not running"
fi

if command -v civpnclient >/dev/null 2>&1; then
    log "Cipher VPN client found: $(command -v civpnclient)"
else
    log "[WARNING] civpnclient command was not found in PATH"
fi

# ---------------- CONFIG ----------------

ensure_config

# ---------------- MARK SUCCESS ----------------

echo "$TARGET_VERSION" > "$VERSION_FILE"

log "=========================================="
log "CIPHER VPN INSTALLATION SUCCESSFUL"
log "Version: ${TARGET_VERSION}"
log "Service: ${SERVICE} ($(systemctl is-active "$SERVICE"))"
log "=========================================="

exit 0
