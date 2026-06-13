# 🖥️ Home Assistant Computer Sync

Synchronise your **Windows** or **Linux** computer with [Home Assistant](https://www.home-assistant.io/).  
The agent running on your PC continuously pushes system metrics to HA via a secure heartbeat and lets you send remote commands (shutdown, reboot, sleep, hibernate, lock) back from anywhere — **no open ports on the PC required**.

> **Module M122 – Scripting Languages** · Open source · Personal & educational use

---

## How It Works

```
Your PC                                 Home Assistant
────────────────────────────────────────────────────────────────
sync.sh / sync.ps1  (background)
  → POST every 30 s ──────────────────→ /api/computer_sync/heartbeat
    { cpu, memory, disk, battery … }         ↓
                                        New device? → auto-create
                                        all sensors + control buttons
  ← { "command": "none" }  ←──────────  (Plug & Play, no config in HA!)
       or  { "command": "shutdown" }
  → executes command locally
```

The PC **connects outward** to Home Assistant — no firewall rules, no port forwarding.  
Works from any network as long as your HA instance is reachable (local or via DuckDNS / Nabu Casa).

---

## Features

| Metric / Action | Linux | Windows |
|---|:---:|:---:|
| CPU usage (%) | ✅ | ✅ |
| Memory usage (%) | ✅ | ✅ |
| Disk usage (%) | ✅ | ✅ |
| Battery level & status | ✅ | ✅ |
| System uptime | ✅ | ✅ |
| IP address | ✅ | ✅ |
| Online / Offline status | ✅ | ✅ |
| **Remote: Shutdown** | ✅ | ✅ |
| **Remote: Reboot** | ✅ | ✅ |
| **Remote: Sleep / Hibernate** | ✅ | ✅ |
| **Remote: Lock screen** | ✅ | ✅ |
| Auto-start on login | systemd user service | Windows Autostart shortcut |
| Auto device registration | ✅ | ✅ |

---

## Requirements

| | Linux | Windows |
|---|---|---|
| Shell | Bash 4+ | PowerShell 5.1+ (pre-installed on Win 10/11) |
| Tools | `curl`, `jq`, `iproute2` | Built-in cmdlets only |
| Network | Must reach HA instance | Must reach HA instance |

Install missing Linux tools:
```bash
sudo apt install curl jq iproute2      # Debian / Ubuntu
sudo dnf install curl jq iproute       # Fedora / RHEL
```

---

## Step 1 – Install the HA Custom Integration

The integration registers the heartbeat endpoint in Home Assistant and automatically creates all sensors and control buttons the moment a new device is detected.

### Via HACS (recommended)

1. Open HACS → **Integrations** → ⋮ (top right) → **Custom Repositories**
2. URL: `https://github.com/RubeldiRubelda/Home-Assistant-PC-Sync`  
   Category: **Integration** → **Add**
3. Search for **Computer Sync** → **Download**
4. **Restart Home Assistant**

### Manually

```
Copy:  custom_components/computer_sync/
Into:  config/custom_components/computer_sync/

Restart Home Assistant.
```

### Activate the Integration

1. **Settings → Devices & Services → + Add Integration**
2. Search for **Computer Sync** → set up
3. Done – the heartbeat endpoint `/api/computer_sync/heartbeat` is now active

---

## Step 2 – Create a Long-Lived Access Token

1. Open Home Assistant in your browser.
2. Click your **profile picture** (bottom-left corner).
3. Scroll down to **Long-Lived Access Tokens**.
4. Click **Create Token**, give it a name (e.g. `Computer Sync`), click **OK**.
5. **Copy the token** – it is shown only once!

---

## Step 3 – Install the Agent on Your Computer

### Linux

```bash
git clone https://github.com/RubeldiRubelda/Home-Assistant-PC-Sync.git
cd Home-Assistant-PC-Sync/linux
chmod +x setup.sh sync.sh
./setup.sh
```

The installer will:
1. Check for required tools (`curl`, `jq`)
2. Generate a unique **Device ID** from your hostname (saved permanently)
3. Ask for your **HA URL** and **Access Token**
4. Install `sync.sh` to `/opt/ha-computer-sync/`
5. Write `config.cfg` with your settings
6. Create and optionally start a **systemd user service**

**Useful commands after install:**

```bash
# Live log output
journalctl --user -u ha-computer-sync -f

# Stop / Start / Restart
systemctl --user stop    ha-computer-sync
systemctl --user start   ha-computer-sync
systemctl --user restart ha-computer-sync

# Edit configuration
nano /opt/ha-computer-sync/config.cfg

# Uninstall
bash /opt/ha-computer-sync/uninstall.sh
```

---

### Windows

Open **PowerShell as Administrator** and run:

```powershell
cd Home-Assistant-PC-Sync\windows
.\setup.ps1
```

The installer will:
1. Generate a unique **Device ID** from your computer name (saved permanently to `.device_id`)
2. Ask for your **HA URL** and **Access Token**
3. Install `sync.ps1` to `C:\Program Files\Home-Assistant-Computer-Sync\`
4. Write `config.cfg` with your settings
5. Optionally create an **Autostart shortcut** (runs hidden at login)
6. Optionally start the agent immediately

**Useful commands after install:**

```powershell
# Edit configuration
notepad "C:\Program Files\Home-Assistant-Computer-Sync\config.cfg"

# Uninstall
& "C:\Program Files\Home-Assistant-Computer-Sync\uninstall.ps1"
```

---

## Step 4 – Verify in Home Assistant

After the first heartbeat is received, open **Settings → Devices & Services → Computer Sync**.  
Your device appears automatically with all sensors and control buttons:

| Entity | Example value |
|---|---|
| `sensor.MY_DEVICE_status` | `online` |
| `sensor.MY_DEVICE_cpu_usage` | `12` (%) |
| `sensor.MY_DEVICE_memory_usage` | `54.3` (%) |
| `sensor.MY_DEVICE_disk_usage` | `67` (%) |
| `sensor.MY_DEVICE_battery_level` | `85` (%) |
| `sensor.MY_DEVICE_battery_status` | `Discharging` |
| `sensor.MY_DEVICE_uptime` | `up 3 days, 4 hours` |
| `sensor.MY_DEVICE_ip_address` | `192.168.1.42` |
| `button.MY_DEVICE_shutdown` | — |
| `button.MY_DEVICE_reboot` | — |
| `button.MY_DEVICE_sleep` | — |
| `button.MY_DEVICE_hibernate` | — |
| `button.MY_DEVICE_lock` | — |

---

## Step 5 – Send Remote Commands

Press any control button in the Home Assistant device page or dashboard.  
The command is queued and delivered on the next heartbeat (within `UPDATE_INTERVAL` seconds).  
Commands can also be triggered from **automations**, **scripts**, or the **HA Companion App**.

---

## Configuration Reference

`config.cfg` (same format on Linux and Windows):

```ini
# URL of your Home Assistant instance
HA_URL=http://homeassistant.local:8123

# Long-Lived Access Token (create in HA profile page)
HA_TOKEN=your_token_here

# Unique device identifier – generated automatically, do not change!
DEVICE_ID=my_laptop

# How often to send metrics in seconds (minimum: 10)
UPDATE_INTERVAL=30

# Allow remote commands from HA (true / false)
COMMANDS_ENABLED=true
```

---

## Dashboard Example

Add a card to your HA dashboard (replace `my_laptop` with your Device ID):

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
  - entity: button.my_laptop_shutdown
  - entity: button.my_laptop_reboot
  - entity: button.my_laptop_sleep
  - entity: button.my_laptop_hibernate
  - entity: button.my_laptop_lock
```

---

## Project Structure

```
Home-Assistant-PC-Sync/
├── custom_components/
│   └── computer_sync/          HA custom integration (install via HACS)
│       ├── __init__.py         Heartbeat endpoint + auto device discovery
│       ├── sensor.py           Dynamic sensors (CPU, RAM, disk, battery …)
│       ├── button.py           Control buttons (shutdown, reboot, lock …)
│       ├── config_flow.py      UI setup + auto config entry
│       ├── const.py            Constants and sensor definitions
│       ├── manifest.json
│       └── translations/
├── linux/
│   ├── config.cfg              Configuration template
│   ├── setup.sh                Installation script (Bash)
│   └── sync.sh                 Sync agent (Bash)
├── windows/
│   ├── config.cfg              Configuration template
│   ├── setup.ps1               Installation script (PowerShell)
│   └── sync.ps1                Sync agent (PowerShell)
├── hacs.json
└── README.md
```

---

## Troubleshooting

**No sensors appear after the first heartbeat**  
→ Confirm the integration is installed and HA has been restarted.  
→ Check that `HA_URL` is reachable from your PC: `curl http://homeassistant.local:8123/api/`  
→ Verify the token is correct and not expired.

**Remote commands are not executed**  
→ Check that `COMMANDS_ENABLED=true` in `config.cfg`.  
→ On Linux, power commands require `sudo` – the uninstall/setup scripts handle this; check `sudo systemctl poweroff` works manually.  
→ Review the agent log for error messages.

**Linux: Service does not start after reboot**  
→ Run `loginctl enable-linger $USER` to allow user services without an active graphical session.

**Windows: Script blocked by execution policy**  
→ Run `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` and retry.

**Linux: CPU usage shows 0**  
→ Ensure `/proc/stat` is accessible (standard on all Linux distributions).

---

## Security Notes

- `config.cfg` contains your HA token. On Linux the file is only readable by your user (`chmod 600`). On Windows it lives in `C:\Program Files\Home-Assistant-Computer-Sync\` with standard NTFS permissions.
- Use a **dedicated HA user** with minimal permissions if you share your HA instance.
- Remote commands (shutdown, reboot) are powerful — ensure only trusted HA users can press the control buttons.
- Set `COMMANDS_ENABLED=false` to disable all remote actions on a per-device basis.

---

## License

Open source — free to use and modify for personal and educational purposes.  
*Module M122 – Scripting Languages*
