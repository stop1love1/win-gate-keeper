# ============================================================================
# WinGateKeeper - System Status Overview Module
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force
Import-Module "$PSScriptRoot\DirectorySetup.psm1" -Force
Import-Module "$PSScriptRoot\OpenSSHSetup.psm1" -Force
Import-Module "$PSScriptRoot\SFTPConfig.psm1" -Force
Import-Module "$PSScriptRoot\AuditLogging.psm1" -Force

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
    $auditCheck = auditpol /get /subcategory:"File System" 2>$null
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

    # 7. User count
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
        # Show logged-in users via query
        $quser = quser 2>$null
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
    Write-Host "  Step 4: Enable audit policies" -ForegroundColor White
    Write-Host "  Step 5: Enable PowerShell logging" -ForegroundColor White
    Write-Host "  Step 6: Enable directory auditing" -ForegroundColor White

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
    Write-Step "STEP 1/6: Initializing directories..." -Type Info
    try {
        Initialize-BaseDirectoriesCore -Settings $settings
        Write-Step "Directories initialized." -Type Success
    }
    catch {
        Write-Step "Failed to initialize directories: $_" -Type Error
    }

    # Step 2: Install & configure OpenSSH
    Write-Host ""
    Write-Step "STEP 2/6: Installing OpenSSH Server..." -Type Info
    try {
        Install-OpenSSHServerCore -Settings $settings
        Write-Step "OpenSSH Server configured." -Type Success
    }
    catch {
        Write-Step "Failed to configure OpenSSH: $_" -Type Error
    }

    # Step 3: Configure SFTP chroot
    Write-Host ""
    Write-Step "STEP 3/6: Configuring SFTP chroot..." -Type Info
    try {
        Set-SFTPChrootConfigCore -Settings $settings
        Write-Step "SFTP chroot configured." -Type Success
    }
    catch {
        Write-Step "Failed to configure SFTP chroot: $_" -Type Error
    }

    # Step 4: Enable audit policies
    Write-Host ""
    Write-Step "STEP 4/6: Enabling audit policies..." -Type Info
    try {
        Enable-FileAuditCore
        Write-Step "Audit policies enabled." -Type Success
    }
    catch {
        Write-Step "Failed to enable audit policies: $_" -Type Error
    }

    # Step 5: Enable PowerShell logging
    Write-Host ""
    Write-Step "STEP 5/6: Enabling PowerShell logging..." -Type Info
    try {
        Enable-PowerShellLoggingCore -Settings $settings
        Write-Step "PowerShell logging enabled." -Type Success
    }
    catch {
        Write-Step "Failed to enable PowerShell logging: $_" -Type Error
    }

    # Step 6: Enable directory auditing
    Write-Host ""
    Write-Step "STEP 6/6: Enabling directory auditing..." -Type Info
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

    # Set base path ACLs
    $acl = Get-Acl $Settings.BasePath
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
    Set-Acl -Path $Settings.BasePath -AclObject $acl

    # Users root ACLs
    $uAcl = Get-Acl $Settings.UsersRoot
    $uAcl.SetAccessRuleProtection($true, $false)
    $uAcl.Access | ForEach-Object { $uAcl.RemoveAccessRule($_) } | Out-Null
    $uAcl.AddAccessRule($adminRule)
    $uAcl.AddAccessRule($systemRule)
    $usersReadRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Users", "ReadAndExecute", "None", "None", "Allow"
    )
    $uAcl.AddAccessRule($usersReadRule)
    Set-Acl -Path $Settings.UsersRoot -AclObject $uAcl
}

function Install-OpenSSHServerCore {
    param([PSCustomObject]$Settings = $null)

    $capability = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "OpenSSH.Server*" }
    if (-not $capability) {
        throw "OpenSSH Server capability not found on this system."
    }

    if ($capability.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
        Write-Step "OpenSSH Server installed." -Type Success
    }
    else {
        Write-Step "OpenSSH Server already installed." -Type Info
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
        Set-Content -Path $tempConfig -Value $content -Encoding UTF8
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
        Restart-Service sshd -Force
    }
    else {
        Write-Step "SFTP chroot already configured." -Type Info
    }
}

function Enable-FileAuditCore {
    auditpol /set /subcategory:"File System" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"Logon" /success:enable /failure:enable | Out-Null
    auditpol /set /subcategory:"Logoff" /success:enable | Out-Null
    auditpol /set /subcategory:"Handle Manipulation" /success:enable | Out-Null
    auditpol /set /subcategory:"File Share" /success:enable /failure:enable | Out-Null
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
}

Export-ModuleMember -Function *
