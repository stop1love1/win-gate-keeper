# ============================================================================
# WinGateKeeper - Directory Structure & NTFS ACL Module
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force
Import-Module "$PSScriptRoot\UserManagement.psm1" -Force

function Initialize-BaseDirectories {
    Write-MenuHeader "Initialize Base Directory Structure"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    $dirs = @(
        $settings.BasePath,
        $settings.UsersRoot,
        $settings.LogsPath,
        $settings.PowerShellLogging.TranscriptionPath
    )

    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Step "Created: $dir" -Type Success
        }
        else {
            Write-Step "Exists:  $dir" -Type Info
        }
    }

    # Set base path permissions - only Administrators and SYSTEM
    Write-Step "Setting ACLs on base path: $($settings.BasePath)" -Type Info
    $acl = New-AdminSystemAcl -Path $settings.BasePath
    Set-Acl -Path $settings.BasePath -AclObject $acl
    Write-Step "Base directory ACLs configured." -Type Success

    # Users root: Admins + SYSTEM full, Users Traverse only (no ListDirectory)
    Write-Step "Setting ACLs on users root: $($settings.UsersRoot)" -Type Info
    $uAcl = New-AdminSystemAcl -Path $settings.UsersRoot
    $usersTraverseRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Users", "Traverse", "None", "None", "Allow"
    )
    $uAcl.AddAccessRule($usersTraverseRule)
    Set-Acl -Path $settings.UsersRoot -AclObject $uAcl
    Write-Step "Users root ACLs configured." -Type Success
    Write-Log "Base directory structure initialized."

    Write-Host ""
    Write-Step "Directory structure initialized!" -Type Success
    Pause-Menu
}

function Show-DirectoryStatus {
    Write-MenuHeader "Directory Structure Status"

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    $checks = @(
        @{ Label = "Base Path";        Path = $settings.BasePath },
        @{ Label = "Users Root";       Path = $settings.UsersRoot },
        @{ Label = "Logs Path";        Path = $settings.LogsPath },
        @{ Label = "Transcripts Path"; Path = $settings.PowerShellLogging.TranscriptionPath }
    )

    Write-Host ""
    Write-Host "  Directory                              Status" -ForegroundColor White
    Write-Separator

    foreach ($check in $checks) {
        $label = $check.Label.PadRight(36)
        Write-Host "  $label " -NoNewline
        if (Test-Path $check.Path) {
            Write-Host "EXISTS" -ForegroundColor Green
        }
        else {
            Write-Host "MISSING" -ForegroundColor Red
        }
    }

    # Show user directories
    if (Test-Path $settings.UsersRoot) {
        Write-Host ""
        Write-Host "  User Directories:" -ForegroundColor White
        Write-Separator
        $userDirs = Get-ChildItem -Path $settings.UsersRoot -Directory -ErrorAction SilentlyContinue
        if ($userDirs) {
            foreach ($dir in $userDirs) {
                $size = (Get-ChildItem -Path $dir.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
                if (-not $size) { $size = 0 }
                $sizeStr = if ($size -gt 1GB) { "{0:N2} GB" -f ($size / 1GB) }
                           elseif ($size -gt 1MB) { "{0:N2} MB" -f ($size / 1MB) }
                           elseif ($size -gt 1KB) { "{0:N2} KB" -f ($size / 1KB) }
                           else { "$size B" }
                Write-Host "  $($dir.Name.PadRight(30)) $sizeStr" -ForegroundColor Cyan
            }
        }
        else {
            Write-Host "  (no user directories)" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Pause-Menu
}

function Repair-UserPermissions {
    Write-MenuHeader "Repair User Directory Permissions"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }
    $usersRoot = $settings.UsersRoot

    if (-not (Test-Path $usersRoot)) {
        Write-Step "Users root does not exist. Run 'Initialize Base Directories' first." -Type Error
        Pause-Menu
        return
    }

    $userDirs = Get-ChildItem -Path $usersRoot -Directory
    if (-not $userDirs) {
        Write-Step "No user directories found." -Type Warning
        Pause-Menu
        return
    }

    foreach ($dir in $userDirs) {
        $username = $dir.Name
        $localUser = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
        if ($localUser) {
            Set-UserDirectoryPermissions -Username $username -Path $dir.FullName
            Write-Step "'$username' - permissions repaired." -Type Success
        }
        else {
            Write-Step "'$username' - no matching local user, skipping." -Type Warning
        }
    }

    Write-Log "User directory permissions repaired."
    Pause-Menu
}

function Show-DirectoryMenu {
    while ($true) {
        $choice = Select-MenuOption -Title "Directory & Permissions Management" -Items @(
            @{ Key = "1"; Label = "Initialize Base Directories" }
            @{ Key = "2"; Label = "Show Directory Status" }
            @{ Key = "3"; Label = "Repair User Permissions" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back to Main Menu" }
        )
        switch ($choice) {
            "1" { Initialize-BaseDirectories }
            "2" { Show-DirectoryStatus }
            "3" { Repair-UserPermissions }
            "B" { return }
        }
    }
}

Export-ModuleMember -Function *
