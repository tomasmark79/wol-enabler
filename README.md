# WoL Enabler

> Experimental project. This is a proof-of-concept utility and is not fully tested across hardware, firmware variants, or deployment environments. Use it at your own risk.

The scripts enable Wake-on-LAN (magic packet) in both the UEFI/BIOS and the network adapter. The Windows script supports business-class Dell, HP, Lenovo, and ASUS systems. UEFI does not expose a universal write API, so each vendor requires a vendor-specific backend.

## Windows 11

Open PowerShell as administrator and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\enable-wol.ps1
```

### Read-only status check

The Windows WoL state can be inspected with a separate read-only script:

```powershell
.\get-wol-status.ps1
```

For bulk collection of data:

```powershell
.\get-wol-status.ps1 -AsJson
```

`WindowsStatus: Active` means the adapter is active, the driver has magic packet enabled, and Windows sees it as a device allowed to wake the system. `ShutdownStatus: BlockedByFastStartup` indicates Fast Startup is enabled. `FirmwareStatus: NotVerifiedByWindows` is intentional: the default Windows API does not verify the UEFI state. For firmware validation, use `enable-wol.ps1 -ReportOnly` and the vendor backend.

The `-FailIfNotReady` option returns exit code `2` if any adapter is not ready; this is useful for Intune, SCCM, or other deployment systems.

You can review the discovered firmware settings without writing anything first:

```powershell
.\enable-wol.ps1 -ReportOnly
```

If the UEFI is protected by a password, provide it without storing it in the command history:

```powershell
$biosPassword = Read-Host 'UEFI password' -AsSecureString
.\enable-wol.ps1 -BiosPassword $biosPassword
```

Only a specific adapter: `.\enable-wol.ps1 -Name 'Ethernet'`. Only firmware: `.\enable-wol.ps1 -SkipWindowsNic`.

### Vendor requirements

- **HP Business**: uses the built-in `HP InstrumentedBIOS` WMI.
- **Lenovo ThinkPad/ThinkCentre/ThinkStation**: uses the built-in Lenovo BIOS WMI.
- **Dell business**: the deployment image must include the `Dell Command PowerShell Provider` or `Dell Command Configure` (`cctk.exe`).
- **ASUS commercial**: install the `ASUS BIOS Config Tool` and place `act.exe` on `PATH`, next to the script, or pass `-AsusActPath C:\path\to\act.exe`. ACT is downloaded from the support page for the specific model under the Software and Utility section.

On ASUS systems, the script enables `Wake On LAN` / `Power On By PCI-E`, disables `ErP` or `Max Power Saving` when ACT is available, and disables Windows Fast Startup. These steps are required by ASUS for wake after shutdown.

ASUS firmware only, if ACT is in a different directory:

```powershell
.\enable-wol.ps1 -SkipWindowsNic -AsusActPath 'C:\Program Files\ASUS\ACT\act.exe'
```

ASUS with an ACT encrypted password file:

```powershell
.\enable-wol.ps1 -AsusActPath 'C:\Tools\ACT\act.exe' -AsusPasswordFile 'C:\Tools\ACT\bios-password.bin'
```

Consumer models and other vendors may not expose writable firmware interfaces from Windows. For broad deployment, first run `-ReportOnly` on one device from each model family. If computers are protected by different UEFI passwords, the deployment system must supply them securely.

The script also sets the standard Windows magic packet option and tries common vendor-specific adapter property names.

## Debian/Ubuntu and systemd Linux

```bash
sudo apt update && sudo apt install -y ethtool
sudo ./enable-wol-linux.sh
```

For a single interface, for example `enp3s0`: `sudo ./enable-wol-linux.sh enp3s0`.

## NixOS

One-off (run again after the next boot):

```bash
nix-shell -p ethtool --run 'sudo ./enable-wol-linux.sh enp3s0'
```

Persistently add the following to `configuration.nix` (adjust the interface name):

```nix
environment.systemPackages = [ pkgs.ethtool ];
systemd.services.wol-enp3s0 = {
  description = "Enable Wake-on-LAN";
  wantedBy = [ "multi-user.target" ];
  before = [ "network.target" ];
  serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.ethtool}/bin/ethtool -s enp3s0 wol g"; };
};
```

Then run `sudo nixos-rebuild switch`.

Linux verification: `ethtool enp3s0 | grep Wake-on` should return `Wake-on: g`.
