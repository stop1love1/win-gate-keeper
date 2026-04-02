# ============================================================================
# AdminGate - Main CLI Entry Point
# Windows Server Access Control & User Isolation
# ============================================================================

#Requires -Version 5.1

$ErrorActionPreference = "Continue"

# Import all modules
$modulePath = Join-Path $PSScriptRoot "modules"
Import-Module "$modulePath\Utils.psm1" -Force
Import-Module "$modulePath\OpenSSHSetup.psm1" -Force
Import-Module "$modulePath\UserManagement.psm1" -Force
Import-Module "$modulePath\DirectorySetup.psm1" -Force
Import-Module "$modulePath\SFTPConfig.psm1" -Force
Import-Module "$modulePath\AuditLogging.psm1" -Force
Import-Module "$modulePath\StatusOverview.psm1" -Force

$script:_statusCache = $null
$script:_statusCacheTime = [datetime]::MinValue

function Get-QuickStatus {
    # Return cached result if less than 30 seconds old
    if ($script:_statusCache -and ([datetime]::Now - $script:_statusCacheTime).TotalSeconds -lt 30) {
        return $script:_statusCache
    }

    $status = @{}

    # OpenSSH
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    $status.SSH = if ($svc -and $svc.Status -eq "Running") { "OK" } else { "FAIL" }

    # Directories
    $settings = Get-Settings
    if ($settings) {
        $status.Dirs = if ((Test-Path $settings.BasePath) -and (Test-Path $settings.UsersRoot)) { "OK" } else { "FAIL" }

        # Users
        $builtIn = @("Administrator", "DefaultAccount", "Guest", "WDAGUtilityAccount")
        $count = @(Get-LocalUser | Where-Object { $_.Name -notin $builtIn }).Count
        $status.Users = if ($count -gt 0) { "$count users" } else { "0 users" }

        # SFTP
        $sftpGroup = Get-LocalGroup -Name $settings.SFTPOnlyGroup -ErrorAction SilentlyContinue
        if ($sftpGroup -and (Test-Path $settings.SSHConfigPath)) {
            $cfg = Get-Content $settings.SSHConfigPath -Raw -ErrorAction SilentlyContinue
            $status.SFTP = if ($cfg -match [regex]::Escape("Match Group $($settings.SFTPOnlyGroup)")) { "OK" } else { "FAIL" }
        }
        else { $status.SFTP = "FAIL" }
    }
    else {
        $status.Dirs = "FAIL"
        $status.Users = "?"
        $status.SFTP = "FAIL"
    }

    # Audit
    $sbLog = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -ErrorAction SilentlyContinue
    $status.Audit = if ($sbLog -and $sbLog.EnableScriptBlockLogging -eq 1) { "OK" } else { "FAIL" }

    $script:_statusCache = $status
    $script:_statusCacheTime = [datetime]::Now
    return $status
}

function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-Banner

        # Quick status check
        $st = Get-QuickStatus

        Write-MenuHeader "Main Menu"
        Write-Host ""
        Write-MenuOption "0" "Quick Setup (All Steps)"
        Write-Host ""
        Write-MenuOption "1" "OpenSSH Server Management" -Status $st.SSH
        Write-MenuOption "2" "User Management" -Status $st.Users
        Write-MenuOption "3" "Directory & Permissions" -Status $st.Dirs
        Write-MenuOption "4" "SFTP Configuration" -Status $st.SFTP
        Write-MenuOption "5" "Audit & Logging" -Status $st.Audit
        Write-Separator
        Write-MenuOption "S" "System Status Overview"
        Write-MenuOption "C" "Edit Configuration"
        Write-Separator
        Write-MenuOption "Q" "Quit"

        $choice = Read-MenuChoice

        switch ($choice) {
            "0" { Start-QuickSetup; $script:_statusCache = $null }
            "1" { Show-OpenSSHMenu; $script:_statusCache = $null }
            "2" { Show-UserManagementMenu; $script:_statusCache = $null }
            "3" { Show-DirectoryMenu; $script:_statusCache = $null }
            "4" { Show-SFTPMenu; $script:_statusCache = $null }
            "5" { Show-AuditMenu; $script:_statusCache = $null }
            "S" { Show-SystemOverview }
            "C" { Edit-Configuration; $script:_statusCache = $null }
            "Q" {
                Write-Host ""
                Write-Step "Goodbye!" -Type Info
                Write-Host ""
                return
            }
            default {
                Write-Step "Invalid option. Please try again." -Type Warning
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Edit-Configuration {
    Write-MenuHeader "Edit Configuration"

    $settingsPath = Join-Path $PSScriptRoot "config\settings.json"
    if (-not (Test-Path $settingsPath)) {
        Write-Step "Settings file not found at $settingsPath" -Type Error
        Pause-Menu
        return
    }
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json

    Write-Host ""
    Write-Host "  Current Configuration:" -ForegroundColor White
    Write-Separator
    Write-Host "  Base Path:        $($settings.BasePath)" -ForegroundColor Cyan
    Write-Host "  Users Root:       $($settings.UsersRoot)" -ForegroundColor Cyan
    Write-Host "  Logs Path:        $($settings.LogsPath)" -ForegroundColor Cyan
    Write-Host "  SSH Config:       $($settings.SSHConfigPath)" -ForegroundColor Cyan
    Write-Host "  SFTP Group:       $($settings.SFTPOnlyGroup)" -ForegroundColor Cyan
    Write-Host "  Admin Group:      $($settings.AdminGroup)" -ForegroundColor Cyan
    Write-Host "  Transcripts:      $($settings.PowerShellLogging.TranscriptionPath)" -ForegroundColor Cyan

    Write-Host ""
    Write-MenuOption "1" "Change Base Path"
    Write-MenuOption "2" "Change SFTP Group Name"
    Write-MenuOption "3" "Open settings.json in editor"
    Write-Separator
    Write-MenuOption "B" "Back"

    $choice = Read-MenuChoice

    switch ($choice) {
        "1" {
            Write-Host "  Enter new base path: " -ForegroundColor White -NoNewline
            $newPath = (Read-Host).Trim()
            if ($newPath) {
                $settings.BasePath = $newPath
                $settings.UsersRoot = Join-Path $newPath "Users"
                $settings.LogsPath = Join-Path $newPath "Logs"
                $settings | ConvertTo-Json -Depth 5 | Set-Content $settingsPath -Encoding UTF8
                Reset-LogCache
                Write-Step "Configuration updated." -Type Success
                Write-Log "Base path changed to: $newPath"
            }
            Pause-Menu
        }
        "2" {
            Write-Host "  Enter new SFTP group name: " -ForegroundColor White -NoNewline
            $newGroup = (Read-Host).Trim()
            if ($newGroup) {
                $settings.SFTPOnlyGroup = $newGroup
                $settings | ConvertTo-Json -Depth 5 | Set-Content $settingsPath -Encoding UTF8
                Write-Step "SFTP group name updated to: $newGroup" -Type Success
                Write-Log "SFTP group changed to: $newGroup"
            }
            Pause-Menu
        }
        "3" {
            if (Get-Command notepad -ErrorAction SilentlyContinue) {
                Start-Process notepad $settingsPath
                Write-Step "Opened settings.json in Notepad." -Type Info
            }
            Pause-Menu
        }
        "B" { return }
    }
}

# Entry point - require Administrator
if (-not (Test-IsAdmin)) {
    Write-Banner
    Write-Host ""
    Write-Host "  ERROR: AdminGate requires Administrator privileges!" -ForegroundColor Red
    Write-Host "  Please right-click PowerShell and select 'Run as Administrator'." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Show-MainMenu
