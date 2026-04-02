#!/usr/bin/env bash
# =============================================================================
# colors.sh — Shared color definitions and logging functions
# =============================================================================
# Source this file from other scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/colors.sh"
# =============================================================================

# --- Terminal capability detection -------------------------------------------
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  MAGENTA='\033[0;35m'
  BOLD='\033[1m'
  DIM='\033[2m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' NC=''
fi

# --- Logging functions -------------------------------------------------------

log_info() {
  printf "${BLUE}[INFO]${NC}    %s\n" "$*"
}

log_success() {
  printf "${GREEN}[OK]${NC}      %s\n" "$*"
}

log_warn() {
  printf "${YELLOW}[WARN]${NC}    %s\n" "$*"
}

log_error() {
  printf "${RED}[ERROR]${NC}   %s\n" "$*" >&2
}

log_phase() {
  printf "\n${BOLD}${CYAN}========== %s ==========${NC}\n\n" "$*"
}

log_step() {
  printf "${MAGENTA}[STEP]${NC}    %s\n" "$*"
}

log_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    printf "${DIM}[DEBUG]${NC}   %s\n" "$*"
  fi
}

# --- Formatted output helpers ------------------------------------------------

# Print a key-value row: label, value, optional color
print_row() {
  local label="$1" value="$2" color="${3:-$NC}"
  printf "  ${BOLD}%-24s${NC} ${color}%s${NC}\n" "${label}:" "$value"
}

# Print a section header
print_section() {
  printf "\n${BOLD}%s${NC}\n" "$*"
}

# Print a separator line
print_separator() {
  printf "${DIM}%s${NC}\n" "$(printf '%.0s-' {1..60})"
}

# --- Progress indicator ------------------------------------------------------

# Show a spinner while a background process runs
# Usage: run_with_spinner "message" command arg1 arg2 ...
run_with_spinner() {
  local msg="$1"
  shift
  local spin_chars='|/-\'
  local pid

  "$@" &
  pid=$!

  printf "${BLUE}[....]${NC}    %s " "$msg"
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    local c="${spin_chars:i%4:1}"
    printf "\r${BLUE}[%s]${NC}    %s " " ${c} " "$msg"
    i=$((i + 1))
    sleep 0.2
  done

  wait "$pid"
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    printf "\r${GREEN}[OK]${NC}      %s\n" "$msg"
  else
    printf "\r${RED}[FAIL]${NC}    %s\n" "$msg"
  fi
  return $exit_code
}

# --- Banner ------------------------------------------------------------------

print_banner() {
  printf "${BOLD}${CYAN}"
  cat <<'BANNER'

  _  ___   ___       ____  _     _        _ _           _   _
 | |/ / | | __|___  |  _ \(_)___| |_ _ __(_) |__  _   _| |_(_) ___  _ __
 | ' /| |_| _|/ __| | | | | / __| __| '__| | '_ \| | | | __| |/ _ \| '_ \
 | . \|  _  |_\__ \ | |_| | \__ \ |_| |  | | |_) | |_| | |_| | (_) | | | |
 |_|\_\_| |_(_)___/ |____/|_|___/\__|_|  |_|_.__/ \__,_|\__|_|\___/|_| |_|

BANNER
  printf "${NC}"
  printf "${BOLD}  K8s DevOps Stack — Distribution Installer${NC}\n"
  printf "${DIM}  Inspired by Pivotals' Patform Approach${NC}\n\n"
}
