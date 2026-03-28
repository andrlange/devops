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
║  K8s DevOps Stack — Installer v1.0                           ║
║  Pre-flight checks and environment setup                     ║
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

# --- Tool checking functions -------------------------------------------------

# Compare two version strings: returns 0 if $1 >= $2
version_gte() {
  local v1="$1" v2="$2"
  local highest
  highest=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -1)
  [[ "$highest" == "$v1" ]]
}

# check_tool <name> <command> <min_version>
# min_version can be "" to skip version check
# Returns 0 if present (and version OK), 1 otherwise
# Sets TOOL_VERSION_<cmd> variable with detected version
check_tool() {
  local name="$1" cmd="$2" min_ver="$3"

  if ! command -v "$cmd" &>/dev/null; then
    return 1
  fi

  if [[ -z "$min_ver" ]]; then
    return 0
  fi

  # Detect version based on tool
  local raw_ver=""
  case "$cmd" in
    helm)
      raw_ver=$(helm version --short 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    kubectl)
      raw_ver=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    limactl)
      raw_ver=$(limactl --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    cf)
      raw_ver=$(cf version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    *)
      raw_ver=$("$cmd" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
  esac

  if [[ -z "$raw_ver" ]]; then
    # Cannot determine version — treat as OK (best effort)
    return 0
  fi

  # Store version for display
  printf -v "TOOL_VER_${cmd//-/_}" "%s" "$raw_ver"

  if version_gte "$raw_ver" "$min_ver"; then
    return 0
  else
    return 1
  fi
}

# install_tool <name> <brew_formula>
install_tool() {
  local name="$1" formula="$2"
  log_info "Installing ${name}..."
  if [[ "$formula" == "--cask docker" ]]; then
    brew install --cask docker
  else
    brew install "$formula"
  fi
}

# Get installed version of a command (best effort)
get_tool_version() {
  local cmd="$1"
  local raw_ver=""
  case "$cmd" in
    helm)
      raw_ver=$(helm version --short 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    kubectl)
      raw_ver=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    limactl)
      raw_ver=$(limactl --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    cf)
      raw_ver=$(cf version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    docker)
      raw_ver=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    go)
      raw_ver=$(go version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
    *)
      raw_ver=$("$cmd" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) ;;
  esac
  printf "%s" "$raw_ver"
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

# --- Host tools check --------------------------------------------------------

check_host_tools() {
  # Required tools: name | command | brew formula | min version (empty = any)
  # Format: "name:cmd:formula:minver"
  local required_tools=(
    "Homebrew:brew:__homebrew__:"
    "Docker Desktop:docker:--cask docker:"
    "Lima:limactl:lima:1.0"
    "kubectl:kubectl:kubectl:1.28"
    "Helm:helm:helm:3.12"
    "jq:jq:jq:"
    "envsubst:envsubst:gettext:"
    "skopeo:skopeo:skopeo:"
    "crane:crane:crane:"
    "CF CLI:cf:cloudfoundry/tap/cf-cli@8:8"
  )

  local optional_tools=(
    "Go:go:go:"
    "ArgoCD CLI:argocd:argocd:"
    "Velero CLI:velero:velero:"
    "k9s:k9s:k9s:"
  )

  printf "${BOLD}${CYAN}  Required Tools${NC}\n"
  printf "  %-22s %-12s %s\n" "Tool" "Status" "Version"
  printf "  %s\n" "──────────────────────────────────────────────"

  local missing_required=()
  local docker_was_missing=false

  for entry in "${required_tools[@]}"; do
    local name cmd formula minver
    IFS=: read -r name cmd formula minver <<< "$entry"

    local status_text version_str color
    if command -v "$cmd" &>/dev/null; then
      version_str=$(get_tool_version "$cmd")
      if [[ -n "$minver" && -n "$version_str" ]]; then
        if version_gte "$version_str" "$minver"; then
          status_text="installed"
          color="$GREEN"
        else
          status_text="outdated"
          color="$RED"
          missing_required+=("$name:$cmd:$formula:$minver")
        fi
      else
        status_text="installed"
        color="$GREEN"
        [[ -z "$version_str" ]] && version_str="-"
      fi
    else
      status_text="missing"
      color="$RED"
      version_str="-"
      missing_required+=("$name:$cmd:$formula:$minver")
      [[ "$cmd" == "docker" ]] && docker_was_missing=true
    fi

    printf "  %-22s ${color}%-12s${NC} %s\n" "$name" "$status_text" "${version_str:-−}"
  done

  printf "\n"
  printf "${BOLD}${CYAN}  Optional Tools${NC}\n"
  printf "  %-22s %-12s %s\n" "Tool" "Status" "Version"
  printf "  %s\n" "──────────────────────────────────────────────"

  local missing_optional=()

  for entry in "${optional_tools[@]}"; do
    local name cmd formula minver
    IFS=: read -r name cmd formula minver <<< "$entry"

    local status_text version_str color
    if command -v "$cmd" &>/dev/null; then
      version_str=$(get_tool_version "$cmd")
      status_text="installed"
      color="$GREEN"
      [[ -z "$version_str" ]] && version_str="-"
    else
      status_text="missing"
      color="$YELLOW"
      version_str="-"
      missing_optional+=("$name:$cmd:$formula:$minver")
    fi

    printf "  %-22s ${color}%-12s${NC} %s\n" "$name" "$status_text" "${version_str:-−}"
  done

  printf "\n"

  # --- Homebrew special handling ---
  local brew_missing=false
  for entry in "${missing_required[@]+"${missing_required[@]}"}"; do
    local name cmd
    IFS=: read -r name cmd _ _ <<< "$entry"
    if [[ "$cmd" == "brew" ]]; then
      brew_missing=true
      break
    fi
  done

  if $brew_missing; then
    log_warn "Homebrew is not installed. It is required to install all other tools."
    local ans
    read -rp "  Install Homebrew now? (requires sudo) [Y/n] " ans
    ans="${ans:-Y}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      log_info "Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      log_success "Homebrew installed."
      # Re-run tool check after brew is available
      printf "\n"
      log_info "Re-checking tools now that Homebrew is available..."
      check_host_tools
      return
    else
      log_error "Homebrew is required. Cannot continue without it."
      exit 1
    fi
  fi

  # --- Required tools install prompt ---
  local num_missing="${#missing_required[@]}"
  if [[ "$num_missing" -gt 0 ]]; then
    local ans
    read -rp "  ${BOLD}${num_missing} required tool(s) missing. Install automatically?${NC} [Y/n] " ans
    ans="${ans:-Y}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      local docker_installed=false
      for entry in "${missing_required[@]+"${missing_required[@]}"}"; do
        local name cmd formula minver
        IFS=: read -r name cmd formula minver <<< "$entry"
        [[ "$cmd" == "brew" ]] && continue  # already handled above
        install_tool "$name" "$formula"
        log_success "$name installed."
        [[ "$cmd" == "docker" ]] && docker_installed=true
      done
      if $docker_installed; then
        printf "\n"
        log_warn "Docker Desktop was just installed."
        read -rp "  Please start Docker Desktop, then press Enter to continue..." _
      fi
    else
      printf "\n"
      log_error "The stack cannot be installed without required tools."
      exit 1
    fi
  fi

  # --- Optional tools install prompt ---
  local num_opt_missing="${#missing_optional[@]}"
  if [[ "$num_opt_missing" -gt 0 ]]; then
    local opt_names=()
    for entry in "${missing_optional[@]+"${missing_optional[@]}"}"; do
      local name
      IFS=: read -r name _ _ _ <<< "$entry"
      opt_names+=("$name")
    done
    local opt_list
    opt_list=$(IFS=", "; echo "${opt_names[*]+"${opt_names[*]}"}")
    local ans
    read -rp "  Install optional tools? (${opt_list}) [y/N] " ans
    ans="${ans:-N}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      for entry in "${missing_optional[@]+"${missing_optional[@]}"}"; do
        local name cmd formula minver
        IFS=: read -r name cmd formula minver <<< "$entry"
        install_tool "$name" "$formula"
        log_success "$name installed."
      done
    fi
  fi

  printf "\n"
  log_success "Host tools check complete."
  printf "\n"
}

# --- Registry authentication -------------------------------------------------

REGISTRY_USER=""
REGISTRY_PASS=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_registry_auth() {
  printf "${BOLD}${CYAN}"
  cat <<'REGBANNER'
╔══════════════════════════════════════════════════════════════╗
║  Registry Authentication                                     ║
║                                                              ║
║  This stack uses a private container registry at             ║
║  artifactory.cfapps.cool. You need credentials to proceed.   ║
║                                                              ║
║  Credentials are provided by your administrator.             ║
╚══════════════════════════════════════════════════════════════╝
REGBANNER
  printf "${NC}\n"

  local attempts=0
  local max_attempts=3

  while [[ "$attempts" -lt "$max_attempts" ]]; do
    local username token
    read -rp "  Registry username: " username
    read -rsp "  API Token: " token
    printf "\n"

    if curl -sf -u "${username}:${token}" \
        "https://artifactory.cfapps.cool/v2/token?service=artifact-keeper" \
        >/dev/null 2>&1; then

      # Also log in to Docker if it's running
      if docker info >/dev/null 2>&1; then
        log_info "Docker is running — logging in to registry..."
        if echo "$token" | docker login artifactory.cfapps.cool \
            -u "$username" --password-stdin >/dev/null 2>&1; then
          log_success "Docker login successful."
        else
          log_warn "Docker login failed (non-fatal — continuing)."
        fi
      fi

      REGISTRY_USER="$username"
      REGISTRY_PASS="$token"
      log_success "Registry authentication successful."
      printf "\n"
      return 0
    fi

    attempts=$(( attempts + 1 ))
    if [[ "$attempts" -lt "$max_attempts" ]]; then
      log_error "Authentication failed. Please check your credentials."
      printf "\n"
    fi
  done

  log_error "Authentication failed after ${max_attempts} attempts."
  log_error "Cannot proceed without registry access."
  exit 1
}

# --- Unpack and configure ----------------------------------------------------

unpack_and_configure() {
  printf "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  printf "${BOLD}  Stack Installation${NC}\n"
  printf "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  printf "\n"

  # --- Install directory prompt ---
  local default_dir="${HOME}/devops-stack"
  local install_dir
  read -rp "  Install directory [~/devops-stack]: " install_dir
  install_dir="${install_dir:-$default_dir}"
  # Expand ~ if the user typed it literally
  install_dir="${install_dir/#\~/$HOME}"

  if [[ -d "$install_dir" ]]; then
    local display_dir="${install_dir/#$HOME/~}"
    local ans
    read -rp "  Directory '${display_dir}' already exists. Overwrite? [y/N] " ans
    ans="${ans:-N}"
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
      log_error "Installation aborted."
      exit 1
    fi
    rm -rf "$install_dir"
  fi

  # --- Checksum verification ---
  local tgz="${SCRIPT_DIR}/stack.tgz"
  if [[ ! -f "$tgz" ]]; then
    log_error "stack.tgz not found in ${SCRIPT_DIR}"
    exit 1
  fi

  if [[ "$EXPECTED_CHECKSUM" == "PLACEHOLDER" ]]; then
    log_warn "Checksum verification skipped (development mode)."
  else
    log_info "Verifying stack.tgz checksum..."
    local actual_checksum
    actual_checksum=$(shasum -a 256 "${tgz}" | cut -d' ' -f1)
    if [[ "$actual_checksum" != "$EXPECTED_CHECKSUM" ]]; then
      log_error "Checksum verification failed!"
      log_error "  Expected: ${EXPECTED_CHECKSUM}"
      log_error "  Actual:   ${actual_checksum}"
      exit 1
    fi
    log_success "Checksum verified."
  fi

  # --- Extract ---
  log_info "Extracting stack.tgz..."
  mkdir -p "$install_dir"
  tar xzf "${tgz}" -C "$install_dir"
  log_success "Stack extracted."

  # --- Write .install-config ---
  local config_dir="${install_dir}/k8/distribution"
  mkdir -p "$config_dir"
  cat > "${config_dir}/.install-config" <<EOF
REGISTRY="artifactory.cfapps.cool"
REGISTRY_REPO="docker-local"
REGISTRY_USER="${REGISTRY_USER}"
REGISTRY_PASS="${REGISTRY_PASS}"
EOF
  chmod 600 "${config_dir}/.install-config"
  log_success "Install config written."

  # --- Next steps ---
  local display_dir="${install_dir/#$HOME/~}"
  printf "\n"
  printf "  ${GREEN}✓${NC} Stack unpacked to ${BOLD}${display_dir}${NC}\n"
  printf "\n"
  printf "  Next steps:\n"
  printf "    1. Set up DNS provider (see GETTING_STARTED.md in ${display_dir}/)\n"
  printf "    2. Run the installer:\n"
  printf "       cd ${display_dir}/k8/distribution && ./install.sh\n"
  printf "\n"
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

  # --- Host Tools ---
  printf "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  printf "${BOLD}  Host Tools${NC}\n"
  printf "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  printf "\n"

  check_host_tools

  check_registry_auth
  unpack_and_configure
}

main "$@"
