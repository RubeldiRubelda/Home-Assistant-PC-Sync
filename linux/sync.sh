#!/usr/bin/env bash
# ==============================================================================
#  Home Assistant Computer Sync - Linux Agent (Heartbeat Edition)
#  Equivalent to sync.ps1
#
#  Dependencies: curl, jq, bc, iproute2 (ip), upower (optional for battery)
#  Install:  sudo apt install curl jq bc iproute2 upower
# ==============================================================================

set -euo pipefail

# ── Config --------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${HA_CONFIG:-$SCRIPT_DIR/config.cfg}"

# ── Load Configuration --------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

declare -A CONFIG
while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key="${key// /}"
    value="${value// /}"
    CONFIG["$key"]="$value"
done < <(grep -v '^\s*#' "$CONFIG_FILE" | grep -v '^\s*$')

for required in HA_URL HA_TOKEN DEVICE_ID; do
    if [[ -z "${CONFIG[$required]:-}" ]]; then
        echo "ERROR: Missing required config: $required" >&2
        exit 1
    fi
done

HA_URL="${CONFIG[HA_URL]%/}"
HA_TOKEN="${CONFIG[HA_TOKEN]}"
DEVICE_ID="${CONFIG[DEVICE_ID],,}"   # lowercase
UPDATE_INTERVAL="${CONFIG[UPDATE_INTERVAL]:-30}"
COMMANDS_ENABLED="${CONFIG[COMMANDS_ENABLED]:-true}"

API_ENDPOINT="$HA_URL/api/computer_sync/heartbeat"

# ── Logging -------------------------------------------------------------------
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $*"
}

# ── Metric Collection ---------------------------------------------------------
get_system_metrics() {
    # CPU usage (1-second sample via /proc/stat)
    local cpu=0
    if [[ -f /proc/stat ]]; then
        read -r _ u1 n1 s1 i1 _ < /proc/stat
        sleep 1
        read -r _ u2 n2 s2 i2 _ < /proc/stat
        local used=$(( (u2+n2+s2) - (u1+n1+s1) ))
        local total=$(( used + (i2 - i1) ))
        [[ $total -gt 0 ]] && cpu=$(( used * 100 / total ))
    fi

    # Memory (%)
    local mem_total mem_free mem_available mem_pct=0
    mem_total=$(awk '/MemTotal/  {print $2}' /proc/meminfo)
    mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    local mem_used=$(( mem_total - mem_available ))
    [[ $mem_total -gt 0 ]] && mem_pct=$(( mem_used * 100 / mem_total ))

    # Disk usage for /
    local disk_pct=0
    disk_pct=$(df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')

    # Battery
    local bat_level=-1
    local bat_status="Not Present"
    if command -v upower &>/dev/null; then
        local bat_path
        bat_path=$(upower -e 2>/dev/null | grep -i 'battery' | head -1)
        if [[ -n "$bat_path" ]]; then
            bat_level=$(upower -i "$bat_path" 2>/dev/null \
                | awk '/percentage/ {gsub(/%/,"",$2); printf "%d", $2}')
            local state
            state=$(upower -i "$bat_path" 2>/dev/null \
                | awk '/state/ {print $2}')
            case "$state" in
                discharging) bat_status="Discharging" ;;
                charging)    bat_status="Charging"    ;;
                fully-charged) bat_status="Full"      ;;
                *)           bat_status="Unknown"     ;;
            esac
        fi
    elif [[ -d /sys/class/power_supply ]]; then
        for ps in /sys/class/power_supply/BAT*; do
            [[ -f "$ps/capacity" ]] && bat_level=$(cat "$ps/capacity")
            if [[ -f "$ps/status" ]]; then
                local raw_status
                raw_status=$(cat "$ps/status")
                case "$raw_status" in
                    Discharging)    bat_status="Discharging" ;;
                    Charging)       bat_status="Charging"    ;;
                    Full)           bat_status="Full"        ;;
                    *)              bat_status="Unknown"     ;;
                esac
            fi
            break
        done
    fi

    # Uptime
    local uptime_str="unknown"
    if [[ -f /proc/uptime ]]; then
        local uptime_secs
        uptime_secs=$(awk '{printf "%d", $1}' /proc/uptime)
        local days=$(( uptime_secs / 86400 ))
        local hours=$(( (uptime_secs % 86400) / 3600 ))
        local mins=$(( (uptime_secs % 3600) / 60 ))

        local parts=()
        [[ $days -gt 0 ]]  && parts+=("$days day$(  [[ $days  -ne 1 ]] && echo s)")
        [[ $hours -gt 0 ]] && parts+=("$hours hour$([[ $hours -ne 1 ]] && echo s)")
        [[ ${#parts[@]} -eq 0 ]] && parts+=("$mins minute$(  [[ $mins  -ne 1 ]] && echo s)")
        uptime_str="up $(IFS=', '; echo "${parts[*]}")"
    fi

    # IP address (first non-loopback, non-link-local IPv4)
    local ip_str="unknown"
    ip_str=$(ip -4 addr show scope global \
        | awk '/inet / {print $2}' \
        | cut -d/ -f1 \
        | grep -v '^127\.' \
        | grep -v '^169\.254\.' \
        | head -1) || true
    [[ -z "$ip_str" ]] && ip_str="unknown"

    # Output JSON via jq (safe escaping)
    jq -cn \
        --arg device_id      "$DEVICE_ID" \
        --arg hostname       "$(hostname)" \
        --argjson cpu        "$cpu" \
        --argjson memory     "$mem_pct" \
        --argjson disk       "$disk_pct" \
        --argjson bat_level  "$bat_level" \
        --arg bat_status     "$bat_status" \
        --arg uptime         "$uptime_str" \
        --arg ip             "$ip_str" \
        '{
            device_id:      $device_id,
            hostname:       $hostname,
            cpu:            $cpu,
            memory:         $memory,
            disk:           $disk,
            battery_level:  $bat_level,
            battery_status: $bat_status,
            uptime:         $uptime,
            ip:             $ip,
            status:         "online"
        }'
}

# ── Remote Commands -----------------------------------------------------------
execute_command() {
    local cmd="${1,,}"   # lowercase

    if [[ "$COMMANDS_ENABLED" == "false" ]]; then
        log "Commands disabled – ignoring: $cmd"
        return
    fi

    case "$cmd" in
        none) return ;;
        shutdown)
            log "Executing shutdown..."
            sleep 2
            sudo systemctl poweroff
            ;;
        reboot)
            log "Executing reboot..."
            sleep 2
            sudo systemctl reboot
            ;;
        sleep)
            log "Executing sleep (suspend)..."
            sudo systemctl suspend
            ;;
        hibernate)
            log "Executing hibernate..."
            sudo systemctl hibernate
            ;;
        lock)
            log "Executing lock..."
            # Try common screen lockers
            if command -v loginctl &>/dev/null; then
                loginctl lock-session
            elif command -v gnome-screensaver-command &>/dev/null; then
                gnome-screensaver-command -l
            elif command -v xdg-screensaver &>/dev/null; then
                xdg-screensaver lock
            else
                log "WARNING: No screen locker found for 'lock' command"
            fi
            ;;
        *)
            log "WARNING: Unknown command '$cmd'"
            ;;
    esac
}

# ── Heartbeat -----------------------------------------------------------------
send_heartbeat() {
    local payload
    payload="$(get_system_metrics)"

    log "Sending heartbeat to $API_ENDPOINT ..."

    local response http_code
    response=$(curl --silent --show-error --max-time 15 \
        --write-out "\n%{http_code}" \
        --header "Authorization: Bearer $HA_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$payload" \
        --request POST \
        "$API_ENDPOINT" 2>&1) || {
        log "ERROR: curl failed – HA not reachable?"
        return
    }

    http_code="${response##*$'\n'}"
    local body="${response%$'\n'*}"

    if [[ "$http_code" != "200" ]]; then
        log "WARNING: HA returned HTTP $http_code"
        return
    fi

    # Parse command from response
    local cmd
    cmd=$(echo "$body" | jq -r '.command // "none"' 2>/dev/null) || cmd="none"

    if [[ -n "$cmd" && "$cmd" != "none" ]]; then
        log "Received command from HA: $cmd"
        execute_command "$cmd"
    fi
}

# ── Main ----------------------------------------------------------------------
echo ""
echo "========================================================"
echo "  Home Assistant Computer Sync (Heartbeat Edition)"
echo "========================================================"
echo "  Device ID:    $DEVICE_ID"
echo "  HA API:       $API_ENDPOINT"
echo "  Interval:     ${UPDATE_INTERVAL}s"
echo "  Commands:     $COMMANDS_ENABLED"
echo "========================================================"
echo ""

log "Agent started. Pushing heartbeat every ${UPDATE_INTERVAL}s..."
echo ""

while true; do
    send_heartbeat || log "ERROR in main loop – continuing..."
    sleep "$UPDATE_INTERVAL"
done
