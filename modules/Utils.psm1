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

function Select-MenuOption {
    <#
    .SYNOPSIS
        Interactive arrow-key menu selector. Use Up/Down to navigate, Enter to select.
        Also supports typing the shortcut key directly.
    .PARAMETER Items
        Array of hashtables: @{ Key="1"; Label="Option"; Status="OK" }
        For separators: @{ Separator=$true }
    .PARAMETER Title
        Menu header title (optional, displayed above items)
    #>
    param(
        [array]$Items,
        [string]$Title = "",
        [scriptblock]$BeforeRender = $null
    )

    # Filter selectable items (non-separator)
    $selectableItems = @($Items | Where-Object { -not $_.Separator })
    if ($selectableItems.Count -eq 0) { return $null }

    $selectedIndex = 0
    $cursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    try {
        while ($true) {
            Clear-Host

            # Run custom render (e.g. banner, status)
            if ($BeforeRender) { & $BeforeRender }

            if ($Title) { Write-MenuHeader $Title }
            Write-Host ""

            # Render all items
            $selectableIdx = 0
            foreach ($item in $Items) {
                if ($item.Separator) {
                    Write-Separator
                    continue
                }

                $isSelected = ($selectableIdx -eq $selectedIndex)
                $key = $item.Key
                $label = $item.Label
                $status = $item.Status

                if ($isSelected) {
                    # Highlighted row
                    Write-Host "  > " -ForegroundColor White -NoNewline
                    Write-Host "[$key]" -ForegroundColor Black -BackgroundColor Yellow -NoNewline
                    Write-Host " $label" -ForegroundColor White -BackgroundColor DarkCyan -NoNewline
                    if ($status) {
                        $statusColor = switch -Regex ($status) {
                            "^OK"       { "Green" }
                            "^FAIL"     { "Red" }
                            "^\d+ user" { "Cyan" }
                            default     { "DarkYellow" }
                        }
                        $statusText = switch ($status) {
                            "OK"   { " [OK]" }
                            "FAIL" { " [NOT CONFIGURED]" }
                            default { " [$status]" }
                        }
                        Write-Host $statusText -ForegroundColor $statusColor -BackgroundColor DarkCyan -NoNewline
                    }
                    # Pad rest of line with background
                    $lineLen = 4 + $key.Length + 2 + $label.Length + 1
                    if ($status) {
                        $statusText = switch ($status) { "OK" { " [OK]" }; "FAIL" { " [NOT CONFIGURED]" }; default { " [$status]" } }
                        $lineLen += $statusText.Length
                    }
                    $pad = [Math]::Max(0, 56 - $lineLen + 4)
                    Write-Host (" " * $pad) -BackgroundColor DarkCyan
                }
                else {
                    # Normal row
                    Write-Host "    " -NoNewline
                    Write-Host "[$key]" -ForegroundColor Yellow -NoNewline
                    Write-Host " $label" -NoNewline
                    if ($status) {
                        switch ($status) {
                            "OK"   { Write-Host " [OK]" -ForegroundColor Green }
                            "FAIL" { Write-Host " [NOT CONFIGURED]" -ForegroundColor Red }
                            default {
                                $c = if ($status -match "^\d+ user") { "Cyan" } else { "DarkYellow" }
                                Write-Host " [$status]" -ForegroundColor $c
                            }
                        }
                    }
                    else {
                        Write-Host ""
                    }
                }
                $selectableIdx++
            }

            Write-Host ""
            Write-Host "  Use " -ForegroundColor DarkGray -NoNewline
            Write-Host "[Up/Down]" -ForegroundColor Cyan -NoNewline
            Write-Host " to navigate, " -ForegroundColor DarkGray -NoNewline
            Write-Host "[Enter]" -ForegroundColor Cyan -NoNewline
            Write-Host " to select, or press a shortcut key" -ForegroundColor DarkGray

            # Read key input
            $keyInfo = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

            switch ($keyInfo.VirtualKeyCode) {
                38 {
                    # Up arrow
                    $selectedIndex = if ($selectedIndex -gt 0) { $selectedIndex - 1 } else { $selectableItems.Count - 1 }
                }
                40 {
                    # Down arrow
                    $selectedIndex = if ($selectedIndex -lt ($selectableItems.Count - 1)) { $selectedIndex + 1 } else { 0 }
                }
                13 {
                    # Enter
                    return $selectableItems[$selectedIndex].Key
                }
                default {
                    # Check if typed character matches a shortcut key
                    $ch = $keyInfo.Character
                    if ($ch) {
                        $typed = $ch.ToString().ToUpper()
                        $match = $selectableItems | Where-Object { $_.Key -eq $typed }
                        if ($match) {
                            return $typed
                        }
                    }
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $cursorVisible
    }
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
    Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

Export-ModuleMember -Function *
