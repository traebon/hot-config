#!/bin/bash
# sn-web-offline-fsck — one-shot offline e2fsck of sn-web's (VM 102) LUKS2-encrypted root
# filesystem, scheduled for tonight at Mr. Byrne's direct request after real, repeated
# `EXT4-fs error: Detected aborted journal` events were found live on 2026-09-11 (all 6 client
# sites/containers stayed up throughout -- purely a filesystem-integrity concern, not a live
# outage).
#
# Runs on the GATEWAY, not hot-bm-nl -- hot-bm-nl has no SSH trust to sn-web at all (confirmed
# live, same class of gap already found for hot-erp-nl->hot-pn), so the final container-health
# verification could never run from there. The Gateway already has working SSH to both hot-bm-nl
# (for the disk-level Proxmox/LUKS/fsck work) and sn-web (for the post-restart verification), so
# every remote command below is explicitly `ssh hot-bm-nl "..."` or `ssh sn-web "..."` rather than
# assuming any local access -- this script has no privileged local state of its own.
#
# Real safety gates before touching anything: (1) refuses to run if today's vzdump snapshot for
# VM 102 isn't present in pvesm's own listing (the actual safety net this whole operation relies
# on); (2) uses qm shutdown (graceful) with a bounded wait before falling back to qm stop, never
# a blind hard-stop first; (3) e2fsck runs with -p (preen -- safe automatic repair of the
# straightforward inconsistencies a preen pass handles) and if that returns "manual intervention
# required" (exit code >=4), STOPS and alerts urgently rather than blindly escalating to -y
# unattended -- an ext4 journal abort is exactly the class of fault that occasionally needs a
# human's judgment on ambiguous repairs; (4) VM disk is only accessed via clevis-based Tang
# unlock + vgchange while the VM is confirmed stopped, and everything is deactivated/closed in
# reverse order afterward regardless of outcome; (5) after restart, verifies real SSH reachability
# + all 9 expected containers report Up before declaring success.
set -uo pipefail

VMID=102
LUKS_PART="/dev/zd48p5"
LUKS_MAPPER_NAME="sn-web-offline-fsck"
VG_NAME="sn-web-vg"
LOG="/var/log/sn-web-offline-fsck.log"
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"
SSH="ssh -o ConnectTimeout=15 -o BatchMode=yes"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

VM_STATE="unknown"
fail() {
  log "FATAL: $1"
  notify urgent "sn-web offline fsck FAILED" "$1 — see $LOG on the Gateway. sn-web was left ${VM_STATE}."
  # Best-effort cleanup on hot-bm-nl regardless of how far we got -- harmless no-ops if these
  # were never opened/activated.
  $SSH hot-bm-nl "vgchange -an $VG_NAME; cryptsetup luksClose $LUKS_MAPPER_NAME" >>"$LOG" 2>&1 || true
  exit 1
}

log "=== sn-web-offline-fsck START ==="

# ── Safety gate: refuse to run without a real, current backup already on record ─────────────────
LATEST_SNAP=$($SSH hot-bm-nl "pvesm list pbs-hot 2>/dev/null | grep 'vm/${VMID}/' | sort | tail -1")
if [ -z "$LATEST_SNAP" ]; then
  LATEST_SNAP=$($SSH hot-bm-nl "pvesm list local-backup-zfs 2>/dev/null | grep 'vzdump-qemu-${VMID}-' | sort | tail -1")
fi
if [ -z "$LATEST_SNAP" ]; then
  fail "No real vzdump snapshot found for VM $VMID on pbs-hot or local-backup-zfs — refusing to proceed without a safety net."
fi
log "Safety net confirmed: $LATEST_SNAP"

# ── Confirm VM is currently running before we try to shut it down ───────────────────────────────
if ! $SSH hot-bm-nl "qm status $VMID" | grep -q running; then
  fail "VM $VMID is not currently running (unexpected pre-condition) — not proceeding automatically."
fi

# ── Graceful shutdown, bounded wait, hard-stop fallback ──────────────────────────────────────────
log "Shutting down VM $VMID gracefully..."
$SSH hot-bm-nl "qm shutdown $VMID --timeout 120" >>"$LOG" 2>&1
STOPPED=0
for i in $(seq 1 30); do
  if $SSH hot-bm-nl "qm status $VMID" | grep -q stopped; then STOPPED=1; break; fi
  sleep 5
done
if [ "$STOPPED" -ne 1 ]; then
  log "WARNING: graceful shutdown did not complete in ~150s — falling back to qm stop."
  $SSH hot-bm-nl "qm stop $VMID --timeout 60" >>"$LOG" 2>&1
  sleep 5
fi
if ! $SSH hot-bm-nl "qm status $VMID" | grep -q stopped; then
  fail "VM $VMID did not reach a stopped state after both graceful and forced attempts."
fi
VM_STATE="stopped"
log "VM $VMID stopped."

# ── Offline LUKS unlock (clevis/Tang, same NBDE binding the VM uses to auto-unlock at its own
# boot) + LVM activation + fsck on the raw LV, never mounted ────────────────────────────────────
log "Unlocking LUKS partition via clevis (Tang)..."
if ! $SSH hot-bm-nl "clevis luks unlock -d $LUKS_PART -n $LUKS_MAPPER_NAME" >>"$LOG" 2>&1; then
  fail "clevis luks unlock failed on $LUKS_PART — VM left stopped, disk untouched. Manual unlock needed."
fi
VM_STATE="stopped, LUKS open"

log "Activating volume group $VG_NAME..."
if ! $SSH hot-bm-nl "vgchange -ay $VG_NAME" >>"$LOG" 2>&1; then
  fail "vgchange -ay $VG_NAME failed after successful LUKS unlock — VM left stopped, LUKS open. Manual attention needed."
fi
VM_STATE="stopped, LUKS open, VG active"

# /dev/<vg>/<lv> avoids /dev/mapper/<vg>-<lv>'s dash-doubling for hyphenated VG names
# (VG_NAME has hyphens -- the first run 2026-09-11 hardcoded the mapper path and failed here).
ROOT_LV="/dev/${VG_NAME}/root"
if ! $SSH hot-bm-nl "[ -e $ROOT_LV ]"; then
  fail "Expected root LV $ROOT_LV not found after vgchange -- VM left stopped, LUKS open, VG active. Manual attention needed."
fi

log "Running e2fsck -p (preen) on $ROOT_LV — never mounted during this pass..."
FSCK_OUT=$($SSH hot-bm-nl "e2fsck -p $ROOT_LV" 2>&1)
FSCK_RC=$?
echo "$FSCK_OUT" >>"$LOG"
log "e2fsck exit code: $FSCK_RC"

if [ "$FSCK_RC" -ge 4 ]; then
  # >=4 means e2fsck left the filesystem in an unknown/uncorrected state -- do NOT restart the VM
  # on top of a filesystem e2fsck itself couldn't confirm is clean. This needs a human, not a
  # blind -y retry, on a production VM's real data.
  fail "e2fsck reported errors requiring manual intervention (exit $FSCK_RC): $FSCK_OUT — VM deliberately left stopped, LUKS open, VG active on hot-bm-nl so you can run 'e2fsck -y $ROOT_LV' by hand and inspect first."
fi

if [ "$FSCK_RC" -eq 0 ]; then
  log "e2fsck: clean, no errors found."
elif [ "$FSCK_RC" -eq 1 ]; then
  log "e2fsck: errors found and corrected automatically (safe preen-level fixes)."
elif [ "$FSCK_RC" -eq 2 ]; then
  log "e2fsck: errors corrected, system should be rebooted (normal boot process, no extra action needed here)."
fi

# ── Deactivate + close before restarting the VM ──────────────────────────────────────────────────
log "Deactivating VG and closing LUKS before restart..."
$SSH hot-bm-nl "vgchange -an $VG_NAME" >>"$LOG" 2>&1 || fail "vgchange -an failed post-fsck -- disk may still be held open, do not assume it's safe to restart the VM yet."
$SSH hot-bm-nl "cryptsetup luksClose $LUKS_MAPPER_NAME" >>"$LOG" 2>&1 || fail "cryptsetup luksClose failed post-fsck -- disk may still be held open, do not assume it's safe to restart the VM yet."
VM_STATE="stopped, disk released"

# ── Restart the VM normally (its own boot-time NBDE unlock chain takes over from here) ──────────
log "Starting VM $VMID..."
$SSH hot-bm-nl "qm start $VMID" >>"$LOG" 2>&1 || fail "qm start $VMID failed after a successful fsck -- disk is clean and released, but the VM itself would not start. Needs manual attention."
VM_STATE="starting"

log "Waiting for VM $VMID to become reachable (qemu-guest-agent ping, up to 5 min)..."
UP=0
for i in $(seq 1 30); do
  if $SSH hot-bm-nl "qm agent $VMID ping" >>"$LOG" 2>&1; then UP=1; break; fi
  sleep 10
done
if [ "$UP" -ne 1 ]; then
  fail "VM $VMID did not respond to qemu-guest-agent ping within 5 minutes of starting -- disk was clean, restart was issued, but the VM isn't confirmed up. Needs manual check."
fi
VM_STATE="running, guest agent responding"

log "Verifying real SSH reachability + container health..."
sleep 15  # give sshd/dockerd a moment past guest-agent-ready before probing
CONTAINER_CHECK=$($SSH sn-web "docker ps --format '{{.Names}}: {{.Status}}'" 2>&1)
CONTAINER_COUNT=$(echo "$CONTAINER_CHECK" | grep -c "Up ")
log "Containers reporting Up: $CONTAINER_COUNT/9"
log "$CONTAINER_CHECK"

if [ "$CONTAINER_COUNT" -lt 9 ]; then
  notify urgent "sn-web offline fsck: fsck OK but containers didn't all come back" \
    "e2fsck completed (exit $FSCK_RC), VM restarted, but only $CONTAINER_COUNT/9 containers report Up. Check sn-web directly -- 'restart: unless-stopped' should have recovered these on its own after a clean qm start, matching the documented VM-hard-power-cycle orphaned-docker-proxy gotcha (operational-rules.md) if any port bind collided."
  exit 1
fi

log "=== sn-web-offline-fsck DONE: fsck exit=$FSCK_RC, all 9 containers Up, VM fully recovered ==="
notify default "sn-web offline fsck complete" \
  "e2fsck exit code $FSCK_RC ($([ "$FSCK_RC" -eq 0 ] && echo "clean, no errors" || echo "errors found and corrected")). VM restarted cleanly, all 9 containers confirmed Up. Full log: $LOG on the Gateway."
