#Requires -Version 5.1
<#
    Home Assistant Computer Sync - Windows Setup
    =============================================
    Installiert den Sync-Agent nach C:\Program Files\Home-Assistant-Computer-Sync
    und richtet den Autostart ein.

    Plug & Play: Das Gerät wird automatisch in Home Assistant registriert,
    sobald der erste Heartbeat empfangen wird. Keine manuelle Konfiguration in HA nötig!
#>

# ─── Admin-Check ─────────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Warning "Administratorrechte werden benötigt. Fordere Rechte an..."
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs
    Exit
}

# ─── Pfade ────────────────────────────────────────────────────────────────────
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceSyncScript = Join-Path $ScriptDir "sync.ps1"
$InstallDir      = Join-Path $env:ProgramFiles "Home-Assistant-Computer-Sync"
$DestConfigFile  = Join-Path $InstallDir "config.cfg"
$DestSyncScript  = Join-Path $InstallDir "sync.ps1"
$UninstallScript = Join-Path $InstallDir "uninstall.ps1"
$DeviceIdFile    = Join-Path $InstallDir ".device_id"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Home Assistant Computer Sync - Windows Setup" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# ─── 1. Geräte-ID ────────────────────────────────────────────────────────────
# Die Geräte-ID wird einmalig generiert und gespeichert (unveränderlich).
# Basiert auf dem Computernamen; Sonderzeichen werden entfernt.

if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory | Out-Null
}

if (Test-Path $DeviceIdFile) {
    $deviceId = (Get-Content $DeviceIdFile -Raw).Trim()
    Write-Host "[i] Bestehende Geräte-ID gefunden: $deviceId" -ForegroundColor Yellow
} else {
    # Automatisch aus Hostname ableiten: nur a-z, 0-9 und Unterstriche
    $rawId = $env:COMPUTERNAME.ToLower() -replace '[^a-z0-9]', '_'
    $deviceId = $rawId.Trim('_')
    $deviceId | Out-File -FilePath $DeviceIdFile -Encoding UTF8 -NoNewline
    Write-Host "[+] Neue Geräte-ID generiert: $deviceId" -ForegroundColor Green
}

# ─── 2. Konfigurationsabfrage ─────────────────────────────────────────────────
Write-Host ""
Write-Host "Das Skript nutzt einen sicheren Heartbeat ohne offene Ports." -ForegroundColor Yellow
Write-Host "Kein Port-Forwarding nötig – der PC verbindet sich aktiv mit HA." -ForegroundColor Yellow
Write-Host ""

$haUrl = Read-Host "Home Assistant URL (z.B. http://homeassistant.local:8123 oder https://myhome.duckdns.org)"
$haUrl = $haUrl.TrimEnd('/')

Write-Host ""
Write-Host "Long-Lived Access Token:" -ForegroundColor Yellow
Write-Host "  → Profil (unten links) → Long-Lived Access Tokens → Token erstellen" -ForegroundColor Gray
$haToken = Read-Host "HA Token"

$updateInterval = Read-Host "Heartbeat-Intervall in Sekunden [Standard: 30]"
if ([string]::IsNullOrWhiteSpace($updateInterval)) { $updateInterval = "30" }

$commandsEnabled = Read-Host "Remote-Befehle erlauben? (Herunterfahren, Sperren etc.) [true/false, Standard: true]"
if ([string]::IsNullOrWhiteSpace($commandsEnabled)) { $commandsEnabled = "true" }

# ─── 3. Dateien installieren ──────────────────────────────────────────────────
Copy-Item -Path $SourceSyncScript -Destination $DestSyncScript -Force

$configContent = @"
# Home Assistant Computer Sync - Windows Configuration
# =========================================================
# Generiert von setup.ps1 – manuell bearbeitbar, dann Agent neu starten.

# HA_URL - Vollständige URL deiner Home Assistant Instanz
HA_URL=$haUrl

# HA_TOKEN - Long-Lived Access Token (Profil → Long-Lived Access Tokens)
HA_TOKEN=$haToken

# DEVICE_ID - Eindeutige Geräte-ID (automatisch generiert, nicht ändern!)
DEVICE_ID=$deviceId

# UPDATE_INTERVAL - Heartbeat-Intervall in Sekunden (Minimum: 10)
UPDATE_INTERVAL=$updateInterval

# COMMANDS_ENABLED - Remote-Befehle via Heartbeat erlauben
COMMANDS_ENABLED=$commandsEnabled
"@
$configContent | Out-File -FilePath $DestConfigFile -Encoding UTF8

Write-Host ""
Write-Host "[+] Dateien installiert:     $InstallDir" -ForegroundColor Green
Write-Host "[+] Konfiguration gespeichert: $DestConfigFile" -ForegroundColor Green
Write-Host "[+] Geräte-ID:               $deviceId" -ForegroundColor Green

# ─── 4. Deinstallationsskript erstellen ───────────────────────────────────────
$uninstallContent = @"
#Requires -Version 5.1
`$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not `$isAdmin) { Write-Warning "Bitte als Administrator ausführen."; Exit }

`$confirm = Read-Host "Wirklich deinstallieren? (y/n)"
if (`$confirm -match "^y") {
    Write-Host "Beende laufenden Sync-Prozess..."
    Get-WmiObject Win32_Process -Filter "CommandLine LIKE '%Home-Assistant-Computer-Sync%sync.ps1%'" | Invoke-WmiMethod -Name Terminate | Out-Null

    Write-Host "Entferne Autostart-Eintrag..."
    `$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) "HA-Computer-Sync.lnk"
    if (Test-Path `$ShortcutPath) { Remove-Item `$ShortcutPath -Force }

    Write-Host "Entferne Installationsverzeichnis..."
    Start-Sleep -Seconds 1
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c ping localhost -n 3 > nul & rmdir /s /q `"$InstallDir`"" -WindowStyle Hidden
    Write-Host "Deinstallation abgeschlossen!" -ForegroundColor Green
    Start-Sleep -Seconds 3
}
"@
$uninstallContent | Out-File -FilePath $UninstallScript -Encoding UTF8

# ─── 5. Autostart ─────────────────────────────────────────────────────────────
$setupAutostart = Read-Host "`nAutostart beim Login einrichten? (y/n)"
if ($setupAutostart -match "^y") {
    $WshShell     = New-Object -ComObject WScript.Shell
    $ShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) "HA-Computer-Sync.lnk"

    $Shortcut                  = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath       = "powershell.exe"
    $Shortcut.Arguments        = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$DestSyncScript`""
    $Shortcut.WorkingDirectory = $InstallDir
    $Shortcut.Description      = "Home Assistant Computer Sync Agent"
    $Shortcut.Save()

    Write-Host "[+] Autostart eingerichtet: $ShortcutPath" -ForegroundColor Green

    $startNow = Read-Host "Agent jetzt starten? (y/n)"
    if ($startNow -match "^y") {
        Start-Process -FilePath "powershell.exe" -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$DestSyncScript`""
        Write-Host "[+] Agent im Hintergrund gestartet." -ForegroundColor Green
        Write-Host ""
        Write-Host "Home Assistant wird das Gerät '$deviceId' automatisch erkennen" -ForegroundColor Cyan
        Write-Host "und alle Sensoren & Steuerungs-Buttons anlegen!" -ForegroundColor Cyan
    }
} else {
    Write-Host "[-] Autostart übersprungen." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Setup abgeschlossen!" -ForegroundColor Cyan
Write-Host "  Geräte-ID: $deviceId" -ForegroundColor Cyan
Write-Host "  HA URL:    $haUrl" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Drücke eine Taste zum Beenden..."
$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
