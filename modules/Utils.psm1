# ============================================================================
# WinGateKeeper - Utility Functions
# ============================================================================

function Write-Banner {
    $banner = @"


       WinGateKeeper
  Windows Server Access Control & User Isolation
  -----------------------------------------------
"@
    Write-Host $banner -ForegroundColor Cyan
}

function Write-MenuHeader {
    param([string]$Title)
    $line = "=" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan
}

function Write-MenuOption {
    param(
        [string]$Key,
        [string]$Label,
        [string]$Status = ""
    )
    $keyText = "  [$Key]"
    Write-Host $keyText -ForegroundColor Yellow -NoNewline
    Write-Host " $Label" -NoNewline
    if (-not $Status) {
        Write-Host ""
    }
    elseif ($Status -eq "OK") {
        Write-Host " [OK]" -ForegroundColor Green
    }
    elseif ($Status -eq "FAIL") {
        Write-Host " [NOT CONFIGURED]" -ForegroundColor Red
    }
    elseif ($Status -match "^\d+ user") {
        Write-Host " [$Status]" -ForegroundColor Cyan
    }
    else {
        Write-Host " [$Status]" -ForegroundColor DarkYellow
    }
}

function Write-Step {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Type = "Info"
    )
    $icon = switch ($Type) {
        "Info"    { "[*]" }
        "Success" { "[+]" }
        "Warning" { "[!]" }
        "Error"   { "[-]" }
    }
    $color = switch ($Type) {
        "Info"    { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }
    Write-Host " $icon " -ForegroundColor $color -NoNewline
    Write-Host $Message
}

function Write-Separator {
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray
}

function Read-MenuChoice {
    param([string]$Prompt = "Select an option")
    Write-Host ""
    Write-Host "  $Prompt" -ForegroundColor White -NoNewline
    Write-Host ": " -NoNewline
    return (Read-Host).Trim().ToUpper()
}

function Test-InteractiveConsole {
    <# Returns $true if we have a real console with RawUI support #>
    try {
        $null = $Host.UI.RawUI.KeyAvailable
        $null = [Console]::CursorVisible
        return $true
    }
    catch { return $false }
}

function Write-MenuItemLine {
    <# Renders a single menu item line. Used by Select-MenuOption for both
       initial render and partial updates (no-flicker). #>
    param(
        [hashtable]$Item,
        [bool]$IsSelected,
        [int]$MenuWidth = 60
    )
    $key = $Item.Key
    $label = $Item.Label
    $status = $Item.Status

    # Build status text
    $statusText = ""
    if ($status) {
        $statusText = switch ($status) {
            "OK"   { " [OK]" }
            "FAIL" { " [NOT CONFIGURED]" }
            default { " [$status]" }
        }
    }

    if ($IsSelected) {
        Write-Host "  > " -ForegroundColor White -NoNewline
        Write-Host "[$key]" -ForegroundColor Black -BackgroundColor Yellow -NoNewline
        Write-Host " $label" -ForegroundColor White -BackgroundColor DarkCyan -NoNewline
        if ($statusText) {
            $statusColor = switch -Regex ($status) {
                "^OK"       { "Green" }
                "^FAIL"     { "Red" }
                "^\d+ user" { "Cyan" }
                default     { "DarkYellow" }
            }
            Write-Host $statusText -ForegroundColor $statusColor -BackgroundColor DarkCyan -NoNewline
        }
        # Pad to fixed width with background color, then reset
        $contentLen = 4 + $key.Length + 2 + $label.Length + $statusText.Length
        $pad = [Math]::Max(1, $MenuWidth - $contentLen)
        Write-Host (" " * $pad) -BackgroundColor DarkCyan
    }
    else {
        Write-Host "    " -NoNewline
        Write-Host "[$key]" -ForegroundColor Yellow -NoNewline
        Write-Host " $label" -NoNewline
        if ($statusText) {
            $statusColor = switch -Regex ($status) {
                "^OK"       { "Green" }
                "^FAIL"     { "Red" }
                "^\d+ user" { "Cyan" }
                default     { "DarkYellow" }
            }
            Write-Host $statusText -ForegroundColor $statusColor -NoNewline
        }
        # Pad to clear any leftover characters from selected state
        $contentLen = 4 + $key.Length + 2 + $label.Length + $statusText.Length
        $pad = [Math]::Max(1, $MenuWidth - $contentLen)
        Write-Host (" " * $pad)
    }
}

function Select-MenuOption {
    <#
    .SYNOPSIS
        Interactive arrow-key menu selector. Use Up/Down to navigate, Enter to select.
        Falls back to text-based Read-Host when no interactive console is available
        (PSSession, Scheduled Task, ISE, etc.).
    #>
    param(
        [array]$Items,
        [string]$Title = "",
        [scriptblock]$BeforeRender = $null
    )

    $selectableItems = @($Items | Where-Object { -not $_.Separator })
    if ($selectableItems.Count -eq 0) { return $null }

    # Fallback: no interactive console → render static menu + Read-Host
    if (-not (Test-InteractiveConsole)) {
        return Select-MenuOptionFallback -Items $Items -Title $Title -BeforeRender $BeforeRender
    }

    $selectedIndex = 0
    $savedCursor = $true
    try { $savedCursor = [Console]::CursorVisible } catch {}
    try { [Console]::CursorVisible = $false } catch {}

    # Build a map: selectableIndex -> screen row (filled after first render)
    $itemRowMap = @{}
    $menuWidth = 60

    try {
        # --- First render: draw full screen once ---
        Clear-Host
        if ($BeforeRender) { & $BeforeRender }
        if ($Title) { Write-MenuHeader $Title }
        Write-Host ""

        $selectableIdx = 0
        foreach ($item in $Items) {
            if ($item.Separator) {
                Write-Separator
                continue
            }
            # Record which screen row this item starts on
            $itemRowMap[$selectableIdx] = [Console]::CursorTop
            Write-MenuItemLine -Item $item -IsSelected ($selectableIdx -eq $selectedIndex) -MenuWidth $menuWidth
            $selectableIdx++
        }

        Write-Host ""
        Write-Host "  Use " -ForegroundColor DarkGray -NoNewline
        Write-Host "[Up/Down]" -ForegroundColor Cyan -NoNewline
        Write-Host " to navigate, " -ForegroundColor DarkGray -NoNewline
        Write-Host "[Enter]" -ForegroundColor Cyan -NoNewline
        Write-Host " to select, or press a shortcut key" -ForegroundColor DarkGray

        # --- Input loop: only redraw changed lines ---
        while ($true) {
            $keyInfo = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            $prevIndex = $selectedIndex

            switch ($keyInfo.VirtualKeyCode) {
                38 { $selectedIndex = if ($selectedIndex -gt 0) { $selectedIndex - 1 } else { $selectableItems.Count - 1 } }
                40 { $selectedIndex = if ($selectedIndex -lt ($selectableItems.Count - 1)) { $selectedIndex + 1 } else { 0 } }
                13 { return $selectableItems[$selectedIndex].Key }
                default {
                    $ch = $keyInfo.Character
                    if ($ch) {
                        $typed = $ch.ToString().ToUpper()
                        $match = $selectableItems | Where-Object { $_.Key -eq $typed }
                        if ($match) { return $typed }
                    }
                }
            }

            # Only redraw if selection changed
            if ($selectedIndex -ne $prevIndex) {
                # Redraw old line (deselect)
                if ($itemRowMap.ContainsKey($prevIndex)) {
                    [Console]::SetCursorPosition(0, $itemRowMap[$prevIndex])
                    Write-MenuItemLine -Item $selectableItems[$prevIndex] -IsSelected $false -MenuWidth $menuWidth
                }
                # Redraw new line (select)
                if ($itemRowMap.ContainsKey($selectedIndex)) {
                    [Console]::SetCursorPosition(0, $itemRowMap[$selectedIndex])
                    Write-MenuItemLine -Item $selectableItems[$selectedIndex] -IsSelected $true -MenuWidth $menuWidth
                }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $savedCursor } catch {}
    }
}

function Select-MenuOptionFallback {
    <# Text-only fallback for non-interactive consoles (PSSession, ISE, Scheduled Task) #>
    param(
        [array]$Items,
        [string]$Title = "",
        [scriptblock]$BeforeRender = $null
    )

    Clear-Host
    if ($BeforeRender) { & $BeforeRender }
    if ($Title) { Write-MenuHeader $Title }
    Write-Host ""

    foreach ($item in $Items) {
        if ($item.Separator) { Write-Separator; continue }
        Write-MenuOption $item.Key $item.Label -Status $item.Status
    }

    return Read-MenuChoice
}

function Confirm-Action {
    param([string]$Message)
    Write-Host ""
    Write-Host "  $Message (Y/N): " -ForegroundColor Yellow -NoNewline
    $response = (Read-Host).Trim().ToUpper()
    return ($response -eq "Y" -or $response -eq "YES")
}

function Get-Settings {
    $settingsPath = Join-Path $PSScriptRoot "..\config\settings.json"
    if (Test-Path $settingsPath) {
        return Get-Content $settingsPath -Raw | ConvertFrom-Json
    }
    else {
        Write-Step "Settings file not found at $settingsPath" -Type Error
        return $null
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-RequiresAdmin {
    Write-Step "This operation requires Administrator privileges." -Type Error
    Write-Step "Please run this script as Administrator." -Type Warning
}

$script:_cachedLogDir = $null

function Reset-LogCache {
    $script:_cachedLogDir = $null
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    if (-not $script:_cachedLogDir) {
        $settings = Get-Settings
        $script:_cachedLogDir = if ($settings) { $settings.LogsPath } else { "C:\WinGateKeeper\Logs" }
    }
    $logDir = $script:_cachedLogDir
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $logFile = Join-Path $logDir "wingatekeeper_$(Get-Date -Format 'yyyyMMdd').log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    try {
        Add-Content -Path $logFile -Value $entry -ErrorAction Stop
    }
    catch {
        Write-Warning "WinGateKeeper: Failed to write log: $_"
    }
}

function Restart-SSHDService {
    <# Safe sshd restart with timeout — avoids hanging on StopPending #>
    param([int]$TimeoutSeconds = 15)
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Step "sshd service not found." -Type Warning
        return $false
    }
    try {
        if ($svc.Status -ne 'Stopped') {
            $svc.Stop()
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        $svc.Start()
        $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($TimeoutSeconds))
        return $true
    }
    catch [System.ServiceProcess.TimeoutException] {
        Write-Step "sshd restart timed out after ${TimeoutSeconds}s. Check service status manually." -Type Error
        return $false
    }
    catch {
        Write-Step "sshd restart failed: $_" -Type Error
        return $false
    }
}

function New-AdminSystemAcl {
    <#
    .SYNOPSIS
        Creates a standard ACL with inheritance blocked, only Admins + SYSTEM full control.
        Returns the ACL object for further customization before applying.
    #>
    param([string]$Path)
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) } | Out-Null

    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $acl.AddAccessRule($adminRule)
    $acl.AddAccessRule($systemRule)
    return $acl
}

function Invoke-LogRotation {
    $settings = Get-Settings
    if (-not $settings) { return }

    $logMgmt = $settings.LogManagement
    $maxDays = if ($logMgmt -and $logMgmt.MaxLogAgeDays) { $logMgmt.MaxLogAgeDays } else { 90 }
    $logDir = $settings.LogsPath

    if (-not (Test-Path $logDir)) { return }

    $cutoff = (Get-Date).AddDays(-$maxDays)
    $removed = 0

    # Clean old WinGateKeeper logs
    Get-ChildItem -Path $logDir -Filter "wingatekeeper_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }

    # Clean old transcript folders
    $transcriptPath = $settings.PowerShellLogging.TranscriptionPath
    if ($transcriptPath -and (Test-Path $transcriptPath)) {
        Get-ChildItem -Path $transcriptPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                $removed++
            }
        # Remove empty directories (catch race: a file may appear between check and delete)
        Get-ChildItem -Path $transcriptPath -Directory -Recurse -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                try {
                    [System.IO.Directory]::Delete($_.FullName, $false)
                }
                catch {
                    # Directory not empty or already removed — expected, ignore
                }
            }
    }

    if ($removed -gt 0) {
        Write-Log "Log rotation: removed $removed files older than $maxDays days."
    }
}

function Pause-Menu {
    Write-Host ""
    Write-Host "  Press Enter to continue..." -ForegroundColor DarkGray -NoNewline
    Read-Host | Out-Null
}

Export-ModuleMember -Function *
