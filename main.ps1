# ============================================================================
# WinGateKeeper - Main CLI Entry Point
# Windows Server Access Control & User Isolation
# ============================================================================

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

# Import all modules
$modulePath = Join-Path $PSScriptRoot "modules"
Import-Module "$modulePath\Utils.psm1" -Force
Import-Module "$modulePath\OpenSSHSetup.psm1" -Force
Import-Module "$modulePath\UserManagement.psm1" -Force
Import-Module "$modulePath\DirectorySetup.psm1" -Force
Import-Module "$modulePath\SFTPConfig.psm1" -Force
Import-Module "$modulePath\AuditLogging.psm1" -Force
Import-Module "$modulePath\StatusOverview.psm1" -Force
Import-Module "$modulePath\Doctor.psm1" -Force
Import-Module "$modulePath\SystemReset.psm1" -Force
Import-Module "$modulePath\SSHHardening.psm1" -Force

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
        $st = Get-QuickStatus
        $choice = Select-MenuOption -Title "Main Menu" -BeforeRender { Write-Banner } -Items @(
            @{ Key = "0"; Label = "Quick Setup (All Steps)" }
            @{ Separator = $true }
            @{ Key = "1"; Label = "OpenSSH Server Management"; Status = $st.SSH }
            @{ Key = "2"; Label = "User Management"; Status = $st.Users }
            @{ Key = "3"; Label = "Directory & Permissions"; Status = $st.Dirs }
            @{ Key = "4"; Label = "SFTP Configuration"; Status = $st.SFTP }
            @{ Key = "5"; Label = "Audit & Logging"; Status = $st.Audit }
            @{ Key = "6"; Label = "SSH Security & Sessions" }
            @{ Separator = $true }
            @{ Key = "S"; Label = "System Status Overview" }
            @{ Key = "D"; Label = "Doctor (Health Check & Auto-Fix)" }
            @{ Key = "R"; Label = "System Reset / Clear Data" }
            @{ Key = "C"; Label = "Edit Configuration" }
            @{ Key = "A"; Label = "About / Author" }
            @{ Separator = $true }
            @{ Key = "Q"; Label = "Quit" }
        )

        switch ($choice) {
            "0" { Start-QuickSetup; $script:_statusCache = $null }
            "1" { Show-OpenSSHMenu; $script:_statusCache = $null }
            "2" { Show-UserManagementMenu; $script:_statusCache = $null }
            "3" { Show-DirectoryMenu; $script:_statusCache = $null }
            "4" { Show-SFTPMenu; $script:_statusCache = $null }
            "5" { Show-AuditMenu; $script:_statusCache = $null }
            "6" { Show-SSHSecurityMenu; $script:_statusCache = $null }
            "S" { Show-SystemOverview }
            "D" { Show-DoctorMenu; $script:_statusCache = $null }
            "R" { Show-ResetMenu; $script:_statusCache = $null }
            "C" { Edit-Configuration; $script:_statusCache = $null }
            "A" { Show-AuthorInfo }
            "Q" {
                Write-Host ""
                Write-Step "Goodbye!" -Type Info
                Write-Host ""
                return
            }
        }
    }
}

function Show-AuthorInfo {
    $repoUrl = "https://github.com/stop1love1/win-gate-keeper"

    while ($true) {
        $choice = Select-MenuOption -Title "About WinGateKeeper" -BeforeRender {
            Write-Banner
            Write-Host ""
            Write-Host "  Author:     stop1love1" -ForegroundColor Cyan
            Write-Host "  Repository: $repoUrl" -ForegroundColor White
        } -Items @(
            @{ Key = "1"; Label = "Open repository in default browser" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back to Main Menu" }
        )
        switch ($choice) {
            "1" {
                try {
                    Start-Process $repoUrl -ErrorAction Stop
                    Write-Step "Link opened in your default browser." -Type Info
                }
                catch {
                    Write-Step "Could not open browser. Visit manually: $repoUrl" -Type Warning
                }
                Pause-Menu
            }
            "B" { return }
        }
    }
}

function Edit-Configuration {
    Write-MenuHeader "Edit Configuration"

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }
    $settingsPath = Join-Path $PSScriptRoot "config\settings.json"

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
                # Validate: block dangerous system paths
                $blocked = @(
                    "$env:SystemRoot", "$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64",
                    "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramData",
                    "C:\Windows", "C:\Windows\System32", "C:\Program Files", "C:\Program Files (x86)"
                )
                $resolvedNew = $newPath.TrimEnd('\')
                $isBlocked = $blocked | Where-Object { $resolvedNew -ieq $_.TrimEnd('\') }
                if ($isBlocked) {
                    Write-Step "Cannot use '$newPath' as base path - this is a protected system directory." -Type Error
                }
                elseif ($newPath -notmatch '^[A-Z]:\\') {
                    Write-Step "Please enter a full path starting with a drive letter (e.g. D:\WinGateKeeper)." -Type Error
                }
                else {
                    $settings.BasePath = $newPath
                    $settings.UsersRoot = Join-Path $newPath "Users"
                    $settings.LogsPath = Join-Path $newPath "Logs"
                    $settings | ConvertTo-Json -Depth 5 | Set-Content $settingsPath -Encoding UTF8
                    Reset-LogCache
                    Write-Step "Configuration updated." -Type Success
                    Write-Log "Base path changed to: $newPath"
                }
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
# Run log rotation on startup (clean old logs silently)
try { Invoke-LogRotation } catch {}

if (-not (Test-IsAdmin)) {
    Write-Banner
    Write-Host ""
    Write-Host "  ERROR: WinGateKeeper requires Administrator privileges!" -ForegroundColor Red
    Write-Host "  Please right-click PowerShell and select 'Run as Administrator'." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Show-MainMenu
