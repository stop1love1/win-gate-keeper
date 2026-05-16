# ============================================================================
# WinGateKeeper - Hyper-V Management Module
# Install/manage Hyper-V role, create/manage VMs, virtual switches, snapshots
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

# ============================================================================
# Guard & Prerequisite Functions
# ============================================================================

function Test-HyperVInstalled {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
        return ($feature -and $feature.State -eq 'Enabled')
    }
    catch {
        return $false
    }
}

function Test-HyperVServiceRunning {
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    return ($svc -and $svc.Status -eq 'Running')
}

function Test-HyperVReady {
    <#
        Combined check: Hyper-V installed + vmms running + PowerShell module available.
        Shows clear message if something is wrong. Returns $true if all OK.
    #>
    if (-not (Test-HyperVInstalled)) {
        Write-Step "Hyper-V is not installed. Use option [1] to install it first." -Type Error
        return $false
    }
    if (-not (Test-HyperVServiceRunning)) {
        Write-Step "Hyper-V service (vmms) is not running. Try restarting the server." -Type Error
        return $false
    }
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        Write-Step "Hyper-V PowerShell module is not installed." -Type Error
        Write-Step "Run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell" -Type Info
        return $false
    }
    return $true
}

function Get-HyperVDefaults {
    $settings = Get-Settings
    if ($settings -and $settings.HyperV) {
        return $settings.HyperV
    }
    return @{
        DefaultVMPath      = "C:\HyperV\VMs"
        DefaultVHDPath     = "C:\HyperV\VHDs"
        DefaultSwitchName  = "Default Switch"
        DefaultRAMGB       = 2
        DefaultCPUCount    = 2
        DefaultDiskSizeGB  = 50
        DefaultGeneration  = 2
    }
}

# ============================================================================
# Install Hyper-V
# ============================================================================

function Install-HyperVRole {
    Write-MenuHeader "Install / Check Hyper-V Role"

    if (-not (Test-IsAdmin)) {
        Write-RequiresAdmin
        Pause-Menu
        return
    }

    Write-Host ""
    $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue

    if ($feature -and $feature.State -eq 'Enabled') {
        Write-Step "Hyper-V role is already installed and enabled." -Type Success

        $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host "  VMMS Service:    " -NoNewline
            if ($svc.Status -eq 'Running') {
                Write-Host "RUNNING" -ForegroundColor Green
            }
            else {
                Write-Host "$($svc.Status)" -ForegroundColor Yellow
                Write-Host ""
                if (Confirm-Action "Start VMMS service?") {
                    try {
                        Start-Service vmms -ErrorAction Stop
                        Write-Step "VMMS service started." -Type Success
                    }
                    catch {
                        Write-Step "Failed to start VMMS: $_" -Type Error
                    }
                }
            }
        }

        if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
            $vmCount = @(Get-VM -ErrorAction SilentlyContinue).Count
            Write-Host "  VM Count:        $vmCount" -ForegroundColor Cyan
        }

        Pause-Menu
        return
    }

    # Not installed
    Write-Host ""
    Write-Step "Hyper-V is not installed on this server." -Type Info
    Write-Host ""
    Write-Host "  Hyper-V allows you to create and manage Virtual Machines" -ForegroundColor White
    Write-Host "  to partition server resources (CPU, RAM, Disk, Network)." -ForegroundColor White
    Write-Host ""
    Write-Step "Note: A system REBOOT is required after installation." -Type Warning
    Write-Host ""

    if (-not (Confirm-Action "Install Hyper-V?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        Write-Step "Installing Hyper-V role (this may take a few minutes)..." -Type Info
        $result = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart -ErrorAction Stop

        if ($result.RestartNeeded) {
            Write-Host ""
            Write-Step "Installed successfully! A REBOOT is required to complete." -Type Warning
            Write-Step "After reboot, run WinGateKeeper again to use Hyper-V." -Type Info
        }
        else {
            Write-Step "Hyper-V installed and ready to use." -Type Success
        }

        Write-Log "Hyper-V role installed."
    }
    catch {
        Write-Step "Installation failed: $_" -Type Error
        Write-Host ""
        Write-Host "  Possible causes:" -ForegroundColor Yellow
        Write-Host "    - Hardware does not support virtualization" -ForegroundColor White
        Write-Host "    - VT-x/AMD-V not enabled in BIOS" -ForegroundColor White
        Write-Host "    - Running Windows Home edition (requires Pro/Server)" -ForegroundColor White
    }

    Pause-Menu
}

# ============================================================================
# Helper: Select VM from list
# ============================================================================

function Select-VMFromList {
    param(
        [string]$Filter,
        [string]$Prompt = "Select VM number"
    )

    try {
        $vms = if ($Filter) {
            @(Get-VM -ErrorAction Stop | Where-Object State -eq $Filter)
        }
        else {
            @(Get-VM -ErrorAction Stop)
        }
    }
    catch {
        Write-Step "Failed to get VM list: $_" -Type Error
        return $null
    }

    if ($vms.Count -eq 0) {
        $filterText = switch ($Filter) {
            'Off'     { " that are stopped" }
            'Running' { " that are running" }
            'Saved'   { " in saved state" }
            default   { "" }
        }
        Write-Step "No virtual machines found$filterText." -Type Info
        return $null
    }

    Write-Host ""
    Write-Host "  #    VM Name                       State         CPU   RAM" -ForegroundColor White
    Write-Host ("  " + "-" * 65) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $vms.Count; $i++) {
        $vm = $vms[$i]
        $ramMB = if ($vm.MemoryAssigned -gt 0) { [math]::Round($vm.MemoryAssigned / 1MB) } else { 0 }
        $idx = "  $($i + 1)".PadRight(7)
        $name = $vm.Name.PadRight(26)
        $state = $vm.State.ToString().PadRight(14)
        $cpu = "$($vm.ProcessorCount) core".PadRight(8)
        $ram = "$ramMB MB"

        $color = switch ($vm.State.ToString()) {
            'Running' { 'Green' }
            'Off'     { 'DarkGray' }
            'Saved'   { 'Yellow' }
            default   { 'Cyan' }
        }
        Write-Host "$idx$name$state$cpu$ram" -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "  $Prompt (0 to cancel): " -ForegroundColor White -NoNewline
    $choice = (Read-Host).Trim()

    if (-not $choice -or $choice -eq "0") { return $null }

    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $vms.Count) {
        return $vms[$idx - 1]
    }

    Write-Step "Invalid selection." -Type Error
    return $null
}

# ============================================================================
# VM Lifecycle Functions
# ============================================================================

function Show-VMList {
    Write-MenuHeader "Virtual Machines"

    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vms = @(Get-VM -ErrorAction SilentlyContinue)

    if ($vms.Count -eq 0) {
        Write-Step "No virtual machines found. Use [3] to create a new VM." -Type Info
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  VM Name                       State         CPU%  RAM (MB)   Uptime" -ForegroundColor White
    Write-Host ("  " + "-" * 75) -ForegroundColor DarkGray

    foreach ($vm in $vms) {
        $ramMB = if ($vm.MemoryAssigned -gt 0) { [math]::Round($vm.MemoryAssigned / 1MB) } else { 0 }
        $cpuPct = if ($vm.State -eq 'Running') { "$($vm.CPUUsage)%" } else { "-" }
        $uptime = if ($vm.State -eq 'Running' -and $vm.Uptime) {
            try { $vm.Uptime.ToString("d\.hh\:mm\:ss") } catch { "-" }
        } else { "-" }

        $name = $vm.Name.PadRight(28)
        $state = $vm.State.ToString().PadRight(14)
        $cpuStr = $cpuPct.PadRight(6)
        $ramStr = $ramMB.ToString().PadRight(11)

        $color = switch ($vm.State.ToString()) {
            'Running' { 'Green' }
            'Off'     { 'DarkGray' }
            'Saved'   { 'Yellow' }
            default   { 'Cyan' }
        }
        Write-Host "  $name$state$cpuStr$ramStr$uptime" -ForegroundColor $color
    }

    $runningCount = @($vms | Where-Object State -eq 'Running').Count
    Write-Host ""
    Write-Host "  Total: $($vms.Count) VM(s), $runningCount running" -ForegroundColor White
    Write-Host ""
    Pause-Menu
}

function New-HyperVVM {
    Write-MenuHeader "Create New Virtual Machine"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $defaults = Get-HyperVDefaults

    Write-Host ""
    Write-Host "  Tip: Press Enter to use default values shown in brackets." -ForegroundColor DarkGray
    Write-Host ""

    # VM Name (required)
    Write-Host "  VM Name (required): " -ForegroundColor White -NoNewline
    $vmName = (Read-Host).Trim()
    if (-not $vmName) {
        Write-Step "Cancelled - VM name is required." -Type Warning
        Pause-Menu
        return
    }

    # Validate VM name
    if ($vmName -match '[\\/:*?"<>|]') {
        Write-Step "VM name cannot contain special characters: \ / : * ? < > |" -Type Error
        Pause-Menu
        return
    }
    if ($vmName.Length -gt 100) {
        Write-Step "VM name is too long (max 100 characters)." -Type Error
        Pause-Menu
        return
    }

    # Check duplicate
    $existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Step "A VM named '$vmName' already exists. Choose a different name." -Type Error
        Pause-Menu
        return
    }

    # Get host info for validation
    $hostRAMGB = 0
    $hostCPU = 0
    try {
        $hostRAMGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 1)
        $hostCPU = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    }
    catch {
        # Could not detect host info - skip resource cap checks
        $hostRAMGB = 0
        $hostCPU = 0
    }

    # Generation
    Write-Host "  Generation - 1 (legacy) or 2 (UEFI, recommended) [$($defaults.DefaultGeneration)]: " -ForegroundColor White -NoNewline
    $genInput = (Read-Host).Trim()
    $generation = if ($genInput -match '^[12]$') { [int]$genInput } else { [int]$defaults.DefaultGeneration }

    # RAM
    $ramPrompt = if ($hostRAMGB -gt 0) { "  RAM in GB - host has $hostRAMGB GB [$($defaults.DefaultRAMGB)]: " } else { "  RAM in GB [$($defaults.DefaultRAMGB)]: " }
    Write-Host $ramPrompt -ForegroundColor White -NoNewline
    $ramInput = (Read-Host).Trim()
    $ramGB = if ($ramInput -and [double]::TryParse($ramInput, [ref]$null)) { [double]$ramInput } else { [double]$defaults.DefaultRAMGB }
    if ($ramGB -lt 0.5) { $ramGB = 0.5; Write-Step "Using minimum 0.5 GB." -Type Info }
    if ($hostRAMGB -gt 0 -and $ramGB -gt $hostRAMGB) {
        Write-Step "Requested RAM ($ramGB GB) exceeds host RAM ($hostRAMGB GB). Reducing." -Type Warning
        $ramGB = [math]::Floor($hostRAMGB * 0.8)
        Write-Step "Using $ramGB GB." -Type Info
    }
    $ramBytes = [long]($ramGB * 1GB)

    # CPU
    $cpuPrompt = if ($hostCPU -gt 0) { "  CPU cores - host has $hostCPU cores [$($defaults.DefaultCPUCount)]: " } else { "  CPU cores [$($defaults.DefaultCPUCount)]: " }
    Write-Host $cpuPrompt -ForegroundColor White -NoNewline
    $cpuInput = (Read-Host).Trim()
    $cpuCount = if ($cpuInput -and [int]::TryParse($cpuInput, [ref]$null)) { [int]$cpuInput } else { [int]$defaults.DefaultCPUCount }
    if ($cpuCount -lt 1) { $cpuCount = 1 }
    if ($hostCPU -gt 0 -and $cpuCount -gt $hostCPU) {
        Write-Step "CPU count ($cpuCount) exceeds host cores ($hostCPU). Using $hostCPU." -Type Warning
        $cpuCount = $hostCPU
    }

    # Disk
    Write-Host "  Disk size in GB [$($defaults.DefaultDiskSizeGB)]: " -ForegroundColor White -NoNewline
    $diskInput = (Read-Host).Trim()
    $diskGB = if ($diskInput -and [double]::TryParse($diskInput, [ref]$null)) { [double]$diskInput } else { [double]$defaults.DefaultDiskSizeGB }
    if ($diskGB -lt 1) { $diskGB = 1 }
    $diskBytes = [long]($diskGB * 1GB)

    # Check disk space
    try {
        $vhdDriveLetter = ($defaults.DefaultVHDPath).Substring(0, 1)
        $driveInfo = Get-PSDrive -Name $vhdDriveLetter -ErrorAction SilentlyContinue
        if ($driveInfo -and $driveInfo.Free -and ($driveInfo.Free / 1GB) -lt 5) {
            Write-Step "Warning: Drive $($vhdDriveLetter): only has $([math]::Round($driveInfo.Free / 1GB, 1)) GB free." -Type Warning
        }
    }
    catch {}

    # Virtual Switch
    $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue)
    $switchName = $null
    if ($switches.Count -gt 0) {
        Write-Host ""
        Write-Host "  Select Virtual Switch:" -ForegroundColor White
        for ($i = 0; $i -lt $switches.Count; $i++) {
            Write-Host "    [$($i + 1)] $($switches[$i].Name) ($($switches[$i].SwitchType))" -ForegroundColor Cyan
        }
        Write-Host "    [0] No network connection" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Select [1]: " -ForegroundColor White -NoNewline
        $swInput = (Read-Host).Trim()
        $swIdx = if ($swInput -and [int]::TryParse($swInput, [ref]$null)) { [int]$swInput } else { 1 }
        if ($swIdx -ge 1 -and $swIdx -le $switches.Count) {
            $switchName = $switches[$swIdx - 1].Name
        }
    }
    else {
        Write-Step "No virtual switches found. VM will have no network. Create one in [N]." -Type Warning
    }

    # ISO for OS installation
    Write-Host ""
    Write-Host "  OS installation ISO file (Enter to skip): " -ForegroundColor White -NoNewline
    $isoPath = (Read-Host).Trim().Trim('"')

    $validISO = $false
    if ($isoPath) {
        if (-not (Test-Path $isoPath)) {
            Write-Step "File not found: $isoPath" -Type Warning
            $isoPath = $null
        }
        elseif ($isoPath -notmatch '\.iso$') {
            Write-Step "Not an ISO file: $isoPath" -Type Warning
            $isoPath = $null
        }
        else {
            $validISO = $true
        }
    }

    # Summary
    Write-Host ""
    Write-Host "  ============ VM Configuration Summary ============" -ForegroundColor White
    Write-Host "  Name:        $vmName" -ForegroundColor Cyan
    Write-Host "  Generation:  $generation" -ForegroundColor Cyan
    Write-Host "  RAM:         $ramGB GB" -ForegroundColor Cyan
    Write-Host "  CPU:         $cpuCount core(s)" -ForegroundColor Cyan
    Write-Host "  Disk:        $diskGB GB (dynamic expanding)" -ForegroundColor Cyan
    $swDisplay = if ($switchName) { $switchName } else { "Not connected" }
    Write-Host "  Network:     $swDisplay" -ForegroundColor Cyan
    if ($validISO) {
        Write-Host "  ISO:         $(Split-Path $isoPath -Leaf)" -ForegroundColor Cyan
    }
    Write-Host "  =================================================" -ForegroundColor White
    Write-Host ""

    if (-not (Confirm-Action "Create this virtual machine?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    $vhdFile = $null
    try {
        $vhdPath = $defaults.DefaultVHDPath
        $vmPath = $defaults.DefaultVMPath
        if (-not (Test-Path $vhdPath)) { New-Item -Path $vhdPath -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $vmPath)) { New-Item -Path $vmPath -ItemType Directory -Force | Out-Null }

        $vhdFile = Join-Path $vhdPath "$vmName.vhdx"
        if (Test-Path $vhdFile) {
            Write-Step "VHD file already exists: $vhdFile" -Type Error
            Write-Step "Delete it or choose a different VM name." -Type Info
            Pause-Menu
            return
        }

        Write-Step "Creating virtual disk ($diskGB GB)..." -Type Info
        New-VHD -Path $vhdFile -SizeBytes $diskBytes -Dynamic -ErrorAction Stop | Out-Null

        Write-Step "Creating virtual machine..." -Type Info
        $vmParams = @{
            Name               = $vmName
            MemoryStartupBytes = $ramBytes
            Generation         = $generation
            VHDPath            = $vhdFile
            Path               = $vmPath
            ErrorAction        = 'Stop'
        }
        if ($switchName) { $vmParams.SwitchName = $switchName }
        New-VM @vmParams | Out-Null

        Set-VM -Name $vmName -ProcessorCount $cpuCount -ErrorAction Stop

        # Attach ISO if provided
        if ($validISO) {
            try {
                Add-VMDvdDrive -VMName $vmName -Path $isoPath -ErrorAction Stop
                Write-Step "ISO attached: $(Split-Path $isoPath -Leaf)" -Type Success
                if ($generation -eq 2) {
                    $dvd = Get-VMDvdDrive -VMName $vmName -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($dvd) {
                        Set-VMFirmware -VMName $vmName -FirstBootDevice $dvd -ErrorAction SilentlyContinue
                        Write-Step "Boot order: DVD first (Gen 2)." -Type Info
                    }
                }
            }
            catch {
                Write-Step "Failed to attach ISO (VM not affected): $_" -Type Warning
            }
        }

        Write-Host ""
        Write-Step "VM '$vmName' created successfully!" -Type Success
        Write-Log "Created VM '$vmName' (Gen$generation, ${ramGB}GB RAM, ${cpuCount} CPU, ${diskGB}GB disk)."

        Write-Host ""
        Write-Host "  Next steps:" -ForegroundColor White
        Write-Host "    - Use [4] Start VM to power on the VM" -ForegroundColor DarkGray
        Write-Host "    - Open Hyper-V Manager to access VM console" -ForegroundColor DarkGray
        if (-not $validISO) {
            Write-Host "    - Attach an ISO in Hyper-V Manager to install an OS" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Step "Failed to create VM: $_" -Type Error
        if ($vhdFile) {
            $vmCheck = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if (-not $vmCheck -and (Test-Path $vhdFile)) {
                Write-Step "Cleaning up orphaned VHD file..." -Type Info
                Remove-Item $vhdFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Pause-Menu
}

function Start-HyperVVM {
    Write-MenuHeader "Start Virtual Machine"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    # Show Off and Saved VMs (both can be started)
    try {
        $startableVMs = @(Get-VM -ErrorAction Stop | Where-Object { $_.State -eq 'Off' -or $_.State -eq 'Saved' })
    }
    catch {
        Write-Step "Failed to get VM list: $_" -Type Error
        Pause-Menu
        return
    }

    if ($startableVMs.Count -eq 0) {
        Write-Step "No stopped or saved VMs available to start." -Type Info
        Pause-Menu
        return
    }

    # Display startable VMs with index
    Write-Host ""
    Write-Host "  #    VM Name                       State         CPU   RAM" -ForegroundColor White
    Write-Host ("  " + "-" * 65) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $startableVMs.Count; $i++) {
        $v = $startableVMs[$i]
        $ramMB = if ($v.MemoryAssigned -gt 0) { [math]::Round($v.MemoryAssigned / 1MB) } else { 0 }
        $idx = "  $($i + 1)".PadRight(7)
        $name = $v.Name.PadRight(26)
        $state = $v.State.ToString().PadRight(14)
        $cpu = "$($v.ProcessorCount) core".PadRight(8)
        Write-Host "$idx$name$state$cpu$ramMB MB" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  Select VM to start (0 to cancel): " -ForegroundColor White -NoNewline
    $choice = (Read-Host).Trim()
    if (-not $choice -or $choice -eq "0") { Pause-Menu; return }
    $idx = 0
    if (-not ([int]::TryParse($choice, [ref]$idx)) -or $idx -lt 1 -or $idx -gt $startableVMs.Count) {
        Write-Step "Invalid selection." -Type Error
        Pause-Menu
        return
    }
    $vm = $startableVMs[$idx - 1]

    try {
        Write-Step "Starting '$($vm.Name)'..." -Type Info
        Start-VM -Name $vm.Name -ErrorAction Stop
        Write-Step "VM '$($vm.Name)' started successfully." -Type Success
        Write-Log "Started VM '$($vm.Name)'."
        Write-Host ""
        Write-Host "  Connect to VM console:" -ForegroundColor White
        Write-Host "    vmconnect localhost `"$($vm.Name)`"" -ForegroundColor Green
        Write-Host "  Or use [G] Connection Guide for more options." -ForegroundColor DarkGray
    }
    catch {
        Write-Step "Failed to start VM: $_" -Type Error
        Write-Host ""
        Write-Host "  Possible causes:" -ForegroundColor Yellow
        Write-Host "    - Not enough RAM on the host" -ForegroundColor White
        Write-Host "    - VHD file is corrupted or missing" -ForegroundColor White
        Write-Host "    - Virtual Switch has been removed" -ForegroundColor White
    }

    Pause-Menu
}

function Stop-HyperVVM {
    Write-MenuHeader "Stop Virtual Machine"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vm = Select-VMFromList -Filter "Running" -Prompt "Select VM to stop"
    if (-not $vm) { Pause-Menu; return }

    if (-not (Confirm-Action "Stop VM '$($vm.Name)'?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    # Try graceful shutdown first, auto-fallback to force if failed
    try {
        Write-Step "Sending shutdown signal (graceful shutdown)..." -Type Info
        Stop-VM -Name $vm.Name -ErrorAction Stop
        Write-Step "VM '$($vm.Name)' has been stopped." -Type Success
        Write-Log "Stopped VM '$($vm.Name)'."
    }
    catch {
        Write-Step "Graceful shutdown failed. Guest OS may not support it." -Type Warning
        Write-Host ""
        if (Confirm-Action "Force power off? (unsaved data in the VM will be lost)") {
            try {
                Stop-VM -Name $vm.Name -Force -TurnOff -ErrorAction Stop
                Write-Step "VM '$($vm.Name)' has been force stopped." -Type Success
                Write-Log "Force stopped VM '$($vm.Name)'."
            }
            catch {
                Write-Step "Force stop failed: $_" -Type Error
            }
        }
    }

    Pause-Menu
}

function Restart-HyperVVM {
    Write-MenuHeader "Restart Virtual Machine"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vm = Select-VMFromList -Filter "Running" -Prompt "Select VM to restart"
    if (-not $vm) { Pause-Menu; return }

    if (-not (Confirm-Action "Restart VM '$($vm.Name)'?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        Write-Step "Restarting '$($vm.Name)'..." -Type Info
        Restart-VM -Name $vm.Name -Force -ErrorAction Stop
        Write-Step "VM '$($vm.Name)' is restarting." -Type Success
        Write-Log "Restarted VM '$($vm.Name)'."
    }
    catch {
        Write-Step "Restart failed: $_" -Type Error
    }

    Pause-Menu
}

function Remove-HyperVVM {
    Write-MenuHeader "Remove Virtual Machine"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vm = Select-VMFromList -Prompt "Select VM to remove"
    if (-not $vm) { Pause-Menu; return }

    Write-Host ""
    Write-Step "WARNING: This will PERMANENTLY remove VM '$($vm.Name)'!" -Type Warning
    Write-Host ""

    if (-not (Confirm-Action "Confirm removal of VM '$($vm.Name)'?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        if ($vm.State -eq 'Running' -or $vm.State -eq 'Saved') {
            Write-Step "Stopping VM before removal..." -Type Info
            Stop-VM -Name $vm.Name -Force -TurnOff -ErrorAction Stop
        }

        $vhds = @()
        try {
            $vhds = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue |
                Where-Object { $_.Path } |
                Select-Object -ExpandProperty Path)
        }
        catch {}

        Remove-VM -Name $vm.Name -Force -ErrorAction Stop
        Write-Step "VM '$($vm.Name)' removed." -Type Success

        if ($vhds.Count -gt 0) {
            Write-Host ""
            Write-Host "  Associated virtual disks:" -ForegroundColor White
            foreach ($vhd in $vhds) {
                $sizeGB = 0
                if (Test-Path $vhd) {
                    $sizeGB = [math]::Round((Get-Item $vhd).Length / 1GB, 1)
                }
                Write-Host "    $vhd ($sizeGB GB)" -ForegroundColor Cyan
            }
            Write-Host ""
            if (Confirm-Action "Also delete the virtual disk file(s)?") {
                foreach ($vhd in $vhds) {
                    if (Test-Path $vhd) {
                        Remove-Item $vhd -Force -ErrorAction SilentlyContinue
                        Write-Step "Deleted: $(Split-Path $vhd -Leaf)" -Type Info
                    }
                }
                Write-Step "Virtual disk files cleaned up." -Type Success
            }
            else {
                Write-Step "Virtual disk files kept." -Type Info
            }
        }

        Write-Log "Removed VM '$($vm.Name)'."
    }
    catch {
        Write-Step "Failed to remove VM: $_" -Type Error
    }

    Pause-Menu
}

function Set-HyperVMResources {
    Write-MenuHeader "Modify VM Resources (CPU / RAM)"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vm = Select-VMFromList -Prompt "Select VM to modify"
    if (-not $vm) { Pause-Menu; return }

    $currentRAMGB = 0
    try { $currentRAMGB = [math]::Round($vm.MemoryStartup / 1GB, 1) } catch { $currentRAMGB = 0 }

    Write-Host ""
    Write-Host "  Current resources for '$($vm.Name)':" -ForegroundColor White
    Write-Host ("  " + "-" * 40) -ForegroundColor DarkGray
    Write-Host "  CPU:    $($vm.ProcessorCount) core(s)" -ForegroundColor Cyan
    Write-Host "  RAM:    $currentRAMGB GB" -ForegroundColor Cyan
    Write-Host "  State:  $($vm.State)" -ForegroundColor Cyan

    if ($vm.State -ne 'Off') {
        Write-Host ""
        Write-Step "VM must be stopped to change RAM. CPU changes may apply while running." -Type Warning
    }

    Write-Host ""
    Write-Host "  New CPU count (Enter to keep $($vm.ProcessorCount)): " -ForegroundColor White -NoNewline
    $cpuInput = (Read-Host).Trim()
    $newCPU = if ($cpuInput -and [int]::TryParse($cpuInput, [ref]$null) -and [int]$cpuInput -ge 1) { [int]$cpuInput } else { $vm.ProcessorCount }

    Write-Host "  New RAM in GB (Enter to keep $currentRAMGB): " -ForegroundColor White -NoNewline
    $ramInput = (Read-Host).Trim()
    $newRAMGB = if ($ramInput -and [double]::TryParse($ramInput, [ref]$null) -and [double]$ramInput -ge 0.5) { [double]$ramInput } else { $currentRAMGB }
    $newRAMBytes = [long]($newRAMGB * 1GB)

    if ($newCPU -eq $vm.ProcessorCount -and $newRAMGB -eq $currentRAMGB) {
        Write-Step "No changes made." -Type Info
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  Changes: CPU $($vm.ProcessorCount) -> $newCPU, RAM $currentRAMGB GB -> $newRAMGB GB" -ForegroundColor Cyan

    try {
        Set-VM -Name $vm.Name -ProcessorCount $newCPU -MemoryStartupBytes $newRAMBytes -ErrorAction Stop
        Write-Step "Updated successfully: $newCPU CPU(s), $newRAMGB GB RAM." -Type Success
        Write-Log "Modified VM '$($vm.Name)': $newCPU CPU, ${newRAMGB}GB RAM."
    }
    catch {
        Write-Step "Update failed: $_" -Type Error
        if ($vm.State -ne 'Off') {
            Write-Host "  Try stopping the VM first, then make changes." -ForegroundColor Yellow
        }
    }

    Pause-Menu
}

# ============================================================================
# Virtual Switch Functions
# ============================================================================

function Show-VMSwitchList {
    Write-MenuHeader "Virtual Switches"

    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue)

    if ($switches.Count -eq 0) {
        Write-Step "No virtual switches found." -Type Info
        Write-Host ""
        Write-Host "  Virtual switches allow VMs to connect to networks." -ForegroundColor DarkGray
        Write-Host "  Use [2] to create a new switch." -ForegroundColor DarkGray
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  Switch Name                    Type           Network Adapter" -ForegroundColor White
    Write-Host ("  " + "-" * 65) -ForegroundColor DarkGray

    foreach ($sw in $switches) {
        $name = $sw.Name.PadRight(30)
        $type = $sw.SwitchType.ToString().PadRight(15)
        $adapter = if ($sw.NetAdapterInterfaceDescription) { $sw.NetAdapterInterfaceDescription } else { "-" }
        Write-Host "  $name$type$adapter" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  Switch types:" -ForegroundColor DarkGray
    Write-Host "    External = VMs access physical network (internet)" -ForegroundColor DarkGray
    Write-Host "    Internal = Host <-> VMs only, no external access" -ForegroundColor DarkGray
    Write-Host "    Private  = VMs <-> VMs only, no host access" -ForegroundColor DarkGray
    Write-Host ""
    Pause-Menu
}

function New-HyperVSwitch {
    Write-MenuHeader "Create Virtual Switch"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    Write-Host ""
    Write-Host "  Select switch type:" -ForegroundColor White
    Write-Host "    [1] External - VMs access internet via physical adapter" -ForegroundColor Cyan
    Write-Host "    [2] Internal - Communication between VMs and host only" -ForegroundColor Cyan
    Write-Host "    [3] Private  - Communication between VMs only" -ForegroundColor Cyan
    Write-Host "    [0] Cancel" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Select type: " -ForegroundColor White -NoNewline
    $typeChoice = (Read-Host).Trim()

    if (-not $typeChoice -or $typeChoice -eq "0") {
        Write-Step "Cancelled." -Type Info
        Pause-Menu
        return
    }

    if ($typeChoice -notin @("1", "2", "3")) {
        Write-Step "Invalid selection." -Type Error
        Pause-Menu
        return
    }

    Write-Host "  Switch name: " -ForegroundColor White -NoNewline
    $swName = (Read-Host).Trim()
    if (-not $swName) {
        Write-Step "Cancelled - name is required." -Type Warning
        Pause-Menu
        return
    }

    $existing = Get-VMSwitch -Name $swName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Step "A switch named '$swName' already exists. Choose a different name." -Type Error
        Pause-Menu
        return
    }

    try {
        switch ($typeChoice) {
            "1" {
                $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
                if ($adapters.Count -eq 0) {
                    Write-Step "No active physical network adapters found." -Type Error
                    Pause-Menu
                    return
                }

                Write-Host ""
                Write-Host "  Select physical adapter:" -ForegroundColor White
                for ($i = 0; $i -lt $adapters.Count; $i++) {
                    Write-Host "    [$($i + 1)] $($adapters[$i].Name) - $($adapters[$i].InterfaceDescription)" -ForegroundColor Cyan
                }
                Write-Host ""
                Write-Host "  Select adapter: " -ForegroundColor White -NoNewline
                $adInput = (Read-Host).Trim()
                $adIdx = 0
                if (-not ([int]::TryParse($adInput, [ref]$adIdx)) -or $adIdx -lt 1 -or $adIdx -gt $adapters.Count) {
                    Write-Step "Invalid selection." -Type Error
                    Pause-Menu
                    return
                }

                Write-Host ""
                Write-Step "Note: Creating an External switch may briefly interrupt network." -Type Warning
                if (-not (Confirm-Action "Create External switch '$swName'?")) {
                    Write-Step "Cancelled." -Type Warning
                    Pause-Menu
                    return
                }

                New-VMSwitch -Name $swName -NetAdapterName $adapters[$adIdx - 1].Name -AllowManagementOS $true -ErrorAction Stop | Out-Null
                Write-Step "External switch '$swName' created." -Type Success
                Write-Log "Created External VM switch '$swName'."
            }
            "2" {
                New-VMSwitch -Name $swName -SwitchType Internal -ErrorAction Stop | Out-Null
                Write-Step "Internal switch '$swName' created." -Type Success
                Write-Log "Created Internal VM switch '$swName'."
            }
            "3" {
                New-VMSwitch -Name $swName -SwitchType Private -ErrorAction Stop | Out-Null
                Write-Step "Private switch '$swName' created." -Type Success
                Write-Log "Created Private VM switch '$swName'."
            }
        }
    }
    catch {
        Write-Step "Failed to create switch: $_" -Type Error
    }

    Pause-Menu
}

function Remove-HyperVSwitch {
    Write-MenuHeader "Remove Virtual Switch"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue)
    if ($switches.Count -eq 0) {
        Write-Step "No virtual switches to remove." -Type Info
        Pause-Menu
        return
    }

    Write-Host ""
    for ($i = 0; $i -lt $switches.Count; $i++) {
        Write-Host "  [$($i + 1)] $($switches[$i].Name) ($($switches[$i].SwitchType))" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  Select switch to remove (0 to cancel): " -ForegroundColor White -NoNewline
    $choice = (Read-Host).Trim()

    if (-not $choice -or $choice -eq "0") { Pause-Menu; return }

    $idx = 0
    if (-not ([int]::TryParse($choice, [ref]$idx)) -or $idx -lt 1 -or $idx -gt $switches.Count) {
        Write-Step "Invalid selection." -Type Error
        Pause-Menu
        return
    }

    $sw = $switches[$idx - 1]
    Write-Step "Warning: VMs using this switch will lose network connectivity!" -Type Warning
    if (-not (Confirm-Action "Remove switch '$($sw.Name)'?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        Remove-VMSwitch -Name $sw.Name -Force -ErrorAction Stop
        Write-Step "Switch '$($sw.Name)' removed." -Type Success
        Write-Log "Removed VM switch '$($sw.Name)'."
    }
    catch {
        Write-Step "Failed to remove switch: $_" -Type Error
    }

    Pause-Menu
}

# ============================================================================
# Snapshot / Checkpoint Functions
# ============================================================================

function Select-CheckpointFromVM {
    param([string]$VMName)

    $checkpoints = @(Get-VMCheckpoint -VMName $VMName -ErrorAction SilentlyContinue)
    if ($checkpoints.Count -eq 0) {
        Write-Step "No checkpoints found for '$VMName'." -Type Info
        return $null
    }

    Write-Host ""
    Write-Host "  #    Checkpoint Name                 Created" -ForegroundColor White
    Write-Host ("  " + "-" * 55) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $checkpoints.Count; $i++) {
        $cp = $checkpoints[$i]
        $idx = "  $($i + 1)".PadRight(7)
        $name = $cp.Name.PadRight(30)
        $created = try { $cp.CreationTime.ToString('yyyy-MM-dd HH:mm') } catch { "N/A" }
        Write-Host "$idx$name$created" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  Select checkpoint (0 to cancel): " -ForegroundColor White -NoNewline
    $choice = (Read-Host).Trim()

    if (-not $choice -or $choice -eq "0") { return $null }

    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $checkpoints.Count) {
        return $checkpoints[$idx - 1]
    }

    Write-Step "Invalid selection." -Type Error
    return $null
}

function Show-VMCheckpoints {
    Write-MenuHeader "View VM Checkpoints"

    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vm = Select-VMFromList -Prompt "Select VM to view checkpoints"
    if (-not $vm) { Pause-Menu; return }

    $checkpoints = @(Get-VMCheckpoint -VMName $vm.Name -ErrorAction SilentlyContinue)
    if ($checkpoints.Count -eq 0) {
        Write-Step "No checkpoints for '$($vm.Name)'." -Type Info
        Write-Host ""
        Write-Host "  Checkpoints save the VM state at a point in time," -ForegroundColor DarkGray
        Write-Host "  so you can roll back if something goes wrong." -ForegroundColor DarkGray
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  Checkpoints for '$($vm.Name)':" -ForegroundColor White
    Write-Host ("  " + "-" * 55) -ForegroundColor DarkGray
    foreach ($cp in $checkpoints) {
        $created = try { $cp.CreationTime.ToString('yyyy-MM-dd HH:mm') } catch { "N/A" }
        $parent = if ($cp.ParentCheckpointName) { " -> $($cp.ParentCheckpointName)" } else { "" }
        Write-Host "  $($cp.Name.PadRight(30)) $created$parent" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  Total: $($checkpoints.Count) checkpoint(s)" -ForegroundColor White
    Write-Host ""
    Pause-Menu
}

function New-VMCheckpointAction {
    Write-MenuHeader "Create Checkpoint (Save VM State)"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    Write-Host ""
    Write-Host "  A checkpoint saves the current VM state." -ForegroundColor DarkGray
    Write-Host "  You can restore to this state at any time." -ForegroundColor DarkGray
    Write-Host ""

    $vm = Select-VMFromList -Prompt "Select VM for checkpoint"
    if (-not $vm) { Pause-Menu; return }

    $defaultName = "$($vm.Name)_$(Get-Date -Format 'yyyyMMdd_HHmm')"
    Write-Host "  Checkpoint name [$defaultName]: " -ForegroundColor White -NoNewline
    $cpName = (Read-Host).Trim()
    if (-not $cpName) { $cpName = $defaultName }

    try {
        Write-Step "Creating checkpoint..." -Type Info
        Checkpoint-VM -Name $vm.Name -SnapshotName $cpName -ErrorAction Stop
        Write-Step "Checkpoint '$cpName' created." -Type Success
        Write-Log "Created checkpoint '$cpName' for VM '$($vm.Name)'."
    }
    catch {
        Write-Step "Failed to create checkpoint: $_" -Type Error
    }

    Pause-Menu
}

function Restore-VMCheckpointAction {
    Write-MenuHeader "Restore Checkpoint (Roll Back)"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vm = Select-VMFromList -Prompt "Select VM to restore"
    if (-not $vm) { Pause-Menu; return }

    $cp = Select-CheckpointFromVM -VMName $vm.Name
    if (-not $cp) { Pause-Menu; return }

    # Check if VM is running - must be stopped to restore
    if ($vm.State -eq 'Running') {
        Write-Step "VM '$($vm.Name)' is currently running." -Type Warning
        if (Confirm-Action "Stop the VM before restoring?") {
            try {
                Stop-VM -Name $vm.Name -Force -TurnOff -ErrorAction Stop
                Write-Step "VM stopped." -Type Success
            }
            catch {
                Write-Step "Failed to stop VM: $_" -Type Error
                Pause-Menu
                return
            }
        }
        else {
            Write-Step "Cannot restore checkpoint while VM is running." -Type Error
            Pause-Menu
            return
        }
    }

    Write-Host ""
    Write-Step "WARNING: Current VM state will be lost!" -Type Warning
    Write-Step "VM will be reverted to checkpoint '$($cp.Name)'." -Type Warning
    Write-Host ""

    if (-not (Confirm-Action "Restore VM '$($vm.Name)' to '$($cp.Name)'?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        Write-Step "Restoring..." -Type Info
        Restore-VMCheckpoint -VMCheckpoint $cp -Confirm:$false -ErrorAction Stop
        Write-Step "VM '$($vm.Name)' restored to '$($cp.Name)'." -Type Success
        Write-Log "Restored VM '$($vm.Name)' to checkpoint '$($cp.Name)'."
    }
    catch {
        Write-Step "Restore failed: $_" -Type Error
    }

    Pause-Menu
}

function Remove-VMCheckpointAction {
    Write-MenuHeader "Remove Checkpoint"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vm = Select-VMFromList -Prompt "Select VM"
    if (-not $vm) { Pause-Menu; return }

    $cp = Select-CheckpointFromVM -VMName $vm.Name
    if (-not $cp) { Pause-Menu; return }

    if (-not (Confirm-Action "Delete checkpoint '$($cp.Name)'?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        Remove-VMCheckpoint -VMCheckpoint $cp -Confirm:$false -ErrorAction Stop
        Write-Step "Checkpoint '$($cp.Name)' removed." -Type Success
        Write-Log "Removed checkpoint '$($cp.Name)' from VM '$($vm.Name)'."
    }
    catch {
        Write-Step "Failed to remove checkpoint: $_" -Type Error
    }

    Pause-Menu
}

# ============================================================================
# Resource Monitoring
# ============================================================================

function Show-VMResourceUsage {
    Write-MenuHeader "VM Resource Usage"

    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vms = @(Get-VM -ErrorAction SilentlyContinue)
    if ($vms.Count -eq 0) {
        Write-Step "No virtual machines found." -Type Info
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "  VM Name                       State       CPU%  RAM Used   RAM Demand  Uptime" -ForegroundColor White
    Write-Host ("  " + "-" * 85) -ForegroundColor DarkGray

    foreach ($vm in $vms) {
        $ramUsedMB = if ($vm.MemoryAssigned -gt 0) { [math]::Round($vm.MemoryAssigned / 1MB) } else { 0 }
        $ramDemandMB = if ($vm.MemoryDemand -gt 0) { [math]::Round($vm.MemoryDemand / 1MB) } else { 0 }
        $cpuPct = if ($vm.State -eq 'Running') { "$($vm.CPUUsage)%" } else { "-" }
        $uptime = if ($vm.State -eq 'Running' -and $vm.Uptime) {
            try { $vm.Uptime.ToString("d\.hh\:mm\:ss") } catch { "-" }
        } else { "-" }

        $name = $vm.Name.PadRight(28)
        $state = $vm.State.ToString().PadRight(12)
        $cpuStr = $cpuPct.PadRight(6)
        $ramUsedStr = ("$ramUsedMB MB").PadRight(11)
        $ramDemandStr = ("$ramDemandMB MB").PadRight(12)

        $color = if ($vm.State -eq 'Running') { 'Green' } else { 'DarkGray' }
        Write-Host "  $name$state$cpuStr$ramUsedStr$ramDemandStr$uptime" -ForegroundColor $color
    }

    $running = @($vms | Where-Object State -eq 'Running')
    $totalRAMUsedGB = 0
    $hostRAMGB = 0
    try {
        $memSum = ($vms | Measure-Object -Property MemoryAssigned -Sum -ErrorAction SilentlyContinue).Sum
        if ($memSum) { $totalRAMUsedGB = [math]::Round($memSum / 1GB, 1) }
        $hostRAMGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 1)
    }
    catch {}

    Write-Host ""
    Write-Host ("  " + "-" * 85) -ForegroundColor DarkGray
    Write-Host "  Total: $($vms.Count) VM(s) | Running: $($running.Count) | VM RAM: ${totalRAMUsedGB} GB / ${hostRAMGB} GB host" -ForegroundColor White
    if ($hostRAMGB -gt 0 -and $totalRAMUsedGB -gt ($hostRAMGB * 0.8)) {
        Write-Step "Warning: VM RAM usage exceeds 80% of host RAM!" -Type Warning
    }
    Write-Host ""

    Pause-Menu
}

# ============================================================================
# VM Export / Import (Backup)
# ============================================================================

function Export-HyperVVM {
    Write-MenuHeader "Export VM (Backup)"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vm = Select-VMFromList -Prompt "Select VM to export"
    if (-not $vm) { Pause-Menu; return }

    $defaults = Get-HyperVDefaults
    $defaultPath = if ($defaults.DefaultBackupPath) { $defaults.DefaultBackupPath } else { "C:\HyperV\Backups" }

    Write-Host ""
    Write-Host "  Export destination [$defaultPath]: " -ForegroundColor White -NoNewline
    $destPath = (Read-Host).Trim()
    if (-not $destPath) { $destPath = $defaultPath }

    # Ensure destination exists
    if (-not (Test-Path $destPath)) {
        try {
            New-Item -Path $destPath -ItemType Directory -Force | Out-Null
            Write-Step "Created directory: $destPath" -Type Info
        }
        catch {
            Write-Step "Failed to create directory: $_" -Type Error
            Pause-Menu
            return
        }
    }

    # Check if export already exists
    $exportDir = Join-Path $destPath $vm.Name
    if (Test-Path $exportDir) {
        Write-Step "Export already exists at: $exportDir" -Type Warning
        if (-not (Confirm-Action "Overwrite existing export?")) {
            Write-Step "Cancelled." -Type Warning
            Pause-Menu
            return
        }
        Remove-Item $exportDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Check available space
    try {
        $driveLetter = $destPath.Substring(0, 1)
        $drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
        if ($drive -and $drive.Free) {
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
            Write-Host "  Available space on drive $($driveLetter):: $freeGB GB" -ForegroundColor DarkGray
        }
    }
    catch {}

    if (-not (Confirm-Action "Export VM '$($vm.Name)' to '$destPath'?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        Write-Step "Exporting '$($vm.Name)' (this may take a while)..." -Type Info
        Export-VM -Name $vm.Name -Path $destPath -ErrorAction Stop
        Write-Step "VM '$($vm.Name)' exported successfully." -Type Success

        # Show export size
        if (Test-Path $exportDir) {
            $sizeGB = [math]::Round((Get-ChildItem $exportDir -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB, 2)
            Write-Host "  Export size: $sizeGB GB" -ForegroundColor Cyan
            Write-Host "  Location:    $exportDir" -ForegroundColor Cyan
        }

        Write-Log "Exported VM '$($vm.Name)' to '$destPath'."
    }
    catch {
        Write-Step "Export failed: $_" -Type Error
    }

    Pause-Menu
}

function Import-HyperVVM {
    Write-MenuHeader "Import VM (Restore)"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $defaults = Get-HyperVDefaults
    $defaultPath = if ($defaults.DefaultBackupPath) { $defaults.DefaultBackupPath } else { "C:\HyperV\Backups" }

    Write-Host ""
    Write-Host "  Enter path to exported VM folder [$defaultPath]: " -ForegroundColor White -NoNewline
    $importPath = (Read-Host).Trim().Trim('"')
    if (-not $importPath) { $importPath = $defaultPath }

    if (-not (Test-Path $importPath)) {
        Write-Step "Path not found: $importPath" -Type Error
        Pause-Menu
        return
    }

    # Look for VM config files (.vmcx or .xml)
    $vmcxFiles = @(Get-ChildItem -Path $importPath -Filter "*.vmcx" -Recurse -ErrorAction SilentlyContinue)
    $xmlFiles = @(Get-ChildItem -Path $importPath -Filter "*.xml" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'Virtual Machines' })

    $configFiles = @($vmcxFiles) + @($xmlFiles)
    if ($configFiles.Count -eq 0) {
        Write-Step "No VM configuration files found in '$importPath'." -Type Error
        Write-Host "  Expected .vmcx or .xml files in a 'Virtual Machines' subfolder." -ForegroundColor DarkGray
        Pause-Menu
        return
    }

    # List found configs
    Write-Host ""
    Write-Host "  Found VM configuration(s):" -ForegroundColor White
    for ($i = 0; $i -lt $configFiles.Count; $i++) {
        $cf = $configFiles[$i]
        Write-Host "    [$($i + 1)] $($cf.Name) ($($cf.DirectoryName))" -ForegroundColor Cyan
    }

    if ($configFiles.Count -eq 1) {
        $selectedConfig = $configFiles[0].FullName
        Write-Host ""
        Write-Host "  Using: $selectedConfig" -ForegroundColor DarkGray
    }
    else {
        Write-Host ""
        Write-Host "  Select config (0 to cancel): " -ForegroundColor White -NoNewline
        $cfChoice = (Read-Host).Trim()
        $cfIdx = 0
        if (-not ([int]::TryParse($cfChoice, [ref]$cfIdx)) -or $cfIdx -lt 1 -or $cfIdx -gt $configFiles.Count) {
            Write-Step "Cancelled." -Type Info
            Pause-Menu
            return
        }
        $selectedConfig = $configFiles[$cfIdx - 1].FullName
    }

    Write-Host ""
    Write-Host "  Import mode:" -ForegroundColor White
    Write-Host "    [1] Copy (Recommended) - Creates a new copy, keeps original backup intact" -ForegroundColor Cyan
    Write-Host "    [2] In-place - Uses files from current location (faster, but backup is consumed)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Select [1]: " -ForegroundColor White -NoNewline
    $modeChoice = (Read-Host).Trim()
    $copyMode = ($modeChoice -ne "2")

    if (-not (Confirm-Action "Import VM from '$selectedConfig'?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    try {
        Write-Step "Importing VM (this may take a while)..." -Type Info

        $importParams = @{
            Path        = $selectedConfig
            ErrorAction = 'Stop'
        }
        if ($copyMode) {
            $importParams.Copy = $true
            $importParams.GenerateNewId = $true
            $vmPath = $defaults.DefaultVMPath
            $vhdPath = $defaults.DefaultVHDPath
            if (-not (Test-Path $vmPath)) { New-Item -Path $vmPath -ItemType Directory -Force | Out-Null }
            if (-not (Test-Path $vhdPath)) { New-Item -Path $vhdPath -ItemType Directory -Force | Out-Null }
            $importParams.VhdDestinationPath = $vhdPath
            $importParams.VirtualMachinePath = $vmPath
        }

        $imported = Import-VM @importParams
        Write-Step "VM '$($imported.Name)' imported successfully." -Type Success
        Write-Log "Imported VM '$($imported.Name)' from '$selectedConfig'."
    }
    catch {
        Write-Step "Import failed: $_" -Type Error
    }

    Pause-Menu
}

# ============================================================================
# Checkpoint Cleanup
# ============================================================================

function Invoke-CheckpointCleanup {
    Write-MenuHeader "Cleanup Old Checkpoints"

    if (-not (Test-IsAdmin)) { Write-RequiresAdmin; Pause-Menu; return }
    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $defaults = Get-HyperVDefaults
    $retention = if ($defaults.CheckpointRetention) { $defaults.CheckpointRetention } else { @{ MaxAgeDays = 30; MaxPerVM = 5 } }
    $maxAge = if ($retention.MaxAgeDays) { [int]$retention.MaxAgeDays } else { 30 }
    $maxPerVM = if ($retention.MaxPerVM) { [int]$retention.MaxPerVM } else { 5 }

    Write-Host ""
    Write-Host "  Retention policy (from settings.json):" -ForegroundColor White
    Write-Host "    Max age:      $maxAge days" -ForegroundColor Cyan
    Write-Host "    Max per VM:   $maxPerVM checkpoints" -ForegroundColor Cyan
    Write-Host ""

    $vms = @(Get-VM -ErrorAction SilentlyContinue)
    if ($vms.Count -eq 0) {
        Write-Step "No virtual machines found." -Type Info
        Pause-Menu
        return
    }

    $cutoffDate = (Get-Date).AddDays(-$maxAge)
    $toDelete = @()

    foreach ($vm in $vms) {
        $checkpoints = @(Get-VMCheckpoint -VMName $vm.Name -ErrorAction SilentlyContinue |
            Sort-Object CreationTime)
        if ($checkpoints.Count -eq 0) { continue }

        # Find checkpoints older than max age
        foreach ($cp in $checkpoints) {
            if ($cp.CreationTime -lt $cutoffDate) {
                $toDelete += @{ VM = $vm.Name; Checkpoint = $cp; Reason = "Older than $maxAge days" }
            }
        }

        # Find excess checkpoints (keep newest $maxPerVM)
        if ($checkpoints.Count -gt $maxPerVM) {
            $excess = $checkpoints | Select-Object -First ($checkpoints.Count - $maxPerVM)
            foreach ($cp in $excess) {
                $already = $toDelete | Where-Object { $_.Checkpoint.Id -eq $cp.Id }
                if (-not $already) {
                    $toDelete += @{ VM = $vm.Name; Checkpoint = $cp; Reason = "Exceeds $maxPerVM per VM" }
                }
            }
        }
    }

    if ($toDelete.Count -eq 0) {
        Write-Step "All checkpoints are within retention policy. Nothing to clean up." -Type Success
        Pause-Menu
        return
    }

    # Show what will be deleted
    Write-Host "  Checkpoints to remove:" -ForegroundColor White
    Write-Host ("  " + "-" * 70) -ForegroundColor DarkGray
    foreach ($item in $toDelete) {
        $cp = $item.Checkpoint
        $age = [math]::Round(((Get-Date) - $cp.CreationTime).TotalDays)
        Write-Host "  $($item.VM.PadRight(20)) $($cp.Name.PadRight(25)) ${age}d old  ($($item.Reason))" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Total: $($toDelete.Count) checkpoint(s) to remove" -ForegroundColor White
    Write-Host ""

    if (-not (Confirm-Action "Remove these $($toDelete.Count) checkpoint(s)?")) {
        Write-Step "Cancelled." -Type Warning
        Pause-Menu
        return
    }

    $removed = 0
    $failed = 0
    foreach ($item in $toDelete) {
        try {
            Remove-VMCheckpoint -VMCheckpoint $item.Checkpoint -Confirm:$false -ErrorAction Stop
            $removed++
        }
        catch {
            Write-Step "Failed to remove '$($item.Checkpoint.Name)' from '$($item.VM)': $_" -Type Error
            $failed++
        }
    }

    Write-Step "Cleanup complete: $removed removed, $failed failed." -Type $(if ($failed -eq 0) { 'Success' } else { 'Warning' })
    Write-Log "Checkpoint cleanup: $removed removed, $failed failed."

    Pause-Menu
}

# ============================================================================
# VM Connection Guide
# ============================================================================

function Show-VMConnectionGuide {
    Write-MenuHeader "VM Connection Guide"

    if (-not (Test-HyperVReady)) { Pause-Menu; return }

    $vms = @(Get-VM -ErrorAction SilentlyContinue | Where-Object State -eq 'Running')

    Write-Host ""
    Write-Host "  How to connect to a Virtual Machine:" -ForegroundColor White
    Write-Host ("  " + "=" * 55) -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  Method 1: Hyper-V Manager (GUI)" -ForegroundColor Cyan
    Write-Host "    1. Open Hyper-V Manager from Start Menu" -ForegroundColor White
    Write-Host "    2. Double-click the VM to open its console" -ForegroundColor White
    Write-Host ""
    Write-Host "  Method 2: vmconnect command (Quick)" -ForegroundColor Cyan
    Write-Host "    Run in PowerShell or CMD:" -ForegroundColor White
    Write-Host ""

    if ($vms.Count -gt 0) {
        foreach ($vm in $vms) {
            Write-Host "    vmconnect localhost `"$($vm.Name)`"" -ForegroundColor Green
        }
    }
    else {
        Write-Host "    vmconnect localhost `"<VMName>`"" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    (No running VMs found)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  Method 3: Remote access from another machine" -ForegroundColor Cyan
    Write-Host "    vmconnect $($env:COMPUTERNAME) `"<VMName>`"" -ForegroundColor White
    Write-Host ""
    Write-Host "  Method 4: RDP into the VM (if OS is installed)" -ForegroundColor Cyan
    Write-Host "    1. Get the VM's IP:  Get-VMNetworkAdapter -VMName `"<Name>`" | Select IPAddresses" -ForegroundColor White
    Write-Host "    2. Connect via RDP:  mstsc /v:<VM-IP>" -ForegroundColor White
    Write-Host ""
    Write-Host ("  " + "=" * 55) -ForegroundColor DarkCyan
    Write-Host ""
    Pause-Menu
}

# ============================================================================
# Menus
# ============================================================================

function Show-VMSwitchMenu {
    while ($true) {
        $choice = Select-MenuOption -Title "Virtual Switch Management" -Items @(
            @{ Key = "1"; Label = "List Virtual Switches" }
            @{ Key = "2"; Label = "Create Virtual Switch" }
            @{ Key = "3"; Label = "Remove Virtual Switch" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back" }
        )
        switch ($choice) {
            "1" { Show-VMSwitchList }
            "2" { New-HyperVSwitch }
            "3" { Remove-HyperVSwitch }
            "B" { return }
        }
    }
}

function Show-VMSnapshotMenu {
    while ($true) {
        $choice = Select-MenuOption -Title "Checkpoint Management (Save / Restore State)" -Items @(
            @{ Key = "1"; Label = "View Checkpoints" }
            @{ Key = "2"; Label = "Create Checkpoint" }
            @{ Key = "3"; Label = "Restore Checkpoint (Roll Back)" }
            @{ Key = "4"; Label = "Remove Checkpoint" }
            @{ Separator = $true }
            @{ Key = "C"; Label = "Cleanup Old Checkpoints (Auto)" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back" }
        )
        switch ($choice) {
            "1" { Show-VMCheckpoints }
            "2" { New-VMCheckpointAction }
            "3" { Restore-VMCheckpointAction }
            "4" { Remove-VMCheckpointAction }
            "C" { Invoke-CheckpointCleanup }
            "B" { return }
        }
    }
}

function Show-HyperVMenu {
    while ($true) {
        $hvStatus = "N/A"
        try {
            if (Test-HyperVInstalled) {
                if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
                    $allVMs = @(Get-VM -ErrorAction SilentlyContinue)
                    $vmCount = $allVMs.Count
                    $runCount = @($allVMs | Where-Object State -eq 'Running').Count
                    $hvStatus = "$runCount/$vmCount VMs"
                }
                else { $hvStatus = "OK" }
            }
        }
        catch { $hvStatus = "?" }

        $choice = Select-MenuOption -Title "Hyper-V Management" -Items @(
            @{ Key = "1"; Label = "Install / Check Hyper-V Role"; Status = $hvStatus }
            @{ Separator = $true }
            @{ Key = "2"; Label = "List Virtual Machines" }
            @{ Key = "3"; Label = "Create New VM" }
            @{ Key = "4"; Label = "Start VM" }
            @{ Key = "5"; Label = "Stop VM" }
            @{ Key = "6"; Label = "Restart VM" }
            @{ Key = "7"; Label = "Modify VM Resources (CPU/RAM)" }
            @{ Key = "8"; Label = "Remove VM" }
            @{ Separator = $true }
            @{ Separator = $true }
            @{ Key = "E"; Label = "Export VM (Backup)" }
            @{ Key = "I"; Label = "Import VM (Restore)" }
            @{ Separator = $true }
            @{ Key = "N"; Label = "Virtual Switch Management" }
            @{ Key = "S"; Label = "Checkpoint (Save / Restore State)" }
            @{ Key = "R"; Label = "Resource Usage Monitor" }
            @{ Key = "G"; Label = "VM Connection Guide" }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back to Main Menu" }
        )
        switch ($choice) {
            "1" { Install-HyperVRole }
            "2" { Show-VMList }
            "3" { New-HyperVVM }
            "4" { Start-HyperVVM }
            "5" { Stop-HyperVVM }
            "6" { Restart-HyperVVM }
            "7" { Set-HyperVMResources }
            "8" { Remove-HyperVVM }
            "E" { Export-HyperVVM }
            "I" { Import-HyperVVM }
            "N" { Show-VMSwitchMenu }
            "S" { Show-VMSnapshotMenu }
            "R" { Show-VMResourceUsage }
            "G" { Show-VMConnectionGuide }
            "B" { return }
        }
    }
}

Export-ModuleMember -Function *
