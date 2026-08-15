# =============================================================================
# dsh-tray.ps1 - DeepSeek Harness (dsh web) Windows-native tray controller
#
# Version: 1.2.0
#
# The tray is the switch + watchdog for the Windows-native dsh web instance
# (default port 3090). It starts / restarts / stops dsh, watches health, and
# auto-recovers crashes. All knobs live in dsh-tray.json next to this script.
# Menu text follows the system UI language (zh / en); override in config.
#
# Process model:
#   dsh-tray.lnk (Startup) -> wscript dsh-tray-launch.vbs
#     -> powershell -WindowStyle Hidden -> this script
#       -> Start-Process cmd.exe /c dsh-win-start.cmd
#            -> dsh web --port 3090   (DSH_HOME=C:\Users\catti\.dsh)
#
# Watchdog policy (since 1.1.0):
#   - the tray manages the *lifecycle*, not liveness:
#     a live-but-slow process is never killed; only a crash (process gone)
#     schedules a restart, with 5s -> 30s backoff.
#   - Stop only taskkills a process positively identified as dsh web
#     (node/bun runtime + command line referencing dsh).
#
# There is intentionally NO Exit menu item: the tray runs forever and the
# watchdog owns dsh's lifecycle. To fully stop: menu Stop dsh, then kill the
# tray process (taskkill /PID <tray-pid> /F).
# =============================================================================

$script:Version = "1.2.0"

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- script state -----------------------------------------------------------
$script:TrayRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:LogDir     = Join-Path $script:TrayRoot "logs"
$script:TrayLog    = Join-Path $script:LogDir "dsh-tray.log"
$script:ManagedByTray    = $false    # did THIS tray start the healthy service?
$script:StartedAt        = $null
$script:LastHealthCheck  = [DateTime]::MinValue
$script:RestartAfter     = [DateTime]::MinValue
$script:HealthFailures   = 0
$script:RestartCount     = 0    # consecutive crash-restarts (drives restart backoff)
$script:AutoRestartEnabled = $true
$script:Exiting          = $false
$script:Context          = $null
$script:Timer            = $null
$script:NotifyIcon       = $null
$script:StatusItem       = $null
$script:WhaleIcon        = $null    # DeepSeek whale icon (assets\dsh-whale.png)
$script:LastState        = $null    # last status state, for transition balloons
$script:SawUnhealthy     = $false   # have we ever observed an unhealthy state?
$script:SuppressAutostartEvents = $false   # guard: setting Checked at build time must not toggle the lnk
$script:MouseTypeDefined = $false   # Add-Type guard for the P/Invoke mouse helper
$script:Config           = $null
$script:Port             = 3090
$script:HealthUrl        = $null
$script:DashboardUrl     = $null
$script:StartScript      = $null
$script:DshLogFile       = $null
$script:HealthIntervalSeconds = 10
$script:StartupGraceSeconds   = 120
$script:RestartDelaySeconds   = 5
$script:Lang             = "en"
$script:L                = @{}    # localized UI strings

New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

# --- helpers ----------------------------------------------------------------
function Write-TrayLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $script:TrayLog -Value $line -Encoding UTF8
}

function Show-Balloon {
    param(
        [string]$Title,
        [string]$Text,
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info
    )
    if (-not $script:Config -or -not $script:Config.notifications) { return }
    if (-not $script:NotifyIcon) { return }
    try {
        $script:NotifyIcon.BalloonTipTitle = $Title
        $script:NotifyIcon.BalloonTipText  = $Text
        $script:NotifyIcon.BalloonTipIcon  = $Icon
        $script:NotifyIcon.ShowBalloonTip(3000)
    }
    catch {
        Write-TrayLog "WARN balloon failed: $($_.Exception.Message)"
    }
}

function Set-TrayStatus {
    param(
        [string]$Text,
        [ValidateSet("Healthy", "Warning", "Error", "Stopped")]
        [string]$State = "Warning"
    )

    if ($script:StatusItem) {
        $script:StatusItem.Text = $Text
    }
    if (-not $script:NotifyIcon) {
        return
    }

    $tooltip = "dsh :$($script:Port) - $Text"
    if ($tooltip.Length -gt 63) {
        $tooltip = $tooltip.Substring(0, 63)
    }
    $script:NotifyIcon.Text = $tooltip

    switch ($State) {
        "Healthy" { $script:NotifyIcon.Icon = if ($script:WhaleIcon) { $script:WhaleIcon } else { [System.Drawing.SystemIcons]::Information } }
        "Error"   { $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Error }
        "Stopped" { $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Application }
        default   { $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Warning }
    }

    # Balloon only on state *transitions*, never on every tick.
    if ($State -ne $script:LastState) {
        if ($State -eq "Error") { $script:SawUnhealthy = $true }
        if ($State -eq "Healthy" -and $script:SawUnhealthy) {
            Show-Balloon -Title $script:L.BalloonRecovered -Text $Text
        }
        $script:LastState = $State
    }
}

function Test-DshHealth {
    $request = $null
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($script:HealthUrl)
        $request.Method = "GET"
        $request.Timeout = 2000
        $request.ReadWriteTimeout = 2000
        $request.Proxy = $null
        $response = $request.GetResponse()
        return ([int]$response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
    finally {
        if ($response) {
            $response.Close()
        }
    }
}

function Find-DshProcessId {
    # Find the PID listening on our port (the dsh web server).
    $conn = Get-NetTCPConnection -LocalPort $script:Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) {
        return $conn.OwningProcess
    }
    return $null
}

function Test-DshProcessIdentity {
    # Only kill a process we can positively attribute to dsh web. The PID is
    # looked up by port number, so without this check a foreign process
    # squatting on :$Port would be taskkilled /T /F.
    param([int]$ProcessId)

    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if (-not $proc) {
        return $false
    }

    $name = $proc.Name.ToLowerInvariant()
    $cmdLine = [string]$proc.CommandLine

    # dsh web runs as a Node CLI (npm global shim -> node <cli>\bin.js web);
    # require both a known runtime and a command line that references dsh.
    if ($name -notin @("node.exe", "node", "bun.exe", "bun", "dsh.exe", "dsh")) {
        return $false
    }
    if ($cmdLine -notmatch "dsh") {
        return $false
    }
    return $true
}

# --- config & i18n ----------------------------------------------------------
function Read-Config {
    $cfg = @{}
    # Defaults are generic; a dsh-tray.json next to the script overrides them.
    $defaults = @{
        port                 = 3090
        startscript          = (Join-Path $script:TrayRoot "start-dsh.cmd")
        dshlogfile           = (Join-Path $script:TrayRoot "logs\dsh-web.log")
        healthintervalseconds = 10
        startupgraceseconds  = 120
        restartdelayseconds  = 5
        language             = "auto"
        notifications        = $true
        whaleicon            = $true
    }
    $defaults.GetEnumerator() | ForEach-Object { $cfg[$_.Key] = $_.Value }

    $cfgPath = Join-Path $script:TrayRoot "dsh-tray.json"
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $user = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
            $user.PSObject.Properties | ForEach-Object {
                $key = $_.Name.ToLowerInvariant()
                if ($defaults.ContainsKey($key)) {
                    $cfg[$key] = $_.Value
                }
                else {
                    Write-TrayLog "WARN unknown config key: $($_.Name)"
                }
            }
        }
        catch {
            Write-TrayLog "WARN failed to parse dsh-tray.json: $($_.Exception.Message)"
        }
    }

    # URL fields are derived from the port unless explicitly set.
    $cfg['healthurl']    = "http://127.0.0.1:$($cfg['port'])/"
    $cfg['dashboardurl'] = "http://127.0.0.1:$($cfg['port'])/"
    return $cfg
}

function Resolve-Language {
    param([string]$Lang)
    if ($Lang -eq 'zh') { return 'zh' }
    if ($Lang -eq 'en') { return 'en' }
    $ui = Get-UICulture
    if ($ui.Name -like 'zh*') { return 'zh' }
    return 'en'
}

function Init-I18n {
    $lang = Resolve-Language $script:Config.language
    $script:Lang = $lang

    $script:Strings = @{
        zh = @{
            StatusHealthy       = "Healthy (:PORT)"
            StatusStarting      = "Starting..."
            StatusWarming       = "Warming up (Ns grace)"
            StatusUnhealthy     = "Unhealthy (n/3)"
            StatusStopped       = "Stopped"
            StatusRestartPending = "Restart pending"
            StatusScriptMissing = "Start script missing"
            StatusStartFailed   = "Start failed; retry pending"
            MenuDashboard       = "打开面板"
            MenuNewChat         = "开启新对话"
            MenuRestart         = "重启 dsh"
            MenuStop            = "停止 dsh"
            MenuCopyLog         = "复制最近日志"
            MenuAutostart       = "开机自启"
            BalloonStarted      = "dsh 已启动"
            BalloonStopped      = "dsh 已停止"
            BalloonRestarting   = "dsh 正在重启"
            BalloonRecovered    = "dsh 已恢复"
            BalloonUnhealthy    = "dsh 异常"
            BalloonCopied       = "日志已复制"
            BalloonNewChat      = "新对话已就绪"
            BalloonNewChatHint = "新对话已开启"
            BalloonError        = "出错"
        }
        en = @{
            StatusHealthy       = "Healthy (:PORT)"
            StatusStarting      = "Starting..."
            StatusWarming       = "Warming up (Ns grace)"
            StatusUnhealthy     = "Unhealthy (n/3)"
            StatusStopped       = "Stopped"
            StatusRestartPending = "Restart pending"
            StatusScriptMissing = "Start script missing"
            StatusStartFailed   = "Start failed; retry pending"
            MenuDashboard       = "Open Dashboard"
            MenuNewChat         = "New Conversation"
            MenuRestart         = "Restart dsh"
            MenuStop            = "Stop dsh"
            MenuCopyLog         = "Copy Recent Log"
            MenuAutostart       = "Start with Windows"
            BalloonStarted      = "dsh started"
            BalloonStopped      = "dsh stopped"
            BalloonRestarting   = "dsh restarting"
            BalloonRecovered    = "dsh recovered"
            BalloonUnhealthy    = "dsh unhealthy"
            BalloonCopied       = "log copied"
            BalloonNewChat      = "new conversation ready"
            BalloonNewChatHint = "new conversation opened"
            BalloonError        = "error"
        }
    }
    $script:L = $script:Strings[$lang]
}

# --- dsh lifecycle -----------------------------------------------------------
function Start-DshProxy {
    if (-not $script:AutoRestartEnabled -or $script:Exiting) {
        return
    }

    if (Test-DshHealth) {
        Set-TrayStatus -Text ($script:L.StatusHealthy -replace ':PORT', ":$($script:Port)") -State Healthy
        return
    }

    if (-not (Test-Path -LiteralPath $script:StartScript)) {
        Write-TrayLog "ERROR missing start script: $($script:StartScript)"
        Set-TrayStatus -Text $script:L.StatusScriptMissing -State Error
        return
    }

    try {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$($script:StartScript)`" $($script:Port)" -WindowStyle Hidden | Out-Null
        $script:ManagedByTray = $true
        $script:StartedAt = Get-Date
        $script:RestartAfter = [DateTime]::MinValue
        $script:HealthFailures = 0
        $script:RestartCount = 0
        Write-TrayLog "Started dsh web (Windows-native) port=$($script:Port)"
        Set-TrayStatus -Text $script:L.StatusStarting -State Warning
        Show-Balloon -Title $script:L.BalloonStarted -Text "dsh :$($script:Port)"
    }
    catch {
        $script:ManagedByTray = $false
        $script:RestartAfter = (Get-Date).AddSeconds($script:RestartDelaySeconds)
        Write-TrayLog "ERROR start failed: $($_.Exception.Message)"
        Set-TrayStatus -Text $script:L.StatusStartFailed -State Error
        Show-Balloon -Title $script:L.BalloonError -Text $_.Exception.Message -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Stop-DshProxy {
    param([string]$Reason = "requested")

    Write-TrayLog "Stopping dsh web reason=$Reason"
    $procId = Find-DshProcessId
    if ($procId) {
        if (-not (Test-DshProcessIdentity -ProcessId $procId)) {
            Write-TrayLog "WARN port $($script:Port) owned by PID $procId is not identified as dsh web; skipping kill"
        }
        else {
            try {
                & taskkill.exe /PID $procId /T /F 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-TrayLog "WARN taskkill exit $LASTEXITCODE for PID $procId"
                }
            }
            catch {
                Write-TrayLog "WARN stop error: $($_.Exception.Message)"
            }
        }
    }
    else {
        Write-TrayLog "No listener found on port $($script:Port); nothing to stop"
    }

    $script:ManagedByTray = $false
    $script:StartedAt = $null
    $script:HealthFailures = 0
    $script:RestartCount = 0
}

function Restart-DshProxy {
    $script:AutoRestartEnabled = $true

    if ($script:ManagedByTray -or (Test-DshHealth)) {
        Stop-DshProxy -Reason "tray restart"
    }

    $script:RestartAfter = (Get-Date).AddSeconds(1)
    Set-TrayStatus -Text $script:L.StatusRestartPending -State Warning
    Show-Balloon -Title $script:L.BalloonRestarting -Text "dsh :$($script:Port)"
}

# --- monitor loop -------------------------------------------------------------
function Invoke-MonitorTick {
    $now = Get-Date

    # Defensive: guard against a cleared/null LastHealthCheck so the tick
    # never hits `DateTime - $null` (PS 5.1 op_Subtraction crash).
    $lastCheck = $script:LastHealthCheck
    if (-not $lastCheck) {
        $lastCheck = [DateTime]::MinValue
    }
    if (($now - $lastCheck).TotalSeconds -lt $script:HealthIntervalSeconds) {
        # Fast path (between health polls): only fire a pending restart once it
        # is due. No HTTP probe here -- Start-DshProxy re-checks health itself,
        # so a down service never blocks the UI thread for the 2s probe timeout.
        if (
            $script:AutoRestartEnabled -and
            $script:RestartAfter -ne [DateTime]::MinValue -and
            $now -ge $script:RestartAfter
        ) {
            Start-DshProxy
        }
        return
    }

    $script:LastHealthCheck = $now
    $healthy = Test-DshHealth

    if ($healthy) {
        $script:HealthFailures = 0
        Set-TrayStatus -Text ($script:L.StatusHealthy -replace ':PORT', ":$($script:Port)") -State Healthy
        return
    }

    if (-not $script:AutoRestartEnabled) {
        Set-TrayStatus -Text $script:L.StatusStopped -State Stopped
        return
    }

    if ($script:ManagedByTray -and $script:StartedAt) {
        $ageSeconds = ($now - $script:StartedAt).TotalSeconds

        if ($ageSeconds -lt $script:StartupGraceSeconds) {
            # During grace we only wait for a *live* process; a crash during
            # boot should not wait out the whole grace period.
            if (-not (Find-DshProcessId)) {
                Write-TrayLog "dsh process disappeared during startup grace; scheduling restart"
                $script:RestartCount++
                $backoff = $script:RestartDelaySeconds * [Math]::Min($script:RestartCount, 6)
                $script:RestartAfter = $now.AddSeconds($backoff)
            }
            $remaining = [Math]::Max(0, [Math]::Ceiling($script:StartupGraceSeconds - $ageSeconds))
            Set-TrayStatus -Text ($script:L.StatusWarming -replace 'Ns', "${remaining}s") -State Warning
            return
        }

        # Watchdog policy: the tray manages the *lifecycle*, not liveness.
        #  - Process still listening: never kill it just for being slow to
        #    serve / (a slow cordis boot used to be killed every ~3 min).
        #  - Process gone: that is a crash; schedule a bounded restart with
        #    backoff so a broken install is not hammered every few seconds.
        if (Find-DshProcessId) {
            $script:HealthFailures++
            $display = [Math]::Min($script:HealthFailures, 3)
            Set-TrayStatus -Text ($script:L.StatusUnhealthy -replace 'n/3', "$display/3") -State Error
            if ($display -eq 1) {
                Show-Balloon -Title $script:L.BalloonUnhealthy -Text "dsh :$($script:Port)" -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
            }
            return
        }

        Write-TrayLog "dsh process no longer listening after startup grace; scheduling restart"
        $script:HealthFailures = 0
        $script:RestartCount++
        $backoff = $script:RestartDelaySeconds * [Math]::Min($script:RestartCount, 6)
        $script:RestartAfter = $now.AddSeconds($backoff)
        return
    }

    if ($script:RestartAfter -eq [DateTime]::MinValue -or $now -ge $script:RestartAfter) {
        Start-DshProxy
    }
}

# --- tray actions --------------------------------------------------------------
function Invoke-MouseClick {
    param([int]$X, [int]$Y)
    if (-not $script:MouseTypeDefined) {
        Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class DshTrayMouse{ [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y); [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,UIntPtr e); public static void Click(int x,int y){ SetCursorPos(x,y); System.Threading.Thread.Sleep(100); mouse_event(0x0002,0,0,0,UIntPtr.Zero); mouse_event(0x0004,0,0,0,UIntPtr.Zero);} }' -ErrorAction SilentlyContinue
        $script:MouseTypeDefined = $true
    }
    [DshTrayMouse]::Click($X, $Y)
    return $true
}

function Invoke-UiaElementActivate {
    # Activate a UI element: semantic patterns first (no cursor movement),
    # a real mouse click at the element center only as a last resort.
    param($Element)
    try {
        $p = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $p.Invoke()
        return $true
    }
    catch {
    }
    try {
        $p = $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $p.Select()
        return $true
    }
    catch {
    }
    $r = $Element.Current.BoundingRectangle
    if ($r.Width -gt 0 -and $r.Height -gt 0) {
        return (Invoke-MouseClick -X ([int]($r.X + $r.Width / 2)) -Y ([int]($r.Y + $r.Height / 2)))
    }
    return $false
}

function Invoke-GuiNewConversation {
    # Drive the harness GUI's own "new conversation" flow through UI Automation.
    # The GUI owns session creation, view switching and its localStorage
    # persistence - no RPC hacks needed.
    #
    # Deterministic logic (the GUI button alone proved flaky):
    #   1. An untitled entry already selected  -> GUI is on a fresh conversation
    #   2. An untitled entry exists            -> select it
    #   3. None exists -> click "New conversation", wait for the new entry,
    #      then select it (InvokePattern first; real click after focusing the
    #      window as a fallback).
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes

    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $win = $null
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
        if ($w.Current.ClassName -eq 'Chrome_WidgetWin_1' -and $w.Current.Name -match 'DeepSeek Harness') {
            $win = $w
            break
        }
    }
    if (-not $win) {
        return $false
    }

    $itemCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::TreeItem)
    function Get-UntitledItems {
        $found = @()
        foreach ($t in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCond)) {
            if ($t.Current.Name -match '新会话|^New (session|conversation)') {
                $found += $t
            }
        }
        return $found
    }

    $untitled = @(Get-UntitledItems)

    # Case 1 + 2: reuse an existing empty conversation if possible.
    foreach ($t in $untitled) {
        try {
            $p = $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($p.Current.IsSelected) {
                try { $win.SetFocus() } catch { }
                return $true
            }
        }
        catch {
        }
    }
    if ($untitled.Count -gt 0) {
        if (Invoke-UiaElementActivate $untitled[0]) {
            try { $win.SetFocus() } catch { }
            return $true
        }
    }

    # Case 3: create a new empty conversation via the GUI button.
    $btnCond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)),
        (New-Object System.Windows.Automation.OrCondition(
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, '新建会话')),
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'New conversation')))))
    $btn = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
    if (-not $btn) {
        return $false
    }

    $beforeCount = $untitled.Count
    $clicked = Invoke-UiaElementActivate $btn
    if (-not $clicked) {
        return $false
    }

    $item = $null
    for ($attempt = 0; $attempt -lt 2 -and -not $item; $attempt++) {
        for ($i = 0; $i -lt 10 -and -not $item; $i++) {
            Start-Sleep -Milliseconds 400
            $now = @(Get-UntitledItems)
            if ($now.Count -gt $beforeCount) {
                $item = $now[$now.Count - 1]
            }
        }
        if (-not $item -and $attempt -eq 0) {
            # InvokePattern sometimes does not register; retry with a real click
            # after focusing the window so coordinates are safe.
            try { $win.SetFocus() } catch { }
            $r = $btn.Current.BoundingRectangle
            if ($r.Width -gt 0 -and $r.Height -gt 0) {
                [void](Invoke-MouseClick -X ([int]($r.X + $r.Width / 2)) -Y ([int]($r.Y + $r.Height / 2)))
            }
        }
    }
    if (-not $item) {
        return $false
    }
    if (Invoke-UiaElementActivate $item) {
        try { $win.SetFocus() } catch { }
        return $true
    }
    return $false
}

function Start-NewConversation {
    # Preferred: drive the GUI's own "new conversation" flow (creation +
    # selection + localStorage all handled by the GUI itself). Fallback:
    # create a session through the harness RPC and open a new browser tab.
    if (Invoke-GuiNewConversation) {
        Write-TrayLog "New conversation opened via GUI"
        Show-Balloon -Title $script:L.BalloonNewChat -Text $script:L.BalloonNewChatHint
        return
    }
    Write-TrayLog "WARN GUI automation unavailable; falling back to RPC + browser tab"

    $workspaceId = $null
    $wsRpcId = "tray-ws-" + ([guid]::NewGuid().ToString("N").Substring(0, 12))
    $wsBody = @{
        type    = "client-request"
        rpcId   = $wsRpcId
        method  = "workspace.list"
        payload = @{}
    } | ConvertTo-Json -Compress

    try {
        $wsResp = Invoke-RestMethod -Uri "http://127.0.0.1:$($script:Port)/api/workspace.list" `
            -Method Post -ContentType "application/json" -Body $wsBody -TimeoutSec 10
        if ($wsResp.result.ok -and $wsResp.result.value.items -and $wsResp.result.value.items.Count -gt 0) {
            $workspaceId = [string]$wsResp.result.value.items[0].workspaceId
        }
    }
    catch {
        Write-TrayLog "WARN workspace.list: $($_.Exception.Message)"
    }

    $payload = @{}
    if ($workspaceId) {
        $payload.workspaceId = $workspaceId
    }
    $rpcId = "tray-" + ([guid]::NewGuid().ToString("N").Substring(0, 12))
    $body = @{
        type    = "client-request"
        rpcId   = $rpcId
        method  = "session.create"
        payload = $payload
    } | ConvertTo-Json -Compress

    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$($script:Port)/api/session.create" `
            -Method Post -ContentType "application/json" -Body $body -TimeoutSec 10
        if ($resp.result.ok) {
            $sessionId = $resp.result.value.sessionId
            Write-TrayLog "New conversation created: $sessionId workspace=$workspaceId"
            # Unique fragment forces the browser to open a NEW tab.
            $openUrl = $script:DashboardUrl.TrimEnd("/") + "#tray-new-" + ([guid]::NewGuid().ToString("N").Substring(0, 8))
            Start-Process $openUrl
            Show-Balloon -Title $script:L.BalloonNewChat -Text $script:L.BalloonNewChatHint
        }
        else {
            Write-TrayLog "WARN session.create rejected: $($resp.result.error | ConvertTo-Json -Compress)"
            Show-Balloon -Title $script:L.BalloonError -Text "session.create failed" -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
            Start-Process $script:DashboardUrl
        }
    }
    catch {
        Write-TrayLog "ERROR session.create: $($_.Exception.Message)"
        Show-Balloon -Title $script:L.BalloonError -Text $_.Exception.Message -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        Start-Process $script:DashboardUrl
    }
}

function Copy-RecentLog {
    # Copy the tail of the dsh web log (fall back to the tray log) to the clipboard.
    $source = $script:DshLogFile
    if (-not (Test-Path -LiteralPath $source)) {
        $source = $script:TrayLog
    }
    if (-not (Test-Path -LiteralPath $source)) {
        Show-Balloon -Title $script:L.BalloonError -Text "no log file found" -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        return
    }
    try {
        $tail = Get-Content -LiteralPath $source -Tail 25
        $text = "=== $source ===" + [Environment]::NewLine + ($tail -join [Environment]::NewLine)
        Set-Clipboard -Value $text
        Write-TrayLog "Copied $($tail.Count) log lines from $source to clipboard"
        Show-Balloon -Title $script:L.BalloonCopied -Text "$($tail.Count) lines"
    }
    catch {
        Write-TrayLog "WARN copy log failed: $($_.Exception.Message)"
        Show-Balloon -Title $script:L.BalloonError -Text $_.Exception.Message -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Test-Autostart {
    return (Test-Path -LiteralPath $script:LnkPath)
}

function Set-Autostart {
    param([bool]$Enable)

    $launchVbs = Join-Path $script:TrayRoot "dsh-tray-launch.vbs"
    if ($Enable -and -not (Test-Path -LiteralPath $launchVbs)) {
        Write-TrayLog "WARN missing launcher: $launchVbs"
        Show-Balloon -Title $script:L.BalloonError -Text "dsh-tray-launch.vbs missing" -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        return
    }

    try {
        $ws = New-Object -ComObject WScript.Shell
        if ($Enable) {
            $lnk = $ws.CreateShortcut($script:LnkPath)
            $lnk.TargetPath = Join-Path $env:SystemRoot "System32\wscript.exe"
            $lnk.Arguments = "//nologo `"$launchVbs`""
            $lnk.WorkingDirectory = $script:TrayRoot
            $lnk.Description = "DeepSeek Harness (dsh) web tray controller"
            $lnk.Save()
            Write-TrayLog "Autostart enabled: $($script:LnkPath)"
        }
        else {
            if (Test-Path -LiteralPath $script:LnkPath) {
                Remove-Item -LiteralPath $script:LnkPath -Force
                Write-TrayLog "Autostart disabled: $($script:LnkPath)"
            }
        }
    }
    catch {
        Write-TrayLog "WARN autostart toggle failed: $($_.Exception.Message)"
        Show-Balloon -Title $script:L.BalloonError -Text $_.Exception.Message -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
    }
}

# --- startup -------------------------------------------------------------------
$script:Config = Read-Config
$script:Port = [int]$script:Config.port
$script:HealthUrl = [string]$script:Config.healthurl
$script:DashboardUrl = [string]$script:Config.dashboardurl
$script:StartScript = [string]$script:Config.startscript
$script:DshLogFile = [string]$script:Config.dshlogfile
$script:HealthIntervalSeconds = [int]$script:Config.healthintervalseconds
$script:StartupGraceSeconds = [int]$script:Config.startupgraceseconds
$script:RestartDelaySeconds = [int]$script:Config.restartdelayseconds
Init-I18n

$startupDir = [Environment]::GetFolderPath("Startup")
$script:LnkPath = Join-Path $startupDir "dsh-tray.lnk"

$createdNew = $false
$mutexName = "Local\DshTray-$($script:Port)"
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    Write-TrayLog "Tray application starting (Windows-native dsh) port=$($script:Port) v$($script:Version) lang=$($script:Lang)"

    $script:Context = New-Object System.Windows.Forms.ApplicationContext
    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon

    # Load the DeepSeek whale icon (PNG -> HICON via GDI+); fall back to the
    # generic application icon if the asset is missing or disabled.
    if ($script:Config.whaleicon) {
        $whalePath = Join-Path $script:TrayRoot "assets\dsh-whale.png"
        if (Test-Path -LiteralPath $whalePath) {
            try {
                $bmp = [System.Drawing.Bitmap]::FromFile($whalePath)
                $script:WhaleIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
                $bmp.Dispose()
            }
            catch {
                $script:WhaleIcon = $null
            }
        }
    }
    $script:NotifyIcon.Icon = if ($script:WhaleIcon) { $script:WhaleIcon } else { [System.Drawing.SystemIcons]::Application }
    $script:NotifyIcon.Text = "dsh :$($script:Port)"

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:StatusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $script:StatusItem.Text = $script:L.StatusStarting
    $script:StatusItem.Enabled = $false
    [void]$menu.Items.Add($script:StatusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $dashboardItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $dashboardItem.Text = $script:L.MenuDashboard
    $dashboardItem.add_Click({ Start-Process $script:DashboardUrl })
    [void]$menu.Items.Add($dashboardItem)

    $newChatItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $newChatItem.Text = $script:L.MenuNewChat
    $newChatItem.add_Click({ Start-NewConversation })
    [void]$menu.Items.Add($newChatItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $restartItem.Text = $script:L.MenuRestart
    $restartItem.add_Click({ Restart-DshProxy })
    [void]$menu.Items.Add($restartItem)

    $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $stopItem.Text = $script:L.MenuStop
    $stopItem.add_Click({
        $script:AutoRestartEnabled = $false
        Stop-DshProxy -Reason "tray stop"
        Set-TrayStatus -Text $script:L.StatusStopped -State Stopped
        Show-Balloon -Title $script:L.BalloonStopped -Text "dsh :$($script:Port)"
    })
    [void]$menu.Items.Add($stopItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $copyLogItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $copyLogItem.Text = $script:L.MenuCopyLog
    $copyLogItem.add_Click({ Copy-RecentLog })
    [void]$menu.Items.Add($copyLogItem)

    $autoItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $autoItem.Text = $script:L.MenuAutostart
    $autoItem.CheckOnClick = $true
    $script:SuppressAutostartEvents = $true
    $autoItem.Checked = (Test-Autostart)
    $script:SuppressAutostartEvents = $false
    $autoItem.add_CheckedChanged({
        if (-not $script:SuppressAutostartEvents) {
            Set-Autostart -Enable $autoItem.Checked
        }
    })
    [void]$menu.Items.Add($autoItem)

    $script:NotifyIcon.ContextMenuStrip = $menu
    $script:NotifyIcon.add_DoubleClick({ Start-Process $script:DashboardUrl })
    $script:NotifyIcon.Visible = $true

    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 1000
    $script:Timer.add_Tick({ Invoke-MonitorTick })
    $script:Timer.Start()

    if (Test-DshHealth) {
        Set-TrayStatus -Text ($script:L.StatusHealthy -replace ':PORT', ":$($script:Port)") -State Healthy
    }
    else {
        Start-DshProxy
    }

    [System.Windows.Forms.Application]::Run($script:Context)
}
catch {
    Write-TrayLog "FATAL $($_.Exception.ToString())"
    if ($script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    throw
}
finally {
    if ($createdNew) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
        }
    }
    $mutex.Dispose()
}
