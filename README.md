# Home-Assistant-Computer-Sync

Synchronise your **Windows** or **Linux** computer with [Home Assistant](https://www.home-assistant.io/).  
The agent running on your PC continuously sends system metrics to HA and lets you send remote commands (shutdown, reboot, sleep, lock) back to the computer from anywhere.

---

## Features

| Metric / Action | Linux (Bash) | Windows (PowerShell) |
|---|:---:|:---:|
| CPU usage (%) | ✅ | ✅ |
| Memory usage (%) | ✅ | ✅ |
| Disk usage (%) | ✅ | ✅ |
| Battery level & status | ✅ | ✅ |
| System uptime | ✅ | ✅ |
| IP address | ✅ | ✅ |
| Online/Offline status | ✅ | ✅ |
| **Remote: Shutdown** | ✅ | ✅ |
| **Remote: Reboot** | ✅ | ✅ |
| **Remote: Sleep / Hibernate** | ✅ | ✅ |
| **Remote: Lock screen** | ✅ | ✅ |
| Auto-start on login | systemd user service | Task Scheduler |

---

## Requirements

| | Linux | Windows |
|---|---|---|
| Shell | Bash 4+ | PowerShell 5.1+ (pre-installed on Win 10/11) |
| Tools | `curl`, `ip` / `hostname` | Built-in cmdlets only |
| Network | Must reach HA instance | Must reach HA instance |

---

## Step 1 – Prepare Home Assistant

### 1a – Create a Long-Lived Access Token

1. Open Home Assistant in your browser.
2. Click your **profile picture** (bottom-left corner).
3. Scroll down to **Long-Lived Access Tokens**.
4. Click **Create Token**, enter a name (e.g. `Computer Sync`), and click **OK**.
5. **Copy the token** – you will need it during installation. It is shown only once!

### 1b – Add the Command Helper

The agent polls an `input_select` entity in HA to receive remote commands.  
Create one helper per managed computer:

**Option A – HA User Interface (recommended):**

1. Go to **Settings → Devices & Services → Helpers**.
2. Click **+ Create Helper → Dropdown**.
3. Fill in:
   - **Name**: `My Laptop – Remote Command` (or similar)
   - **Options**: `none`, `shutdown`, `reboot`, `sleep`, `hibernate`, `lock`
4. Click **Create**.
5. Note the entity ID shown (e.g. `input_select.my_laptop_remote_command`).  
   You will need to use the same base name as your **Device ID** (see install step),  
   e.g. Device ID `my_laptop` → entity `input_select.my_laptop_command`.

**Option B – configuration.yaml:**

See [`homeassistant/configuration.yaml`](homeassistant/configuration.yaml) for copy-pasteable snippets.  
Restart Home Assistant after editing configuration.yaml.

---

## Step 2 – Install the Agent

### Linux

```bash
# Clone or download this repository, then:
cd Home-Assistant-Computer-Sync/linux
chmod +x install.sh sync.sh
./install.sh
```

The installer will:
1. Ask for your HA URL, token, device name, and update interval.
2. Copy `sync.sh` to `~/.local/share/ha-computer-sync/`.
3. Write your config to `~/.config/ha-computer-sync/config.cfg` (chmod 600).
4. Create and start a **systemd user service** that auto-starts at login.
5. Optionally add a sudoers rule so power commands run without a password prompt.

MQTT Discovery (optional):
If you enable MQTT during installation the agent will publish Home Assistant MQTT discovery
payloads and state topics so sensors and a command `select` are created automatically.
The installer attempts to install the Python dependency `paho-mqtt` when MQTT is enabled.
You still need a running MQTT broker reachable from the computer (e.g., Mosquitto or the
Home Assistant Mosquitto add-on).

**Manual config location:** `~/.config/ha-computer-sync/config.cfg`

**Useful commands after install:**

```bash
# View live log output
journalctl --user -u ha-computer-sync -f

# Stop / start / restart
systemctl --user stop    ha-computer-sync
systemctl --user start   ha-computer-sync
systemctl --user restart ha-computer-sync

# Edit configuration
nano ~/.config/ha-computer-sync/config.cfg

# Uninstall
systemctl --user disable --now ha-computer-sync
rm -rf ~/.local/share/ha-computer-sync ~/.config/ha-computer-sync
rm -f  ~/.config/systemd/user/ha-computer-sync.service
```

---

### Windows

Open **PowerShell** (no Administrator rights needed) and run:

```powershell
# Navigate to the windows folder of this repository
cd Home-Assistant-Computer-Sync\windows

# Allow running the installer (one-time, current user only)
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

.\install.ps1
```

The installer will prompt for administrator rights if needed and then continue in an elevated PowerShell window. Leave that window open until setup finishes.
It uses only built-in Windows PowerShell and does not require Python.

The installer will:
1. Ask for your HA URL, token, device name, and update interval.
2. Copy `sync.ps1` to `%APPDATA%\HA-Computer-Sync\`.
3. Write your config to `%APPDATA%\HA-Computer-Sync\config.cfg`.
4. Optionally create a **Task Scheduler** task that runs at every login.
5. Optionally start the task immediately.

**Manual config location:** `%APPDATA%\HA-Computer-Sync\config.cfg`

**Useful commands after install:**

```powershell
# Stop / start the agent
Stop-ScheduledTask  -TaskName 'HA-Computer-Sync'
Start-ScheduledTask -TaskName 'HA-Computer-Sync'

# Edit configuration
notepad "$env:APPDATA\HA-Computer-Sync\config.cfg"

# Uninstall
Stop-ScheduledTask        -TaskName 'HA-Computer-Sync'
Unregister-ScheduledTask  -TaskName 'HA-Computer-Sync' -Confirm:$false
Remove-Item -Recurse -Force "$env:APPDATA\HA-Computer-Sync"
```

---

## Step 3 – Verify in Home Assistant

After starting the agent, open **Developer Tools → States** in HA and search for your Device ID.  
You should see sensors like:

| Entity ID | Example value |
|---|---|
| `sensor.my_laptop_status` | `online` |
| `sensor.my_laptop_cpu_usage` | `12` (%) |
| `sensor.my_laptop_memory_usage` | `54.3` (%) |
| `sensor.my_laptop_disk_usage` | `67` (%) |
| `sensor.my_laptop_battery_level` | `85` (%) |
| `sensor.my_laptop_battery_status` | `Discharging` |
| `sensor.my_laptop_uptime` | `up 3 days, 4 hours` |
| `sensor.my_laptop_ip_address` | `192.168.1.42` |

---

## Step 4 – Send Remote Commands

1. In HA open the **Entities** view or a dashboard.
2. Find `input_select.my_laptop_command` (or your Device ID).
3. Select a command from the dropdown: `shutdown`, `reboot`, `sleep`, `hibernate`, or `lock`.
4. The agent will detect the change within `UPDATE_INTERVAL` seconds, execute the command,
   and reset the dropdown back to `none`.

You can also trigger commands from **automations**, **scripts**, or the HA **companion app**.

---

## Configuration Reference

Both `linux/config.cfg` and `windows/config.cfg` share the same format:

```ini
# URL of your Home Assistant instance
HA_URL=http://homeassistant.local:8123

# Long-Lived Access Token (create in HA profile page)
HA_TOKEN=your_token_here

# Unique identifier for this device (lowercase, no spaces)
# Used as prefix for all sensor entity IDs
DEVICE_ID=my_laptop

# How often to send metrics (in seconds, minimum 10)
UPDATE_INTERVAL=30

# Enable/disable remote commands from HA
COMMANDS_ENABLED=true
```

---

## Dashboard Example

Add a card to your HA dashboard to see all metrics at a glance.  
Example Lovelace YAML (replace `my_laptop` with your Device ID):

```yaml
type: entities
title: My Laptop
entities:
  - entity: sensor.my_laptop_status
  - entity: sensor.my_laptop_cpu_usage
  - entity: sensor.my_laptop_memory_usage
  - entity: sensor.my_laptop_disk_usage
  - entity: sensor.my_laptop_battery_level
  - entity: sensor.my_laptop_battery_status
  - entity: sensor.my_laptop_uptime
  - entity: sensor.my_laptop_ip_address
  - entity: input_select.my_laptop_command
```

---

## Troubleshooting

**The agent connects but no sensors appear in HA**  
→ Make sure you are using the correct HA_TOKEN and that the token has not expired.  
→ Check that `HA_URL` is reachable from your computer (try `curl http://homeassistant.local:8123/api/` in a terminal).

**Remote commands are not executed**  
→ Ensure the `input_select` entity ID exactly matches `input_select.{DEVICE_ID}_command`.  
→ On Linux, make sure the sudoers rule was added (see `install.sh` output).  
→ Check the agent log for error messages.

**Linux: Service does not start after reboot**  
→ Run `loginctl enable-linger $USER` to allow user services to start without a graphical session.

**Windows: Script is blocked by execution policy**  
→ Run `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` in PowerShell and try again.

**Linux: CPU usage always shows 0**  
→ Make sure `/proc/stat` is accessible (it should be on all Linux distributions).

---

## Security Notes

- The **config.cfg** file contains your HA token. On Linux the installer sets permissions to `600`
  (only readable by you). On Windows, store it in your user profile (`%APPDATA%`) and ensure other
  users on the machine cannot access it.
- Use a **dedicated HA user** or a token with minimal permissions if you are security-conscious.
- Remote commands (shutdown, reboot) are powerful – ensure only trusted HA users have access to the
  `input_select` entity.

---

## Project Structure

```
Home-Assistant-Computer-Sync/
├── linux/
│   ├── config.cfg        Configuration template
│   ├── install.sh        Installation script (Bash)
│   └── sync.sh           Sync agent (Bash)
├── windows/
│   ├── config.cfg        Configuration template
│   ├── install.ps1       Installation script (PowerShell)
│   └── sync.ps1          Sync agent (PowerShell)
├── homeassistant/
│   └── configuration.yaml  HA configuration snippets
└── README.md
```

---

## License

This project is open-source. Feel free to use and modify it for personal and educational purposes
(Module M122 – Scripting Languages).
