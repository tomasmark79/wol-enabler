<#
.SYNOPSIS
Read-only Wake-on-LAN status check for Windows 11.

.EXAMPLE
.\get-wol-status.ps1
.\get-wol-status.ps1 -AsJson
.\get-wol-status.ps1 -FailIfNotReady
#>
[CmdletBinding()]
param(
    [string[]] $Name,
    [switch] $AsJson,
    [switch] $FailIfNotReady
)

$ErrorActionPreference = 'Stop'

$system = Get-CimInstance Win32_ComputerSystem
$fastStartupValue = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
$fastStartup = if ($fastStartupValue -eq 0) { 'Disabled' } elseif ($fastStartupValue -eq 1) { 'Enabled' } else { 'Unknown' }

$wakeArmedDevices = @(powercfg.exe /devicequery wake_armed 2>$null) | ForEach-Object { $_.Trim() } | Where-Object { $_ }

if (-not $Name) {
    $Name = @(Get-NetAdapter -Physical | Where-Object {
        $_.InterfaceDescription -notmatch '(?i)Wi-?Fi|Wireless|Bluetooth'
    } | Select-Object -ExpandProperty Name)
}

if (-not $Name) {
    Write-Error 'No physical Ethernet adapter was found.'
    exit 3
}

$report = foreach ($adapterName in $Name) {
    $adapter = Get-NetAdapter -Name $adapterName -ErrorAction Stop
    $power = $null
    try { $power = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction Stop } catch { }

    $advancedWakeProperties = @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -match '(?i)wake|magic|shutdown.*wol|wol.*shutdown' -or
        $_.RegistryKeyword -match '(?i)wake|magic|wol'
    })
    $enabledAdvancedProperties = @($advancedWakeProperties | Where-Object {
        $_.DisplayValue -match '(?i)^enabled$|^on$|^yes$|magic'
    })

    $standardMagicPacket = if ($power -and $null -ne $power.WakeOnMagicPacket) {
        [string]$power.WakeOnMagicPacket
    } else { 'Unsupported' }

    $wakeArmed = @($wakeArmedDevices | Where-Object {
        $_ -eq $adapter.InterfaceDescription -or $_ -like "*$($adapter.InterfaceDescription)*"
    }).Count -gt 0

    $driverReady = $standardMagicPacket -eq 'Enabled' -or $enabledAdvancedProperties.Count -gt 0
    $windowsReady = $adapter.Status -ne 'Disabled' -and $driverReady -and $wakeArmed
    $windowsStatus = if ($windowsReady) { 'Active' } else { 'Inactive' }
    $shutdownStatus = if (-not $windowsReady) {
        'Inactive'
    } elseif ($fastStartup -eq 'Enabled') {
        'BlockedByFastStartup'
    } elseif ($fastStartup -eq 'Disabled') {
        'WindowsReadyFirmwareUnverified'
    } else {
        'UnknownFastStartupState'
    }

    [pscustomobject]@{
        ComputerName          = $env:COMPUTERNAME
        Manufacturer          = $system.Manufacturer
        Model                 = $system.Model
        Adapter               = $adapter.Name
        InterfaceDescription  = $adapter.InterfaceDescription
        MacAddress            = $adapter.MacAddress
        AdapterStatus         = [string]$adapter.Status
        WakeOnMagicPacket     = $standardMagicPacket
        WakeArmed             = $wakeArmed
        FastStartup           = $fastStartup
        WindowsStatus         = $windowsStatus
        WindowsReady          = $windowsReady
        ShutdownStatus        = $shutdownStatus
        FirmwareStatus        = 'NotVerifiedByWindows'
        AdvancedWakeSettings  = ($advancedWakeProperties | ForEach-Object {
            "$($_.DisplayName)=$($_.DisplayValue)"
        }) -join '; '
    }
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 3
} else {
    $report | Format-List ComputerName, Manufacturer, Model, Adapter, InterfaceDescription,
        MacAddress, AdapterStatus, WakeOnMagicPacket, WakeArmed, FastStartup,
        WindowsStatus, WindowsReady, ShutdownStatus, FirmwareStatus, AdvancedWakeSettings
}

if ($FailIfNotReady -and @($report | Where-Object {
    -not $_.WindowsReady -or $_.ShutdownStatus -eq 'BlockedByFastStartup'
}).Count) { exit 2 }
