# ============================================================================
# AdminGate - Utility Functions
# ============================================================================

function Write-Banner {
    $banner = @"

     _       _           _        ____       _
    / \   __| |_ __ ___ (_)_ __  / ___| __ _| |_ ___
   / _ \ / _` | '_ ` _ \| | '_ \| |  _ / _` | __/ _ \
  / ___ \ (_| | | | | | | | | | | |_| | (_| | ||  __/
 /_/   \_\__,_|_| |_| |_|_|_| |_|\____|\__,_|\__\___|

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
        $script:_cachedLogDir = if ($settings) { $settings.LogsPath } else { "C:\AdminGate\Logs" }
    }
    $logDir = $script:_cachedLogDir
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $logFile = Join-Path $logDir "admingate_$(Get-Date -Format 'yyyyMMdd').log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    try {
        Add-Content -Path $logFile -Value $entry -ErrorAction Stop
    }
    catch {
        Write-Warning "AdminGate: Failed to write log: $_"
    }
}

function Pause-Menu {
    Write-Host ""
    Write-Host "  Press any key to continue..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

Export-ModuleMember -Function *
