#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# ops/restore_full.sh — restore the Lima VM exactly as backed up
# -----------------------------------------------------------------------------
# REFUSES to run if a VM with the configured name already exists (so it never
# clobbers a live VM). Otherwise it clones the backup back into place, restores
# Lima SSH keys + host config if missing, starts the VM, and regenerates the
# host kubeconfig.
#
# Usage: ops/restore_full.sh [BACKUP_DIR | TIMESTAMP]
#   no arg      restore the 'latest' backup
#   TIMESTAMP   e.g. 20260606-201500 (a subdir under the per-VM backup root)
#   BACKUP_DIR  an explicit path to a timestamped backup directory
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
need limactl; need jq

# --- Refuse if a VM already exists (core safety requirement) -----------------
if vm_listed; then
  die "A Lima VM named '${LIMA_VM_NAME}' already exists (status: $(vm_status)). Delete it first: ${OPS_DIR}/delete_full.sh"
fi
[[ -e "$VM_DIR" ]] && die "VM directory already exists (orphan?): ${VM_DIR} — remove it or run ${OPS_DIR}/delete_full.sh first"

# --- Select which backup to restore -----------------------------------------
SEL="${1:-}"
if [[ -z "$SEL" ]]; then
  [[ -e "$LATEST_LINK" ]] || die "no 'latest' backup at ${VM_BACKUP_DIR}; pass a backup path or timestamp explicitly"
  SRC="$(cd "$LATEST_LINK" && pwd)"
elif [[ -d "$SEL" ]]; then
  SRC="$(cd "$SEL" && pwd)"
elif [[ -d "${VM_BACKUP_DIR}/${SEL}" ]]; then
  SRC="$(cd "${VM_BACKUP_DIR}/${SEL}" && pwd)"
else
  die "backup not found: ${SEL}"
fi
[[ -d "${SRC}/vm" ]] || die "invalid backup (missing vm/ directory): ${SRC}"

same_volume "$SRC" "$LIMA_HOME" \
  || die "backup '${SRC}' is on a different volume than '${LIMA_HOME}'. APFS clone restore needs the same volume."

info "Restoring VM '${LIMA_VM_NAME}' from ${SRC}"

clone_vm_dir "${SRC}/vm" "$VM_DIR"
ok "VM disk + config restored to ${VM_DIR}"

# Restore Lima shared SSH keys only if absent (never clobber keys other VMs use).
mkdir -p "${LIMA_HOME}/_config"
if [[ -d "${SRC}/lima-config" ]]; then
  for f in user user.pub networks.yaml; do
    if [[ -f "${SRC}/lima-config/$f" && ! -f "${LIMA_HOME}/_config/$f" ]]; then
      cp "${SRC}/lima-config/$f" "${LIMA_HOME}/_config/$f"; ok "  restored _config/$f"
    fi
  done
fi

# Restore host-side config only if absent (e.g. after a fresh repo checkout).
if [[ -d "${SRC}/host-config" ]]; then
  for f in config.env .env.local; do
    if [[ -f "${SRC}/host-config/$f" && ! -f "${K8_DIR}/$f" ]]; then
      cp "${SRC}/host-config/$f" "${K8_DIR}/$f"; ok "  restored k8/$f"
    fi
  done
fi

# Warn if the VM's host mount path no longer exists (start would fail).
MNT="$(awk '/location:/{print $3; exit}' "${VM_DIR}/lima.yaml" 2>/dev/null | tr -d '"')"
if [[ -n "$MNT" && ! -d "$MNT" ]]; then
  warn "VM mounts host path '${MNT}' which does not exist here — start may fail until that path exists (it is the k8/ dir from the original install)."
fi

info "Starting VM…"
limactl start "$LIMA_VM_NAME"
vm_running || die "VM did not reach Running state — check 'limactl list' and ${VM_DIR}/ha.stderr.log"
ok "VM running"

regen_kubeconfig || warn "kubeconfig not updated automatically — run ./k8/stack.sh start, or set KUBECONFIG manually."

echo
ok "Restore complete — '${LIMA_VM_NAME}' is back exactly as it was backed up."
printf "  Restored from : %s\n" "$SRC"
printf "  KUBECONFIG    : %s  (context %s)\n" "$KUBECONFIG_HOST" "$KUBE_CONTEXT"
echo
info "Verify:  KUBECONFIG=${KUBECONFIG_HOST} kubectl get nodes"
