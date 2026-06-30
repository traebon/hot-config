#!/bin/bash
# Proxmox Planned Maintenance Reboot
# Gracefully shuts down all VMs, reboots host, monitors recovery, sends email

set -euo pipefail
LOG="/var/log/proxmox-maintenance-$(date +%Y%m%d-%H%M%S).log"
MAIL_TO="tristian@securenexus.net"
MAIL_FROM="notifications@house-of-trae.com"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

send_mail() {
  local subj="$1"; local body="$2"
  printf "Subject: %s\nFrom: %s\nTo: %s\n\n%s" "$subj" "$MAIL_FROM" "$MAIL_TO" "$body" \
    | curl -s --ssl-reqd --url "smtp://mail.house-of-trae.com:587" \
        --mail-from "$MAIL_FROM" --mail-rcpt "$MAIL_TO" \
        -u "notifications@house-of-trae.com:$(grep NOTIFICATIONS_PASS /opt/stacks/mailserver/.env 2>/dev/null | cut -d= -f2)" \
        --upload-file - 2>/dev/null || \
    log "WARN: email send failed — check SMTP credentials"
}

log "=== Proxmox Maintenance Reboot Starting ==="

# Step 1: Graceful VM shutdown — qm shutdown accepts ONE vmid at a time
log "Shutting down all VMs (100-106)..."
for vmid in 100 101 102 103 104 105 106; do
  ssh -o StrictHostKeyChecking=no proxmox "qm shutdown $vmid" 2>&1 | tee -a "$LOG" || true
done

# Step 2: Wait up to 6 minutes for VMs to stop
log "Waiting for VMs to stop (max 6 min)..."
for i in $(seq 1 36); do
  sleep 10
  running=$(ssh -o ConnectTimeout=5 proxmox "qm list 2>/dev/null | awk '/running/{count++} END{print count+0}'" 2>/dev/null || echo "0")
  log "  Tick $i/36 — VMs still running: $running"
  [ "$running" -eq 0 ] && { log "All VMs stopped gracefully"; break; }
  [ "$i" -eq 36 ] && log "WARN: VMs still running after 6 min — proceeding with reboot"
done

# Step 3: Reboot Proxmox
log "Issuing reboot to Proxmox host..."
ssh -o ConnectTimeout=5 proxmox "reboot" 2>/dev/null || true
log "SSH disconnected — Proxmox rebooting..."

# Step 4: Wait for Proxmox to come back (up to 13 minutes)
log "Polling for Proxmox recovery..."
for i in $(seq 1 40); do
  sleep 20
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no proxmox "uptime" > /dev/null 2>&1; then
    log "Proxmox is back online (tick $i)"
    break
  fi
  log "  Tick $i/40 — not up yet"
  [ "$i" -eq 40 ] && { log "ERROR: Proxmox did not come back in 13 min"; send_mail "[HoT ALERT] Proxmox did not recover after maintenance reboot" "Proxmox host did not respond within 13 minutes. Manual intervention required. Log: $LOG"; exit 1; }
done

# Step 5: Wait for NBDE unlock and VM auto-start (all 7 VMs need time)
log "Waiting 3 min for NBDE unlock and VM auto-start..."
sleep 180
vm_status=$(ssh -o ConnectTimeout=10 proxmox "qm list" 2>/dev/null || echo "SSH failed")

# Step 5b: Start any VMs that didn't auto-start (NBDE may have taken longer)
stopped_vms=$(ssh -o ConnectTimeout=10 proxmox "qm list 2>/dev/null | awk '/stopped/ && \$1 ~ /^[0-9]+$/ && \$1 < 999 {print \$1}'" 2>/dev/null || echo "")
if [ -n "$stopped_vms" ]; then
  log "VMs still stopped after NBDE window — starting manually: $stopped_vms"
  for vmid in $stopped_vms; do
    ssh -o ConnectTimeout=10 proxmox "qm start $vmid" 2>&1 | tee -a "$LOG" || true
  done
  sleep 30
  vm_status=$(ssh -o ConnectTimeout=10 proxmox "qm list" 2>/dev/null || echo "SSH failed")
fi
log "$vm_status"

# Step 6: Verify pcie_aspm=off is in cmdline
cmdline=$(ssh -o ConnectTimeout=5 proxmox "cat /proc/cmdline" 2>/dev/null || echo "unknown")
kernel=$(ssh -o ConnectTimeout=5 proxmox "uname -r" 2>/dev/null || echo "unknown")
aspm_status=$(echo "$cmdline" | grep -o 'pcie_aspm=off' || echo 'WARNING: pcie_aspm=off NOT FOUND')
log "Kernel cmdline check: $aspm_status"
log "Running kernel: $kernel"

# Step 7: Send completion email
body="Proxmox maintenance reboot completed.

Kernel: $kernel
pcie_aspm: $aspm_status

VM Status:
$vm_status

Full log: $LOG"

send_mail "[HoT] Proxmox maintenance reboot completed" "$body"
log "=== Maintenance complete. Email sent to $MAIL_TO ==="
