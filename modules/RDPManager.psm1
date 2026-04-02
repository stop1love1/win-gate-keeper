# ============================================================================
# WinGateKeeper - Remote Desktop (RDP) Management Module
# Enable/disable RDP, manage RDP user access, monitor RDP sessions
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

function Test-RDPEnabled {
    $reg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -ErrorAction SilentlyContinue
    return ($reg -and $reg.fDenyTSConnections -eq 0)
}

function Enable-RDP {
    Write-MenuHeader "Enable Remote Desktop"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    if (Test-RDPEnabled) {
        Write-Step "Remote Desktop is already enabled." -Type Success
        Pause-Menu
        return
    }

    if (-not (Confirm-Action "Enable Remote Desktop on this server?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        # Enable RDP
        Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0 -Type DWord -ErrorAction Stop
        Write-Step "Remote Desktop enabled." -Type Success

        # Enable Network Level Authentication (more secure)
        Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1 -Type DWord -ErrorAction Stop
        Write-Step "Network Level Authentication (NLA) enabled." -Type Success

        # Firewall rule
        $rule = Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
        if ($rule) {
            Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
            Write-Step "Firewall rules enabled for Remote Desktop." -Type Success
        }
        else {
            New-NetFirewallRule -Name "WinGateKeeper-RDP-TCP" -DisplayName "Remote Desktop (WinGateKeeper)" `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 3389 | Out-Null
            Write-Step "Firewall rule created for RDP (port 3389)." -Type Success
        }

        Write-Log "Remote Desktop enabled."
    }
    catch {
        Write-Step "Failed to enable RDP: $_" -Type Error
    }

    Pause-Menu
}

function Disable-RDP {
    Write-MenuHeader "Disable Remote Desktop"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    if (-not (Test-RDPEnabled)) {
        Write-Step "Remote Desktop is already disabled." -Type Info
        Pause-Menu
        return
    }

    if (-not (Confirm-Action "Disable Remote Desktop? Active sessions will be disconnected.")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 1 -Type DWord -ErrorAction Stop
        Write-Step "Remote Desktop disabled." -Type Success

        Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
        Write-Step "Firewall rules disabled." -Type Success

        Write-Log "Remote Desktop disabled."
    }
    catch {
        Write-Step "Failed to disable RDP: $_" -Type Error
    }

    Pause-Menu
}

function Grant-RDPAccess {
    param([string]$Username)

    if (-not $Username) {
        Write-Host "  Enter username: " -ForegroundColor White -NoNewline
        $Username = (Read-Host).Trim()
    }

    $user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Step "User '$Username' not found." -Type Error
        return $false
    }

    try {
        Add-LocalGroupMember -Group "Remote Desktop Users" -Member $Username -ErrorAction Stop
        Write-Step "'$Username' granted RDP access." -Type Success
        Write-Log "Granted RDP access to '$Username'."
        return $true
    }
    catch {
        if ($_ -match "already a member") {
            Write-Step "'$Username' already has RDP access." -Type Info
            return $true
        }
        Write-Step "Failed to grant RDP access: $_" -Type Error
        return $false
    }
}

function Revoke-RDPAccess {
    param([string]$Username)

    if (-not $Username) {
        # Show current RDP users
        Show-RDPUsers
        Write-Host ""
        Write-Host "  Enter username to revoke: " -ForegroundColor White -NoNewline
        $Username = (Read-Host).Trim()
    }

    if (-not $Username) { return }

    $user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Step "User '$Username' not found." -Type Error
        return
    }

    if (-not (Confirm-Action "Revoke RDP access for '$Username'?")) {
        return
    }

    try {
        Remove-LocalGroupMember -Group "Remote Desktop Users" -Member $Username -ErrorAction Stop
        Write-Step "'$Username' RDP access revoked." -Type Success
        Write-Log "Revoked RDP access for '$Username'."
    }
    catch {
        Write-Step "Failed to revoke RDP access: $_" -Type Error
    }
}

function Show-RDPUsers {
    Write-Host ""
    Write-Host "  Users with RDP access:" -ForegroundColor White
    Write-Host ("  " + "-" * 40) -ForegroundColor DarkGray

    try {
        $members = @(Get-LocalGroupMember -Group "Remote Desktop Users" -ErrorAction SilentlyContinue)
        if ($members.Count -eq 0) {
            Write-Host "  (no users)" -ForegroundColor DarkGray
        }
        else {
            foreach ($m in $members) {
                $uname = ($m.Name -split '\\')[-1]
                $localUser = Get-LocalUser -Name $uname -ErrorAction SilentlyContinue
                $status = if ($localUser -and $localUser.Enabled) { "Enabled" } else { "Disabled" }
                $statusColor = if ($status -eq "Enabled") { "Green" } else { "Red" }
                Write-Host "  $($uname.PadRight(25)) " -NoNewline
                Write-Host "$status" -ForegroundColor $statusColor
            }
        }
    }
    catch {
        Write-Host "  (cannot read group)" -ForegroundColor Red
    }

    # Also show Administrators (they always have RDP access)
    Write-Host ""
    Write-Host "  Administrators (always have RDP access):" -ForegroundColor DarkGray
    try {
        $admins = @(Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue)
        foreach ($m in $admins) {
            Write-Host "  $($m.Name)" -ForegroundColor DarkGray
        }
    }
    catch {}
}

function Show-RDPStatus {
    Write-MenuHeader "Remote Desktop Status"

    Write-Host ""

    # RDP enabled?
    Write-Host "  Remote Desktop             " -NoNewline
    if (Test-RDPEnabled) {
        Write-Host "ENABLED" -ForegroundColor Green
    }
    else {
        Write-Host "DISABLED" -ForegroundColor Red
    }

    # NLA
    $nla = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name UserAuthentication -ErrorAction SilentlyContinue
    Write-Host "  Network Level Auth (NLA)   " -NoNewline
    if ($nla -and $nla.UserAuthentication -eq 1) {
        Write-Host "ENABLED" -ForegroundColor Green
    }
    else {
        Write-Host "DISABLED" -ForegroundColor Yellow
    }

    # Port
    $portReg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name PortNumber -ErrorAction SilentlyContinue
    $rdpPort = if ($portReg) { $portReg.PortNumber } else { 3389 }
    Write-Host "  RDP Port                   $rdpPort" -ForegroundColor Cyan

    # Firewall
    $fwRule = Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq "True" }
    Write-Host "  Firewall Rule              " -NoNewline
    if ($fwRule) {
        Write-Host "OPEN" -ForegroundColor Green
    }
    else {
        Write-Host "BLOCKED" -ForegroundColor Red
    }

    # RDP users
    Show-RDPUsers

    # Active RDP sessions
    Write-Host ""
    Write-Host "  Active RDP Sessions:" -ForegroundColor White
    Write-Host ("  " + "-" * 40) -ForegroundColor DarkGray

    if (Get-Command quser -ErrorAction SilentlyContinue) {
        $quser = quser 2>&1 | Where-Object { $_ -is [string] }
        if ($quser -and $quser.Count -gt 1) {
            foreach ($line in ($quser | Select-Object -Skip 1)) {
                $trimmed = $line.Trim()
                if ($trimmed) { Write-Host "  $trimmed" -ForegroundColor Cyan }
            }
        }
        else {
            Write-Host "  (no active sessions)" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "  (quser not available on Server Core)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Pause-Menu
}

function Disconnect-RDPSession {
    Write-MenuHeader "Disconnect RDP Session"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    if (-not (Get-Command quser -ErrorAction SilentlyContinue)) {
        Write-Step "quser command not available (Server Core)." -Type Error
        Pause-Menu
        return
    }

    $quser = quser 2>&1 | Where-Object { $_ -is [string] }
    if (-not $quser -or $quser.Count -le 1) {
        Write-Step "No active RDP sessions." -Type Info
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  Active Sessions:" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray
    foreach ($line in ($quser | Select-Object -Skip 1)) {
        Write-Host "  $($line.Trim())" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  Enter Session ID to disconnect (0 to cancel): " -ForegroundColor White -NoNewline
    $sessionId = (Read-Host).Trim()

    if (-not $sessionId -or $sessionId -eq "0") {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    if (Confirm-Action "Force disconnect session ID $sessionId?") {
        try {
            $result = logoff $sessionId /v 2>&1
            Write-Step "Session $sessionId disconnected." -Type Success
            Write-Log "Force disconnected RDP session $sessionId."
        }
        catch {
            Write-Step "Failed to disconnect: $_" -Type Error
        }
    }

    Pause-Menu
}

function Show-RDPMenu {
    while ($true) {
        $rdpStatus = if (Test-RDPEnabled) { "OK" } else { "FAIL" }
        $choice = Select-MenuOption -Title "Remote Desktop (RDP) Management" -Items @(
            @{ Key = "1"; Label = "Enable Remote Desktop" }
            @{ Key = "2"; Label = "Disable Remote Desktop" }
            @{ Key = "3"; Label = "Show RDP Status"; Status = $rdpStatus }
            @{ Separator = $true }
            @{ Key = "4"; Label = "Grant RDP Access to User" }
            @{ Key = "5"; Label = "Revoke RDP Access from User" }
            @{ Separator = $true }
            @{ Key = "6"; Label = "View Active RDP Sessions" }
            @{ Key = "7"; Label = "Disconnect RDP Session" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back to Main Menu" }
        )
        switch ($choice) {
            "1" { Enable-RDP }
            "2" { Disable-RDP }
            "3" { Show-RDPStatus }
            "4" {
                Write-MenuHeader "Grant RDP Access"
                Grant-RDPAccess
                Pause-Menu
            }
            "5" {
                Write-MenuHeader "Revoke RDP Access"
                Revoke-RDPAccess
                Pause-Menu
            }
            "6" { Show-RDPStatus }
            "7" { Disconnect-RDPSession }
            "B" { return }
        }
    }
}

Export-ModuleMember -Function *
