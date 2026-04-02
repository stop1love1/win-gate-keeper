# ============================================================================
# WinGateKeeper - Audit Policy & PowerShell Logging Module
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

function Enable-FileAudit {
    Write-MenuHeader "Enable File System Audit Policy"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    Write-Step "Enabling audit policy for Object Access (File System)..." -Type Info

    # Enable success and failure auditing for Object Access
    # Use GUIDs instead of English names for non-English OS compatibility
    $auditCmds = @(
        @{ Name = "File System";         GUID = "{0CCE921D-69AE-11D9-BED3-505054503030}"; Success = $true; Failure = $true },
        @{ Name = "Logon";               GUID = "{0CCE9215-69AE-11D9-BED3-505054503030}"; Success = $true; Failure = $true },
        @{ Name = "Logoff";              GUID = "{0CCE9216-69AE-11D9-BED3-505054503030}"; Success = $true; Failure = $false },
        @{ Name = "Handle Manipulation";  GUID = "{0CCE9223-69AE-11D9-BED3-505054503030}"; Success = $true; Failure = $false },
        @{ Name = "File Share";          GUID = "{0CCE9224-69AE-11D9-BED3-505054503030}"; Success = $true; Failure = $true }
    )

    foreach ($cmd in $auditCmds) {
        $auditArgs = @("/set", "/subcategory:$($cmd.GUID)")
        if ($cmd.Success) { $auditArgs += "/success:enable" }
        if ($cmd.Failure) { $auditArgs += "/failure:enable" }
        $result = & auditpol @auditArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Step "$($cmd.Name) auditing enabled." -Type Success
        }
        else {
            Write-Step "$($cmd.Name) audit failed (code $LASTEXITCODE)." -Type Warning
        }
    }

    Write-Log "File system audit policies enabled."

    Write-Host ""
    Write-Step "Audit policies configured!" -Type Success
    Pause-Menu
}

function Enable-DirectoryAudit {
    Write-MenuHeader "Enable Audit on User Directories"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }
    $usersRoot = $settings.UsersRoot

    if (-not (Test-Path $usersRoot)) {
        Write-Step "Users root does not exist. Initialize directories first." -Type Error
        Pause-Menu
        return
    }

    Write-Step "Applying audit rules to: $usersRoot" -Type Info

    $acl = Get-Acl $usersRoot

    # Audit rule: track all file modifications by Everyone
    $auditRule = New-Object System.Security.AccessControl.FileSystemAuditRule(
        "Everyone",
        "Modify, Delete, Write",
        "ContainerInherit, ObjectInherit",
        "None",
        "Success, Failure"
    )

    # Check for existing rule to avoid duplicates
    $existingRules = $acl.GetAuditRules($true, $false, [System.Security.Principal.NTAccount])
    $alreadyExists = $existingRules | Where-Object {
        $_.IdentityReference.Value -eq "Everyone" -and
        ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Modify)
    }
    if (-not $alreadyExists) {
        $acl.AddAuditRule($auditRule)
        Set-Acl -Path $usersRoot -AclObject $acl
    }

    Write-Step "Audit SACL applied to user directories." -Type Success
    Write-Log "Directory audit SACL applied to $usersRoot."

    # Apply to each user subdirectory
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
        Write-Step "Audit applied: $($dir.Name)" -Type Info
    }

    Write-Host ""
    Write-Step "Directory auditing configured!" -Type Success
    Pause-Menu
}

function Enable-PowerShellLogging {
    Write-MenuHeader "Enable PowerShell Logging"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }
    $psLog = $settings.PowerShellLogging

    # Script Block Logging
    Write-Step "Enabling Script Block Logging..." -Type Info
    $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "EnableScriptBlockLogging" -Value 1 -Type DWord
    Write-Step "Script Block Logging enabled." -Type Success

    # Module Logging
    Write-Step "Enabling Module Logging..." -Type Info
    $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "EnableModuleLogging" -Value 1 -Type DWord

    $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "*" -Value "*" -Type String
    Write-Step "Module Logging enabled (all modules)." -Type Success

    # Transcription
    Write-Step "Enabling PowerShell Transcription..." -Type Info
    $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "EnableTranscripting" -Value 1 -Type DWord
    Set-ItemProperty -Path $regPath -Name "EnableInvocationHeader" -Value 1 -Type DWord

    $transcriptPath = $psLog.TranscriptionPath
    if (-not (Test-Path $transcriptPath)) {
        New-Item -ItemType Directory -Path $transcriptPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name "OutputDirectory" -Value $transcriptPath -Type String
    Write-Step "Transcription enabled. Output: $transcriptPath" -Type Success

    Write-Log "PowerShell logging fully enabled."

    Write-Host ""
    Write-Step "PowerShell logging configured!" -Type Success
    Pause-Menu
}

function Show-AuditStatus {
    Write-MenuHeader "Audit & Logging Status"

    Write-Host ""
    Write-Host "  Windows Audit Policies:" -ForegroundColor White
    Write-Separator

    $auditOutput = auditpol /get /category:"Object Access" 2>&1
    if ($auditOutput) {
        foreach ($line in $auditOutput) {
            if ($line -match "^\s+(File System|File Share|Handle Manipulation)") {
                $parts = $line.Trim() -split "\s{2,}"
                $name = $parts[0].PadRight(30)
                $value = if ($parts.Count -gt 1) { $parts[1] } else { "Unknown" }
                $color = if ($value -match "Success") { "Green" } else { "Red" }
                Write-Host "  $name " -NoNewline
                Write-Host "$value" -ForegroundColor $color
            }
        }
    }

    $auditOutput = auditpol /get /category:"Logon/Logoff" 2>&1
    if ($auditOutput) {
        foreach ($line in $auditOutput) {
            if ($line -match "^\s+(Logon|Logoff)\s") {
                $parts = $line.Trim() -split "\s{2,}"
                $name = $parts[0].PadRight(30)
                $value = if ($parts.Count -gt 1) { $parts[1] } else { "Unknown" }
                $color = if ($value -match "Success") { "Green" } else { "Red" }
                Write-Host "  $name " -NoNewline
                Write-Host "$value" -ForegroundColor $color
            }
        }
    }

    Write-Host ""
    Write-Host "  PowerShell Logging:" -ForegroundColor White
    Write-Separator

    # Script Block Logging
    $sbLog = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -ErrorAction SilentlyContinue
    Write-Host "  Script Block Logging     " -NoNewline
    if ($sbLog -and $sbLog.EnableScriptBlockLogging -eq 1) {
        Write-Host "Enabled" -ForegroundColor Green
    }
    else {
        Write-Host "Disabled" -ForegroundColor Red
    }

    # Module Logging
    $mlLog = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" -ErrorAction SilentlyContinue
    Write-Host "  Module Logging           " -NoNewline
    if ($mlLog -and $mlLog.EnableModuleLogging -eq 1) {
        Write-Host "Enabled" -ForegroundColor Green
    }
    else {
        Write-Host "Disabled" -ForegroundColor Red
    }

    # Transcription
    $trLog = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription" -ErrorAction SilentlyContinue
    Write-Host "  Transcription            " -NoNewline
    if ($trLog -and $trLog.EnableTranscripting -eq 1) {
        Write-Host "Enabled" -ForegroundColor Green
        if ($trLog.OutputDirectory) {
            Write-Host "  Transcript Path          $($trLog.OutputDirectory)" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "Disabled" -ForegroundColor Red
    }

    Write-Host ""
    Pause-Menu
}

function Show-RecentLogs {
    Write-MenuHeader "Recent WinGateKeeper Logs"

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }
    $logDir = $settings.LogsPath
    $logFile = Join-Path $logDir "wingatekeeper_$(Get-Date -Format 'yyyyMMdd').log"
    if (-not (Test-Path $logFile)) {
        $legacyLog = Join-Path $logDir "admingate_$(Get-Date -Format 'yyyyMMdd').log"
        if (Test-Path $legacyLog) { $logFile = $legacyLog }
    }

    if (-not (Test-Path $logFile)) {
        Write-Step "No log file found for today." -Type Warning
        Pause-Menu
        return
    }

    Write-Host ""
    $lines = Get-Content $logFile -Tail 30
    foreach ($line in $lines) {
        if ($line -match "\[ERROR\]") {
            Write-Host "  $line" -ForegroundColor Red
        }
        elseif ($line -match "\[WARNING\]") {
            Write-Host "  $line" -ForegroundColor Yellow
        }
        else {
            Write-Host "  $line" -ForegroundColor Gray
        }
    }

    Write-Host ""
    Write-Host "  (showing last 30 entries)" -ForegroundColor DarkGray
    Pause-Menu
}

function Show-RecentLoginEvents {
    Write-MenuHeader "Recent Login Events (Security Log)"

    Write-Step "Querying Windows Security Event Log..." -Type Info
    Write-Host ""

    try {
        # Event ID 4624 = Successful logon, 4625 = Failed logon
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Security'
            Id = 4624, 4625
        } -MaxEvents 25 -ErrorAction SilentlyContinue

        if (-not $events) {
            Write-Step "No login events found." -Type Warning
            Pause-Menu
            return
        }

        Write-Host "  Time                   Event    User                                 Source IP" -ForegroundColor White
        Write-Separator

        foreach ($event in $events) {
            $xml = [xml]$event.ToXml()
            $data = @{}
            foreach ($d in $xml.Event.EventData.Data) {
                $data[$d.Name] = $d.'#text'
            }

            $time = $event.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
            $type = if ($event.Id -eq 4624) { "Login " } else { "FAILED" }
            $typeColor = if ($event.Id -eq 4624) { "Green" } else { "Red" }
            $targetUser = if ($data['TargetUserName']) { $data['TargetUserName'] } else { "UNKNOWN" }
            $targetDomain = if ($data['TargetDomainName']) { $data['TargetDomainName'] } else { "" }

            # Skip SYSTEM/machine logons
            if ($targetUser -in @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'DWM-1', 'UMFD-0', 'UMFD-1', 'UNKNOWN')) { continue }
            if ($targetUser -match '\$$') { continue }

            $user = "$targetDomain\$targetUser"
            if ($user.Length -gt 36) { $user = $user.Substring(0, 33) + "..." }
            $sourceIP = if ($data['IpAddress']) { $data['IpAddress'] } else { "-" }

            Write-Host "  $time  " -NoNewline
            Write-Host "$($type.PadRight(8))" -ForegroundColor $typeColor -NoNewline
            Write-Host "$($user.PadRight(36)) " -NoNewline
            Write-Host "$sourceIP" -ForegroundColor Cyan
        }
    }
    catch {
        Write-Step "Failed to read Security Event Log: $_" -Type Error
    }

    Write-Host ""
    Pause-Menu
}

function Show-RecentFileAccessEvents {
    Write-MenuHeader "Recent File Access Events"

    $settings = Get-Settings
    if (-not $settings) { Pause-Menu; return }

    Write-Step "Querying Windows Security Event Log (file access)..." -Type Info
    Write-Host ""

    try {
        # Event ID 4663 = Object access (file/folder)
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Security'
            Id = 4663
        } -MaxEvents 30 -ErrorAction SilentlyContinue

        if (-not $events) {
            Write-Step "No file access events found. Enable audit policies first." -Type Warning
            Pause-Menu
            return
        }

        Write-Host "  Time                   User                 Action       Path" -ForegroundColor White
        Write-Separator

        foreach ($event in $events) {
            $xml = [xml]$event.ToXml()
            $data = @{}
            foreach ($d in $xml.Event.EventData.Data) {
                $data[$d.Name] = $d.'#text'
            }

            $objectName = $data['ObjectName']
            # Only show events under configured BasePath
            if ($objectName -and $objectName -like "$($settings.BasePath)*") {
                $time = $event.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                $user = if ($data['SubjectUserName']) { $data['SubjectUserName'] } else { "UNKNOWN" }
                if ($user.Length -gt 20) { $user = $user.Substring(0, 17) + "..." }

                $accessMask = $data['AccessMask']
                $action = switch ($accessMask) {
                    "0x2"     { "Write" }
                    "0x1"     { "Read" }
                    "0x10000" { "Delete" }
                    "0x6"     { "Write" }
                    default   { "Access" }
                }

                $shortPath = $objectName.Replace($settings.BasePath, "~")
                if ($shortPath.Length -gt 35) { $shortPath = "..." + $shortPath.Substring($shortPath.Length - 32) }

                Write-Host "  $time  " -NoNewline
                Write-Host "$($user.PadRight(20)) " -ForegroundColor Cyan -NoNewline
                Write-Host "$($action.PadRight(12)) " -ForegroundColor Yellow -NoNewline
                Write-Host "$shortPath"
            }
        }
    }
    catch {
        Write-Step "Failed to read Security Event Log: $_" -Type Error
    }

    Write-Host ""
    Pause-Menu
}

function Show-AuditMenu {
    while ($true) {
        $choice = Select-MenuOption -Title "Audit & Logging" -Items @(
            @{ Key = "1"; Label = "Enable File System Audit Policy" }
            @{ Key = "2"; Label = "Enable Audit on User Directories" }
            @{ Key = "3"; Label = "Enable PowerShell Logging" }
            @{ Separator = $true }
            @{ Key = "4"; Label = "Show Audit & Logging Status" }
            @{ Key = "5"; Label = "View Recent WinGateKeeper Logs" }
            @{ Key = "6"; Label = "View Recent Login Events" }
            @{ Key = "7"; Label = "View Recent File Access Events" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back to Main Menu" }
        )
        switch ($choice) {
            "1" { Enable-FileAudit }
            "2" { Enable-DirectoryAudit }
            "3" { Enable-PowerShellLogging }
            "4" { Show-AuditStatus }
            "5" { Show-RecentLogs }
            "6" { Show-RecentLoginEvents }
            "7" { Show-RecentFileAccessEvents }
            "B" { return }
        }
    }
}

Export-ModuleMember -Function *
