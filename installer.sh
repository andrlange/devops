#!/usr/bin/env bash
# =============================================================================
# installer.sh — K8s DevOps Stack Installer
# =============================================================================
set -euo pipefail

EXPECTED_CHECKSUM="PLACEHOLDER"

# --- Terminal capability detection -------------------------------------------
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
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

# --- Banner ------------------------------------------------------------------

banner() {
  printf "${BOLD}${CYAN}"
  cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  K8s DevOps Stack — Installer v1.0                          ║
║  Pre-flight checks and environment setup                    ║
╚══════════════════════════════════════════════════════════════╝
BANNER
  printf "${NC}\n"
}

# --- Check result helpers ----------------------------------------------------

FAILED_CHECKS=()

pass() {
  local label="$1" detail="$2"
  printf "  ${GREEN}[OK]${NC}   ${BOLD}%-30s${NC} %s\n" "$label" "$detail"
}

fail() {
  local label="$1" detail="$2"
  printf "  ${RED}[FAIL]${NC} ${BOLD}%-30s${NC} %s\n" "$label" "$detail" >&2
  FAILED_CHECKS+=("$label: $detail")
}

# --- Prerequisite checks -----------------------------------------------------

check_macos_version() {
  local required_major=26
  local version
  version=$(sw_vers -productVersion)
  local major
  major=$(echo "$version" | cut -d. -f1)

  if [[ "$major" -ge "$required_major" ]]; then
    pass "macOS version" "$version (>= ${required_major}.0 required)"
  else
    fail "macOS version" "$version (>= ${required_major}.0 required)"
  fi
}

check_apple_chip() {
  local required_gen=4
  local chip_line
  chip_line=$(system_profiler SPHardwareDataType | grep "Chip" || true)

  # Extract the number after "Apple M" — handles "Apple M4", "Apple M5 Pro", "Apple M4 Max", etc.
  local chip_gen
  if [[ "$chip_line" =~ Apple\ M([0-9]+) ]]; then
    chip_gen="${BASH_REMATCH[1]}"
  else
    fail "Apple Chip (M${required_gen}+)" "Could not detect Apple Silicon chip"
    return
  fi

  local chip_label
  chip_label=$(echo "$chip_line" | sed 's/.*Chip: //' | xargs)

  if [[ "$chip_gen" -ge "$required_gen" ]]; then
    pass "Apple Chip (M${required_gen}+)" "${chip_label} (gen ${chip_gen} >= ${required_gen} required)"
  else
    fail "Apple Chip (M${required_gen}+)" "${chip_label} (gen ${chip_gen} < ${required_gen} required)"
  fi
}

check_architecture() {
  local arch
  arch=$(uname -m)

  if [[ "$arch" == "arm64" ]]; then
    pass "Architecture" "$arch"
  else
    fail "Architecture" "$arch (arm64 required)"
  fi
}

check_ram() {
  local required_gb=64
  local memsize_bytes
  memsize_bytes=$(sysctl -n hw.memsize)
  local memsize_gb=$(( memsize_bytes / 1073741824 ))

  if [[ "$memsize_gb" -ge "$required_gb" ]]; then
    pass "RAM" "${memsize_gb}GB (>= ${required_gb}GB required)"
  else
    fail "RAM" "${memsize_gb}GB (>= ${required_gb}GB required)"
  fi
}

check_free_disk() {
  local required_gb=500
  # df -g / outputs: Filesystem 1G-blocks Used Available Capacity iused ifree %iused Mounted
  local available_gb
  available_gb=$(df -g / | awk 'NR==2 {print $4}')

  if [[ "$available_gb" -ge "$required_gb" ]]; then
    pass "Free disk space" "${available_gb}GB available (>= ${required_gb}GB required)"
  else
    fail "Free disk space" "${available_gb}GB available (>= ${required_gb}GB required)"
  fi
}

# --- Main --------------------------------------------------------------------

main() {
  banner

  log_info "Running system prerequisite checks..."
  printf "\n"

  check_macos_version
  check_apple_chip
  check_architecture
  check_ram
  check_free_disk

  printf "\n"

  if [[ "${#FAILED_CHECKS[@]}" -gt 0 ]]; then
    log_error "System prerequisite checks failed:"
    for check in "${FAILED_CHECKS[@]}"; do
      printf "  ${RED}•${NC} %s\n" "$check" >&2
    done
    printf "\n"
    exit 1
  fi

  log_success "All system checks passed."
  printf "\n"
}

main "$@"
