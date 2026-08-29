#requires -RunAsAdministrator
<#
.SYNOPSIS
Enables Wake-on-LAN in UEFI/BIOS and in the Windows 11 network adapter.

.DESCRIPTION
Automatically uses vendor-specific interfaces for supported business PCs:
  Dell   - Dell Command PowerShell Provider or Dell Command Configure (cctk)
  HP     - built-in HP Instrumented BIOS WMI
  Lenovo - built-in Lenovo BIOS WMI
  ASUS   - ASUS Configuration Tool (act.exe)

UEFI does not expose a universal write API. Other vendors therefore require
custom tooling or a model-specific backend.

EXPERIMENTAL NOTE
This script is intended as a proof-of-concept utility and is not fully tested
across all vendor models, firmware variants, or deployment environments.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $Name,
    [SecureString] $BiosPassword,
    [string] $AsusActPath,
    [string] $AsusPasswordFile,
    [switch] $SkipFirmware,
    [switch] $SkipWindowsNic,
    [switch] $ReportOnly
)

$ErrorActionPreference = 'Stop'

function ConvertTo-PlainText([SecureString] $Value) {
    if (-not $Value) { return '' }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Get-ResultText($Result) {
    foreach ($property in 'Return', 'return', 'Status', 'Result') {
        if ($null -ne $Result.$property) { return [string]$Result.$property }
    }
    return [string]$Result
}

function Select-EnabledValue($Setting, [string[]] $Fallback) {
    $possible = @($Setting.PossibleValues | Where-Object { $_ })
    foreach ($candidate in @('Boot to Hard Drive', 'LAN Only', 'LANOnly', 'Enabled', 'Enable', 'On', 'Automatic', 'Primary')) {
        $match = $possible | Where-Object { $_ -ieq $candidate } | Select-Object -First 1
        if ($match) { return $match }
    }
    if ($possible.Count) {
        $match = $possible | Where-Object { $_ -notmatch '(?i)disable|off|pxe|network boot' } | Select-Object -First 1
        if ($match) { return $match }
    }
    return $Fallback[0]
}

function Set-HpFirmwareWol([string] $Password) {
    $namespace = 'root/HP/InstrumentedBIOS'
    $settings = @(Get-CimInstance -Namespace $namespace -ClassName HP_BIOSSetting |
        Where-Object { $_.Name -match '(?i)^wake.+(lan|network)' -and $_.Name -notmatch '(?i)wlan' })
    if (-not $settings.Count) { throw 'HP firmware does not expose any Wake on LAN settings.' }
    if ($ReportOnly) {
        $settings | Select-Object Name, CurrentValue, PossibleValues | Format-List
        return
    }

    $interface = Get-CimInstance -Namespace $namespace -ClassName HP_BIOSSettingInterface | Select-Object -First 1
    foreach ($setting in $settings) {
        $value = Select-EnabledValue $setting @('Boot to Hard Drive')
        if ($PSCmdlet.ShouldProcess("HP UEFI: $($setting.Name)", "set '$value'")) {
            $result = Invoke-CimMethod -InputObject $interface -MethodName SetBIOSSetting -Arguments @{
                Name = $setting.Name
                Value = $value
                Password = if ($Password) { "<utf-16/>$Password" } else { '' }
            }
            $status = Get-ResultText $result
            if ($status -notin @('0', 'Success')) { throw "HP rejected '$($setting.Name)=$value' (status $status)." }
            Write-Host "  HP UEFI: $($setting.Name) = $value"
        }
    }
}

function Set-LenovoFirmwareWol([string] $Password) {
    $namespace = 'root/wmi'
    $settings = @(Get-CimInstance -Namespace $namespace -ClassName Lenovo_BiosSetting | Where-Object {
        $_.CurrentSetting -match '(?i)^wake.+(lan|network),' -and $_.CurrentSetting -notmatch '(?i)wlan'
    })
    if (-not $settings.Count) { throw 'Lenovo firmware does not expose any Wake on LAN settings.' }
    if ($ReportOnly) {
        $settings | Select-Object CurrentSetting | Format-Table -AutoSize
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Lenovo UEFI: Wake on LAN', 'set and save')) { return }

    $setter = Get-CimInstance -Namespace $namespace -ClassName Lenovo_SetBiosSetting | Select-Object -First 1
    $saver = Get-CimInstance -Namespace $namespace -ClassName Lenovo_SaveBiosSettings | Select-Object -First 1
    foreach ($setting in $settings) {
        $settingName = ($setting.CurrentSetting -split ',', 2)[0]
        $success = $false
        foreach ($value in 'Primary', 'Automatic', 'AC Only', 'AC and Battery', 'Enabled', 'Enable') {
            $parameter = if ($Password) { "$settingName,$value,$Password,ascii,us;" } else { "$settingName,$value;" }
            $result = Invoke-CimMethod -InputObject $setter -MethodName SetBiosSetting -Arguments @{ parameter = $parameter }
            $status = Get-ResultText $result
            if ($status -ieq 'Success') {
                Write-Host "  Lenovo UEFI: $settingName = $value"
                $success = $true
                break
            }
            if ($status -notmatch '(?i)invalid parameter') { throw "Lenovo rejected '$settingName' (status $status)." }
        }
        if (-not $success) { throw "Lenovo: no supported enabled value was found for '$settingName'." }
    }
    $saveParameter = if ($Password) { "$Password,ascii,us;" } else { ';' }
    $saved = Invoke-CimMethod -InputObject $saver -MethodName SaveBiosSettings -Arguments @{ parameter = $saveParameter }
    $saveStatus = Get-ResultText $saved
    if ($saveStatus -ine 'Success') { throw "Lenovo did not save the UEFI settings (status $saveStatus)." }
}

function Set-AsusFirmwareWol([string] $Password) {
    $actCandidates = @(
        $AsusActPath,
        (Get-Command act.exe -ErrorAction SilentlyContinue).Source,
        (Join-Path $PSScriptRoot 'act.exe'),
        "$env:ProgramFiles\ASUS\ASUS Configuration Tool\act.exe",
        "$env:ProgramFiles\ASUS\ACT\act.exe",
        "${env:ProgramFiles(x86)}\ASUS\ASUS Configuration Tool\act.exe"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
    $act = $actCandidates | Select-Object -First 1
    if (-not $act) {
        throw 'ASUS requires the official ASUS Configuration Tool (act.exe). Place act.exe next to the script or use -AsusActPath.'
    }
    if ($AsusPasswordFile -and -not (Test-Path -LiteralPath $AsusPasswordFile -PathType Leaf)) {
        throw "ASUS password file does not exist: $AsusPasswordFile"
    }

    if ($ReportOnly) {
        & $act --get --filter '*Wake*LAN*'
        if ($LASTEXITCODE -ne 0) { throw "ASUS ACT report failed (exit code $LASTEXITCODE)." }
        return
    }
    if (-not $PSCmdlet.ShouldProcess('ASUS UEFI: Wake on LAN', 'enable WoL and disable ErP/Max Power Saving')) { return }

    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("wol-enabler-asus-" + [guid]::NewGuid().ToString('N'))
    $jsonPath = Join-Path $temporaryDirectory 'bios-settings.json'
    [void](New-Item -ItemType Directory -Path $temporaryDirectory)
    try {
        $authArguments = @()
        if ($AsusPasswordFile) { $authArguments = @('--pwd', (Resolve-Path -LiteralPath $AsusPasswordFile).Path) }
        elseif ($Password) { $authArguments = @('--pwd', $Password) }

        & $act --get --output $jsonPath @authArguments
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $jsonPath)) {
            throw "ASUS ACT BIOS configuration export failed (exit code $LASTEXITCODE)."
        }
        $configuration = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        $changed = [Collections.Generic.List[string]]::new()

        function Update-AsusJsonNode($Node) {
            if ($null -eq $Node -or $Node -is [string] -or $Node.GetType().IsPrimitive) { return }
            if ($Node -is [Collections.IEnumerable] -and $Node -isnot [Management.Automation.PSCustomObject]) {
                foreach ($child in $Node) { Update-AsusJsonNode $child }
                return
            }

            $properties = @($Node.PSObject.Properties)
            $description = ($properties | Where-Object {
                $_.Value -is [string] -and $_.Name -notin @('#text', '@current')
            } | ForEach-Object { [string]$_.Value }) -join ' '
            $currentProperty = $properties | Where-Object { $_.Name -ieq '@current' } | Select-Object -First 1
            $targetPrompt = $null
            if ($description -match '(?i)(wake\s*on\s*lan|power\s*on\s*by\s*pci-e)' -and $description -notmatch '(?i)wlan') {
                $targetPrompt = 'Enable'
            } elseif ($description -match '(?i)(erp|max(?:imum)?\s*power\s*saving)') {
                $targetPrompt = 'Disable'
            }

            if ($currentProperty -and $targetPrompt) {
                $optionObjects = @($properties | Where-Object { $_.Name -match '(?i)^options?$' } | ForEach-Object { $_.Value })
                $options = @()
                foreach ($optionObject in $optionObjects) {
                    if ($optionObject -is [Collections.IEnumerable] -and $optionObject -isnot [string]) { $options += @($optionObject) }
                    else { $options += $optionObject }
                }
                $selected = $options | Where-Object {
                    $_.PSObject.Properties['@prompt'] -and [string]$_.'@prompt' -match "(?i)^$targetPrompt(?:d)?$"
                } | Select-Object -First 1
                if ($selected -and $selected.PSObject.Properties['#text']) {
                    $newValue = $selected.'#text'
                    if ($currentProperty.Value -is [int] -or $currentProperty.Value -is [long]) { $newValue = [int64]$newValue }
                    $currentProperty.Value = $newValue
                    $changed.Add("$description = $targetPrompt")
                }
            }
            foreach ($property in $properties) { Update-AsusJsonNode $property.Value }
        }

        Update-AsusJsonNode $configuration
        if (-not $changed.Count) {
            throw 'ASUS ACT JSON does not include supported Wake on LAN / Power On By PCI-E settings. This model is not accessible via ACT.'
        }
        $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($jsonPath, ($configuration | ConvertTo-Json -Depth 100), $utf8WithoutBom)
        & $act --set --input $jsonPath @authArguments
        if ($LASTEXITCODE -ne 0) { throw "ASUS ACT write of BIOS configuration failed (exit code $LASTEXITCODE)." }
        $changed | Sort-Object -Unique | ForEach-Object { Write-Host "  ASUS UEFI: $_" }
        $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
        Set-ItemProperty -LiteralPath $powerKey -Name HiberbootEnabled -Value 0
        Write-Host '  Windows: Fast Startup = Disabled (ASUS requirement for WoL after shutdown)'
    } finally {
        if (Test-Path -LiteralPath $temporaryDirectory) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }
}

function Set-DellFirmwareWol([string] $Password) {
    $provider = Get-Module -ListAvailable -Name DellBIOSProvider | Select-Object -First 1
    if ($provider) {
        Import-Module DellBIOSProvider
        $item = Get-Item 'DellSmbios:/PowerManagement/WakeOnLan'
        if ($ReportOnly) { $item | Format-List; return }
        $arguments = @{ Path = 'DellSmbios:/PowerManagement/WakeOnLan'; Value = 'LANOnly'; ErrorAction = 'Stop' }
        if ($Password) { $arguments.Password = $Password }
        if ($PSCmdlet.ShouldProcess('Dell UEFI: WakeOnLan', "set 'LANOnly'")) {
            Set-Item @arguments
            Write-Host '  Dell UEFI: WakeOnLan = LANOnly'
        }
        return
    }

    $cctk = @(
        (Get-Command cctk.exe -ErrorAction SilentlyContinue).Source,
        "$env:ProgramFiles\Dell\Command Configure\X86_64\cctk.exe",
        "${env:ProgramFiles(x86)}\Dell\Command Configure\X86_64\cctk.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $cctk) {
        throw 'Missing Dell Command PowerShell Provider or Dell Command Configure (cctk.exe). Install one in the deployment image.'
    }
    if ($ReportOnly) { & $cctk --wakeonlan; return }
    if (-not $PSCmdlet.ShouldProcess('Dell UEFI: WakeOnLan', 'set via cctk')) { return }

    foreach ($value in 'lanonly', 'enable', 'onboard') {
        $arguments = @("--wakeonlan=$value")
        if ($Password) { $arguments += "--valsetuppwd=$Password" }
        & $cctk @arguments | Write-Host
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Dell UEFI: WakeOnLan = $value"
            return
        }
    }
    throw "Dell Command Configure could not set WakeOnLan (last exit code $LASTEXITCODE)."
}

$system = Get-CimInstance Win32_ComputerSystem
$firmware = Get-CimInstance Win32_BIOS
Write-Host "Computer: $($system.Manufacturer) $($system.Model); BIOS $($firmware.SMBIOSBIOSVersion)"

if (-not $SkipFirmware) {
    $plainPassword = ConvertTo-PlainText $BiosPassword
    try {
        switch -Regex ($system.Manufacturer) {
            'Dell' { Set-DellFirmwareWol $plainPassword; break }
            'HP|Hewlett-Packard' { Set-HpFirmwareWol $plainPassword; break }
            'Lenovo' { Set-LenovoFirmwareWol $plainPassword; break }
            'ASUSTeK|ASUS' { Set-AsusFirmwareWol $plainPassword; break }
            default { throw "Manufacturer '$($system.Manufacturer)' does not yet have a firmware backend in this script." }
        }
    } finally { $plainPassword = $null }
}

if ($ReportOnly -or $SkipWindowsNic) { return }

if (-not $Name) {
    $Name = @(Get-NetAdapter -Physical | Where-Object {
        $_.Status -ne 'Disabled' -and $_.InterfaceDescription -notmatch 'Wi-?Fi|Wireless'
    } | Select-Object -ExpandProperty Name)
}
if (-not $Name) { throw 'No active physical Ethernet adapter was found.' }

foreach ($adapterName in $Name) {
    $adapter = Get-NetAdapter -Name $adapterName
    Write-Host "Windows NIC: $($adapter.Name) ($($adapter.InterfaceDescription))"
    try {
        Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnMagicPacket Enabled
        Write-Host '  WakeOnMagicPacket = Enabled'
    } catch { Write-Warning "The driver does not support the standard power-management API: $($_.Exception.Message)" }

    foreach ($propertyName in 'Wake on Magic Packet', 'Wake on magic packet', 'Wake on LAN', 'Shutdown Wake-On-Lan', 'Wake From Shutdown') {
        foreach ($value in 'Enabled', 'On', 'Yes') {
            try {
                Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $propertyName -DisplayValue $value -NoRestart
                Write-Host "  $propertyName = $value"
                break
            } catch { }
        }
    }
    Restart-NetAdapter -Name $adapter.Name -Confirm:$false
}

Write-Host 'Done. The UEFI change may appear only after the next reboot on some models.'
