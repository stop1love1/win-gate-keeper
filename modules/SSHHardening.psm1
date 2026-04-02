# ============================================================================
# WinGateKeeper - SSH Security Hardening Module
# Handles: sshd_config hardening, login banner, IP restriction, session mgmt
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

function Set-SSHHardening {
    param(
        [PSCustomObject]$Settings,
        [string]$ConfigContent
    )

    $ssh = $Settings.SSHSecurity
    if (-not $ssh) { return $ConfigContent }

    # Sync SSH port from settings to sshd_config
    $sshPort = if ($Settings.SSHPort) { $Settings.SSHPort } else { 22 }

    # Build hardening directives
    $directives = @{
        "Port"                 = $sshPort
        "MaxAuthTries"         = if ($ssh.MaxAuthTries) { $ssh.MaxAuthTries } else { 3 }
        "MaxStartups"          = if ($ssh.MaxStartups) { $ssh.MaxStartups } else { "3:50:10" }
        "ClientAliveInterval"  = if ($ssh.ClientAliveInterval) { $ssh.ClientAliveInterval } else { 300 }
        "ClientAliveCountMax"  = if ($ssh.ClientAliveCountMax) { $ssh.ClientAliveCountMax } else { 2 }
        "LogLevel"             = "VERBOSE"
        "PermitRootLogin"      = "no"
        "PasswordAuthentication" = "yes"
        "PubkeyAuthentication" = "yes"
        "PermitEmptyPasswords" = "no"
        "AllowAgentForwarding" = "no"
        "AllowTcpForwarding"   = "no"
        "X11Forwarding"        = "no"
    }

    # Login banner
    if ($ssh.LoginBanner -or $ssh.BannerPath) {
        $bannerPath = if ($ssh.BannerPath) { $ssh.BannerPath } else { "C:\ProgramData\ssh\banner.txt" }
        $directives["Banner"] = $bannerPath
    }

    foreach ($key in $directives.Keys) {
        $value = $directives[$key]
        # Check if directive already exists (uncommented)
        if ($ConfigContent -match "(?m)^\s*$key\s") {
            $ConfigContent = $ConfigContent -replace "(?m)^\s*$key\s+.*$", "$key $value"
        }
        # Check if directive exists but commented out
        elseif ($ConfigContent -match "(?m)^#\s*$key\s") {
            $ConfigContent = $ConfigContent -replace "(?m)^#\s*$key\s+.*$", "$key $value"
        }
        else {
            # Insert before any Match blocks
            if ($ConfigContent -match "(?m)^Match\s") {
                $ConfigContent = $ConfigContent -replace "(?m)(^Match\s)", "$key $value`r`n`r`n`$1"
            }
            else {
                $ConfigContent += "`r`n$key $value"
            }
        }
    }

    return $ConfigContent
}

function Set-LoginBanner {
    Write-MenuHeader "Configure Login Banner"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    $ssh = $settings.SSHSecurity
    $bannerPath = if ($ssh -and $ssh.BannerPath) { $ssh.BannerPath } else { "C:\ProgramData\ssh\banner.txt" }

    Write-Host ""
    Write-Host "  Banner file: $bannerPath" -ForegroundColor Cyan
    Write-Host ""

    if (Test-Path $bannerPath) {
        Write-Step "Current banner content:" -Type Info
        Write-Host ""
        Get-Content $bannerPath | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Write-Host ""
    }

    Write-MenuOption "1" "Set default banner (recommended)"
    Write-MenuOption "2" "Set custom banner text"
    Write-MenuOption "3" "Remove banner"
    Write-Separator
    Write-MenuOption "B" "Back"

    $choice = Read-MenuChoice

    switch ($choice) {
        "1" {
            $hostname = $env:COMPUTERNAME
            $defaultBanner = @"
========================================================================
                    AUTHORIZED ACCESS ONLY

  This system is the property of the system owner. Unauthorized access
  is prohibited. All activities on this system are logged and monitored.
  By connecting to this system, you consent to monitoring and recording
  of all your activities. Unauthorized use may result in criminal
  prosecution.

  Server: $hostname
========================================================================
"@
            $bannerDir = Split-Path $bannerPath -Parent
            if (-not (Test-Path $bannerDir)) { New-Item -ItemType Directory -Path $bannerDir -Force | Out-Null }
            [System.IO.File]::WriteAllText($bannerPath, $defaultBanner, [System.Text.UTF8Encoding]::new($false))
            Write-Step "Default banner created at: $bannerPath" -Type Success
            Write-Log "Login banner created."
        }
        "2" {
            Write-Host "  Enter banner text (type 'END' on a new line to finish):" -ForegroundColor White
            $bannerLines = @()
            while ($true) {
                $line = Read-Host
                if ($line -eq "END") { break }
                $bannerLines += $line
            }
            if ($bannerLines.Count -gt 0) {
                $bannerDir = Split-Path $bannerPath -Parent
                if (-not (Test-Path $bannerDir)) { New-Item -ItemType Directory -Path $bannerDir -Force | Out-Null }
                [System.IO.File]::WriteAllText($bannerPath, ($bannerLines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
                Write-Step "Custom banner saved." -Type Success
            }
        }
        "3" {
            if (Test-Path $bannerPath) {
                Remove-Item $bannerPath -Force
                Write-Step "Banner file removed." -Type Success
            }
        }
        "B" { return }
    }

    Pause-Menu
}

function Set-IPRestriction {
    Write-MenuHeader "Configure IP Access Restriction"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    $ssh = $settings.SSHSecurity
    $currentIPs = if ($ssh -and $ssh.AllowedIPs) { $ssh.AllowedIPs } else { "*" }

    Write-Host ""
    Write-Host "  Current allowed IPs: " -ForegroundColor White -NoNewline
    if ($currentIPs -eq "*") {
        Write-Host "$currentIPs (all IPs allowed)" -ForegroundColor Yellow
    }
    else {
        Write-Host "$currentIPs" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-MenuOption "1" "Allow all IPs (*)"
    Write-MenuOption "2" "Restrict to specific IPs"
    Write-MenuOption "3" "View current firewall rule"
    Write-Separator
    Write-MenuOption "B" "Back"

    $choice = Read-MenuChoice

    switch ($choice) {
        "1" {
            Update-FirewallIPRestriction -AllowedIPs "*" -Port $settings.SSHPort
            Update-SettingsField -FieldPath "SSHSecurity.AllowedIPs" -Value "*"
            Write-Step "SSH access opened to all IPs." -Type Success
            Write-Log "IP restriction removed (allow all)."
            Pause-Menu
        }
        "2" {
            Write-Host ""
            Write-Host "  Enter allowed IPs (comma-separated):" -ForegroundColor White
            Write-Host "  Example: 192.168.1.0/24, 10.0.0.5, 172.16.0.0/16" -ForegroundColor DarkGray
            Write-Host "  > " -NoNewline
            $ips = (Read-Host).Trim()
            if ($ips) {
                $ipList = $ips -split "\s*,\s*"
                Update-FirewallIPRestriction -AllowedIPs $ipList -Port $settings.SSHPort
                Update-SettingsField -FieldPath "SSHSecurity.AllowedIPs" -Value $ips
                Write-Step "SSH access restricted to: $ips" -Type Success
                Write-Log "IP restriction set: $ips"
            }
            Pause-Menu
        }
        "3" {
            $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
            if ($rule) {
                $filter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule
                Write-Host ""
                Write-Host "  Firewall Rule: OpenSSH-Server-In-TCP" -ForegroundColor White
                Write-Host "  Enabled:       $($rule.Enabled)" -ForegroundColor Cyan
                Write-Host "  Direction:     $($rule.Direction)" -ForegroundColor Cyan
                Write-Host "  Remote IPs:    $($filter.RemoteAddress -join ', ')" -ForegroundColor Cyan
            }
            else {
                Write-Step "No SSH firewall rule found." -Type Warning
            }
            Pause-Menu
        }
        "B" { return }
    }
}

function Update-FirewallIPRestriction {
    param(
        [string[]]$AllowedIPs,
        [int]$Port = 22
    )

    $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if ($AllowedIPs -eq "*" -or $AllowedIPs -contains "*") {
        if ($rule) {
            Set-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -RemoteAddress Any
        }
        else {
            New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $Port | Out-Null
        }
    }
    else {
        if ($rule) {
            Set-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -RemoteAddress $AllowedIPs
        }
        else {
            New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
                -LocalPort $Port -RemoteAddress $AllowedIPs | Out-Null
        }
    }
}

function Update-SettingsField {
    param(
        [string]$FieldPath,
        $Value  # Untyped — preserves int, bool, string as-is in JSON
    )
    $settingsPath = Join-Path $PSScriptRoot "..\config\settings.json"
    if (-not (Test-Path $settingsPath)) {
        Write-Step "Settings file not found." -Type Error
        return
    }
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $parts = $FieldPath -split "\."

    # Navigate to the parent object for arbitrary nesting depth
    $current = $settings
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $next = $current.($parts[$i])
        if ($null -eq $next) {
            Write-Step "Settings path '$FieldPath' not found at '$($parts[$i])'." -Type Error
            return
        }
        $current = $next
    }
    $current.($parts[-1]) = $Value

    [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
}

function Show-ActiveSessions {
    Write-MenuHeader "Active SSH Sessions"

    Write-Host ""
    Write-Host "  Detecting SSH sessions..." -ForegroundColor White
    Write-Host ""

    # Get sshd child processes (each represents a session)
    $sshdProcesses = @(Get-Process -Name sshd -ErrorAction SilentlyContinue)

    if ($sshdProcesses.Count -le 1) {
        Write-Step "No active SSH sessions." -Type Info
        Pause-Menu
        return
    }

    # Identify the listener PID via the process listening on the SSH port
    $settings = Get-Settings
    $sshPort = if ($settings -and $settings.SSHPort) { $settings.SSHPort } else { 22 }
    $listenerPid = $null
    try {
        $listener = Get-NetTCPConnection -LocalPort $sshPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listener) { $listenerPid = $listener.OwningProcess }
    }
    catch {}
    # Fallback: if we couldn't find via port, skip the oldest process
    if (-not $listenerPid) {
        $listenerPid = ($sshdProcesses | Sort-Object StartTime | Select-Object -First 1).Id
    }

    Write-Host "  PID       Started              Memory" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray

    $sessionProcs = @()
    foreach ($proc in $sshdProcesses) {
        if ($proc.Id -eq $listenerPid) { continue }
        $sessionProcs += $proc
        $mem = "{0:N1} MB" -f ($proc.WorkingSet64 / 1MB)
        $started = if ($proc.StartTime) { $proc.StartTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Unknown" }
        Write-Host "  $($proc.Id.ToString().PadRight(10))$($started.PadRight(22))$mem" -ForegroundColor Cyan
    }

    # Also try to detect which users have active network connections on SSH port
    Write-Host ""
    Write-Host "  Network Connections (SSH port):" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray

    $settings = Get-Settings
    $port = if ($settings -and $settings.SSHPort) { $settings.SSHPort } else { 22 }
    $connections = Get-NetTCPConnection -LocalPort $port -State Established -ErrorAction SilentlyContinue
    if ($connections) {
        foreach ($conn in $connections) {
            Write-Host "  $($conn.RemoteAddress):$($conn.RemotePort)" -ForegroundColor Cyan -NoNewline
            Write-Host " -> PID $($conn.OwningProcess)" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "  (no established connections)" -ForegroundColor DarkGray
    }

    Write-Host ""
}

function Disconnect-SSHSession {
    Write-MenuHeader "Force Disconnect SSH Session"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    Show-ActiveSessions

    Write-Host ""
    Write-Host "  Enter PID to disconnect (0 to cancel): " -ForegroundColor White -NoNewline
    $pidStr = (Read-Host).Trim()

    if (-not $pidStr -or $pidStr -eq "0") {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    $targetPid = 0
    if (-not [int]::TryParse($pidStr, [ref]$targetPid)) {
        Write-Step "Invalid PID." -Type Error
        Pause-Menu
        return
    }

    $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.Name -ne "sshd") {
        Write-Step "PID $targetPid is not an sshd process." -Type Error
        Pause-Menu
        return
    }

    # Prevent killing the listener process
    $settings = Get-Settings
    $sshPort = if ($settings -and $settings.SSHPort) { $settings.SSHPort } else { 22 }
    $listener = Get-NetTCPConnection -LocalPort $sshPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($listener -and $listener.OwningProcess -eq $targetPid) {
        Write-Step "PID $targetPid is the SSH listener! Killing it would stop ALL SSH access." -Type Error
        Pause-Menu
        return
    }

    if (Confirm-Action "Force disconnect session PID $targetPid?") {
        try {
            Stop-Process -Id $targetPid -Force -ErrorAction Stop
            Write-Step "Session PID $targetPid terminated." -Type Success
            Write-Log "Force disconnected SSH session PID $targetPid."
        }
        catch {
            Write-Step "Failed to terminate process: $_" -Type Error
        }
    }

    Pause-Menu
}

function Show-SSHSecurityMenu {
    while ($true) {
        $choice = Select-MenuOption -Title "SSH Security & Sessions" -Items @(
            @{ Key = "1"; Label = "Apply SSH Hardening (sshd_config)" }
            @{ Key = "2"; Label = "Configure Login Banner" }
            @{ Key = "3"; Label = "Configure IP Restriction" }
            @{ Separator = $true }
            @{ Key = "4"; Label = "View Active Sessions" }
            @{ Key = "5"; Label = "Force Disconnect Session" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back to Main Menu" }
        )
        switch ($choice) {
            "1" { Invoke-ApplyHardening }
            "2" { Set-LoginBanner }
            "3" { Set-IPRestriction }
            "4" { Show-ActiveSessions; Pause-Menu }
            "5" { Disconnect-SSHSession }
            "B" { return }
        }
    }
}

function Invoke-ApplyHardening {
    Write-MenuHeader "Apply SSH Hardening"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }
    $sshdConfig = $settings.SSHConfigPath

    if (-not (Test-Path $sshdConfig)) {
        Write-Step "sshd_config not found. Install OpenSSH first." -Type Error
        Pause-Menu
        return
    }

    $ssh = $settings.SSHSecurity
    Write-Host ""
    Write-Host "  The following hardening will be applied:" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray
    Write-Host "  MaxAuthTries:          $(if ($ssh) { $ssh.MaxAuthTries } else { 3 })" -ForegroundColor Cyan
    Write-Host "  ClientAliveInterval:   $(if ($ssh) { $ssh.ClientAliveInterval } else { 300 })s" -ForegroundColor Cyan
    Write-Host "  ClientAliveCountMax:   $(if ($ssh) { $ssh.ClientAliveCountMax } else { 2 })" -ForegroundColor Cyan
    Write-Host "  PermitRootLogin:       no" -ForegroundColor Cyan
    Write-Host "  PermitEmptyPasswords:  no" -ForegroundColor Cyan
    Write-Host "  Login Banner:          $(if ($ssh -and $ssh.LoginBanner) { 'Yes' } else { 'No' })" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Confirm-Action "Apply SSH hardening?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    # Backup
    $backupPath = "$sshdConfig.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item -Path $sshdConfig -Destination $backupPath
    Write-Step "Backup saved: $backupPath" -Type Info

    # Create banner file if enabled
    if ($ssh -and $ssh.LoginBanner) {
        $bannerPath = if ($ssh.BannerPath) { $ssh.BannerPath } else { "C:\ProgramData\ssh\banner.txt" }
        if (-not (Test-Path $bannerPath)) {
            $hostname = $env:COMPUTERNAME
            $defaultBanner = @"
========================================================================
                    AUTHORIZED ACCESS ONLY

  This system is the property of the system owner. Unauthorized access
  is prohibited. All activities on this system are logged and monitored.
  Server: $hostname
========================================================================
"@
            $bannerDir = Split-Path $bannerPath -Parent
            if (-not (Test-Path $bannerDir)) { New-Item -ItemType Directory -Path $bannerDir -Force | Out-Null }
            [System.IO.File]::WriteAllText($bannerPath, $defaultBanner, [System.Text.UTF8Encoding]::new($false))
            Write-Step "Banner file created: $bannerPath" -Type Success
        }
    }

    # Apply hardening
    $content = Get-Content $sshdConfig -Raw
    $content = Set-SSHHardening -Settings $settings -ConfigContent $content

    # Validate
    $tempConfig = "$sshdConfig.tmp"
    [System.IO.File]::WriteAllText($tempConfig, $content, [System.Text.UTF8Encoding]::new($false))

    $sshdExe = Get-Command sshd.exe -ErrorAction SilentlyContinue
    if ($sshdExe) {
        $testResult = & sshd.exe -t -f $tempConfig 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Step "Invalid config! Restoring backup." -Type Error
            Write-Step "$testResult" -Type Error
            Copy-Item -Path $backupPath -Destination $sshdConfig -Force
            Remove-Item -Path $tempConfig -Force -ErrorAction SilentlyContinue
            Pause-Menu
            return
        }
    }

    Move-Item -Path $tempConfig -Destination $sshdConfig -Force
    Write-Step "Restarting sshd service..." -Type Info
    if (Restart-SSHDService) {
        Write-Step "SSH hardening applied and sshd restarted." -Type Success
    }
    Write-Log "SSH hardening applied."

    Pause-Menu
}

Export-ModuleMember -Function *
