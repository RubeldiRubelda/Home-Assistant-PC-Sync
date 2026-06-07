"""Constants for the Computer Sync integration."""

DOMAIN = "computer_sync"

CONF_COMMAND_QUEUE = "command_queue"
CONF_DEVICE_ID = "device_id"
CONF_HOSTNAME = "hostname"

COMMAND_NONE      = "none"
COMMAND_SHUTDOWN  = "shutdown"
COMMAND_REBOOT    = "reboot"
COMMAND_SLEEP     = "sleep"
COMMAND_HIBERNATE = "hibernate"
COMMAND_LOCK      = "lock"

ALL_COMMANDS = [
    COMMAND_SHUTDOWN,
    COMMAND_REBOOT,
    COMMAND_SLEEP,
    COMMAND_HIBERNATE,
    COMMAND_LOCK,
]

# ── Sensor definitions ────────────────────────────────────────────────────────
# Each tuple: (payload_key, friendly_name_suffix, unit, device_class, state_class, icon)
from homeassistant.components.sensor import SensorDeviceClass, SensorStateClass
from homeassistant.const import (
    PERCENTAGE,
    UnitOfInformation,
)

SENSOR_DEFINITIONS = [
    {
        "key": "cpu",
        "name": "CPU Usage",
        "unit": PERCENTAGE,
        "device_class": None,
        "state_class": SensorStateClass.MEASUREMENT,
        "icon": "mdi:cpu-64-bit",
    },
    {
        "key": "memory",
        "name": "Memory Usage",
        "unit": PERCENTAGE,
        "device_class": None,
        "state_class": SensorStateClass.MEASUREMENT,
        "icon": "mdi:memory",
    },
    {
        "key": "disk",
        "name": "Disk Usage",
        "unit": PERCENTAGE,
        "device_class": None,
        "state_class": SensorStateClass.MEASUREMENT,
        "icon": "mdi:harddisk",
    },
    {
        "key": "battery_level",
        "name": "Battery Level",
        "unit": PERCENTAGE,
        "device_class": SensorDeviceClass.BATTERY,
        "state_class": SensorStateClass.MEASUREMENT,
        "icon": "mdi:battery",
    },
    {
        "key": "battery_status",
        "name": "Battery Status",
        "unit": None,
        "device_class": None,
        "state_class": None,
        "icon": "mdi:battery-charging",
    },
    {
        "key": "uptime",
        "name": "Uptime",
        "unit": None,
        "device_class": None,
        "state_class": None,
        "icon": "mdi:timer-outline",
    },
    {
        "key": "ip",
        "name": "IP Address",
        "unit": None,
        "device_class": None,
        "state_class": None,
        "icon": "mdi:ip-network",
    },
    {
        "key": "status",
        "name": "Status",
        "unit": None,
        "device_class": None,
        "state_class": None,
        "icon": "mdi:desktop-classic",
    },
    {
        "key": "hostname",
        "name": "Hostname",
        "unit": None,
        "device_class": None,
        "state_class": None,
        "icon": "mdi:laptop",
    },
]
