#!/usr/bin/env bash
# ==============================================================================
# Home Assistant Computer Sync - Linux Installation Script
# Version: 1.0
# ==============================================================================
# This script installs the HA Computer Sync agent on a Linux system.
#
# What it does:
#   1. Asks for your Home Assistant URL, API token, and device name
#   2. Copies the sync agent to ~/.local/share/ha-computer-sync/
#   3. Writes a config file to ~/.config/ha-computer-sync/config.cfg
#   4. Installs a systemd user service that starts automatically at login
#   5. Tests the connection to Home Assistant
#
# Requirements:
#   - bash, curl, systemd (for auto-start), sudo (for power commands)
#   - A running Home Assistant instance reachable from this computer
# ==============================================================================

set -euo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/share/ha-computer-sync"
CONFIG_DIR="${HOME}/.config/ha-computer-sync"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
SERVICE_NAME="ha-computer-sync"
SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
section() { echo -e "\n${BOLD}$*${RESET}"; }

# ─── Dependency check ─────────────────────────────────────────────────────────
check_dependencies() {
    local missing=()
    for cmd in curl bash; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        error "Missing required tools: ${missing[*]}"
        error "Install them with your package manager (e.g. sudo apt install curl)"
        exit 1
    fi
}

# ─── Input helpers ────────────────────────────────────────────────────────────
ask() {
    # ask <variable_name> <prompt> [default]
    local _var="$1" _prompt="$2" _default="${3:-}" _input
    if [[ -n "$_default" ]]; then
        read -rp "  $_prompt [${_default}]: " _input
        printf -v "$_var" '%s' "${_input:-$_default}"
    else
        while true; do
            read -rp "  $_prompt: " _input
            [[ -n "$_input" ]] && break
            warn "This field is required."
        done
        printf -v "$_var" '%s' "$_input"
    fi
}

ask_secret() {
    # ask_secret <variable_name> <prompt>
    local _var="$1" _prompt="$2" _input
    while true; do
        read -rsp "  $_prompt: " _input
        echo
        [[ -n "$_input" ]] && break
        warn "This field is required."
    done
    printf -v "$_var" '%s' "$_input"
}

# ─── Sudoers helper ───────────────────────────────────────────────────────────
configure_sudoers() {
    local sudoers_file="/etc/sudoers.d/ha-computer-sync"
    local user="$USER"
    section "Configuring sudo access for power commands..."
    cat <<EOF
  To allow shutdown/reboot/sleep commands without a password prompt,
  a sudoers rule will be added (requires your sudo password now).

  File: ${sudoers_file}
  Rule: Allow '${user}' to run shutdown, reboot, systemctl suspend/hibernate
EOF
    read -rp "  Add sudoers rule? [Y/n]: " answer
    if [[ "${answer,,}" != "n" ]]; then
        sudo tee "$sudoers_file" > /dev/null <<SUDOERS
# Added by ha-computer-sync installer
${user} ALL=(ALL) NOPASSWD: /sbin/shutdown, /sbin/reboot, /usr/bin/systemctl suspend, /usr/bin/systemctl hibernate
SUDOERS
        sudo chmod 440 "$sudoers_file"
        info "Sudoers rule added: ${sudoers_file}"
    else
        warn "Skipped sudoers configuration. Power commands may prompt for a password."
    fi
}

# ==============================================================================
# MAIN INSTALLATION
# ==============================================================================

echo ""
echo -e "${BOLD}============================================================${RESET}"
echo -e "${BOLD}  Home Assistant Computer Sync  –  Linux Installer v1.0${RESET}"
echo -e "${BOLD}============================================================${RESET}"
echo ""
echo "  This installer will set up the HA Computer Sync agent on your"
echo "  Linux system so it starts automatically and keeps Home Assistant"
echo "  updated with your computer's metrics."
echo ""

check_dependencies

# ─── Gather configuration ─────────────────────────────────────────────────────
section "Step 1 – Home Assistant connection"
echo "  Enter your Home Assistant URL and API token."
echo "  You can find/create a Long-Lived Access Token at:"
echo "  HA → Profile (bottom-left) → Long-Lived Access Tokens"
echo ""

ask    HA_URL    "Home Assistant URL" "http://homeassistant.local:8123"
ask_secret HA_TOKEN "Long-Lived Access Token"

section "Step 2 – Device identity"
DEFAULT_DEVICE_ID="$(hostname | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_' '_' | sed 's/_*$//')"
ask DEVICE_ID "Device ID (no spaces, lowercase)" "${DEFAULT_DEVICE_ID}"
ask UPDATE_INTERVAL "Update interval in seconds" "30"

section "Step 3 – Remote commands"
echo "  Remote commands allow Home Assistant to shutdown, reboot,"
echo "  suspend, hibernate, or lock the screen of this computer."
read -rp "  Enable remote commands? [Y/n]: " _cmd_answer
COMMANDS_ENABLED="true"
[[ "${_cmd_answer,,}" == "n" ]] && COMMANDS_ENABLED="false"

section "Step 4 – MQTT (optional)"
echo "  Optionally enable MQTT discovery to allow Home Assistant to auto-create entities."
read -rp "  Enable MQTT discovery? [y/N]: " _mqtt_ans
MQTT_ENABLED="false"
MQTT_HOST="localhost"
MQTT_PORT="1883"
MQTT_USER=""
MQTT_PASS=""
MQTT_PREFIX="homeassistant"
if [[ "${_mqtt_ans,,}" == "y" ]]; then
    MQTT_ENABLED="true"
    read -rp "  MQTT broker host [localhost]: " _mhost
    MQTT_HOST="${_mhost:-localhost}"
    read -rp "  MQTT broker port [1883]: " _mport
    MQTT_PORT="${_mport:-1883}"
    read -rp "  MQTT username (leave blank if none): " _muser
    MQTT_USER="${_muser:-}"
    read -rsp "  MQTT password (leave blank if none): " _mpass
    echo
    MQTT_PASS="${_mpass:-}"
    read -rp "  MQTT discovery prefix [homeassistant]: " _mprefix
    MQTT_PREFIX="${_mprefix:-homeassistant}"
    info "Installing Python dependency 'paho-mqtt' for MQTT support..."
    if command -v pip3 >/dev/null 2>&1; then
        pip3 install --user paho-mqtt || warn "Failed to install paho-mqtt with pip3"
    elif command -v pip >/dev/null 2>&1; then
        pip install --user paho-mqtt || warn "Failed to install paho-mqtt with pip"
    else
        warn "pip not found; please install Python pip and run 'pip install paho-mqtt'"
    fi
fi

# ─── Test connection ──────────────────────────────────────────────────────────
section "Testing connection to Home Assistant..."
HA_URL="${HA_URL%/}"   # strip trailing slash
http_code=$(curl -so /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    "${HA_URL}/api/" || true)
if [[ "$http_code" == "200" ]]; then
    info "Connection successful!"
else
    warn "Received HTTP ${http_code} from ${HA_URL}/api/"
    warn "Installation will continue, but please verify your URL and token."
    read -rp "  Continue anyway? [y/N]: " _cont
    [[ "${_cont,,}" != "y" ]] && { info "Installation cancelled."; exit 0; }
fi

# ─── Create directory structure ───────────────────────────────────────────────
section "Installing files..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$SYSTEMD_DIR"

# Copy the sync script
cp "${SCRIPT_DIR}/sync.sh" "${INSTALL_DIR}/sync.sh"
chmod +x "${INSTALL_DIR}/sync.sh"
info "Sync script installed to: ${INSTALL_DIR}/sync.sh"

# Write configuration (permissions 600 – only owner can read the token)
cat > "${CONFIG_DIR}/config.cfg" <<CFG
# Home Assistant Computer Sync – configuration
# Generated by install.sh on $(date)
HA_URL=${HA_URL}
HA_TOKEN=${HA_TOKEN}
DEVICE_ID=${DEVICE_ID}
UPDATE_INTERVAL=${UPDATE_INTERVAL}
COMMANDS_ENABLED=${COMMANDS_ENABLED}
MQTT_ENABLED=${MQTT_ENABLED}
MQTT_HOST=${MQTT_HOST}
MQTT_PORT=${MQTT_PORT}
MQTT_USER=${MQTT_USER}
MQTT_PASS=${MQTT_PASS}
MQTT_PREFIX=${MQTT_PREFIX}
CFG
chmod 600 "${CONFIG_DIR}/config.cfg"
info "Configuration written to: ${CONFIG_DIR}/config.cfg"

# ─── Systemd user service ─────────────────────────────────────────────────────
section "Creating systemd user service..."
cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=Home Assistant Computer Sync Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HA_CONFIG=${CONFIG_DIR}/config.cfg
ExecStart=/bin/bash ${INSTALL_DIR}/sync.sh
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=default.target
SERVICE

# Enable lingering so the service starts even without a graphical login
if command -v loginctl &>/dev/null; then
    loginctl enable-linger "$USER" 2>/dev/null || true
fi

systemctl --user daemon-reload
systemctl --user enable "${SERVICE_NAME}.service"
systemctl --user start  "${SERVICE_NAME}.service"

if systemctl --user is-active --quiet "${SERVICE_NAME}.service"; then
    info "Service '${SERVICE_NAME}' is running."
else
    warn "Service did not start immediately. Check logs with:"
    warn "  journalctl --user -u ${SERVICE_NAME} -f"
fi

# ─── Sudoers (optional) ───────────────────────────────────────────────────────
if [[ "$COMMANDS_ENABLED" == "true" ]]; then
    configure_sudoers
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}============================================================${RESET}"
echo -e "${GREEN}  Installation complete!${RESET}"
echo -e "${BOLD}============================================================${RESET}"
echo ""
echo "  Useful commands:"
echo "    View live logs : journalctl --user -u ${SERVICE_NAME} -f"
echo "    Stop agent     : systemctl --user stop ${SERVICE_NAME}"
echo "    Restart agent  : systemctl --user restart ${SERVICE_NAME}"
echo "    Edit config    : nano ${CONFIG_DIR}/config.cfg"
echo ""
echo "  Sensors will appear in Home Assistant with the prefix:"
echo "    sensor.${DEVICE_ID}_*"
echo ""
echo "  Next step – add the Home Assistant helpers:"
echo "    See homeassistant/configuration.yaml in this repository."
echo ""
