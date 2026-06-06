#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# ops/delete_full.sh — fully delete the Lima VM, KEEPING its backups
# -----------------------------------------------------------------------------
# Removes the VM (stack + all in-VM data) so you can run the installer from
# scratch to test the updated stack. Backups under $STACK_BACKUP_DIR are NOT
# touched. Refuses to run unless a backup exists (override with --force).
#
# Usage: ops/delete_full.sh [--force] [--yes]
#   --force / -f   delete even if no backup is found
#   --yes   / -y   skip the type-the-name confirmation
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
need limactl; need jq

FORCE=false; ASSUME_YES=false
for a in "$@"; do
  case "$a" in
    -f|--force) FORCE=true ;;
    -y|--yes)   ASSUME_YES=true ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $a (see --help)" ;;
  esac
done

if ! vm_listed && [[ ! -e "$VM_DIR" ]]; then
  info "No Lima VM named '${LIMA_VM_NAME}' exists — nothing to delete."
  exit 0
fi

# Safety net: require a backup unless forced.
if [[ -e "$LATEST_LINK" ]]; then
  ok "Backup present: $(cd "$LATEST_LINK" 2>/dev/null && pwd || echo "$LATEST_LINK")"
elif $FORCE; then
  warn "No backup found at ${VM_BACKUP_DIR} — proceeding anyway (--force)."
else
  die "No backup found at ${VM_BACKUP_DIR}. Run ${OPS_DIR}/backup_full.sh first, or pass --force to delete without one."
fi

status="$(vm_status)"; status="${status:-not-running}"
echo
warn "About to DELETE Lima VM '${LIMA_VM_NAME}' (status: ${status})."
warn "The entire stack and ALL data inside the VM will be removed. Backups are kept."
$ASSUME_YES || confirm_or_abort "Type the VM name to confirm deletion [${LIMA_VM_NAME}]: " "$LIMA_VM_NAME"

if vm_running; then info "Stopping VM…"; vm_stop && ok "VM stopped"; fi
info "Deleting VM…"
limactl delete "$LIMA_VM_NAME" >/dev/null 2>&1 || limactl delete -f "$LIMA_VM_NAME" >/dev/null 2>&1 || true
[[ -e "$VM_DIR" ]] && rm -rf "$VM_DIR"
ok "VM '${LIMA_VM_NAME}' deleted"

# kubeconfig cleanup (context/cluster/user are all named after the VM).
kubectl config delete-context "$KUBE_CONTEXT" >/dev/null 2>&1 && ok "  removed kube context ${KUBE_CONTEXT}" || true
kubectl config delete-cluster "$KUBE_CONTEXT" >/dev/null 2>&1 || true
kubectl config delete-user    "$KUBE_CONTEXT" >/dev/null 2>&1 || true

echo
ok "Done. Backup retained — restore with: ${OPS_DIR}/restore_full.sh"
info "You can now run the installer to test a from-scratch deployment."
