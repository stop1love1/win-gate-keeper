# ============================================================================
# WinGateKeeper - System Status Overview Module
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force
Import-Module "$PSScriptRoot\DirectorySetup.psm1" -Force
Import-Module "$PSScriptRoot\OpenSSHSetup.psm1" -Force
Import-Module "$PSScriptRoot\SFTPConfig.psm1" -Force
Import-Module "$PSScriptRoot\AuditLogging.psm1" -Force
Import-Module "$PSScriptRoot\SSHHardening.psm1" -Force

function Show-SystemOverview {
    Write-MenuHeader "WinGateKeeper System Overview"

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }
    $allGood = $true

    # System Information
    Write-Host ""
    Write-Host "  System Information:" -ForegroundColor White
    Write-Host ("  " + "=" * 50) -ForegroundColor DarkCyan
    Write-Host "  Hostname:    $($env:COMPUTERNAME)" -ForegroundColor Cyan
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        Write-Host "  OS:          $($os.Caption) ($($os.Version))" -ForegroundColor Cyan
    }
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } |
        Select-Object -ExpandProperty IPAddress)
    if ($ips) {
        Write-Host "  IP Address:  $($ips -join ', ')" -ForegroundColor Cyan
    }
    Write-Host "  Date/Time:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "  Component                        Status" -ForegroundColor White
    Write-Host ("  " + "=" * 50) -ForegroundColor DarkCyan

    # 1. OpenSSH Server
    $sshInstalled = $false
    $sshRunning = $false
    $cap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "OpenSSH.Server*" }
    if ($cap -and $cap.State -eq "Installed") { $sshInstalled = $true }
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { $sshRunning = $true }

    Write-Host "  OpenSSH Server                   " -NoNewline
    if ($sshInstalled -and $sshRunning) {
        Write-Host "OK" -ForegroundColor Green
    }
    elseif ($sshInstalled) {
        Write-Host "INSTALLED (not running)" -ForegroundColor Yellow
        $allGood = $false
    }
    else {
        Write-Host "NOT INSTALLED" -ForegroundColor Red
        $allGood = $false
    }

    # 2. Base directories
    Write-Host "  Base Directories                 " -NoNewline
    if ((Test-Path $settings.BasePath) -and (Test-Path $settings.UsersRoot)) {
        Write-Host "OK" -ForegroundColor Green
    }
    else {
        Write-Host "MISSING" -ForegroundColor Red
        $allGood = $false
    }

    # 3. SFTP group
    $sftpGroup = Get-LocalGroup -Name $settings.SFTPOnlyGroup -ErrorAction SilentlyContinue
    Write-Host "  SFTP Group ($($settings.SFTPOnlyGroup))          " -NoNewline
    if ($sftpGroup) {
        $memberCount = @(Get-LocalGroupMember -Group $settings.SFTPOnlyGroup -ErrorAction SilentlyContinue).Count
        Write-Host "OK ($memberCount members)" -ForegroundColor Green
    }
    else {
        Write-Host "NOT CREATED" -ForegroundColor Yellow
        $allGood = $false
    }

    # 4. SFTP chroot config
    Write-Host "  SFTP Chroot Config               " -NoNewline
    if (Test-Path $settings.SSHConfigPath) {
        $config = Get-Content $settings.SSHConfigPath -Raw -ErrorAction SilentlyContinue
        if ($config -match [regex]::Escape("Match Group $($settings.SFTPOnlyGroup)")) {
            Write-Host "OK" -ForegroundColor Green
        }
        else {
            Write-Host "NOT CONFIGURED" -ForegroundColor Yellow
            $allGood = $false
        }
    }
    else {
        Write-Host "NO sshd_config" -ForegroundColor Red
        $allGood = $false
    }

    # 5. Audit policies
    Write-Host "  File Audit Policy                " -NoNewline
    $auditCheck = auditpol /get /subcategory:"File System" 2>&1
    if ($auditCheck -and ($auditCheck -join " ") -match "Success") {
        Write-Host "OK" -ForegroundColor Green
    }
    else {
        Write-Host "NOT ENABLED" -ForegroundColor Yellow
        $allGood = $false
    }

    # 6. PowerShell logging
    Write-Host "  PowerShell Logging               " -NoNewline
    $sbLog = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -ErrorAction SilentlyContinue
    if ($sbLog -and $sbLog.EnableScriptBlockLogging -eq 1) {
        Write-Host "OK" -ForegroundColor Green
    }
    else {
        Write-Host "NOT ENABLED" -ForegroundColor Yellow
        $allGood = $false
    }

    # 7. Hyper-V
    Write-Host "  Hyper-V Role                     " -NoNewline
    $hvFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
    if ($hvFeature -and $hvFeature.State -eq 'Enabled') {
        $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if ($vmms -and $vmms.Status -eq 'Running') {
            $hvVMs = @(Get-VM -ErrorAction SilentlyContinue)
            $vmCount = $hvVMs.Count
            $runningCount = @($hvVMs | Where-Object State -eq 'Running').Count
            Write-Host "OK ($runningCount running / $vmCount total)" -ForegroundColor Green
        }
        else {
            Write-Host "INSTALLED (vmms not running)" -ForegroundColor Yellow
            $allGood = $false
        }
    }
    else {
        Write-Host "NOT INSTALLED" -ForegroundColor DarkGray
    }

    # 8. User count
    $builtIn = @("Administrator", "DefaultAccount", "Guest", "WDAGUtilityAccount")
    $userCount = @(Get-LocalUser | Where-Object { $_.Name -notin $builtIn }).Count
    Write-Host ""
    Write-Host "  Managed Users: $userCount" -ForegroundColor Cyan

    # User directory count
    if (Test-Path $settings.UsersRoot) {
        $dirCount = @(Get-ChildItem -Path $settings.UsersRoot -Directory -ErrorAction SilentlyContinue).Count
        Write-Host "  User Directories: $dirCount" -ForegroundColor Cyan
    }

    # 8. Active SSH sessions
    Write-Host ""
    Write-Host "  Active SSH Sessions:" -ForegroundColor White
    Write-Host ("  " + "-" * 50) -ForegroundColor DarkCyan
    $sshSessions = @(Get-Process -Name sshd -ErrorAction SilentlyContinue)
    # First sshd is the listener, the rest are session processes
    $sessionCount = if ($sshSessions.Count -gt 1) { $sshSessions.Count - 1 } else { 0 }
    if ($sessionCount -gt 0) {
        Write-Host "  Active connections: $sessionCount" -ForegroundColor Yellow
        # Show logged-in users via query (not available on Server Core)
        $quser = if (Get-Command quser -ErrorAction SilentlyContinue) { quser 2>&1 | Where-Object { $_ -is [string] } } else { $null }
        if ($quser) {
            foreach ($line in ($quser | Select-Object -Skip 1)) {
                $trimmed = $line.Trim()
                if ($trimmed) {
                    Write-Host "    $trimmed" -ForegroundColor White
                }
            }
        }
    }
    else {
        Write-Host "  No active SSH sessions." -ForegroundColor DarkGray
    }

    # Overall status
    Write-Host ""
    Write-Host ("  " + "=" * 50) -ForegroundColor DarkCyan
    if ($allGood) {
        Write-Step "All systems operational." -Type Success
    }
    else {
        Write-Step "Some components need attention. Use the setup menus to configure." -Type Warning
    }

    Write-Host ""
    Pause-Menu
}

function Start-QuickSetup {
    Write-MenuHeader "Quick Setup Wizard"
    Write-Host ""
    Write-Step "This wizard will run all setup steps in sequence:" -Type Info
    Write-Host ""
    Write-Host "  Step 1: Initialize base directories" -ForegroundColor White
    Write-Host "  Step 2: Install & configure OpenSSH Server" -ForegroundColor White
    Write-Host "  Step 3: Configure SFTP chroot jail" -ForegroundColor White
    Write-Host "  Step 4: Apply SSH security hardening" -ForegroundColor White
    Write-Host "  Step 5: Enable audit policies" -ForegroundColor White
    Write-Host "  Step 6: Enable PowerShell logging" -ForegroundColor White
    Write-Host "  Step 7: Enable directory auditing" -ForegroundColor White

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    if (-not (Confirm-Action "Proceed with Quick Setup?")) {
        Write-Step "Setup cancelled." -Type Warning
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host ("  " + "=" * 50) -ForegroundColor DarkCyan

    # Step 1: Initialize directories
    Write-Host ""
    Write-Step "STEP 1/7: Initializing directories..." -Type Info
    try {
        Initialize-BaseDirectoriesCore -Settings $settings
        Write-Step "Directories initialized." -Type Success
    }
    catch {
        Write-Step "Failed to initialize directories: $_" -Type Error
    }

    # Step 2: Install & configure OpenSSH
    Write-Host ""
    Write-Step "STEP 2/7: Installing OpenSSH Server..." -Type Info
    try {
        Install-OpenSSHServerCore -Settings $settings
        Write-Step "OpenSSH Server configured." -Type Success
    }
    catch {
        Write-Step "Failed to configure OpenSSH: $_" -Type Error
    }

    # Step 3: Configure SFTP chroot
    Write-Host ""
    Write-Step "STEP 3/7: Configuring SFTP chroot..." -Type Info
    try {
        Set-SFTPChrootConfigCore -Settings $settings
        Write-Step "SFTP chroot configured." -Type Success
    }
    catch {
        Write-Step "Failed to configure SFTP chroot: $_" -Type Error
    }

    # Step 4: Apply SSH hardening
    Write-Host ""
    Write-Step "STEP 4/7: Applying SSH security hardening..." -Type Info
    try {
        $sshdConfig = $settings.SSHConfigPath
        if (Test-Path $sshdConfig) {
            $content = Get-Content $sshdConfig -Raw
            $content = Set-SSHHardening -Settings $settings -ConfigContent $content
            [System.IO.File]::WriteAllText($sshdConfig, $content, [System.Text.UTF8Encoding]::new($false))

            # Create login banner if configured
            $ssh = $settings.SSHSecurity
            if ($ssh -and $ssh.LoginBanner) {
                $bannerPath = if ($ssh.BannerPath) { $ssh.BannerPath } else { "C:\ProgramData\ssh\banner.txt" }
                if (-not (Test-Path $bannerPath)) {
                    $hostname = $env:COMPUTERNAME
                    $defaultBanner = "========================================================================`r`nAUTHORIZED ACCESS ONLY - All activities are logged and monitored.`r`nServer: $hostname`r`n========================================================================"
                    $bannerDir = Split-Path $bannerPath -Parent
                    if (-not (Test-Path $bannerDir)) { New-Item -ItemType Directory -Path $bannerDir -Force | Out-Null }
                    [System.IO.File]::WriteAllText($bannerPath, $defaultBanner, [System.Text.UTF8Encoding]::new($false))
                }
            }

            Restart-SSHDService | Out-Null
            Write-Step "SSH hardening applied." -Type Success
        }
        else {
            Write-Step "sshd_config not found, skipping hardening." -Type Warning
        }
    }
    catch {
        Write-Step "Failed to apply SSH hardening: $_" -Type Error
    }

    # Step 5: Enable audit policies
    Write-Host ""
    Write-Step "STEP 5/7: Enabling audit policies..." -Type Info
    try {
        Enable-FileAuditCore
        Write-Step "Audit policies enabled." -Type Success
    }
    catch {
        Write-Step "Failed to enable audit policies: $_" -Type Error
    }

    # Step 6: Enable PowerShell logging
    Write-Host ""
    Write-Step "STEP 6/7: Enabling PowerShell logging..." -Type Info
    try {
        Enable-PowerShellLoggingCore -Settings $settings
        Write-Step "PowerShell logging enabled." -Type Success
    }
    catch {
        Write-Step "Failed to enable PowerShell logging: $_" -Type Error
    }

    # Step 7: Enable directory auditing
    Write-Host ""
    Write-Step "STEP 7/7: Enabling directory auditing..." -Type Info
    try {
        Enable-DirectoryAuditCore -Settings $settings
        Write-Step "Directory auditing enabled." -Type Success
    }
    catch {
        Write-Step "Failed to enable directory auditing: $_" -Type Error
    }

    Write-Log "Quick Setup completed successfully."

    Write-Host ""
    Write-Host ("  " + "=" * 50) -ForegroundColor DarkCyan
    Write-Step "Quick Setup complete! All components configured." -Type Success

    # Show server connection info
    $port = if ($settings.SSHPort) { $settings.SSHPort } else { 22 }
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } |
        Select-Object -ExpandProperty IPAddress)

    Write-Host ""
    Write-Host "  SSH Server is ready!" -ForegroundColor Green
    Write-Host ("  " + "-" * 50) -ForegroundColor DarkGray
    Write-Host "  Hostname:  $($env:COMPUTERNAME)" -ForegroundColor Cyan
    if ($ips.Count -gt 0) {
        Write-Host "  IP:        $($ips -join ', ')" -ForegroundColor Cyan
    }
    Write-Host "  SSH Port:  $port" -ForegroundColor Cyan
    Write-Host ""
    Write-Step "Next step: Go to [2] User Management to create users." -Type Info

    Write-Host ""
    Pause-Menu
}

# ============================================================================
# Core functions (non-interactive, called by Quick Setup and menu wrappers)
# ============================================================================

function Initialize-BaseDirectoriesCore {
    param([PSCustomObject]$Settings)

    $dirs = @(
        $Settings.BasePath,
        $Settings.UsersRoot,
        $Settings.LogsPath,
        $Settings.PowerShellLogging.TranscriptionPath
    )

    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Step "Created: $dir" -Type Success
        }
        else {
            Write-Step "Exists: $dir" -Type Info
        }
    }

    # Set base path ACLs (Admins + SYSTEM only)
    $acl = New-AdminSystemAcl -Path $Settings.BasePath
    Set-Acl -Path $Settings.BasePath -AclObject $acl

    # Users root ACLs (Admins + SYSTEM + Users Traverse)
    $uAcl = New-AdminSystemAcl -Path $Settings.UsersRoot
    $usersTraverseRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Users", "Traverse", "None", "None", "Allow"
    )
    $uAcl.AddAccessRule($usersTraverseRule)
    Set-Acl -Path $Settings.UsersRoot -AclObject $uAcl
}

function Install-OpenSSHServerCore {
    param([PSCustomObject]$Settings = $null)

    $capability = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "OpenSSH.Server*" }
    if ($capability -and $capability.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
        Write-Step "OpenSSH Server installed." -Type Success
    }
    elseif ($capability) {
        Write-Step "OpenSSH Server already installed." -Type Info
    }
    else {
        # Fallback: check manual install (Server 2016)
        $sshdExe = Get-Command sshd.exe -ErrorAction SilentlyContinue
        if ($sshdExe) {
            Write-Step "OpenSSH Server detected (manual install)." -Type Info
        }
        else {
            Write-Step "OpenSSH Server not found. Install manually on Server 2016." -Type Warning
            return
        }
    }

    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd -ErrorAction SilentlyContinue
    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service ssh-agent -ErrorAction SilentlyContinue

    $sshPort = if ($Settings -and $Settings.SSHPort) { $Settings.SSHPort } else { 22 }
    $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $sshPort | Out-Null
    }
}

function Set-SFTPChrootConfigCore {
    param([PSCustomObject]$Settings)

    $sftpGroup = $Settings.SFTPOnlyGroup

    # Ensure SFTP group exists
    $group = Get-LocalGroup -Name $sftpGroup -ErrorAction SilentlyContinue
    if (-not $group) {
        New-LocalGroup -Name $sftpGroup -Description "SFTP-only access users" | Out-Null
        Write-Step "Created group '$sftpGroup'." -Type Success
    }

    $sshdConfig = $Settings.SSHConfigPath
    if (-not (Test-Path $sshdConfig)) {
        Write-Step "sshd_config not found. Skipping chroot config." -Type Warning
        return
    }

    $backupPath = "$sshdConfig.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item -Path $sshdConfig -Destination $backupPath

    $content = Get-Content $sshdConfig -Raw
    if ($content -notmatch [regex]::Escape("Match Group $sftpGroup")) {
        $matchBlock = @"

# BEGIN WinGateKeeper SFTP Configuration
Match Group $sftpGroup
    ForceCommand internal-sftp
    ChrootDirectory $($Settings.UsersRoot)
    PermitTunnel no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
# END WinGateKeeper SFTP Configuration
"@
        $content = $content.TrimEnd() + "`r`n" + $matchBlock + "`r`n"

        # Validate before applying
        $tempConfig = "$sshdConfig.tmp"
        [System.IO.File]::WriteAllText($tempConfig, $content, [System.Text.UTF8Encoding]::new($false))
        $sshdExe = Get-Command sshd.exe -ErrorAction SilentlyContinue
        if ($sshdExe) {
            $testResult = & sshd.exe -t -f $tempConfig 2>&1
            if ($LASTEXITCODE -ne 0) {
                Copy-Item -Path $backupPath -Destination $sshdConfig -Force
                Remove-Item -Path $tempConfig -Force -ErrorAction SilentlyContinue
                throw "Invalid sshd_config syntax: $testResult"
            }
        }
        Move-Item -Path $tempConfig -Destination $sshdConfig -Force
        Restart-SSHDService | Out-Null
    }
    else {
        Write-Step "SFTP chroot already configured." -Type Info
    }
}

function Enable-FileAuditCore {
    # Use GUIDs for non-English OS compatibility
    auditpol /set /subcategory:"{0CCE921D-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable | Out-Null  # File System
    auditpol /set /subcategory:"{0CCE9215-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable | Out-Null  # Logon
    auditpol /set /subcategory:"{0CCE9216-69AE-11D9-BED3-505054503030}" /success:enable | Out-Null                  # Logoff
    auditpol /set /subcategory:"{0CCE9223-69AE-11D9-BED3-505054503030}" /success:enable | Out-Null                  # Handle Manipulation
    auditpol /set /subcategory:"{0CCE9224-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable | Out-Null  # File Share
}

function Enable-PowerShellLoggingCore {
    param([PSCustomObject]$Settings)

    $regPaths = @(
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames",
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription"
    )
    foreach ($rp in $regPaths) {
        if (-not (Test-Path $rp)) { New-Item -Path $rp -Force | Out-Null }
    }
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 1 -Type DWord
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" -Name "EnableModuleLogging" -Value 1 -Type DWord
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames" -Name "*" -Value "*" -Type String
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription" -Name "EnableTranscripting" -Value 1 -Type DWord
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription" -Name "EnableInvocationHeader" -Value 1 -Type DWord

    $transcriptPath = $Settings.PowerShellLogging.TranscriptionPath
    if (-not (Test-Path $transcriptPath)) {
        New-Item -ItemType Directory -Path $transcriptPath -Force | Out-Null
    }
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription" -Name "OutputDirectory" -Value $transcriptPath -Type String
}

function Enable-DirectoryAuditCore {
    param([PSCustomObject]$Settings)

    $usersRoot = $Settings.UsersRoot
    if (-not (Test-Path $usersRoot)) { return }

    $auditRule = New-Object System.Security.AccessControl.FileSystemAuditRule(
        "Everyone",
        "Modify, Delete, Write",
        "ContainerInherit, ObjectInherit",
        "None",
        "Success, Failure"
    )

    $acl = Get-Acl $usersRoot
    $existingRules = $acl.GetAuditRules($true, $false, [System.Security.Principal.NTAccount])
    $alreadyExists = $existingRules | Where-Object {
        $_.IdentityReference.Value -eq "Everyone" -and
        ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Modify)
    }
    if (-not $alreadyExists) {
        $acl.AddAuditRule($auditRule)
        Set-Acl -Path $usersRoot -AclObject $acl
    }

    # Apply audit rules to existing subdirectories (inheritance may be blocked)
    $userDirs = Get-ChildItem -Path $usersRoot -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $userDirs) {
        $dAcl = Get-Acl $dir.FullName
        $dExisting = $dAcl.GetAuditRules($true, $false, [System.Security.Principal.NTAccount])
        $dHasRule = $dExisting | Where-Object {
            $_.IdentityReference.Value -eq "Everyone" -and
            ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Modify)
        }
        if (-not $dHasRule) {
            $dAcl.AddAuditRule($auditRule)
            Set-Acl -Path $dir.FullName -AclObject $dAcl
        }
    }
}

Export-ModuleMember -Function *
