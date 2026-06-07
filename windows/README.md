# 🖥️ Home Assistant Computer Sync

Überwache und steuere deinen Windows-PC direkt aus Home Assistant – **vollautomatisch, kein Port-Forwarding, kein manuelles Einrichten.**

---

## ✨ Funktionsweise

```
Windows PC                          Home Assistant
──────────────────────────────────────────────────────
sync.ps1 läuft im Hintergrund
  → sendet alle 30s einen POST    →  /api/computer_sync/heartbeat
     mit CPU, RAM, Disk, Akku…         ↓
                                    Gerät neu? → Config Entry + Sensoren + Buttons anlegen
                                    Befehl in Queue? → {"command": "shutdown"}
  ← empfängt Antwort              ←  {"command": "none"}
     führt Befehl aus
```

Der PC verbindet sich **aktiv** mit Home Assistant – keine offenen Ports auf dem PC nötig. Funktioniert auch in fremden Netzwerken (Hotel, Büro) solange HA von außen erreichbar ist.

---

## 📦 Installation

### 1. Home Assistant Integration installieren

**Via HACS (empfohlen):**
1. HACS → Integrationen → `+` → "Computer Sync" suchen → Installieren
2. HA neu starten

**Manuell:**
```
Ordner kopieren:
  custom_components/computer_sync/
  → nach: config/custom_components/computer_sync/

Home Assistant neu starten.
```

### 2. Integration in HA aktivieren

1. **Einstellungen → Geräte & Dienste → Integration hinzufügen**
2. „Computer Sync" suchen → einrichten
3. ✅ Fertig – der Heartbeat-Endpunkt ist jetzt aktiv

### 3. Windows Agent installieren

```powershell
# Als Administrator ausführen:
.\setup.ps1
```

Das Skript fragt nach:
- HA URL (z.B. `https://myhome.duckdns.org`)
- Long-Lived Access Token (Profil → Long-Lived Access Tokens)

Die **Geräte-ID** wird automatisch aus dem Computernamen generiert und gespeichert.

### 4. Fertig! 🎉

Sobald der erste Heartbeat ankommt, erscheinen in HA automatisch:

| Sensor | Beschreibung |
|--------|-------------|
| `sensor.GERÄT_cpu_usage` | CPU-Auslastung (%) |
| `sensor.GERÄT_memory_usage` | RAM-Auslastung (%) |
| `sensor.GERÄT_disk_usage` | Disk C: Auslastung (%) |
| `sensor.GERÄT_battery_level` | Akkustand (%) |
| `sensor.GERÄT_battery_status` | Ladestand-Status |
| `sensor.GERÄT_uptime` | Laufzeit seit letztem Boot |
| `sensor.GERÄT_ip_address` | Aktuelle IP-Adresse |
| `sensor.GERÄT_status` | online / offline |
| `sensor.GERÄT_hostname` | Computername |

| Button | Aktion |
|--------|--------|
| `button.GERÄT_shutdown` | PC herunterfahren |
| `button.GERÄT_reboot` | PC neustarten |
| `button.GERÄT_sleep` | Ruhezustand |
| `button.GERÄT_hibernate` | Tiefschlaf |
| `button.GERÄT_lock` | PC sperren |

---

## ⚙️ Konfigurationsdatei

```ini
# C:\Program Files\Home-Assistant-Computer-Sync\config.cfg

HA_URL=https://myhome.duckdns.org
HA_TOKEN=eyJ...
DEVICE_ID=mein_laptop        # automatisch generiert, nicht ändern!
UPDATE_INTERVAL=30           # Sekunden (Minimum: 10)
COMMANDS_ENABLED=true        # false = Steuerungs-Buttons deaktivieren
```

---

## 🔧 Mehrere PCs

Führe `setup.ps1` auf jedem PC aus. Jedes Gerät registriert sich selbst mit seiner eindeutigen ID. Für jeden PC entstehen eigene Sensoren und Buttons in HA.

---

## 🗑️ Deinstallation

**Windows Agent:**
```powershell
# Als Administrator:
C:\Program Files\Home-Assistant-Computer-Sync\uninstall.ps1
```

**HA Integration:**
Einstellungen → Geräte & Dienste → Computer Sync → Löschen

---

## 🔒 Sicherheit

- Authentifizierung via HA Long-Lived Access Token (Bearer-Header)
- Home Assistant validiert das Token automatisch
- Kein offener Port auf dem PC
- `COMMANDS_ENABLED=false` deaktiviert alle Remote-Aktionen
