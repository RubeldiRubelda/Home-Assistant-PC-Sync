"""Sensors for Computer Sync integration."""
from __future__ import annotations

import logging
from typing import Any

from homeassistant.components.sensor import SensorEntity, SensorDeviceClass, SensorStateClass
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN, SENSOR_DEFINITIONS, CONF_DEVICE_ID, CONF_HOSTNAME

_LOGGER = logging.getLogger(__name__)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up Computer Sync sensors from a config entry."""

    # Hub entry has no device_id – skip sensor setup for it
    device_id = entry.data.get(CONF_DEVICE_ID)
    if not device_id:
        return

    hostname = entry.data.get(CONF_HOSTNAME, device_id)

    sensors = [
        ComputerSyncSensor(hass, entry, device_id, hostname, sensor_def)
        for sensor_def in SENSOR_DEFINITIONS
    ]
    async_add_entities(sensors, update_before_add=True)
    _LOGGER.info(
        "Computer Sync: Registered %d sensors for device '%s'", len(sensors), device_id
    )


class ComputerSyncSensor(SensorEntity):
    """A sensor that reflects one metric from a Windows PC heartbeat."""

    _attr_has_entity_name = True
    _attr_should_poll = False  # Push-based via event bus

    def __init__(
        self,
        hass: HomeAssistant,
        entry: ConfigEntry,
        device_id: str,
        hostname: str,
        sensor_def: dict,
    ) -> None:
        self.hass = hass
        self._entry = entry
        self._device_id = device_id
        self._hostname = hostname
        self._sensor_def = sensor_def
        self._key = sensor_def["key"]

        self._attr_unique_id = f"{DOMAIN}_{device_id}_{self._key}"
        self._attr_name = sensor_def["name"]
        self._attr_icon = sensor_def.get("icon")
        self._attr_native_unit_of_measurement = sensor_def.get("unit")
        self._attr_device_class = sensor_def.get("device_class")
        self._attr_state_class = sensor_def.get("state_class")
        self._attr_native_value = None

    @property
    def device_info(self) -> DeviceInfo:
        """Group all sensors under one device in the device registry."""
        return DeviceInfo(
            identifiers={(DOMAIN, self._device_id)},
            name=f"{self._hostname}",
            manufacturer="Computer Sync",
            model="Windows PC",
            sw_version="1.0.0",
        )

    async def async_added_to_hass(self) -> None:
        """Subscribe to heartbeat update events."""
        self.async_on_remove(
            self.hass.bus.async_listen(
                f"{DOMAIN}_data_updated",
                self._handle_data_update,
            )
        )
        # Load any already-available data
        self._refresh_value()

    @callback
    def _handle_data_update(self, event) -> None:
        """Triggered when a new heartbeat arrives for any device."""
        if event.data.get("device_id") != self._device_id:
            return
        self._refresh_value()
        self.async_write_ha_state()

    def _refresh_value(self) -> None:
        """Pull the latest value from shared device data."""
        devices = self.hass.data.get(DOMAIN, {}).get("devices", {})
        device_data: dict = devices.get(self._device_id, {}).get("data", {})
        raw = device_data.get(self._key)

        if raw is None:
            return

        # Numeric sensors: ensure correct type
        if self._attr_native_unit_of_measurement and isinstance(raw, str):
            try:
                raw = float(raw)
            except ValueError:
                pass

        self._attr_native_value = raw

    @property
    def available(self) -> bool:
        """Mark unavailable if we have never received data."""
        devices = self.hass.data.get(DOMAIN, {}).get("devices", {})
        return bool(devices.get(self._device_id, {}).get("data"))
