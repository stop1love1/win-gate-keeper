# ============================================================================
# WinGateKeeper - SFTP Configuration Module
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

function Set-SFTPChrootConfig {
    Write-MenuHeader "Configure SFTP Chroot Jail"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }
    $sshdConfig = $settings.SSHConfigPath

    if (-not (Test-Path $sshdConfig)) {
        Write-Step "sshd_config not found at: $sshdConfig" -Type Error
        Write-Step "Install OpenSSH Server first." -Type Warning
        Pause-Menu
        return
    }

    # Backup current config
    $backupPath = "$sshdConfig.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item -Path $sshdConfig -Destination $backupPath
    Write-Step "Backup saved: $backupPath" -Type Info

    $content = Get-Content $sshdConfig -Raw

    # SFTP subsystem (Windows OpenSSH does not support -l flag on sftp-server.exe)
    $sftpSubsystem = "Subsystem sftp sftp-server.exe"

    # Check and update subsystem line
    if ($content -match "^Subsystem\s+sftp") {
        $content = $content -replace "(?m)^Subsystem\s+sftp.*$", $sftpSubsystem
        Write-Step "Updated SFTP subsystem line." -Type Info
    }
    elseif ($content -notmatch "Subsystem\s+sftp") {
        $content += "`r`n$sftpSubsystem"
        Write-Step "Added SFTP subsystem line." -Type Info
    }

    # Match group block for SFTP-only users
    $sftpGroup = $settings.SFTPOnlyGroup
    $chrootDir = $settings.UsersRoot

    # Windows OpenSSH does not support %u/%h tokens in ChrootDirectory.
    # Per-user isolation is enforced via NTFS ACLs: each user's subdirectory
    # grants Modify only to that user. UsersRoot grants users only Traverse
    # (no ListDirectory), so users cannot enumerate other usernames.
    # NOTE: OpenSSH chroot requires the chroot directory to be owned by
    # Administrators with no write access for other users.
    $matchBlock = @"

# BEGIN WinGateKeeper SFTP Configuration
Match Group $sftpGroup
    ForceCommand internal-sftp
    ChrootDirectory $chrootDir
    PermitTunnel no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
# END WinGateKeeper SFTP Configuration
"@

    # Remove existing WinGateKeeper or legacy AdminGate block (marker-based for safety)
    $lines = $content -split "`r?`n"
    $inBlock = $false
    $cleanedLines = @()
    foreach ($line in $lines) {
        if ($line -match "^# BEGIN (AdminGate|WinGateKeeper)" -or $line -in @("# AdminGate SFTP-only configuration", "# WinGateKeeper SFTP-only configuration")) {
            $inBlock = $true
            continue
        }
        if ($inBlock) {
            if ($line -match "^# END (AdminGate|WinGateKeeper)") {
                $inBlock = $false
                continue
            }
            # Legacy format: end on non-indented non-empty line
            if ($line -match "^[^\s#]" -and $line -ne "") {
                $inBlock = $false
                $cleanedLines += $line
            }
            continue
        }
        $cleanedLines += $line
    }
    $content = ($cleanedLines -join "`r`n").TrimEnd() + "`r`n" + $matchBlock + "`r`n"

    # Write to temp file (BOM-free UTF-8, required by OpenSSH) and validate before applying
    $tempConfig = "$sshdConfig.tmp"
    [System.IO.File]::WriteAllText($tempConfig, $content, [System.Text.UTF8Encoding]::new($false))

    # Validate sshd config syntax
    $sshdExe = Get-Command sshd.exe -ErrorAction SilentlyContinue
    if ($sshdExe) {
        $testResult = & sshd.exe -t -f $tempConfig 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Step "Invalid sshd_config syntax! Restoring backup." -Type Error
            Write-Step "$testResult" -Type Error
            Copy-Item -Path $backupPath -Destination $sshdConfig -Force
            Remove-Item -Path $tempConfig -Force -ErrorAction SilentlyContinue
            Pause-Menu
            return
        }
    }

    # Apply validated config
    Move-Item -Path $tempConfig -Destination $sshdConfig -Force
    Write-Step "sshd_config updated with SFTP chroot configuration." -Type Success

    # Restart sshd to apply
    Write-Step "Restarting sshd service..." -Type Info
    Restart-Service sshd -Force
    Write-Step "sshd service restarted." -Type Success

    Write-Log "SFTP chroot configuration applied. Group: $sftpGroup, ChrootDir: $chrootDir"

    Write-Host ""
    Write-Step "SFTP chroot configuration complete!" -Type Success
    Pause-Menu
}

function Show-SSHDConfig {
    Write-MenuHeader "Current sshd_config"

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }
    $sshdConfig = $settings.SSHConfigPath

    if (-not (Test-Path $sshdConfig)) {
        Write-Step "sshd_config not found." -Type Error
        Pause-Menu
        return
    }

    Write-Host ""
    $content = Get-Content $sshdConfig
    foreach ($line in $content) {
        if ($line -match "^#") {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
        elseif ($line -match "^Match ") {
            Write-Host "  $line" -ForegroundColor Yellow
        }
        elseif ($line.Trim()) {
            Write-Host "  $line" -ForegroundColor White
        }
        else {
            Write-Host ""
        }
    }

    Pause-Menu
}

function Test-SFTPAccess {
    Write-MenuHeader "Test SFTP Configuration"

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    Write-Host ""
    Write-Host "  Enter username to test: " -ForegroundColor White -NoNewline
    $username = (Read-Host).Trim()

    $user = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Step "User '$username' not found." -Type Error
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  Test Results:" -ForegroundColor White
    Write-Separator

    # Check if user exists
    Write-Host "  User exists               " -NoNewline
    Write-Host "PASS" -ForegroundColor Green

    # Check if user is enabled
    Write-Host "  User enabled              " -NoNewline
    if ($user.Enabled) { Write-Host "PASS" -ForegroundColor Green }
    else { Write-Host "FAIL (disabled)" -ForegroundColor Red }

    # Check SFTP group membership
    $sftpGroup = $settings.SFTPOnlyGroup
    $inSFTPGroup = $false
    try {
        $members = Get-LocalGroupMember -Group $sftpGroup -ErrorAction SilentlyContinue
        $inSFTPGroup = ($members.Name -like "*\$username")
    }
    catch {}

    Write-Host "  In SFTP-only group        " -NoNewline
    if ($inSFTPGroup) { Write-Host "YES (SFTP-only)" -ForegroundColor Cyan }
    else { Write-Host "NO (Shell access)" -ForegroundColor Yellow }

    # Check user directory
    $userDir = Join-Path $settings.UsersRoot $username
    Write-Host "  User directory exists      " -NoNewline
    if (Test-Path $userDir) { Write-Host "PASS" -ForegroundColor Green }
    else { Write-Host "FAIL (missing)" -ForegroundColor Red }

    # Check sshd_config has Match block
    $sshdConfig = $settings.SSHConfigPath
    if (Test-Path $sshdConfig) {
        $content = Get-Content $sshdConfig -Raw
        Write-Host "  SFTP chroot configured    " -NoNewline
        if ($content -match [regex]::Escape("Match Group $sftpGroup")) {
            Write-Host "PASS" -ForegroundColor Green
        }
        else {
            Write-Host "FAIL (no Match block)" -ForegroundColor Red
        }
    }

    # Check sshd running
    Write-Host "  sshd service running      " -NoNewline
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { Write-Host "PASS" -ForegroundColor Green }
    else { Write-Host "FAIL" -ForegroundColor Red }

    Write-Host ""
    Pause-Menu
}

function Show-SFTPMenu {
    while ($true) {
        $choice = Select-MenuOption -Title "SFTP Configuration" -Items @(
            @{ Key = "1"; Label = "Configure SFTP Chroot Jail" }
            @{ Key = "2"; Label = "View sshd_config" }
            @{ Key = "3"; Label = "Test SFTP Access for User" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back to Main Menu" }
        )
        switch ($choice) {
            "1" { Set-SFTPChrootConfig }
            "2" { Show-SSHDConfig }
            "3" { Test-SFTPAccess }
            "B" { return }
        }
    }
}

Export-ModuleMember -Function *
