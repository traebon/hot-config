#!/bin/bash
# vzdump-backup-register — registers the real, latest Proxmox vzdump snapshot for each of hot-bm-nl's
# 4 VMs into PrivateNexus's own service_backups table.
#
# Built 2026-09-11, closing the last real "backup_policy=daily but zero backup records" gap Mr.
# Byrne flagged: sn-infra/sn-web/sn-monitor/sn-security's real backup mechanism is Proxmox's own
# `daily-fleet-backup-pbs`/`daily-fleet-backup-pbs-sninfra` vzdump jobs (02:00/02:15 daily on
# hot-bm-nl) -- a real, working backup that had simply never told PN about itself, same root gap as
# every other backup script this project has had to close individually (fleet-state-backup.sh,
# backup-gateway-vps.sh, backup-keycloak.sh, pbs-host-backup.sh -- see
# pn_health_and_backup_tracking_fix_2026_09_10 memory).
#
# Runs on the Gateway (only host with fleet-wide SSH reach -- hot-bm-nl has no SSH trust to hot-pn
# at all, confirmed live 2026-09-11, same class of gap pbs-host-backup.sh already found for
# hot-erp-nl): SSHes into hot-bm-nl to ask Proxmox's own `pvesm list` for the real latest snapshot
# per VM (whichever storage currently has one -- pbs-hot preferred, local-backup-zfs as a fallback
# if PBS is unreachable that day, matching this project's own documented interim-fallback pattern),
# then registers it into hot-pn's service_backups via the same direct-psql-over-SSH register_backup
# pattern every other backup script in this fleet already uses.
set -uo pipefail

LOG="/var/log/vzdump-backup-register.log"
NTFY_URL="https://ntfy.house-of-trae.com"
NTFY_TOPIC="hot-alerts"
NTFY_TOKEN_FILE="/etc/apt-daily-update/ntfy_token"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

notify() {
  local priority="$1" title="$2" message="$3"
  [ -f "$NTFY_TOKEN_FILE" ] || return 0
  curl -fsS -m 10 -u ":$(cat "$NTFY_TOKEN_FILE")" \
    -H "X-Title: $title" -H "X-Priority: $priority" \
    -d "$message" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

# vmid -> PN service_id (sn-infra=100, sn-web=102, sn-monitor=104, sn-security=106)
declare -A VMID_TO_SERVICE=(
  [100]="20cebe62-6284-4f86-bf74-037fbec77ccf"
  [102]="445d4941-2e0f-457d-bf24-05094ea8ee59"
  [104]="acaefc90-f48d-4056-9ffd-ab322ae97ad2"
  [106]="777080eb-ab59-412e-8fd2-2a5eb77adc3e"
)
declare -A VMID_TO_SLUG=( [100]="sn-infra" [102]="sn-web" [104]="sn-monitor" [106]="sn-security" )

log "=== vzdump-backup-register START ==="

FAILED=0
for vmid in 100 102 104 106; do
  slug="${VMID_TO_SLUG[$vmid]}"
  service_id="${VMID_TO_SERVICE[$vmid]}"

  # Prefer pbs-hot (the real primary target); fall back to local-backup-zfs if PBS itself is
  # unreachable that day (pvesm list returns nothing/errors rather than hanging when the storage
  # is inactive -- confirmed live 2026-09-11 during a real PBS outage this same script was built to
  # work around).
  latest=""
  storage=""
  for try_storage in pbs-hot local-backup-zfs; do
    entry=$(ssh -o ConnectTimeout=10 -o BatchMode=yes hot-bm-nl \
      "pvesm list $try_storage 2>/dev/null | grep 'vzdump-qemu-${vmid}-' | sort | tail -1")
    if [ -n "$entry" ]; then
      latest="$entry"
      storage="$try_storage"
      break
    fi
  done

  if [ -z "$latest" ]; then
    log "  $slug (VM $vmid): no snapshot found on pbs-hot or local-backup-zfs -- skipping"
    FAILED=1
    continue
  fi

  volid=$(echo "$latest" | awk '{print $1}')
  size_bytes=$(echo "$latest" | awk '{print $4}')
  # volid looks like "pbs-hot:backup/vm/100/2026-09-11T02:00:00Z" or
  # "local-backup-zfs:backup/vzdump-qemu-100-2026_09_11-02_00_00.vma.zst" -- extract a readable date
  snap_date=$(echo "$volid" | grep -oP '\d{4}[-_]\d{2}[-_]\d{2}([T_]\d{2}[:_]\d{2}[:_]\d{2})?' | head -1)

  esc_label="Automated vzdump-backup-register -- ${slug} (VM ${vmid}) ${snap_date}"
  esc_location=$(printf '%s' "$volid" | sed "s/'/''/g")
  sql="INSERT INTO service_backups (tenant_id, service_id, label, backup_type, trust_state, location, size_bytes, notes) VALUES ('10000000-0000-0000-0000-000000000001', '${service_id}', '${esc_label}', 'full', 'trusted', '${esc_location}', ${size_bytes:-NULL}, 'Registered by vzdump-backup-register.sh -- real Proxmox vzdump snapshot on ${storage}, queried live via pvesm list on hot-bm-nl.');"

  if ssh -o ConnectTimeout=10 -o BatchMode=yes hot-pn \
      "docker exec -i privatenexus-db psql -U privatenexus -d privatenexus -v ON_ERROR_STOP=1 -c \"$sql\"" \
      >/tmp/vbr_err 2>&1; then
    log "  $slug (VM $vmid): registered $volid ($storage)"
  else
    log "  $slug (VM $vmid): register FAILED -- $(cat /tmp/vbr_err 2>/dev/null)"
    FAILED=1
  fi
  rm -f /tmp/vbr_err
done

if [ "$FAILED" -eq 1 ]; then
  notify default "vzdump-backup-register: partial failure" "One or more VMs' vzdump snapshot could not be found/registered -- see $LOG."
fi

log "=== vzdump-backup-register DONE ==="
