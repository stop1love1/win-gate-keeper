# ============================================================================
# AdminGate - User Management Module
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

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

    # Password with confirmation
    Write-Host ""
    Write-Host "  Enter password: " -ForegroundColor White -NoNewline
    $securePass = Read-Host -AsSecureString
    Write-Host "  Confirm password: " -ForegroundColor White -NoNewline
    $confirmPass = Read-Host -AsSecureString

    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPass))
    $matched = ($p1 -eq $p2)
    $p1 = $null; $p2 = $null
    [GC]::Collect()

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
            AccountNeverExpires  = $true
        }
        if ($fullName) { $params.FullName = $fullName }
        if ($description) { $params.Description = $description }

        New-LocalUser @params | Out-Null
        Write-Step "User '$username' created." -Type Success

        # Add to Users group
        Add-LocalGroupMember -Group "Users" -Member $username -ErrorAction SilentlyContinue
        Write-Step "Added to 'Users' group." -Type Success

        # SFTP-only group
        if ($isSFTPOnly) {
            $sftpGroup = $settings.SFTPOnlyGroup
            # Create group if it doesn't exist
            $group = Get-LocalGroup -Name $sftpGroup -ErrorAction SilentlyContinue
            if (-not $group) {
                New-LocalGroup -Name $sftpGroup -Description "SFTP-only access users"
                Write-Step "Created group '$sftpGroup'." -Type Info
            }
            Add-LocalGroupMember -Group $sftpGroup -Member $username -ErrorAction Stop
            Write-Step "Added to '$sftpGroup' group (SFTP-only)." -Type Success
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
        $acl = Get-Acl $Path

        # Remove inheritance
        $acl.SetAccessRuleProtection($true, $false)

        # Clear existing rules
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) } | Out-Null

        # Admin full control
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($adminRule)

        # SYSTEM full control
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($systemRule)

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

    # List current AdminGate users
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

    try {
        Remove-LocalUser -Name $username
        Write-Step "User '$username' removed." -Type Success

        $removeDir = Confirm-Action "Also remove user directory?"
        if ($removeDir) {
            $userDir = Join-Path $settings.UsersRoot $username
            if (Test-Path $userDir) {
                Remove-Item -Path $userDir -Recurse -Force
                Write-Step "Directory removed: $userDir" -Type Success
            }
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

    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($newPass))
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPass))
    $matched = ($p1 -eq $p2)
    $p1 = $null; $p2 = $null
    [GC]::Collect()

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

function Show-UserManagementMenu {
    while ($true) {
        Clear-Host
        Write-MenuHeader "User Management"
        Write-Host ""
        Write-MenuOption "1" "Create New User"
        Write-MenuOption "2" "List Users"
        Write-MenuOption "3" "Enable/Disable User"
        Write-MenuOption "4" "Reset User Password"
        Write-MenuOption "5" "Remove User"
        Write-Separator
        Write-MenuOption "B" "Back to Main Menu"

        $choice = Read-MenuChoice

        switch ($choice) {
            "1" { New-GateUser }
            "2" {
                Write-MenuHeader "User List"
                Show-UserList
                Pause-Menu
            }
            "3" { Enable-DisableUser }
            "4" { Reset-UserPassword }
            "5" { Remove-GateUser }
            "B" { return }
            default { Write-Step "Invalid option." -Type Warning; Start-Sleep -Seconds 1 }
        }
    }
}

Export-ModuleMember -Function *
