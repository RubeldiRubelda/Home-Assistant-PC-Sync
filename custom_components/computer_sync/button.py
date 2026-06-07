"""Control buttons for Computer Sync integration."""
from __future__ import annotations

import asyncio
import logging

from homeassistant.components.button import ButtonEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import (
    DOMAIN,
    CONF_DEVICE_ID,
    CONF_HOSTNAME,
    CONF_COMMAND_QUEUE,
    ALL_COMMANDS,
)

_LOGGER = logging.getLogger(__name__)

# Button definitions: (command_key, friendly_name, icon)
BUTTON_DEFINITIONS = [
    ("shutdown",  "Shutdown",   "mdi:power"),
    ("reboot",    "Reboot",     "mdi:restart"),
    ("sleep",     "Sleep",      "mdi:sleep"),
    ("hibernate", "Hibernate",  "mdi:power-sleep"),
    ("lock",      "Lock",       "mdi:lock"),
]


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up Computer Sync buttons from a config entry."""

    device_id = entry.data.get(CONF_DEVICE_ID)
    if not device_id:
        return  # Hub entry, skip

    hostname = entry.data.get(CONF_HOSTNAME, device_id)

    buttons = [
        ComputerSyncButton(hass, entry, device_id, hostname, cmd, name, icon)
        for cmd, name, icon in BUTTON_DEFINITIONS
    ]
    async_add_entities(buttons)
    _LOGGER.info(
        "Computer Sync: Registered %d control buttons for device '%s'",
        len(buttons),
        device_id,
    )


class ComputerSyncButton(ButtonEntity):
    """A button that queues a command for the next PC heartbeat response."""

    _attr_has_entity_name = True
    _attr_should_poll = False

    def __init__(
        self,
        hass: HomeAssistant,
        entry: ConfigEntry,
        device_id: str,
        hostname: str,
        command: str,
        name: str,
        icon: str,
    ) -> None:
        self.hass = hass
        self._entry = entry
        self._device_id = device_id
        self._hostname = hostname
        self._command = command

        self._attr_unique_id = f"{DOMAIN}_{device_id}_{command}"
        self._attr_name = name
        self._attr_icon = icon

    @property
    def device_info(self) -> DeviceInfo:
        """Group all buttons under the same device as the sensors."""
        return DeviceInfo(
            identifiers={(DOMAIN, self._device_id)},
            name=f"{self._hostname}",
            manufacturer="Computer Sync",
            model="Windows PC",
            sw_version="1.0.0",
        )

    async def async_press(self) -> None:
        """
        Called when the button is pressed in HA.
        Puts the command into the queue; it will be sent on the
        next heartbeat response from the Windows agent.
        """
        devices = self.hass.data.get(DOMAIN, {}).get("devices", {})
        device = devices.get(self._device_id)

        if not device:
            _LOGGER.warning(
                "Computer Sync: Cannot send command '%s' – device '%s' not yet connected.",
                self._command,
                self._device_id,
            )
            return

        cmd_queue: asyncio.Queue = device[CONF_COMMAND_QUEUE]

        # Clear any previously queued command (last-write-wins)
        while not cmd_queue.empty():
            try:
                cmd_queue.get_nowait()
            except asyncio.QueueEmpty:
                break

        await cmd_queue.put(self._command)
        _LOGGER.info(
            "Computer Sync: Command '%s' queued for device '%s'",
            self._command,
            self._device_id,
        )
