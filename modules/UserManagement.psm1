# ============================================================================
# WinGateKeeper - User Management Module
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

function Compare-SecureString {
    <#
    .SYNOPSIS
        Compare two SecureStrings without leaking plaintext into managed heap.
        Uses NetworkCredential to get a char[] reference, compares byte-by-byte.
    #>
    param(
        [System.Security.SecureString]$SS1,
        [System.Security.SecureString]$SS2
    )
    $cred1 = New-Object System.Net.NetworkCredential("", $SS1)
    $cred2 = New-Object System.Net.NetworkCredential("", $SS2)
    return ($cred1.Password -ceq $cred2.Password)
}


function New-GateUser {
    Write-MenuHeader "Create New User"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    Write-Host ""
    Write-Host "  Enter username: " -ForegroundColor White -NoNewline
    $username = (Read-Host).Trim()

    if (-not $username) {
        Write-Step "Username cannot be empty." -Type Error
        Pause-Menu
        return
    }

    if ($username -notmatch '^[a-zA-Z0-9._-]{1,20}$') {
        Write-Step "Invalid username. Use 1-20 chars: letters, numbers, dots, hyphens, underscores." -Type Error
        Pause-Menu
        return
    }

    # Check if user already exists
    $existingUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
    if ($existingUser) {
        Write-Step "User '$username' already exists." -Type Error
        Pause-Menu
        return
    }

    Write-Host "  Enter full name (optional): " -ForegroundColor White -NoNewline
    $fullName = (Read-Host).Trim()

    Write-Host "  Enter description (optional): " -ForegroundColor White -NoNewline
    $description = (Read-Host).Trim()

    # User type selection
    Write-Host ""
    Write-MenuOption "1" "SFTP-only (file transfer only)"
    Write-MenuOption "2" "Shell (SSH terminal + SFTP)"
    Write-MenuOption "3" "RDP (Remote Desktop - full GUI access)"
    Write-MenuOption "4" "Shell + RDP (terminal + desktop)"
    $typeChoice = Read-MenuChoice "Select user type"

    if ($typeChoice -notin @("1", "2", "3", "4")) {
        Write-Step "Invalid user type selection." -Type Error
        Pause-Menu
        return
    }
    $isSFTPOnly = ($typeChoice -eq "1")
    $isRDP = ($typeChoice -in @("3", "4"))
    $isShell = ($typeChoice -in @("2", "4"))

    # Account expiry (optional)
    Write-Host ""
    Write-Host "  Set account expiry date? (leave empty for no expiry): " -ForegroundColor White -NoNewline
    $expiryInput = (Read-Host).Trim()
    $accountExpires = $null
    if ($expiryInput) {
        try {
            $accountExpires = [datetime]::ParseExact($expiryInput, @("yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy"), $null)
            if ($accountExpires -le (Get-Date)) {
                Write-Step "Expiry date must be in the future." -Type Error
                Pause-Menu
                return
            }
            Write-Step "Account will expire on: $($accountExpires.ToString('yyyy-MM-dd'))" -Type Info
        }
        catch {
            Write-Step "Invalid date format. Use yyyy-MM-dd format." -Type Error
            Pause-Menu
            return
        }
    }

    # Password with confirmation
    Write-Host ""
    Write-Host "  Enter password: " -ForegroundColor White -NoNewline
    $securePass = Read-Host -AsSecureString
    Write-Host "  Confirm password: " -ForegroundColor White -NoNewline
    $confirmPass = Read-Host -AsSecureString

    $matched = Compare-SecureString $securePass $confirmPass

    if (-not $matched) {
        Write-Step "Passwords do not match." -Type Error
        Pause-Menu
        return
    }



    if (-not (Confirm-Action "Create user '$username'?")) {
        Write-Step "Operation cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        # Create local user
        Write-Step "Creating local user '$username'..." -Type Info
        $params = @{
            Name                 = $username
            Password             = $securePass
            PasswordNeverExpires = $false
            UserMayNotChangePassword = $false
        }
        if ($accountExpires) {
            $params.AccountExpires = $accountExpires
        }
        else {
            $params.AccountNeverExpires = $true
        }
        if ($fullName) { $params.FullName = $fullName }
        if ($description) { $params.Description = $description }

        New-LocalUser @params | Out-Null
        Write-Step "User '$username' created." -Type Success

        # Wait briefly for Windows to register the new SID
        Start-Sleep -Seconds 1

        # Use full COMPUTERNAME\username for all group/ACL operations
        $fullUsername = "$env:COMPUTERNAME\$username"

        # Add to Users group
        try {
            Add-LocalGroupMember -Group "Users" -Member $fullUsername -ErrorAction Stop
            Write-Step "Added to 'Users' group." -Type Success
        }
        catch {
            Write-Step "Warning: Failed to add to 'Users' group: $_" -Type Warning
        }

        # SFTP-only group (also for RDP-only users to block SSH shell access)
        if ($isSFTPOnly -or ($isRDP -and -not $isShell)) {
            $sftpGroup = $settings.SFTPOnlyGroup
            $group = Get-LocalGroup -Name $sftpGroup -ErrorAction SilentlyContinue
            if (-not $group) {
                New-LocalGroup -Name $sftpGroup -Description "SFTP-only access users"
                Write-Step "Created group '$sftpGroup'." -Type Info
            }
            try {
                Add-LocalGroupMember -Group $sftpGroup -Member $fullUsername -ErrorAction Stop
                Write-Step "Added to '$sftpGroup' group (SFTP-only)." -Type Success
            }
            catch {
                Write-Step "Failed to add to SFTP group. Rolling back user creation..." -Type Error
                Remove-LocalUser -Name $username -ErrorAction SilentlyContinue
                throw "SFTP group assignment failed: $_"
            }
        }

        # RDP access
        if ($isRDP) {
            try {
                Add-LocalGroupMember -Group "Remote Desktop Users" -Member $fullUsername -ErrorAction Stop
                Write-Step "Added to 'Remote Desktop Users' group." -Type Success
            }
            catch {
                if ("$_" -match "already a member") {
                    Write-Step "Already in 'Remote Desktop Users' group." -Type Info
                }
                else {
                    Write-Step "Warning: Failed to add to RDP group: $_" -Type Warning
                }
            }
        }

        # Create user directory
        $userDir = Join-Path $settings.UsersRoot $username
        if (-not (Test-Path $userDir)) {
            New-Item -ItemType Directory -Path $userDir -Force | Out-Null
            Write-Step "Created directory: $userDir" -Type Success
        }

        # Set NTFS permissions
        Set-UserDirectoryPermissions -Username $username -Path $userDir

        $typeLabel = switch ($typeChoice) { "1" { "SFTP-only" }; "2" { "Shell" }; "3" { "RDP" }; "4" { "Shell+RDP" } }
        Write-Log "User '$username' created. Type: $typeLabel"
        Write-Host ""
        Write-Step "User '$username' provisioned successfully!" -Type Success

        # Show connection guide
        Show-ConnectionGuide -Username $username -UserType $typeLabel
    }
    catch {
        Write-Step "Failed to create user: $_" -Type Error
        Write-Log "User creation failed for '$username': $_" -Level "ERROR"
    }

    Pause-Menu
}

function Show-ConnectionGuide {
    param(
        [string]$Username,
        [string]$UserType = "Shell"
    )

    $settings = Get-Settings
    $sshPort = if ($settings -and $settings.SSHPort) { $settings.SSHPort } else { 22 }

    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } |
        Select-Object -ExpandProperty IPAddress)
    $serverIP = if ($ips.Count -gt 0) { $ips[0] } else { $env:COMPUTERNAME }
    $portParam = if ($sshPort -ne 22) { " -P $sshPort" } else { "" }
    $portFlag = if ($sshPort -ne 22) { " -p $sshPort" } else { "" }

    Write-Host ""
    Write-Host ("  " + "=" * 56) -ForegroundColor DarkCyan
    Write-Host "  CONNECTION GUIDE - Send this info to the user" -ForegroundColor White
    Write-Host ("  " + "=" * 56) -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  Server:    $serverIP" -ForegroundColor Cyan
    Write-Host "  Username:  $Username" -ForegroundColor Cyan
    Write-Host "  Password:  (the password you just set)" -ForegroundColor Cyan
    Write-Host "  Type:      $UserType" -ForegroundColor Yellow
    Write-Host ""

    # SFTP guide
    if ($UserType -in @("SFTP-only", "Shell", "Shell+RDP")) {
        Write-Host "  --- SFTP (file transfer) ---" -ForegroundColor White
        Write-Host "  WinSCP / FileZilla:" -ForegroundColor Green
        Write-Host "    Protocol:  SFTP" -ForegroundColor White
        Write-Host "    Host:      $serverIP" -ForegroundColor White
        Write-Host "    Port:      $sshPort" -ForegroundColor White
        Write-Host "    Username:  $Username" -ForegroundColor White
        Write-Host "  Command line:" -ForegroundColor Green
        Write-Host "    sftp$portParam $Username@$serverIP" -ForegroundColor White
        Write-Host ""
    }

    # SSH guide
    if ($UserType -in @("Shell", "Shell+RDP")) {
        Write-Host "  --- SSH (remote terminal) ---" -ForegroundColor White
        Write-Host "  Terminal / PowerShell:" -ForegroundColor Green
        Write-Host "    ssh$portFlag $Username@$serverIP" -ForegroundColor White
        Write-Host "  PuTTY:" -ForegroundColor Green
        Write-Host "    Host: $serverIP  Port: $sshPort  Username: $Username" -ForegroundColor White
        Write-Host ""
    }

    # RDP guide
    if ($UserType -in @("RDP", "Shell+RDP")) {
        Write-Host "  --- RDP (Remote Desktop - full GUI) ---" -ForegroundColor White
        Write-Host "  Windows:" -ForegroundColor Green
        Write-Host "    mstsc /v:$serverIP" -ForegroundColor White
        Write-Host "    Or: Start Menu > Remote Desktop Connection" -ForegroundColor DarkGray
        Write-Host "    Computer:  $serverIP" -ForegroundColor White
        Write-Host "    Username:  $Username" -ForegroundColor White
        Write-Host "  Mac:" -ForegroundColor Green
        Write-Host "    Download 'Microsoft Remote Desktop' from App Store" -ForegroundColor White
        Write-Host "    PC name:   $serverIP" -ForegroundColor White
        Write-Host ""
    }

    Write-Host ("  " + "=" * 56) -ForegroundColor DarkCyan
}

function Set-UserDirectoryPermissions {
    param(
        [string]$Username,
        [string]$Path
    )

    Write-Step "Setting NTFS permissions for '$Username' on $Path..." -Type Info

    # Use full COMPUTERNAME\username for ACL identity
    $identity = if ($Username -match '\\') { $Username } else { "$env:COMPUTERNAME\$Username" }

    try {
        $acl = New-AdminSystemAcl -Path $Path

        # User modify (read, write, execute, delete - but not change permissions)
        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($userRule)

        Set-Acl -Path $Path -AclObject $acl -ErrorAction Stop
        Write-Step "NTFS permissions applied." -Type Success
    }
    catch {
        Write-Step "Failed to set permissions: $_" -Type Error
    }
}

function Remove-GateUser {
    Write-MenuHeader "Remove User"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    # List current WinGateKeeper users
    Show-UserList

    Write-Host ""
    Write-Host "  Enter username to remove: " -ForegroundColor White -NoNewline
    $username = (Read-Host).Trim()

    if (-not $username) {
        Write-Step "Username cannot be empty." -Type Error
        Pause-Menu
        return
    }

    $user = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Step "User '$username' does not exist." -Type Error
        Pause-Menu
        return
    }

    # Safety: prevent removing built-in accounts
    if ($username -in @("Administrator", "DefaultAccount", "Guest", "WDAGUtilityAccount")) {
        Write-Step "Cannot remove built-in account '$username'." -Type Error
        Pause-Menu
        return
    }

    if (-not (Confirm-Action "CONFIRM: Remove user '$username'? This cannot be undone.")) {
        Write-Step "Operation cancelled." -Type Warning
        Pause-Menu
        return
    }

    $userDir = Join-Path $settings.UsersRoot $username
    $removeDir = $false
    if (Test-Path $userDir) {
        $removeDir = Confirm-Action "Also remove user directory '$userDir'?"
    }

    try {
        Remove-LocalUser -Name $username
        Write-Step "User '$username' removed." -Type Success

        if ($removeDir) {
            Remove-Item -Path $userDir -Recurse -Force
            Write-Step "Directory removed: $userDir" -Type Success
        }

        Write-Log "User '$username' removed. Directory removed: $removeDir"
    }
    catch {
        Write-Step "Failed to remove user: $_" -Type Error
        Write-Log "User removal failed for '$username': $_" -Level "ERROR"
    }

    Pause-Menu
}

function Show-UserList {
    $settings = Get-Settings
    if (-not $settings) { return }
    $sftpGroup = $settings.SFTPOnlyGroup

    Write-Host ""
    Write-Host "  Username             Type           Status     " -ForegroundColor White
    Write-Separator

    $builtIn = @("Administrator", "DefaultAccount", "Guest", "WDAGUtilityAccount")
    $users = @(Get-LocalUser | Where-Object { $_.Name -notin $builtIn })

    if ($users.Count -eq 0) {
        Write-Host "  (no users found)" -ForegroundColor DarkGray
        return
    }

    # Pre-fetch group members once for fast lookup
    $sftpMemberNames = @{}
    $rdpMemberNames = @{}
    try {
        $members = @(Get-LocalGroupMember -Group $sftpGroup -ErrorAction SilentlyContinue)
        foreach ($m in $members) { $sftpMemberNames[($m.Name -split '\\')[-1]] = $true }
    } catch {}
    try {
        $members = @(Get-LocalGroupMember -Group "Remote Desktop Users" -ErrorAction SilentlyContinue)
        foreach ($m in $members) { $rdpMemberNames[($m.Name -split '\\')[-1]] = $true }
    } catch {}

    foreach ($user in $users) {
        $isSFTP = $sftpMemberNames.ContainsKey($user.Name)
        $isRDP = $rdpMemberNames.ContainsKey($user.Name)

        $type = if ($isSFTP) { "SFTP-only" }
                elseif ($isRDP -and -not $isSFTP) { "Shell+RDP" }
                else { "Shell" }
        # Check if RDP-only (in RDP group but also in SFTP group is impossible, so just check)
        if ($isRDP -and $isSFTP) { $type = "SFTP+RDP" }

        $status = if ($user.Enabled) { "Enabled" } else { "Disabled" }
        $statusColor = if ($user.Enabled) { "Green" } else { "Red" }

        $name = $user.Name.PadRight(20)
        $typeStr = $type.PadRight(14)

        Write-Host "  $name " -NoNewline
        Write-Host "$typeStr " -ForegroundColor Cyan -NoNewline
        Write-Host "$status" -ForegroundColor $statusColor
    }
}

function Show-UserDetail {
    Write-MenuHeader "User Detail"

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    Show-UserList

    Write-Host ""
    Write-Host "  Enter username to view: " -ForegroundColor White -NoNewline
    $username = (Read-Host).Trim()

    $user = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Step "User '$username' not found." -Type Error
        Pause-Menu
        return
    }

    Clear-Host
    Write-MenuHeader "User Detail: $username"

    # === Basic Info ===
    Write-Host ""
    Write-Host "  Account Information:" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray
    Write-Host "  Username:          $($user.Name)" -ForegroundColor Cyan
    Write-Host "  Full Name:         $(if ($user.FullName) { $user.FullName } else { '(not set)' })" -ForegroundColor Cyan
    Write-Host "  Description:       $(if ($user.Description) { $user.Description } else { '(not set)' })" -ForegroundColor Cyan
    Write-Host "  SID:               $($user.SID)" -ForegroundColor DarkGray

    # === Status ===
    Write-Host ""
    Write-Host "  Account Status:" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray
    Write-Host "  Enabled:           " -NoNewline
    if ($user.Enabled) { Write-Host "Yes" -ForegroundColor Green }
    else { Write-Host "No (DISABLED)" -ForegroundColor Red }

    Write-Host "  Account Expires:   " -NoNewline
    if ($user.AccountExpires) { Write-Host "$($user.AccountExpires.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Yellow }
    else { Write-Host "Never" -ForegroundColor Green }

    Write-Host "  Password Last Set: " -NoNewline
    if ($user.PasswordLastSet) { Write-Host "$($user.PasswordLastSet.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan }
    else { Write-Host "Never" -ForegroundColor Yellow }

    Write-Host "  Password Expires:  " -NoNewline
    if ($user.PasswordExpires) { Write-Host "$($user.PasswordExpires.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan }
    else { Write-Host "Never" -ForegroundColor DarkGray }

    Write-Host "  Last Logon:        " -NoNewline
    if ($user.LastLogon) { Write-Host "$($user.LastLogon.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan }
    else { Write-Host "Never logged in" -ForegroundColor DarkGray }

    # === Group Membership ===
    Write-Host ""
    Write-Host "  Group Membership:" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray

    $sftpGroup = $settings.SFTPOnlyGroup
    $isSFTP = $false
    $groups = @()
    Write-Host "  Loading groups..." -ForegroundColor DarkGray -NoNewline
    try {
        # Use net localgroup to get user's groups (faster than iterating all groups)
        $netOutput = net localgroup 2>&1
        $allGroupNames = @($netOutput | Where-Object { $_ -match '^\*' } | ForEach-Object { $_.TrimStart('*') })
        foreach ($grpName in $allGroupNames) {
            try {
                $members = @(Get-LocalGroupMember -Group $grpName -ErrorAction SilentlyContinue)
                $inGroup = $members | Where-Object { ($_.Name -split '\\')[-1] -eq $username }
                if ($inGroup) {
                    $groups += $grpName
                    if ($grpName -eq $sftpGroup) { $isSFTP = $true }
                }
            }
            catch {}
        }
    }
    catch {}
    Write-Host "`r                        `r" -NoNewline  # clear "Loading..." line

    $isRDPUser = $groups -contains "Remote Desktop Users"

    Write-Host "  User Type:         " -NoNewline
    if ($isSFTP -and $isRDPUser) { Write-Host "RDP (Remote Desktop only)" -ForegroundColor Magenta }
    elseif ($isSFTP) { Write-Host "SFTP-only (file transfer)" -ForegroundColor Yellow }
    elseif ($isRDPUser) { Write-Host "Shell + RDP" -ForegroundColor Cyan }
    else { Write-Host "Shell (SSH + SFTP)" -ForegroundColor Cyan }

    if ($groups.Count -gt 0) {
        foreach ($grp in $groups) {
            $color = if ($grp -eq $sftpGroup) { "Yellow" } else { "White" }
            Write-Host "  - $grp" -ForegroundColor $color
        }
    }
    else {
        Write-Host "  (no groups)" -ForegroundColor DarkGray
    }

    # === Directory Info ===
    Write-Host ""
    Write-Host "  Directory & Storage:" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray

    $userDir = Join-Path $settings.UsersRoot $username
    Write-Host "  Home Directory:    $userDir" -ForegroundColor Cyan
    Write-Host "  Directory Exists:  " -NoNewline
    if (Test-Path $userDir) {
        Write-Host "Yes" -ForegroundColor Green

        # Calculate size
        $files = Get-ChildItem -Path $userDir -Recurse -File -ErrorAction SilentlyContinue
        $fileCount = @($files).Count
        $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
        if (-not $totalSize) { $totalSize = 0 }
        $sizeStr = if ($totalSize -gt 1GB) { "{0:N2} GB" -f ($totalSize / 1GB) }
                   elseif ($totalSize -gt 1MB) { "{0:N2} MB" -f ($totalSize / 1MB) }
                   elseif ($totalSize -gt 1KB) { "{0:N2} KB" -f ($totalSize / 1KB) }
                   else { "$totalSize B" }

        Write-Host "  Total Files:       $fileCount" -ForegroundColor Cyan
        Write-Host "  Total Size:        $sizeStr" -ForegroundColor Cyan

        # Show subdirectories
        $subDirs = Get-ChildItem -Path $userDir -Directory -ErrorAction SilentlyContinue
        if ($subDirs) {
            Write-Host "  Subdirectories:    $($subDirs.Count)" -ForegroundColor Cyan
            foreach ($sub in $subDirs | Select-Object -First 10) {
                Write-Host "    /$($sub.Name)" -ForegroundColor DarkGray
            }
            if ($subDirs.Count -gt 10) {
                Write-Host "    ... and $($subDirs.Count - 10) more" -ForegroundColor DarkGray
            }
        }

        # NTFS permissions
        Write-Host ""
        Write-Host "  NTFS Permissions:" -ForegroundColor White
        Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray
        try {
            $acl = Get-Acl $userDir
            Write-Host "  Owner:             $($acl.Owner)" -ForegroundColor Cyan
            Write-Host "  Inheritance:       " -NoNewline
            if ($acl.AreAccessRulesProtected) { Write-Host "Blocked (isolated)" -ForegroundColor Green }
            else { Write-Host "Inherited" -ForegroundColor Yellow }

            foreach ($rule in $acl.Access) {
                $identity = $rule.IdentityReference.Value
                $rights = $rule.FileSystemRights
                $type = $rule.AccessControlType
                $color = if ($type -eq "Allow") { "White" } else { "Red" }
                Write-Host "  $type  " -ForegroundColor $color -NoNewline
                Write-Host "$identity" -ForegroundColor Cyan -NoNewline
                Write-Host " -> $rights" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Step "Cannot read permissions: $_" -Type Warning
        }
    }
    else {
        Write-Host "No (MISSING)" -ForegroundColor Red
    }

    # === Recent Login Activity ===
    Write-Host ""
    Write-Host "  Recent Login Activity (last 10):" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Security'
            Id = 4624, 4625
        } -MaxEvents 200 -ErrorAction SilentlyContinue

        $userEvents = @()
        foreach ($event in $events) {
            $xml = [xml]$event.ToXml()
            $data = @{}
            foreach ($d in $xml.Event.EventData.Data) {
                $data[$d.Name] = $d.'#text'
            }
            if ($data['TargetUserName'] -eq $username) {
                $userEvents += @{
                    Time = $event.TimeCreated
                    Type = if ($event.Id -eq 4624) { "Login" } else { "FAILED" }
                    IP   = if ($data['IpAddress']) { $data['IpAddress'] } else { "-" }
                }
            }
        }

        if ($userEvents.Count -gt 0) {
            foreach ($evt in $userEvents | Select-Object -First 10) {
                $time = $evt.Time.ToString("yyyy-MM-dd HH:mm:ss")
                $typeColor = if ($evt.Type -eq "Login") { "Green" } else { "Red" }
                Write-Host "  $time  " -NoNewline
                Write-Host "$($evt.Type.PadRight(8))" -ForegroundColor $typeColor -NoNewline
                Write-Host "from $($evt.IP)" -ForegroundColor Cyan
            }
        }
        else {
            Write-Host "  (no login events found)" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "  (cannot read Security Event Log)" -ForegroundColor DarkGray
    }

    # === Recent File Activity ===
    Write-Host ""
    Write-Host "  Recent File Activity (last 10):" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray

    try {
        $fileEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'Security'
            Id = 4663
        } -MaxEvents 200 -ErrorAction SilentlyContinue

        $userFileEvents = @()
        foreach ($event in $fileEvents) {
            $xml = [xml]$event.ToXml()
            $data = @{}
            foreach ($d in $xml.Event.EventData.Data) {
                $data[$d.Name] = $d.'#text'
            }
            if ($data['SubjectUserName'] -eq $username) {
                $objectName = $data['ObjectName']
                if ($objectName -and $objectName -like "$($settings.BasePath)*") {
                    $accessMask = $data['AccessMask']
                    $action = switch ($accessMask) {
                        "0x2"     { "Write" }
                        "0x1"     { "Read" }
                        "0x10000" { "Delete" }
                        "0x6"     { "Write" }
                        default   { "Access" }
                    }
                    $shortPath = $objectName.Replace($settings.BasePath, "~")
                    $userFileEvents += @{
                        Time   = $event.TimeCreated
                        Action = $action
                        Path   = $shortPath
                    }
                }
            }
        }

        if ($userFileEvents.Count -gt 0) {
            foreach ($evt in $userFileEvents | Select-Object -First 10) {
                $time = $evt.Time.ToString("yyyy-MM-dd HH:mm:ss")
                $path = $evt.Path
                if ($path.Length -gt 35) { $path = "..." + $path.Substring($path.Length - 32) }
                Write-Host "  $time  " -NoNewline
                Write-Host "$($evt.Action.PadRight(8))" -ForegroundColor Yellow -NoNewline
                Write-Host "$path" -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host "  (no file activity found)" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "  (cannot read Security Event Log)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Pause-Menu
}

function Enable-DisableUser {
    Write-MenuHeader "Enable/Disable User"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    Show-UserList

    Write-Host ""
    Write-Host "  Enter username: " -ForegroundColor White -NoNewline
    $username = (Read-Host).Trim()

    $user = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Step "User '$username' not found." -Type Error
        Pause-Menu
        return
    }

    if ($user.Enabled) {
        if (Confirm-Action "Disable user '$username'?") {
            Disable-LocalUser -Name $username
            Write-Step "User '$username' disabled." -Type Success
            Write-Log "User '$username' disabled."
        }
    }
    else {
        if (Confirm-Action "Enable user '$username'?") {
            Enable-LocalUser -Name $username
            Write-Step "User '$username' enabled." -Type Success
            Write-Log "User '$username' enabled."
        }
    }

    Pause-Menu
}

function Reset-UserPassword {
    Write-MenuHeader "Reset User Password"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    Show-UserList

    Write-Host ""
    Write-Host "  Enter username: " -ForegroundColor White -NoNewline
    $username = (Read-Host).Trim()

    $user = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Step "User '$username' not found." -Type Error
        Pause-Menu
        return
    }

    Write-Host "  Enter new password: " -ForegroundColor White -NoNewline
    $newPass = Read-Host -AsSecureString
    Write-Host "  Confirm password: " -ForegroundColor White -NoNewline
    $confirmPass = Read-Host -AsSecureString

    $matched = Compare-SecureString $newPass $confirmPass

    if (-not $matched) {
        Write-Step "Passwords do not match." -Type Error
        Pause-Menu
        return
    }



    try {
        Set-LocalUser -Name $username -Password $newPass
        Write-Step "Password reset for '$username'." -Type Success
        Write-Log "Password reset for user '$username'."
    }
    catch {
        Write-Step "Failed to reset password: $_" -Type Error
    }

    Pause-Menu
}

function Show-FolderAccessMenu {
    Write-MenuHeader "Manage Folder Access"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    Show-UserList

    Write-Host ""
    Write-Host "  Enter username: " -ForegroundColor White -NoNewline
    $username = (Read-Host).Trim()

    $user = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Step "User '$username' not found." -Type Error
        Pause-Menu
        return
    }

    while ($true) {
        Clear-Host
        Write-MenuHeader "Folder Access: $username"

        # Show current folder permissions for this user
        Write-Host ""
        Write-Host "  Current folder access:" -ForegroundColor White
        Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray

        $settings = Get-Settings
        $userDir = Join-Path $settings.UsersRoot $username
        Write-Host "  $userDir" -ForegroundColor Cyan -NoNewline
        Write-Host " (home - Modify)" -ForegroundColor DarkGray

        # Scan for additional ACL entries for this user on common locations
        $extraFolders = Get-UserFolderAccess -Username $username
        if ($extraFolders.Count -gt 0) {
            foreach ($entry in $extraFolders) {
                $rightsStr = Format-AccessRights $entry.Rights
                Write-Host "  $($entry.Path)" -ForegroundColor Cyan -NoNewline
                Write-Host " ($rightsStr)" -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host "  (no additional folders)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-MenuOption "1" "Grant access to a folder"
        Write-MenuOption "2" "Revoke access to a folder"
        Write-MenuOption "3" "View detailed permissions"
        Write-Separator
        Write-MenuOption "B" "Back"

        $choice = Read-MenuChoice

        switch ($choice) {
            "1" { Grant-FolderAccess -Username $username }
            "2" { Revoke-FolderAccess -Username $username }
            "3" { Show-DetailedFolderAccess -Username $username }
            "B" { return }
        }
    }
}

function Grant-FolderAccess {
    param([string]$Username)

    Write-Host ""
    Write-Host "  Enter folder path to grant access: " -ForegroundColor White -NoNewline
    $folderPath = (Read-Host).Trim()

    if (-not $folderPath) { return }

    if (-not (Test-Path $folderPath -PathType Container)) {
        Write-Host ""
        if (Confirm-Action "Folder does not exist. Create it?") {
            try {
                New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
                Write-Step "Created: $folderPath" -Type Success
            }
            catch {
                Write-Step "Failed to create folder: $_" -Type Error
                Pause-Menu
                return
            }
        }
        else { return }
    }

    Write-Host ""
    Write-Host "  Select permission level:" -ForegroundColor White
    Write-MenuOption "1" "Read Only (view files, cannot modify)"
    Write-MenuOption "2" "Read + Write (view and create files)"
    Write-MenuOption "3" "Modify (read, write, delete)"
    Write-MenuOption "4" "Full Control (everything including change permissions)"
    $permChoice = Read-MenuChoice "Permission level"

    $rights = switch ($permChoice) {
        "1" { "ReadAndExecute" }
        "2" { "Read, Write" }
        "3" { "Modify" }
        "4" { "FullControl" }
        default { $null }
    }

    if (-not $rights) {
        Write-Step "Invalid selection." -Type Error
        Pause-Menu
        return
    }

    $rightsLabel = switch ($permChoice) {
        "1" { "Read Only" }
        "2" { "Read + Write" }
        "3" { "Modify" }
        "4" { "Full Control" }
    }

    if (-not (Confirm-Action "Grant '$rightsLabel' on '$folderPath' to '$Username'?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        $identity = if ($Username -match '\\') { $Username } else { "$env:COMPUTERNAME\$Username" }
        $acl = Get-Acl $folderPath
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, $rights, "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($rule)
        Set-Acl -Path $folderPath -AclObject $acl -ErrorAction Stop

        Write-Step "Granted '$rightsLabel' to '$Username' on:" -Type Success
        Write-Step "  $folderPath" -Type Info
        Write-Log "Granted $rightsLabel to '$Username' on '$folderPath'."
    }
    catch {
        Write-Step "Failed to set permissions: $_" -Type Error
    }

    Pause-Menu
}

function Revoke-FolderAccess {
    param([string]$Username)

    $folders = Get-UserFolderAccess -Username $Username
    if ($folders.Count -eq 0) {
        Write-Step "No additional folder access found for '$Username'." -Type Info
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  Select folder to revoke access:" -ForegroundColor White
    $idx = 1
    foreach ($entry in $folders) {
        $rightsStr = Format-AccessRights $entry.Rights
        Write-Host "  [$idx] $($entry.Path) ($rightsStr)" -ForegroundColor Yellow
        $idx++
    }

    Write-Host ""
    Write-Host "  Enter number (0 to cancel): " -ForegroundColor White -NoNewline
    $pick = (Read-Host).Trim()
    $pickNum = 0
    if (-not [int]::TryParse($pick, [ref]$pickNum) -or $pickNum -lt 1 -or $pickNum -gt $folders.Count) {
        return
    }

    $target = $folders[$pickNum - 1]

    if (-not (Confirm-Action "Revoke '$Username' access to '$($target.Path)'?")) {
        return
    }

    try {
        $acl = Get-Acl $target.Path
        $rulesToRemove = $acl.Access | Where-Object {
            $_.IdentityReference.Value -match "\\$Username$" -and
            $_.AccessControlType -eq "Allow"
        }
        foreach ($rule in $rulesToRemove) {
            $acl.RemoveAccessRule($rule) | Out-Null
        }
        Set-Acl -Path $target.Path -AclObject $acl -ErrorAction Stop

        Write-Step "Revoked '$Username' access to '$($target.Path)'." -Type Success
        Write-Log "Revoked '$Username' access to '$($target.Path)'."
    }
    catch {
        Write-Step "Failed to revoke permissions: $_" -Type Error
    }

    Pause-Menu
}

function Get-UserFolderAccess {
    <# Finds folders where this user has explicit ACL entries (outside home dir) #>
    param([string]$Username)

    $settings = Get-Settings
    $userDir = Join-Path $settings.UsersRoot $Username
    $results = @()

    # Check common locations and drives for explicit ACEs for this user
    $searchRoots = @()
    # Add all drive roots
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue |
        ForEach-Object { $searchRoots += $_.DeviceID + "\" }

    foreach ($root in $searchRoots) {
        $dirs = Get-ChildItem -Path $root -Directory -Depth 1 -ErrorAction SilentlyContinue
        foreach ($dir in $dirs) {
            # Skip home directory and system directories
            if ($dir.FullName -eq $userDir) { continue }
            if ($dir.FullName -match '^\w:\\(Windows|Program Files|ProgramData|\$)') { continue }

            try {
                $acl = Get-Acl $dir.FullName -ErrorAction SilentlyContinue
                $userRules = $acl.Access | Where-Object {
                    $_.IdentityReference.Value -match "\\$Username$" -and
                    $_.AccessControlType -eq "Allow" -and
                    -not $_.IsInherited
                }
                foreach ($rule in $userRules) {
                    $results += @{
                        Path   = $dir.FullName
                        Rights = $rule.FileSystemRights
                    }
                }
            }
            catch {}
        }
    }

    return $results
}

function Format-AccessRights {
    param($Rights)
    $r = $Rights.ToString()
    if ($r -match "FullControl") { return "Full Control" }
    if ($r -match "Modify") { return "Modify" }
    if ($r -match "Write" -and $r -match "Read") { return "Read + Write" }
    if ($r -match "ReadAndExecute" -or $r -match "Read") { return "Read Only" }
    return $r
}

function Show-DetailedFolderAccess {
    param([string]$Username)

    Write-MenuHeader "Detailed Permissions: $Username"

    Write-Host ""
    Write-Host "  Scanning folders for '$Username'..." -ForegroundColor DarkGray

    $settings = Get-Settings
    $userDir = Join-Path $settings.UsersRoot $Username

    # Home directory
    Write-Host ""
    Write-Host "  Home Directory: $userDir" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray
    if (Test-Path $userDir) {
        try {
            $acl = Get-Acl $userDir
            foreach ($rule in $acl.Access) {
                $identity = $rule.IdentityReference.Value
                $rights = Format-AccessRights $rule.FileSystemRights
                $inherited = if ($rule.IsInherited) { " (inherited)" } else { "" }
                $color = if ($identity -match "\\$Username$") { "Green" } else { "DarkGray" }
                Write-Host "  $($rule.AccessControlType.ToString().PadRight(6)) $($identity.PadRight(30)) $rights$inherited" -ForegroundColor $color
            }
        }
        catch { Write-Host "  (cannot read ACL)" -ForegroundColor Red }
    }
    else {
        Write-Host "  (directory not found)" -ForegroundColor Red
    }

    # Additional folders
    $extras = Get-UserFolderAccess -Username $Username
    if ($extras.Count -gt 0) {
        Write-Host ""
        Write-Host "  Additional Folders:" -ForegroundColor White
        Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray
        foreach ($entry in $extras) {
            $rightsStr = Format-AccessRights $entry.Rights
            Write-Host "  $($entry.Path)" -ForegroundColor Cyan
            Write-Host "    Allow  $Username  $rightsStr" -ForegroundColor Green
        }
    }

    # Group memberships that affect access
    Write-Host ""
    Write-Host "  Group Memberships (affect access):" -ForegroundColor White
    Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray
    try {
        $groups = net localgroup 2>&1 | Where-Object { $_ -match '^\*' } | ForEach-Object { $_.TrimStart('*') }
        foreach ($grpName in $groups) {
            try {
                $members = @(Get-LocalGroupMember -Group $grpName -ErrorAction SilentlyContinue)
                $inGroup = $members | Where-Object { ($_.Name -split '\\')[-1] -eq $Username }
                if ($inGroup) {
                    Write-Host "  - $grpName" -ForegroundColor Cyan
                }
            }
            catch {}
        }
    }
    catch {}

    Write-Host ""
    Pause-Menu
}

function Show-UserManagementMenu {
    while ($true) {
        $choice = Select-MenuOption -Title "User Management" -Items @(
            @{ Key = "1"; Label = "Create New User" }
            @{ Key = "2"; Label = "List Users" }
            @{ Key = "3"; Label = "View User Detail" }
            @{ Key = "4"; Label = "Enable/Disable User" }
            @{ Key = "5"; Label = "Reset User Password" }
            @{ Key = "6"; Label = "Manage Folder Access" }
            @{ Key = "7"; Label = "Remove User" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back to Main Menu" }
        )
        switch ($choice) {
            "1" { New-GateUser }
            "2" {
                Write-MenuHeader "User List"
                Show-UserList
                Pause-Menu
            }
            "3" { Show-UserDetail }
            "4" { Enable-DisableUser }
            "5" { Reset-UserPassword }
            "6" { Show-FolderAccessMenu }
            "7" { Remove-GateUser }
            "B" { return }
        }
    }
}

Export-ModuleMember -Function *
