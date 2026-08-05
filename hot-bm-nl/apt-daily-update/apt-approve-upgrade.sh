#!/bin/bash
# House of Trae — manual apt upgrade approval for hot-bm-nl (Proxmox host).
# Run this by hand after the daily apt-daily-check notification. Never runs
# unattended — hosts all 4 production VMs, a bad pve-kernel/pve-manager bump
# or auto-reboot here would take the whole fleet down at once.
set -uo pipefail

echo "The following packages are upgradable on $(hostname):"
apt list --upgradable 2>/dev/null | grep -v '^Listing'
echo
read -rp "Proceed with 'apt-get upgrade -y'? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted — nothing changed."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade

if [ -f /var/run/reboot-required ]; then
  echo
  echo "⚠ Reboot required to complete this upgrade. NOT rebooting automatically —"
  echo "  reboot hot-bm-nl by hand when convenient (it hosts all 4 production VMs)."
else
  echo
  echo "Done. No reboot required."
fi
