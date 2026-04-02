# ============================================================================
# WinGateKeeper - Application Control Module
# Scan installed apps from Windows, block/unblock per user via NTFS Deny
# AppLocker policy management for advanced control
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

function Get-InstalledApps {
    <# Scan Windows for installed applications — returns array of @{Name; Path; Source} #>
    $apps = @{}

    # 1. Start Menu shortcuts (most reliable for GUI apps)
    $shortcutDirs = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    )
    foreach ($dir in $shortcutDirs) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem -Path $dir -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($_.FullName)
                $target = $shortcut.TargetPath
                if ($target -and (Test-Path $target) -and $target -match '\.(exe|msc)$') {
                    $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                    if (-not $apps.ContainsKey($target.ToLower())) {
                        $apps[$target.ToLower()] = @{
                            Name   = $name
                            Path   = $target
                            Source = "Start Menu"
                        }
                    }
                }
            }
            catch {}
        }
    }

    # 2. Registry Uninstall keys (for installed programs)
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($regPath in $regPaths) {
        Get-ItemProperty $regPath -ErrorAction SilentlyContinue | ForEach-Object {
            $displayName = $_.DisplayName
            $installLocation = $_.InstallLocation
            $displayIcon = $_.DisplayIcon
            if ($displayName -and $installLocation -and (Test-Path $installLocation)) {
                $exes = Get-ChildItem -Path $installLocation -Filter "*.exe" -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($exes) {
                    $target = $exes.FullName
                    if (-not $apps.ContainsKey($target.ToLower())) {
                        $apps[$target.ToLower()] = @{
                            Name   = $displayName
                            Path   = $target
                            Source = "Registry"
                        }
                    }
                }
            }
            elseif ($displayName -and $displayIcon -and ($displayIcon -match '^(.+\.exe)')) {
                $iconExe = $Matches[1]
                if ((Test-Path $iconExe) -and -not $apps.ContainsKey($iconExe.ToLower())) {
                    $apps[$iconExe.ToLower()] = @{
                        Name   = $displayName
                        Path   = $iconExe
                        Source = "Registry"
                    }
                }
            }
        }
    }

    # 3. Common system tools (always include these)
    $systemTools = @(
        @{ Name = "Control Panel";          Path = "$env:SystemRoot\System32\control.exe" },
        @{ Name = "Command Prompt (cmd)";   Path = "$env:SystemRoot\System32\cmd.exe" },
        @{ Name = "PowerShell";             Path = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" },
        @{ Name = "Task Manager";           Path = "$env:SystemRoot\System32\Taskmgr.exe" },
        @{ Name = "Registry Editor";        Path = "$env:SystemRoot\regedit.exe" },
        @{ Name = "MMC Console";            Path = "$env:SystemRoot\System32\mmc.exe" },
        @{ Name = "Event Viewer";           Path = "$env:SystemRoot\System32\eventvwr.exe" },
        @{ Name = "Services";               Path = "$env:SystemRoot\System32\services.msc" },
        @{ Name = "File Explorer";          Path = "$env:SystemRoot\explorer.exe" },
        @{ Name = "Notepad";                Path = "$env:SystemRoot\System32\notepad.exe" },
        @{ Name = "Remote Desktop Client";  Path = "$env:SystemRoot\System32\mstsc.exe" },
        @{ Name = "Disk Management";        Path = "$env:SystemRoot\System32\diskmgmt.msc" },
        @{ Name = "Device Manager";         Path = "$env:SystemRoot\System32\devmgmt.msc" },
        @{ Name = "Computer Management";    Path = "$env:SystemRoot\System32\compmgmt.msc" }
    )
    foreach ($tool in $systemTools) {
        if ((Test-Path $tool.Path) -and -not $apps.ContainsKey($tool.Path.ToLower())) {
            $apps[$tool.Path.ToLower()] = @{
                Name   = $tool.Name
                Path   = $tool.Path
                Source = "System"
            }
        }
    }

    # Sort by name and return as array
    return @($apps.Values | Sort-Object { $_.Name })
}

function Get-UserBlockedApps {
    <# Get list of exe paths that have NTFS Deny for a user #>
    param([string]$Username)

    $identity = if ($Username -match '\\') { $Username } else { "$env:COMPUTERNAME\$Username" }
    $blocked = @()

    $apps = Get-InstalledApps
    foreach ($app in $apps) {
        if (Test-Path $app.Path) {
            try {
                $acl = Get-Acl $app.Path -ErrorAction SilentlyContinue
                $denyRule = $acl.Access | Where-Object {
                    $_.IdentityReference.Value -eq $identity -and
                    $_.AccessControlType -eq "Deny"
                }
                if ($denyRule) {
                    $blocked += $app.Path.ToLower()
                }
            }
            catch {}
        }
    }
    return $blocked
}

function Block-AppForUser {
    param(
        [string]$Username,
        [string]$AppPath
    )
    $identity = if ($Username -match '\\') { $Username } else { "$env:COMPUTERNAME\$Username" }
    if (-not (Test-Path $AppPath)) { return $false }
    try {
        $acl = Get-Acl $AppPath
        $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, "ReadAndExecute", "Deny"
        )
        $acl.AddAccessRule($denyRule)
        Set-Acl -Path $AppPath -AclObject $acl -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

function Unblock-AppForUser {
    param(
        [string]$Username,
        [string]$AppPath
    )
    $identity = if ($Username -match '\\') { $Username } else { "$env:COMPUTERNAME\$Username" }
    if (-not (Test-Path $AppPath)) { return $false }
    try {
        $acl = Get-Acl $AppPath
        $rulesToRemove = $acl.Access | Where-Object {
            $_.IdentityReference.Value -eq $identity -and
            $_.AccessControlType -eq "Deny"
        }
        foreach ($rule in $rulesToRemove) {
            $acl.RemoveAccessRule($rule) | Out-Null
        }
        Set-Acl -Path $AppPath -AclObject $acl -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

# ============================================================================
# AppLocker Management
# ============================================================================

function Test-AppLockerAvailable {
    $svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    return [bool]$svc
}

function Show-AppLockerStatus {
    Write-MenuHeader "AppLocker Status"

    Write-Host ""
    Write-Host "  AppIDSvc Service         " -NoNewline
    $svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "Running" -ForegroundColor Green
    }
    elseif ($svc) {
        Write-Host "$($svc.Status)" -ForegroundColor Yellow
    }
    else {
        Write-Host "Not available (requires Enterprise/Server edition)" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "  AppLocker Rules:" -ForegroundColor White
    Write-Host ("  " + "-" * 50) -ForegroundColor DarkGray
    try {
        $policies = Get-AppLockerPolicy -Effective -ErrorAction Stop
        foreach ($collection in $policies.RuleCollections) {
            if ($collection.Count -gt 0) {
                $typeName = $collection[0].GetType().Name -replace 'Rule$',''
                Write-Host "  $typeName : $($collection.Count) rules" -ForegroundColor Cyan
                foreach ($rule in $collection) {
                    $action = $rule.Action
                    $color = if ($action -eq "Allow") { "Green" } else { "Red" }
                    Write-Host "    $action  $($rule.Name)" -ForegroundColor $color
                }
            }
        }
    }
    catch {
        Write-Host "  (no policies or AppLocker unavailable)" -ForegroundColor DarkGray
    }

    Pause-Menu
}

function New-AppLockerRule {
    param([string]$Action = "Deny")

    Write-MenuHeader "Create AppLocker $Action Rule"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }

    # Enable AppIDSvc if needed
    $svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Step "AppLocker not available on this edition." -Type Error
        Pause-Menu
        return
    }
    if ($svc.Status -ne "Running") {
        Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service AppIDSvc -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  Enter full path to exe (e.g. C:\Program Files\App\app.exe): " -ForegroundColor White -NoNewline
    $appPath = (Read-Host).Trim()
    if (-not $appPath) { return }

    Write-Host "  Apply to:" -ForegroundColor White
    Write-MenuOption "1" "Specific user"
    Write-MenuOption "2" "Group"
    $targetChoice = Read-MenuChoice

    $targetName = ""
    if ($targetChoice -eq "1") {
        Write-Host "  Username: " -ForegroundColor White -NoNewline
        $targetName = (Read-Host).Trim()
        if ($targetName -and $targetName -notmatch '\\') { $targetName = "$env:COMPUTERNAME\$targetName" }
    }
    elseif ($targetChoice -eq "2") {
        Write-Host "  Group name: " -ForegroundColor White -NoNewline
        $targetName = (Read-Host).Trim()
    }
    else { return }
    if (-not $targetName) { return }

    try {
        $account = New-Object System.Security.Principal.NTAccount($targetName)
        $sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value

        $ruleXml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="$([guid]::NewGuid())" Name="$Action $appPath for $targetName (WinGateKeeper)" Description="Created by WinGateKeeper" UserOrGroupSid="$sid" Action="$Action">
      <Conditions>
        <FilePathCondition Path="$appPath" />
      </Conditions>
    </FilePathRule>
  </RuleCollection>
</AppLockerPolicy>
"@
        $ruleXml | Set-AppLockerPolicy -Merge -ErrorAction Stop
        Write-Step "AppLocker $Action rule created." -Type Success
        Write-Log "AppLocker $Action : $targetName -> $appPath"
    }
    catch {
        Write-Step "Failed: $_" -Type Error
    }

    Pause-Menu
}

# ============================================================================
# Quick Block UI — scans real installed apps
# ============================================================================

function Show-QuickBlockMenu {
    param([string]$Username)

    if (-not $Username) {
        Write-Host "  Enter username: " -ForegroundColor White -NoNewline
        $Username = (Read-Host).Trim()
    }

    $user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Step "User '$Username' not found." -Type Error
        Pause-Menu
        return
    }

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }

    # Scan installed apps once
    Write-Host "  Scanning installed applications..." -ForegroundColor DarkGray
    $allApps = Get-InstalledApps
    if ($allApps.Count -eq 0) {
        Write-Step "No applications found." -Type Warning
        Pause-Menu
        return
    }

    # Pagination
    $pageSize = 15
    $page = 0
    $totalPages = [Math]::Ceiling($allApps.Count / $pageSize)

    while ($true) {
        Clear-Host
        Write-MenuHeader "App Control: $Username (Page $($page+1)/$totalPages)"

        $blockedPaths = Get-UserBlockedApps -Username $Username

        Write-Host ""
        $startIdx = $page * $pageSize
        $endIdx = [Math]::Min($startIdx + $pageSize, $allApps.Count)

        for ($i = $startIdx; $i -lt $endIdx; $i++) {
            $app = $allApps[$i]
            $isBlocked = $blockedPaths -contains $app.Path.ToLower()
            $num = ($i + 1).ToString().PadLeft(3)
            $mark = if ($isBlocked) { "[BLOCKED]" } else { "[  OK   ]" }
            $color = if ($isBlocked) { "Red" } else { "Green" }

            Write-Host "  $num. " -NoNewline
            Write-Host "$mark " -ForegroundColor $color -NoNewline
            Write-Host "$($app.Name)" -ForegroundColor White
        }

        Write-Host ""
        Write-Host ("  " + "-" * 56) -ForegroundColor DarkGray
        $nav = @()
        if ($page -gt 0) { $nav += "[P]rev" }
        if ($page -lt $totalPages - 1) { $nav += "[N]ext" }
        $nav += "[A]ll Block"
        $nav += "[U]nblock All"
        $nav += "[S]ave & Back"
        Write-Host "  $($nav -join '  |  ')" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Enter number to toggle, or command: " -ForegroundColor White -NoNewline
        $input = (Read-Host).Trim().ToUpper()

        if ($input -eq "S") { return }
        if ($input -eq "P" -and $page -gt 0) { $page--; continue }
        if ($input -eq "N" -and $page -lt $totalPages - 1) { $page++; continue }

        if ($input -eq "A") {
            Write-Host "  Blocking all apps for '$Username'..." -ForegroundColor Yellow
            $count = 0
            foreach ($app in $allApps) {
                if ($blockedPaths -notcontains $app.Path.ToLower()) {
                    if (Block-AppForUser -Username $Username -AppPath $app.Path) { $count++ }
                }
            }
            Write-Step "Blocked $count apps." -Type Success
            Write-Log "Blocked all apps ($count) for '$Username'."
            Start-Sleep -Seconds 1
            continue
        }

        if ($input -eq "U") {
            Write-Host "  Unblocking all apps for '$Username'..." -ForegroundColor Green
            $count = 0
            foreach ($app in $allApps) {
                if ($blockedPaths -contains $app.Path.ToLower()) {
                    if (Unblock-AppForUser -Username $Username -AppPath $app.Path) { $count++ }
                }
            }
            Write-Step "Unblocked $count apps." -Type Success
            Write-Log "Unblocked all apps ($count) for '$Username'."
            Start-Sleep -Seconds 1
            continue
        }

        # Toggle specific app
        $num = 0
        if ([int]::TryParse($input, [ref]$num) -and $num -gt 0 -and $num -le $allApps.Count) {
            $app = $allApps[$num - 1]
            if ($blockedPaths -contains $app.Path.ToLower()) {
                if (Unblock-AppForUser -Username $Username -AppPath $app.Path) {
                    Write-Host "  Unblocked: $($app.Name)" -ForegroundColor Green
                }
            }
            else {
                if (Block-AppForUser -Username $Username -AppPath $app.Path) {
                    Write-Host "  Blocked: $($app.Name)" -ForegroundColor Red
                }
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

# ============================================================================
# Main Menu
# ============================================================================

function Show-AppControlMenu {
    while ($true) {
        $choice = Select-MenuOption -Title "Application Control" -Items @(
            @{ Key = "1"; Label = "Block/Unblock Apps for User (scan installed)" }
            @{ Key = "2"; Label = "View Blocked Apps for User" }
            @{ Separator = $true }
            @{ Key = "3"; Label = "AppLocker Status" }
            @{ Key = "4"; Label = "Create AppLocker Allow Rule" }
            @{ Key = "5"; Label = "Create AppLocker Deny Rule" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back" }
        )
        switch ($choice) {
            "1" { Show-QuickBlockMenu }
            "2" {
                Write-MenuHeader "View Blocked Apps"
                Write-Host "  Enter username: " -ForegroundColor White -NoNewline
                $uname = (Read-Host).Trim()
                if ($uname) {
                    Write-Host "  Scanning..." -ForegroundColor DarkGray
                    $blocked = Get-UserBlockedApps -Username $uname
                    $allApps = Get-InstalledApps
                    Write-Host ""
                    if ($blocked.Count -eq 0) {
                        Write-Step "No apps blocked for '$uname'." -Type Info
                    }
                    else {
                        Write-Host "  Blocked apps for '$uname':" -ForegroundColor White
                        foreach ($path in $blocked) {
                            $app = $allApps | Where-Object { $_.Path.ToLower() -eq $path }
                            $name = if ($app) { $app.Name } else { [System.IO.Path]::GetFileName($path) }
                            Write-Host "    [BLOCKED] $name" -ForegroundColor Red
                            Write-Host "              $path" -ForegroundColor DarkGray
                        }
                    }
                }
                Pause-Menu
            }
            "3" { Show-AppLockerStatus }
            "4" { New-AppLockerRule -Action "Allow" }
            "5" { New-AppLockerRule -Action "Deny" }
            "B" { return }
        }
    }
}

Export-ModuleMember -Function *
