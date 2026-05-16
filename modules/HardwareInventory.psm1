# ============================================================================
# WinGateKeeper - Hardware Inventory & Integrity Module
# Collects hardware snapshot, runs health checks, detects replaced/missing
# components by comparing against a signed baseline. Supports all Windows
# versions from 7 / Server 2012 R2 onward (PowerShell 5.1+).
# ============================================================================

Import-Module "$PSScriptRoot\Utils.psm1" -Force

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Get-HardwareBaselinePath {
    $settings = Get-Settings
    if ($settings.HardwareInventory -and $settings.HardwareInventory.BaselinePath) {
        return $settings.HardwareInventory.BaselinePath
    }
    return (Join-Path $settings.BasePath "hardware-baseline.json")
}

function Get-HardwareThresholds {
    # Returns a hashtable of thresholds, merging settings.json overrides on top of safe defaults.
    # Any missing key in settings falls back to default - no crash if config is partial.
    $defaults = @{
        DiskPowerOnHoursWarn          = 10000
        DiskPowerOnHoursFail          = 20000
        SSDWearWarnPercent            = 50
        SSDWearFailPercent            = 80
        DiskTempWarnCelsius           = 60
        DiskFreeSpaceWarnPercent      = 15
        DiskFreeSpaceFailPercent      = 5
        BatteryWearWarnPercent        = 15
        BatteryWearFailPercent        = 30
        OSInstallRecentWarnDays       = 60
        WHEALookbackDays              = 90
        BSODLookbackDays              = 90
        BSODWarnCount                 = 3
        UnexpectedShutdownLookbackDays = 90
        UnexpectedShutdownWarnCount   = 5
        GPUDriverCrashLookbackDays    = 90
        GPUDriverCrashWarnCount       = 3
        EventLookbackDays             = 7
        RAMMismatchToleranceBytes     = 1073741824
        RecentInstallLookbackDays     = 30
        USBHistoryShowLast            = 25
        BenchmarkDiskSizeMB           = 100
        BenchmarkCPUIterations        = 500
        BenchmarkMemorySizeMB         = 50
        BenchmarkMemoryIterations     = 10
        RunBenchmarks                 = $true
    }

    try {
        $settings = Get-Settings
        if ($settings -and $settings.HardwareInventory -and $settings.HardwareInventory.Thresholds) {
            $overrides = $settings.HardwareInventory.Thresholds
            foreach ($prop in $overrides.PSObject.Properties) {
                if ($defaults.ContainsKey($prop.Name) -and $null -ne $prop.Value) {
                    $defaults[$prop.Name] = $prop.Value
                }
            }
        }
    } catch {}

    return $defaults
}

function Get-HardwareReportDir {
    $settings = Get-Settings
    if ($settings.HardwareInventory -and $settings.HardwareInventory.ReportsPath) {
        return $settings.HardwareInventory.ReportsPath
    }
    return (Join-Path $settings.BasePath "HardwareReports")
}

function ConvertTo-CanonicalJson {
    # Produces stable JSON (sorted keys, no whitespace) for hashing
    param($Object)
    if ($null -eq $Object) { return "null" }
    if ($Object -is [string]) { return ($Object | ConvertTo-Json -Compress) }
    if ($Object -is [bool] -or $Object -is [int] -or $Object -is [long] -or $Object -is [double] -or $Object -is [decimal]) {
        return ($Object | ConvertTo-Json -Compress)
    }
    if ($Object -is [System.Collections.IDictionary] -or $Object -is [pscustomobject]) {
        $props = if ($Object -is [System.Collections.IDictionary]) { $Object.Keys } else { $Object.PSObject.Properties.Name }
        $sorted = $props | Sort-Object
        $parts = foreach ($k in $sorted) {
            $v = if ($Object -is [System.Collections.IDictionary]) { $Object[$k] } else { $Object.$k }
            ($k | ConvertTo-Json -Compress) + ":" + (ConvertTo-CanonicalJson -Object $v)
        }
        return "{" + ($parts -join ",") + "}"
    }
    if ($Object -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $Object) { ConvertTo-CanonicalJson -Object $item }
        return "[" + ($parts -join ",") + "]"
    }
    return ($Object.ToString() | ConvertTo-Json -Compress)
}

function Get-StringSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Safe-Trim {
    param($Value)
    if ($null -eq $Value) { return "" }
    return ($Value.ToString().Trim())
}

# ----------------------------------------------------------------------------
# Snapshot Collection
# ----------------------------------------------------------------------------

function Get-HardwareSnapshot {
    <#
    .SYNOPSIS
        Collects a complete hardware snapshot of the current machine.
        Returns a structured hashtable suitable for display, export, hashing.
    #>
    [CmdletBinding()]
    param()

    $snap = [ordered]@{
        CollectedAt    = (Get-Date).ToString("o")
        Hostname       = $env:COMPUTERNAME
        SchemaVersion  = 1
        System         = $null
        BIOS           = $null
        OS             = $null
        BaseBoard      = $null
        CPU            = @()
        Memory         = @()
        Disks          = @()
        GPUs           = @()
        NetworkAdapters= @()
        Monitors       = @()
        Battery        = $null
        TPM            = $null
        SecureBoot     = $null
        ProblemDevices = @()
    }

    # System / ComputerSystem
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $snap.System = [ordered]@{
            Manufacturer = Safe-Trim $cs.Manufacturer
            Model        = Safe-Trim $cs.Model
            SystemType   = Safe-Trim $cs.SystemType
            TotalRAM     = [int64]$cs.TotalPhysicalMemory
            Domain       = Safe-Trim $cs.Domain
            UUID         = $null
        }
        $sysProd = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
        if ($sysProd) {
            $snap.System.UUID         = Safe-Trim $sysProd.UUID
            $snap.System.SerialNumber = Safe-Trim $sysProd.IdentifyingNumber
        }
    } catch { Write-Log "HW: ComputerSystem query failed: $_" "WARN" }

    # BIOS
    try {
        $b = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $snap.BIOS = [ordered]@{
            Manufacturer  = Safe-Trim $b.Manufacturer
            Version       = Safe-Trim $b.SMBIOSBIOSVersion
            SerialNumber  = Safe-Trim $b.SerialNumber
            ReleaseDate   = if ($b.ReleaseDate) { $b.ReleaseDate.ToString("o") } else { $null }
            SMBIOSVersion = "$($b.SMBIOSMajorVersion).$($b.SMBIOSMinorVersion)"
        }
    } catch { Write-Log "HW: BIOS query failed: $_" "WARN" }

    # OS
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $snap.OS = [ordered]@{
            Caption        = Safe-Trim $os.Caption
            Version        = Safe-Trim $os.Version
            BuildNumber    = Safe-Trim $os.BuildNumber
            Architecture   = Safe-Trim $os.OSArchitecture
            InstallDate    = if ($os.InstallDate) { $os.InstallDate.ToString("o") } else { $null }
            LastBootUpTime = if ($os.LastBootUpTime) { $os.LastBootUpTime.ToString("o") } else { $null }
        }
    } catch { Write-Log "HW: OS query failed: $_" "WARN" }

    # BaseBoard / Motherboard
    try {
        $mb = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
        $snap.BaseBoard = [ordered]@{
            Manufacturer = Safe-Trim $mb.Manufacturer
            Product      = Safe-Trim $mb.Product
            SerialNumber = Safe-Trim $mb.SerialNumber
            Version      = Safe-Trim $mb.Version
        }
    } catch { Write-Log "HW: BaseBoard query failed: $_" "WARN" }

    # CPU
    try {
        Get-CimInstance Win32_Processor -ErrorAction Stop | ForEach-Object {
            $snap.CPU += [ordered]@{
                Name          = Safe-Trim $_.Name
                Manufacturer  = Safe-Trim $_.Manufacturer
                ProcessorId   = Safe-Trim $_.ProcessorId
                SocketDesign  = Safe-Trim $_.SocketDesignation
                Cores         = [int]$_.NumberOfCores
                Threads       = [int]$_.NumberOfLogicalProcessors
                MaxClockMHz   = [int]$_.MaxClockSpeed
                L2CacheKB     = [int]$_.L2CacheSize
                L3CacheKB     = [int]$_.L3CacheSize
            }
        }
    } catch { Write-Log "HW: CPU query failed: $_" "WARN" }

    # Memory (each DIMM)
    try {
        Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | ForEach-Object {
            $snap.Memory += [ordered]@{
                BankLabel     = Safe-Trim $_.BankLabel
                DeviceLocator = Safe-Trim $_.DeviceLocator
                Manufacturer  = Safe-Trim $_.Manufacturer
                PartNumber    = Safe-Trim $_.PartNumber
                SerialNumber  = Safe-Trim $_.SerialNumber
                Capacity      = [int64]$_.Capacity
                SpeedMHz      = [int]$_.Speed
                ConfiguredClockSpeed = [int]$_.ConfiguredClockSpeed
                FormFactor    = [int]$_.FormFactor
            }
        }
    } catch { Write-Log "HW: Memory query failed: $_" "WARN" }

    # Disks
    try {
        $physDisks = @()
        try { $physDisks = @(Get-PhysicalDisk -ErrorAction Stop) } catch {}
        $reliabilityMap = @{}
        if ($physDisks.Count -gt 0) {
            foreach ($pd in $physDisks) {
                try {
                    $rel = Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction SilentlyContinue
                    if ($rel) { $reliabilityMap[$pd.SerialNumber] = $rel }
                } catch {}
            }
        }
        Get-CimInstance Win32_DiskDrive -ErrorAction Stop | ForEach-Object {
            $w = $_
            $sn = Safe-Trim $w.SerialNumber
            $pd = $physDisks | Where-Object { (Safe-Trim $_.SerialNumber) -eq $sn } | Select-Object -First 1
            $rel = $reliabilityMap[$sn]
            $snap.Disks += [ordered]@{
                Model        = Safe-Trim $w.Model
                SerialNumber = $sn
                FirmwareRev  = Safe-Trim $w.FirmwareRevision
                InterfaceType= Safe-Trim $w.InterfaceType
                Size         = [int64]$w.Size
                MediaType    = if ($pd) { Safe-Trim $pd.MediaType } else { "" }
                BusType      = if ($pd) { Safe-Trim $pd.BusType } else { "" }
                HealthStatus = if ($pd) { Safe-Trim $pd.HealthStatus } else { "Unknown" }
                OperationalStatus = if ($pd) { (@($pd.OperationalStatus) -join ", ") } else { "" }
                Wear         = if ($rel) { $rel.Wear } else { $null }
                Temperature  = if ($rel) { $rel.Temperature } else { $null }
                ReadErrorsTotal  = if ($rel) { $rel.ReadErrorsTotal } else { $null }
                WriteErrorsTotal = if ($rel) { $rel.WriteErrorsTotal } else { $null }
                PowerOnHours = if ($rel) { $rel.PowerOnHours } else { $null }
            }
        }
    } catch { Write-Log "HW: Disk query failed: $_" "WARN" }

    # GPU
    try {
        Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object {
            $snap.GPUs += [ordered]@{
                Name          = Safe-Trim $_.Name
                DriverVersion = Safe-Trim $_.DriverVersion
                DriverDate    = if ($_.DriverDate) { $_.DriverDate.ToString("o") } else { $null }
                AdapterRAM    = [int64]($_.AdapterRAM | ForEach-Object { if ($_ -lt 0) { 0 } else { $_ } } | Select-Object -First 1)
                PnPDeviceID   = Safe-Trim $_.PNPDeviceID
                VideoMode     = Safe-Trim $_.VideoModeDescription
                Status        = Safe-Trim $_.Status
            }
        }
    } catch { Write-Log "HW: GPU query failed: $_" "WARN" }

    # Network Adapters (physical only)
    try {
        $adapters = @()
        try { $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { -not $_.Virtual }) } catch {}
        foreach ($a in $adapters) {
            $snap.NetworkAdapters += [ordered]@{
                Name           = Safe-Trim $a.Name
                InterfaceDescription = Safe-Trim $a.InterfaceDescription
                MacAddress     = Safe-Trim $a.MacAddress
                LinkSpeed      = Safe-Trim $a.LinkSpeed
                Status         = Safe-Trim $a.Status
                DriverVersion  = Safe-Trim $a.DriverVersion
                PnPDeviceID    = Safe-Trim $a.PnPDeviceID
            }
        }
        if ($adapters.Count -eq 0) {
            # Fallback for older systems
            Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.PhysicalAdapter -eq $true -and $_.MACAddress } |
                ForEach-Object {
                    $snap.NetworkAdapters += [ordered]@{
                        Name           = Safe-Trim $_.Name
                        InterfaceDescription = Safe-Trim $_.Description
                        MacAddress     = Safe-Trim $_.MACAddress
                        LinkSpeed      = Safe-Trim $_.Speed
                        Status         = if ($_.NetEnabled) { "Up" } else { "Down" }
                        DriverVersion  = ""
                        PnPDeviceID    = Safe-Trim $_.PNPDeviceID
                    }
                }
        }
    } catch { Write-Log "HW: Network adapter query failed: $_" "WARN" }

    # Monitors (EDID)
    try {
        Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object {
            $mfg = if ($_.ManufacturerName) { -join ($_.ManufacturerName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) } else { "" }
            $prod = if ($_.ProductCodeID) { -join ($_.ProductCodeID | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) } else { "" }
            $sn = if ($_.SerialNumberID) { -join ($_.SerialNumberID | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) } else { "" }
            $name = if ($_.UserFriendlyName) { -join ($_.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) } else { "" }
            $snap.Monitors += [ordered]@{
                Manufacturer    = $mfg
                ProductCode     = $prod
                SerialNumber    = $sn
                Name            = $name
                ManufactureYear = [int]$_.YearOfManufacture
            }
        }
    } catch { Write-Log "HW: Monitor EDID not available: $_" "INFO" }

    # Battery (laptops only)
    try {
        $batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($batt) {
            $design = $null; $full = $null
            try {
                $bs = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue
                $bf = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue
                if ($bs) { $design = ($bs | Select-Object -First 1).DesignedCapacity }
                if ($bf) { $full   = ($bf | Select-Object -First 1).FullChargedCapacity }
            } catch {}
            $wear = $null
            if ($design -and $full -and $design -gt 0) {
                $wear = [math]::Round((($design - $full) / $design) * 100, 2)
            }
            $snap.Battery = [ordered]@{
                Name                = Safe-Trim $batt.Name
                DeviceID            = Safe-Trim $batt.DeviceID
                EstimatedChargePct  = [int]$batt.EstimatedChargeRemaining
                DesignCapacitymWh   = $design
                FullChargeCapacitymWh = $full
                WearPercent         = $wear
                Status              = Safe-Trim $batt.Status
            }
        }
    } catch { Write-Log "HW: Battery query failed: $_" "WARN" }

    # TPM
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $snap.TPM = [ordered]@{
            TpmPresent    = [bool]$tpm.TpmPresent
            TpmReady      = [bool]$tpm.TpmReady
            TpmEnabled    = [bool]$tpm.TpmEnabled
            TpmActivated  = [bool]$tpm.TpmActivated
            ManufacturerVersion = Safe-Trim $tpm.ManufacturerVersion
            ManufacturerIdTxt   = Safe-Trim $tpm.ManufacturerIdTxt
        }
    } catch {
        # Fallback via WMI
        try {
            $tpmWmi = Get-CimInstance -Namespace "root\cimv2\security\microsofttpm" -ClassName Win32_Tpm -ErrorAction Stop
            if ($tpmWmi) {
                $snap.TPM = [ordered]@{
                    TpmPresent          = $true
                    TpmReady            = [bool]$tpmWmi.IsEnabled_InitialValue
                    TpmEnabled          = [bool]$tpmWmi.IsEnabled_InitialValue
                    TpmActivated        = [bool]$tpmWmi.IsActivated_InitialValue
                    ManufacturerVersion = Safe-Trim $tpmWmi.ManufacturerVersion
                    ManufacturerIdTxt   = Safe-Trim $tpmWmi.ManufacturerIdTxt
                }
            }
        } catch {
            $snap.TPM = [ordered]@{ TpmPresent = $false }
        }
    }

    # Secure Boot
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        $snap.SecureBoot = [ordered]@{ Supported = $true; Enabled = [bool]$sb }
    } catch {
        $snap.SecureBoot = [ordered]@{ Supported = $false; Enabled = $false }
    }

    # PnP Problem Devices
    try {
        $bad = Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -ne 'OK' }
        foreach ($d in $bad) {
            $snap.ProblemDevices += [ordered]@{
                FriendlyName = Safe-Trim $d.FriendlyName
                Class        = Safe-Trim $d.Class
                Status       = Safe-Trim $d.Status
                ProblemCode  = [int]$d.ProblemCode
                InstanceId   = Safe-Trim $d.InstanceId
            }
        }
    } catch { Write-Log "HW: PnP device query failed: $_" "WARN" }

    return $snap
}

# ----------------------------------------------------------------------------
# Display
# ----------------------------------------------------------------------------

function Show-HardwareInventory {
    Write-MenuHeader "Hardware Inventory"

    Write-Step "Collecting hardware information..." -Type Info
    $snap = Get-HardwareSnapshot

    Write-Host ""
    Write-Host "  System" -ForegroundColor White
    Write-Separator
    if ($snap.System) {
        Write-Host "    Manufacturer : $($snap.System.Manufacturer)" -ForegroundColor Cyan
        Write-Host "    Model        : $($snap.System.Model)" -ForegroundColor Cyan
        Write-Host "    Serial       : $($snap.System.SerialNumber)" -ForegroundColor Cyan
        Write-Host "    UUID         : $($snap.System.UUID)" -ForegroundColor Cyan
        Write-Host "    Total RAM    : $(Format-Bytes $snap.System.TotalRAM)" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  Operating System" -ForegroundColor White
    Write-Separator
    if ($snap.OS) {
        Write-Host "    Caption      : $($snap.OS.Caption)" -ForegroundColor Cyan
        Write-Host "    Version      : $($snap.OS.Version) (Build $($snap.OS.BuildNumber))" -ForegroundColor Cyan
        Write-Host "    Architecture : $($snap.OS.Architecture)" -ForegroundColor Cyan
        Write-Host "    Installed    : $($snap.OS.InstallDate)" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  BIOS / Firmware" -ForegroundColor White
    Write-Separator
    if ($snap.BIOS) {
        Write-Host "    Vendor       : $($snap.BIOS.Manufacturer)" -ForegroundColor Cyan
        Write-Host "    Version      : $($snap.BIOS.Version)" -ForegroundColor Cyan
        Write-Host "    Serial       : $($snap.BIOS.SerialNumber)" -ForegroundColor Cyan
        Write-Host "    Released     : $($snap.BIOS.ReleaseDate)" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  Motherboard" -ForegroundColor White
    Write-Separator
    if ($snap.BaseBoard) {
        Write-Host "    Manufacturer : $($snap.BaseBoard.Manufacturer)" -ForegroundColor Cyan
        Write-Host "    Product      : $($snap.BaseBoard.Product)" -ForegroundColor Cyan
        Write-Host "    Serial       : $($snap.BaseBoard.SerialNumber)" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  CPU ($($snap.CPU.Count) socket(s))" -ForegroundColor White
    Write-Separator
    foreach ($cpu in $snap.CPU) {
        Write-Host "    - $($cpu.Name)" -ForegroundColor Cyan
        Write-Host "      ID: $($cpu.ProcessorId)  Socket: $($cpu.SocketDesign)" -ForegroundColor DarkCyan
        Write-Host "      Cores: $($cpu.Cores)  Threads: $($cpu.Threads)  Max: $($cpu.MaxClockMHz) MHz" -ForegroundColor DarkCyan
    }

    Write-Host ""
    Write-Host "  Memory ($($snap.Memory.Count) module(s))" -ForegroundColor White
    Write-Separator
    foreach ($m in $snap.Memory) {
        Write-Host ("    - [{0}] {1} {2} {3} @ {4} MHz  SN:{5}" -f `
            $m.DeviceLocator, $m.Manufacturer, $m.PartNumber, (Format-Bytes $m.Capacity), $m.SpeedMHz, $m.SerialNumber) -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  Disks ($($snap.Disks.Count))" -ForegroundColor White
    Write-Separator
    foreach ($d in $snap.Disks) {
        $healthColor = if ($d.HealthStatus -eq "Healthy") { "Green" } elseif ($d.HealthStatus -eq "Unknown") { "DarkYellow" } else { "Red" }
        Write-Host "    - $($d.Model)" -ForegroundColor Cyan
        Write-Host "      SN: $($d.SerialNumber)  FW: $($d.FirmwareRev)  Bus: $($d.BusType)  Media: $($d.MediaType)" -ForegroundColor DarkCyan
        Write-Host "      Size: $(Format-Bytes $d.Size)  Health: " -ForegroundColor DarkCyan -NoNewline
        Write-Host $d.HealthStatus -ForegroundColor $healthColor
        if ($d.Wear -ne $null -or $d.Temperature -ne $null) {
            $wearTxt = if ($d.Wear -ne $null) { "Wear:$($d.Wear)%" } else { "" }
            $tempTxt = if ($d.Temperature -ne $null) { "Temp:$($d.Temperature)C" } else { "" }
            $errTxt  = if ($d.ReadErrorsTotal) { "ReadErr:$($d.ReadErrorsTotal)" } else { "" }
            Write-Host "      $wearTxt $tempTxt $errTxt" -ForegroundColor DarkCyan
        }
    }

    Write-Host ""
    Write-Host "  GPUs ($($snap.GPUs.Count))" -ForegroundColor White
    Write-Separator
    foreach ($g in $snap.GPUs) {
        Write-Host "    - $($g.Name)" -ForegroundColor Cyan
        Write-Host "      Driver: $($g.DriverVersion)  VRAM: $(Format-Bytes $g.AdapterRAM)  Status: $($g.Status)" -ForegroundColor DarkCyan
    }

    Write-Host ""
    Write-Host "  Network Adapters ($($snap.NetworkAdapters.Count))" -ForegroundColor White
    Write-Separator
    foreach ($n in $snap.NetworkAdapters) {
        Write-Host "    - $($n.Name) [$($n.MacAddress)]" -ForegroundColor Cyan
        Write-Host "      $($n.InterfaceDescription)  Link:$($n.LinkSpeed)  $($n.Status)" -ForegroundColor DarkCyan
    }

    if ($snap.Monitors.Count -gt 0) {
        Write-Host ""
        Write-Host "  Monitors ($($snap.Monitors.Count))" -ForegroundColor White
        Write-Separator
        foreach ($mon in $snap.Monitors) {
            Write-Host "    - $($mon.Manufacturer) $($mon.ProductCode) SN:$($mon.SerialNumber)  Year:$($mon.ManufactureYear)" -ForegroundColor Cyan
        }
    }

    if ($snap.Battery) {
        Write-Host ""
        Write-Host "  Battery" -ForegroundColor White
        Write-Separator
        Write-Host "    $($snap.Battery.Name)  Charge: $($snap.Battery.EstimatedChargePct)%" -ForegroundColor Cyan
        if ($snap.Battery.WearPercent -ne $null) {
            $wearColor = if ($snap.Battery.WearPercent -gt 30) { "Red" } elseif ($snap.Battery.WearPercent -gt 15) { "Yellow" } else { "Green" }
            Write-Host "    Wear: " -ForegroundColor DarkCyan -NoNewline
            Write-Host "$($snap.Battery.WearPercent)%" -ForegroundColor $wearColor
        }
    }

    Write-Host ""
    Write-Host "  TPM & Secure Boot" -ForegroundColor White
    Write-Separator
    if ($snap.TPM) {
        Write-Host "    TPM Present: $($snap.TPM.TpmPresent)  Ready: $($snap.TPM.TpmReady)" -ForegroundColor Cyan
    }
    if ($snap.SecureBoot) {
        Write-Host "    Secure Boot: Supported=$($snap.SecureBoot.Supported)  Enabled=$($snap.SecureBoot.Enabled)" -ForegroundColor Cyan
    }

    if ($snap.ProblemDevices.Count -gt 0) {
        Write-Host ""
        Write-Host "  Problem Devices ($($snap.ProblemDevices.Count))" -ForegroundColor Yellow
        Write-Separator
        foreach ($p in $snap.ProblemDevices) {
            Write-Host "    - [$($p.Status)] $($p.FriendlyName) (Class: $($p.Class), Code: $($p.ProblemCode))" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Log "Hardware inventory displayed."
}

# ----------------------------------------------------------------------------
# Health Check
# ----------------------------------------------------------------------------

function Invoke-HardwareHealthCheck {
    Write-MenuHeader "Hardware Health Check"

    $snap = Get-HardwareSnapshot
    $issues = @()
    $passed = 0
    $failed = 0

    Write-Host ""

    # Disks
    foreach ($d in $snap.Disks) {
        $label = "Disk: $($d.Model)".PadRight(50)
        Write-Host "  $label " -NoNewline
        if ($d.HealthStatus -eq "Healthy") {
            Write-Host "OK" -ForegroundColor Green
            $passed++
        }
        elseif ($d.HealthStatus -eq "Unknown" -or [string]::IsNullOrEmpty($d.HealthStatus)) {
            Write-Host "UNKNOWN" -ForegroundColor DarkYellow
        }
        else {
            Write-Host "FAIL ($($d.HealthStatus))" -ForegroundColor Red
            $issues += "Disk '$($d.Model)' health is $($d.HealthStatus)"
            $failed++
        }

        if ($d.Wear -ne $null -and $d.Wear -gt 80) {
            Write-Host "    [!] Wear level $($d.Wear)% (over 80%)" -ForegroundColor Red
            $issues += "Disk '$($d.Model)' wear $($d.Wear)% - replace soon"
            $failed++
        }
        if ($d.Temperature -ne $null -and $d.Temperature -gt 60) {
            Write-Host "    [!] Temperature $($d.Temperature)C" -ForegroundColor Yellow
            $issues += "Disk '$($d.Model)' running hot ($($d.Temperature)C)"
        }
        if ($d.ReadErrorsTotal -and $d.ReadErrorsTotal -gt 0) {
            Write-Host "    [!] Read errors: $($d.ReadErrorsTotal)" -ForegroundColor Yellow
            $issues += "Disk '$($d.Model)' has $($d.ReadErrorsTotal) read errors"
        }
    }

    # Battery wear
    if ($snap.Battery -and $snap.Battery.WearPercent -ne $null) {
        $label = "Battery wear".PadRight(50)
        Write-Host "  $label " -NoNewline
        if ($snap.Battery.WearPercent -gt 30) {
            Write-Host "DEGRADED ($($snap.Battery.WearPercent)%)" -ForegroundColor Red
            $issues += "Battery wear is $($snap.Battery.WearPercent)% - consider replacement"
            $failed++
        }
        else {
            Write-Host "OK ($($snap.Battery.WearPercent)%)" -ForegroundColor Green
            $passed++
        }
    }

    # PnP Problem devices
    $label = "PnP devices".PadRight(50)
    Write-Host "  $label " -NoNewline
    if ($snap.ProblemDevices.Count -eq 0) {
        Write-Host "OK" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "$($snap.ProblemDevices.Count) issue(s)" -ForegroundColor Red
        foreach ($p in $snap.ProblemDevices) {
            Write-Host "    - $($p.FriendlyName) [$($p.Status), code $($p.ProblemCode)]" -ForegroundColor Yellow
            $issues += "Device '$($p.FriendlyName)' status $($p.Status) (code $($p.ProblemCode))"
        }
        $failed += $snap.ProblemDevices.Count
    }

    # WHEA hardware errors in last 7 days
    $label = "WHEA hardware errors (7 days)".PadRight(50)
    Write-Host "  $label " -NoNewline
    try {
        $since = (Get-Date).AddDays(-7)
        $whea = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$since } -ErrorAction SilentlyContinue
        if ($whea -and $whea.Count -gt 0) {
            Write-Host "$($whea.Count) event(s)" -ForegroundColor Red
            $issues += "$($whea.Count) WHEA hardware error events in last 7 days - possible CPU/RAM/PCIe fault"
            $failed++
        }
        else {
            Write-Host "OK" -ForegroundColor Green
            $passed++
        }
    } catch {
        Write-Host "SKIPPED" -ForegroundColor DarkGray
    }

    # Disk errors in last 7 days
    $label = "Disk I/O errors (7 days)".PadRight(50)
    Write-Host "  $label " -NoNewline
    try {
        $since = (Get-Date).AddDays(-7)
        $diskErr = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='disk'; Level=1,2,3; StartTime=$since } -ErrorAction SilentlyContinue
        if ($diskErr -and $diskErr.Count -gt 0) {
            Write-Host "$($diskErr.Count) event(s)" -ForegroundColor Yellow
            $issues += "$($diskErr.Count) disk I/O error events in last 7 days"
            $failed++
        }
        else {
            Write-Host "OK" -ForegroundColor Green
            $passed++
        }
    } catch {
        Write-Host "SKIPPED" -ForegroundColor DarkGray
    }

    # Memory diagnostic results
    $label = "Memory diagnostic results".PadRight(50)
    Write-Host "  $label " -NoNewline
    try {
        $mem = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($mem) {
            if ($mem.Id -eq 1201) {
                Write-Host "OK (no errors)" -ForegroundColor Green
                $passed++
            }
            else {
                Write-Host "FAIL (errors found)" -ForegroundColor Red
                $issues += "Last memory diagnostic reported errors (event $($mem.Id))"
                $failed++
            }
        }
        else {
            Write-Host "NOT RUN" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "SKIPPED" -ForegroundColor DarkGray
    }

    # Volume health (logical drives)
    $label = "Volume health".PadRight(50)
    Write-Host "  $label " -NoNewline
    try {
        $bad = Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.HealthStatus -and $_.HealthStatus -ne 'Healthy' }
        if (-not $bad -or $bad.Count -eq 0) {
            Write-Host "OK" -ForegroundColor Green
            $passed++
        }
        else {
            Write-Host "$($bad.Count) unhealthy" -ForegroundColor Red
            foreach ($v in $bad) {
                $issues += "Volume $($v.DriveLetter): health is $($v.HealthStatus)"
            }
            $failed += $bad.Count
        }
    } catch {
        Write-Host "SKIPPED" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host ("  " + "=" * 50) -ForegroundColor DarkCyan
    Write-Host "  Results: " -NoNewline
    Write-Host "$passed passed" -ForegroundColor Green -NoNewline
    Write-Host ", " -NoNewline
    if ($failed -gt 0) {
        Write-Host "$failed failed" -ForegroundColor Red
    }
    else {
        Write-Host "$failed failed" -ForegroundColor Green
    }

    if ($issues.Count -gt 0) {
        Write-Host ""
        Write-Host "  Issues found:" -ForegroundColor Yellow
        foreach ($i in $issues) {
            Write-Host "   - $i" -ForegroundColor White
        }
    }
    else {
        Write-Host ""
        Write-Step "All hardware checks passed." -Type Success
    }

    Write-Log "Hardware health check complete. Passed=$passed Failed=$failed"
    Write-Host ""
}

# ----------------------------------------------------------------------------
# Baseline (save / compare)
# ----------------------------------------------------------------------------

function Get-HardwareIdentity {
    # Returns the canonical "what defines this hardware" subset used for diffing.
    param($Snap)

    $identity = [ordered]@{
        System    = if ($Snap.System) { [ordered]@{
            Manufacturer = $Snap.System.Manufacturer
            Model        = $Snap.System.Model
            UUID         = $Snap.System.UUID
            SerialNumber = $Snap.System.SerialNumber
        }} else { @{} }
        BIOS = if ($Snap.BIOS) { [ordered]@{
            Manufacturer = $Snap.BIOS.Manufacturer
            SerialNumber = $Snap.BIOS.SerialNumber
            Version      = $Snap.BIOS.Version
        }} else { @{} }
        BaseBoard = if ($Snap.BaseBoard) { [ordered]@{
            Manufacturer = $Snap.BaseBoard.Manufacturer
            Product      = $Snap.BaseBoard.Product
            SerialNumber = $Snap.BaseBoard.SerialNumber
        }} else { @{} }
        CPU       = @($Snap.CPU      | ForEach-Object { [ordered]@{ Name=$_.Name; ProcessorId=$_.ProcessorId; Socket=$_.SocketDesign } })
        Memory    = @($Snap.Memory   | ForEach-Object { [ordered]@{ Slot=$_.DeviceLocator; PartNumber=$_.PartNumber; SerialNumber=$_.SerialNumber; Capacity=$_.Capacity } })
        Disks     = @($Snap.Disks    | ForEach-Object { [ordered]@{ Model=$_.Model; SerialNumber=$_.SerialNumber; Size=$_.Size } })
        GPUs      = @($Snap.GPUs     | ForEach-Object { [ordered]@{ Name=$_.Name; PnPDeviceID=$_.PnPDeviceID } })
        NICs      = @($Snap.NetworkAdapters | ForEach-Object { [ordered]@{ Description=$_.InterfaceDescription; MAC=$_.MacAddress; PnPDeviceID=$_.PnPDeviceID } })
        Monitors  = @($Snap.Monitors | ForEach-Object { [ordered]@{ Manufacturer=$_.Manufacturer; ProductCode=$_.ProductCode; SerialNumber=$_.SerialNumber } })
    }
    return $identity
}

function Save-HardwareBaseline {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    $path = Get-HardwareBaselinePath
    if ((Test-Path $path) -and -not $Force) {
        Write-Step "Baseline already exists at $path" -Type Warning
        if (-not (Confirm-Action "Overwrite existing baseline?")) {
            Write-Step "Cancelled." -Type Info
            return
        }
    }

    Write-Step "Collecting hardware snapshot..." -Type Info
    $snap = Get-HardwareSnapshot
    $identity = Get-HardwareIdentity -Snap $snap

    $baseline = [ordered]@{
        CreatedAt = (Get-Date).ToString("o")
        CreatedBy = "$env:USERDOMAIN\$env:USERNAME"
        Hostname  = $env:COMPUTERNAME
        Identity  = $identity
        FullSnapshot = $snap
    }

    $canonical = ConvertTo-CanonicalJson -Object $identity
    $hash = Get-StringSha256 -Text $canonical
    $baseline.IdentityHash = $hash

    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $baseline | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))

    # Lock down ACLs (Admins + SYSTEM only)
    try {
        $acl = New-AdminSystemAcl -Path $path
        Set-Acl -Path $path -AclObject $acl
    } catch {
        Write-Step "Could not harden baseline ACL: $_" -Type Warning
    }

    Write-Step "Baseline saved." -Type Success
    Write-Host "    Path: $path" -ForegroundColor DarkCyan
    Write-Host "    Hash: $hash" -ForegroundColor DarkCyan
    Write-Log "Hardware baseline saved by $($baseline.CreatedBy) (hash $hash)"
}

function Compare-IdentityList {
    # Diff two arrays of ordered dictionaries by their key field
    param($Baseline, $Current, [string]$KeyField, [string]$Category)

    $results = @()
    $baseByKey = @{}
    foreach ($b in $Baseline) {
        $k = $b.$KeyField
        if ([string]::IsNullOrWhiteSpace($k)) { $k = ($b.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '|' }
        $baseByKey[$k] = $b
    }
    $curByKey = @{}
    foreach ($c in $Current) {
        $k = $c.$KeyField
        if ([string]::IsNullOrWhiteSpace($k)) { $k = ($c.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '|' }
        $curByKey[$k] = $c
    }

    foreach ($k in $baseByKey.Keys) {
        if (-not $curByKey.ContainsKey($k)) {
            $results += [pscustomobject]@{ Category=$Category; Change="MISSING"; Key=$k; Detail=($baseByKey[$k] | ConvertTo-Json -Compress) }
        }
    }
    foreach ($k in $curByKey.Keys) {
        if (-not $baseByKey.ContainsKey($k)) {
            $results += [pscustomobject]@{ Category=$Category; Change="NEW";     Key=$k; Detail=($curByKey[$k] | ConvertTo-Json -Compress) }
        }
        else {
            $baseJson = ConvertTo-CanonicalJson -Object $baseByKey[$k]
            $curJson  = ConvertTo-CanonicalJson -Object $curByKey[$k]
            if ($baseJson -ne $curJson) {
                $results += [pscustomobject]@{ Category=$Category; Change="CHANGED"; Key=$k; Detail="was=$baseJson  now=$curJson" }
            }
        }
    }
    return $results
}

function Compare-HardwareBaseline {
    [CmdletBinding()]
    param()

    Write-MenuHeader "Hardware Baseline Comparison"

    $path = Get-HardwareBaselinePath
    if (-not (Test-Path $path)) {
        Write-Step "No baseline found at $path" -Type Warning
        Write-Step "Run 'Set / Update Baseline' first to capture the original hardware state." -Type Info
        return
    }

    $raw = Get-Content $path -Raw
    $baseline = $raw | ConvertFrom-Json
    Write-Host "  Baseline created at: $($baseline.CreatedAt) by $($baseline.CreatedBy)" -ForegroundColor DarkCyan
    Write-Host "  Baseline hostname:   $($baseline.Hostname)" -ForegroundColor DarkCyan

    # Verify baseline integrity
    $idCanonical = ConvertTo-CanonicalJson -Object $baseline.Identity
    $idHash = Get-StringSha256 -Text $idCanonical
    if ($baseline.IdentityHash -and ($idHash -ne $baseline.IdentityHash)) {
        Write-Host ""
        Write-Step "BASELINE INTEGRITY FAILURE - file was modified outside this tool." -Type Error
        Write-Host "    Stored hash:   $($baseline.IdentityHash)" -ForegroundColor Red
        Write-Host "    Computed hash: $idHash" -ForegroundColor Red
        Write-Log "Baseline hash mismatch detected!" "ERROR"
    }
    else {
        Write-Host "  Baseline integrity:  " -NoNewline
        Write-Host "OK (hash verified)" -ForegroundColor Green
    }

    Write-Host ""
    Write-Step "Collecting current hardware snapshot..." -Type Info
    $current = Get-HardwareSnapshot
    $currentIdentity = Get-HardwareIdentity -Snap $current

    if ($baseline.Hostname -ne $env:COMPUTERNAME) {
        Write-Step "Hostname differs: baseline=$($baseline.Hostname), current=$($env:COMPUTERNAME)" -Type Warning
    }

    # Top-level (System/BIOS/BaseBoard)
    $diffs = @()

    foreach ($section in @("System", "BIOS", "BaseBoard")) {
        $bObj = $baseline.Identity.$section
        $cObj = $currentIdentity.$section
        $bJson = ConvertTo-CanonicalJson -Object $bObj
        $cJson = ConvertTo-CanonicalJson -Object $cObj
        if ($bJson -ne $cJson) {
            $diffs += [pscustomobject]@{ Category=$section; Change="CHANGED"; Key="(whole)"; Detail="was=$bJson  now=$cJson" }
        }
    }

    $diffs += Compare-IdentityList -Baseline $baseline.Identity.CPU      -Current $currentIdentity.CPU      -KeyField "ProcessorId"  -Category "CPU"
    $diffs += Compare-IdentityList -Baseline $baseline.Identity.Memory   -Current $currentIdentity.Memory   -KeyField "SerialNumber" -Category "Memory"
    $diffs += Compare-IdentityList -Baseline $baseline.Identity.Disks    -Current $currentIdentity.Disks    -KeyField "SerialNumber" -Category "Disk"
    $diffs += Compare-IdentityList -Baseline $baseline.Identity.GPUs     -Current $currentIdentity.GPUs     -KeyField "PnPDeviceID"  -Category "GPU"
    $diffs += Compare-IdentityList -Baseline $baseline.Identity.NICs     -Current $currentIdentity.NICs     -KeyField "MAC"          -Category "Network"
    $diffs += Compare-IdentityList -Baseline $baseline.Identity.Monitors -Current $currentIdentity.Monitors -KeyField "SerialNumber" -Category "Monitor"

    Write-Host ""
    if ($diffs.Count -eq 0) {
        Write-Step "No hardware changes detected. Machine matches baseline." -Type Success
        Write-Log "Hardware comparison: no changes."
    }
    else {
        Write-Host "  $($diffs.Count) change(s) detected:" -ForegroundColor Yellow
        Write-Host ("  " + "=" * 56) -ForegroundColor DarkGray
        foreach ($d in $diffs) {
            $color = switch ($d.Change) {
                "NEW"     { "Cyan" }
                "MISSING" { "Red" }
                "CHANGED" { "Yellow" }
                default   { "White" }
            }
            Write-Host "  [$($d.Change)]" -ForegroundColor $color -NoNewline
            Write-Host " $($d.Category): $($d.Key)" -ForegroundColor White
            Write-Host "          $($d.Detail)" -ForegroundColor DarkGray
        }
        Write-Log "Hardware comparison: $($diffs.Count) changes detected." "WARN"
    }
    Write-Host ""
}

function Test-HardwareBaselineStatus {
    # Returns one of: "OK", "TAMPER", "DRIFT", "NONE"
    # Full check - collects a live snapshot and diffs against baseline.
    try {
        $path = Get-HardwareBaselinePath
        if (-not (Test-Path $path)) { return "NONE" }
        $baseline = Get-Content $path -Raw | ConvertFrom-Json

        $idCanonical = ConvertTo-CanonicalJson -Object $baseline.Identity
        $idHash = Get-StringSha256 -Text $idCanonical
        if ($baseline.IdentityHash -and ($idHash -ne $baseline.IdentityHash)) { return "TAMPER" }

        $current = Get-HardwareSnapshot
        $currentIdentity = Get-HardwareIdentity -Snap $current
        $baseJson = ConvertTo-CanonicalJson -Object $baseline.Identity
        $curJson  = ConvertTo-CanonicalJson -Object $currentIdentity
        if ($baseJson -ne $curJson) { return "DRIFT" }
        return "OK"
    } catch {
        return "ERROR"
    }
}

function Test-HardwareBaselineQuickStatus {
    # Fast version (no snapshot) suitable for the main menu badge.
    # Only verifies the baseline file exists and its identity hash is intact.
    try {
        $path = Get-HardwareBaselinePath
        if (-not (Test-Path $path)) { return "NONE" }
        $baseline = Get-Content $path -Raw | ConvertFrom-Json
        if (-not $baseline.IdentityHash) { return "OK" }
        $idCanonical = ConvertTo-CanonicalJson -Object $baseline.Identity
        $idHash = Get-StringSha256 -Text $idCanonical
        if ($idHash -ne $baseline.IdentityHash) { return "TAMPER" }
        return "OK"
    } catch {
        return "ERROR"
    }
}

# ----------------------------------------------------------------------------
# Export
# ----------------------------------------------------------------------------

function Export-HardwareReport {
    [CmdletBinding()]
    param(
        [ValidateSet("JSON", "HTML", "CSV")]
        [string]$Format = "HTML"
    )

    $dir = Get-HardwareReportDir
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Write-Step "Collecting hardware snapshot..." -Type Info
    $snap = Get-HardwareSnapshot

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $file  = Join-Path $dir "hardware_${env:COMPUTERNAME}_$stamp.$($Format.ToLower())"

    switch ($Format) {
        "JSON" {
            $snap | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
        }
        "CSV" {
            # CSV: flatten one row per component category
            $rows = @()
            foreach ($cpu in $snap.CPU) { $rows += [pscustomobject]@{ Category="CPU"; Name=$cpu.Name; Id=$cpu.ProcessorId; Detail="Cores=$($cpu.Cores) Threads=$($cpu.Threads) Max=$($cpu.MaxClockMHz)MHz" } }
            foreach ($m in $snap.Memory) { $rows += [pscustomobject]@{ Category="Memory"; Name="$($m.Manufacturer) $($m.PartNumber)"; Id=$m.SerialNumber; Detail="Slot=$($m.DeviceLocator) Cap=$($m.Capacity) Speed=$($m.SpeedMHz)" } }
            foreach ($d in $snap.Disks) { $rows += [pscustomobject]@{ Category="Disk"; Name=$d.Model; Id=$d.SerialNumber; Detail="Size=$($d.Size) Health=$($d.HealthStatus) Bus=$($d.BusType) Media=$($d.MediaType)" } }
            foreach ($g in $snap.GPUs) { $rows += [pscustomobject]@{ Category="GPU"; Name=$g.Name; Id=$g.PnPDeviceID; Detail="Driver=$($g.DriverVersion)" } }
            foreach ($n in $snap.NetworkAdapters) { $rows += [pscustomobject]@{ Category="Network"; Name=$n.InterfaceDescription; Id=$n.MacAddress; Detail="Link=$($n.LinkSpeed) Status=$($n.Status)" } }
            foreach ($mon in $snap.Monitors) { $rows += [pscustomobject]@{ Category="Monitor"; Name="$($mon.Manufacturer) $($mon.ProductCode)"; Id=$mon.SerialNumber; Detail="Year=$($mon.ManufactureYear)" } }
            $rows | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
        }
        "HTML" {
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine("<!doctype html><html><head><meta charset='utf-8'>")
            [void]$sb.AppendLine("<title>Hardware Report - $($snap.Hostname)</title>")
            [void]$sb.AppendLine("<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222} h1{color:#0a4a78} h2{border-bottom:2px solid #0a4a78;color:#0a4a78;margin-top:32px} table{border-collapse:collapse;margin:8px 0;width:100%} th,td{border:1px solid #ccc;padding:6px 10px;text-align:left;font-size:13px} th{background:#0a4a78;color:#fff} tr:nth-child(even){background:#f5f7fa} .bad{color:#c00;font-weight:bold} .warn{color:#b86b00;font-weight:bold} .ok{color:#1c7a1c}</style>")
            [void]$sb.AppendLine("</head><body>")
            [void]$sb.AppendLine("<h1>Hardware Inventory Report</h1>")
            [void]$sb.AppendLine("<p>Host: <b>$($snap.Hostname)</b> &nbsp; Collected: $($snap.CollectedAt)</p>")

            function Add-HtmlSection {
                param($Sb, $Title, $Items)
                if (-not $Items -or @($Items).Count -eq 0) { return }
                [void]$Sb.AppendLine("<h2>$Title</h2>")
                $first = @($Items)[0]
                $keys = if ($first -is [System.Collections.IDictionary]) { @($first.Keys) } else { @($first.PSObject.Properties.Name) }
                [void]$Sb.Append("<table><tr>")
                foreach ($k in $keys) { [void]$Sb.Append("<th>$k</th>") }
                [void]$Sb.AppendLine("</tr>")
                foreach ($it in @($Items)) {
                    [void]$Sb.Append("<tr>")
                    foreach ($k in $keys) {
                        $v = if ($it -is [System.Collections.IDictionary]) { $it[$k] } else { $it.$k }
                        [void]$Sb.Append("<td>$([System.Net.WebUtility]::HtmlEncode([string]$v))</td>")
                    }
                    [void]$Sb.AppendLine("</tr>")
                }
                [void]$Sb.AppendLine("</table>")
            }

            Add-HtmlSection -Sb $sb -Title "System"       -Items @($snap.System)
            Add-HtmlSection -Sb $sb -Title "Operating System" -Items @($snap.OS)
            Add-HtmlSection -Sb $sb -Title "BIOS"         -Items @($snap.BIOS)
            Add-HtmlSection -Sb $sb -Title "Motherboard"  -Items @($snap.BaseBoard)
            Add-HtmlSection -Sb $sb -Title "CPU"          -Items $snap.CPU
            Add-HtmlSection -Sb $sb -Title "Memory"       -Items $snap.Memory
            Add-HtmlSection -Sb $sb -Title "Disks"        -Items $snap.Disks
            Add-HtmlSection -Sb $sb -Title "GPUs"         -Items $snap.GPUs
            Add-HtmlSection -Sb $sb -Title "Network Adapters" -Items $snap.NetworkAdapters
            Add-HtmlSection -Sb $sb -Title "Monitors"     -Items $snap.Monitors
            if ($snap.Battery) { Add-HtmlSection -Sb $sb -Title "Battery" -Items @($snap.Battery) }
            if ($snap.TPM)     { Add-HtmlSection -Sb $sb -Title "TPM"     -Items @($snap.TPM) }
            if ($snap.SecureBoot) { Add-HtmlSection -Sb $sb -Title "Secure Boot" -Items @($snap.SecureBoot) }
            if ($snap.ProblemDevices.Count -gt 0) { Add-HtmlSection -Sb $sb -Title "Problem Devices" -Items $snap.ProblemDevices }
            [void]$sb.AppendLine("</body></html>")
            [System.IO.File]::WriteAllText($file, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
        }
    }

    Write-Step "Report saved." -Type Success
    Write-Host "    Path: $file" -ForegroundColor DarkCyan
    Write-Log "Hardware report exported to $file"
    return $file
}

# ----------------------------------------------------------------------------
# Event log viewer
# ----------------------------------------------------------------------------

function Show-HardwareEventErrors {
    Write-MenuHeader "Hardware Event Log Errors (last 7 days)"
    $since = (Get-Date).AddDays(-7)

    $providers = @(
        @{ Name = "WHEA (CPU/Memory/PCIe)"; Filter = @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$since } }
        @{ Name = "Disk";                   Filter = @{ LogName='System'; ProviderName='disk'; Level=1,2,3; StartTime=$since } }
        @{ Name = "Display";                Filter = @{ LogName='System'; ProviderName='Display'; Level=1,2,3; StartTime=$since } }
        @{ Name = "Kernel Power";           Filter = @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Level=1,2,3; StartTime=$since } }
        @{ Name = "Memory Diagnostic";      Filter = @{ LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results' } }
    )

    foreach ($p in $providers) {
        Write-Host ""
        Write-Host "  $($p.Name)" -ForegroundColor White
        Write-Separator
        try {
            $events = Get-WinEvent -FilterHashtable $p.Filter -MaxEvents 10 -ErrorAction Stop
            if (-not $events -or $events.Count -eq 0) {
                Write-Host "    No events." -ForegroundColor Green
            }
            else {
                foreach ($e in $events) {
                    $lvl = switch ($e.LevelDisplayName) {
                        "Critical" { "Red" }
                        "Error"    { "Red" }
                        "Warning"  { "Yellow" }
                        default    { "DarkCyan" }
                    }
                    Write-Host ("    [{0:yyyy-MM-dd HH:mm}] [{1}] Id={2}" -f $e.TimeCreated, $e.LevelDisplayName, $e.Id) -ForegroundColor $lvl
                    if ($e.Message) {
                        $msg = $e.Message -split "`n" | Select-Object -First 1
                        Write-Host "      $msg" -ForegroundColor DarkGray
                    }
                }
            }
        } catch {
            Write-Host "    No events / provider not registered." -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

# ----------------------------------------------------------------------------
# Pure-data helpers used by the combined report
# ----------------------------------------------------------------------------

function Get-HardwareHealthData {
    # Returns an array of @{Component; Status; Severity; Detail}
    param($Snap)
    $th = Get-HardwareThresholds
    $results = @()

    foreach ($d in $Snap.Disks) {
        $sev = "OK"; $detail = "Healthy"
        if ($d.HealthStatus -and $d.HealthStatus -ne "Healthy" -and $d.HealthStatus -ne "Unknown") {
            $sev = "FAIL"; $detail = "Health: $($d.HealthStatus)"
        } elseif ($d.HealthStatus -eq "Unknown" -or -not $d.HealthStatus) {
            $sev = "INFO"; $detail = "Health: Unknown"
        }
        $results += @{ Component = "Disk: $($d.Model) (SN $($d.SerialNumber))"; Status = $d.HealthStatus; Severity = $sev; Detail = $detail }

        if ($d.Wear -ne $null -and $d.Wear -gt $th.SSDWearFailPercent) {
            $results += @{ Component = "Disk wear: $($d.Model)"; Status = "DEGRADED"; Severity = "FAIL"; Detail = "$($d.Wear)% (over $($th.SSDWearFailPercent)%) - replace soon" }
        }
        if ($d.Temperature -ne $null -and $d.Temperature -gt $th.DiskTempWarnCelsius) {
            $results += @{ Component = "Disk temp: $($d.Model)"; Status = "HOT"; Severity = "WARN"; Detail = "$($d.Temperature)C" }
        }
        if ($d.ReadErrorsTotal -and $d.ReadErrorsTotal -gt 0) {
            $results += @{ Component = "Disk read errors: $($d.Model)"; Status = "ERRORS"; Severity = "WARN"; Detail = "$($d.ReadErrorsTotal) read errors total" }
        }
    }

    if ($Snap.Battery -and $Snap.Battery.WearPercent -ne $null) {
        $sev = if ($Snap.Battery.WearPercent -gt $th.BatteryWearFailPercent) { "FAIL" } elseif ($Snap.Battery.WearPercent -gt $th.BatteryWearWarnPercent) { "WARN" } else { "OK" }
        $results += @{ Component = "Battery wear"; Status = "$($Snap.Battery.WearPercent)%"; Severity = $sev; Detail = "Design=$($Snap.Battery.DesignCapacitymWh)mWh Full=$($Snap.Battery.FullChargeCapacitymWh)mWh" }
    }

    if ($Snap.ProblemDevices.Count -eq 0) {
        $results += @{ Component = "PnP devices"; Status = "OK"; Severity = "OK"; Detail = "No problem devices" }
    } else {
        foreach ($p in $Snap.ProblemDevices) {
            $results += @{ Component = "PnP: $($p.FriendlyName)"; Status = $p.Status; Severity = "FAIL"; Detail = "Class=$($p.Class) Code=$($p.ProblemCode)" }
        }
    }

    $since = (Get-Date).AddDays(-$th.EventLookbackDays)
    $window = "$($th.EventLookbackDays)d"
    try {
        $whea = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$since } -ErrorAction SilentlyContinue
        $n = @($whea).Count
        $sev = if ($n -gt 0) { "FAIL" } else { "OK" }
        $results += @{ Component = "WHEA events ($window)"; Status = "$n"; Severity = $sev; Detail = if ($n -gt 0) { "Possible CPU/RAM/PCIe fault" } else { "No hardware errors" } }
    } catch {}

    try {
        $diskErr = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='disk'; Level=1,2,3; StartTime=$since } -ErrorAction SilentlyContinue
        $n = @($diskErr).Count
        $sev = if ($n -gt 0) { "WARN" } else { "OK" }
        $results += @{ Component = "Disk I/O errors ($window)"; Status = "$n"; Severity = $sev; Detail = if ($n -gt 0) { "Check disk subsystem" } else { "No disk I/O errors" } }
    } catch {}

    try {
        $mem = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($mem) {
            $sev = if ($mem.Id -eq 1201) { "OK" } else { "FAIL" }
            $detail = if ($mem.Id -eq 1201) { "Last run: no errors" } else { "Last run: errors (event $($mem.Id))" }
            $results += @{ Component = "Memory diagnostic"; Status = "Id=$($mem.Id)"; Severity = $sev; Detail = $detail }
        }
    } catch {}

    try {
        $bad = Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.HealthStatus -and $_.HealthStatus -ne 'Healthy' }
        if (-not $bad -or $bad.Count -eq 0) {
            $results += @{ Component = "Volume health"; Status = "OK"; Severity = "OK"; Detail = "All volumes healthy" }
        } else {
            foreach ($v in $bad) {
                $results += @{ Component = "Volume $($v.DriveLetter):"; Status = $v.HealthStatus; Severity = "FAIL"; Detail = "Unhealthy volume" }
            }
        }
    } catch {}

    return $results
}

function Get-HardwareBaselineDiff {
    # Returns a hashtable describing baseline status + diffs (no console output).
    param($CurrentSnap)

    $path = Get-HardwareBaselinePath
    $result = @{
        State        = "NONE"     # NONE | OK | DRIFT | TAMPER | ERROR
        BaselinePath = $path
        CreatedAt    = $null
        CreatedBy    = $null
        Hostname     = $null
        Diffs        = @()
    }

    if (-not (Test-Path $path)) { return $result }
    try {
        $baseline = Get-Content $path -Raw | ConvertFrom-Json
        $result.CreatedAt = $baseline.CreatedAt
        $result.CreatedBy = $baseline.CreatedBy
        $result.Hostname  = $baseline.Hostname

        $idCanonical = ConvertTo-CanonicalJson -Object $baseline.Identity
        $idHash = Get-StringSha256 -Text $idCanonical
        if ($baseline.IdentityHash -and ($idHash -ne $baseline.IdentityHash)) {
            $result.State = "TAMPER"
            return $result
        }

        $currentIdentity = Get-HardwareIdentity -Snap $CurrentSnap
        $diffs = @()

        foreach ($section in @("System", "BIOS", "BaseBoard")) {
            $bJson = ConvertTo-CanonicalJson -Object $baseline.Identity.$section
            $cJson = ConvertTo-CanonicalJson -Object $currentIdentity.$section
            if ($bJson -ne $cJson) {
                $diffs += [pscustomobject]@{ Category=$section; Change="CHANGED"; Key="(whole)"; Detail="was=$bJson  now=$cJson" }
            }
        }
        $diffs += Compare-IdentityList -Baseline $baseline.Identity.CPU      -Current $currentIdentity.CPU      -KeyField "ProcessorId"  -Category "CPU"
        $diffs += Compare-IdentityList -Baseline $baseline.Identity.Memory   -Current $currentIdentity.Memory   -KeyField "SerialNumber" -Category "Memory"
        $diffs += Compare-IdentityList -Baseline $baseline.Identity.Disks    -Current $currentIdentity.Disks    -KeyField "SerialNumber" -Category "Disk"
        $diffs += Compare-IdentityList -Baseline $baseline.Identity.GPUs     -Current $currentIdentity.GPUs     -KeyField "PnPDeviceID"  -Category "GPU"
        $diffs += Compare-IdentityList -Baseline $baseline.Identity.NICs     -Current $currentIdentity.NICs     -KeyField "MAC"          -Category "Network"
        $diffs += Compare-IdentityList -Baseline $baseline.Identity.Monitors -Current $currentIdentity.Monitors -KeyField "SerialNumber" -Category "Monitor"

        $result.Diffs = $diffs
        $result.State = if ($diffs.Count -eq 0) { "OK" } else { "DRIFT" }
        return $result
    } catch {
        $result.State = "ERROR"
        $result.Error = "$_"
        return $result
    }
}

# ============================================================================
# Tier 1-4 extended inspection collectors
# Each function returns plain data (hashtables / arrays). Errors are swallowed
# so a missing capability never breaks the whole report.
# ============================================================================

function Get-WindowsActivationInfo {
    try {
        $licMap = @{ 0="Unlicensed"; 1="Licensed"; 2="OOB Grace"; 3="OOT Grace"; 4="Non-Genuine Grace"; 5="Notification"; 6="Extended Grace" }
        $prod = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop |
                Where-Object { $_.Name -like "Windows*" -and $_.PartialProductKey } |
                Select-Object -First 1
        if ($prod) {
            return @{
                Name        = $prod.Name
                Description = $prod.Description
                Channel     = $prod.ProductKeyChannel
                LicenseStatus = $licMap[[int]$prod.LicenseStatus]
                PartialKey  = $prod.PartialProductKey
                Genuine     = ([int]$prod.LicenseStatus -eq 1)
            }
        }
    } catch {}
    return @{ Name="Unknown"; LicenseStatus="Unknown"; Genuine=$false }
}

function Get-BitLockerInfo {
    $list = @()
    try {
        Get-BitLockerVolume -ErrorAction Stop | ForEach-Object {
            $list += @{
                MountPoint     = $_.MountPoint
                VolumeStatus   = "$($_.VolumeStatus)"
                ProtectionStatus = "$($_.ProtectionStatus)"
                EncryptionPercent = $_.EncryptionPercentage
                KeyProtectorTypes = (@($_.KeyProtector | ForEach-Object { $_.KeyProtectorType }) -join ", ")
            }
        }
    } catch {}
    return $list
}

function Get-DefenderStatus {
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        return @{
            AntivirusEnabled        = [bool]$st.AntivirusEnabled
            RealTimeProtection      = [bool]$st.RealTimeProtectionEnabled
            TamperProtection        = [bool]$st.IsTamperProtected
            DefinitionLastUpdate    = if ($st.AntivirusSignatureLastUpdated) { $st.AntivirusSignatureLastUpdated.ToString("o") } else { "" }
            DefinitionAge           = if ($st.AntivirusSignatureLastUpdated) { [int]((Get-Date) - $st.AntivirusSignatureLastUpdated).TotalDays } else { -1 }
            BehaviorMonitor         = [bool]$st.BehaviorMonitorEnabled
            ProductVersion          = $st.AMProductVersion
        }
    } catch {
        return @{ AntivirusEnabled = $false; Note = "Defender not available or third-party AV present" }
    }
}

function Get-AutoLoginStatus {
    try {
        $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
        return @{
            Enabled         = ($wl.AutoAdminLogon -eq "1")
            DefaultUser     = $wl.DefaultUserName
            DefaultDomain   = $wl.DefaultDomainName
            PasswordStored  = -not [string]::IsNullOrEmpty($wl.DefaultPassword)
        }
    } catch { return @{ Enabled=$false } }
}

function Get-DomainJoinInfo {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        return @{
            PartOfDomain = [bool]$cs.PartOfDomain
            Domain       = $cs.Domain
            Workgroup    = $cs.Workgroup
            DomainRole   = switch ([int]$cs.DomainRole) { 0{"Standalone Workstation"}; 1{"Member Workstation"}; 2{"Standalone Server"}; 3{"Member Server"}; 4{"Backup DC"}; 5{"Primary DC"}; default{"$($cs.DomainRole)"} }
        }
    } catch { return @{ PartOfDomain=$false } }
}

function Get-LocalAccountsInfo {
    $builtIn = @("Administrator","DefaultAccount","Guest","WDAGUtilityAccount")
    $accounts = @()
    try {
        Get-LocalUser -ErrorAction Stop | ForEach-Object {
            $accounts += @{
                Name            = $_.Name
                Enabled         = [bool]$_.Enabled
                IsBuiltIn       = ($_.Name -in $builtIn)
                LastLogon       = if ($_.LastLogon) { $_.LastLogon.ToString("o") } else { "" }
                PasswordRequired = [bool]$_.PasswordRequired
                PasswordExpires  = if ($_.PasswordExpires) { $_.PasswordExpires.ToString("o") } else { "" }
            }
        }
    } catch {}
    return $accounts
}

function Get-AllPnpDevices {
    $byClass = @{}
    try {
        Get-PnpDevice -PresentOnly -ErrorAction Stop | ForEach-Object {
            $cls = if ($_.Class) { $_.Class } else { "(no class)" }
            if (-not $byClass.ContainsKey($cls)) { $byClass[$cls] = @() }
            $byClass[$cls] += @{
                FriendlyName = $_.FriendlyName
                Manufacturer = $_.Manufacturer
                Status       = "$($_.Status)"
                ProblemCode  = [int]$_.ProblemCode
                InstanceId   = $_.InstanceId
            }
        }
    } catch {}
    return $byClass
}

function Get-USBControllerInfo {
    $controllers = @()
    try {
        Get-CimInstance Win32_USBController -ErrorAction Stop | ForEach-Object {
            $ver = "USB"
            if ($_.Name -match "3\.2|3\.1|3\.0") { $ver = "USB 3.x" }
            elseif ($_.Name -match "USB4|Thunderbolt") { $ver = "USB4 / TB" }
            elseif ($_.Name -match "Enhanced|2\.0") { $ver = "USB 2.0" }
            elseif ($_.Name -match "Open|Universal Host") { $ver = "USB 1.1" }
            $controllers += @{
                Name        = $_.Name
                Manufacturer = $_.Manufacturer
                Status      = $_.Status
                Version     = $ver
            }
        }
    } catch {}
    return $controllers
}

function Get-GPUDriverCrashCount {
    $th = Get-HardwareThresholds
    try {
        $crashes = Get-WinEvent -FilterHashtable @{
            LogName='System'; Id=4101; ProviderName='Display'; StartTime=(Get-Date).AddDays(-$th.GPUDriverCrashLookbackDays)
        } -ErrorAction SilentlyContinue
        return @{
            Count        = @($crashes).Count
            LookbackDays = $th.GPUDriverCrashLookbackDays
        }
    } catch { return @{ Count=0; LookbackDays=$th.GPUDriverCrashLookbackDays } }
}

function Get-VolumeInfo {
    $vols = @()
    try {
        Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter } | ForEach-Object {
            $size = [int64]$_.Size
            $free = [int64]$_.SizeRemaining
            $freePct = if ($size -gt 0) { [math]::Round(($free / $size) * 100, 1) } else { 0 }
            $dirty = $null
            try {
                $out = & fsutil dirty query "$($_.DriveLetter):" 2>$null
                $dirty = ($out -match "is Dirty" -and $out -notmatch "is NOT Dirty")
            } catch {}
            $vols += @{
                DriveLetter   = "$($_.DriveLetter):"
                FileSystem    = $_.FileSystem
                Label         = $_.FileSystemLabel
                SizeBytes     = $size
                FreeBytes     = $free
                FreePercent   = $freePct
                HealthStatus  = "$($_.HealthStatus)"
                DirtyBit      = [bool]$dirty
            }
        }
    } catch {}
    return $vols
}

function Get-USBDeviceHistory {
    $th = Get-HardwareThresholds
    $list = @()
    try {
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR' -ErrorAction Stop |
            ForEach-Object {
                $modelKey = $_
                Get-ChildItem $modelKey.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                    if ($props -and $props.FriendlyName) {
                        $list += @{
                            FriendlyName = $props.FriendlyName
                            Mfg          = $props.Mfg
                            Service      = $props.Service
                            ModelKey     = $modelKey.PSChildName
                        }
                    }
                }
            }
    } catch {}
    if ($list.Count -gt $th.USBHistoryShowLast) {
        return @($list | Select-Object -First $th.USBHistoryShowLast) + @(@{ FriendlyName = "... and $($list.Count - $th.USBHistoryShowLast) more"; Mfg=""; Service=""; ModelKey="" })
    }
    return $list
}

function Get-NetworkCapability {
    $info = @{ Wifi = $null; Bluetooth = $null; Ethernet = @() }
    # WiFi via netsh
    try {
        $raw = & netsh wlan show drivers 2>$null
        if ($raw) {
            $text = $raw -join "`n"
            $standards = @()
            foreach ($s in @("802.11be","802.11ax","802.11ac","802.11n","802.11a","802.11g","802.11b")) {
                if ($text -match [regex]::Escape($s)) { $standards += $s }
            }
            $gen = if ($standards -contains "802.11be") { "Wi-Fi 7" }
                   elseif ($standards -contains "802.11ax") { "Wi-Fi 6/6E" }
                   elseif ($standards -contains "802.11ac") { "Wi-Fi 5" }
                   elseif ($standards -contains "802.11n") { "Wi-Fi 4" }
                   else { "Legacy" }
            $info.Wifi = @{ Generation = $gen; Standards = ($standards -join ", ") }
        }
    } catch {}
    # Bluetooth
    try {
        $bt = Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "OK" } | Select-Object -First 1
        if ($bt) {
            $info.Bluetooth = @{ Name = $bt.FriendlyName; Status = "$($bt.Status)" }
        }
    } catch {}
    # Ethernet link speeds
    try {
        Get-NetAdapter -ErrorAction Stop |
            Where-Object { -not $_.Virtual -and $_.MediaType -eq "802.3" } |
            ForEach-Object { $info.Ethernet += @{ Name=$_.Name; LinkSpeed=$_.LinkSpeed; Status="$($_.Status)" } }
    } catch {}
    return $info
}

function Get-RAMDetail {
    param($Snap)
    $r = @{}
    try {
        $arr = Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction Stop | Select-Object -First 1
        $r.TotalSlots = [int]$arr.MemoryDevices
        $r.MaxCapacityBytes = [int64]$arr.MaxCapacity * 1KB
    } catch {}
    $r.UsedSlots = $Snap.Memory.Count
    $r.EmptySlots = if ($r.TotalSlots) { $r.TotalSlots - $r.UsedSlots } else { $null }
    $speeds = @($Snap.Memory | ForEach-Object { [int]$_.SpeedMHz } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    $r.SpeedsMHz = $speeds
    $r.SpeedMismatch = ($speeds.Count -gt 1)
    return $r
}

function Get-SystemUptimeInfo {
    $r = @{}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $r.LastBoot = $os.LastBootUpTime.ToString("o")
        $r.UptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
        $r.InstallDate = $os.InstallDate.ToString("o")
        $r.InstallAgeDays = [int]((Get-Date) - $os.InstallDate).TotalDays
    } catch {}
    return $r
}

function Get-RecentSoftwareChanges {
    $th = Get-HardwareThresholds
    $since = (Get-Date).AddDays(-$th.RecentInstallLookbackDays)
    $changes = @()
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='MsiInstaller'; Id=1033,1034,1036; StartTime=$since } -ErrorAction SilentlyContinue
        foreach ($e in $events) {
            $action = switch ($e.Id) { 1033 {"Installed"} 1034 {"Removed"} 1036 {"Repaired"} default {"$($e.Id)"} }
            $product = if ($e.Properties.Count -gt 0) { $e.Properties[0].Value } else { "(unknown)" }
            $changes += @{ Time=$e.TimeCreated.ToString("yyyy-MM-dd HH:mm"); Action=$action; Product=$product }
        }
    } catch {}
    return $changes
}

function Get-PowerConfigInfo {
    $r = @{}
    try {
        $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
        if ($pf) {
            $r.PageFile = @{ Path = $pf.Name; AllocatedMB = [int]$pf.AllocatedBaseSize; CurrentMB = [int]$pf.CurrentUsage }
        }
    } catch {}
    try {
        $hib = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop
        $r.HibernateEnabled = ($hib.HibernateEnabled -eq 1)
    } catch {}
    return $r
}

# ----------------------------------------------------------------------------
# Tier 3 - Mini benchmarks
# ----------------------------------------------------------------------------

function Invoke-DiskBenchmark {
    $th = Get-HardwareThresholds
    $sizeMB = [int]$th.BenchmarkDiskSizeMB
    $file = Join-Path $env:TEMP "wgk_bench_$(Get-Random).bin"
    try {
        $size = $sizeMB * 1MB
        $data = New-Object byte[] $size
        ([System.Random]::new()).NextBytes($data)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [System.IO.File]::WriteAllBytes($file, $data)
        $writeSec = $sw.Elapsed.TotalSeconds
        $sw.Restart()
        $null = [System.IO.File]::ReadAllBytes($file)
        $readSec = $sw.Elapsed.TotalSeconds
        return @{
            FileSizeMB  = $sizeMB
            WriteMBps   = if ($writeSec -gt 0) { [math]::Round($sizeMB / $writeSec, 1) } else { 0 }
            ReadMBps    = if ($readSec  -gt 0) { [math]::Round($sizeMB / $readSec,  1) } else { 0 }
            WriteSec    = [math]::Round($writeSec, 3)
            ReadSec     = [math]::Round($readSec,  3)
            TestedOn    = (Split-Path $file -Qualifier)
        }
    } catch {
        return @{ Error = "$_" }
    } finally {
        try { Remove-Item $file -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Invoke-CPUBenchmark {
    $th = Get-HardwareThresholds
    $iters = [int]$th.BenchmarkCPUIterations
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $data = New-Object byte[] (1MB)
        ([System.Random]::new()).NextBytes($data)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $iters; $i++) { $null = $sha.ComputeHash($data) }
        $sec = $sw.Elapsed.TotalSeconds
        $sha.Dispose()
        return @{
            Iterations = $iters
            DataSizeMB = 1
            ElapsedSec = [math]::Round($sec, 3)
            HashMBps   = if ($sec -gt 0) { [math]::Round($iters / $sec, 1) } else { 0 }
        }
    } catch { return @{ Error = "$_" } }
}

function Invoke-MemoryBenchmark {
    $th = Get-HardwareThresholds
    $sizeMB = [int]$th.BenchmarkMemorySizeMB
    $iters  = [int]$th.BenchmarkMemoryIterations
    try {
        $size = $sizeMB * 1MB
        $src = New-Object byte[] $size
        $dst = New-Object byte[] $size
        ([System.Random]::new()).NextBytes($src)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $iters; $i++) {
            [System.Buffer]::BlockCopy($src, 0, $dst, 0, $size)
        }
        $sec = $sw.Elapsed.TotalSeconds
        $totalMB = $iters * $sizeMB
        return @{
            BlockSizeMB     = $sizeMB
            Iterations      = $iters
            TotalCopiedMB   = $totalMB
            ElapsedSec      = [math]::Round($sec, 3)
            BandwidthMBps   = if ($sec -gt 0) { [math]::Round($totalMB / $sec, 1) } else { 0 }
        }
    } catch { return @{ Error = "$_" } }
}

function Get-WinSATCachedScores {
    try {
        $w = Get-CimInstance Win32_WinSAT -ErrorAction Stop
        if ($w -and $w.WinSPRLevel -gt 0) {
            return @{
                BaseScore     = $w.WinSPRLevel
                CPUScore      = $w.CPUScore
                MemoryScore   = $w.MemoryScore
                DiskScore     = $w.DiskScore
                GraphicsScore = $w.GraphicsScore
                D3DScore      = $w.D3DScore
                AssessedOn    = if ($w.TimeTaken) { "$($w.TimeTaken)" } else { "" }
                State         = "$($w.WinSATAssessmentState)"
            }
        }
    } catch {}
    return $null
}

# ----------------------------------------------------------------------------
# Tier 4 - Advanced / best-effort
# ----------------------------------------------------------------------------

function Get-ThermalZoneTemperatures {
    $temps = @()
    try {
        $zones = Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        foreach ($z in $zones) {
            $kelvin = $z.CurrentTemperature / 10.0
            $celsius = [math]::Round($kelvin - 273.15, 1)
            $temps += @{ Zone = $z.InstanceName; TempC = $celsius }
        }
    } catch {}
    return $temps
}

function Get-UnsignedDriversInfo {
    $unsigned = @()
    try {
        $out = & pnputil /enum-drivers 2>$null
        if ($out) {
            $block = @{}
            foreach ($line in $out) {
                $l = "$line".Trim()
                if ($l -match '^Published Name\s*:\s*(.+)$') { $block.PublishedName = $matches[1].Trim() }
                elseif ($l -match '^Original Name\s*:\s*(.+)$') { $block.OriginalName = $matches[1].Trim() }
                elseif ($l -match '^Provider Name\s*:\s*(.+)$') { $block.Provider = $matches[1].Trim() }
                elseif ($l -match '^Class Name\s*:\s*(.+)$') { $block.Class = $matches[1].Trim() }
                elseif ($l -match '^Driver Version\s*:\s*(.+)$') { $block.Version = $matches[1].Trim() }
                elseif ($l -match '^Signer Name\s*:\s*(.+)$') {
                    $block.Signer = $matches[1].Trim()
                    if ($block.Signer -match '^(N/A|None)$' -or -not $block.Signer) {
                        $unsigned += @{ Driver = $block.OriginalName; Provider = $block.Provider; Class = $block.Class; Signer = $block.Signer }
                    }
                    $block = @{}
                }
            }
        }
    } catch {}
    return $unsigned
}

function Get-BloatwareSuspects {
    # Look for typical consumer pre-installed apps that buyers don't want left over
    $patterns = @(
        "CandyCrush", "BubbleWitch", "March of Empires", "Spotify", "Disney",
        "FarmVille", "Twitter", "Facebook", "TikTok", "Netflix",
        "King\.com", "Asphalt", "PandoraMediaInc"
    )
    $found = @()
    try {
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($p in $patterns) {
                if ($_.Name -match $p) {
                    $found += @{ Name = $_.Name; Publisher = $_.Publisher; Source = "AppX" }
                    break
                }
            }
        }
    } catch {}
    return $found
}

function Get-ManualTestLaunchers {
    return @(
        @{ Test = "Keyboard test (every key)"; Url = "https://keyboardtester.com" }
        @{ Test = "Dead pixel test (screen)"; Url = "https://www.deadpixeltest.org" }
        @{ Test = "Monitor full test (color, contrast)"; Url = "https://www.eizo.be/monitor-test/" }
        @{ Test = "Microphone test"; Url = "https://onlinemictest.com" }
        @{ Test = "Webcam test"; Url = "https://webcamtests.com" }
        @{ Test = "Speaker / headphone L+R test"; Url = "https://onlinetonegenerator.com" }
        @{ Test = "Touchscreen multi-touch test"; Url = "https://touchtest.org" }
    )
}

# ----------------------------------------------------------------------------
# Aggregator + extended buyer flags
# ----------------------------------------------------------------------------

function Get-InspectionChecklist {
    # Builds an ordered TODO-style list of inspection items, each with:
    #   Name, Status (PASS|WARN|FAIL|INFO|SKIP), Detail
    # The Detail is shown when the user expands a non-PASS row.
    param($Snap, $Extended, $Health, $Events, $Diff, $Buyer)

    $th    = Get-HardwareThresholds
    $items = @()

    $addItem = {
        param([string]$Name, [string]$Status, [string]$Detail = "")
        $script:_clItems += @{ Name=$Name; Status=$Status; Detail=$Detail }
    }
    $script:_clItems = @()

    # ---- License / Activation ----
    if ($Extended.Activation.Genuine) {
        & $addItem "Windows activation"  "PASS" "Licensed: $($Extended.Activation.Name) (channel $($Extended.Activation.Channel))"
    } else {
        & $addItem "Windows activation"  "FAIL" "License status: $($Extended.Activation.LicenseStatus). Channel: $($Extended.Activation.Channel). Verify the key is legitimate or expect activation prompts."
    }

    # ---- Defender ----
    if ($Extended.Defender.AntivirusEnabled) {
        $note = "RealTime=$($Extended.Defender.RealTimeProtection), DefAge=$($Extended.Defender.DefinitionAge)d"
        if ($Extended.Defender.DefinitionAge -gt 14) {
            & $addItem "Microsoft Defender" "WARN" "$note - AV signatures are stale (>14 days). Connect to internet and update."
        } else {
            & $addItem "Microsoft Defender" "PASS" $note
        }
    } else {
        & $addItem "Microsoft Defender" "WARN" "Defender disabled. Could be replaced by 3rd-party AV - verify some AV is running."
    }

    # ---- Auto-login ----
    if ($Extended.AutoLogin.Enabled) {
        $detail = "User: $($Extended.AutoLogin.DefaultUser)"
        if ($Extended.AutoLogin.PasswordStored) { $detail += " | Password stored in plain text in registry." }
        & $addItem "Auto-login" "WARN" $detail
    } else {
        & $addItem "Auto-login" "PASS" "Auto-login disabled."
    }

    # ---- Domain join ----
    if ($Extended.DomainJoin.PartOfDomain) {
        & $addItem "Domain membership" "WARN" "Joined to '$($Extended.DomainJoin.Domain)' ($($Extended.DomainJoin.DomainRole)). May have lingering GPOs - leave and rejoin a workgroup."
    } else {
        & $addItem "Domain membership" "PASS" "Workgroup: $($Extended.DomainJoin.Workgroup)"
    }

    # ---- Local accounts ----
    $extra = @($Extended.LocalAccounts | Where-Object { -not $_.IsBuiltIn -and $_.Enabled })
    if ($extra.Count -eq 0) {
        & $addItem "Local user accounts" "PASS" "No non-builtin accounts remaining."
    } else {
        $names = ($extra | ForEach-Object { $_.Name }) -join ", "
        & $addItem "Local user accounts" "WARN" "$($extra.Count) leftover account(s) from previous owner: $names. Disable or remove."
    }

    # ---- BitLocker ----
    $encrypted = @($Extended.BitLocker | Where-Object { $_.ProtectionStatus -eq "On" -or $_.VolumeStatus -match "Encrypted" })
    if ($encrypted.Count -gt 0) {
        $drives = ($encrypted | ForEach-Object { $_.MountPoint }) -join ", "
        & $addItem "BitLocker encryption" "WARN" "Encrypted drive(s): $drives. If you don't have the recovery key from the seller, you can be locked out after hardware changes."
    } else {
        & $addItem "BitLocker encryption" "PASS" "No drives are BitLocker-protected."
    }

    # ---- Disks: SMART / Wear / Hours ----
    foreach ($d in $Snap.Disks) {
        $name = "Disk: $($d.Model)"
        $bad = @()
        $isFail = $false; $isWarn = $false
        if ($d.HealthStatus -and $d.HealthStatus -ne "Healthy" -and $d.HealthStatus -ne "Unknown") {
            $bad += "SMART: $($d.HealthStatus)"; $isFail = $true
        }
        if ($d.Wear -ne $null -and $d.Wear -gt $th.SSDWearFailPercent)  { $bad += "Wear $($d.Wear)% (over $($th.SSDWearFailPercent)%)"; $isFail = $true }
        elseif ($d.Wear -ne $null -and $d.Wear -gt $th.SSDWearWarnPercent) { $bad += "Wear $($d.Wear)%"; $isWarn = $true }
        if ($d.PowerOnHours -ne $null -and $d.PowerOnHours -gt $th.DiskPowerOnHoursFail) { $bad += "$($d.PowerOnHours) power-on hours (heavy use)"; $isFail = $true }
        elseif ($d.PowerOnHours -ne $null -and $d.PowerOnHours -gt $th.DiskPowerOnHoursWarn) { $bad += "$($d.PowerOnHours) power-on hours"; $isWarn = $true }
        if ($d.Temperature -ne $null -and $d.Temperature -gt $th.DiskTempWarnCelsius) { $bad += "Temp $($d.Temperature)C"; $isWarn = $true }
        if ($d.ReadErrorsTotal -and $d.ReadErrorsTotal -gt 0)  { $bad += "$($d.ReadErrorsTotal) read errors"; $isWarn = $true }
        if ($d.WriteErrorsTotal -and $d.WriteErrorsTotal -gt 0){ $bad += "$($d.WriteErrorsTotal) write errors"; $isFail = $true }

        $status = if ($isFail) { "FAIL" } elseif ($isWarn) { "WARN" } else { "PASS" }
        $detail = if ($bad.Count -gt 0) { ($bad -join "; ") } else { "Healthy. Size=$(Format-Bytes $d.Size), SN=$($d.SerialNumber)" }
        & $addItem $name $status $detail
    }

    # ---- Volume free + dirty ----
    foreach ($v in $Extended.Volumes) {
        $bad = @()
        $isFail = $false; $isWarn = $false
        if ($v.DirtyBit) { $bad += "Filesystem dirty bit set (chkdsk needed)"; $isFail = $true }
        if ($v.FreePercent -lt $th.DiskFreeSpaceFailPercent) { $bad += "Only $($v.FreePercent)% free ($(Format-Bytes $v.FreeBytes))"; $isFail = $true }
        elseif ($v.FreePercent -lt $th.DiskFreeSpaceWarnPercent) { $bad += "Low free space: $($v.FreePercent)%"; $isWarn = $true }
        if ($v.HealthStatus -ne "Healthy" -and $v.HealthStatus) { $bad += "Volume health: $($v.HealthStatus)"; $isFail = $true }
        $status = if ($isFail) { "FAIL" } elseif ($isWarn) { "WARN" } else { "PASS" }
        $detail = if ($bad.Count -gt 0) { ($bad -join "; ") } else { "$($v.FreePercent)% free of $(Format-Bytes $v.SizeBytes)" }
        & $addItem "Volume $($v.DriveLetter)" $status $detail
    }

    # ---- Battery ----
    if ($Snap.Battery -and $Snap.Battery.WearPercent -ne $null) {
        $bw = $Snap.Battery.WearPercent
        if ($bw -gt $th.BatteryWearFailPercent) {
            & $addItem "Battery wear" "FAIL" "$bw% wear. Design=$($Snap.Battery.DesignCapacitymWh)mWh -> Full=$($Snap.Battery.FullChargeCapacitymWh)mWh. Replacement recommended."
        } elseif ($bw -gt $th.BatteryWearWarnPercent) {
            & $addItem "Battery wear" "WARN" "$bw% wear. Some capacity lost but serviceable."
        } else {
            & $addItem "Battery wear" "PASS" "$bw% wear - excellent."
        }
    }

    # ---- WHEA / BSOD / Shutdowns / GPU TDR ----
    foreach ($m in $Buyer.KeyMetrics) {
        if ($m.Label -like "WHEA*") {
            if ([int]$m.Value -gt 0) {
                & $addItem "WHEA hardware errors ($($th.WHEALookbackDays)d)" "FAIL" "$($m.Value) WHEA events - possible CPU/RAM/PCIe fault."
            } else {
                & $addItem "WHEA hardware errors ($($th.WHEALookbackDays)d)" "PASS" "No WHEA events."
            }
        }
    }
    # BSOD
    $bsodMetric = $Buyer.KeyMetrics | Where-Object { $_.Label -like "Bluescreens*" } | Select-Object -First 1
    if ($bsodMetric) {
        if ([int]$bsodMetric.Value -ge $th.BSODWarnCount) {
            & $addItem "BSODs ($($th.BSODLookbackDays)d)" "WARN" "$($bsodMetric.Value) BSOD(s). Investigate driver/hardware stability."
        } else {
            & $addItem "BSODs ($($th.BSODLookbackDays)d)" "PASS" "$($bsodMetric.Value) BSOD(s) - within tolerance."
        }
    } else {
        & $addItem "BSODs ($($th.BSODLookbackDays)d)" "PASS" "No BSOD events recorded."
    }
    # Unexpected shutdowns
    $usMetric = $Buyer.KeyMetrics | Where-Object { $_.Label -like "Unexpected shutdowns*" } | Select-Object -First 1
    if ($usMetric) {
        if ([int]$usMetric.Value -ge $th.UnexpectedShutdownWarnCount) {
            & $addItem "Unexpected shutdowns ($($th.UnexpectedShutdownLookbackDays)d)" "WARN" "$($usMetric.Value) unexpected shutdowns - possible PSU / overheating."
        } else {
            & $addItem "Unexpected shutdowns ($($th.UnexpectedShutdownLookbackDays)d)" "PASS" "$($usMetric.Value) within tolerance."
        }
    } else {
        & $addItem "Unexpected shutdowns ($($th.UnexpectedShutdownLookbackDays)d)" "PASS" "No unexpected shutdowns recorded."
    }
    # GPU TDR
    if ($Extended.GPUCrashes.Count -gt 0) {
        $sev = if ($Extended.GPUCrashes.Count -ge $th.GPUDriverCrashWarnCount) { "FAIL" } else { "WARN" }
        & $addItem "GPU driver crashes ($($Extended.GPUCrashes.LookbackDays)d)" $sev "$($Extended.GPUCrashes.Count) Display TDR events (id 4101)."
    } else {
        & $addItem "GPU driver crashes ($($Extended.GPUCrashes.LookbackDays)d)" "PASS" "No GPU driver recovery events."
    }

    # ---- PnP problem devices ----
    if ($Snap.ProblemDevices.Count -eq 0) {
        & $addItem "PnP problem devices" "PASS" "All present devices report status OK."
    } else {
        $names = ($Snap.ProblemDevices | ForEach-Object { "$($_.FriendlyName) [code $($_.ProblemCode)]" }) -join " | "
        & $addItem "PnP problem devices" "FAIL" "$($Snap.ProblemDevices.Count) device(s) with error: $names"
    }

    # ---- RAM mismatch / slots ----
    if ($Extended.RAMDetail.SpeedMismatch) {
        & $addItem "RAM speed consistency" "WARN" "DIMMs at mixed speeds: $($Extended.RAMDetail.SpeedsMHz -join ', ') MHz. Possible cheaper module swap."
    } else {
        $sp = if ($Extended.RAMDetail.SpeedsMHz) { ($Extended.RAMDetail.SpeedsMHz -join ', ') + ' MHz' } else { "uniform" }
        & $addItem "RAM speed consistency" "PASS" "All DIMMs at $sp."
    }

    # ---- USB controllers / Wi-Fi / Bluetooth (informational) ----
    if ($Extended.USBControllers.Count -gt 0) {
        $vers = (($Extended.USBControllers | ForEach-Object { $_.Version }) | Sort-Object -Unique) -join ", "
        & $addItem "USB controllers" "INFO" "$($Extended.USBControllers.Count) controller(s). Versions: $vers"
    }
    if ($Extended.Network.Wifi) {
        & $addItem "Wi-Fi capability" "INFO" "$($Extended.Network.Wifi.Generation) ($($Extended.Network.Wifi.Standards))"
    } else {
        & $addItem "Wi-Fi capability" "SKIP" "No WLAN driver / Wi-Fi adapter detected."
    }
    if ($Extended.Network.Bluetooth) {
        & $addItem "Bluetooth" "INFO" "$($Extended.Network.Bluetooth.Name) ($($Extended.Network.Bluetooth.Status))"
    } else {
        & $addItem "Bluetooth" "SKIP" "No Bluetooth adapter detected."
    }

    # ---- TPM / Secure Boot ----
    if ($Snap.TPM -and $Snap.TPM.TpmPresent) {
        & $addItem "TPM" "PASS" "TPM present (ready=$($Snap.TPM.TpmReady))."
    } else {
        & $addItem "TPM" "INFO" "No TPM detected. Windows 11 / BitLocker limited."
    }
    if ($Snap.SecureBoot -and $Snap.SecureBoot.Enabled) {
        & $addItem "Secure Boot" "PASS" "Enabled."
    } elseif ($Snap.SecureBoot -and $Snap.SecureBoot.Supported) {
        & $addItem "Secure Boot" "INFO" "Supported but disabled in firmware."
    } else {
        & $addItem "Secure Boot" "INFO" "Not supported (legacy BIOS / not UEFI)."
    }

    # ---- Unsigned drivers / Bloatware ----
    if (@($Extended.UnsignedDrivers).Count -gt 0) {
        & $addItem "Driver signing" "WARN" "$(@($Extended.UnsignedDrivers).Count) unsigned driver(s) installed - review list in detail section."
    } else {
        & $addItem "Driver signing" "PASS" "All drivers are signed."
    }
    if (@($Extended.Bloatware).Count -gt 0) {
        $names = (@($Extended.Bloatware) | ForEach-Object { $_.Name }) -join ", "
        & $addItem "Pre-installed consumer apps" "INFO" "Detected: $names"
    } else {
        & $addItem "Pre-installed consumer apps" "PASS" "No known bloatware patterns."
    }

    # ---- Recently installed OS (could mask history) ----
    if ($Extended.Uptime.InstallAgeDays -ne $null -and $Extended.Uptime.InstallAgeDays -lt $th.OSInstallRecentWarnDays) {
        & $addItem "OS install recency" "WARN" "OS installed only $($Extended.Uptime.InstallAgeDays) days ago. Could be a fresh install to mask history - inspect event logs and disk wear carefully."
    } else {
        & $addItem "OS install recency" "PASS" "OS installed $($Extended.Uptime.InstallAgeDays) days ago."
    }

    # ---- Baseline match (optional) ----
    if ($Diff.State -eq "NONE") {
        & $addItem "Baseline comparison" "SKIP" "No baseline set (this is normal for first-time inspection)."
    } elseif ($Diff.State -eq "OK") {
        & $addItem "Baseline comparison" "PASS" "Hardware matches baseline - no swapped components."
    } elseif ($Diff.State -eq "DRIFT") {
        $cats = (($Diff.Diffs | ForEach-Object { $_.Category }) | Sort-Object -Unique) -join ", "
        & $addItem "Baseline comparison" "WARN" "$(@($Diff.Diffs).Count) component change(s) since baseline. Categories: $cats"
    } elseif ($Diff.State -eq "TAMPER") {
        & $addItem "Baseline comparison" "FAIL" "Baseline file integrity check failed - file modified outside this tool."
    }

    $out = $script:_clItems
    $script:_clItems = $null
    return $out
}

function Get-ExtendedInspection {
    param($Snap, [switch]$IncludeBenchmarks)

    $ext = @{
        Activation       = Get-WindowsActivationInfo
        BitLocker        = Get-BitLockerInfo
        Defender         = Get-DefenderStatus
        AutoLogin        = Get-AutoLoginStatus
        DomainJoin       = Get-DomainJoinInfo
        LocalAccounts    = Get-LocalAccountsInfo
        PnpDevicesByClass = Get-AllPnpDevices
        USBControllers   = Get-USBControllerInfo
        GPUCrashes       = Get-GPUDriverCrashCount
        Volumes          = Get-VolumeInfo
        USBHistory       = Get-USBDeviceHistory
        Network          = Get-NetworkCapability
        RAMDetail        = Get-RAMDetail -Snap $Snap
        Uptime           = Get-SystemUptimeInfo
        SoftwareChanges  = Get-RecentSoftwareChanges
        PowerConfig      = Get-PowerConfigInfo
        Thermals         = Get-ThermalZoneTemperatures
        UnsignedDrivers  = Get-UnsignedDriversInfo
        Bloatware        = Get-BloatwareSuspects
        WinSAT           = Get-WinSATCachedScores
        ManualTests      = Get-ManualTestLaunchers
    }
    if ($IncludeBenchmarks) {
        $ext.Benchmarks = @{
            Disk   = Invoke-DiskBenchmark
            CPU    = Invoke-CPUBenchmark
            Memory = Invoke-MemoryBenchmark
        }
    }
    return $ext
}

function Get-BuyerInspection {
    # Builds the "is this used machine OK to buy?" view.
    # Returns @{ Summary; RedFlags = @(...); KeyMetrics = @(...) }
    param($Snap, $Extended)

    $th      = Get-HardwareThresholds
    $flags   = @()      # array of @{ Severity; Title; Detail }
    $metrics = @()      # array of @{ Label; Value; Note }

    # --- Machine age ---
    $installDate = $null
    if ($Snap.OS -and $Snap.OS.InstallDate) {
        try { $installDate = [datetime]$Snap.OS.InstallDate } catch {}
    }
    $biosDate = $null
    if ($Snap.BIOS -and $Snap.BIOS.ReleaseDate) {
        try { $biosDate = [datetime]$Snap.BIOS.ReleaseDate } catch {}
    }
    $monitorYears = @($Snap.Monitors | Where-Object { $_.ManufactureYear -gt 1990 } | ForEach-Object { $_.ManufactureYear })

    $ageGuess = $null
    if ($installDate) {
        $days = [int]((Get-Date) - $installDate).TotalDays
        $ageGuess = "{0:N1} years (since OS install)" -f ($days / 365.25)
        $metrics += @{ Label = "OS install date"; Value = $installDate.ToString("yyyy-MM-dd"); Note = "$days days ago" }
        if ($days -lt $th.OSInstallRecentWarnDays) {
            $flags += @{ Severity = "WARN"; Title = "OS installed very recently ($days days ago)"; Detail = "Could be a fresh install to hide history. Inspect disk wear and event logs carefully." }
        }
    }
    if ($biosDate) {
        $metrics += @{ Label = "BIOS release date"; Value = $biosDate.ToString("yyyy-MM-dd"); Note = "Indicates earliest possible production year" }
    }
    if ($monitorYears.Count -gt 0) {
        $metrics += @{ Label = "Monitor manufacture year"; Value = (($monitorYears | Sort-Object -Unique) -join ", "); Note = "From EDID" }
    }
    if ($ageGuess) {
        $metrics += @{ Label = "Estimated machine age"; Value = $ageGuess; Note = "" }
    }

    # --- Disk inspection (most critical for used PC) ---
    foreach ($d in $Snap.Disks) {
        $label = "$($d.Model) (SN $($d.SerialNumber))"

        if ($d.PowerOnHours -ne $null) {
            $hours = [int]$d.PowerOnHours
            $years = [math]::Round($hours / 24 / 365.25, 1)
            $metrics += @{ Label = "Disk power-on hours"; Value = "$hours h (~$years yrs)"; Note = $label }
            if ($hours -gt $th.DiskPowerOnHoursFail) {
                $flags += @{ Severity = "FAIL"; Title = "Disk has $hours power-on hours (~$years years)"; Detail = "$label is heavily used. Failure risk increasing." }
            } elseif ($hours -gt $th.DiskPowerOnHoursWarn) {
                $flags += @{ Severity = "WARN"; Title = "Disk has $hours power-on hours"; Detail = "$label has significant runtime. Negotiate price or budget for replacement." }
            }
        }

        if ($d.Wear -ne $null) {
            $metrics += @{ Label = "SSD wear level"; Value = "$($d.Wear)%"; Note = $label }
            if ($d.Wear -gt $th.SSDWearFailPercent) {
                $flags += @{ Severity = "FAIL"; Title = "SSD wear $($d.Wear)% (over $($th.SSDWearFailPercent)%)"; Detail = "$label - replace immediately." }
            } elseif ($d.Wear -gt $th.SSDWearWarnPercent) {
                $flags += @{ Severity = "WARN"; Title = "SSD wear $($d.Wear)%"; Detail = "$label - moderate wear. Expect 1-3 more years of use." }
            }
        }

        if ($d.Temperature -ne $null -and $d.Temperature -gt $th.DiskTempWarnCelsius) {
            $flags += @{ Severity = "WARN"; Title = "Disk running hot ($($d.Temperature)C)"; Detail = "$label - check thermal pad / airflow" }
        }

        if ($d.ReadErrorsTotal -and $d.ReadErrorsTotal -gt 0) {
            $flags += @{ Severity = "FAIL"; Title = "Disk has $($d.ReadErrorsTotal) read errors"; Detail = "$label - data integrity at risk" }
        }
        if ($d.WriteErrorsTotal -and $d.WriteErrorsTotal -gt 0) {
            $flags += @{ Severity = "FAIL"; Title = "Disk has $($d.WriteErrorsTotal) write errors"; Detail = "$label - write failure detected" }
        }

        if ($d.HealthStatus -and $d.HealthStatus -ne "Healthy" -and $d.HealthStatus -ne "Unknown" -and $d.HealthStatus -ne "") {
            $flags += @{ Severity = "FAIL"; Title = "Disk SMART status: $($d.HealthStatus)"; Detail = $label }
        }
    }

    # --- Battery (laptop) ---
    if ($Snap.Battery -and $Snap.Battery.WearPercent -ne $null) {
        $metrics += @{ Label = "Battery wear"; Value = "$($Snap.Battery.WearPercent)%"; Note = "Design $($Snap.Battery.DesignCapacitymWh)mWh -> Full $($Snap.Battery.FullChargeCapacitymWh)mWh" }
        if ($Snap.Battery.WearPercent -gt $th.BatteryWearFailPercent) {
            $flags += @{ Severity = "FAIL"; Title = "Battery wear $($Snap.Battery.WearPercent)%"; Detail = "Capacity dropped significantly - factor replacement cost into the price." }
        } elseif ($Snap.Battery.WearPercent -gt $th.BatteryWearWarnPercent) {
            $flags += @{ Severity = "WARN"; Title = "Battery wear $($Snap.Battery.WearPercent)%"; Detail = "Mild wear, still serviceable." }
        }
    }

    # --- WHEA hardware errors history ---
    try {
        $whea = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=(Get-Date).AddDays(-$th.WHEALookbackDays) } -ErrorAction SilentlyContinue
        $n = @($whea).Count
        $metrics += @{ Label = "WHEA errors ($($th.WHEALookbackDays) days)"; Value = "$n"; Note = "CPU / RAM / PCIe fault count" }
        if ($n -gt 0) {
            $flags += @{ Severity = "FAIL"; Title = "$n WHEA hardware error(s) in last $($th.WHEALookbackDays) days"; Detail = "Symptom of unstable CPU/RAM/PCIe. Investigate before buying." }
        }
    } catch {}

    # --- PnP problem devices ---
    if ($Snap.ProblemDevices.Count -gt 0) {
        $names = ($Snap.ProblemDevices | ForEach-Object { $_.FriendlyName }) -join ", "
        $flags += @{ Severity = "FAIL"; Title = "$($Snap.ProblemDevices.Count) device(s) with driver/hardware problem"; Detail = $names }
    }

    # --- Unexpected shutdowns ---
    try {
        $kp = Get-WinEvent -FilterHashtable @{ LogName='System'; Id=41; ProviderName='Microsoft-Windows-Kernel-Power'; StartTime=(Get-Date).AddDays(-$th.UnexpectedShutdownLookbackDays) } -ErrorAction SilentlyContinue
        $n = @($kp).Count
        if ($n -gt 0) {
            $metrics += @{ Label = "Unexpected shutdowns ($($th.UnexpectedShutdownLookbackDays)d)"; Value = "$n"; Note = "Kernel-Power event 41" }
            if ($n -ge $th.UnexpectedShutdownWarnCount) {
                $flags += @{ Severity = "WARN"; Title = "$n unexpected shutdowns in $($th.UnexpectedShutdownLookbackDays) days"; Detail = "Possible PSU, overheating, or driver instability." }
            }
        }
    } catch {}

    # --- BSOD / bug-check count ---
    try {
        $bugs = Get-WinEvent -FilterHashtable @{ LogName='System'; Id=1001; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; StartTime=(Get-Date).AddDays(-$th.BSODLookbackDays) } -ErrorAction SilentlyContinue
        $n = @($bugs).Count
        if ($n -gt 0) {
            $metrics += @{ Label = "Bluescreens ($($th.BSODLookbackDays)d)"; Value = "$n"; Note = "WER bug-check reports" }
            if ($n -ge $th.BSODWarnCount) {
                $flags += @{ Severity = "WARN"; Title = "$n BSOD(s) in last $($th.BSODLookbackDays) days"; Detail = "Investigate driver / hardware stability." }
            }
        }
    } catch {}

    # --- TPM / Secure Boot (BitLocker readiness) ---
    if ($Snap.TPM -and -not $Snap.TPM.TpmPresent) {
        $flags += @{ Severity = "INFO"; Title = "No TPM detected"; Detail = "BitLocker / Windows 11 features may be limited." }
    }

    # --- Memory module count vs total ---
    if ($Snap.System -and $Snap.Memory.Count -gt 0) {
        $totalRam = 0
        foreach ($mm in $Snap.Memory) { $totalRam += [int64]$mm.Capacity }
        $sysRam = $Snap.System.TotalRAM
        $metrics += @{ Label = "RAM modules"; Value = "$($Snap.Memory.Count) installed"; Note = "Sum = $(Format-Bytes $totalRam)" }
        # Tolerate the configured difference (iGPU shared memory, ACPI/BIOS reserved regions)
        if ($sysRam -and ($totalRam -gt 0) -and ([math]::Abs($totalRam - $sysRam) -gt $th.RAMMismatchToleranceBytes)) {
            $flags += @{ Severity = "WARN"; Title = "Reported RAM mismatch"; Detail = "Modules sum=$(Format-Bytes $totalRam) vs System=$(Format-Bytes $sysRam) - one module may be faulty / unrecognized." }
        }
    }

    # --- Extended (Tier 1-4) checks ---
    if ($Extended) {
        # Activation
        if ($Extended.Activation -and -not $Extended.Activation.Genuine) {
            $flags += @{ Severity = "FAIL"; Title = "Windows not activated / not genuine"; Detail = "License status: $($Extended.Activation.LicenseStatus). Verify license is legitimate before buying." }
        }
        $metrics += @{ Label = "Windows activation"; Value = "$($Extended.Activation.LicenseStatus)"; Note = "Channel: $($Extended.Activation.Channel)" }

        # BitLocker
        foreach ($bl in $Extended.BitLocker) {
            if ($bl.ProtectionStatus -eq "On" -or $bl.VolumeStatus -match "Encrypted") {
                $flags += @{ Severity = "WARN"; Title = "Drive $($bl.MountPoint) is BitLocker-encrypted"; Detail = "If you don't have the recovery key from the seller, you can be locked out after a hardware change." }
            }
        }

        # Defender
        if ($Extended.Defender -and -not $Extended.Defender.AntivirusEnabled) {
            $flags += @{ Severity = "WARN"; Title = "Microsoft Defender disabled"; Detail = "Could indicate third-party AV installed - or Defender was manually turned off." }
        }
        if ($Extended.Defender.DefinitionAge -gt 14) {
            $flags += @{ Severity = "WARN"; Title = "AV definitions outdated ($($Extended.Defender.DefinitionAge) days)"; Detail = "Antivirus signatures not updating - machine may be offline or AV broken." }
        }

        # Auto-login
        if ($Extended.AutoLogin.Enabled) {
            $detail = "User: $($Extended.AutoLogin.DefaultUser)"
            if ($Extended.AutoLogin.PasswordStored) { $detail += " | PASSWORD STORED IN PLAIN TEXT in registry" }
            $flags += @{ Severity = "WARN"; Title = "Auto-login is enabled"; Detail = $detail }
        }

        # Domain join
        if ($Extended.DomainJoin.PartOfDomain) {
            $flags += @{ Severity = "WARN"; Title = "Machine is joined to domain '$($Extended.DomainJoin.Domain)'"; Detail = "Previous corporate machine. May have GPO restrictions or be remotely managed." }
        }

        # Local accounts
        $extraAccounts = @($Extended.LocalAccounts | Where-Object { -not $_.IsBuiltIn -and $_.Enabled })
        if ($extraAccounts.Count -gt 0) {
            $names = ($extraAccounts | ForEach-Object { $_.Name }) -join ", "
            $flags += @{ Severity = "WARN"; Title = "$($extraAccounts.Count) leftover user account(s) from previous owner"; Detail = "Accounts: $names. Remove or change passwords before use." }
        }
        $metrics += @{ Label = "Local users (non-builtin)"; Value = "$($extraAccounts.Count)"; Note = (@($Extended.LocalAccounts | Where-Object { -not $_.IsBuiltIn }) | ForEach-Object { $_.Name }) -join ", " }

        # GPU TDR crashes
        if ($Extended.GPUCrashes.Count -gt 0) {
            $sev = if ($Extended.GPUCrashes.Count -ge $th.GPUDriverCrashWarnCount) { "FAIL" } else { "WARN" }
            $flags += @{ Severity = $sev; Title = "$($Extended.GPUCrashes.Count) GPU driver crash(es) in $($Extended.GPUCrashes.LookbackDays) days"; Detail = "Display driver TDR events - GPU instability sign." }
        }
        $metrics += @{ Label = "GPU driver crashes ($($Extended.GPUCrashes.LookbackDays)d)"; Value = "$($Extended.GPUCrashes.Count)"; Note = "TDR events 4101" }

        # Disk free + dirty
        foreach ($v in $Extended.Volumes) {
            if ($v.DirtyBit) {
                $flags += @{ Severity = "FAIL"; Title = "Drive $($v.DriveLetter) has filesystem dirty bit set"; Detail = "Filesystem needs chkdsk. Possible corruption from improper shutdown." }
            }
            if ($v.FreePercent -lt $th.DiskFreeSpaceFailPercent) {
                $flags += @{ Severity = "FAIL"; Title = "Drive $($v.DriveLetter) almost full ($($v.FreePercent)%)"; Detail = "Only $(Format-Bytes $v.FreeBytes) free of $(Format-Bytes $v.SizeBytes)" }
            } elseif ($v.FreePercent -lt $th.DiskFreeSpaceWarnPercent) {
                $flags += @{ Severity = "WARN"; Title = "Drive $($v.DriveLetter) low on space ($($v.FreePercent)%)"; Detail = "Only $(Format-Bytes $v.FreeBytes) free" }
            }
        }

        # USB controllers metric
        if ($Extended.USBControllers.Count -gt 0) {
            $versions = @($Extended.USBControllers | ForEach-Object { $_.Version }) | Sort-Object -Unique
            $metrics += @{ Label = "USB controllers"; Value = "$($Extended.USBControllers.Count)"; Note = "Versions: $($versions -join ', ')" }
        }

        # Network capability
        if ($Extended.Network.Wifi) {
            $metrics += @{ Label = "Wi-Fi"; Value = $Extended.Network.Wifi.Generation; Note = $Extended.Network.Wifi.Standards }
        }
        if ($Extended.Network.Bluetooth) {
            $metrics += @{ Label = "Bluetooth"; Value = $Extended.Network.Bluetooth.Name; Note = "Status: $($Extended.Network.Bluetooth.Status)" }
        }

        # RAM detail
        if ($Extended.RAMDetail.SpeedMismatch) {
            $flags += @{ Severity = "WARN"; Title = "RAM speed mismatch detected"; Detail = "DIMMs running at different speeds: $($Extended.RAMDetail.SpeedsMHz -join ', ') MHz. Could indicate mixed/replaced modules." }
        }
        if ($Extended.RAMDetail.TotalSlots) {
            $metrics += @{ Label = "DIMM slots"; Value = "$($Extended.RAMDetail.UsedSlots)/$($Extended.RAMDetail.TotalSlots) used"; Note = "$($Extended.RAMDetail.EmptySlots) empty slot(s) for upgrade" }
        }

        # Uptime / age
        if ($Extended.Uptime.UptimeHours -gt 0) {
            $metrics += @{ Label = "Current uptime"; Value = "$($Extended.Uptime.UptimeHours) hours"; Note = "Since last boot" }
        }

        # Unsigned drivers
        if (@($Extended.UnsignedDrivers).Count -gt 0) {
            $flags += @{ Severity = "WARN"; Title = "$(@($Extended.UnsignedDrivers).Count) unsigned driver(s) installed"; Detail = "Could be legitimate (homebrew) or suspicious. Review the list below." }
        }

        # Bloatware
        if (@($Extended.Bloatware).Count -gt 0) {
            $names = (@($Extended.Bloatware) | ForEach-Object { $_.Name }) -join ", "
            $flags += @{ Severity = "INFO"; Title = "Pre-installed consumer apps detected"; Detail = $names }
        }

        # Benchmarks (if provided)
        if ($Extended.Benchmarks) {
            if ($Extended.Benchmarks.Disk.ReadMBps) {
                $metrics += @{ Label = "Disk read speed"; Value = "$($Extended.Benchmarks.Disk.ReadMBps) MB/s"; Note = "$($Extended.Benchmarks.Disk.FileSizeMB)MB on $($Extended.Benchmarks.Disk.TestedOn)" }
                $metrics += @{ Label = "Disk write speed"; Value = "$($Extended.Benchmarks.Disk.WriteMBps) MB/s"; Note = "" }
            }
            if ($Extended.Benchmarks.CPU.HashMBps) {
                $metrics += @{ Label = "CPU SHA-256 throughput"; Value = "$($Extended.Benchmarks.CPU.HashMBps) MB/s"; Note = "$($Extended.Benchmarks.CPU.Iterations) iters in $($Extended.Benchmarks.CPU.ElapsedSec)s" }
            }
            if ($Extended.Benchmarks.Memory.BandwidthMBps) {
                $metrics += @{ Label = "Memory copy bandwidth"; Value = "$($Extended.Benchmarks.Memory.BandwidthMBps) MB/s"; Note = "BlockCopy $($Extended.Benchmarks.Memory.TotalCopiedMB)MB" }
            }
        }

        # WinSAT cached
        if ($Extended.WinSAT) {
            $metrics += @{ Label = "WinSAT base score"; Value = "$($Extended.WinSAT.BaseScore)"; Note = "CPU=$($Extended.WinSAT.CPUScore) Mem=$($Extended.WinSAT.MemoryScore) Disk=$($Extended.WinSAT.DiskScore) Gfx=$($Extended.WinSAT.GraphicsScore) D3D=$($Extended.WinSAT.D3DScore)" }
        }
    }

    # --- Summary verdict ---
    $failCnt = @($flags | Where-Object { $_.Severity -eq "FAIL" }).Count
    $warnCnt = @($flags | Where-Object { $_.Severity -eq "WARN" }).Count
    $verdict = if ($failCnt -gt 0) {
        "AVOID OR NEGOTIATE - $failCnt critical issue(s) found"
    } elseif ($warnCnt -gt 0) {
        "CAUTION - $warnCnt warning(s), inspect closely"
    } else {
        "LOOKS GOOD - no major red flags detected"
    }
    $verdictSev = if ($failCnt -gt 0) { "FAIL" } elseif ($warnCnt -gt 0) { "WARN" } else { "OK" }

    return @{
        Summary    = $verdict
        Severity   = $verdictSev
        RedFlags   = $flags
        KeyMetrics = $metrics
    }
}

function Get-HardwareEventSummary {
    param([int]$Days = 0)
    if ($Days -le 0) {
        $th = Get-HardwareThresholds
        $Days = [int]$th.EventLookbackDays
    }
    $since = (Get-Date).AddDays(-$Days)
    $providers = @(
        @{ Name = "WHEA";              Filter = @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$since } }
        @{ Name = "Disk";              Filter = @{ LogName='System'; ProviderName='disk'; Level=1,2,3; StartTime=$since } }
        @{ Name = "Display";           Filter = @{ LogName='System'; ProviderName='Display'; Level=1,2,3; StartTime=$since } }
        @{ Name = "Kernel-Power";      Filter = @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Level=1,2,3; StartTime=$since } }
        @{ Name = "MemoryDiagnostic";  Filter = @{ LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results' } }
    )
    $out = @()
    foreach ($p in $providers) {
        try {
            $events = Get-WinEvent -FilterHashtable $p.Filter -MaxEvents 10 -ErrorAction Stop
            foreach ($e in @($events)) {
                $msg = if ($e.Message) { ($e.Message -split "`n" | Select-Object -First 1) } else { "" }
                $out += [pscustomobject]@{
                    Provider = $p.Name
                    Time     = $e.TimeCreated
                    Level    = $e.LevelDisplayName
                    Id       = $e.Id
                    Message  = $msg
                }
            }
        } catch {}
    }
    return $out
}

# ----------------------------------------------------------------------------
# One-shot combined report (inventory + health + baseline diff + events)
# ----------------------------------------------------------------------------

function Invoke-HardwareReport {
    [CmdletBinding()]
    param(
        [switch]$NoOpen,
        [string]$OutputPath
    )

    Write-MenuHeader "Generating Hardware Report"

    Write-Step "Collecting hardware snapshot..." -Type Info
    $snap = Get-HardwareSnapshot

    $th = Get-HardwareThresholds
    $runBench = [bool]$th.RunBenchmarks

    Write-Step "Running extended inspection (Tier 1-4 checks)..." -Type Info
    if ($runBench) { Write-Step "  Running quick benchmarks (disk/CPU/memory, ~10-30s)..." -Type Info }
    $ext = Get-ExtendedInspection -Snap $snap -IncludeBenchmarks:$runBench

    Write-Step "Running buyer inspection..." -Type Info
    $buyer = Get-BuyerInspection -Snap $snap -Extended $ext

    Write-Step "Running health checks..." -Type Info
    $health = Get-HardwareHealthData -Snap $snap

    # Build the TODO-style checklist (after $diff is collected below; placeholder, populated later)

    Write-Step "Comparing against baseline (optional)..." -Type Info
    $diff = Get-HardwareBaselineDiff -CurrentSnap $snap

    Write-Step "Reading hardware event logs..." -Type Info
    $events = Get-HardwareEventSummary

    Write-Step "Building inspection checklist..." -Type Info
    $checklist = Get-InspectionChecklist -Snap $snap -Extended $ext -Health $health -Events $events -Diff $diff -Buyer $buyer

    # Counts
    $healthFail = @($health | Where-Object { $_.Severity -eq "FAIL" }).Count
    $healthWarn = @($health | Where-Object { $_.Severity -eq "WARN" }).Count
    $diffCount  = @($diff.Diffs).Count
    $flagFail   = @($buyer.RedFlags | Where-Object { $_.Severity -eq "FAIL" }).Count
    $flagWarn   = @($buyer.RedFlags | Where-Object { $_.Severity -eq "WARN" }).Count

    # Output path
    if (-not $OutputPath) {
        $dir = Get-HardwareReportDir
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $OutputPath = Join-Path $dir "report_${env:COMPUTERNAME}_$stamp.html"
    }

    # Build HTML
    $sb = [System.Text.StringBuilder]::new()
    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }

    [void]$sb.AppendLine("<!doctype html><html><head><meta charset='utf-8'>")
    [void]$sb.AppendLine("<title>Hardware Report - $($snap.Hostname)</title>")
    [void]$sb.AppendLine(@"
<style>
  body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2937; background: #f9fafb; }
  h1 { color: #0a4a78; margin-bottom: 4px; }
  h2 { border-bottom: 2px solid #0a4a78; color: #0a4a78; margin-top: 32px; padding-bottom: 4px; }
  .meta { color: #6b7280; font-size: 13px; margin-bottom: 12px; }
  .summary { display: flex; gap: 12px; margin: 16px 0 24px; flex-wrap: wrap; }
  .card { background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 14px 20px; min-width: 160px; box-shadow: 0 1px 2px rgba(0,0,0,.04); }
  .card .label { font-size: 12px; text-transform: uppercase; color: #6b7280; letter-spacing: .5px; }
  .card .value { font-size: 22px; font-weight: 700; margin-top: 6px; }
  .ok { color: #15803d; } .warn { color: #b45309; } .fail { color: #b91c1c; } .info { color: #1f2937; }
  table { border-collapse: collapse; margin: 8px 0; width: 100%; background: #fff; border-radius: 6px; overflow: hidden; box-shadow: 0 1px 2px rgba(0,0,0,.04); }
  th, td { border: 1px solid #e5e7eb; padding: 8px 10px; text-align: left; font-size: 13px; vertical-align: top; }
  th { background: #0a4a78; color: #fff; }
  tr:nth-child(even) td { background: #f9fafb; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; }
  .badge-ok    { background: #dcfce7; color: #15803d; }
  .badge-warn  { background: #fef3c7; color: #b45309; }
  .badge-fail  { background: #fee2e2; color: #b91c1c; }
  .badge-info  { background: #e0e7ff; color: #3730a3; }
  .badge-new     { background: #dbeafe; color: #1e40af; }
  .badge-missing { background: #fee2e2; color: #b91c1c; }
  .badge-changed { background: #fef3c7; color: #92400e; }
  pre { white-space: pre-wrap; word-break: break-all; font-size: 12px; background: #f3f4f6; padding: 6px; border-radius: 4px; margin: 0; }
</style>
"@)
    [void]$sb.AppendLine("</head><body>")

    [void]$sb.AppendLine("<h1>Hardware Report</h1>")
    [void]$sb.AppendLine("<div class='meta'>Host: <b>$(& $enc $snap.Hostname)</b> &nbsp;|&nbsp; Collected: $(& $enc $snap.CollectedAt)</div>")

    # ---- Inspection Checklist (TODO-style list, status on the right) ----
    [void]$sb.AppendLine("<h2>Inspection Checklist</h2>")
    [void]$sb.AppendLine("<p class='meta'>Click any FAIL / WARN row to expand and see why. PASS rows have no extra detail.</p>")
    [void]$sb.AppendLine("<table style='width:100%'><colgroup><col style='width:auto'><col style='width:90px'></colgroup>")
    [void]$sb.AppendLine("<tr><th>Check</th><th style='text-align:right'>Status</th></tr>")
    foreach ($c in $checklist) {
        $cls = switch ($c.Status) {
            "PASS" {"badge-ok"}
            "WARN" {"badge-warn"}
            "FAIL" {"badge-fail"}
            "SKIP" {"badge-info"}
            default {"badge-info"}
        }
        $badge = "<span class='badge $cls'>$(& $enc $c.Status)</span>"
        if ($c.Status -eq "PASS" -or $c.Status -eq "SKIP" -or -not $c.Detail) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $c.Name)</td><td style='text-align:right'>$badge</td></tr>")
        } else {
            # Non-PASS rows: collapsible <details>
            [void]$sb.AppendLine("<tr><td colspan='2'><details><summary style='cursor:pointer;display:flex;justify-content:space-between'><span>$(& $enc $c.Name)</span>$badge</summary><div style='padding:8px 4px 4px;color:#444'>$(& $enc $c.Detail)</div></details></td></tr>")
        }
    }
    [void]$sb.AppendLine("</table>")

    # Summary cards
    $verdictClass = switch ($buyer.Severity) { "FAIL" {"fail"} "WARN" {"warn"} default {"ok"} }
    $diffLabel = switch ($diff.State) { "OK" {"<span class='ok'>MATCH</span>"} "DRIFT" {"<span class='warn'>$diffCount changes</span>"} "TAMPER" {"<span class='fail'>TAMPERED</span>"} "NONE" {"<span class='info'>not used</span>"} default {"<span class='info'>$($diff.State)</span>"} }
    $healthLabel = if ($healthFail -gt 0) { "<span class='fail'>$healthFail failed</span>" } elseif ($healthWarn -gt 0) { "<span class='warn'>$healthWarn warnings</span>" } else { "<span class='ok'>healthy</span>" }
    $flagLabel = if ($flagFail -gt 0) { "<span class='fail'>$flagFail critical</span>" } elseif ($flagWarn -gt 0) { "<span class='warn'>$flagWarn warnings</span>" } else { "<span class='ok'>clean</span>" }

    [void]$sb.AppendLine("<div class='summary'>")
    [void]$sb.AppendLine("  <div class='card'><div class='label'>Buyer verdict</div><div class='value $verdictClass'>$(& $enc $buyer.Summary)</div></div>")
    [void]$sb.AppendLine("  <div class='card'><div class='label'>Red flags</div><div class='value'>$flagLabel</div></div>")
    [void]$sb.AppendLine("  <div class='card'><div class='label'>Health checks</div><div class='value'>$healthLabel</div></div>")
    [void]$sb.AppendLine("  <div class='card'><div class='label'>Problem devices</div><div class='value'>$($snap.ProblemDevices.Count)</div></div>")
    [void]$sb.AppendLine("  <div class='card'><div class='label'>Event errors (7d)</div><div class='value'>$(@($events).Count)</div></div>")
    [void]$sb.AppendLine("</div>")

    # ---- Buyer Inspection (used-PC purchase) ----
    [void]$sb.AppendLine("<h2>Buyer Inspection - Red Flags</h2>")
    if ($buyer.RedFlags.Count -eq 0) {
        [void]$sb.AppendLine("<p class='ok'><b>No red flags detected.</b> Hardware looks healthy on automated inspection. Still verify the chassis, screen, keyboard, ports physically.</p>")
    } else {
        [void]$sb.AppendLine("<table><tr><th>Severity</th><th>Issue</th><th>Detail</th></tr>")
        foreach ($f in ($buyer.RedFlags | Sort-Object { switch ($_.Severity) { "FAIL" {0} "WARN" {1} default {2} } })) {
            $cls = switch ($f.Severity) { "FAIL" {"badge-fail"} "WARN" {"badge-warn"} default {"badge-info"} }
            [void]$sb.AppendLine("<tr><td><span class='badge $cls'>$(& $enc $f.Severity)</span></td><td>$(& $enc $f.Title)</td><td>$(& $enc $f.Detail)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    [void]$sb.AppendLine("<h2>Buyer Inspection - Key Metrics</h2>")
    [void]$sb.AppendLine("<table><tr><th>Metric</th><th>Value</th><th>Context</th></tr>")
    foreach ($m in $Buyer.KeyMetrics) {
        [void]$sb.AppendLine("<tr><td>$(& $enc $m.Label)</td><td><b>$(& $enc $m.Value)</b></td><td>$(& $enc $m.Note)</td></tr>")
    }
    [void]$sb.AppendLine("</table>")

    # ============================================================
    # Tier 1-4 extended sections
    # ============================================================

    # --- Security & License (Tier 1) ---
    [void]$sb.AppendLine("<h2>Security &amp; License</h2>")
    $sec = @(
        @{ Item="Windows activation"; Value="$($ext.Activation.LicenseStatus) ($($ext.Activation.Channel))"; Note=$ext.Activation.Description }
        @{ Item="Defender enabled"; Value="$($ext.Defender.AntivirusEnabled)"; Note="RealTime=$($ext.Defender.RealTimeProtection), Tamper=$($ext.Defender.TamperProtection), DefAge=$($ext.Defender.DefinitionAge)d" }
        @{ Item="Auto-login enabled"; Value="$($ext.AutoLogin.Enabled)"; Note="User=$($ext.AutoLogin.DefaultUser) PwdInRegistry=$($ext.AutoLogin.PasswordStored)" }
        @{ Item="Domain joined"; Value="$($ext.DomainJoin.PartOfDomain)"; Note="$($ext.DomainJoin.Domain) / $($ext.DomainJoin.DomainRole)" }
    )
    [void]$sb.AppendLine("<table><tr><th>Item</th><th>Value</th><th>Detail</th></tr>")
    foreach ($r in $sec) { [void]$sb.AppendLine("<tr><td>$(& $enc $r.Item)</td><td><b>$(& $enc $r.Value)</b></td><td>$(& $enc $r.Note)</td></tr>") }
    [void]$sb.AppendLine("</table>")

    # BitLocker volumes
    if (@($ext.BitLocker).Count -gt 0) {
        [void]$sb.AppendLine("<h2>BitLocker Volumes</h2>")
        [void]$sb.AppendLine("<table><tr><th>Drive</th><th>Protection</th><th>Status</th><th>Encryption</th><th>Key protectors</th></tr>")
        foreach ($b in $ext.BitLocker) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $b.MountPoint)</td><td>$(& $enc $b.ProtectionStatus)</td><td>$(& $enc $b.VolumeStatus)</td><td>$(& $enc $b.EncryptionPercent)%</td><td>$(& $enc $b.KeyProtectorTypes)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # Local accounts
    [void]$sb.AppendLine("<h2>Local User Accounts</h2>")
    if (@($ext.LocalAccounts).Count -eq 0) {
        [void]$sb.AppendLine("<p class='info'>No local accounts found.</p>")
    } else {
        [void]$sb.AppendLine("<table><tr><th>Name</th><th>Enabled</th><th>Built-in</th><th>Last logon</th><th>Pwd required</th></tr>")
        foreach ($a in $ext.LocalAccounts) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $a.Name)</td><td>$(& $enc $a.Enabled)</td><td>$(& $enc $a.IsBuiltIn)</td><td>$(& $enc $a.LastLogon)</td><td>$(& $enc $a.PasswordRequired)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # Volumes / disk space + dirty
    [void]$sb.AppendLine("<h2>Volumes (free space, integrity)</h2>")
    [void]$sb.AppendLine("<table><tr><th>Drive</th><th>FS</th><th>Label</th><th>Size</th><th>Free</th><th>Free %</th><th>Health</th><th>Dirty bit</th></tr>")
    foreach ($v in $ext.Volumes) {
        $freeCls = if ($v.FreePercent -lt $th.DiskFreeSpaceFailPercent) { "fail" } elseif ($v.FreePercent -lt $th.DiskFreeSpaceWarnPercent) { "warn" } else { "ok" }
        $dirtyCls = if ($v.DirtyBit) { "fail" } else { "ok" }
        [void]$sb.AppendLine("<tr><td>$(& $enc $v.DriveLetter)</td><td>$(& $enc $v.FileSystem)</td><td>$(& $enc $v.Label)</td><td>$(& $enc (Format-Bytes $v.SizeBytes))</td><td>$(& $enc (Format-Bytes $v.FreeBytes))</td><td class='$freeCls'><b>$(& $enc $v.FreePercent)%</b></td><td>$(& $enc $v.HealthStatus)</td><td class='$dirtyCls'>$(& $enc $v.DirtyBit)</td></tr>")
    }
    [void]$sb.AppendLine("</table>")

    # USB controllers + Network capability (Tier 1/2)
    [void]$sb.AppendLine("<h2>USB Controllers</h2>")
    if (@($ext.USBControllers).Count -eq 0) {
        [void]$sb.AppendLine("<p class='info'>No USB controllers reported.</p>")
    } else {
        [void]$sb.AppendLine("<table><tr><th>Name</th><th>Version</th><th>Manufacturer</th><th>Status</th></tr>")
        foreach ($c in $ext.USBControllers) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $c.Name)</td><td><b>$(& $enc $c.Version)</b></td><td>$(& $enc $c.Manufacturer)</td><td>$(& $enc $c.Status)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    [void]$sb.AppendLine("<h2>Network Capability</h2>")
    [void]$sb.AppendLine("<table><tr><th>Type</th><th>Details</th></tr>")
    if ($ext.Network.Wifi) {
        [void]$sb.AppendLine("<tr><td>Wi-Fi</td><td><b>$(& $enc $ext.Network.Wifi.Generation)</b> &mdash; standards: $(& $enc $ext.Network.Wifi.Standards)</td></tr>")
    }
    if ($ext.Network.Bluetooth) {
        [void]$sb.AppendLine("<tr><td>Bluetooth</td><td>$(& $enc $ext.Network.Bluetooth.Name) ($(& $enc $ext.Network.Bluetooth.Status))</td></tr>")
    }
    foreach ($e in $ext.Network.Ethernet) {
        [void]$sb.AppendLine("<tr><td>Ethernet</td><td>$(& $enc $e.Name) &mdash; link: $(& $enc $e.LinkSpeed) ($(& $enc $e.Status))</td></tr>")
    }
    [void]$sb.AppendLine("</table>")

    # PnP device tree (collapsed by class)
    [void]$sb.AppendLine("<h2>All Connected Devices (PnP tree)</h2>")
    if ($ext.PnpDevicesByClass.Count -eq 0) {
        [void]$sb.AppendLine("<p class='info'>No PnP devices enumerated.</p>")
    } else {
        foreach ($cls in ($ext.PnpDevicesByClass.Keys | Sort-Object)) {
            $items = $ext.PnpDevicesByClass[$cls]
            [void]$sb.AppendLine("<h3 style='color:#1f2937;margin-top:18px'>$(& $enc $cls) ($($items.Count))</h3>")
            [void]$sb.AppendLine("<table><tr><th>Friendly Name</th><th>Manufacturer</th><th>Status</th></tr>")
            foreach ($d in $items) {
                $sCls = if ($d.Status -ne "OK") { "fail" } else { "" }
                [void]$sb.AppendLine("<tr><td>$(& $enc $d.FriendlyName)</td><td>$(& $enc $d.Manufacturer)</td><td class='$sCls'>$(& $enc $d.Status)</td></tr>")
            }
            [void]$sb.AppendLine("</table>")
        }
    }

    # USB history
    [void]$sb.AppendLine("<h2>USB Device History</h2>")
    if (@($ext.USBHistory).Count -eq 0) {
        [void]$sb.AppendLine("<p class='info'>No USB storage history in registry.</p>")
    } else {
        [void]$sb.AppendLine("<table><tr><th>Device</th><th>Manufacturer</th><th>Service</th></tr>")
        foreach ($u in $ext.USBHistory) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $u.FriendlyName)</td><td>$(& $enc $u.Mfg)</td><td>$(& $enc $u.Service)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # RAM detail
    [void]$sb.AppendLine("<h2>RAM Configuration</h2>")
    [void]$sb.AppendLine("<table><tr><th>Total slots</th><th>Used</th><th>Empty</th><th>Speeds (MHz)</th><th>Mismatch</th><th>Max capacity</th></tr>")
    $rd = $ext.RAMDetail
    $maxCap = if ($rd.MaxCapacityBytes) { Format-Bytes $rd.MaxCapacityBytes } else { "?" }
    $mmCls = if ($rd.SpeedMismatch) { "warn" } else { "ok" }
    [void]$sb.AppendLine("<tr><td>$(& $enc $rd.TotalSlots)</td><td>$(& $enc $rd.UsedSlots)</td><td>$(& $enc $rd.EmptySlots)</td><td>$(& $enc ($rd.SpeedsMHz -join ', '))</td><td class='$mmCls'>$(& $enc $rd.SpeedMismatch)</td><td>$(& $enc $maxCap)</td></tr>")
    [void]$sb.AppendLine("</table>")

    # Uptime + power config
    [void]$sb.AppendLine("<h2>Uptime &amp; Power</h2>")
    [void]$sb.AppendLine("<table><tr><th>Item</th><th>Value</th></tr>")
    [void]$sb.AppendLine("<tr><td>Last boot</td><td>$(& $enc $ext.Uptime.LastBoot)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Current uptime (hours)</td><td>$(& $enc $ext.Uptime.UptimeHours)</td></tr>")
    [void]$sb.AppendLine("<tr><td>OS install age (days)</td><td>$(& $enc $ext.Uptime.InstallAgeDays)</td></tr>")
    if ($ext.PowerConfig.HibernateEnabled -ne $null) {
        [void]$sb.AppendLine("<tr><td>Hibernate enabled</td><td>$(& $enc $ext.PowerConfig.HibernateEnabled)</td></tr>")
    }
    if ($ext.PowerConfig.PageFile) {
        [void]$sb.AppendLine("<tr><td>Page file</td><td>$(& $enc $ext.PowerConfig.PageFile.Path) - $(& $enc $ext.PowerConfig.PageFile.AllocatedMB) MB allocated</td></tr>")
    }
    [void]$sb.AppendLine("</table>")

    # Recent software changes
    [void]$sb.AppendLine("<h2>Recent Software Changes (last $($th.RecentInstallLookbackDays) days)</h2>")
    if (@($ext.SoftwareChanges).Count -eq 0) {
        [void]$sb.AppendLine("<p class='info'>No MSI install/uninstall events in window.</p>")
    } else {
        [void]$sb.AppendLine("<table><tr><th>Time</th><th>Action</th><th>Product</th></tr>")
        foreach ($c in $ext.SoftwareChanges) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $c.Time)</td><td>$(& $enc $c.Action)</td><td>$(& $enc $c.Product)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # Benchmarks
    if ($ext.Benchmarks) {
        [void]$sb.AppendLine("<h2>Quick Performance Benchmarks</h2>")
        [void]$sb.AppendLine("<table><tr><th>Test</th><th>Result</th><th>Detail</th></tr>")
        $b = $ext.Benchmarks
        if ($b.Disk.ReadMBps) {
            [void]$sb.AppendLine("<tr><td>Disk read</td><td><b>$($b.Disk.ReadMBps) MB/s</b></td><td>$($b.Disk.FileSizeMB)MB file, $($b.Disk.ReadSec)s on $($b.Disk.TestedOn)</td></tr>")
            [void]$sb.AppendLine("<tr><td>Disk write</td><td><b>$($b.Disk.WriteMBps) MB/s</b></td><td>$($b.Disk.FileSizeMB)MB file, $($b.Disk.WriteSec)s</td></tr>")
        }
        if ($b.CPU.HashMBps) {
            [void]$sb.AppendLine("<tr><td>CPU SHA-256</td><td><b>$($b.CPU.HashMBps) MB/s</b></td><td>$($b.CPU.Iterations) iterations of 1MB in $($b.CPU.ElapsedSec)s (single-threaded)</td></tr>")
        }
        if ($b.Memory.BandwidthMBps) {
            [void]$sb.AppendLine("<tr><td>Memory copy</td><td><b>$($b.Memory.BandwidthMBps) MB/s</b></td><td>$($b.Memory.TotalCopiedMB)MB copied in $($b.Memory.ElapsedSec)s</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # WinSAT cached
    if ($ext.WinSAT) {
        [void]$sb.AppendLine("<h2>WinSAT Cached Scores</h2>")
        [void]$sb.AppendLine("<table><tr><th>Component</th><th>Score (out of ~9.9)</th></tr>")
        [void]$sb.AppendLine("<tr><td>Base</td><td><b>$($ext.WinSAT.BaseScore)</b></td></tr>")
        [void]$sb.AppendLine("<tr><td>CPU</td><td>$($ext.WinSAT.CPUScore)</td></tr>")
        [void]$sb.AppendLine("<tr><td>Memory</td><td>$($ext.WinSAT.MemoryScore)</td></tr>")
        [void]$sb.AppendLine("<tr><td>Disk</td><td>$($ext.WinSAT.DiskScore)</td></tr>")
        [void]$sb.AppendLine("<tr><td>Graphics</td><td>$($ext.WinSAT.GraphicsScore)</td></tr>")
        [void]$sb.AppendLine("<tr><td>D3D</td><td>$($ext.WinSAT.D3DScore)</td></tr>")
        [void]$sb.AppendLine("</table>")
    }

    # Thermal zones
    if (@($ext.Thermals).Count -gt 0) {
        [void]$sb.AppendLine("<h2>Thermal Zones (best-effort)</h2>")
        [void]$sb.AppendLine("<p class='meta'>Note: many systems do not expose CPU/GPU temps via WMI. For accurate temps use HWInfo or LibreHardwareMonitor.</p>")
        [void]$sb.AppendLine("<table><tr><th>Zone</th><th>Temperature</th></tr>")
        foreach ($t in $ext.Thermals) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $t.Zone)</td><td>$(& $enc $t.TempC) C</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # Unsigned drivers
    [void]$sb.AppendLine("<h2>Unsigned / Suspicious Drivers</h2>")
    if (@($ext.UnsignedDrivers).Count -eq 0) {
        [void]$sb.AppendLine("<p class='ok'>All drivers signed.</p>")
    } else {
        [void]$sb.AppendLine("<table><tr><th>Driver</th><th>Provider</th><th>Class</th><th>Signer</th></tr>")
        foreach ($d in $ext.UnsignedDrivers) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $d.Driver)</td><td>$(& $enc $d.Provider)</td><td>$(& $enc $d.Class)</td><td>$(& $enc $d.Signer)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # Bloatware
    if (@($ext.Bloatware).Count -gt 0) {
        [void]$sb.AppendLine("<h2>Pre-installed Consumer Apps Detected</h2>")
        [void]$sb.AppendLine("<table><tr><th>Name</th><th>Publisher</th><th>Source</th></tr>")
        foreach ($a in $ext.Bloatware) {
            [void]$sb.AppendLine("<tr><td>$(& $enc $a.Name)</td><td>$(& $enc $a.Publisher)</td><td>$(& $enc $a.Source)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # Manual test launchers
    [void]$sb.AppendLine("<h2>Manual Tests You Must Run Yourself</h2>")
    [void]$sb.AppendLine("<p class='meta'>These cannot be checked from PowerShell. Click each link, run the test, and verify in person.</p>")
    [void]$sb.AppendLine("<table><tr><th>Test</th><th>Link</th></tr>")
    foreach ($t in $ext.ManualTests) {
        [void]$sb.AppendLine("<tr><td>$(& $enc $t.Test)</td><td><a href='$(& $enc $t.Url)' target='_blank'>$(& $enc $t.Url)</a></td></tr>")
    }
    [void]$sb.AppendLine("</table>")

    # ---- Baseline diff (optional / advanced) ----
    [void]$sb.AppendLine("<h2>Baseline Comparison (advanced)</h2>")
    switch ($diff.State) {
        "NONE" {
            [void]$sb.AppendLine("<p class='info'>No baseline set. Run the 'Set / Update Baseline' option to capture this machine's original hardware fingerprint.</p>")
        }
        "TAMPER" {
            [void]$sb.AppendLine("<p class='fail'><b>Baseline file integrity FAILED.</b> The baseline file was modified outside this tool - its hash no longer matches. Treat any comparison result with suspicion and re-baseline from a trusted state.</p>")
        }
        "ERROR" {
            [void]$sb.AppendLine("<p class='fail'>Error reading baseline: $(& $enc $diff.Error)</p>")
        }
        default {
            [void]$sb.AppendLine("<p class='info'>Baseline captured: $(& $enc $diff.CreatedAt) by $(& $enc $diff.CreatedBy) on $(& $enc $diff.Hostname).</p>")
            if ($diff.State -eq "OK") {
                [void]$sb.AppendLine("<p class='ok'><b>Hardware matches baseline.</b> No replaced or missing components detected.</p>")
            } else {
                [void]$sb.AppendLine("<p class='warn'><b>$diffCount component change(s) detected since baseline:</b></p>")
                [void]$sb.AppendLine("<table><tr><th>Change</th><th>Category</th><th>Key</th><th>Detail</th></tr>")
                foreach ($d in $diff.Diffs) {
                    $cls = switch ($d.Change) { "NEW" {"badge-new"} "MISSING" {"badge-missing"} "CHANGED" {"badge-changed"} default {"badge-info"} }
                    [void]$sb.AppendLine("<tr><td><span class='badge $cls'>$(& $enc $d.Change)</span></td><td>$(& $enc $d.Category)</td><td>$(& $enc $d.Key)</td><td><pre>$(& $enc $d.Detail)</pre></td></tr>")
                }
                [void]$sb.AppendLine("</table>")
            }
        }
    }

    # ---- Health ----
    [void]$sb.AppendLine("<h2>Health Check</h2>")
    [void]$sb.AppendLine("<table><tr><th>Severity</th><th>Component</th><th>Status</th><th>Detail</th></tr>")
    foreach ($h in $health) {
        $cls = switch ($h.Severity) { "OK" {"badge-ok"} "WARN" {"badge-warn"} "FAIL" {"badge-fail"} default {"badge-info"} }
        [void]$sb.AppendLine("<tr><td><span class='badge $cls'>$(& $enc $h.Severity)</span></td><td>$(& $enc $h.Component)</td><td>$(& $enc $h.Status)</td><td>$(& $enc $h.Detail)</td></tr>")
    }
    [void]$sb.AppendLine("</table>")

    # ---- Inventory sections (helper) ----
    function Add-Section {
        param($Sb, $Title, $Items, [scriptblock]$Encode)
        if (-not $Items -or @($Items).Count -eq 0) { return }
        [void]$Sb.AppendLine("<h2>$Title</h2>")
        $first = @($Items)[0]
        $keys = if ($first -is [System.Collections.IDictionary]) { @($first.Keys) } else { @($first.PSObject.Properties.Name) }
        [void]$Sb.Append("<table><tr>")
        foreach ($k in $keys) { [void]$Sb.Append("<th>$k</th>") }
        [void]$Sb.AppendLine("</tr>")
        foreach ($it in @($Items)) {
            [void]$Sb.Append("<tr>")
            foreach ($k in $keys) {
                $v = if ($it -is [System.Collections.IDictionary]) { $it[$k] } else { $it.$k }
                [void]$Sb.Append("<td>$(& $Encode $v)</td>")
            }
            [void]$Sb.AppendLine("</tr>")
        }
        [void]$Sb.AppendLine("</table>")
    }

    Add-Section -Sb $sb -Title "System"       -Items @($snap.System)     -Encode $enc
    Add-Section -Sb $sb -Title "Operating System" -Items @($snap.OS)      -Encode $enc
    Add-Section -Sb $sb -Title "BIOS"         -Items @($snap.BIOS)        -Encode $enc
    Add-Section -Sb $sb -Title "Motherboard"  -Items @($snap.BaseBoard)   -Encode $enc
    Add-Section -Sb $sb -Title "CPU"          -Items $snap.CPU            -Encode $enc
    Add-Section -Sb $sb -Title "Memory"       -Items $snap.Memory         -Encode $enc
    Add-Section -Sb $sb -Title "Disks"        -Items $snap.Disks          -Encode $enc
    Add-Section -Sb $sb -Title "GPUs"         -Items $snap.GPUs           -Encode $enc
    Add-Section -Sb $sb -Title "Network Adapters" -Items $snap.NetworkAdapters -Encode $enc
    Add-Section -Sb $sb -Title "Monitors"     -Items $snap.Monitors       -Encode $enc
    if ($snap.Battery)    { Add-Section -Sb $sb -Title "Battery"     -Items @($snap.Battery)    -Encode $enc }
    if ($snap.TPM)        { Add-Section -Sb $sb -Title "TPM"         -Items @($snap.TPM)        -Encode $enc }
    if ($snap.SecureBoot) { Add-Section -Sb $sb -Title "Secure Boot" -Items @($snap.SecureBoot) -Encode $enc }
    if ($snap.ProblemDevices.Count -gt 0) { Add-Section -Sb $sb -Title "Problem Devices" -Items $snap.ProblemDevices -Encode $enc }

    # ---- Events ----
    $evWindow = (Get-HardwareThresholds).EventLookbackDays
    [void]$sb.AppendLine("<h2>Hardware Event Log (last $evWindow days)</h2>")
    if (@($events).Count -eq 0) {
        [void]$sb.AppendLine("<p class='ok'>No hardware error events recorded.</p>")
    } else {
        [void]$sb.AppendLine("<table><tr><th>Time</th><th>Provider</th><th>Level</th><th>Id</th><th>Message</th></tr>")
        foreach ($e in $events | Sort-Object Time -Descending) {
            [void]$sb.AppendLine("<tr><td>$(& $enc ($e.Time.ToString('yyyy-MM-dd HH:mm:ss')))</td><td>$(& $enc $e.Provider)</td><td>$(& $enc $e.Level)</td><td>$(& $enc $e.Id)</td><td>$(& $enc $e.Message)</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    [void]$sb.AppendLine("</body></html>")

    [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    Write-Step "Report written." -Type Success
    Write-Host "    Path: $OutputPath" -ForegroundColor DarkCyan
    Write-Log "Hardware report generated: $OutputPath (health-fail=$healthFail, drift=$diffCount, events=$(@($events).Count))"

    if (-not $NoOpen) {
        try {
            Start-Process $OutputPath -ErrorAction Stop
            Write-Step "Opened in default browser." -Type Info
        } catch {
            Write-Step "Could not auto-open report. Open manually: $OutputPath" -Type Warning
        }
    }
    return $OutputPath
}

# ----------------------------------------------------------------------------
# Menu (simplified - one command = one report)
# ----------------------------------------------------------------------------

function Show-HardwareMenu {
    while ($true) {
        $statusBadge = switch (Test-HardwareBaselineQuickStatus) {
            "OK"     { "BASELINE SET" }
            "TAMPER" { "BASELINE TAMPERED" }
            "NONE"   { "NO BASELINE" }
            default  { "?" }
        }

        $choice = Select-MenuOption -Title "Machine Inspection (used-PC buyer checks)" -Items @(
            @{ Key = "1"; Label = "Generate Inspection Report (inventory + health + buyer red flags)" }
            @{ Separator = $true }
            @{ Key = "2"; Label = "Set / Update Baseline (optional - for owners tracking changes)"; Status = $statusBadge }
            @{ Separator = $true }
            @{ Key = "B"; Label = "Back to Main Menu" }
        )

        switch ($choice) {
            "1" { Invoke-HardwareReport; Pause-Menu }
            "2" {
                if (Confirm-Action "Capture current hardware as the trusted baseline?") {
                    Save-HardwareBaseline -Force
                }
                Pause-Menu
            }
            "B" { return }
        }
    }
}

Export-ModuleMember -Function *
