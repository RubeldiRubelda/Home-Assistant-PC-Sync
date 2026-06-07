"""Config flow for Computer Sync integration."""
from __future__ import annotations

import logging
from typing import Any

import voluptuous as vol

from homeassistant import config_entries
from homeassistant.core import HomeAssistant
from homeassistant.data_entry_flow import FlowResult

from .const import DOMAIN, CONF_DEVICE_ID, CONF_HOSTNAME

_LOGGER = logging.getLogger(__name__)


class ComputerSyncConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """
    Handle a config flow for Computer Sync.

    Two sources:
    1. User-initiated (via UI): just confirm to activate the integration.
       Devices register themselves automatically on first heartbeat.
    2. Discovery: triggered automatically when a new device sends its
       first heartbeat (via async_fire "computer_sync_device_discovered").
    """

    VERSION = 1

    def __init__(self) -> None:
        self._device_id: str | None = None
        self._hostname: str | None = None

    # ── User-initiated setup ──────────────────────────────────────────────────

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        """
        First-time setup through the UI.
        No configuration needed – just activate the integration.
        Devices register automatically when they send their first heartbeat.
        """
        if user_input is not None:
            return self.async_create_entry(
                title="Computer Sync (Hub)",
                data={"hub": True},
            )

        return self.async_show_form(
            step_id="user",
            description_placeholders={
                "endpoint": "/api/computer_sync/heartbeat"
            },
            data_schema=vol.Schema({}),
        )

    # ── Auto-discovery (fired by HeartbeatView) ───────────────────────────────

    async def async_step_discovery(
        self, discovery_info: dict[str, Any]
    ) -> FlowResult:
        """Handle a discovered device (called programmatically)."""
        device_id: str = discovery_info["device_id"]
        hostname: str = discovery_info.get("hostname", device_id)

        # Prevent duplicate config entries for the same device
        await self.async_set_unique_id(f"{DOMAIN}_{device_id}")
        self._abort_if_unique_id_configured()

        self._device_id = device_id
        self._hostname = hostname

        return self.async_create_entry(
            title=f"Computer: {hostname} ({device_id})",
            data={
                CONF_DEVICE_ID: device_id,
                CONF_HOSTNAME: hostname,
            },
        )
