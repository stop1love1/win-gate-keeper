# ============================================================================
# WinGateKeeper - OpenSSH Server Setup Module
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

function Test-OpenSSHInstalled {
    $sshServer = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "OpenSSH.Server*" }
    if ($sshServer -and $sshServer.State -eq "Installed") {
        return $true
    }
    return $false
}

function Test-OpenSSHRunning {
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq "Running") {
        return $true
    }
    return $false
}

function Install-OpenSSHServer {
    Write-MenuHeader "OpenSSH Server Installation"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    # Step 1: Check current status
    Write-Step "Checking OpenSSH Server status..." -Type Info
    $capability = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "OpenSSH.Server*" }

    if (-not $capability) {
        Write-Step "OpenSSH Server capability not found on this system." -Type Error
        Pause-Menu
        return
    }

    if ($capability.State -eq "Installed") {
        Write-Step "OpenSSH Server is already installed." -Type Success
    }
    else {
        Write-Step "Installing OpenSSH Server..." -Type Info
        try {
            Add-WindowsCapability -Online -Name $capability.Name
            Write-Step "OpenSSH Server installed successfully." -Type Success
            Write-Log "OpenSSH Server installed."
        }
        catch {
            Write-Step "Failed to install OpenSSH Server: $_" -Type Error
            Write-Log "OpenSSH Server installation failed: $_" -Level "ERROR"
            Pause-Menu
            return
        }
    }

    # Step 2: Install OpenSSH Client if missing
    Write-Step "Checking OpenSSH Client..." -Type Info
    $clientCap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "OpenSSH.Client*" }
    if (-not $clientCap) {
        Write-Step "OpenSSH Client capability not found. Skipping." -Type Warning
    }
    elseif ($clientCap.State -ne "Installed") {
        Write-Step "Installing OpenSSH Client..." -Type Info
        Add-WindowsCapability -Online -Name $clientCap.Name
        Write-Step "OpenSSH Client installed." -Type Success
    }
    else {
        Write-Step "OpenSSH Client already installed." -Type Success
    }

    # Step 3: Configure sshd service
    Write-Step "Configuring sshd service to start automatically..." -Type Info
    Set-Service -Name sshd -StartupType Automatic
    Write-Step "sshd service set to Automatic." -Type Success

    # Step 4: Start sshd service
    Write-Step "Starting sshd service..." -Type Info
    $service = Get-Service -Name sshd
    if ($service.Status -ne "Running") {
        Start-Service sshd
        Write-Step "sshd service started." -Type Success
    }
    else {
        Write-Step "sshd service is already running." -Type Success
    }

    # Step 5: Configure ssh-agent
    Write-Step "Configuring ssh-agent service..." -Type Info
    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service ssh-agent -ErrorAction SilentlyContinue
    Write-Step "ssh-agent configured and started." -Type Success

    # Step 6: Firewall rule
    $settings = Get-Settings
    $sshPort = if ($settings -and $settings.SSHPort) { $settings.SSHPort } else { 22 }
    Write-Step "Checking firewall rule for SSH (port $sshPort)..." -Type Info
    $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
            -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -Action Allow `
            -LocalPort $sshPort
        Write-Step "Firewall rule created for port $sshPort." -Type Success
    }
    else {
        Write-Step "Firewall rule already exists." -Type Success
    }

    Write-Log "OpenSSH Server setup completed."
    Write-Host ""
    Write-Step "OpenSSH Server setup complete!" -Type Success
    Pause-Menu
}

function Set-DefaultShell {
    Write-MenuHeader "Configure Default Shell"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    Write-Host ""
    Write-MenuOption "1" "PowerShell (powershell.exe)"
    Write-MenuOption "2" "PowerShell 7 (pwsh.exe)"
    Write-MenuOption "3" "Command Prompt (cmd.exe)"

    $choice = Read-MenuChoice "Select default shell"

    $shellPath = switch ($choice) {
        "1" { "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" }
        "2" { "C:\Program Files\PowerShell\7\pwsh.exe" }
        "3" { "C:\Windows\System32\cmd.exe" }
        default {
            Write-Step "Invalid selection." -Type Error
            Pause-Menu
            return
        }
    }

    if (-not (Test-Path $shellPath)) {
        Write-Step "Shell not found at: $shellPath" -Type Error
        Pause-Menu
        return
    }

    $regPath = "HKLM:\SOFTWARE\OpenSSH"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name DefaultShell -Value $shellPath -PropertyType String -Force | Out-Null
    Write-Step "Default shell set to: $shellPath" -Type Success
    Write-Log "Default SSH shell changed to: $shellPath"
    Pause-Menu
}

function Show-OpenSSHStatus {
    Write-MenuHeader "OpenSSH Server Status"

    $installed = Test-OpenSSHInstalled
    $running = Test-OpenSSHRunning

    Write-Host ""
    Write-Host "  Component            Status" -ForegroundColor White
    Write-Separator

    Write-Host "  OpenSSH Server       " -NoNewline
    if ($installed) { Write-Host "Installed" -ForegroundColor Green }
    else { Write-Host "Not Installed" -ForegroundColor Red }

    Write-Host "  sshd Service         " -NoNewline
    if ($running) { Write-Host "Running" -ForegroundColor Green }
    else { Write-Host "Stopped" -ForegroundColor Red }

    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($service) {
        Write-Host "  Startup Type         " -NoNewline
        Write-Host "$($service.StartType)" -ForegroundColor White
    }

    # Check firewall
    $fwRule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    Write-Host "  Firewall Rule        " -NoNewline
    if ($fwRule) { Write-Host "Configured" -ForegroundColor Green }
    else { Write-Host "Missing" -ForegroundColor Red }

    # Check default shell
    $regShell = Get-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -ErrorAction SilentlyContinue
    Write-Host "  Default Shell        " -NoNewline
    if ($regShell) { Write-Host "$($regShell.DefaultShell)" -ForegroundColor White }
    else { Write-Host "System Default" -ForegroundColor DarkGray }

    Write-Host ""
    Pause-Menu
}

function Show-OpenSSHMenu {
    while ($true) {
        Clear-Host
        Write-MenuHeader "OpenSSH Server Management"
        Write-Host ""
        Write-MenuOption "1" "Install & Configure OpenSSH Server"
        Write-MenuOption "2" "Set Default Shell"
        Write-MenuOption "3" "Show OpenSSH Status"
        Write-Separator
        Write-MenuOption "B" "Back to Main Menu"

        $choice = Read-MenuChoice

        switch ($choice) {
            "1" { Install-OpenSSHServer }
            "2" { Set-DefaultShell }
            "3" { Show-OpenSSHStatus }
            "B" { return }
            default { Write-Step "Invalid option." -Type Warning; Start-Sleep -Seconds 1 }
        }
    }
}

Export-ModuleMember -Function *
