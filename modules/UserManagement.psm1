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

function ConvertFrom-SecureStringPlain {
    <#
    .SYNOPSIS
        Convert SecureString to plaintext for validation only.
        Uses NetworkCredential (shorter-lived than PtrToStringBSTR).
    #>
    param([System.Security.SecureString]$SecurePassword)
    return (New-Object System.Net.NetworkCredential("", $SecurePassword)).Password
}

function Test-PasswordPolicy {
    param(
        [System.Security.SecureString]$SecurePassword,
        [string]$Username
    )

    $settings = Get-Settings
    $policy = if ($settings -and $settings.PasswordPolicy) { $settings.PasswordPolicy } else { $null }
    $minLen = if ($policy -and $policy.MinLength) { $policy.MinLength } else { 8 }
    $reqUpper = if ($policy) { $policy.RequireUppercase } else { $true }
    $reqLower = if ($policy) { $policy.RequireLowercase } else { $true }
    $reqDigit = if ($policy) { $policy.RequireDigit } else { $true }
    $reqSpecial = if ($policy) { $policy.RequireSpecialChar } else { $false }

    $plain = ConvertFrom-SecureStringPlain $SecurePassword
    $errors = @()

    if ($plain.Length -lt $minLen) {
        $errors += "Must be at least $minLen characters"
    }
    if ($reqUpper -and $plain -cnotmatch '[A-Z]') {
        $errors += "Must contain at least one uppercase letter"
    }
    if ($reqLower -and $plain -cnotmatch '[a-z]') {
        $errors += "Must contain at least one lowercase letter"
    }
    if ($reqDigit -and $plain -notmatch '\d') {
        $errors += "Must contain at least one digit"
    }
    if ($reqSpecial -and $plain -notmatch '[!@#$%^&*()_+\-=\[\]{}|;:,.<>?/~`]') {
        $errors += "Must contain at least one special character"
    }
    if ($Username -and $plain -eq $Username) {
        $errors += "Password cannot be the same as username"
    }

    $plain = $null
    return $errors
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
    Write-MenuOption "1" "Standard User (SFTP-only)"
    Write-MenuOption "2" "Shell User (SSH + SFTP)"
    $typeChoice = Read-MenuChoice "Select user type"

    if ($typeChoice -notin @("1", "2")) {
        Write-Step "Invalid user type selection." -Type Error
        Pause-Menu
        return
    }
    $isSFTPOnly = ($typeChoice -eq "1")

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

    # Password policy check
    $policyErrors = Test-PasswordPolicy -SecurePassword $securePass -Username $username
    if ($policyErrors.Count -gt 0) {
        Write-Step "Password does not meet policy requirements:" -Type Error
        foreach ($err in $policyErrors) {
            Write-Host "    - $err" -ForegroundColor Red
        }
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

        # Add to Users group
        try {
            Add-LocalGroupMember -Group "Users" -Member $username -ErrorAction Stop
            Write-Step "Added to 'Users' group." -Type Success
        }
        catch {
            Write-Step "Warning: Failed to add to 'Users' group: $_" -Type Warning
        }

        # SFTP-only group
        if ($isSFTPOnly) {
            $sftpGroup = $settings.SFTPOnlyGroup
            # Create group if it doesn't exist
            $group = Get-LocalGroup -Name $sftpGroup -ErrorAction SilentlyContinue
            if (-not $group) {
                New-LocalGroup -Name $sftpGroup -Description "SFTP-only access users"
                Write-Step "Created group '$sftpGroup'." -Type Info
            }
            try {
                Add-LocalGroupMember -Group $sftpGroup -Member $username -ErrorAction Stop
                Write-Step "Added to '$sftpGroup' group (SFTP-only)." -Type Success
            }
            catch {
                Write-Step "Failed to add to SFTP group. Rolling back user creation..." -Type Error
                Remove-LocalUser -Name $username -ErrorAction SilentlyContinue
                throw "SFTP group assignment failed: $_"
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

        Write-Log "User '$username' created. Type: $(if ($isSFTPOnly) {'SFTP-only'} else {'Shell'})"
        Write-Host ""
        Write-Step "User '$username' provisioned successfully!" -Type Success
    }
    catch {
        Write-Step "Failed to create user: $_" -Type Error
        Write-Log "User creation failed for '$username': $_" -Level "ERROR"
    }

    Pause-Menu
}

function Set-UserDirectoryPermissions {
    param(
        [string]$Username,
        [string]$Path
    )

    Write-Step "Setting NTFS permissions for '$Username' on $Path..." -Type Info

    try {
        $acl = New-AdminSystemAcl -Path $Path

        # User modify (read, write, execute, delete - but not change permissions)
        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Username, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($userRule)

        Set-Acl -Path $Path -AclObject $acl
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

    # Pre-fetch group members once (not per-user)
    $sftpMembers = @()
    try {
        $sftpMembers = @(Get-LocalGroupMember -Group $sftpGroup -ErrorAction SilentlyContinue)
    }
    catch {}

    foreach ($user in $users) {
        $isSFTP = $sftpMembers | Where-Object { $_.Name -eq "$($env:COMPUTERNAME)\$($user.Name)" }
        $isSFTP = [bool]$isSFTP

        $type = if ($isSFTP) { "SFTP-only" } else { "Shell" }
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
    try {
        $allGroups = Get-LocalGroup -ErrorAction SilentlyContinue
        foreach ($grp in $allGroups) {
            $members = Get-LocalGroupMember -Group $grp.Name -ErrorAction SilentlyContinue
            if ($members.Name -like "*\$username") {
                $groups += $grp.Name
                if ($grp.Name -eq $sftpGroup) { $isSFTP = $true }
            }
        }
    }
    catch {}

    Write-Host "  User Type:         " -NoNewline
    if ($isSFTP) { Write-Host "SFTP-only (restricted)" -ForegroundColor Yellow }
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

    # Password policy check
    $policyErrors = Test-PasswordPolicy -SecurePassword $newPass -Username $username
    if ($policyErrors.Count -gt 0) {
        Write-Step "Password does not meet policy requirements:" -Type Error
        foreach ($err in $policyErrors) {
            Write-Host "    - $err" -ForegroundColor Red
        }
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

function Show-UserManagementMenu {
    while ($true) {
        $choice = Select-MenuOption -Title "User Management" -Items @(
            @{ Key = "1"; Label = "Create New User" }
            @{ Key = "2"; Label = "List Users" }
            @{ Key = "3"; Label = "View User Detail" }
            @{ Key = "4"; Label = "Enable/Disable User" }
            @{ Key = "5"; Label = "Reset User Password" }
            @{ Key = "6"; Label = "Remove User" }
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
            "6" { Remove-GateUser }
            "B" { return }
        }
    }
}

Export-ModuleMember -Function *
