# WoL enabler

Skripty zapinaji Wake-on-LAN (magic packet) v UEFI i sitovem ovladaci. Windows skript podporuje firemni pocitace Dell, HP, Lenovo a ASUS. UEFI nema univerzalni zapisove API, proto ma kazdy vyrobce vlastni backend.

## Windows 11

Otevrete PowerShell jako spravce a spustte:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\enable-wol.ps1
```

Nejprve lze bez zapisu zobrazit nalezene firmware nastaveni:

```powershell
.\enable-wol.ps1 -ReportOnly
```

Pokud je UEFI chraneno heslem, zadejte ho bez ulozeni do prikazove radky:

```powershell
$biosPassword = Read-Host 'UEFI heslo' -AsSecureString
.\enable-wol.ps1 -BiosPassword $biosPassword
```

Jen pro konkretni adapter: `.\enable-wol.ps1 -Name 'Ethernet'`. Jen firmware: `.\enable-wol.ps1 -SkipWindowsNic`.

### Pozadavky podle vyrobce

- **HP Business**: pouziva vestavene `HP InstrumentedBIOS` WMI.
- **Lenovo ThinkPad/ThinkCentre/ThinkStation**: pouziva vestavene Lenovo BIOS WMI.
- **Dell business**: v deployment image musi byt nainstalovan `Dell Command PowerShell Provider` nebo `Dell Command Configure` (`cctk.exe`).
- **ASUS commercial**: nainstalujte `ASUS BIOS Config Tool` a dejte `act.exe` do `PATH`, vedle skriptu, nebo predejte `-AsusActPath C:\cesta\act.exe`. ACT se stahuje ze support stranky konkretniho modelu v sekci Software and Utility.

U ASUS skript zapne `Wake On LAN` / `Power On By PCI-E`, vypne `ErP` nebo `Max Power Saving`, pokud je ACT zpristupni, a vypne Windows Fast Startup. Tyto kroky ASUS pozaduje pro probuzeni po vypnuti.

ASUS pouze firmware, pokud je ACT v jine ceste:

```powershell
.\enable-wol.ps1 -SkipWindowsNic -AsusActPath 'C:\Program Files\ASUS\ACT\act.exe'
```

ASUS s ACT sifrovanym password souborem:

```powershell
.\enable-wol.ps1 -AsusActPath 'C:\Tools\ACT\act.exe' -AsusPasswordFile 'C:\Tools\ACT\bios-password.bin'
```

Consumer modely a jini vyrobci nemusi z Windows nabizet zapisovatelne firmware rozhrani. Pro hromadne nasazeni nejprve spustte `-ReportOnly` na jednom modelu z kazde modelove rady. Pokud jsou pocitace chranene ruznymi UEFI hesly, musi je deployment system dodat bezpecnym zpusobem.

Skript navic nastavi standardni Windows volbu pro magic packet a zkusi bezne vyrobcem specificke nazvy vlastnosti ovladace.

## Debian/Ubuntu a systemd Linux

```bash
sudo apt update && sudo apt install -y ethtool
sudo ./enable-wol-linux.sh
```

Pro jedno rozhrani, napriklad `enp3s0`: `sudo ./enable-wol-linux.sh enp3s0`.

## NixOS

Jednorazove (a po dalsim bootu znovu spustit):

```bash
nix-shell -p ethtool --run 'sudo ./enable-wol-linux.sh enp3s0'
```

Trvale deklarativne pridejte do `configuration.nix` (upravte nazev rozhrani):

```nix
environment.systemPackages = [ pkgs.ethtool ];
systemd.services.wol-enp3s0 = {
  description = "Enable Wake-on-LAN";
  wantedBy = [ "multi-user.target" ];
  before = [ "network.target" ];
  serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.ethtool}/bin/ethtool -s enp3s0 wol g"; };
};
```

Pak pouzijte `sudo nixos-rebuild switch`.

Kontrola na Linuxu: `ethtool enp3s0 | grep Wake-on` musi vratit `Wake-on: g`.
