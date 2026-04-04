# ============================================================================
# WinGateKeeper - System Reset Module
# Clear all data or reset to factory defaults
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

function Reset-WinGateKeeper {
    Write-MenuHeader "Reset WinGateKeeper"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    Write-Host ""
    Write-Host "  WARNING: This will permanently destroy data!" -ForegroundColor Red
    Write-Host ""
    Write-MenuOption "1" "Clear User Data Only (keep users, delete their files)"
    Write-MenuOption "2" "Remove All Users + Data (keep system config)"
    Write-MenuOption "3" "Full Factory Reset (remove everything)"
    Write-Separator
    Write-MenuOption "B" "Cancel"

    $choice = Read-MenuChoice

    switch ($choice) {
        "1" { Clear-UserData -Settings $settings }
        "2" { Remove-AllUsersAndData -Settings $settings }
        "3" { Invoke-FactoryReset -Settings $settings }
        "B" { return }
        default {
            Write-Step "Invalid option." -Type Warning
            Start-Sleep -Seconds 1
        }
    }
}

function Clear-UserData {
    param([PSCustomObject]$Settings)

    Write-MenuHeader "Clear User Data"

    $usersRoot = $Settings.UsersRoot
    if (-not (Test-Path $usersRoot)) {
        Write-Step "Users root does not exist: $usersRoot" -Type Warning
        Pause-Menu
        return
    }

    $userDirs = Get-ChildItem -Path $usersRoot -Directory -ErrorAction SilentlyContinue
    if (-not $userDirs) {
        Write-Step "No user directories found." -Type Info
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  The following user directories will be emptied:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($dir in $userDirs) {
        $size = (Get-ChildItem -Path $dir.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if (-not $size) { $size = 0 }
        $sizeStr = if ($size -gt 1MB) { "{0:N2} MB" -f ($size / 1MB) }
                   elseif ($size -gt 1KB) { "{0:N2} KB" -f ($size / 1KB) }
                   else { "$size B" }
        Write-Host "  - $($dir.Name) ($sizeStr)" -ForegroundColor White
    }

    Write-Host ""
    if (-not (Confirm-Action "CONFIRM: Delete ALL files inside these directories?")) {
        Write-Step "Operation cancelled." -Type Warning
        Pause-Menu
        return
    }

    # Double confirmation for safety
    Write-Host ""
    Write-Host "  Type 'DELETE' to confirm: " -ForegroundColor Red -NoNewline
    $confirm = (Read-Host).Trim()
    if ($confirm -ne "DELETE") {
        Write-Step "Operation cancelled." -Type Warning
        Pause-Menu
        return
    }

    $cleared = 0
    foreach ($dir in $userDirs) {
        $skipped = 0
        Get-ChildItem -Path $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
                }
                catch {
                    $skipped++
                }
            }
        if ($skipped -eq 0) {
            Write-Step "Cleared: $($dir.Name)" -Type Success
        }
        else {
            Write-Step "Cleared: $($dir.Name) ($skipped files skipped - locked)" -Type Warning
        }
        $cleared++
    }

    Write-Log "Cleared user data for $cleared directories."
    Write-Host ""
    Write-Step "$cleared user directories emptied." -Type Success
    Pause-Menu
}

function Remove-AllUsersAndData {
    param([PSCustomObject]$Settings)

    Write-MenuHeader "Remove All Users & Data"

    $builtIn = @("Administrator", "DefaultAccount", "Guest", "WDAGUtilityAccount")
    $users = @(Get-LocalUser | Where-Object { $_.Name -notin $builtIn })

    if ($users.Count -eq 0) {
        Write-Step "No managed users found." -Type Info
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  The following users will be PERMANENTLY DELETED:" -ForegroundColor Red
    Write-Host ""
    foreach ($user in $users) {
        $status = if ($user.Enabled) { "Enabled" } else { "Disabled" }
        Write-Host "  - $($user.Name) ($status)" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "  User directories under '$($Settings.UsersRoot)' will also be deleted." -ForegroundColor Yellow

    Write-Host ""
    if (-not (Confirm-Action "CONFIRM: Remove ALL $($users.Count) users and their data?")) {
        Write-Step "Operation cancelled." -Type Warning
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  Type 'DELETE ALL' to confirm: " -ForegroundColor Red -NoNewline
    $confirm = (Read-Host).Trim()
    if ($confirm -ne "DELETE ALL") {
        Write-Step "Operation cancelled." -Type Warning
        Pause-Menu
        return
    }

    $removed = 0
    foreach ($user in $users) {
        try {
            # Remove from SFTP group first
            $sftpGroup = $Settings.SFTPOnlyGroup
            try {
                Remove-LocalGroupMember -Group $sftpGroup -Member $user.Name -ErrorAction SilentlyContinue
            }
            catch {}

            # Remove user
            Remove-LocalUser -Name $user.Name -ErrorAction Stop
            Write-Step "Removed user: $($user.Name)" -Type Success

            # Remove directory
            $userDir = Join-Path $Settings.UsersRoot $user.Name
            if (Test-Path $userDir) {
                Remove-Item -Path $userDir -Recurse -Force -ErrorAction Stop
                Write-Step "Removed directory: $($user.Name)" -Type Info
            }

            $removed++
        }
        catch {
            Write-Step "Failed to remove '$($user.Name)': $_" -Type Error
        }
    }

    Write-Log "Removed $removed users and their data."
    Write-Host ""
    Write-Step "$removed users removed." -Type Success
    Pause-Menu
}

function Invoke-FactoryReset {
    param([PSCustomObject]$Settings)

    Write-MenuHeader "FACTORY RESET"

    Write-Host ""
    Write-Host "  " -NoNewline
    Write-Host " !!! DANGER ZONE !!! " -BackgroundColor Red -ForegroundColor White
    Write-Host ""
    Write-Host "  This will:" -ForegroundColor Red
    Write-Host "  1. Remove ALL managed users" -ForegroundColor White
    Write-Host "  2. Delete ALL user directories and data" -ForegroundColor White
    Write-Host "  3. Remove SFTP group ($($Settings.SFTPOnlyGroup))" -ForegroundColor White
    Write-Host "  4. Remove WinGateKeeper Match block from sshd_config" -ForegroundColor White
    Write-Host "  5. Delete WinGateKeeper logs" -ForegroundColor White
    Write-Host "  6. Delete base directories ($($Settings.BasePath))" -ForegroundColor White
    Write-Host "  7. Disable audit policies set by WinGateKeeper" -ForegroundColor White
    Write-Host "  8. Stop & remove ALL Hyper-V VMs, switches, and data" -ForegroundColor White
    Write-Host ""
    Write-Host "  OpenSSH Server will NOT be uninstalled." -ForegroundColor Yellow
    Write-Host "  Settings file (config/settings.json) will be preserved." -ForegroundColor Yellow

    Write-Host ""
    if (-not (Confirm-Action "Are you ABSOLUTELY SURE you want to factory reset?")) {
        Write-Step "Operation cancelled." -Type Warning
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  Type 'FACTORY RESET' to confirm: " -ForegroundColor Red -NoNewline
    $confirm = (Read-Host).Trim()
    if ($confirm -ne "FACTORY RESET") {
        Write-Step "Operation cancelled." -Type Warning
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host ("  " + "=" * 50) -ForegroundColor Red

    # Step 1: Remove all managed users
    Write-Host ""
    Write-Step "Step 1/8: Removing managed users..." -Type Info
    $builtIn = @("Administrator", "DefaultAccount", "Guest", "WDAGUtilityAccount")
    $users = @(Get-LocalUser | Where-Object { $_.Name -notin $builtIn })
    foreach ($user in $users) {
        try {
            Remove-LocalUser -Name $user.Name -ErrorAction Stop
            Write-Step "Removed user: $($user.Name)" -Type Success
        }
        catch {
            Write-Step "Failed to remove '$($user.Name)': $_" -Type Error
        }
    }

    # Step 2: Delete user directories
    Write-Step "Step 2/8: Deleting user directories..." -Type Info
    if (Test-Path $Settings.UsersRoot) {
        $userDirs = Get-ChildItem -Path $Settings.UsersRoot -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $userDirs) {
            try {
                Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                Write-Step "Deleted: $($dir.Name)" -Type Info
            }
            catch {
                Write-Step "Failed to delete '$($dir.Name)': $_" -Type Error
            }
        }
    }

    # Step 3: Remove SFTP group
    Write-Step "Step 3/8: Removing SFTP group..." -Type Info
    try {
        $group = Get-LocalGroup -Name $Settings.SFTPOnlyGroup -ErrorAction SilentlyContinue
        if ($group) {
            Remove-LocalGroup -Name $Settings.SFTPOnlyGroup -ErrorAction Stop
            Write-Step "Removed group '$($Settings.SFTPOnlyGroup)'." -Type Success
        }
        else {
            Write-Step "SFTP group not found, skipping." -Type Info
        }
    }
    catch {
        Write-Step "Failed to remove group: $_" -Type Error
    }

    # Step 4: Clean sshd_config
    Write-Step "Step 4/8: Cleaning sshd_config..." -Type Info
    $sshdConfig = $Settings.SSHConfigPath
    if (Test-Path $sshdConfig) {
        try {
            $content = Get-Content $sshdConfig -Raw
            $lines = $content -split "`r?`n"
            $inBlock = $false
            $cleanedLines = @()
            foreach ($line in $lines) {
                if ($line -match "^# BEGIN (AdminGate|WinGateKeeper)") {
                    $inBlock = $true
                    continue
                }
                if ($inBlock) {
                    if ($line -match "^# END (AdminGate|WinGateKeeper)") {
                        $inBlock = $false
                        continue
                    }
                    continue
                }
                $cleanedLines += $line
            }
            $cleaned = ($cleanedLines -join "`r`n").TrimEnd() + "`r`n"
            [System.IO.File]::WriteAllText($sshdConfig, $cleaned, [System.Text.UTF8Encoding]::new($false))
            Restart-SSHDService | Out-Null
            Write-Step "WinGateKeeper config block removed from sshd_config." -Type Success
        }
        catch {
            Write-Step "Failed to clean sshd_config: $_" -Type Error
        }
    }

    # Step 5: Delete logs
    Write-Step "Step 5/8: Deleting WinGateKeeper logs..." -Type Info
    if (Test-Path $Settings.LogsPath) {
        try {
            Get-ChildItem -Path $Settings.LogsPath -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction Stop
            Write-Step "Logs deleted." -Type Success
        }
        catch {
            Write-Step "Failed to delete some logs: $_" -Type Warning
        }
    }

    # Step 6: Delete base directories
    Write-Step "Step 6/8: Deleting base directories..." -Type Info
    if (Test-Path $Settings.BasePath) {
        try {
            Remove-Item -Path $Settings.BasePath -Recurse -Force -ErrorAction Stop
            Write-Step "Deleted: $($Settings.BasePath)" -Type Success
        }
        catch {
            Write-Step "Failed to delete base path: $_" -Type Error
        }
    }

    # Step 7: Disable WinGateKeeper audit policies
    Write-Step "Step 7/8: Resetting audit policies..." -Type Info
    try {
        # Remove PowerShell logging policies
        $psPolicies = @(
            "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging",
            "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging",
            "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription"
        )
        foreach ($regPath in $psPolicies) {
            if (Test-Path $regPath) {
                Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Step "PowerShell logging policies removed." -Type Success
    }
    catch {
        Write-Step "Failed to reset some policies: $_" -Type Warning
    }

    # Step 8: Hyper-V cleanup
    Write-Step "Step 8/8: Cleaning up Hyper-V resources..." -Type Info
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        $hvVMs = @(Get-VM -ErrorAction SilentlyContinue)
        if ($hvVMs.Count -gt 0) {
            foreach ($vm in $hvVMs) {
                try {
                    if ($vm.State -ne 'Off') {
                        Stop-VM -Name $vm.Name -Force -TurnOff -ErrorAction Stop
                    }
                    # Get VHD paths before removal
                    $vhds = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue |
                        Where-Object { $_.Path } | Select-Object -ExpandProperty Path)
                    Remove-VM -Name $vm.Name -Force -ErrorAction Stop
                    # Delete associated VHDs
                    foreach ($vhd in $vhds) {
                        if (Test-Path $vhd) {
                            Remove-Item $vhd -Force -ErrorAction SilentlyContinue
                        }
                    }
                    Write-Step "Removed VM: $($vm.Name)" -Type Info
                }
                catch {
                    Write-Step "Failed to remove VM '$($vm.Name)': $_" -Type Error
                }
            }
        }
        else {
            Write-Step "No VMs found." -Type Info
        }

        # Remove virtual switches (except Default Switch)
        $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object Name -ne 'Default Switch')
        foreach ($sw in $switches) {
            try {
                Remove-VMSwitch -Name $sw.Name -Force -ErrorAction Stop
                Write-Step "Removed switch: $($sw.Name)" -Type Info
            }
            catch {
                Write-Step "Failed to remove switch '$($sw.Name)': $_" -Type Error
            }
        }

        # Delete Hyper-V directories
        $hvSettings = $Settings.HyperV
        if ($hvSettings) {
            $hvPaths = @($hvSettings.DefaultVMPath, $hvSettings.DefaultVHDPath, $hvSettings.DefaultBackupPath) | Where-Object { $_ }
            foreach ($p in $hvPaths) {
                if (Test-Path $p) {
                    try {
                        Remove-Item -Path $p -Recurse -Force -ErrorAction Stop
                        Write-Step "Deleted: $p" -Type Info
                    }
                    catch {
                        Write-Step "Failed to delete '$p': $_" -Type Error
                    }
                }
            }
        }
        Write-Step "Hyper-V cleanup done." -Type Success
    }
    else {
        Write-Step "Hyper-V not available, skipping." -Type Info
    }

    Write-Host ""
    Write-Host ("  " + "=" * 50) -ForegroundColor Red
    Write-Host ""
    Write-Step "Factory reset complete." -Type Success
    Write-Step "WinGateKeeper has been restored to a clean state." -Type Info
    Write-Step "Run Quick Setup [0] to reconfigure from scratch." -Type Info

    Write-Log "FACTORY RESET performed."
    Pause-Menu
}

function Show-ResetMenu {
    while ($true) {
        $choice = Select-MenuOption -Title "System Reset" -BeforeRender {
            Write-Host ""
            Write-Host "  WARNING: These operations are DESTRUCTIVE!" -ForegroundColor Red
        } -Items @(
            @{ Key = "1"; Label = "Clear User Data Only (keep users)" }
            @{ Key = "2"; Label = "Remove All Users + Data" }
            @{ Key = "3"; Label = "Full Factory Reset" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back to Main Menu" }
        )
        switch ($choice) {
            "1" {
                $settings = Get-Settings
                if ($settings) { Clear-UserData -Settings $settings }
                else { Write-Step "Cannot load settings." -Type Error; Pause-Menu }
            }
            "2" {
                $settings = Get-Settings
                if ($settings) { Remove-AllUsersAndData -Settings $settings }
                else { Write-Step "Cannot load settings." -Type Error; Pause-Menu }
            }
            "3" {
                $settings = Get-Settings
                if ($settings) { Invoke-FactoryReset -Settings $settings }
                else { Write-Step "Cannot load settings." -Type Error; Pause-Menu }
            }
            "B" { return }
            default { Write-Step "Invalid option." -Type Warning; Start-Sleep -Seconds 1 }
        }
    }
}

Export-ModuleMember -Function *
