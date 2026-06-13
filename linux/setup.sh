#!/usr/bin/env bash
# ==============================================================================
#  Home Assistant Computer Sync - Linux Setup
#  Equivalent to setup.ps1
#
#  Installs the sync agent to /opt/ha-computer-sync
#  and sets up a systemd user service for autostart.
#
#  Usage: bash setup.sh
# ==============================================================================

set -euo pipefail

# ── Colours ------------------------------------------------------------------
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
NC='\033[0m'   # No Colour

info()    { echo -e "${GRN}[+]${NC} $*"; }
warn()    { echo -e "${YLW}[-]${NC} $*"; }
error()   { echo -e "${RED}[!]${NC} $*" >&2; }
section() { echo -e "\n${CYN}$*${NC}"; }

# ── Paths --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SYNC="$SCRIPT_DIR/sync.sh"

INSTALL_DIR="/opt/ha-computer-sync"
DEST_CONFIG="$INSTALL_DIR/config.cfg"
DEST_SYNC="$INSTALL_DIR/sync.sh"
DEVICE_ID_FILE="$INSTALL_DIR/.device_id"

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/ha-computer-sync.service"

# ── Dependency Check ----------------------------------------------------------
section "========================================================"
section "  Home Assistant Computer Sync - Linux Setup"
section "========================================================"
echo ""

missing_deps=()
for dep in curl jq; do
    command -v "$dep" &>/dev/null || missing_deps+=("$dep")
done

if [[ ${#missing_deps[@]} -gt 0 ]]; then
    error "Fehlende Abhaengigkeiten: ${missing_deps[*]}"
    echo "  Installieren mit:  sudo apt install ${missing_deps[*]}"
    exit 1
fi
info "Abhaengigkeiten OK (curl, jq)"

# upower optional
if ! command -v upower &>/dev/null; then
    warn "upower nicht gefunden – Akkuinfo deaktiviert. (sudo apt install upower)"
fi

# ── Install Directory ---------------------------------------------------------
if [[ ! -d "$INSTALL_DIR" ]]; then
    sudo mkdir -p "$INSTALL_DIR"
    sudo chown "$USER:$USER" "$INSTALL_DIR"
    info "Installationsverzeichnis erstellt: $INSTALL_DIR"
fi

# ── Device ID -----------------------------------------------------------------
if [[ -f "$DEVICE_ID_FILE" ]]; then
    DEVICE_ID="$(cat "$DEVICE_ID_FILE")"
    warn "Bestehende Geraete-ID gefunden: $DEVICE_ID"
else
    # Generate from hostname: only a-z, 0-9 and underscores
    RAW_ID="${HOSTNAME,,}"
    DEVICE_ID="${RAW_ID//[^a-z0-9]/_}"
    DEVICE_ID="${DEVICE_ID#_}"
    DEVICE_ID="${DEVICE_ID%_}"
    echo -n "$DEVICE_ID" > "$DEVICE_ID_FILE"
    info "Neue Geraete-ID generiert: $DEVICE_ID"
fi

# ── User Input ----------------------------------------------------------------
echo ""
warn "Das Skript nutzt einen sicheren Heartbeat ohne offene Ports."
warn "Kein Port-Forwarding noetig – der PC verbindet sich aktiv mit HA."
echo ""

read -rp "Home Assistant URL (z.B. http://homeassistant.local:8123): " HA_URL
HA_URL="${HA_URL%/}"

echo ""
warn "Long-Lived Access Token:"
warn "  Profil (unten links) -> Long-Lived Access Tokens -> Token erstellen"
read -rp "HA Token: " HA_TOKEN

read -rp "Heartbeat-Intervall in Sekunden [Standard: 30]: " UPDATE_INTERVAL
UPDATE_INTERVAL="${UPDATE_INTERVAL:-30}"
[[ -z "$UPDATE_INTERVAL" ]] && UPDATE_INTERVAL="30"

read -rp "Remote-Befehle erlauben? (true/false) [Standard: true]: " COMMANDS_ENABLED
[[ -z "$COMMANDS_ENABLED" ]] && COMMANDS_ENABLED="true"

# ── Write config.cfg ----------------------------------------------------------
cat > "$DEST_CONFIG" <<EOF
# Home Assistant Computer Sync - Konfiguration
# Generiert von setup.sh

HA_URL=$HA_URL
HA_TOKEN=$HA_TOKEN
DEVICE_ID=$DEVICE_ID
UPDATE_INTERVAL=$UPDATE_INTERVAL
COMMANDS_ENABLED=$COMMANDS_ENABLED
EOF

info "Konfiguration gespeichert: $DEST_CONFIG"

# ── Install sync.sh -----------------------------------------------------------
if [[ ! -f "$SOURCE_SYNC" ]]; then
    error "sync.sh nicht gefunden: $SOURCE_SYNC"
    exit 1
fi

cp "$SOURCE_SYNC" "$DEST_SYNC"
chmod +x "$DEST_SYNC"
info "sync.sh installiert: $DEST_SYNC"

# ── Uninstall Script ----------------------------------------------------------
cat > "$INSTALL_DIR/uninstall.sh" <<'UNINSTALL'
#!/usr/bin/env bash
read -rp "Wirklich deinstallieren? (y/n): " confirm
if [[ "$confirm" =~ ^y ]]; then
    echo "Stoppe und deaktiviere Service..."
    systemctl --user stop  ha-computer-sync.service 2>/dev/null || true
    systemctl --user disable ha-computer-sync.service 2>/dev/null || true
    SERVICE="$HOME/.config/systemd/user/ha-computer-sync.service"
    [[ -f "$SERVICE" ]] && rm -f "$SERVICE"
    systemctl --user daemon-reload 2>/dev/null || true

    echo "Entferne Installationsverzeichnis..."
    sudo rm -rf /opt/ha-computer-sync
    echo "Deinstallation abgeschlossen!"
fi
UNINSTALL
chmod +x "$INSTALL_DIR/uninstall.sh"
info "Deinstallationsskript erstellt: $INSTALL_DIR/uninstall.sh"

# ── Systemd User Service ------------------------------------------------------
read -rp $'\nAutostart per systemd einrichten? (y/n): ' setup_autostart

if [[ "$setup_autostart" =~ ^y ]]; then
    mkdir -p "$SYSTEMD_USER_DIR"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Home Assistant Computer Sync Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $DEST_SYNC
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal
Environment=HA_CONFIG=$DEST_CONFIG

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable ha-computer-sync.service
    info "systemd-Service erstellt und aktiviert: $SERVICE_FILE"

    # Enable linger so service runs even when user is logged out
    loginctl enable-linger "$USER" 2>/dev/null || \
        warn "loginctl linger nicht verfuegbar – Service laeuft nur bei aktivem Login."

    read -rp "Agent jetzt starten? (y/n): " start_now
    if [[ "$start_now" =~ ^y ]]; then
        systemctl --user start ha-computer-sync.service
        info "Agent gestartet."
        echo ""
        echo -e "${CYN}Home Assistant erkennt '$DEVICE_ID' automatisch${NC}"
        echo -e "${CYN}und legt alle Sensoren und Steuerungs-Buttons an!${NC}"
        echo ""
        echo "Log ansehen:  journalctl --user -u ha-computer-sync -f"
    fi
else
    warn "Autostart uebersprungen."
    echo ""
    echo "Manuell starten:  bash $DEST_SYNC"
fi

# ── Summary -------------------------------------------------------------------
echo ""
echo "========================================================"
echo "  Setup abgeschlossen!"
echo "  Geraete-ID: $DEVICE_ID"
echo "  HA URL:     $HA_URL"
echo "========================================================"
echo ""
echo "Nuetzliche Befehle:"
echo "  Status:       systemctl --user status ha-computer-sync"
echo "  Log:          journalctl --user -u ha-computer-sync -f"
echo "  Stoppen:      systemctl --user stop ha-computer-sync"
echo "  Deinstall:    bash $INSTALL_DIR/uninstall.sh"
echo ""
