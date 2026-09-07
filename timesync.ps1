<#
.SYNOPSIS
    NTPulse - Precision Time Synchronization Engine
.DESCRIPTION
    Automatic Windows time correction using reliable NTP servers.
    Features: Manual sync, auto-sync timer, system tray, startup task.
.NOTES
    Requires Administrator privileges. Self-elevates if needed.
    Windows 10/11 with PowerShell 5.1+
#>

param(
    [switch]$AutoSync,
    [switch]$Background,
    [ValidateSet("Enable", "Disable")]
    [string]$Configure
)

# ================================================================
# CONSTANTS
# ================================================================
$ScriptPath    = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$ProjectRoot   = Split-Path -Parent $ScriptPath
$RegPath       = "HKCU:\Software\NTPulse"
$TaskName      = "NTPulse"
$LogDir        = Join-Path $env:LOCALAPPDATA "NTPulse"
$LogFile       = Join-Path $ProjectRoot "sync.log"
$ServerFile    = Join-Path $ProjectRoot "server.md"
$NtpServers    = @()

# UI state
$script:LogEntries     = [System.Collections.ArrayList]::new()
$script:LastSyncServer = "Not synced"
$script:LastSyncTime   = "Never"
$script:LastSyncLatency = "--"
$script:LastSyncOffset = "--"
$script:SyncStatus     = "Waiting"
$script:forceClose     = $false
$script:notifyIcon     = $null
$script:autoSyncTimer  = $null
$RankingsFile          = Join-Path $LogDir "rankings.json"
$script:ServerRankings = [System.Collections.ArrayList]::new()
$script:testBusy       = $false
$script:LastConfigureError = ""

function Load-ServerList {
    $servers = @()
    try {
        if (-not (Test-Path -LiteralPath $ServerFile)) {
            @('# NTPulse server list', '# Put one hostname or IP address per line.') | Set-Content -LiteralPath $ServerFile -Encoding UTF8
        }
        foreach ($line in @(Get-Content -LiteralPath $ServerFile -ErrorAction Stop)) {
            $server = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($server) -or $server.StartsWith('#')) { continue }
            if ($server.StartsWith('-')) { $server = $server.Substring(1).Trim() }
            if ($server -and $server -notmatch '\s' -and $servers -notcontains $server) {
                $servers += $server
            }
        }
    } catch {
        $servers = @()
    }
    return @($servers)
}

$NtpServers = @(Load-ServerList)

# ================================================================
# SERVER RANKING SYSTEM
# ================================================================
function Update-ServerRanking {
    param([string]$Server, [double]$LatencyMs, [bool]$Success)
    $existing = $null
    for ($i = 0; $i -lt $script:ServerRankings.Count; $i++) {
        if ($script:ServerRankings[$i].Server -eq $Server) { $existing = $script:ServerRankings[$i]; break }
    }
    if ($existing) {
        if ($Success) {
            $existing.Successes++
            $total = $existing.Successes + $existing.Failures
            $existing.Latency = (($existing.Latency * ($total - 1)) + $LatencyMs) / $total
        } else { $existing.Failures++ }
        $existing.LastTest = Get-Date -Format "HH:mm:ss"
    } else {
        $existing = [PSCustomObject]@{
            Server = $Server; Latency = if ($Success) { $LatencyMs } else { 9999 }
            Successes = if ($Success) { 1 } else { 0 }; Failures = if ($Success) { 0 } else { 1 }
            LastTest = Get-Date -Format "HH:mm:ss"; Score = 0
        }
        [void]$script:ServerRankings.Add($existing)
    }
    try {
        $s = [double]$existing.Successes
        $f = [double]$existing.Failures
        $t = $s + $f
        $lat = [double]$existing.Latency
        $rate = if ($t -gt 0) { $s / $t } else { 0.0 }
        if ($rate -lt 0.01) { $rate = 0.01 }
        $existing.Score = $lat / $rate
    } catch { $existing.Score = 99999 }
    Save-Rankings
}

function Get-BestServer {
    $ranked = @($script:ServerRankings | Where-Object { $_.Successes -gt 0 } | Sort-Object { $_.Score })
    if ($ranked.Count -gt 0) { return $ranked[0].Server }
    if ($NtpServers.Count -gt 0) { return $NtpServers[0] }
    return $null
}

function Get-TopServers {
    param([int]$Count = 5)
    $ranked = @($script:ServerRankings | Where-Object { $_.Successes -gt 0 } | Sort-Object { $_.Score })
    if ($ranked.Count -gt 0) { return ($ranked | Select-Object -First $Count | ForEach-Object { $_.Server }) }
    if ($NtpServers.Count -eq 0) { return @() }
    return $NtpServers[0..([Math]::Min($Count-1, $NtpServers.Count-1))]
}

function Save-Rankings {
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $data = @()
        for ($i = 0; $i -lt $script:ServerRankings.Count; $i++) {
            $r = $script:ServerRankings[$i]
            $data += "$($r.Server)|$($r.Latency)|$($r.Successes)|$($r.Failures)|$($r.LastTest)|$($r.Score)"
        }
        Set-Content -Path $RankingsFile -Value ($data -join "`n") -ErrorAction SilentlyContinue
    } catch {}
}

function Load-Rankings {
    try {
        if (Test-Path $RankingsFile) {
            $lines = Get-Content -Path $RankingsFile -ErrorAction SilentlyContinue
            $script:ServerRankings.Clear()
            foreach ($line in $lines) {
                $parts = $line -split "\|"
                if ($parts.Count -ge 6) {
                    [void]$script:ServerRankings.Add([PSCustomObject]@{
                        Server = $parts[0]; Latency = [double]$parts[1]
                        Successes = [int]$parts[2]; Failures = [int]$parts[3]
                        LastTest = $parts[4]; Score = [double]$parts[5]
                    })
                }
            }
        }
    } catch {}
}

# ================================================================
# NTP ENGINE
# ================================================================
function Read-NtpUInt32 {
    param([byte[]]$Data, [int]$Offset)
    [uint32](  ([uint32]$Data[$Offset] -shl 24) -bor ([uint32]$Data[$Offset+1] -shl 16) `
             -bor ([uint32]$Data[$Offset+2] -shl 8) -bor [uint32]($Data[$Offset+3]) )
}

function Get-NtpTime {
    param([string]$Server, [int]$TimeoutMs = 3000)
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Client.SendTimeout   = $TimeoutMs

        $request = New-Object byte[] 48
        $request[0] = 0x1B   # LI=0, VN=3, Mode=3 (client)

        $udp.Connect($Server, 123)
        $sendTime = [DateTime]::UtcNow
        [void]$udp.Send($request, 48)

        $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref]$remoteEP)
        $recvTime = [DateTime]::UtcNow

        if ($response.Length -lt 48) { return $null }
        if (($response[0] -band 0xC0) -eq 0xC0) { return $null }

        $epoch = [DateTime]::new(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $T0 = ($sendTime - $epoch).TotalSeconds
        $T3 = ($recvTime - $epoch).TotalSeconds

        $T1 = [double](Read-NtpUInt32 $response 32) + [double](Read-NtpUInt32 $response 36) / [Math]::Pow(2,32)
        $T2 = [double](Read-NtpUInt32 $response 40) + [double](Read-NtpUInt32 $response 44) / [Math]::Pow(2,32)

        $offset    = (($T1 - $T0) + ($T2 - $T3)) / 2
        $roundtrip = ($T3 - $T0) - ($T2 - $T1)

        return @{ Offset = $offset; RoundTrip = $roundtrip; ServerTime = $epoch.AddSeconds($T2) }
    } catch { return $null }
    finally { if ($udp) { try { $udp.Close(); $udp.Dispose() } catch {} } }
}

function Sync-TimeFromNtp {
    $best = @{ Server = $null; Offset = 0; RoundTrip = [double]::MaxValue }

    # Try ranked servers first (fast path)
    $topServers = Get-TopServers -Count 5
    foreach ($server in $topServers) {
        $r = Get-NtpTime -Server $server
        if ($r) {
            $ms = [Math]::Round($r.RoundTrip * 1000, 0)
            Update-ServerRanking -Server $server -LatencyMs $ms -Success $true
            if ($r.RoundTrip -lt $best.RoundTrip) {
                $best.Server = $server; $best.Offset = $r.Offset; $best.RoundTrip = $r.RoundTrip
            }
            if ($best.RoundTrip -lt 0.5) { break }
        } else {
            Update-ServerRanking -Server $server -LatencyMs 0 -Success $false
        }
    }

    # Fallback: try remaining servers if no good result yet
    if (-not $best.Server) {
        foreach ($server in $NtpServers) {
            if ($topServers -contains $server) { continue }
            $r = Get-NtpTime -Server $server
            if ($r) {
                $ms = [Math]::Round($r.RoundTrip * 1000, 0)
                Update-ServerRanking -Server $server -LatencyMs $ms -Success $true
                if ($r.RoundTrip -lt $best.RoundTrip) {
                    $best.Server = $server; $best.Offset = $r.Offset; $best.RoundTrip = $r.RoundTrip
                }
                if ($best.RoundTrip -lt 0.5) { break }
            } else {
                Update-ServerRanking -Server $server -LatencyMs 0 -Success $false
            }
        }
    }

    if ($best.Server) {
        $offsetMs  = [Math]::Round($best.Offset * 1000, 1)
        $rtMs      = [Math]::Round($best.RoundTrip * 1000, 0)
        $corrLocal = [DateTime]::UtcNow.AddSeconds($best.Offset).ToLocalTime()

        try {
            Set-Date -Date $corrLocal
            $script:LastSyncServer   = $best.Server
            $script:LastSyncTime     = Get-Date -Format "HH:mm:ss"
            $script:LastSyncLatency  = "$rtMs ms"
            $script:LastSyncOffset   = if ($best.Offset -ge 0) { "+${offsetMs}ms" } else { "${offsetMs}ms" }
            $script:SyncStatus       = "Synchronized"
            Add-SyncLog -Server $best.Server -Latency $rtMs -Offset $script:LastSyncOffset -Result "Success"
            return $true
        } catch {
            $script:SyncStatus = "Failed"
            Add-SyncLog -Server $best.Server -Latency $rtMs -Offset $script:LastSyncOffset -Result "Set failed"
            return $false
        }
    } else {
        $script:SyncStatus = "Failed"
        Add-SyncLog -Server "-" -Latency "-" -Offset "-" -Result "All servers failed"
        return $false
    }
}

function Test-AllNtpServers {
    foreach ($server in $NtpServers) {
        $r = Get-NtpTime -Server $server -TimeoutMs 2500
        if ($r) {
            Update-ServerRanking -Server $server -LatencyMs ([Math]::Round($r.RoundTrip * 1000, 0)) -Success $true
        } else {
            Update-ServerRanking -Server $server -LatencyMs 0 -Success $false
        }
    }
}

# ================================================================
# SERVICE MANAGEMENT
# ================================================================
function Get-TimeServiceStatus {
    try { (Get-Service w32time -ErrorAction Stop).Status.ToString() } catch { "Not Found" }
}

function Stop-WindowsTimeSync {
    try {
        Set-Service w32time -StartupType Disabled -ErrorAction Stop
        $service = Get-Service w32time -ErrorAction Stop
        if ($service.Status -ne "Stopped") {
            Stop-Service w32time -Force -ErrorAction Stop
        }
        return $true
    } catch {
        $script:LastConfigureError = "Windows Time disable failed: $($_.Exception.Message)"
        return $false
    }
}

function Start-WindowsTimeSync {
    try {
        Set-Service w32time -StartupType Automatic -ErrorAction Stop
        $service = Get-Service w32time -ErrorAction Stop
        if ($service.Status -ne "Running") { Start-Service w32time -ErrorAction Stop }
        return $true
    } catch {
        $script:LastConfigureError = "Windows Time restore failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-WindowsTimeDisabled {
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='w32time'" -ErrorAction Stop
        return ($svc.StartMode -eq "Disabled")
    } catch { return $false }
}

# ================================================================
# SETTINGS (Registry)
# ================================================================
function Get-Setting {
    param([string]$Name, $Default)
    try {
        $val = Get-ItemProperty -Path $RegPath -Name $Name -ErrorAction Stop
        return $val.$Name
    } catch { return $Default }
}

function Set-Setting {
    param([string]$Name, $Value)
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    Set-ItemProperty -Path $RegPath -Name $Name -Value $Value -ErrorAction SilentlyContinue
}

function Set-NtpulseMode {
    param([ValidateSet("Enable", "Disable")][string]$Mode)
    $script:LastConfigureError = ""
    if ($Mode -eq "Enable") {
        $serviceStopped = Stop-WindowsTimeSync
        $taskCreated = Setup-StartupTask
        if (-not ($serviceStopped -and $taskCreated)) { return $false }
        Set-Setting "NtpulseEnabled" 1
        return $true
    }

    Stop-AutoSyncTimer
    Remove-StartupTask
    $serviceRestored = Start-WindowsTimeSync
    Set-Setting "NtpulseEnabled" 0
    return $serviceRestored
}

function Test-NtpulseActive {
    return ((Get-Setting "NtpulseEnabled" 0) -eq 1 -and
        (Test-StartupTask) -and (Test-WindowsTimeDisabled))
}

# ================================================================
# LOGGING
# ================================================================
function Add-SyncLog {
    param([string]$Server, [string]$Latency, [string]$Offset, [string]$Result)
    $entry = [PSCustomObject]@{
        Time    = (Get-Date -Format "HH:mm:ss")
        Server  = $Server
        Latency = $Latency
        Offset  = $Offset
        Result  = $Result
    }
    [void]$script:LogEntries.Insert(0, $entry)
    if ($script:LogEntries.Count -gt 500) { $script:LogEntries.RemoveAt(500) }

    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Server | $Latency | $Offset | $Result" -ErrorAction SilentlyContinue
}

function Load-LogEntries {
    $script:LogEntries.Clear()
    try {
        if (-not (Test-Path -LiteralPath $LogFile)) { return }
        foreach ($line in @(Get-Content -LiteralPath $LogFile -Tail 500 -ErrorAction Stop)) {
            $parts = $line -split "\s*\|\s*", 5
            if ($parts.Count -ge 5) {
                [void]$script:LogEntries.Add([PSCustomObject]@{
                    Time = $parts[0]; Server = $parts[1]; Latency = $parts[2]
                    Offset = $parts[3]; Result = $parts[4]
                })
            }
        }
        $items = @($script:LogEntries)
        $script:LogEntries.Clear()
        foreach ($item in ($items | Sort-Object Time -Descending)) { [void]$script:LogEntries.Add($item) }
    } catch {}
}

function Invoke-UiPump {
    try { [System.Windows.Forms.Application]::DoEvents() } catch {}
}

function Invoke-SafeAction {
    param([scriptblock]$Action)
    try {
        & $Action
    } catch {
        Add-SyncLog -Server "-" -Latency "-" -Offset "-" -Result $_.Exception.Message
        $script:SyncStatus = "Failed"
        try { Update-DashboardDisplay } catch {}
    }
}

# ================================================================
# TASK SCHEDULER (Startup)
# ================================================================
function Test-StartupTask {
    schtasks /Query /TN $TaskName 2>$null | Out-Null
    $LASTEXITCODE -eq 0
}

function Setup-StartupTask {
    $p = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $powershell = Join-Path $PSHOME "powershell.exe"
        $arguments = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$p`" -Background"
        $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $script:LastConfigureError = "Startup task failed: $($_.Exception.Message)"
        return $false
    }
}

function Remove-StartupTask {
    schtasks /Delete /TN $TaskName /F 2>$null | Out-Null
}

# ================================================================
# AUTO-SYNC TIMER
# ================================================================
function Start-AutoSyncTimer {
    param([int]$IntervalMinutes = 30)
    Stop-AutoSyncTimer
    $script:autoSyncTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:autoSyncTimer.Interval = [TimeSpan]::FromMinutes($IntervalMinutes)
    $script:autoSyncTimer.Add_Tick({
        if (Test-NtpulseActive) {
            Sync-TimeFromNtp | Out-Null
            Update-DashboardDisplay
        } else {
            Stop-AutoSyncTimer
        }
    })
    $script:autoSyncTimer.Start()
}

function Stop-AutoSyncTimer {
    if ($script:autoSyncTimer) {
        $script:autoSyncTimer.Stop()
        $script:autoSyncTimer = $null
    }
}

# ================================================================
# AUTO-SYNC MODE (silent background)
# ================================================================
if ($AutoSync) {
    $result = if (Test-WindowsTimeDisabled -and ((Get-Setting "NtpulseEnabled" 0) -eq 1)) {
        Sync-TimeFromNtp
    } else {
        Add-SyncLog -Server "-" -Latency "-" -Offset "-" -Result "AutoSync blocked: Windows Time is enabled"
        $false
    }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $msg = if ($result) { "OK - $($script:LastSyncServer) $($script:LastSyncLatency)" } else { "FAILED" }
    Add-Content -Path $LogFile -Value "$ts | AutoSync | $msg" -ErrorAction SilentlyContinue
    exit
}

if ($Background) {
    try { (Get-Process -Id $PID).PriorityClass = "High" } catch {}
    while ((Get-Setting "NtpulseEnabled" 0) -eq 1) {
        if (Test-WindowsTimeDisabled) {
            Test-AllNtpServers
            Sync-TimeFromNtp | Out-Null
        } else {
            Add-SyncLog -Server "-" -Latency "-" -Offset "-" -Result "Background sync paused: Windows Time is enabled"
        }
        $minutes = [int](Get-Setting "SyncInterval" 30)
        Start-Sleep -Seconds ([Math]::Max(60, $minutes * 60))
    }
    exit
}

if ($Configure) {
    $ok = Set-NtpulseMode -Mode $Configure
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Configure | $Configure | $(if($ok){'OK'}else{'FAILED'})" -ErrorAction SilentlyContinue
    exit ([int](-not $ok))
}

# ================================================================
# ADMINISTRATOR STATE
# ================================================================
# NTPulse manages the Windows Time service and a high-priority startup task,
# so the interactive application must always run elevated.
$script:IsAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $script:IsAdministrator) {
    $p = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $argList = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$p`""
    if ($AutoSync) { $argList += " -AutoSync" }
    if ($Background) { $argList += " -Background" }
    if ($Configure) { $argList += " -Configure $Configure" }
    try {
        Start-Process powershell.exe $argList -Verb RunAs -WorkingDirectory $ProjectRoot | Out-Null
    } catch {
        Write-Error "NTPulse requires Administrator privileges. Please approve the UAC prompt."
    }
    exit
}

# ================================================================
# SYSTEM TRAY
# ================================================================
function New-TrayIcon {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $bmp = [System.Drawing.Bitmap]::new(32, 32)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(0, 168, 107))
    $g.FillEllipse($brush, 1, 1, 30, 30)
    $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 2.5)
    $pen.EndCap = $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($pen, 16, 16, 16, 7)
    $g.DrawLine($pen, 16, 16, 23, 14)
    $g.FillEllipse([System.Drawing.Brushes]::White, 14, 14, 4, 4)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    $hicon = $bmp.GetHicon()
    $icon  = [System.Drawing.Icon]::FromHandle($hicon)
    $bmp.Dispose()

    $ni = [System.Windows.Forms.NotifyIcon]::new()
    $ni.Icon      = $icon
    $ni.Text      = "NTPulse"
    $ni.Visible   = $true

    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $mSync = $menu.Items.Add("Sync Now")
    $mSync.Add_Click({
        $r = Sync-TimeFromNtp
        $ni.BalloonTipTitle = "NTPulse"
        $ni.BalloonTipText  = if ($r) { "Time synced - $($script:LastSyncLatency)" } else { "Sync failed" }
        $ni.ShowBalloonTip(3000)
    })
    $mOpen = $menu.Items.Add("Open NTPulse")
    $mOpen.Add_Click({ Invoke-SafeAction { Show-Window } })
    $menu.Items.Add("-")
    $mExit = $menu.Items.Add("Exit")
    $mExit.Add_Click({ Invoke-SafeAction { Exit-App } })

    $ni.ContextMenuStrip = $menu
    $ni.Add_DoubleClick({ Show-Window })
    $script:notifyIcon = $ni
}

function Show-Window {
    if ($window) {
        $window.Show()
        $window.WindowState = "Normal"
        $window.Activate()
    }
}

function Exit-App {
    $script:forceClose = $true
    Stop-AutoSyncTimer
    if ($script:notifyIcon) { $script:notifyIcon.Visible = $false; $script:notifyIcon.Dispose() }
    if ($window) { $window.Close() }
}

# ================================================================
# WPF ASSEMBLIES
# ================================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ================================================================
# WPF XAML
# ================================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NTPulse - Precision Time Synchronization"
        Width="920" Height="620" MinWidth="920" MinHeight="620"
        WindowStartupLocation="CenterScreen"
        Background="#1e1e1e"
        ResizeMode="CanResizeWithGrip">

    <Window.Resources>
        <!-- Nav Button Style -->
        <Style x:Key="NavBtn" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#999"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding" Value="18,10"/>
            <Setter Property="Margin" Value="10,2"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="B" Property="Background" Value="#1a2a1e"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Primary Button -->
        <Style x:Key="PrimaryBtn" TargetType="Button">
            <Setter Property="Background" Value="#00A86B"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="28,12"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#00c47d"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="#008f5c"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Background" Value="#333"/><Setter Property="Foreground" Value="#666"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Secondary Button -->
        <Style x:Key="SecondaryBtn" TargetType="Button">
            <Setter Property="Background" Value="#2a2a2a"/>
            <Setter Property="Foreground" Value="#ddd"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#444"/>
            <Setter Property="Padding" Value="20,10"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="6" BorderThickness="{TemplateBinding BorderThickness}" BorderBrush="{TemplateBinding BorderBrush}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#3a3a3a"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Background" Value="#222"/><Setter Property="Foreground" Value="#555"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Danger Button -->
        <Style x:Key="DangerBtn" TargetType="Button">
            <Setter Property="Background" Value="#2a2a2a"/>
            <Setter Property="Foreground" Value="#ff6b6b"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#444"/>
            <Setter Property="Padding" Value="20,10"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="6" BorderThickness="{TemplateBinding BorderThickness}" BorderBrush="{TemplateBinding BorderBrush}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#3a2020"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Dark combo box and dropdown items -->
        <Style x:Key="DarkComboItem" TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="#222222"/>
            <Setter Property="Background" Value="#eeeeee"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#1a3a2a"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#00A86B"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="DarkCombo" TargetType="ComboBox">
            <Setter Property="Foreground" Value="#222222"/>
            <Setter Property="Background" Value="#eeeeee"/>
            <Setter Property="BorderBrush" Value="#555555"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="ItemContainerStyle" Value="{StaticResource DarkComboItem}"/>
        </Style>

        <!-- Toggle Switch -->
        <Style x:Key="ToggleSwitch" TargetType="ToggleButton">
            <Setter Property="Width" Value="44"/>
            <Setter Property="Height" Value="22"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid Width="44" Height="22">
                            <Border x:Name="Track" CornerRadius="11" Background="#555">
                                <Ellipse x:Name="Knob" Width="18" Height="18" Fill="#999" Margin="2,0,0,0" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsChecked" Value="True">
                                    <Setter TargetName="Track" Property="Background" Value="#00A86B"/>
                                    <Setter TargetName="Knob" Property="Fill" Value="White"/>
                                    <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                                    <Setter TargetName="Knob" Property="Margin" Value="0,0,2,0"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="Track" Property="Opacity" Value="0.85"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="230"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- ==================== SIDEBAR ==================== -->
        <Border Grid.Column="0" Background="#0a1a10">
            <DockPanel>
                <TextBlock DockPanel.Dock="Bottom" Text="NTPulse v1.0" FontSize="10" Foreground="#3a5a3a" HorizontalAlignment="Center" Margin="0,0,0,14"/>
                <StackPanel DockPanel.Dock="Top" Margin="0,22,0,0">
                    <!-- Logo -->
                    <StackPanel Orientation="Horizontal" Margin="22,0,0,4">
                        <TextBlock Text="&#xE81C;" FontFamily="Segoe MDL2 Assets" FontSize="22" Foreground="#00A86B" VerticalAlignment="Center"/>
                        <TextBlock Text="NTPulse" FontSize="19" FontWeight="Bold" Foreground="White" Margin="10,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock Text="Precision Time Synchronization" FontSize="10.5" Foreground="#4a6a4a" Margin="56,0,0,20"/>
                    <Separator Background="#1a2a1e" Height="1" Margin="16,0,16,10"/>

                    <!-- Nav: Dashboard -->
                    <Button x:Name="NavDashboard" AutomationProperties.Name="Dashboard" Style="{StaticResource NavBtn}" Tag="Dashboard">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE80F;" FontFamily="Segoe MDL2 Assets" FontSize="15" Width="24" VerticalAlignment="Center"/>
                            <TextBlock Text="Dashboard" FontSize="13" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Button>
                    <!-- Nav: Synchronization -->
                    <Button x:Name="NavSync" AutomationProperties.Name="Synchronization" Style="{StaticResource NavBtn}" Tag="Sync">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE895;" FontFamily="Segoe MDL2 Assets" FontSize="15" Width="24" VerticalAlignment="Center"/>
                            <TextBlock Text="Synchronization" FontSize="13" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Button>
                    <!-- Nav: Servers -->
                    <Button x:Name="NavServers" AutomationProperties.Name="Servers" Style="{StaticResource NavBtn}" Tag="Servers">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE774;" FontFamily="Segoe MDL2 Assets" FontSize="15" Width="24" VerticalAlignment="Center"/>
                            <TextBlock Text="Servers" FontSize="13" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Button>
                    <!-- Nav: Logs -->
                    <Button x:Name="NavLogs" AutomationProperties.Name="Logs" Style="{StaticResource NavBtn}" Tag="Logs">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE8A8;" FontFamily="Segoe MDL2 Assets" FontSize="15" Width="24" VerticalAlignment="Center"/>
                            <TextBlock Text="Logs" FontSize="13" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Button>
                    <!-- Nav: Settings -->
                    <Button x:Name="NavSettings" AutomationProperties.Name="Settings" Style="{StaticResource NavBtn}" Tag="Settings">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" FontSize="15" Width="24" VerticalAlignment="Center"/>
                            <TextBlock Text="Settings" FontSize="13" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Button>
                </StackPanel>
            </DockPanel>
        </Border>

        <!-- ==================== CONTENT AREA ==================== -->
        <Border Grid.Column="1" Background="#1e1e1e">
            <Grid Margin="30,24,30,24">

                <!-- ==================== PAGE: DASHBOARD ==================== -->
                <Grid x:Name="PageDashboard">
                    <ScrollViewer VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <TextBlock Text="Dashboard" FontSize="22" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,20"/>

                            <!-- Status Card -->
                            <Border x:Name="StatusCard" Background="#0a2a15" CornerRadius="10" Padding="24" Margin="0,0,0,20">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock x:Name="StatusIcon" Text="&#xE81C;" FontFamily="Segoe MDL2 Assets" FontSize="36" Foreground="#00A86B" VerticalAlignment="Center" Margin="0,0,18,0"/>
                                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                                        <TextBlock x:Name="StatusTitle" Text="Waiting for sync" FontSize="20" FontWeight="SemiBold" Foreground="White"/>
                                        <TextBlock x:Name="StatusSubtitle" Text="Click Sync Now or enable automatic synchronization" FontSize="12" Foreground="#7aaa7a" Margin="0,4,0,0"/>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <!-- Info Cards -->
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/><RowDefinition Height="12"/><RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>

                                <Border Grid.Column="0" Grid.Row="0" Background="#2a2a2a" CornerRadius="8" Padding="20,16">
                                    <StackPanel>
                                        <TextBlock Text="CURRENT TIME" FontSize="10" Foreground="#777" FontWeight="SemiBold"/>
                                        <TextBlock x:Name="DashClock" Text="00:00:00" FontSize="30" FontWeight="Bold" Foreground="White" Margin="0,6,0,0" FontFamily="Consolas"/>
                                    </StackPanel>
                                </Border>
                                <Border Grid.Column="2" Grid.Row="0" Background="#2a2a2a" CornerRadius="8" Padding="20,16">
                                    <StackPanel>
                                        <TextBlock Text="LAST SYNC" FontSize="10" Foreground="#777" FontWeight="SemiBold"/>
                                        <TextBlock x:Name="DashLastSync" Text="Never" FontSize="30" FontWeight="Bold" Foreground="White" Margin="0,6,0,0" FontFamily="Consolas"/>
                                    </StackPanel>
                                </Border>
                                <Border Grid.Column="0" Grid.Row="2" Background="#2a2a2a" CornerRadius="8" Padding="20,16">
                                    <StackPanel>
                                        <TextBlock Text="NTP SERVER" FontSize="10" Foreground="#777" FontWeight="SemiBold"/>
                                        <TextBlock x:Name="DashServer" Text="--" FontSize="16" FontWeight="SemiBold" Foreground="White" Margin="0,6,0,0"/>
                                    </StackPanel>
                                </Border>
                                <Border Grid.Column="2" Grid.Row="2" Background="#2a2a2a" CornerRadius="8" Padding="20,16">
                                    <StackPanel>
                                        <TextBlock Text="LATENCY" FontSize="10" Foreground="#777" FontWeight="SemiBold"/>
                                        <TextBlock x:Name="DashLatency" Text="--" FontSize="16" FontWeight="SemiBold" Foreground="White" Margin="0,6,0,0"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- Offset -->
                            <Border Background="#2a2a2a" CornerRadius="8" Padding="20,16" Margin="0,12,0,0">
                                <Grid>
                                    <TextBlock Text="CLOCK OFFSET" FontSize="10" Foreground="#777" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="DashOffset" Text="--" FontSize="16" FontWeight="SemiBold" Foreground="White" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                                </Grid>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>

                <!-- ==================== PAGE: SYNCHRONIZATION ==================== -->
                <Grid x:Name="PageSync" Visibility="Collapsed">
                    <ScrollViewer VerticalScrollBarVisibility="Disabled">
                        <StackPanel>
                            <TextBlock Text="Synchronization" FontSize="22" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,20"/>

                            <!-- Service Status -->
                            <Border Background="#2a2a2a" CornerRadius="8" Padding="20" Margin="0,0,0,16">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel>
                                        <TextBlock Text="WINDOWS TIME SERVICE" FontSize="10" Foreground="#777" FontWeight="SemiBold"/>
                                        <TextBlock x:Name="ServiceStatusText" Text="Checking..." FontSize="16" FontWeight="SemiBold" Foreground="White" Margin="0,4,0,0"/>
                                    </StackPanel>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal">
                                        <TextBlock x:Name="ServiceStatusIcon" Text="&#xE730;" FontFamily="Segoe MDL2 Assets" FontSize="20" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <!-- Buttons -->
                            <TextBlock Text="Actions" FontSize="14" FontWeight="SemiBold" Foreground="#aaa" Margin="0,8,0,12"/>

                            <Button x:Name="BtnSyncNow" AutomationProperties.Name="Sync Time Now" Style="{StaticResource PrimaryBtn}" Margin="0,0,0,10" HorizontalAlignment="Left">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="&#xE895;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,10,0" VerticalAlignment="Center"/>
                                    <TextBlock Text="Sync Time Now" FontSize="13" VerticalAlignment="Center"/>
                                </StackPanel>
                            </Button>

                            <!-- NTPulse background mode -->
                            <Border Background="#0a2a15" CornerRadius="8" Padding="20" Margin="0,8,0,16">
                                <StackPanel>
                                    <TextBlock Text="NTPulse Background Mode" FontSize="14" FontWeight="SemiBold" Foreground="White"/>
                                    <TextBlock x:Name="NtpulseModeText" Text="Windows Time is currently in control" Foreground="#9aaa9a" FontSize="12" Margin="0,4,0,14" TextWrapping="Wrap"/>
                                    <StackPanel Orientation="Horizontal">
                                        <Button x:Name="BtnEnableNtpulse" AutomationProperties.Name="Enable NTPulse Sync" Style="{StaticResource PrimaryBtn}" Margin="0,0,10,0">
                                            <TextBlock Text="Enable NTPulse Sync" FontSize="12"/>
                                        </Button>
                                        <Button x:Name="BtnDisableNtpulse" AutomationProperties.Name="Restore Windows Time" Style="{StaticResource DangerBtn}">
                                            <TextBlock Text="Restore Windows Time" FontSize="12"/>
                                        </Button>
                                    </StackPanel>
                                    <TextBlock Text="NTPulse disables Windows Time, starts with Windows at high priority, and synchronizes in the background." Foreground="#718a78" FontSize="11" Margin="0,12,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </Border>

                            <Border Background="#2a2a2a" CornerRadius="8" Padding="20,16" Margin="0,0,0,10">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel VerticalAlignment="Center">
                                        <TextBlock Text="Background Sync Interval" FontWeight="SemiBold" Foreground="White" FontSize="14"/>
                                        <TextBlock x:Name="SyncIntervalStatusText" Text="Every 30 minutes" Foreground="#888" FontSize="12" Margin="0,3,0,0"/>
                                    </StackPanel>
                                    <ComboBox x:Name="SyncIntervalCombo" Grid.Column="1" Style="{StaticResource DarkCombo}" Width="150" Background="#eeeeee" Foreground="#222222" BorderBrush="#555" BorderThickness="1" Padding="10,6" FontSize="13" VerticalAlignment="Center"/>
                                </Grid>
                            </Border>

                        </StackPanel>
                    </ScrollViewer>
                </Grid>

                <!-- ==================== PAGE: SERVERS ==================== -->
                <Grid x:Name="PageServers" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0" Text="NTP Servers" FontSize="22" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,16"/>

                    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,14">
                        <Button x:Name="BtnTestAll" AutomationProperties.Name="Test All Servers" Style="{StaticResource PrimaryBtn}">
                            <StackPanel Orientation="Horizontal">
                                <TextBlock Text="&#xE945;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,10,0" VerticalAlignment="Center"/>
                                <TextBlock Text="Test All Servers" FontSize="13" VerticalAlignment="Center"/>
                            </StackPanel>
                        </Button>
                    </StackPanel>

                    <Border Grid.Row="2" Background="#2a2a2a" CornerRadius="8" Padding="4">
                        <ScrollViewer VerticalScrollBarVisibility="Auto">
                            <StackPanel x:Name="ServerItems"/>
                        </ScrollViewer>
                    </Border>
                </Grid>

                <!-- ==================== PAGE: LOGS ==================== -->
                <Grid x:Name="PageLogs" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0" Text="Synchronization Log" FontSize="22" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,16"/>

                    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,14">
                        <Button x:Name="BtnClearLog" Style="{StaticResource SecondaryBtn}">
                            <TextBlock Text="Clear Log" FontSize="12"/>
                        </Button>
                    </StackPanel>

                    <Border Grid.Row="2" Background="#2a2a2a" CornerRadius="8" Padding="4">
                        <ListView x:Name="LogListView" Background="Transparent" BorderThickness="0" Foreground="#ccc" FontSize="12"
                                  FontFamily="Consolas" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                            <ListView.View>
                                <GridView>
                                    <GridViewColumn Header="Time" Width="75" DisplayMemberBinding="{Binding Time}"/>
                                    <GridViewColumn Header="Server" Width="180" DisplayMemberBinding="{Binding Server}"/>
                                    <GridViewColumn Header="Latency" Width="75" DisplayMemberBinding="{Binding Latency}"/>
                                    <GridViewColumn Header="Offset" Width="80" DisplayMemberBinding="{Binding Offset}"/>
                                    <GridViewColumn Header="Result" Width="90" DisplayMemberBinding="{Binding Result}"/>
                                </GridView>
                            </ListView.View>
                        </ListView>
                    </Border>
                </Grid>

                <!-- ==================== PAGE: SETTINGS ==================== -->
                <Grid x:Name="PageSettings" Visibility="Collapsed">
                    <ScrollViewer VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <TextBlock Text="Settings" FontSize="22" FontWeight="SemiBold" Foreground="White" Margin="0,0,0,20"/>

                            <!-- About -->
                            <Border Background="#2a2a2a" CornerRadius="8" Padding="20" Margin="0,0,0,10">
                                <StackPanel>
                                    <TextBlock Text="About NTPulse" FontWeight="SemiBold" Foreground="White" FontSize="14"/>
                                    <TextBlock Text="Version 1.0.0" Foreground="#888" FontSize="12" Margin="0,4,0,0"/>
                                    <TextBlock Text="Precision Time Synchronization Engine" Foreground="#666" FontSize="12" Margin="0,2,0,0"/>
                                    <TextBlock Text="Lightweight NTP client for Windows with automatic synchronization support." Foreground="#666" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                            </Border>

                            <!-- Log File -->
                            <Border Background="#2a2a2a" CornerRadius="8" Padding="20" Margin="0,0,0,10">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel VerticalAlignment="Center">
                                        <TextBlock Text="Log Location" FontWeight="SemiBold" Foreground="White" FontSize="14"/>
                                        <TextBlock x:Name="LogPathText" Text="" Foreground="#888" FontSize="11" Margin="0,3,0,0" FontFamily="Consolas"/>
                                    </StackPanel>
                                </Grid>
                            </Border>

                            <!-- NTP Servers Count -->
                            <Border Background="#2a2a2a" CornerRadius="8" Padding="20" Margin="0,0,0,10">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <StackPanel>
                                        <TextBlock Text="Configured Servers" FontWeight="SemiBold" Foreground="White" FontSize="14"/>
                                        <TextBlock Text="NTP servers from Iran, Asia, and international pools" Foreground="#888" FontSize="12" Margin="0,3,0,0"/>
                                    </StackPanel>
                                    <TextBlock Grid.Column="1" Text="$($NtpServers.Count)" FontSize="20" FontWeight="Bold" Foreground="#00A86B" VerticalAlignment="Center"/>
                                </Grid>
                            </Border>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>

            </Grid>
        </Border>
    </Grid>
</Window>
"@

# ================================================================
# WINDOW SETUP
# ================================================================
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

function Convert-ToUiTitleCase {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $result = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToTitleCase($Text.ToLower())
    return $result.Replace("Ntpulse", "NTPulse").Replace("Ntp", "NTP")
}

function Apply-UiTitleCase {
    param([System.Windows.DependencyObject]$Node)
    if ($Node -is [System.Windows.Controls.TextBlock] -and $Node.FontFamily.Source -ne "Segoe MDL2 Assets") {
        $Node.Text = Convert-ToUiTitleCase $Node.Text
    } elseif ($Node -is [System.Windows.Controls.ContentControl] -and $Node.Content -is [string]) {
        $Node.Content = Convert-ToUiTitleCase $Node.Content
    }
    $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Node)
    for ($i = 0; $i -lt $count; $i++) {
        Apply-UiTitleCase ([System.Windows.Media.VisualTreeHelper]::GetChild($Node, $i))
    }
}
Apply-UiTitleCase $window

$window.Dispatcher.Add_UnhandledException({
    param($sender, $eventArgs)
    try {
        $message = if ($eventArgs.Exception) { $eventArgs.Exception.ToString() } else { "Unknown WPF exception" }
        Add-SyncLog -Server "-" -Latency "-" -Offset "-" -Result "WPF: $message"
    } catch {}
    $eventArgs.Handled = $true
})

# Find named elements
$el = @{}
@("PageDashboard","PageSync","PageServers","PageLogs","PageSettings",
  "StatusCard","StatusIcon","StatusTitle","StatusSubtitle",
  "DashClock","DashLastSync","DashServer","DashLatency","DashOffset",
  "ServiceStatusText","ServiceStatusIcon",
  "BtnSyncNow",
  "BtnTestAll","ServerItems",
  "NtpulseModeText","BtnEnableNtpulse","BtnDisableNtpulse","SyncIntervalCombo","SyncIntervalStatusText",
  "LogListView","BtnClearLog","LogPathText",
  "NavDashboard","NavSync","NavServers","NavLogs","NavSettings"
) | ForEach-Object { $el[$_] = $window.FindName($_) }

# ================================================================
# NAVIGATION
# ================================================================
$script:NavPages = @{
    "Dashboard"  = $el.PageDashboard
    "Sync"       = $el.PageSync
    "Servers"    = $el.PageServers
    "Logs"       = $el.PageLogs
    "Settings"   = $el.PageSettings
}
$script:NavBtnList = @($el.NavDashboard, $el.NavSync, $el.NavServers, $el.NavLogs, $el.NavSettings)
$script:NavColors = @{ Active = "#1a3a2a"; Normal = "Transparent" }
$script:NavFg    = @{ Active = "#ffffff"; Normal = "#999999" }

function Show-Page {
    param([string]$Name)
    if (-not $script:NavPages.ContainsKey($Name)) { return }
    foreach ($page in @($script:NavPages.Values)) {
        if ($page) { $page.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    $activePage = $script:NavPages[$Name]
    $activePage.Visibility = [System.Windows.Visibility]::Visible
    [System.Windows.Controls.Panel]::SetZIndex($activePage, 10)

    foreach ($btn in @($script:NavBtnList)) {
        if (-not $btn) { continue }
        if ($btn.Tag -eq $Name) {
            $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:NavColors.Active)
            $btn.Foreground = [System.Windows.Media.Brushes]::White
        } else {
            $btn.Background = [System.Windows.Media.Brushes]::Transparent
            $btn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:NavFg.Normal)
        }
    }
}

# ================================================================
# DASHBOARD UPDATE
# ================================================================
function Update-DashboardDisplay {
    if (-not $window -or $window.IsLoaded -ne $true) { return }

    $el.DashClock.Text     = Get-Date -Format "HH:mm:ss"
    $el.DashLastSync.Text  = $script:LastSyncTime
    $el.DashServer.Text    = $script:LastSyncServer
    $el.DashLatency.Text   = $script:LastSyncLatency
    $el.DashOffset.Text    = $script:LastSyncOffset

    $modeActive = Test-NtpulseActive
    switch ($script:SyncStatus) {
        "Synchronized" {
            $el.StatusTitle.Text       = "Synchronized"
            $el.StatusSubtitle.Text    = if ($modeActive) { "NTPulse is managing system time" } else { "System clock is accurate" }
            $el.StatusIcon.Text        = [char]0xE73E
            $el.StatusIcon.Foreground  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00A86B")
            $el.StatusCard.Background  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0a2a15")
        }
        "Failed" {
            $el.StatusTitle.Text       = "Synchronization Failed"
            $el.StatusSubtitle.Text    = "Check network connectivity and try again"
            $el.StatusIcon.Text        = [char]0xE783
            $el.StatusIcon.Foreground  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ef5350")
            $el.StatusCard.Background  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2a0a0a")
        }
        default {
            $el.StatusTitle.Text       = if ($modeActive) { "NTPulse Active" } else { "Windows Time Active" }
            $el.StatusSubtitle.Text    = if ($modeActive) { "Background synchronization is enabled" } else { "Enable NTPulse from Synchronization" }
            $el.StatusIcon.Text        = [char]0xE81C
            $el.StatusIcon.Foreground  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888")
            $el.StatusCard.Background  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2a2a2a")
        }
    }

    # Service status
    $st = Get-TimeServiceStatus
    $el.ServiceStatusText.Text = if ($modeActive) { "NTPulse controls time (Windows Time disabled)" } else { "Windows Time: $st" }
    if ($modeActive) {
        $el.ServiceStatusIcon.Text       = [char]0xE73E
        $el.ServiceStatusIcon.Foreground = [System.Windows.Media.Brushes]::LightGreen
    } elseif ($st -eq "Stopped") {
        $el.ServiceStatusIcon.Text       = [char]0xE711
        $el.ServiceStatusIcon.Foreground = [System.Windows.Media.Brushes]::LightCoral
    } else {
        $el.ServiceStatusIcon.Text       = [char]0xE783
        $el.ServiceStatusIcon.Foreground = [System.Windows.Media.Brushes]::Gray
    }
}

function Update-LogListView {
    $el.LogListView.Items.Clear()
    foreach ($entry in $script:LogEntries) {
        [void]$el.LogListView.Items.Add($entry)
    }
}

# ================================================================
# SERVER LIST
# ================================================================
function Build-ServerList {
    $el.ServerItems.Children.Clear()
    foreach ($server in $NtpServers) {
        $border = [System.Windows.Controls.Border]::new()
        $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#222")
        $border.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $border.Padding = [System.Windows.Thickness]::new(14,10,14,10)
        $border.Margin = [System.Windows.Thickness]::new(4,3,4,3)

        $grid = [System.Windows.Controls.Grid]::new()
        $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(1,[System.Windows.GridUnitType]::Star)
        $c2 = [System.Windows.Controls.ColumnDefinition]::new(); $c2.Width = [System.Windows.GridLength]::new(80)
        $c3 = [System.Windows.Controls.ColumnDefinition]::new(); $c3.Width = [System.Windows.GridLength]::new(32)
        $grid.ColumnDefinitions.Add($c1)
        $grid.ColumnDefinitions.Add($c2)
        $grid.ColumnDefinitions.Add($c3)

        $tbName = [System.Windows.Controls.TextBlock]::new()
        $tbName.Text = $server; $tbName.Foreground = [System.Windows.Media.Brushes]::White; $tbName.FontSize = 12
        $tbName.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($tbName, 0)

        $tbLat = [System.Windows.Controls.TextBlock]::new()
        $tbLat.Text = "Not tested"; $tbLat.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#666")
        $tbLat.FontSize = 11; $tbLat.HorizontalAlignment = "Right"; $tbLat.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($tbLat, 1)

        $tbStatus = [System.Windows.Controls.TextBlock]::new()
        $tbStatus.Text = ""; $tbStatus.FontSize = 14; $tbStatus.HorizontalAlignment = "Center"; $tbStatus.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($tbStatus, 2)

        $grid.Children.Add($tbName)
        $grid.Children.Add($tbLat)
        $grid.Children.Add($tbStatus)
        $border.Child = $grid
        $border.Tag = [PSCustomObject]@{ NameEl = $tbName; LatEl = $tbLat; StatusEl = $tbStatus; Server = $server }
        [void]$el.ServerItems.Children.Add($border)
    }
    Update-ServerListRankings
}

function Update-ServerListRankings {
    foreach ($child in $el.ServerItems.Children) {
        $refs = $child.Tag
        $found = $null
        for ($i = 0; $i -lt $script:ServerRankings.Count; $i++) {
            if ($script:ServerRankings[$i].Server -eq $refs.Server) { $found = $script:ServerRankings[$i]; break }
        }
        if ($found -and $found.Successes -gt 0) {
            $ms = [Math]::Round($found.Latency, 0)
            $refs.LatEl.Text = "$ms ms"
            $refs.LatEl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00A86B")
            $rate = [Math]::Round(($found.Successes / ($found.Successes + $found.Failures)) * 100, 0)
            $refs.StatusEl.Text = "${rate}%"
            $refs.StatusEl.Foreground = if ($rate -ge 80) {
                [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00A86B")
            } elseif ($rate -ge 50) {
                [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ffb74d")
            } else {
                [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ef5350")
            }
        }
    }
}

# ================================================================
# EVENT HANDLERS
# ================================================================

# Navigation
$el.NavDashboard.Add_Click({ Invoke-SafeAction { Show-Page "Dashboard" } })
$el.NavSync.Add_Click({ Invoke-SafeAction { Show-Page "Sync" } })
$el.NavServers.Add_Click({ Invoke-SafeAction { Show-Page "Servers" } })
$el.NavLogs.Add_Click({ Invoke-SafeAction { Show-Page "Logs" } })
$el.NavSettings.Add_Click({ Invoke-SafeAction { Show-Page "Settings" } })

# Sync Now
$el.BtnSyncNow.Add_Click({
    Invoke-SafeAction {
        $el.BtnSyncNow.IsEnabled = $false
        try {
            $script:SyncStatus = "Syncing..."
            Update-DashboardDisplay
            Invoke-UiPump

            $ok = Sync-TimeFromNtp
            Update-DashboardDisplay
            Update-LogListView
        } finally {
            $el.BtnSyncNow.IsEnabled = $true
        }
    }
})

# Test All Servers
$el.BtnTestAll.Add_Click({
    Invoke-SafeAction {
        if ($script:testBusy) { return }
        $script:testBusy = $true
        $el.BtnTestAll.IsEnabled = $false
        try {
            foreach ($child in $el.ServerItems.Children) {
                $refs = $child.Tag
                $refs.LatEl.Text = "Testing..."
                $refs.LatEl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#666")
                $refs.StatusEl.Text = ""
            }
            Invoke-UiPump
            foreach ($child in $el.ServerItems.Children) {
                $refs = $child.Tag
                try {
                    $udp = New-Object System.Net.Sockets.UdpClient
                    $udp.Client.ReceiveTimeout = 2500
                    $udp.Client.SendTimeout = 2500
                    $req = New-Object byte[] 48; $req[0] = 0x1B
                    $udp.Connect($refs.Server, 123)
                    $t0 = [DateTime]::UtcNow
                    [void]$udp.Send($req, 48)
                    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                    $resp = $udp.Receive([ref]$ep)
                    $t1 = [DateTime]::UtcNow
                    $udp.Close(); $udp.Dispose()
                    $ok = $resp.Length -ge 48 -and (($resp[0] -band 0xC0) -ne 0xC0)
                    $ms = [Math]::Round(($t1 - $t0).TotalMilliseconds, 0)
                    if ($ok) {
                        $refs.LatEl.Text = "$ms ms"
                        $refs.LatEl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00A86B")
                        $refs.StatusEl.Text = [char]0x2713
                        $refs.StatusEl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00A86B")
                        Update-ServerRanking -Server $refs.Server -LatencyMs $ms -Success $true
                    } else { throw "bad response" }
                } catch {
                    $refs.LatEl.Text = "Timeout"
                    $refs.LatEl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ef5350")
                    $refs.StatusEl.Text = [char]0x2717
                    $refs.StatusEl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#ef5350")
                    Update-ServerRanking -Server $refs.Server -LatencyMs 0 -Success $false
                }
                Invoke-UiPump
            }
        } finally {
            $el.BtnTestAll.IsEnabled = $true
            $script:testBusy = $false
        }
    }
})

# Enable NTPulse background mode
$el.BtnEnableNtpulse.Add_Click({
    Invoke-SafeAction {
        $el.BtnEnableNtpulse.IsEnabled = $false
        $el.NtpulseModeText.Text = "Enabling NTPulse..."
        $ok = if ($script:IsAdministrator) {
            Set-NtpulseMode -Mode Enable
        } else {
            $p = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
            $child = Start-Process powershell.exe "-ExecutionPolicy Bypass -NoProfile -File `"$p`" -Configure Enable" -Verb RunAs -PassThru
            $child.WaitForExit()
            ($child.ExitCode -eq 0)
        }
        if ($ok) {
            Start-AutoSyncTimer -IntervalMinutes ([int](Get-Setting "SyncInterval" 30))
            $el.NtpulseModeText.Text = "NTPulse is active and Windows Time is disabled."
        } else {
            $detail = if ($script:LastConfigureError) { $script:LastConfigureError } else { "Check Administrator permissions." }
            $el.NtpulseModeText.Text = "Enable failed: $detail"
            Add-SyncLog -Server "-" -Latency "-" -Offset "-" -Result $detail
        }
        $el.BtnEnableNtpulse.IsEnabled = $true
        Update-DashboardDisplay
    }
})

# Restore Windows default mode
$el.BtnDisableNtpulse.Add_Click({
    Invoke-SafeAction {
        $el.BtnDisableNtpulse.IsEnabled = $false
        $el.NtpulseModeText.Text = "Restoring Windows Time..."
        $ok = if ($script:IsAdministrator) {
            Set-NtpulseMode -Mode Disable
        } else {
            $p = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
            $child = Start-Process powershell.exe "-ExecutionPolicy Bypass -NoProfile -File `"$p`" -Configure Disable" -Verb RunAs -PassThru
            $child.WaitForExit()
            ($child.ExitCode -eq 0)
        }
        $el.NtpulseModeText.Text = if ($ok) { "Windows Time and Windows startup defaults restored." } else { "Restore failed. Check Administrator permissions." }
        $el.BtnDisableNtpulse.IsEnabled = $true
        Update-DashboardDisplay
    }
})

# Background sync interval
$el.SyncIntervalCombo.Add_SelectionChanged({
    Invoke-SafeAction {
        if ($el.SyncIntervalCombo.SelectedItem -and $el.SyncIntervalCombo.SelectedItem.Tag) {
            $mins = [int]$el.SyncIntervalCombo.SelectedItem.Tag
            Set-Setting "SyncInterval" $mins
            $el.SyncIntervalStatusText.Text = "Every $mins minutes"
            if ((Get-Setting "NtpulseEnabled" 0) -eq 1) { Start-AutoSyncTimer -IntervalMinutes $mins }
        }
    }
})

# Clear Log
$el.BtnClearLog.Add_Click({
    Invoke-SafeAction {
        $script:LogEntries.Clear()
        Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue
        Update-LogListView
    }
})

# Window close -> minimize to tray
$window.Add_Closing({
    param($s, $e)
    if (-not $script:forceClose) {
        $e.Cancel = $true
        $window.Hide()
    }
})

# ================================================================
# HELPER: Next Sync Display
# ================================================================
# ================================================================
# INITIALIZATION
# ================================================================
# Load settings
$syncInterval = Get-Setting "SyncInterval" 30

# Load saved server rankings
Load-Rankings
Load-LogEntries

# Build server list
Build-ServerList

# Setup interval combo
$intervals = @(
    @{Text="15 minutes";  Value=15},
    @{Text="30 minutes";  Value=30},
    @{Text="1 hour";      Value=60},
    @{Text="3 hours";     Value=180},
    @{Text="6 hours";     Value=360},
    @{Text="12 hours";    Value=720},
    @{Text="Daily";       Value=1440}
)
foreach ($iv in $intervals) {
    $item = [System.Windows.Controls.ComboBoxItem]::new()
    $item.Content = $iv.Text
    $item.Tag     = $iv.Value
    $item.Foreground = [System.Windows.Media.Brushes]::White
    $item.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#3a3a3a")
    [void]$el.SyncIntervalCombo.Items.Add($item)
    if ($iv.Value -eq $syncInterval) { $el.SyncIntervalCombo.SelectedItem = $item }
}
if (-not $el.SyncIntervalCombo.SelectedItem -and $el.SyncIntervalCombo.Items.Count -gt 1) {
    $el.SyncIntervalCombo.SelectedIndex = 1
}
$el.SyncIntervalStatusText.Text = "Every $syncInterval minutes"

# NTPulse background mode
$ntpulseOn = Test-NtpulseActive
$el.NtpulseModeText.Text = if ($ntpulseOn) { "NTPulse is active and Windows Time is disabled." } else { "Windows Time is currently in control." }
if ($ntpulseOn) {
    Start-AutoSyncTimer -IntervalMinutes $syncInterval
}

# Log path
$el.LogPathText.Text = $LogFile
Update-LogListView

# Create tray icon
New-TrayIcon

# Dashboard clock timer
$clockTimer = New-Object System.Windows.Threading.DispatcherTimer
$clockTimer.Interval = [TimeSpan]::FromSeconds(1)
$clockTimer.Add_Tick({ Invoke-SafeAction { Update-DashboardDisplay } })
$clockTimer.Start()

# Periodic server re-test timer (every 5 min)
$retestTimer = New-Object System.Windows.Threading.DispatcherTimer
$retestTimer.Interval = [TimeSpan]::FromMinutes(5)
$retestTimer.Add_Tick({
    Invoke-SafeAction {
        if ($script:testBusy) { return }
        $script:testBusy = $true
        try {
            # Test top 3 ranked + 1 random unrated
            $testList = @()
            $top = Get-TopServers -Count 3
            $testList += $top
            $rated = @($script:ServerRankings | ForEach-Object { $_.Server })
            $unrated = @($NtpServers | Where-Object { $rated -notcontains $_ })
            if ($unrated.Count -gt 0) { $testList += ($unrated | Get-Random) }
            foreach ($s in $testList) {
                try {
                    $udp = New-Object System.Net.Sockets.UdpClient
                    $udp.Client.ReceiveTimeout = 2500
                    $udp.Connect($s, 123)
                    $req = New-Object byte[] 48; $req[0] = 0x1B
                    $t0 = [DateTime]::UtcNow
                    [void]$udp.Send($req, 48)
                    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                    $resp = $udp.Receive([ref]$ep)
                    $t1 = [DateTime]::UtcNow
                    $udp.Close(); $udp.Dispose()
                    $ok = $resp.Length -ge 48 -and (($resp[0] -band 0xC0) -ne 0xC0)
                    $ms = [Math]::Round(($t1 - $t0).TotalMilliseconds, 0)
                    if ($ok) { Update-ServerRanking -Server $s -LatencyMs $ms -Success $true }
                    else { Update-ServerRanking -Server $s -LatencyMs 0 -Success $false }
                } catch { Update-ServerRanking -Server $s -LatencyMs 0 -Success $false }
            }
            Update-ServerListRankings
        } finally {
            $script:testBusy = $false
        }
    }
})
$retestTimer.Start()

# Keep startup fast. Background timers and manual test refresh rankings after the UI is visible.
Update-ServerListRankings

# Show Dashboard
Show-Page "Dashboard"
Update-DashboardDisplay

# ================================================================
# SHOW WINDOW
# ================================================================
try {
    [void]$window.ShowDialog()
} finally {
    $clockTimer.Stop()
    $clockTimer.Dispose()
    $retestTimer.Stop(); $retestTimer.Dispose()
    Stop-AutoSyncTimer
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
    }
}
