"""
Home Assistant Computer Sync - Custom Integration
==================================================
Registers the /api/computer_sync/heartbeat endpoint.
When a new device sends its first heartbeat, all sensors
and control buttons are auto-created (Plug & Play).
"""
from __future__ import annotations

import asyncio
import logging
from typing import Any

from homeassistant.components.http import HomeAssistantView
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant
from homeassistant.helpers import device_registry as dr, entity_registry as er
from homeassistant.helpers.entity_component import EntityComponent

from .const import (
    DOMAIN,
    CONF_COMMAND_QUEUE,
    SENSOR_DEFINITIONS,
    COMMAND_NONE,
)

_LOGGER = logging.getLogger(__name__)

PLATFORMS: list[Platform] = [Platform.SENSOR, Platform.BUTTON]


async def async_setup(hass: HomeAssistant, config: dict) -> bool:
    """Set up the computer_sync component."""
    hass.data.setdefault(DOMAIN, {})
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up computer_sync from a config entry."""
    hass.data.setdefault(DOMAIN, {})

    # Register the heartbeat HTTP endpoint (once, not per entry)
    if not hass.data[DOMAIN].get("view_registered"):
        hass.http.register_view(HeartbeatView(hass))
        hass.data[DOMAIN]["view_registered"] = True
        _LOGGER.info("Computer Sync: Heartbeat endpoint registered at /api/computer_sync/heartbeat")

    # Per-entry device storage: {device_id: {sensors, command_queue, ...}}
    hass.data[DOMAIN].setdefault("devices", {})

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Unload a config entry."""
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)


# ─── Heartbeat HTTP View ───────────────────────────────────────────────────────

class HeartbeatView(HomeAssistantView):
    """
    Receives POST /api/computer_sync/heartbeat from Windows agents.
    
    Expected JSON payload (from sync.ps1):
    {
        "device_id": "my_laptop",
        "hostname": "MY-LAPTOP",
        "cpu": 42,
        "memory": 67.3,
        "disk": 55.1,
        "battery_level": 88,
        "battery_status": "Charging",
        "uptime": "up 2 days, 3 hours",
        "ip": "192.168.1.50",
        "status": "online"
    }
    
    Returns JSON: {"command": "none"} or {"command": "shutdown"} etc.
    Authentication: Bearer token (HA Long-Lived Access Token).
    """

    url = "/api/computer_sync/heartbeat"
    name = "api:computer_sync:heartbeat"
    requires_auth = True  # HA validates the Bearer token automatically

    def __init__(self, hass: HomeAssistant) -> None:
        self.hass = hass

    async def post(self, request):
        """Handle incoming heartbeat POST."""
        from aiohttp.web import Response
        import json

        try:
            payload: dict[str, Any] = await request.json()
        except Exception:
            return Response(status=400, text='{"error": "Invalid JSON"}', content_type="application/json")

        device_id = payload.get("device_id", "").lower().strip()
        if not device_id:
            return Response(status=400, text='{"error": "Missing device_id"}', content_type="application/json")

        _LOGGER.debug("Computer Sync: Heartbeat from '%s': %s", device_id, payload)

        devices = self.hass.data[DOMAIN].setdefault("devices", {})

        # ── Auto-register new device ──────────────────────────────────────────
        if device_id not in devices:
            _LOGGER.info("Computer Sync: New device discovered: '%s' – auto-creating entities.", device_id)
            devices[device_id] = {
                CONF_COMMAND_QUEUE: asyncio.Queue(),
                "data": {},
                "entry_id": None,  # Will be linked when config entry exists
            }

            # Fire an event so config_flow or sensors can react
            self.hass.bus.async_fire(
                f"{DOMAIN}_device_discovered",
                {"device_id": device_id, "hostname": payload.get("hostname", device_id)},
            )

            # Auto-create a config entry for this device if none exists
            await self._ensure_config_entry(device_id, payload)

        # ── Update sensor data ────────────────────────────────────────────────
        devices[device_id]["data"] = payload

        # Notify all sensor entities that data has changed
        self.hass.bus.async_fire(
            f"{DOMAIN}_data_updated",
            {"device_id": device_id},
        )

        # ── Dequeue pending command ───────────────────────────────────────────
        command = COMMAND_NONE
        cmd_queue: asyncio.Queue = devices[device_id][CONF_COMMAND_QUEUE]
        try:
            command = cmd_queue.get_nowait()
            _LOGGER.info("Computer Sync: Dispatching command '%s' to '%s'", command, device_id)
        except asyncio.QueueEmpty:
            pass

        response_body = json.dumps({"command": command})
        return Response(
            status=200,
            text=response_body,
            content_type="application/json",
        )

    async def _ensure_config_entry(self, device_id: str, payload: dict) -> None:
        """Auto-create a config entry for a newly discovered device."""
        existing = [
            e for e in self.hass.config_entries.async_entries(DOMAIN)
            if e.data.get("device_id") == device_id
        ]
        if existing:
            return

        hostname = payload.get("hostname", device_id)
        _LOGGER.info("Computer Sync: Auto-creating config entry for '%s' (%s)", device_id, hostname)

        self.hass.async_create_task(
            self.hass.config_entries.flow.async_init(
                DOMAIN,
                context={"source": "discovery"},
                data={"device_id": device_id, "hostname": hostname},
            )
        )
