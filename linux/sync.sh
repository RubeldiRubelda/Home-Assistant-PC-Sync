#!/usr/bin/env bash
# ==============================================================================
# Home Assistant Computer Sync - Linux Agent
# Version: 1.0
# ==============================================================================
# Continuously sends system metrics (CPU, RAM, disk, battery, etc.) to a
# Home Assistant instance via the REST API, and polls HA for remote commands
# (shutdown, reboot, sleep, hibernate, lock screen).
#
# Configuration: edit config.cfg in the same directory as this script,
# or set the environment variable HA_CONFIG to point to another config file.
# ==============================================================================

set -euo pipefail

# ─── Resolve script directory & config file ───────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${HA_CONFIG:-${SCRIPT_DIR}/config.cfg}"

# ─── Load configuration ───────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please run install.sh first, or copy config.cfg and fill in your values."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ─── Validate required settings ───────────────────────────────────────────────
for _var in HA_URL HA_TOKEN DEVICE_ID; do
    if [[ -z "${!_var:-}" ]]; then
        echo "ERROR: '$_var' is not set in $CONFIG_FILE"
        exit 1
    fi
done

# Strip trailing slash from HA_URL
HA_URL="${HA_URL%/}"

# Apply defaults
UPDATE_INTERVAL="${UPDATE_INTERVAL:-30}"
COMMANDS_ENABLED="${COMMANDS_ENABLED:-true}"
MQTT_ENABLED="${MQTT_ENABLED:-false}"
MQTT_HOST="${MQTT_HOST:-localhost}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
MQTT_PREFIX="${MQTT_PREFIX:-homeassistant}"

# ─── Logging helper ───────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ==============================================================================
# HOME ASSISTANT API HELPERS
# ==============================================================================

# ha_set_state <entity_id> <state> <unit> <friendly_name> <icon>
# Sends a sensor state update to Home Assistant.
ha_set_state() {
    local entity_id="$1"
    local state="$2"
    local unit="$3"
    local friendly_name="$4"
    local icon="${5:-mdi:laptop}"

    local payload
    payload=$(
        printf '{"state":"%s","attributes":{"unit_of_measurement":"%s","friendly_name":"%s","icon":"%s"}}' \
            "$state" "$unit" "$friendly_name" "$icon"
    )

    curl -sf -X POST \
        -H "Authorization: Bearer ${HA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${HA_URL}/api/states/${entity_id}" \
        -o /dev/null \
        || log "WARNING: Failed to update ${entity_id}"
}

# ha_get_state <entity_id>
# Returns the current state string of the given entity, or an empty string.
ha_get_state() {
    local entity_id="$1"
    curl -sf -X GET \
        -H "Authorization: Bearer ${HA_TOKEN}" \
        -H "Content-Type: application/json" \
        "${HA_URL}/api/states/${entity_id}" 2>/dev/null \
        | grep -o '"state":"[^"]*"' \
        | head -1 \
        | cut -d'"' -f4 \
        || true
}

# ha_call_service <domain> <service> <json_payload>
# Calls a Home Assistant service.
ha_call_service() {
    local domain="$1"
    local service="$2"
    local payload="$3"
    curl -sf -X POST \
        -H "Authorization: Bearer ${HA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${HA_URL}/api/services/${domain}/${service}" \
        -o /dev/null \
        || log "WARNING: Failed to call service ${domain}.${service}"
}

# ==============================================================================
# METRIC COLLECTION FUNCTIONS
# ==============================================================================

# Returns CPU usage percentage (0-100), measured over 1 second.
get_cpu_usage() {
    local stat1 stat2 total1 idle1 total2 idle2 dtotal didle
    stat1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5; exit}' /proc/stat)
    sleep 1
    stat2=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5; exit}' /proc/stat)
    total1="${stat1%% *}"; idle1="${stat1##* }"
    total2="${stat2%% *}"; idle2="${stat2##* }"
    dtotal=$(( total2 - total1 ))
    didle=$(( idle2 - idle1 ))
    if (( dtotal == 0 )); then
        echo "0"
    else
        printf "%d" $(( 100 * (dtotal - didle) / dtotal ))
    fi
}

# Returns memory usage percentage (0.0–100.0).
get_memory_usage() {
    awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.1f", (t-a)*100/t}' /proc/meminfo
}

# Returns disk usage percentage for the root filesystem.
get_disk_usage() {
    df / | awk 'NR==2{gsub(/%/,"",$5); print $5}'
}

# Returns the battery level (0–100), or -1 if no battery is present.
get_battery_level() {
    local bpath
    for bpath in /sys/class/power_supply/BAT0 \
                 /sys/class/power_supply/BAT1 \
                 /sys/class/power_supply/battery; do
        if [[ -f "${bpath}/capacity" ]]; then
            cat "${bpath}/capacity"
            return
        fi
    done
    echo "-1"
}

# Returns the battery charging status (Charging / Discharging / Full / Unknown).
get_battery_status() {
    local bpath
    for bpath in /sys/class/power_supply/BAT0 \
                 /sys/class/power_supply/BAT1 \
                 /sys/class/power_supply/battery; do
        if [[ -f "${bpath}/status" ]]; then
            cat "${bpath}/status"
            return
        fi
    done
    echo "Not Present"
}

# Returns a human-readable system uptime string.
get_uptime() {
    uptime -p 2>/dev/null || uptime | sed 's/.*up /up /'
}

# Returns the primary IPv4 address (non-loopback).
get_ip_address() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' \
        || hostname -I 2>/dev/null | awk '{print $1}' \
        || echo "unknown"
}

# ==============================================================================
# METRICS SENDER
# ==============================================================================
send_metrics() {
    local device="${DEVICE_ID}"
    local hn
    hn=$(hostname)

    log "Sending metrics to Home Assistant..."

    # CPU
    local cpu
    cpu=$(get_cpu_usage)
    ha_set_state "sensor.${device}_cpu_usage" "${cpu}" "%" "${hn} CPU Usage" "mdi:cpu-64-bit"
    if [[ "${MQTT_ENABLED}" == "true" ]]; then
        mqtt_publish "${MQTT_PREFIX}/${device}/${device}_cpu_usage/state" "${cpu}"
    fi

    # Memory
    local mem
    mem=$(get_memory_usage)
    ha_set_state "sensor.${device}_memory_usage" "${mem}" "%" "${hn} Memory Usage" "mdi:memory"
    if [[ "${MQTT_ENABLED}" == "true" ]]; then
        mqtt_publish "${MQTT_PREFIX}/${device}/${device}_memory_usage/state" "${mem}"
    fi

    # Disk
    local disk
    disk=$(get_disk_usage)
    ha_set_state "sensor.${device}_disk_usage" "${disk}" "%" "${hn} Disk Usage" "mdi:harddisk"
    if [[ "${MQTT_ENABLED}" == "true" ]]; then
        mqtt_publish "${MQTT_PREFIX}/${device}/${device}_disk_usage/state" "${disk}"
    fi

    # Battery (only if present)
    local battery_level
    battery_level=$(get_battery_level)
    if [[ "$battery_level" != "-1" ]]; then
        ha_set_state "sensor.${device}_battery_level" "${battery_level}" "%" "${hn} Battery Level" "mdi:battery"
        if [[ "${MQTT_ENABLED}" == "true" ]]; then
            mqtt_publish "${MQTT_PREFIX}/${device}/${device}_battery_level/state" "${battery_level}"
        fi
        local battery_status
        battery_status=$(get_battery_status)
        ha_set_state "sensor.${device}_battery_status" "${battery_status}" "" "${hn} Battery Status" "mdi:battery-charging"
        if [[ "${MQTT_ENABLED}" == "true" ]]; then
            mqtt_publish "${MQTT_PREFIX}/${device}/${device}_battery_status/state" "${battery_status}"
        fi
    fi

    # Uptime
    local upt
    upt=$(get_uptime)
    ha_set_state "sensor.${device}_uptime" "${upt}" "" "${hn} Uptime" "mdi:clock-outline"
    if [[ "${MQTT_ENABLED}" == "true" ]]; then
        mqtt_publish "${MQTT_PREFIX}/${device}/${device}_uptime/state" "${upt}"
    fi

    # IP address
    local ip
    ip=$(get_ip_address)
    ha_set_state "sensor.${device}_ip_address" "${ip}" "" "${hn} IP Address" "mdi:ip-network"
    if [[ "${MQTT_ENABLED}" == "true" ]]; then
        mqtt_publish "${MQTT_PREFIX}/${device}/${device}_ip_address/state" "${ip}"
    fi

    # Online status (heartbeat)
    ha_set_state "sensor.${device}_status" "online" "" "${hn} Status" "mdi:laptop"
    if [[ "${MQTT_ENABLED}" == "true" ]]; then
        mqtt_publish "${MQTT_PREFIX}/${device}/${device}_status/state" "online"
    fi

    log "Metrics sent successfully."
}

# ==============================================================================
# REMOTE COMMAND HANDLER
# ==============================================================================
check_commands() {
    [[ "$COMMANDS_ENABLED" == "true" ]] || return 0

    local command_entity="input_select.${DEVICE_ID}_command"
    local cmd
    cmd=$(ha_get_state "$command_entity")

    # Nothing to do if the command is "none" or empty
    [[ -z "$cmd" || "$cmd" == "none" || "$cmd" == "None" ]] && return 0

    log "Received remote command: '${cmd}'"

    # Reset the command in HA immediately to prevent re-execution after reboot
    ha_call_service "input_select" "select_option" \
        "{\"entity_id\":\"${command_entity}\",\"option\":\"none\"}"

    case "$cmd" in
        shutdown)
            log "Executing: shutdown"
            ha_set_state "sensor.${DEVICE_ID}_status" "offline" "" "$(hostname) Status" "mdi:laptop-off"
            sleep 2
            sudo shutdown -h now
            ;;
        reboot)
            log "Executing: reboot"
            ha_set_state "sensor.${DEVICE_ID}_status" "rebooting" "" "$(hostname) Status" "mdi:laptop"
            sleep 2
            sudo reboot
            ;;
        sleep|suspend)
            log "Executing: suspend"
            ha_set_state "sensor.${DEVICE_ID}_status" "sleeping" "" "$(hostname) Status" "mdi:sleep"
            sleep 1
            sudo systemctl suspend
            ;;
        hibernate)
            log "Executing: hibernate"
            ha_set_state "sensor.${DEVICE_ID}_status" "hibernating" "" "$(hostname) Status" "mdi:sleep"
            sleep 1
            sudo systemctl hibernate
            ;;
        lock)
            log "Executing: lock screen"
            # Try several common screen-lockers in order of preference
            if command -v loginctl &>/dev/null; then
                loginctl lock-sessions
            elif command -v gnome-screensaver-command &>/dev/null; then
                gnome-screensaver-command -l
            elif command -v xdg-screensaver &>/dev/null; then
                xdg-screensaver lock
            elif command -v i3lock &>/dev/null; then
                i3lock
            else
                log "WARNING: No supported screen locker found."
            fi
            ;;
        *)
            log "WARNING: Unknown command '${cmd}' – ignoring."
            ;;
    esac
}

# ==============================================================================
# MAIN
# ==============================================================================
echo "============================================================"
echo "  Home Assistant Computer Sync  –  Linux Agent v1.0"
echo "  Device ID : ${DEVICE_ID}"
echo "  HA URL    : ${HA_URL}"
echo "  Interval  : ${UPDATE_INTERVAL}s"
echo "  Commands  : ${COMMANDS_ENABLED}"
echo "============================================================"

# Test connection
log "Testing connection to Home Assistant..."
http_code=$(curl -so /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    "${HA_URL}/api/" || true)
if [[ "$http_code" == "200" ]]; then
    payload=$(printf '{"state":"%s","attributes":{"unit_of_measurement":"%s","friendly_name":"%s","icon":"%s"}}' \
        "$state" "$unit" "$friendly_name" "$icon")
    payload="${payload},\"unit_of_measurement\":\"${unit}\""
fi

# --- MQTT helpers (optional) -------------------------------------------------
MQTT_CMD_FILE="${SCRIPT_DIR}/.mqtt_command"
MQTT_SUB_PID_FILE="${SCRIPT_DIR}/.mqtt_sub_pid"

mqtt_publish() {
    local topic="$1"; shift
    local payload="$1"; shift
    # call python helper
    if command -v python3 >/dev/null 2>&1; then
        python3 "${SCRIPT_DIR}/../tools/mqtt_publish.py" --host "${MQTT_HOST}" --port "${MQTT_PORT}" --topic "$topic" --payload "$payload" --retain
    else
        log "WARNING: python3 not found; cannot publish MQTT message"
    fi
    if [[ "${MQTT_ENABLED}" == "true" && -f "${MQTT_CMD_FILE}" ]]; then
        cmd=$(cat "${MQTT_CMD_FILE}" 2>/dev/null || true)
        rm -f "${MQTT_CMD_FILE}"
    else
        cmd=$(ha_get_state "$command_entity")
    fi

mqtt_start_subscriber() {
    if [[ "${MQTT_ENABLED}" != "true" ]]; then return; fi
    if [[ -f "${MQTT_SUB_PID_FILE}" ]]; then return; fi
    if command -v python3 >/dev/null 2>&1; then
        python3 "${SCRIPT_DIR}/../tools/mqtt_subscribe.py" --host "${MQTT_HOST}" --port "${MQTT_PORT}" --topic "${MQTT_PREFIX}/${DEVICE_ID}/command/set" --outfile "${MQTT_CMD_FILE}" &
        echo $! > "${MQTT_SUB_PID_FILE}"
        log "Started MQTT subscriber (pid=$(cat ${MQTT_SUB_PID_FILE}))."
    else
        log "WARNING: python3 not found; cannot start MQTT subscriber"
    fi
}

mqtt_stop_subscriber() {
    if [[ -f "${MQTT_SUB_PID_FILE}" ]]; then
        kill "$(cat ${MQTT_SUB_PID_FILE})" 2>/dev/null || true
        rm -f "${MQTT_SUB_PID_FILE}"
        log "Stopped MQTT subscriber."
    fi
}

publish_discovery() {
    [[ "${MQTT_ENABLED}" == "true" ]] || return 0
    local device="${DEVICE_ID}"
    local hn
    hn=$(hostname)

    # sensors: cpu, memory, disk, battery_level, battery_status, uptime, ip_address, status
    local sensors=("cpu_usage:%:CPU Usage:mdi:cpu-64-bit" "memory_usage:%:Memory Usage:mdi:memory" "disk_usage:%:Disk Usage:mdi:harddisk" "battery_level:%:Battery Level:mdi:battery" "battery_status::Battery Status:mdi:battery-charging" "uptime::Uptime:mdi:clock-outline" "ip_address::IP Address:mdi:ip-network" "status::Status:mdi:laptop")
    for s in "${sensors[@]}"; do
        IFS=':' read -r key unit name icon <<< "$s"
        object_id="${device}_${key}"
        cfg_topic="${MQTT_PREFIX}/sensor/${object_id}/config"
        state_topic="${MQTT_PREFIX}/${device}/${object_id}/state"
        # build JSON payload
        payload="{\"name\":\"${hn} ${name}\",\"state_topic\":\"${state_topic}\",\"unique_id\":\"${object_id}\",\"device\":{\"identifiers\":[\"${device}\"],\"name\":\"${hn}\",\"manufacturer\":\"computer-sync\",\"model\":\"agent\"},\"icon\":\"${icon}\""
        if [[ -n "$unit" ]]; then
            payload=\"${payload},\\\"unit_of_measurement\\\":\\\"${unit}\\\"\"
        fi
        payload="${payload}}"
        mqtt_publish "$cfg_topic" "$payload"
    done

    # command select (options)
    cmd_object="${device}_command"
    cmd_cfg_topic="${MQTT_PREFIX}/select/${cmd_object}/config"
    cmd_state_topic="${MQTT_PREFIX}/${device}/${cmd_object}/state"
    cmd_command_topic="${MQTT_PREFIX}/${device}/command/set"
    options='["none","shutdown","reboot","sleep","hibernate","lock"]'
    cmd_payload="{\"name\":\"${hn} Command\",\"state_topic\":\"${cmd_state_topic}\",\"command_topic\":\"${cmd_command_topic}\",\"options\":${options},\"unique_id\":\"${cmd_object}\",\"device\":{\"identifiers\":[\"${device}\"],\"name\":\"${hn}\",\"manufacturer\":\"computer-sync\",\"model\":\"agent\"}}"
    mqtt_publish "$cmd_cfg_topic" "$cmd_payload"
}

# Ensure background subscriber is stopped on exit
trap 'mqtt_stop_subscriber' EXIT

if [[ "${MQTT_ENABLED}" == "true" ]]; then
    mqtt_start_subscriber
    publish_discovery
fi

# Main loop
while true; do
    send_metrics
    check_commands
    sleep "${UPDATE_INTERVAL}"
done
