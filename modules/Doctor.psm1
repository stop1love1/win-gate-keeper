# ============================================================================
# WinGateKeeper - Doctor / Health Check Module
# Checks prerequisites, auto-installs missing packages, validates configuration
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

function Invoke-Doctor {
    param(
        [switch]$AutoFix
    )

    Write-MenuHeader "WinGateKeeper Doctor"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    $issues = @()
    $passed = 0
    $failed = 0

    Write-Host ""
    Write-Host "  Running health checks..." -ForegroundColor White
    Write-Host ""

    # =========================================================================
    # 1. PowerShell Version
    # =========================================================================
    Write-Host "  PowerShell Version               " -NoNewline
    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -ge 5) {
        Write-Host "OK ($psVer)" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "FAIL ($psVer - requires 5.1+)" -ForegroundColor Red
        $issues += @{ Name = "PowerShell"; Issue = "Version $psVer is below minimum 5.1"; CanFix = $false }
        $failed++
    }

    # =========================================================================
    # 2. OpenSSH Server
    # =========================================================================
    Write-Host "  OpenSSH Server                   " -NoNewline
    $sshCap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "OpenSSH.Server*" }
    $sshdExe = Get-Command sshd.exe -ErrorAction SilentlyContinue
    $sshdSvcExists = Get-Service -Name sshd -ErrorAction SilentlyContinue

    if ($sshCap -and $sshCap.State -eq "Installed") {
        Write-Host "OK (Windows Capability)" -ForegroundColor Green
        $passed++
    }
    elseif ($sshdExe -and $sshdSvcExists) {
        Write-Host "OK (Manual install)" -ForegroundColor Green
        $passed++
    }
    elseif ($sshCap) {
        Write-Host "MISSING" -ForegroundColor Red
        $issues += @{ Name = "OpenSSH Server"; Issue = "Not installed"; CanFix = $true; FixAction = "Install-OpenSSHServer" }
        $failed++
        if ($AutoFix) {
            Write-Step "Auto-installing OpenSSH Server..." -Type Info
            try {
                Add-WindowsCapability -Online -Name $sshCap.Name | Out-Null
                Write-Step "OpenSSH Server installed." -Type Success
                Write-Log "Doctor: Auto-installed OpenSSH Server."
            }
            catch {
                Write-Step "Failed to install: $_" -Type Error
            }
        }
    }
    else {
        Write-Host "NOT FOUND" -ForegroundColor Red
        $issues += @{ Name = "OpenSSH Server"; Issue = "Not found. On Server 2016 install from github.com/PowerShell/Win32-OpenSSH"; CanFix = $false }
        $failed++
    }

    # =========================================================================
    # 3. OpenSSH Client
    # =========================================================================
    Write-Host "  OpenSSH Client                   " -NoNewline
    $sshClient = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "OpenSSH.Client*" }
    $sshExe = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (($sshClient -and $sshClient.State -eq "Installed") -or $sshExe) {
        Write-Host "OK" -ForegroundColor Green
        $passed++
    }
    elseif ($sshClient) {
        Write-Host "MISSING" -ForegroundColor Red
        $issues += @{ Name = "OpenSSH Client"; Issue = "Not installed"; CanFix = $true; FixAction = "Install-OpenSSHClient" }
        $failed++
        if ($AutoFix) {
            Write-Step "Auto-installing OpenSSH Client..." -Type Info
            try {
                Add-WindowsCapability -Online -Name $sshClient.Name | Out-Null
                Write-Step "OpenSSH Client installed." -Type Success
                Write-Log "Doctor: Auto-installed OpenSSH Client."
            }
            catch {
                Write-Step "Failed to install: $_" -Type Error
            }
        }
    }
    else {
        Write-Host "NOT FOUND" -ForegroundColor Yellow
        $issues += @{ Name = "OpenSSH Client"; Issue = "Not found (optional)"; CanFix = $false }
        $failed++
    }

    # =========================================================================
    # 4. sshd Service Status
    # =========================================================================
    Write-Host "  sshd Service                     " -NoNewline
    $sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshdSvc -and $sshdSvc.Status -eq "Running") {
        Write-Host "OK (Running, $($sshdSvc.StartType))" -ForegroundColor Green
        $passed++
    }
    elseif ($sshdSvc) {
        Write-Host "STOPPED ($($sshdSvc.StartType))" -ForegroundColor Yellow
        $issues += @{ Name = "sshd Service"; Issue = "Not running"; CanFix = $true; FixAction = "Start-sshd" }
        $failed++
        if ($AutoFix) {
            Write-Step "Auto-starting sshd service..." -Type Info
            try {
                Set-Service -Name sshd -StartupType Automatic
                Start-Service sshd
                Write-Step "sshd service started." -Type Success
                Write-Log "Doctor: Auto-started sshd service."
            }
            catch {
                Write-Step "Failed to start sshd: $_" -Type Error
            }
        }
    }
    else {
        Write-Host "NOT FOUND" -ForegroundColor Red
        $issues += @{ Name = "sshd Service"; Issue = "Service not registered (install OpenSSH first)"; CanFix = $false }
        $failed++
    }

    # =========================================================================
    # 5. ssh-agent Service
    # =========================================================================
    Write-Host "  ssh-agent Service                " -NoNewline
    $agentSvc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if ($agentSvc -and $agentSvc.Status -eq "Running") {
        Write-Host "OK (Running)" -ForegroundColor Green
        $passed++
    }
    elseif ($agentSvc) {
        Write-Host "STOPPED" -ForegroundColor Yellow
        $issues += @{ Name = "ssh-agent Service"; Issue = "Not running"; CanFix = $true; FixAction = "Start-ssh-agent" }
        $failed++
        if ($AutoFix) {
            Write-Step "Auto-starting ssh-agent..." -Type Info
            try {
                Set-Service -Name ssh-agent -StartupType Automatic
                Start-Service ssh-agent
                Write-Step "ssh-agent started." -Type Success
            }
            catch {
                Write-Step "Failed to start ssh-agent: $_" -Type Error
            }
        }
    }
    else {
        Write-Host "NOT FOUND" -ForegroundColor Red
        $issues += @{ Name = "ssh-agent"; Issue = "Service not registered"; CanFix = $false }
        $failed++
    }

    # =========================================================================
    # 6. Firewall Rule
    # =========================================================================
    Write-Host "  Firewall Rule (SSH)              " -NoNewline
    $sshPort = if ($settings.SSHPort) { $settings.SSHPort } else { 22 }
    $fwRule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if ($fwRule -and $fwRule.Enabled -eq "True") {
        Write-Host "OK (Port $sshPort)" -ForegroundColor Green
        $passed++
    }
    elseif ($fwRule) {
        Write-Host "DISABLED" -ForegroundColor Yellow
        $issues += @{ Name = "Firewall Rule"; Issue = "Rule exists but disabled"; CanFix = $true }
        $failed++
        if ($AutoFix) {
            Enable-NetFirewallRule -Name "OpenSSH-Server-In-TCP"
            Write-Step "Firewall rule enabled." -Type Success
        }
    }
    else {
        Write-Host "MISSING" -ForegroundColor Red
        $issues += @{ Name = "Firewall Rule"; Issue = "No inbound rule for SSH"; CanFix = $true }
        $failed++
        if ($AutoFix) {
            Write-Step "Auto-creating firewall rule..." -Type Info
            New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $sshPort | Out-Null
            Write-Step "Firewall rule created for port $sshPort." -Type Success
            Write-Log "Doctor: Auto-created firewall rule."
        }
    }

    # =========================================================================
    # 7. Base Directories
    # =========================================================================
    Write-Host "  Base Directories                 " -NoNewline
    $dirsOk = (Test-Path $settings.BasePath) -and (Test-Path $settings.UsersRoot) -and (Test-Path $settings.LogsPath)
    if ($dirsOk) {
        Write-Host "OK" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "MISSING" -ForegroundColor Red
        $missingDirs = @($settings.BasePath, $settings.UsersRoot, $settings.LogsPath) | Where-Object { -not (Test-Path $_) }
        $issues += @{ Name = "Base Directories"; Issue = "Missing: $($missingDirs -join ', ')"; CanFix = $true }
        $failed++
        if ($AutoFix) {
            Write-Step "Auto-creating directories..." -Type Info
            foreach ($dir in $missingDirs) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Write-Step "Created: $dir" -Type Success
            }
            Write-Log "Doctor: Auto-created missing directories."
        }
    }

    # =========================================================================
    # 8. SFTP Group
    # =========================================================================
    Write-Host "  SFTP Group ($($settings.SFTPOnlyGroup))          " -NoNewline
    $sftpGroup = Get-LocalGroup -Name $settings.SFTPOnlyGroup -ErrorAction SilentlyContinue
    if ($sftpGroup) {
        Write-Host "OK" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "MISSING" -ForegroundColor Red
        $issues += @{ Name = "SFTP Group"; Issue = "Group '$($settings.SFTPOnlyGroup)' does not exist"; CanFix = $true }
        $failed++
        if ($AutoFix) {
            Write-Step "Auto-creating SFTP group..." -Type Info
            try {
                New-LocalGroup -Name $settings.SFTPOnlyGroup -Description "SFTP-only access users" | Out-Null
                Write-Step "Group '$($settings.SFTPOnlyGroup)' created." -Type Success
                Write-Log "Doctor: Auto-created SFTP group."
            }
            catch {
                Write-Step "Failed to create group: $_" -Type Error
            }
        }
    }

    # =========================================================================
    # 9. sshd_config Exists
    # =========================================================================
    Write-Host "  sshd_config                      " -NoNewline
    if (Test-Path $settings.SSHConfigPath) {
        Write-Host "OK ($($settings.SSHConfigPath))" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "MISSING" -ForegroundColor Red
        $issues += @{ Name = "sshd_config"; Issue = "File not found at $($settings.SSHConfigPath)"; CanFix = $false }
        $failed++
    }

    # =========================================================================
    # 10. SFTP Chroot Config
    # =========================================================================
    Write-Host "  SFTP Chroot Config               " -NoNewline
    if (Test-Path $settings.SSHConfigPath) {
        $config = Get-Content $settings.SSHConfigPath -Raw -ErrorAction SilentlyContinue
        if ($config -match [regex]::Escape("Match Group $($settings.SFTPOnlyGroup)")) {
            Write-Host "OK" -ForegroundColor Green
            $passed++
        }
        else {
            Write-Host "NOT CONFIGURED" -ForegroundColor Yellow
            $issues += @{ Name = "SFTP Chroot"; Issue = "Match block not found in sshd_config"; CanFix = $false }
            $failed++
        }
    }
    else {
        Write-Host "SKIPPED (no sshd_config)" -ForegroundColor DarkGray
    }

    # =========================================================================
    # 11. File Audit Policy
    # =========================================================================
    Write-Host "  File Audit Policy                " -NoNewline
    $auditCheck = auditpol /get /subcategory:"File System" 2>$null
    if ($auditCheck -and ($auditCheck -join " ") -match "Success") {
        Write-Host "OK" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "NOT ENABLED" -ForegroundColor Yellow
        $issues += @{ Name = "File Audit"; Issue = "File System audit policy not enabled"; CanFix = $true }
        $failed++
        if ($AutoFix) {
            Write-Step "Auto-enabling file audit policies..." -Type Info
            & auditpol /set /subcategory:"File System" /success:enable /failure:enable 2>&1 | Out-Null
            & auditpol /set /subcategory:"Logon" /success:enable /failure:enable 2>&1 | Out-Null
            Write-Step "Audit policies enabled." -Type Success
            Write-Log "Doctor: Auto-enabled audit policies."
        }
    }

    # =========================================================================
    # 12. PowerShell Logging
    # =========================================================================
    Write-Host "  PowerShell Logging               " -NoNewline
    $sbLog = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -ErrorAction SilentlyContinue
    if ($sbLog -and $sbLog.EnableScriptBlockLogging -eq 1) {
        Write-Host "OK" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "NOT ENABLED" -ForegroundColor Yellow
        $issues += @{ Name = "PS Logging"; Issue = "Script Block Logging not enabled"; CanFix = $true }
        $failed++
        if ($AutoFix) {
            Write-Step "Auto-enabling PowerShell logging..." -Type Info
            $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
            Set-ItemProperty -Path $regPath -Name "EnableScriptBlockLogging" -Value 1 -Type DWord
            Write-Step "Script Block Logging enabled." -Type Success
            Write-Log "Doctor: Auto-enabled PowerShell logging."
        }
    }

    # =========================================================================
    # 13. Settings File Integrity
    # =========================================================================
    Write-Host "  Settings File                    " -NoNewline
    $requiredKeys = @("BasePath", "UsersRoot", "LogsPath", "SSHConfigPath", "SFTPOnlyGroup")
    $missingKeys = @()
    foreach ($key in $requiredKeys) {
        if (-not $settings.$key) { $missingKeys += $key }
    }
    if ($missingKeys.Count -eq 0) {
        Write-Host "OK" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "INCOMPLETE (missing: $($missingKeys -join ', '))" -ForegroundColor Red
        $issues += @{ Name = "Settings"; Issue = "Missing keys: $($missingKeys -join ', ')"; CanFix = $false }
        $failed++
    }

    # =========================================================================
    # Summary
    # =========================================================================
    Write-Host ""
    Write-Host ("  " + "=" * 50) -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  Results: " -NoNewline
    Write-Host "$passed passed" -ForegroundColor Green -NoNewline
    Write-Host ", " -NoNewline
    if ($failed -gt 0) {
        Write-Host "$failed failed" -ForegroundColor Red
    }
    else {
        Write-Host "$failed failed" -ForegroundColor Green
    }

    if ($issues.Count -gt 0) {
        Write-Host ""
        Write-Host "  Issues found:" -ForegroundColor Yellow
        Write-Host ("  " + "-" * 50) -ForegroundColor DarkGray
        foreach ($issue in $issues) {
            $fixable = if ($issue.CanFix) { " (auto-fixable)" } else { "" }
            Write-Host "  - $($issue.Name): $($issue.Issue)$fixable" -ForegroundColor White
        }

        if (-not $AutoFix) {
            $fixableCount = @($issues | Where-Object { $_.CanFix }).Count
            if ($fixableCount -gt 0) {
                Write-Host ""
                Write-Step "$fixableCount issue(s) can be auto-fixed. Run Doctor with auto-fix to resolve." -Type Info
            }
        }
    }
    else {
        Write-Host ""
        Write-Step "All checks passed! System is healthy." -Type Success
    }

    Write-Log "Doctor check completed. Passed: $passed, Failed: $failed, AutoFix: $AutoFix"

    Write-Host ""
}

function Show-DoctorMenu {
    while ($true) {
        Clear-Host
        Write-MenuHeader "Doctor - System Health Check"
        Write-Host ""
        Write-MenuOption "1" "Run Health Check (report only)"
        Write-MenuOption "2" "Run Health Check + Auto-Fix"
        Write-Separator
        Write-MenuOption "B" "Back to Main Menu"

        $choice = Read-MenuChoice

        switch ($choice) {
            "1" {
                Invoke-Doctor
                Pause-Menu
            }
            "2" {
                if (Confirm-Action "Auto-fix will install missing packages and enable services. Continue?") {
                    Invoke-Doctor -AutoFix
                }
                else {
                    Write-Step "Cancelled." -Type Warning
                }
                Pause-Menu
            }
            "B" { return }
            default { Write-Step "Invalid option." -Type Warning; Start-Sleep -Seconds 1 }
        }
    }
}

Export-ModuleMember -Function *
