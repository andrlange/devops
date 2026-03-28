#!/usr/bin/env bash
# =============================================================================
# prerequisites.sh — Prerequisite checking functions
# =============================================================================
# Assumes colors.sh has been sourced.
# =============================================================================

# Check if a single command exists, print status
check_command() {
  local cmd="$1"
  local required="${2:-true}"
  if command -v "$cmd" &>/dev/null; then
    log_success "$cmd found: $(command -v "$cmd")"
    return 0
  else
    if [[ "$required" == "true" ]]; then
      log_error "$cmd not found (required)"
    else
      log_warn "$cmd not found (optional)"
    fi
    return 1
  fi
}

# Check minimum version of a command
# Usage: check_version "helm" "3.12" "helm version --short"
check_version() {
  local cmd="$1"
  local min_version="$2"
  local version_cmd="$3"
  local current_version

  if ! command -v "$cmd" &>/dev/null; then
    log_error "$cmd not installed"
    return 1
  fi

  current_version=$(eval "$version_cmd" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  if [[ -z "$current_version" ]]; then
    log_warn "Could not determine $cmd version"
    return 1
  fi

  if version_gte "$current_version" "$min_version"; then
    log_success "$cmd version $current_version (>= $min_version)"
    return 0
  else
    log_error "$cmd version $current_version is below minimum $min_version"
    return 1
  fi
}

# Compare two version strings: returns 0 if $1 >= $2
version_gte() {
  local v1="$1" v2="$2"
  # Use sort -V for version comparison
  local highest
  highest=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -1)
  [[ "$highest" == "$v1" ]]
}

# Validate all required prerequisites for the entire stack
validate_prerequisites() {
  log_phase "Validating Prerequisites"

  local errors=0
  local warnings=0

  # --- Required tools ---
  print_section "Required Tools"
  local required_tools=(limactl kubectl helm jq envsubst)
  for tool in "${required_tools[@]}"; do
    if ! check_command "$tool" "true"; then
      errors=$((errors + 1))
    fi
  done

  # --- Optional tools ---
  print_section "Optional Tools"
  local optional_tools=(velero argocd k9s)
  for tool in "${optional_tools[@]}"; do
    if ! check_command "$tool" "false"; then
      warnings=$((warnings + 1))
    fi
  done

  # --- Version checks ---
  print_section "Version Checks"
  if ! check_version "helm" "3.12" "helm version --short"; then
    errors=$((errors + 1))
  fi
  if ! check_version "kubectl" "1.28" "kubectl version --client --short 2>/dev/null || kubectl version --client -o json | jq -r '.clientVersion.gitVersion'"; then
    errors=$((errors + 1))
  fi

  # --- macOS checks ---
  print_section "System Checks"
  local arch
  arch=$(uname -m)
  if [[ "$arch" == "arm64" ]]; then
    log_success "Apple Silicon detected ($arch)"
  else
    log_warn "Non-ARM architecture detected ($arch) — images may need adjustment"
    warnings=$((warnings + 1))
  fi

  local os
  os=$(uname -s)
  if [[ "$os" == "Darwin" ]]; then
    log_success "macOS detected"
  else
    log_warn "Non-macOS system — Lima VM configuration may need adjustment"
    warnings=$((warnings + 1))
  fi

  # --- Memory check ---
  if [[ "$os" == "Darwin" ]]; then
    local total_mem_gb
    total_mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
    if [[ $total_mem_gb -ge 32 ]]; then
      log_success "System memory: ${total_mem_gb}GB (>= 32GB)"
    else
      log_warn "System memory: ${total_mem_gb}GB (recommend >= 32GB for this stack)"
      warnings=$((warnings + 1))
    fi
  fi

  # --- Disk space check ---
  local avail_gb
  avail_gb=$(df -g / 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
  if [[ $avail_gb -ge 50 ]]; then
    log_success "Available disk space: ${avail_gb}GB (>= 50GB)"
  else
    log_warn "Available disk space: ${avail_gb}GB (recommend >= 50GB)"
    warnings=$((warnings + 1))
  fi

  # --- Connectivity checks ---
  print_section "Connectivity"
  if curl -s --connect-timeout 5 https://get.k3s.io >/dev/null 2>&1; then
    log_success "Internet connectivity OK (k3s.io reachable)"
  else
    log_warn "Cannot reach https://get.k3s.io — offline install may be needed"
    warnings=$((warnings + 1))
  fi

  # --- Summary ---
  echo ""
  print_separator
  if [[ $errors -gt 0 ]]; then
    log_error "Validation failed: $errors error(s), $warnings warning(s)"
    log_info "Install missing tools with: brew install <tool>"
    return 1
  elif [[ $warnings -gt 0 ]]; then
    log_warn "Validation passed with $warnings warning(s)"
    return 0
  else
    log_success "All prerequisites satisfied"
    return 0
  fi
}

# Check if a specific phase's prerequisites are met
check_phase_prerequisites() {
  local phase="$1"
  local state_file="$2"

  case "$phase" in
    1)
      # Phase 1 needs host tools only
      for cmd in limactl kubectl helm jq; do
        if ! command -v "$cmd" &>/dev/null; then
          log_error "Phase 1 requires '$cmd' — install with: brew install $cmd"
          return 1
        fi
      done
      ;;
    2)
      # Phase 2 needs Phase 1 complete
      if ! phase_is_complete 1 "$state_file"; then
        log_error "Phase 2 requires Phase 1 to be complete"
        log_info "Run: ./install.sh phase 1"
        return 1
      fi
      ;;
    3)
      # Phase 3 needs Phase 2 complete
      if ! phase_is_complete 2 "$state_file"; then
        log_error "Phase 3 requires Phase 2 to be complete"
        log_info "Run: ./install.sh phase 2"
        return 1
      fi
      ;;
    4|5)
      if ! phase_is_complete 3 "$state_file"; then
        log_error "Phase $phase requires Phase 3 to be complete"
        log_info "Run: ./install.sh phase 3"
        return 1
      fi
      ;;
    *)
      log_error "Unknown phase: $phase"
      return 1
      ;;
  esac
  return 0
}

# Check if a phase is marked complete in the state file
phase_is_complete() {
  local phase="$1"
  local state_file="$2"
  [[ -f "$state_file" ]] && grep -q "^PHASE_${phase}_COMPLETE=true$" "$state_file"
}

# Mark a phase as complete in the state file
mark_phase_complete() {
  local phase="$1"
  local state_file="$2"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Create or update state file
  if [[ -f "$state_file" ]]; then
    # Remove existing entry if present, then append
    grep -v "^PHASE_${phase}_" "$state_file" > "${state_file}.tmp" || true
    mv "${state_file}.tmp" "$state_file"
  fi

  cat >> "$state_file" <<EOF
PHASE_${phase}_COMPLETE=true
PHASE_${phase}_TIMESTAMP=${timestamp}
EOF

  # Stop phase timer and print timing summary
  if declare -p PHASE_START_TIME &>/dev/null 2>&1; then
    phase_timer_stop "$phase"
    print_phase_timing
  fi
}

# Mark a component as installed within a phase
mark_component_installed() {
  local component="$1"
  local state_file="$2"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [[ -f "$state_file" ]]; then
    grep -v "^COMPONENT_${component}=" "$state_file" > "${state_file}.tmp" || true
    mv "${state_file}.tmp" "$state_file"
  fi

  echo "COMPONENT_${component}=${timestamp}" >> "$state_file"
  log_debug "Marked component $component installed at $timestamp"
}

# Check if a component is already installed
component_is_installed() {
  local component="$1"
  local state_file="$2"
  [[ -f "$state_file" ]] && grep -q "^COMPONENT_${component}=" "$state_file"
}
