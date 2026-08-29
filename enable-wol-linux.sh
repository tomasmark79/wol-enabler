#!/usr/bin/env bash
# Enables WoL magic-packet and creates a systemd service so the setting survives reboot.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root, e.g.: sudo $0" >&2
  exit 1
fi

if ! command -v ethtool >/dev/null; then
  echo "ethtool is missing. Debian/Ubuntu: apt install ethtool; NixOS: nix-shell -p ethtool --run 'sudo $0'" >&2
  exit 1
fi

if (( $# )); then
  interfaces=( "$@" )
else
  mapfile -t interfaces < <(find /sys/class/net -mindepth 1 -maxdepth 1 -type l -printf '%f\n' | while read -r i; do
    [[ "$i" != lo && -e "/sys/class/net/$i/device" ]] && echo "$i"
  done)
fi

(( ${#interfaces[@]} )) || { echo 'No physical network adapter was found.' >&2; exit 1; }

install -d /etc/systemd/system
for interface in "${interfaces[@]}"; do
  [[ -e "/sys/class/net/$interface" ]] || { echo "Interface does not exist: $interface" >&2; exit 1; }
  ethtool -s "$interface" wol g
  cat > "/etc/systemd/system/wol-enabler@$interface.service" <<EOF
[Unit]
Description=Enable Wake-on-LAN for $interface
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
ExecStart=$(command -v ethtool) -s $interface wol g

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable --now "wol-enabler@$interface.service"
  echo "$interface: $(ethtool "$interface" | awk '/Wake-on:/ {print $0}')"
done

echo 'Done. If the machine does not wake after shutdown, enable WoL/PCI-E wake in UEFI and disable ErP/Deep Sleep.'
