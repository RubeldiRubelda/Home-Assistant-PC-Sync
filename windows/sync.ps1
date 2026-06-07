#Requires -Version 5.1
<#
    Home Assistant Computer Sync - Windows Agent (Heartbeat Edition)
    Sends a consolidated JSON payload to a Home Assistant Webhook/API
    and executes commands received in the response.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

# ─── Configuration ────────────────────────────────────────────────────────────
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = if ($env:HA_CONFIG) { $env:HA_CONFIG } else { Join-Path $ScriptDir "config.cfg" }

# ─── Load Configuration ───────────────────────────────────────────────────────
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}

$Config = @{}
Get-Content $ConfigFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line -match '^([^=]+)=(.*)$') {
        $Config[$matches[1].Trim()] = $matches[2].Trim()
    }
}

foreach ($key in @('HA_URL', 'HA_TOKEN', 'DEVICE_ID')) {
    if (-not $Config[$key]) {
        Write-Error "Missing required config: $key"
        exit 1
    }
}

$HA_URL           = $Config['HA_URL'].TrimEnd('/')
$HA_TOKEN         = $Config['HA_TOKEN']
$DEVICE_ID        = $Config['DEVICE_ID'].ToLower()
$UPDATE_INTERVAL  = if ($Config['UPDATE_INTERVAL']) { [int]$Config['UPDATE_INTERVAL'] } else { 30 }
$COMMANDS_ENABLED = ($Config['COMMANDS_ENABLED'] -ne 'false')

# API Endpoint in our upcoming Custom integration!
$API_ENDPOINT = "$HA_URL/api/computer_sync/heartbeat"

# ─── Output Helper ────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$ts] $Msg"
}

# ─── Metric Collection ────────────────────────────────────────────────────────
function Get-SystemMetrics {
    # CPU
    $cpu = [int](Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    
    # Memory
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $usedMem = $os.TotalVisibleMemorySize - $os.FreePhysicalMemory
    $memPct = [Math]::Round($usedMem * 100 / $os.TotalVisibleMemorySize, 1)
    
    # Disk
    $diskPct = 0
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
    if ($disk) { $diskPct = [Math]::Round(($disk.Size - $disk.FreeSpace) * 100 / $disk.Size, 1) }
    
    # Battery
    $batLevel = -1
    $batStatusStr = 'Not Present'
    $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    if ($battery) { 
        $batLevel = $battery.EstimatedChargeRemaining 
        switch ($battery.BatteryStatus) {
            1  { $batStatusStr = 'Discharging' }
            2  { $batStatusStr = 'Charging' }
            3  { $batStatusStr = 'Full' }
            default { $batStatusStr = 'Unknown' }
        }
    }
    
    # Uptime
    $boot = $os.LastBootUpTime
    $span = (Get-Date) - $boot
    $parts = @()
    if ($span.Days -gt 0) { $parts += "$($span.Days) day$(if($span.Days -ne 1){'s'})" }
    if ($span.Hours -gt 0) { $parts += "$($span.Hours) hour$(if($span.Hours -ne 1){'s'})" }
    if ($parts.Count -eq 0) { $parts += "$($span.Minutes) minute$(if($span.Minutes -ne 1){'s'})" }
    $uptimeStr = 'up ' + ($parts -join ', ')
    
    # IP
    $ipStr = 'unknown'
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
          Select-Object -First 1 -ExpandProperty IPAddress
    if ($ip) { $ipStr = $ip }

    return @{
        device_id      = $DEVICE_ID
        hostname       = $env:COMPUTERNAME
        cpu            = $cpu
        memory         = $memPct
        disk           = $diskPct
        battery_level  = $batLevel
        battery_status = $batStatusStr
        uptime         = $uptimeStr
        ip             = $ipStr
        status         = "online"
    }
}

# ─── Remote Commands ──────────────────────────────────────────────────────────
function Execute-Command {
    param([string]$Cmd)
    if (-not $COMMANDS_ENABLED) { return }
    
    switch ($Cmd.ToLower()) {
        'none' { return }
        'shutdown' {
            Write-Log "Executing shutdown..."
            Start-Sleep -Seconds 2
            Stop-Computer -Force
        }
        'reboot' {
            Write-Log "Executing reboot..."
            Start-Sleep -Seconds 2
            Restart-Computer -Force
        }
        'sleep' {
            Write-Log "Executing sleep..."
            rundll32.exe powrprof.dll,SetSuspendState 0,1,0
        }
        'hibernate' {
            Write-Log "Executing hibernate..."
            rundll32.exe powrprof.dll,SetSuspendState 1,1,0
        }
        'lock' {
            Write-Log "Executing lock..."
            rundll32.exe user32.dll,LockWorkStation
        }
        default {
            Write-Log "WARNING: Unknown command '$Cmd'"
        }
    }
}

# ─── Heartbeat ─────────────────────────────────────────────────────────────
function Send-Heartbeat {
    $metrics = Get-SystemMetrics
    $body = $metrics | ConvertTo-Json -Compress
    
    try {
        Write-Log "Sending heartbeat to $API_ENDPOINT ..."
        $resp = Invoke-RestMethod -Uri $API_ENDPOINT -Method POST -Headers @{ Authorization = "Bearer $HA_TOKEN"; 'Content-Type' = 'application/json' } -Body $body -ErrorAction Stop

        if ($resp.command -and $resp.command -ne 'none') {
            Write-Log "Received command from HA: $($resp.command)"
            Execute-Command -Cmd $resp.command
        }
    } catch {
        Write-Log "Heartbeat API not yet reachable or error: $_"
    }
}

# ─── Main Loop ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Home Assistant Computer Sync (Heartbeat Edition)" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Device ID:      $DEVICE_ID"
Write-Host "  HA API:         $API_ENDPOINT"
Write-Host "  Interval:       ${UPDATE_INTERVAL}s"
Write-Host "  Commands:       $COMMANDS_ENABLED"
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "Agent started. Pushing heartbeat every ${UPDATE_INTERVAL}s..."
Write-Host ""

while ($true) {
    try {
        Send-Heartbeat
    } catch {
        Write-Log "ERROR in main loop: $_"
    }
    Start-Sleep -Seconds $UPDATE_INTERVAL
}
