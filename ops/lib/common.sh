#!/usr/bin/env bash
# =============================================================================
# ops/lib/common.sh — shared helpers for the Lima VM lifecycle scripts
# Sourced by backup_full.sh, delete_full.sh, restore_full.sh.
# Runs on the HOST (macOS / Apple Silicon). NOT meant to be executed directly.
# =============================================================================

# --- Paths -------------------------------------------------------------------
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${OPS_DIR}/.." && pwd)"
K8_DIR="${REPO_ROOT}/k8"
CONFIG_ENV="${K8_DIR}/config.env"

# --- Colors / logging --------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi
info() { printf "%s==>%s %s\n" "$CYAN" "$NC" "$*"; }
ok()   { printf "%s✓%s %s\n"  "$GREEN" "$NC" "$*"; }
warn() { printf "%s!%s %s\n"  "$YELLOW" "$NC" "$*" >&2; }
err()  { printf "%s✗%s %s\n"  "$RED" "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- Config ------------------------------------------------------------------
# Loads k8/config.env and derives all paths/names used by the ops scripts.
load_config() {
  [[ -f "$CONFIG_ENV" ]] || die "config not found: ${CONFIG_ENV}"
  # shellcheck source=/dev/null
  source "$CONFIG_ENV"
  : "${LIMA_VM_NAME:?LIMA_VM_NAME not set in ${CONFIG_ENV}}"

  LIMA_HOME="${LIMA_HOME:-${HOME}/.lima}"          # Lima's data dir (respects $LIMA_HOME)
  VM_DIR="${LIMA_HOME}/${LIMA_VM_NAME}"            # the VM's on-disk state
  BACKUP_ROOT="${STACK_BACKUP_DIR:-${HOME}/lima-stack-backups}"
  VM_BACKUP_DIR="${BACKUP_ROOT}/${LIMA_VM_NAME}"   # per-VM backup root
  LATEST_LINK="${VM_BACKUP_DIR}/latest"            # symlink -> newest timestamped backup
  KUBECONFIG_HOST="${HOME}/.kube/config-${LIMA_VM_NAME}"
  KUBE_CONTEXT="k3s-${LIMA_VM_NAME}"
}

# --- Tooling -----------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found on PATH: $1"; }

# --- VM helpers --------------------------------------------------------------
vm_listed()  { limactl list -q 2>/dev/null | grep -qx "$LIMA_VM_NAME"; }
vm_status()  { limactl list --json 2>/dev/null | jq -r "select(.name==\"${LIMA_VM_NAME}\") | .status" 2>/dev/null; }
vm_running() { [[ "$(vm_status)" == "Running" ]]; }
vm_ip() {
  limactl shell "$LIMA_VM_NAME" ip -4 addr show lima0 2>/dev/null \
    | awk '/inet / {split($2, a, "/"); print a[1]}'
}
vm_stop() {
  vm_running || return 0
  limactl stop "$LIMA_VM_NAME" >/dev/null 2>&1 || limactl stop -f "$LIMA_VM_NAME"
}

# --- APFS / volume helpers ---------------------------------------------------
device_of() { stat -f '%d' "$1" 2>/dev/null; }
same_volume() {
  local a b; a="$(device_of "$1")"; b="$(device_of "$2")"
  [[ -n "$a" && -n "$b" && "$a" == "$b" ]]
}

# Clone every regular file/dir in a Lima VM directory using APFS clonefile
# (cp -c): near-instant, copy-on-write, sparse-exact. Skips runtime sockets,
# pid files and logs (recreated by Lima on start). Requires same APFS volume.
clone_vm_dir() {
  local src="$1" dst="$2" f base
  mkdir -p "$dst"
  for f in "$src"/* "$src"/.[!.]*; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    case "$base" in
      *.sock|*.pid|*.log) continue ;;
    esac
    [[ -S "$f" ]] && continue
    cp -c -p -R "$f" "$dst/$base" \
      || die "clone failed for '${base}' — APFS clonefile requires source and destination on the SAME volume"
  done
}

# Re-generate the host kubeconfig for the VM (same logic as install.sh/stack.sh):
# pull k3s.yaml from the VM, swap 127.0.0.1 -> VM IP and the context name, merge.
regen_kubeconfig() {
  local addr tmp; addr="$(vm_ip)"
  [[ -n "$addr" ]] || { warn "could not determine VM IP — skipping kubeconfig update"; return 1; }
  mkdir -p "$(dirname "$KUBECONFIG_HOST")"
  tmp="${KUBECONFIG_HOST}.k3s-tmp"
  limactl shell "$LIMA_VM_NAME" sudo cat /etc/rancher/k3s/k3s.yaml 2>/dev/null \
    | sed "s/127\.0\.0\.1/${addr}/g" \
    | sed "s/default/${KUBE_CONTEXT}/g" > "$tmp" \
    || { warn "could not read k3s.yaml from the VM"; rm -f "$tmp"; return 1; }
  if [[ -s "$KUBECONFIG_HOST" ]]; then
    KUBECONFIG="${KUBECONFIG_HOST}:${tmp}" kubectl config view --flatten > "${KUBECONFIG_HOST}.merged" 2>/dev/null \
      && mv "${KUBECONFIG_HOST}.merged" "$KUBECONFIG_HOST" && rm -f "$tmp"
  else
    mv "$tmp" "$KUBECONFIG_HOST"
  fi
  chmod 600 "$KUBECONFIG_HOST"
  kubectl config use-context "$KUBE_CONTEXT" >/dev/null 2>&1 || true
  ok "kubeconfig updated (VM IP: ${addr}, context: ${KUBE_CONTEXT})"
}

# Prompt the user to type an exact value; abort (exit 0) on mismatch.
confirm_or_abort() {
  local prompt="$1" expected="$2" reply
  read -r -p "$prompt" reply
  [[ "$reply" == "$expected" ]] || { info "Confirmation did not match — aborted."; exit 0; }
}
