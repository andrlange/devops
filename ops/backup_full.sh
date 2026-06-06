#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# ops/backup_full.sh — full, exact, recoverable backup of the Lima VM
# -----------------------------------------------------------------------------
# Captures the ENTIRE stack: the VM disk (k3s + all PV data lives inside it),
# the VM config, Lima's shared SSH keys, and the host-side stack config
# (k8/config.env, k8/.env.local). Uses APFS clonefile — near-instant and
# space-free (copy-on-write) on the same volume.
#
# The VM is stopped for a consistent backup and restarted afterwards if it was
# running. Backups are timestamped under $STACK_BACKUP_DIR (default
# ~/lima-stack-backups) with a 'latest' pointer.
#
# Usage: ops/backup_full.sh
# Env:   STACK_BACKUP_DIR=/path   override backup location (must be same volume)
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
need limactl; need jq

[[ -d "$VM_DIR" ]] || die "no Lima VM directory at ${VM_DIR} — nothing to back up"

mkdir -p "$VM_BACKUP_DIR"
same_volume "$VM_BACKUP_DIR" "$LIMA_HOME" \
  || die "backup dir '${BACKUP_ROOT}' is on a different volume than '${LIMA_HOME}'. APFS clone needs the same volume — set STACK_BACKUP_DIR to a path on the same disk."

TS="$(date +%Y%m%d-%H%M%S)"
DEST="${VM_BACKUP_DIR}/${TS}"
[[ -e "$DEST" ]] && die "backup target already exists: ${DEST}"

disk_alloc="$(du -h "${VM_DIR}/disk" 2>/dev/null | awk '{print $1}')"
info "Backing up VM '${LIMA_VM_NAME}' (disk allocated: ${disk_alloc:-?}) -> ${DEST}"

# Stop for a consistent point-in-time backup; remember prior state.
WAS_RUNNING=false
if vm_running; then
  WAS_RUNNING=true
  info "Stopping VM for a consistent backup…"
  if vm_stop; then ok "VM stopped"; else die "could not stop VM '${LIMA_VM_NAME}'"; fi
fi

mkdir -p "${DEST}/vm" "${DEST}/lima-config" "${DEST}/host-config"

info "Cloning VM disk + config (APFS clonefile)…"
clone_vm_dir "$VM_DIR" "${DEST}/vm"
ok "VM cloned"

# Lima's shared SSH keys (needed so SSH into the restored VM keeps working).
if [[ -d "${LIMA_HOME}/_config" ]]; then
  for f in user user.pub networks.yaml; do
    [[ -f "${LIMA_HOME}/_config/$f" ]] && cp "${LIMA_HOME}/_config/$f" "${DEST}/lima-config/$f"
  done
  ok "Lima SSH keys captured"
fi

# Host-side stack config that does NOT live inside the VM.
for f in config.env .env.local; do
  [[ -f "${K8_DIR}/$f" ]] && cp "${K8_DIR}/$f" "${DEST}/host-config/$f"
done
ok "Host config captured"

# Manifest.
{
  echo "vm_name:          ${LIMA_VM_NAME}"
  echo "timestamp:        ${TS}"
  echo "created:          $(date)"
  echo "host:             $(hostname)"
  echo "repo_root:        ${REPO_ROOT}"
  echo "lima_home:        ${LIMA_HOME}"
  echo "lima_version:     $(cat "${VM_DIR}/lima-version" 2>/dev/null || echo unknown)"
  echo "limactl_version:  $(limactl --version 2>/dev/null | head -1)"
  echo "disk_apparent:    $(ls -lh "${VM_DIR}/disk" 2>/dev/null | awk '{print $5}')"
  echo "disk_allocated:   ${disk_alloc}"
  echo "mount_location:   $(awk '/location:/{print $3; exit}' "${VM_DIR}/lima.yaml" 2>/dev/null | tr -d '\"')"
  echo "kube_context:     ${KUBE_CONTEXT}"
} > "${DEST}/manifest.txt"

ln -sfn "$DEST" "$LATEST_LINK"
ok "Updated 'latest' -> ${TS}"

# Restart if it was running before.
if $WAS_RUNNING; then
  info "Restarting VM (it was running before the backup)…"
  if limactl start "$LIMA_VM_NAME" >/dev/null 2>&1; then
    ok "VM restarted"
    regen_kubeconfig || true
  else
    warn "VM did not restart cleanly — start it manually: limactl start ${LIMA_VM_NAME}"
  fi
fi

size="$(du -sh "$DEST" 2>/dev/null | awk '{print $1}')"
echo
ok "Backup complete"
printf "  Location : %s\n" "$DEST"
printf "  Latest   : %s\n" "$LATEST_LINK"
printf "  Size     : %s  (APFS clone — shares blocks with the live VM until they diverge)\n" "$size"
echo
info "Delete the VM (keeping backups):  ${OPS_DIR}/delete_full.sh"
info "Restore this backup later:        ${OPS_DIR}/restore_full.sh"
