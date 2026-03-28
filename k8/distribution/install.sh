#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# install.sh — K8s DevOps Stack Distribution Installer
# =============================================================================
# Master installer inspired by Pivotal Labs' Iteration Zero approach.
#
# Three modes:
#   - Iteration Zero (ZERO): Gather all configuration interactively
#   - Implementation:        Install each phase individually
#   - Operations:            Day-2 management commands
#
# Usage:
#   ./install.sh                  # Interactive full setup
#   ./install.sh zero             # Only Iteration Zero (gather config)
#   ./install.sh phase <N>        # Install specific phase (1-5)
#   ./install.sh status           # Show installation status
#   ./install.sh validate         # Validate prerequisites
# =============================================================================

# --- Resolve paths -----------------------------------------------------------
DIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8_DIR="$(cd "${DIST_DIR}/.." && pwd)"
CONFIG_FILE="${DIST_DIR}/.install-config"
STATE_FILE="${DIST_DIR}/.install-state"

# --- Source libraries --------------------------------------------------------
source "${DIST_DIR}/lib/colors.sh"
source "${DIST_DIR}/lib/prerequisites.sh"
source "${DIST_DIR}/lib/helm.sh"
source "${DIST_DIR}/lib/interactive.sh"

# --- Source project config (defaults) ----------------------------------------
if [[ -f "${K8_DIR}/config.env" ]]; then
  source "${K8_DIR}/config.env"
fi

# =============================================================================
# write_credentials — Generate/update credentials.md with current secrets
# =============================================================================
write_credentials() {
    local cred_file="${K8_DIR}/../credentials.md"
    local domain="${PLATFORM_DOMAIN:-unknown}"

    cat > "$cred_file" <<'CRED_HEADER'
# Stack Credentials

> WARNING: Development environment only — do not use in production

CRED_HEADER

    echo "Generated: $(date '+%Y-%m-%d %H:%M') | Domain: ${domain}" >> "$cred_file"
    echo "" >> "$cred_file"

    # Platform Access section
    cat >> "$cred_file" <<CRED_TABLE
## Platform Access

| Service | URL | Username | Password |
|---------|-----|----------|----------|
CRED_TABLE

    # Phase 1: OpenBao
    if [[ -n "${OPENBAO_ROOT_TOKEN:-}" ]]; then
        cat >> "$cred_file" <<PHASE1

## Infrastructure (Phase 1)

| Service | Details |
|---------|---------|
| OpenBao Root Token | \`${OPENBAO_ROOT_TOKEN}\` |
| OpenBao Unseal Key 1 | \`${OPENBAO_UNSEAL_KEY_1:-}\` |
| OpenBao Unseal Key 2 | \`${OPENBAO_UNSEAL_KEY_2:-}\` |
| OpenBao Unseal Key 3 | \`${OPENBAO_UNSEAL_KEY_3:-}\` |

PHASE1
    fi

    # Phase 2: Platform services
    [[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]] && \
        echo "| ArgoCD | https://argocd.${domain} | admin | \`${ARGOCD_ADMIN_PASSWORD}\` |" >> "$cred_file"
    [[ -n "${GARAGE_ADMIN_KEY:-}" ]] && \
        echo "| Garage S3 | Admin Key: \`${GARAGE_ADMIN_KEY}\` / Secret: \`${GARAGE_ADMIN_SECRET:-}\` | | |" >> "$cred_file"

    # Phase 3: Monitoring
    [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] && \
        echo "| Grafana | https://grafana.${domain} | admin | \`${GRAFANA_ADMIN_PASSWORD}\` |" >> "$cred_file"

    # Phase 4: Services
    [[ -n "${AK_ADMIN_PASSWORD:-}" ]] && \
        echo "| artifact-keeper | https://artifactory.${domain} | admin | \`${AK_ADMIN_PASSWORD}\` |" >> "$cred_file"

    # Phase 5: GitLab
    [[ -n "${GITLAB_ROOT_PASSWORD:-}" ]] && \
        echo "| GitLab | https://gitlab.${domain} | root | \`${GITLAB_ROOT_PASSWORD}\` |" >> "$cred_file"

    chmod 600 "$cred_file"
    log_info "Credentials written to ${cred_file}"
}

# =============================================================================
# get_metallb_ips — Derive platform and apps IPs from METALLB_IP_RANGE
# =============================================================================
get_metallb_platform_ip() {
  echo "${METALLB_IP_RANGE%%-*}"
}
get_metallb_apps_ip() {
  local first_ip="${METALLB_IP_RANGE%%-*}"
  local base="${first_ip%.*}"
  local last="${first_ip##*.}"
  echo "${base}.$((last + 3))"
}

# =============================================================================
# substitute_domains — Replace hardcoded domains across all K8s manifests
# =============================================================================
substitute_domains() {
  log_info "Substituting domains across manifests..."

  local platform_domain="${PLATFORM_DOMAIN:-development.cfapps.cool}"
  local apps_domain="${APPS_DOMAIN:-app.cfapps.cool}"
  local acme_email="${ACME_EMAIL:-admin@cfapps.cool}"

  # Extract base domain from PLATFORM_DOMAIN (e.g., "development.yotta-cloud.net" → "yotta-cloud.net")
  local base_domain="${platform_domain#*.}"
  if [[ -z "$base_domain" ]] || [[ "$base_domain" == "$platform_domain" ]]; then
    base_domain="cfapps.cool"
  fi

  # Skip if domains are still the defaults (no substitution needed)
  if [[ "$platform_domain" == "development.cfapps.cool" ]]; then
    log_info "Using default domains — no substitution needed"
    return 0
  fi

  local count=0
  while IFS= read -r -d '' file; do
    # Skip .install-config and .install-state
    [[ "$file" == *".install-"* ]] && continue

    local changed=false
    if grep -q "development\.cfapps\.cool" "$file" 2>/dev/null; then
      sed -i '' "s/development\.cfapps\.cool/${platform_domain}/g" "$file"
      changed=true
    fi
    if grep -q "app\.cfapps\.cool" "$file" 2>/dev/null; then
      sed -i '' "s/app\.cfapps\.cool/${apps_domain}/g" "$file"
      changed=true
    fi
    if grep -q "admin@cfapps\.cool" "$file" 2>/dev/null; then
      sed -i '' "s/admin@cfapps\.cool/${acme_email}/g" "$file"
      changed=true
    fi
    # Replace bare cfapps.cool in DNS zone configs (cert-manager ClusterIssuer)
    if grep -q '"cfapps\.cool"' "$file" 2>/dev/null; then
      sed -i '' "s/\"cfapps\.cool\"/\"${base_domain}\"/g" "$file"
      changed=true
    fi

    if [[ "$changed" == "true" ]]; then
      count=$((count + 1))
    fi
  done < <(find "${K8_DIR}" -type f \( -name "*.yaml" -o -name "*.yml" -o -name "*.toml" \) -print0)

  # Also update config.env
  sed -i '' \
    -e "s/^PLATFORM_DOMAIN=.*/PLATFORM_DOMAIN=\"${platform_domain}\"/" \
    -e "s/^APPS_DOMAIN=.*/APPS_DOMAIN=\"${apps_domain}\"/" \
    -e "s/^ACME_EMAIL=.*/ACME_EMAIL=\"${acme_email}\"/" \
    "${K8_DIR}/config.env"

  log_success "Domains substituted in ${count} files"
}

# =============================================================================
# Iteration Zero — Gather all configuration interactively
# =============================================================================
cmd_zero() {
  log_phase "Iteration Zero — Configuration Gathering"

  log_info "This will walk you through ALL configuration parameters."
  log_info "Each question has a sensible default shown in [brackets]."
  log_info "Press ENTER to accept the default."
  echo ""

  # Load existing config if present
  if [[ -f "$CONFIG_FILE" ]]; then
    log_warn "Existing configuration found at $CONFIG_FILE"
    if ask_yes_no "Load existing values as defaults?" "y"; then
      source "$CONFIG_FILE"
    fi
  fi

  # -------------------------------------------------------------------------
  # 1. System Settings
  # -------------------------------------------------------------------------
  print_section "1. System Settings"
  echo ""

  local cfg_arch
  cfg_arch=$(ask_choice "Target architecture" "arm64" "amd64")

  local cfg_lima_vm_name
  cfg_lima_vm_name=$(ask "Lima VM name" "${LIMA_VM_NAME:-k3s-server}")

  local cfg_lima_cpus
  while true; do
    cfg_lima_cpus=$(ask "Lima VM CPUs" "${LIMA_CPUS:-8}")
    if validate_integer_range "$cfg_lima_cpus" 2 32 "CPUs"; then break; fi
  done

  local cfg_lima_memory
  while true; do
    cfg_lima_memory=$(ask "Lima VM Memory (GB)" "${LIMA_MEMORY_GB:-48}")
    if validate_integer_range "$cfg_lima_memory" 4 256 "Memory"; then break; fi
  done

  local cfg_lima_disk
  while true; do
    cfg_lima_disk=$(ask "Lima VM Disk (GB)" "${LIMA_DISK_GB:-200}")
    if validate_integer_range "$cfg_lima_disk" 50 2000 "Disk"; then break; fi
  done

  # -------------------------------------------------------------------------
  # 2. Network Settings
  # -------------------------------------------------------------------------
  print_section "2. Network Settings"
  echo ""

  log_info "Network settings will be auto-detected from vzNAT after VM creation."
  log_info "These defaults are used as fallback only."
  echo ""

  local cfg_network_subnet
  cfg_network_subnet=$(ask "Network subnet" "${NETWORK_SUBNET:-192.168.64.0/24}")

  local cfg_network_gateway
  cfg_network_gateway=$(ask "Network gateway" "${NETWORK_GATEWAY:-192.168.64.1}")

  local cfg_metallb_range
  cfg_metallb_range=$(ask "MetalLB IP range" "${METALLB_IP_RANGE:-192.168.64.200-192.168.64.210}")

  # -------------------------------------------------------------------------
  # 3. Domain Settings
  # -------------------------------------------------------------------------
  print_section "3. Domain Settings"
  echo ""

  local cfg_base_domain
  while true; do
    cfg_base_domain=$(ask "Base domain" "${BASE_DOMAIN:-development.cfapps.cool}")
    if validate_domain "$cfg_base_domain"; then break; fi
  done

  local cfg_acme_email
  while true; do
    cfg_acme_email=$(ask "ACME email (for Let's Encrypt)" "${ACME_EMAIL:-admin@cfapps.cool}")
    if validate_email "$cfg_acme_email"; then break; fi
  done

  # -------------------------------------------------------------------------
  # 4. Container Registry
  # -------------------------------------------------------------------------
  print_section "4. Container Registry"
  echo ""

  local cfg_registry
  cfg_registry=$(ask "Registry URL" "${REGISTRY:-artifactory.cfapps.cool}")

  local cfg_registry_repo
  cfg_registry_repo=$(ask "Registry repository" "${REGISTRY_REPO:-docker-local}")

  local cfg_registry_user
  cfg_registry_user=$(ask "Registry username" "${REGISTRY_USER:-}")

  local cfg_registry_pass
  if [[ -n "${REGISTRY_PASS:-}" ]]; then
    log_info "Registry password already set. Enter new or press ENTER to keep."
  fi
  cfg_registry_pass=$(ask_password "Registry password/token")
  if [[ -z "$cfg_registry_pass" ]] && [[ -n "${REGISTRY_PASS:-}" ]]; then
    cfg_registry_pass="$REGISTRY_PASS"
  fi

  # -------------------------------------------------------------------------
  # 5. DNS Provider
  # -------------------------------------------------------------------------
  print_section "5. DNS Provider (for cert-manager DNS-01 challenges)"
  echo ""

  local cfg_dns_provider
  cfg_dns_provider=$(ask_choice "DNS provider" "gcp" "aws" "both")

  local cfg_gcp_project_id=""
  local cfg_gcp_sa_json_path=""
  local cfg_aws_access_key=""
  local cfg_aws_secret_key=""
  local cfg_aws_region=""

  if [[ "$cfg_dns_provider" == "gcp" ]] || [[ "$cfg_dns_provider" == "both" ]]; then
    echo ""
    printf "  ${BOLD}Google Cloud DNS${NC}\n"
    cfg_gcp_project_id=$(ask "GCP Project ID" "${GCP_PROJECT_ID:-cfapps-cool}")
    cfg_gcp_sa_json_path=$(ask_file "GCP Service Account JSON path" "" "optional")
  fi

  if [[ "$cfg_dns_provider" == "aws" ]] || [[ "$cfg_dns_provider" == "both" ]]; then
    echo ""
    printf "  ${BOLD}AWS Route53${NC}\n"
    cfg_aws_access_key=$(ask "AWS Access Key ID" "${AWS_ACCESS_KEY:-}")
    cfg_aws_secret_key=$(ask_password "AWS Secret Access Key")
    cfg_aws_region=$(ask "AWS Region" "${AWS_REGION:-us-east-1}")
  fi

  # -------------------------------------------------------------------------
  # 6. Passwords
  # -------------------------------------------------------------------------
  print_section "6. Service Passwords"
  echo ""

  local cfg_grafana_admin_pass
  cfg_grafana_admin_pass=$(ask_password_or_generate "Grafana admin password" 24)

  # -------------------------------------------------------------------------
  # 7. Storage
  # -------------------------------------------------------------------------
  print_section "7. Storage Settings"
  echo ""

  local cfg_pv_base_path
  cfg_pv_base_path=$(ask "Persistent volume base path" "${PV_BASE_PATH:-/data/persistent}")

  # -------------------------------------------------------------------------
  # Summary and Confirmation
  # -------------------------------------------------------------------------
  local summary_items=(
    "Architecture=${cfg_arch}"
    "Lima VM Name=${cfg_lima_vm_name}"
    "Lima CPUs=${cfg_lima_cpus}"
    "Lima Memory=${cfg_lima_memory}GB"
    "Lima Disk=${cfg_lima_disk}GB"
    "Network Subnet=${cfg_network_subnet}"
    "MetalLB IP Range=${cfg_metallb_range}"
    "Base Domain=${cfg_base_domain}"
    "ACME Email=${cfg_acme_email}"
    "Registry=${cfg_registry}"
    "Registry Repo=${cfg_registry_repo}"
    "Registry Username=${cfg_registry_user}"
    "Registry Password=${cfg_registry_pass}"
    "DNS Provider=${cfg_dns_provider}"
    "GCP Project ID=${cfg_gcp_project_id}"
    "GCP SA JSON=${cfg_gcp_sa_json_path}"
    "AWS Access Key=${cfg_aws_access_key}"
    "AWS Secret Key=${cfg_aws_secret_key}"
    "AWS Region=${cfg_aws_region}"
    "Grafana Admin Password=${cfg_grafana_admin_pass}"
    "PV Base Path=${cfg_pv_base_path}"
  )

  if ! confirm_summary "Configuration Summary" "${summary_items[@]}"; then
    log_warn "Aborted. No changes saved."
    exit 0
  fi

  # -------------------------------------------------------------------------
  # Save configuration
  # -------------------------------------------------------------------------
  cat > "$CONFIG_FILE" <<CFGEOF
# =============================================================================
# K8s DevOps Stack — Install Configuration
# Generated by install.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# WARNING: Contains secrets. Do NOT commit to Git.
# =============================================================================

# --- System ------------------------------------------------------------------
ARCH="${cfg_arch}"
LIMA_VM_NAME="${cfg_lima_vm_name}"
LIMA_CPUS=${cfg_lima_cpus}
LIMA_MEMORY_GB=${cfg_lima_memory}
LIMA_DISK_GB=${cfg_lima_disk}

# --- Network -----------------------------------------------------------------
NETWORK_SUBNET="${cfg_network_subnet}"
NETWORK_GATEWAY="${cfg_network_gateway}"
NETWORK_DNS="${cfg_network_gateway}"
METALLB_IP_RANGE="${cfg_metallb_range}"

# --- Domain ------------------------------------------------------------------
BASE_DOMAIN="${cfg_base_domain}"
ACME_EMAIL="${cfg_acme_email}"

# --- Registry ----------------------------------------------------------------
REGISTRY="${cfg_registry}"
REGISTRY_REPO="${cfg_registry_repo}"
REGISTRY_PULL_SECRET_NAME="artifact-keeper-pull"
REGISTRY_USER="${cfg_registry_user}"
REGISTRY_PASS="${cfg_registry_pass}"

# --- DNS Provider ------------------------------------------------------------
DNS_PROVIDER="${cfg_dns_provider}"
GCP_PROJECT_ID="${cfg_gcp_project_id}"
GCP_SA_JSON_PATH="${cfg_gcp_sa_json_path}"
AWS_ACCESS_KEY="${cfg_aws_access_key}"
AWS_SECRET_KEY="${cfg_aws_secret_key}"
AWS_REGION="${cfg_aws_region}"

# --- Passwords ---------------------------------------------------------------
GRAFANA_ADMIN_PASSWORD="${cfg_grafana_admin_pass}"

# --- Storage -----------------------------------------------------------------
PV_BASE_PATH="${cfg_pv_base_path}"
CFGEOF

  chmod 600 "$CONFIG_FILE"
  log_success "Configuration saved to $CONFIG_FILE"

  # Persist VM name into config.env so stack.sh picks it up without re-sourcing .install-config
  sed -i '' "s/^LIMA_VM_NAME=.*/LIMA_VM_NAME=\"${cfg_lima_vm_name}\"/" "${K8_DIR}/config.env"

  # Substitute domains across all manifests
  substitute_domains
  echo ""
  log_info "Next steps:"
  echo "  1. Review the configuration:  cat ${CONFIG_FILE}"
  echo "  2. Validate prerequisites:    ./install.sh validate"
  echo "  3. Install Phase 1:           ./install.sh phase 1"
  echo ""
}

# =============================================================================
# Load saved configuration
# =============================================================================
load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "No configuration found at $CONFIG_FILE"
    log_info "Run './install.sh zero' first to generate configuration"
    exit 1
  fi
  source "$CONFIG_FILE"
  log_debug "Configuration loaded from $CONFIG_FILE"
}

# =============================================================================
# Phase 1 — Foundation
# =============================================================================
# Lima VM, K3s, OpenBao, ESO, MetalLB, Traefik, cert-manager
# =============================================================================
install_phase_1() {
  log_phase "Phase 1 — Foundation"
  load_config
  check_phase_prerequisites 1 "$STATE_FILE"

  # --- 1.1 Lima VM + K3s ---
  if ! component_is_installed "LIMA_K3S" "$STATE_FILE"; then
    log_step "1.1 — Lima VM + K3s"

    # Check if VM name already exists (prevent accidental overwrite)
    if limactl list --json 2>/dev/null | jq -e --arg name "$LIMA_VM_NAME" 'select(.name == $name)' &>/dev/null; then
      log_error "Lima VM '${LIMA_VM_NAME}' already exists."
      log_error "Choose a different name or delete the existing VM with:"
      log_error "  limactl delete ${LIMA_VM_NAME}"
      log_error "  or: ./k8/stack.sh deletestack"
      exit 1
    fi

    # Create new VM — patch lima.yaml mount path to current k8/ directory
    log_info "Creating Lima VM '${LIMA_VM_NAME}'..."
    local lima_yaml_tmp="${K8_DIR}/bootstrap/lima-${LIMA_VM_NAME}.yaml"
    sed 's|  - location: .*/k8"|  - location: "'"${K8_DIR}"'"|' "${K8_DIR}/bootstrap/lima.yaml" > "$lima_yaml_tmp"
    limactl create --name="$LIMA_VM_NAME" "$lima_yaml_tmp"
    rm -f "$lima_yaml_tmp"
    limactl start "$LIMA_VM_NAME"
    log_success "Lima VM created and started"

    # Get VM IP — use lima0 interface (vzNAT, reachable from host)
    VM_IP=$(limactl shell "$LIMA_VM_NAME" ip -4 addr show lima0 2>/dev/null \
      | awk '/inet / {split($2, a, "/"); print a[1]}')
    if [[ -z "$VM_IP" ]]; then
      # Fallback to first IP
      VM_IP=$(limactl shell "$LIMA_VM_NAME" hostname -I | awk '{print $1}')
    fi
    if [[ -z "$VM_IP" ]]; then
      log_error "Could not determine VM IP address"
      exit 1
    fi
    log_success "VM IP: $VM_IP"

    # Install K3s
    if limactl shell "$LIMA_VM_NAME" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null; then
      log_info "K3s already installed in VM"
    else
      log_info "Installing K3s inside Lima VM..."
      limactl copy "${K8_DIR}/bootstrap/install-k3s.sh" "${LIMA_VM_NAME}:/tmp/install-k3s.sh"
      limactl shell "$LIMA_VM_NAME" chmod +x /tmp/install-k3s.sh
      limactl shell "$LIMA_VM_NAME" /tmp/install-k3s.sh "$VM_IP"
      log_success "K3s installed"
    fi

    # Export kubeconfig — per-VM file to support multiple stacks
    local kubeconfig_file="${HOME}/.kube/config-${LIMA_VM_NAME}"
    mkdir -p "${HOME}/.kube"
    limactl shell "$LIMA_VM_NAME" sudo cat /etc/rancher/k3s/k3s.yaml \
      | sed "s/127\.0\.0\.1/${VM_IP}/g" \
      | sed "s/default/k3s-${LIMA_VM_NAME}/g" \
      > "$kubeconfig_file"
    chmod 600 "$kubeconfig_file"
    export KUBECONFIG="$kubeconfig_file"
    log_success "Kubeconfig written to $kubeconfig_file"

    # Wait for node
    log_info "Waiting for K3s node to become Ready..."
    local attempts=0
    while ! kubectl get nodes --request-timeout=120s 2>/dev/null | grep -q ' Ready'; do
      attempts=$((attempts + 1))
      if [[ $attempts -ge 30 ]]; then
        log_error "K3s node did not become Ready within 60s"
        exit 1
      fi
      sleep 2
    done
    log_success "K3s node is Ready"

    mark_component_installed "LIMA_K3S" "$STATE_FILE"
  else
    log_info "Lima VM + K3s already installed, skipping"
    # Still need to set KUBECONFIG
    export KUBECONFIG="${HOME}/.kube/config-${LIMA_VM_NAME}"
  fi

  # --- 1.2 Pull Secrets ---
  if ! component_is_installed "PULL_SECRETS" "$STATE_FILE"; then
    log_step "1.2 — Bootstrap Pull Secrets"

    if [[ -z "${REGISTRY_USER:-}" ]] || [[ -z "${REGISTRY_PASS:-}" ]]; then
      log_warn "Registry credentials not set in config. Skipping pull secrets."
    else
      local namespaces=("openbao" "external-secrets" "metallb-system" "traefik" "cert-manager")
      for ns in "${namespaces[@]}"; do
        ensure_namespace "$ns"
        if ! kubectl get secret "${REGISTRY_PULL_SECRET_NAME}" -n "$ns" &>/dev/null; then
          kubectl create secret docker-registry "${REGISTRY_PULL_SECRET_NAME}" \
            --docker-server="$REGISTRY" \
            --docker-username="$REGISTRY_USER" \
            --docker-password="$REGISTRY_PASS" \
            -n "$ns"
          log_success "Created pull secret in '$ns'"
        else
          log_info "Pull secret already exists in '$ns'"
        fi
      done

      # Configure containerd registry
      log_info "Configuring containerd registry credentials..."
      limactl shell "$LIMA_VM_NAME" sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<REGEOF
configs:
  "${REGISTRY}":
    auth:
      username: "${REGISTRY_USER}"
      password: "${REGISTRY_PASS}"
    tls:
      insecure_skip_verify: false
REGEOF

      limactl shell "$LIMA_VM_NAME" sudo systemctl restart k3s
      sleep 5
      local attempts=0
      while ! kubectl get nodes &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge 30 ]]; then
          log_error "K3s did not restart within 30s"
          exit 1
        fi
        sleep 1
      done
      log_success "Registry credentials configured"
    fi

    mark_component_installed "PULL_SECRETS" "$STATE_FILE"
  else
    log_info "Pull secrets already configured, skipping"
  fi

  # --- 1.3 OpenBao ---
  if ! component_is_installed "OPENBAO" "$STATE_FILE"; then
    log_step "1.3 — OpenBao"

    ensure_namespace "openbao"
    helm_install_if_needed "openbao" "${K8_DIR}/services/openbao" "openbao"

    log_info "Waiting for OpenBao pod to be Running..."
    wait_for_pod_running "openbao" "app.kubernetes.io/name=openbao" 120

    # --- Automated OpenBao Init & Unseal ---
    log_info "Initializing OpenBao..."

    # Check if already initialized
    local init_status
    init_status=$(kubectl exec -n openbao openbao-0 -- bao status -format=json 2>/dev/null || echo '{"initialized":false}')
    local is_initialized
    is_initialized=$(echo "$init_status" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('initialized', False))" 2>/dev/null || echo "False")

    if [[ "$is_initialized" == "True" ]]; then
      log_info "OpenBao already initialized"
      # Need root token for bootstrap — check if we have it from config or ask
      if [[ -z "${OPENBAO_ROOT_TOKEN:-}" ]]; then
        log_warn "Root token not available (OpenBao was initialized in a prior run)."
        printf "  ${BOLD}OpenBao Root Token${NC}: " >&2
        read -rs OPENBAO_ROOT_TOKEN </dev/tty
        echo "" >&2
        if [[ -z "$OPENBAO_ROOT_TOKEN" ]]; then
          log_error "Root token is required for bootstrapping secrets."
          exit 1
        fi
      fi
    else
      # Initialize with 5 key shares, 3 key threshold
      local init_output
      init_output=$(kubectl exec -n openbao openbao-0 -- bao operator init \
        -key-shares=5 -key-threshold=3 -format=json 2>/dev/null)

      # Extract unseal keys and root token
      OPENBAO_UNSEAL_KEY_1=$(echo "$init_output" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['unseal_keys_b64'][0])")
      OPENBAO_UNSEAL_KEY_2=$(echo "$init_output" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['unseal_keys_b64'][1])")
      OPENBAO_UNSEAL_KEY_3=$(echo "$init_output" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['unseal_keys_b64'][2])")
      OPENBAO_UNSEAL_KEY_4=$(echo "$init_output" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['unseal_keys_b64'][3])")
      OPENBAO_UNSEAL_KEY_5=$(echo "$init_output" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['unseal_keys_b64'][4])")
      OPENBAO_ROOT_TOKEN=$(echo "$init_output" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['root_token'])")

      log_success "OpenBao initialized"
      log_info "Root Token: ${OPENBAO_ROOT_TOKEN}"
    fi

    # Unseal (need 3 of 5 keys) — skip if keys not available (already initialized in prior run)
    local sealed_check
    sealed_check=$(kubectl exec -n openbao openbao-0 -- bao status -format=json 2>/dev/null \
      | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['sealed'])" 2>/dev/null || echo "true")

    if [[ "$sealed_check" == "true" ]]; then
      log_info "Unsealing OpenBao..."
      for key_var in OPENBAO_UNSEAL_KEY_1 OPENBAO_UNSEAL_KEY_2 OPENBAO_UNSEAL_KEY_3; do
        local key="${!key_var:-}"
        if [[ -n "$key" ]]; then
          kubectl exec -n openbao openbao-0 -- bao operator unseal "$key" >/dev/null 2>&1
        fi
      done

      # Verify unsealed after unseal attempt
      local sealed
      sealed=$(kubectl exec -n openbao openbao-0 -- bao status -format=json 2>/dev/null \
        | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['sealed'])" 2>/dev/null || echo "true")
      if [[ "$sealed" == "false" ]]; then
        log_success "OpenBao is unsealed and ready"
      else
        log_error "OpenBao is still sealed. Unseal keys may be missing (was it initialized in a prior run?)."
        log_error "Manually unseal with: kubectl exec -n openbao openbao-0 -- bao operator unseal <key>"
        exit 1
      fi
    else
      log_success "OpenBao is already unsealed"
    fi

    # --- Automated Bootstrap Secrets ---
    log_info "Bootstrapping OpenBao secrets..."

    local BAO="kubectl exec -n openbao openbao-0 --"

    # Login with root token
    $BAO bao login "$OPENBAO_ROOT_TOKEN" >/dev/null 2>&1

    # Enable KV v2 secrets engine
    $BAO bao secrets enable -path=secret kv-v2 2>/dev/null || log_info "KV engine already enabled"

    # Enable Kubernetes auth
    $BAO bao auth enable kubernetes 2>/dev/null || log_info "K8s auth already enabled"
    $BAO bao write auth/kubernetes/config \
      kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR:-kubernetes.default.svc}:443" >/dev/null 2>&1 || \
    $BAO sh -c 'bao write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"' >/dev/null 2>&1

    # Create ESO policy
    $BAO sh -c 'bao policy write external-secrets - <<POLICY
path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }
POLICY' >/dev/null 2>&1

    # Create ESO role
    $BAO bao write auth/kubernetes/role/external-secrets \
      bound_service_account_names=external-secrets \
      bound_service_account_namespaces=external-secrets \
      policies=external-secrets \
      ttl=1h >/dev/null 2>&1

    # Store registry credentials
    $BAO bao kv put secret/k8s/registry \
      server="${REGISTRY}" \
      username="${REGISTRY_USER}" \
      password="${REGISTRY_PASS}" >/dev/null 2>&1
    log_success "Registry credentials stored in OpenBao"

    # Store DNS provider credentials
    if [[ -n "${GCP_SA_JSON_PATH:-}" ]] && [[ -f "${GCP_SA_JSON_PATH:-}" ]]; then
      # Copy GCP credentials JSON into the pod and store in vault
      kubectl cp "${GCP_SA_JSON_PATH}" openbao/openbao-0:/tmp/gcp-creds.json >/dev/null 2>&1
      $BAO sh -c 'bao kv put secret/dns/google-cloud credentials=@/tmp/gcp-creds.json' >/dev/null 2>&1
      $BAO rm -f /tmp/gcp-creds.json >/dev/null 2>&1
      log_success "GCP DNS credentials stored in OpenBao"
    fi

    if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
      $BAO bao kv put secret/dns/aws \
        access_key="${AWS_ACCESS_KEY_ID}" \
        secret_key="${AWS_SECRET_ACCESS_KEY}" \
        region="${AWS_REGION:-us-east-1}" >/dev/null 2>&1
      log_success "AWS DNS credentials stored in OpenBao"
    fi

    # Store Grafana password
    if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
      $BAO bao kv put secret/grafana/admin \
        username=admin \
        password="${GRAFANA_ADMIN_PASSWORD}" >/dev/null 2>&1
      log_success "Grafana credentials stored in OpenBao"
    fi

    log_success "OpenBao bootstrap complete"

    # Update credentials.md
    write_credentials

    mark_component_installed "OPENBAO" "$STATE_FILE"
  else
    log_info "OpenBao already installed, skipping"
  fi

  # --- 1.4 External Secrets Operator ---
  if ! component_is_installed "ESO" "$STATE_FILE"; then
    log_step "1.4 — External Secrets Operator"

    ensure_namespace "external-secrets"
    helm_install_if_needed "external-secrets" "${K8_DIR}/platform/external-secrets" "external-secrets"
    wait_for_pods "external-secrets" 120

    if [[ -f "${K8_DIR}/platform/external-secrets/cluster-secret-store.yaml" ]]; then
      apply_manifest "${K8_DIR}/platform/external-secrets/cluster-secret-store.yaml"
    fi
    if [[ -f "${K8_DIR}/platform/external-secrets/registry-pull-secret.yaml" ]]; then
      apply_manifest "${K8_DIR}/platform/external-secrets/registry-pull-secret.yaml"
    fi

    log_info "Waiting for ClusterSecretStore to become valid..."
    local attempts=0
    while true; do
      local css_status
      css_status=$(kubectl get clustersecretstore -o jsonpath='{.items[0].status.conditions[0].status}' 2>/dev/null || echo "Unknown")
      if [[ "$css_status" == "True" ]]; then
        log_success "ClusterSecretStore is valid"
        break
      fi
      attempts=$((attempts + 1))
      if [[ $attempts -ge 30 ]]; then
        log_warn "ClusterSecretStore did not become valid within 60s. Continuing..."
        break
      fi
      sleep 2
    done

    mark_component_installed "ESO" "$STATE_FILE"
  else
    log_info "ESO already installed, skipping"
  fi

  # --- 1.5 MetalLB ---
  if ! component_is_installed "METALLB" "$STATE_FILE"; then
    log_step "1.5 — MetalLB"

    ensure_namespace "metallb-system"
    helm_install_if_needed "metallb" "${K8_DIR}/infrastructure/metallb" "metallb-system"
    wait_for_pods "metallb-system" 120

    if [[ -f "${K8_DIR}/infrastructure/metallb/ip-pool.yaml" ]]; then
      # Substitute MetalLB IP range from config
      sed "s|192.168.64.200-192.168.64.210|${METALLB_IP_RANGE}|g" \
        "${K8_DIR}/infrastructure/metallb/ip-pool.yaml" | kubectl apply -f -
      log_success "Applied ip-pool.yaml with IP range: ${METALLB_IP_RANGE}"
    fi

    mark_component_installed "METALLB" "$STATE_FILE"

    # Extract first IP from MetalLB range (platform/Traefik) and +3 for apps/Contour
    local metallb_first_ip="${METALLB_IP_RANGE%%-*}"
    local ip_base="${metallb_first_ip%.*}"
    local ip_last_octet="${metallb_first_ip##*.}"
    local apps_ip="${ip_base}.$((ip_last_octet + 3))"

    log_info ""
    log_info "=============================================="
    log_info "  DNS Configuration Required"
    log_info "=============================================="
    log_info ""
    log_info "  Add these DNS records to your DNS provider:"
    log_info ""
    log_info "  *.${PLATFORM_DOMAIN}  ->  A  ${metallb_first_ip}"
    log_info "  *.${APPS_DOMAIN}      ->  A  ${apps_ip}"
    log_info ""
    log_info "  (MetalLB assigns IPs sequentially from ${METALLB_IP_RANGE})"
    log_info ""
    log_info "=============================================="
    log_info ""
    read -rp "  Press ENTER when DNS records have been configured... " </dev/tty
  else
    log_info "MetalLB already installed, skipping"
  fi

  # --- 1.6 Traefik ---
  if ! component_is_installed "TRAEFIK" "$STATE_FILE"; then
    log_step "1.6 — Traefik"

    ensure_namespace "traefik"
    helm_install_if_needed "traefik" "${K8_DIR}/infrastructure/traefik" "traefik"

    log_info "Waiting for Traefik LoadBalancer IP..."
    local lb_ip
    lb_ip=$(get_lb_ip "traefik" "traefik" 60 || echo "")
    if [[ -n "$lb_ip" ]]; then
      log_success "Traefik LoadBalancer IP: $lb_ip"
      echo ""
      echo "  Add to your DNS or /etc/hosts:"
      echo "  $lb_ip  *.${BASE_DOMAIN}"
    else
      log_warn "No LoadBalancer IP assigned yet"
    fi

    mark_component_installed "TRAEFIK" "$STATE_FILE"
  else
    log_info "Traefik already installed, skipping"
  fi

  # --- 1.7 cert-manager ---
  if ! component_is_installed "CERTMANAGER" "$STATE_FILE"; then
    log_step "1.7 — cert-manager"

    ensure_namespace "cert-manager"
    helm_install_if_needed "cert-manager" "${K8_DIR}/infrastructure/cert-manager" "cert-manager"
    wait_for_pods "cert-manager" 120

    if [[ -f "${K8_DIR}/infrastructure/cert-manager/dns-external-secret.yaml" ]]; then
      apply_manifest "${K8_DIR}/infrastructure/cert-manager/dns-external-secret.yaml"
      sleep 5
    fi

    export GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"
    if [[ -f "${K8_DIR}/infrastructure/cert-manager/clusterissuer.yaml" ]]; then
      apply_manifest_envsubst "${K8_DIR}/infrastructure/cert-manager/clusterissuer.yaml"
    fi

    if [[ -f "${K8_DIR}/infrastructure/cert-manager/wildcard-certificate.yaml" ]]; then
      apply_manifest "${K8_DIR}/infrastructure/cert-manager/wildcard-certificate.yaml"
    fi

    # Apply TLS store
    if [[ -f "${K8_DIR}/infrastructure/traefik/tls-store.yaml" ]]; then
      apply_manifest "${K8_DIR}/infrastructure/traefik/tls-store.yaml"
    fi

    mark_component_installed "CERTMANAGER" "$STATE_FILE"
  else
    log_info "cert-manager already installed, skipping"
  fi

  # --- 1.8 Kubernetes Reflector (cross-namespace secret sync) ---
  if ! component_is_installed "REFLECTOR" "$STATE_FILE"; then
    log_step "1.8 — Kubernetes Reflector"
    helm repo add emberstack https://emberstack.github.io/helm-charts 2>/dev/null || true
    helm install reflector emberstack/reflector -n kube-system 2>&1 | tail -1
    wait_for_pods "kube-system" 60

    # Annotate wildcard-apps cert for reflection to korifi namespace
    if kubectl get secret wildcard-apps-tls -n traefik &>/dev/null; then
      kubectl annotate secret wildcard-apps-tls -n traefik \
        reflector.v1.k8s.emberstack.com/reflection-allowed="true" \
        reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces="korifi" \
        reflector.v1.k8s.emberstack.com/reflection-auto-enabled="true" \
        reflector.v1.k8s.emberstack.com/reflection-auto-namespaces="korifi" \
        --overwrite 2>&1 | tail -1
    fi

    log_success "Kubernetes Reflector installed"
    mark_component_installed "REFLECTOR" "$STATE_FILE"
  else
    log_info "Kubernetes Reflector already installed, skipping"
  fi

  write_credentials
  mark_phase_complete 1 "$STATE_FILE"
  log_success "Phase 1 — Foundation complete"
  echo ""
  log_info "Next step: ./install.sh phase 2"
  echo ""
}

# =============================================================================
# Phase 2 — Platform
# =============================================================================
# ArgoCD, Portainer, Garage, Technitium, Velero
# =============================================================================
install_phase_2() {
  log_phase "Phase 2 — Platform"
  load_config
  check_phase_prerequisites 2 "$STATE_FILE"
  export KUBECONFIG="${HOME}/.kube/config-${LIMA_VM_NAME}"

  # --- 2.1 ArgoCD ---
  if ! component_is_installed "ARGOCD" "$STATE_FILE"; then
    log_step "2.1 — ArgoCD"
    ensure_namespace "argocd"

    if [[ -d "${K8_DIR}/platform/argocd" ]]; then
      helm_install_if_needed "argocd" "${K8_DIR}/platform/argocd" "argocd"
      wait_for_pods "argocd" 180
      log_success "ArgoCD installed"
    else
      log_warn "ArgoCD chart not found at ${K8_DIR}/platform/argocd — skipping"
    fi

    mark_component_installed "ARGOCD" "$STATE_FILE"
  else
    log_info "ArgoCD already installed, skipping"
  fi

  # --- 2.2 Portainer ---
  if ! component_is_installed "PORTAINER" "$STATE_FILE"; then
    log_step "2.2 — Portainer"
    ensure_namespace "portainer"

    if [[ -d "${K8_DIR}/platform/portainer" ]]; then
      helm_install_if_needed "portainer" "${K8_DIR}/platform/portainer" "portainer"
      wait_for_pods "portainer" 120
      log_success "Portainer installed"
    else
      log_warn "Portainer chart not found at ${K8_DIR}/platform/portainer — skipping"
    fi

    mark_component_installed "PORTAINER" "$STATE_FILE"
  else
    log_info "Portainer already installed, skipping"
  fi

  # --- 2.3 Garage (S3-compatible storage) ---
  if ! component_is_installed "GARAGE" "$STATE_FILE"; then
    log_step "2.3 — Garage"
    ensure_namespace "garage"

    # Generate Garage secrets if not already set
    local garage_rpc_secret
    garage_rpc_secret=$(openssl rand -hex 32)
    local garage_admin_token
    garage_admin_token=$(openssl rand -hex 32)

    # Patch ConfigMap with generated secrets and correct domains before applying
    sed -i '' \
      -e "s/rpc_secret = .*/rpc_secret = \"${garage_rpc_secret}\"/" \
      -e "s/admin_token = .*/admin_token = \"${garage_admin_token}\"/" \
      "${K8_DIR}/platform/garage/configmap.yaml"

    smart_install "garage" "${K8_DIR}/platform/garage" "garage"
    wait_for_pods "garage" 180

    # Wait for Garage admin API to be reachable
    log_info "Waiting for Garage admin API..."
    local BAO="kubectl exec -n openbao openbao-0 --"
    local garage_api="http://garage.garage.svc:3903"
    local attempts=0
    while ! kubectl exec -n garage garage-0 -- curl -sf "${garage_api}/health" &>/dev/null; do
      attempts=$((attempts + 1))
      if [[ $attempts -ge 60 ]]; then
        log_warn "Garage admin API not reachable after 60s. Continuing..."
        break
      fi
      sleep 2
    done

    # Configure Garage node layout
    log_info "Configuring Garage node layout..."
    local node_id
    node_id=$(kubectl exec -n garage garage-0 -- curl -sf \
      -H "Authorization: Bearer ${garage_admin_token}" \
      "${garage_api}/v1/status" 2>/dev/null | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['node'])" 2>/dev/null || echo "")

    if [[ -n "$node_id" ]]; then
      kubectl exec -n garage garage-0 -- curl -sf -X POST \
        -H "Authorization: Bearer ${garage_admin_token}" \
        -H "Content-Type: application/json" \
        -d "[{\"id\":\"${node_id}\",\"zone\":\"dc1\",\"capacity\":214748364800,\"tags\":[\"node1\"]}]" \
        "${garage_api}/v1/layout" >/dev/null 2>&1

      # Apply layout
      local layout_version
      layout_version=$(kubectl exec -n garage garage-0 -- curl -sf \
        -H "Authorization: Bearer ${garage_admin_token}" \
        "${garage_api}/v1/layout" 2>/dev/null | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['version'])" 2>/dev/null || echo "1")
      kubectl exec -n garage garage-0 -- curl -sf -X POST \
        -H "Authorization: Bearer ${garage_admin_token}" \
        -H "Content-Type: application/json" \
        -d "{\"version\":${layout_version}}" \
        "${garage_api}/v1/layout/apply" >/dev/null 2>&1
      log_success "Garage node layout configured"
    fi

    # Create S3 API keys for all services and store in OpenBao
    log_info "Creating Garage S3 API keys..."
    local BAO="kubectl exec -n openbao openbao-0 --"
    $BAO bao login "${OPENBAO_ROOT_TOKEN:-}" >/dev/null 2>&1 || true

    for svc_name in admin loki mimir tempo velero artifacts; do
      local key_response
      key_response=$(kubectl exec -n garage garage-0 -- curl -sf -X POST \
        -H "Authorization: Bearer ${garage_admin_token}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${svc_name}\"}" \
        "${garage_api}/v1/key" 2>/dev/null || echo "")

      if [[ -n "$key_response" ]]; then
        local ak sk
        ak=$(echo "$key_response" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['accessKeyId'])" 2>/dev/null)
        sk=$(echo "$key_response" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['secretAccessKey'])" 2>/dev/null)

        if [[ -n "$ak" ]] && [[ -n "$sk" ]]; then
          $BAO bao kv put "secret/garage/${svc_name}" \
            access_key="$ak" secret_key="$sk" >/dev/null 2>&1
          log_success "Garage S3 key '${svc_name}' created and stored in OpenBao"

          # Create buckets for each service
          local bucket_name="${svc_name}"
          [[ "$svc_name" == "admin" ]] && bucket_name="" # Skip bucket for admin key
          if [[ -n "$bucket_name" ]]; then
            kubectl exec -n garage garage-0 -- curl -sf -X PUT \
              -H "Authorization: Bearer ${garage_admin_token}" \
              "${garage_api}/v1/bucket" \
              -H "Content-Type: application/json" \
              -d "{\"globalAlias\":\"${bucket_name}\"}" >/dev/null 2>&1 || true
          fi
        fi
      fi
    done

    # Store admin token in OpenBao
    $BAO bao kv put "secret/garage/admin-token" \
      token="${garage_admin_token}" >/dev/null 2>&1
    log_success "Garage admin token stored in OpenBao"

    log_success "Garage installed and bootstrapped"
    mark_component_installed "GARAGE" "$STATE_FILE"
  else
    log_info "Garage already installed, skipping"
  fi

  # --- 2.4 Technitium DNS ---
  if ! component_is_installed "TECHNITIUM" "$STATE_FILE"; then
    log_step "2.4 — Technitium DNS"
    ensure_namespace "technitium"

    if [[ -d "${K8_DIR}/platform/technitium" ]]; then
      smart_install "technitium" "${K8_DIR}/platform/technitium" "technitium"
      wait_for_pods "technitium" 120
      log_success "Technitium DNS installed"
    else
      log_warn "Technitium chart not found at ${K8_DIR}/platform/technitium — skipping"
    fi

    mark_component_installed "TECHNITIUM" "$STATE_FILE"
  else
    log_info "Technitium DNS already installed, skipping"
  fi

  # --- 2.5 Velero ---
  if ! component_is_installed "VELERO" "$STATE_FILE"; then
    log_step "2.5 — Velero"
    ensure_namespace "velero"

    if [[ -d "${K8_DIR}/velero" ]]; then
      helm_install_if_needed "velero" "${K8_DIR}/velero" "velero"
      wait_for_pods "velero" 120

      # Ensure BackupStorageLocation is set as default
      local bsl_name
      bsl_name=$(kubectl get backupstoragelocation -n velero --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
      if [ -n "$bsl_name" ]; then
        kubectl patch backupstoragelocation "$bsl_name" -n velero \
          --type='json' -p='[{"op":"add","path":"/spec/default","value":true}]' 2>/dev/null || true
        log_success "Velero installed (BSL '${bsl_name}' set as default)"
      else
        log_success "Velero installed"
      fi
    else
      log_warn "Velero chart not found at ${K8_DIR}/velero — skipping"
    fi

    mark_component_installed "VELERO" "$STATE_FILE"
  else
    log_info "Velero already installed, skipping"
  fi

  # --- 2.6 Velero UI ---
  if ! component_is_installed "VELERO_UI" "$STATE_FILE"; then
    log_step "2.6 — Velero UI"

    helm repo add otwld https://otwld.github.io/helm-charts 2>/dev/null || true
    if [[ -f "${K8_DIR}/velero/ui/values.yaml" ]]; then
      helm install velero-ui otwld/velero-ui \
        -n velero \
        -f "${K8_DIR}/velero/ui/values.yaml" \
        2>&1 | tail -1
    else
      helm install velero-ui otwld/velero-ui \
        -n velero \
        --set image.repository="artifactory.cfapps.cool/docker-local/velero-ui" \
        --set image.tag="0.10.1" \
        --set "env[0].name=BASIC_AUTH_ENABLED" \
        --set "env[0].value=true" \
        --set "env[1].name=BASIC_AUTH_USER" \
        --set "env[1].value=admin" \
        --set "env[2].name=BASIC_AUTH_PASSWORD" \
        --set "env[2].value=velero-admin-2026" \
        2>&1 | tail -1
    fi
    wait_for_pods "velero" 60

    # Apply IngressRoute
    if [[ -f "${K8_DIR}/velero/ui/ingressroute.yaml" ]]; then
      apply_manifest "${K8_DIR}/velero/ui/ingressroute.yaml"
    fi

    log_success "Velero UI installed at https://backup.${PLATFORM_DOMAIN}"
    mark_component_installed "VELERO_UI" "$STATE_FILE"
  else
    log_info "Velero UI already installed, skipping"
  fi

  write_credentials
  mark_phase_complete 2 "$STATE_FILE"
  log_success "Phase 2 — Platform complete"
  echo ""
  log_info "Next step: ./install.sh phase 3"
  echo ""
}

# =============================================================================
# Phase 3 — Monitoring
# =============================================================================
# Loki, Mimir, Tempo, Alloy, kube-state-metrics, node-exporter, Grafana
# =============================================================================
install_phase_3() {
  log_phase "Phase 3 — Monitoring"
  load_config
  check_phase_prerequisites 3 "$STATE_FILE"
  export KUBECONFIG="${HOME}/.kube/config-${LIMA_VM_NAME}"

  # --- 3.1 Loki ---
  if ! component_is_installed "LOKI" "$STATE_FILE"; then
    log_step "3.1 — Loki"
    ensure_namespace "monitoring"

    if [[ -d "${K8_DIR}/monitoring/loki" ]]; then
      helm_install_if_needed "loki" "${K8_DIR}/monitoring/loki" "monitoring"
      wait_for_pods "monitoring" 180 || true
      log_success "Loki installed"
    else
      log_warn "Loki chart not found at ${K8_DIR}/monitoring/loki — skipping"
    fi

    mark_component_installed "LOKI" "$STATE_FILE"
  else
    log_info "Loki already installed, skipping"
  fi

  # --- 3.2 Mimir ---
  if ! component_is_installed "MIMIR" "$STATE_FILE"; then
    log_step "3.2 — Mimir"
    ensure_namespace "mimir"

    if [[ -d "${K8_DIR}/monitoring/mimir" ]]; then
      smart_install "mimir" "${K8_DIR}/monitoring/mimir" "mimir"
      wait_for_pods "mimir" 180
      log_success "Mimir installed"
    else
      log_warn "Mimir chart not found at ${K8_DIR}/monitoring/mimir — skipping"
    fi

    mark_component_installed "MIMIR" "$STATE_FILE"
  else
    log_info "Mimir already installed, skipping"
  fi

  # --- 3.3 Tempo ---
  if ! component_is_installed "TEMPO" "$STATE_FILE"; then
    log_step "3.3 — Tempo"
    ensure_namespace "monitoring"

    if [[ -d "${K8_DIR}/monitoring/tempo" ]]; then
      helm_install_if_needed "tempo" "${K8_DIR}/monitoring/tempo" "monitoring"
      wait_for_pods "monitoring" 180 || true
      log_success "Tempo installed"
    else
      log_warn "Tempo chart not found at ${K8_DIR}/monitoring/tempo — skipping"
    fi

    mark_component_installed "TEMPO" "$STATE_FILE"
  else
    log_info "Tempo already installed, skipping"
  fi

  # --- 3.4 Alloy (collector) ---
  if ! component_is_installed "ALLOY" "$STATE_FILE"; then
    log_step "3.4 — Alloy"
    ensure_namespace "monitoring"

    if [[ -d "${K8_DIR}/monitoring/alloy" ]]; then
      helm_install_if_needed "alloy" "${K8_DIR}/monitoring/alloy" "monitoring"
      wait_for_pods "monitoring" 120 || true
      log_success "Alloy installed"
    else
      log_warn "Alloy chart not found at ${K8_DIR}/monitoring/alloy — skipping"
    fi

    mark_component_installed "ALLOY" "$STATE_FILE"
  else
    log_info "Alloy already installed, skipping"
  fi

  # --- 3.5 kube-state-metrics ---
  if ! component_is_installed "KUBE_STATE_METRICS" "$STATE_FILE"; then
    log_step "3.5 — kube-state-metrics"
    ensure_namespace "monitoring"

    if [[ -d "${K8_DIR}/monitoring/kube-state-metrics" ]]; then
      helm_install_if_needed "kube-state-metrics" "${K8_DIR}/monitoring/kube-state-metrics" "monitoring"
      wait_for_pods "monitoring" 120 || true
      log_success "kube-state-metrics installed"
    else
      log_warn "kube-state-metrics chart not found — skipping"
    fi

    mark_component_installed "KUBE_STATE_METRICS" "$STATE_FILE"
  else
    log_info "kube-state-metrics already installed, skipping"
  fi

  # --- 3.6 node-exporter ---
  if ! component_is_installed "NODE_EXPORTER" "$STATE_FILE"; then
    log_step "3.6 — node-exporter"
    ensure_namespace "monitoring"

    if [[ -d "${K8_DIR}/monitoring/node-exporter" ]]; then
      helm_install_if_needed "node-exporter" "${K8_DIR}/monitoring/node-exporter" "monitoring"
      wait_for_pods "monitoring" 120 || true
      log_success "node-exporter installed"
    else
      log_warn "node-exporter chart not found — skipping"
    fi

    mark_component_installed "NODE_EXPORTER" "$STATE_FILE"
  else
    log_info "node-exporter already installed, skipping"
  fi

  # --- 3.7 Grafana ---
  if ! component_is_installed "GRAFANA" "$STATE_FILE"; then
    log_step "3.7 — Grafana"
    ensure_namespace "monitoring"

    if [[ -d "${K8_DIR}/monitoring/grafana" ]]; then
      local grafana_args=()
      if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
        grafana_args+=(--set "grafana.adminPassword=${GRAFANA_ADMIN_PASSWORD}")
      fi
      helm_install_if_needed "grafana" "${K8_DIR}/monitoring/grafana" "monitoring" "${grafana_args[@]}"
      wait_for_pods "monitoring" 120 || true
      log_success "Grafana installed"
    else
      log_warn "Grafana chart not found at ${K8_DIR}/monitoring/grafana — skipping"
    fi

    mark_component_installed "GRAFANA" "$STATE_FILE"
  else
    log_info "Grafana already installed, skipping"
  fi

  write_credentials
  mark_phase_complete 3 "$STATE_FILE"
  log_success "Phase 3 — Monitoring complete"
  echo ""
  log_info "Grafana: https://grafana.${BASE_DOMAIN}"
  log_info "Next step: ./install.sh phase 4"
  echo ""
}

# =============================================================================
# Phase 4 — Services
# =============================================================================
# artifact-keeper (Backend + Web + Trivy), PostgreSQL, Meilisearch
# =============================================================================
install_phase_4() {
  log_phase "Phase 4 — Services (artifact-keeper)"
  load_config
  check_phase_prerequisites 4 "$STATE_FILE"
  export KUBECONFIG="${HOME}/.kube/config-${LIMA_VM_NAME}"

  # Ensure OpenBao is logged in
  if [[ -z "${OPENBAO_ROOT_TOKEN:-}" ]]; then
    printf "  ${BOLD}OpenBao Root Token${NC}: " >&2
    read -rs OPENBAO_ROOT_TOKEN </dev/tty
    echo "" >&2
  fi
  kubectl exec -n openbao openbao-0 -- bao login "${OPENBAO_ROOT_TOKEN}" >/dev/null 2>&1 || true

  # --- Verify Garage artifacts key exists in OpenBao ---
  if ! component_is_installed "phase4_garage_key" "$STATE_FILE"; then
    log_step "Verifying Garage artifacts key in OpenBao..."
    local BAO="kubectl exec -n openbao openbao-0 --"
    $BAO bao login "${OPENBAO_ROOT_TOKEN:-}" >/dev/null 2>&1 || true
    local artifacts_key
    artifacts_key=$($BAO bao kv get -field=access_key secret/garage/artifacts 2>/dev/null || echo "")
    if [[ -n "$artifacts_key" ]]; then
      log_success "Garage artifacts key found in OpenBao (created in Phase 2)"
    else
      log_warn "Garage artifacts key not found — creating via admin API..."
      local garage_admin_token
      garage_admin_token=$($BAO bao kv get -field=token secret/garage/admin-token 2>/dev/null || echo "")
      if [[ -n "$garage_admin_token" ]]; then
        local garage_api="http://garage.garage.svc:3903"
        local key_resp
        key_resp=$(kubectl exec -n garage garage-0 -- curl -sf -X POST \
          -H "Authorization: Bearer ${garage_admin_token}" \
          -H "Content-Type: application/json" \
          -d '{"name":"artifacts"}' \
          "${garage_api}/v1/key" 2>/dev/null || echo "")
        if [[ -n "$key_resp" ]]; then
          local ak sk
          ak=$(echo "$key_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['accessKeyId'])" 2>/dev/null)
          sk=$(echo "$key_resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['secretAccessKey'])" 2>/dev/null)
          $BAO bao kv put secret/garage/artifacts access_key="$ak" secret_key="$sk" >/dev/null 2>&1
          log_success "Garage artifacts key created and stored in OpenBao"
        else
          log_warn "Could not create Garage key — Garage may not be ready"
        fi
      fi
    fi
    mark_component_installed "phase4_garage_key" "$STATE_FILE"
  fi

  # --- Store artifact-keeper secrets in OpenBao ---
  if ! component_is_installed "phase4_secrets" "$STATE_FILE"; then
    log_step "Storing artifact-keeper secrets in OpenBao..."
    kubectl exec -n openbao openbao-0 -- bao kv put secret/artifact-keeper/postgres \
      username="artifact_keeper" password="$(openssl rand -base64 16)" database="artifact_keeper" &>/dev/null
    kubectl exec -n openbao openbao-0 -- bao kv put secret/artifact-keeper/meilisearch \
      master_key="$(openssl rand -hex 16)" &>/dev/null
    local ak_admin_pass=$(openssl rand -base64 16)
    kubectl exec -n openbao openbao-0 -- bao kv put secret/artifact-keeper/app \
      jwt_secret="$(openssl rand -base64 32)" \
      admin_password="$ak_admin_pass" \
      migration_encryption_key="$(openssl rand -base64 32)" &>/dev/null
    log_success "Secrets stored in OpenBao"
    echo ""
    echo -e "  ${BOLD}artifact-keeper admin password: ${ak_admin_pass}${NC}"
    echo -e "  ${YELLOW}Save this password in your password manager!${NC}"
    echo ""
    mark_component_installed "phase4_secrets" "$STATE_FILE"
  fi

  # --- Deploy artifact-keeper stack ---
  if ! component_is_installed "phase4_artifact_keeper" "$STATE_FILE"; then
    log_step "Deploying artifact-keeper (PostgreSQL, Meilisearch, Backend, Web, Trivy)..."
    kubectl apply -k "${K8_DIR}/services/artifact-keeper/" 2>&1 | grep -v "Warning"
    log_info "Waiting for pods..."
    wait_for_pods "artifact-keeper" 180
    log_success "artifact-keeper deployed"
    mark_component_installed "phase4_artifact_keeper" "$STATE_FILE"
  fi

  write_credentials
  mark_phase_complete 4 "$STATE_FILE"
  log_success "Phase 4 complete — artifact-keeper available at https://artifacts.${PLATFORM_DOMAIN:-development.cfapps.cool}"
  echo ""
}

# =============================================================================
# Phase 5 — GitLab CE + Runner
# =============================================================================
install_phase_5() {
  log_phase "Phase 5 — GitLab CE + Runner"
  load_config
  check_phase_prerequisites 5 "$STATE_FILE"
  export KUBECONFIG="${HOME}/.kube/config-${LIMA_VM_NAME}"

  # Ensure OpenBao is logged in
  if [[ -z "${OPENBAO_ROOT_TOKEN:-}" ]]; then
    printf "  ${BOLD}OpenBao Root Token${NC}: " >&2
    read -rs OPENBAO_ROOT_TOKEN </dev/tty
    echo "" >&2
  fi
  kubectl exec -n openbao openbao-0 -- bao login "${OPENBAO_ROOT_TOKEN}" >/dev/null 2>&1 || true

  local GITLAB_DOMAIN="${PLATFORM_DOMAIN:-development.cfapps.cool}"

  # --- Store GitLab root password ---
  if ! component_is_installed "phase5_secrets" "$STATE_FILE"; then
    log_step "Storing GitLab secrets in OpenBao..."
    local gitlab_root_pass=$(openssl rand -base64 16)
    kubectl exec -n openbao openbao-0 -- bao kv put secret/gitlab/admin \
      root_password="$gitlab_root_pass" &>/dev/null
    log_success "GitLab root password stored"
    echo ""
    echo -e "  ${BOLD}GitLab root password: ${gitlab_root_pass}${NC}"
    echo -e "  ${YELLOW}Save this password in your password manager!${NC}"
    echo ""
    mark_component_installed "phase5_secrets" "$STATE_FILE"
  fi

  # --- Deploy GitLab CE ---
  if ! component_is_installed "phase5_gitlab" "$STATE_FILE"; then
    log_step "Deploying GitLab CE (this takes 5-10 minutes to start)..."
    kubectl apply -k "${K8_DIR}/services/gitlab-ce/" 2>&1 | grep -v "Warning"

    log_info "Waiting for GitLab to start (up to 15 minutes)..."
    local attempts=0
    while true; do
      local ready=$(kubectl get pod gitlab-0 -n gitlab -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
      if [[ "$ready" == "true" ]]; then
        log_success "GitLab is Ready"
        break
      fi
      attempts=$((attempts + 1))
      if [[ $attempts -ge 60 ]]; then
        log_warn "GitLab not Ready after 15 minutes. It may still be starting."
        log_info "Check with: kubectl get pods -n gitlab"
        break
      fi
      sleep 15
    done
    mark_component_installed "phase5_gitlab" "$STATE_FILE"
  fi

  # --- Register and deploy GitLab Runner ---
  if ! component_is_installed "phase5_runner" "$STATE_FILE"; then
    log_step "Registering GitLab Runner..."

    # Wait for GitLab API to be available
    log_info "Waiting for GitLab API..."
    local api_ready=false
    for i in $(seq 1 20); do
      local code=$(curl -sk -o /dev/null -w "%{http_code}" "https://gitlab.${GITLAB_DOMAIN}/-/readiness" 2>/dev/null)
      if [[ "$code" == "200" ]]; then
        api_ready=true
        break
      fi
      sleep 10
    done

    if [[ "$api_ready" != "true" ]]; then
      log_warn "GitLab API not reachable. Skipping runner registration."
      log_info "Register manually later: ./install.sh phase 5"
      mark_phase_complete 5 "$STATE_FILE"
      return 0
    fi

    # Create PAT via rails console
    log_info "Creating temporary access token..."
    local pat=$(kubectl exec -n gitlab gitlab-0 -- gitlab-rails runner "
      token = User.find_by_username('root').personal_access_tokens.create!(
        name: 'runner-setup-$(date +%s)',
        scopes: ['api', 'create_runner'],
        expires_at: 1.hour.from_now
      )
      puts token.token
    " 2>/dev/null | tail -1)

    if [[ -z "$pat" || "$pat" == *"Error"* ]]; then
      log_warn "Could not create access token. Skipping runner registration."
      mark_phase_complete 5 "$STATE_FILE"
      return 0
    fi

    # Register instance runner via API
    log_info "Registering instance runner..."
    local runner_response=$(curl -sk --request POST "https://gitlab.${GITLAB_DOMAIN}/api/v4/user/runners" \
      --header "PRIVATE-TOKEN: ${pat}" \
      --form "runner_type=instance_type" \
      --form "description=k8s-runner" \
      --form "tag_list=k8s,docker" 2>/dev/null)

    local runner_token=$(echo "$runner_response" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('token',''))" 2>/dev/null)

    if [[ -z "$runner_token" ]]; then
      log_warn "Runner registration failed. Register manually later."
      mark_phase_complete 5 "$STATE_FILE"
      return 0
    fi

    # Store runner token in OpenBao
    kubectl exec -n openbao openbao-0 -- bao kv put secret/gitlab/runner \
      token="$runner_token" &>/dev/null
    log_success "Runner registered and token stored in OpenBao"

    # Deploy GitLab Runner
    log_step "Deploying GitLab Runner..."
    ensure_namespace "gitlab-runner"
    ensure_namespace "gitlab-runner-jobs"
    helm_install_if_needed "gitlab-runner" "${K8_DIR}/services/gitlab-ce/runner" "gitlab-runner"
    wait_for_pods "gitlab-runner" 60
    log_success "GitLab Runner deployed with Kubernetes executor"
    mark_component_installed "phase5_runner" "$STATE_FILE"
  fi

  write_credentials
  mark_phase_complete 5 "$STATE_FILE"
  echo ""
  log_success "Phase 5 complete"
  echo ""
  echo -e "  ${BOLD}GitLab CE:${NC}     https://gitlab.${GITLAB_DOMAIN} (root)"
  echo -e "  ${BOLD}GitLab SSH:${NC}    192.168.64.202:22"
  echo -e "  ${BOLD}GitLab Runner:${NC} k8s-runner (Kubernetes executor)"
  echo -e "  ${BOLD}Job Namespace:${NC} gitlab-runner-jobs"
  echo ""
}

# =============================================================================
# Phase 6 — Cloud Foundry (Korifi) [OPTIONAL]
# =============================================================================
# Gateway API, Contour, kpack, Service Binding, Korifi
# =============================================================================
install_phase_6() {
  log_phase "Phase 6 — Cloud Foundry (Korifi) [OPTIONAL]"
  load_config
  # Phase 6 only requires Phase 1-3, not 4-5
  # Custom prerequisite check instead of check_phase_prerequisites
  export KUBECONFIG="${HOME}/.kube/config-${LIMA_VM_NAME}"

  local CF_DOMAIN="${APPS_DOMAIN:-app.cfapps.cool}"

  # --- Install QEMU user-static ---
  if ! component_is_installed "phase6_qemu" "$STATE_FILE"; then
    log_step "Installing QEMU user-static in Lima VM..."
    limactl shell "${LIMA_VM_NAME:-k3s-server}" sudo apt install -y qemu-user-static &>/dev/null
    log_success "QEMU user-static installed"
    mark_component_installed "phase6_qemu" "$STATE_FILE"
  fi

  # --- Install Gateway API CRDs ---
  if ! component_is_installed "phase6_gateway_api" "$STATE_FILE"; then
    log_step "Installing Gateway API CRDs..."
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml 2>&1 | tail -3
    log_success "Gateway API CRDs installed"
    mark_component_installed "phase6_gateway_api" "$STATE_FILE"
  fi

  # --- Install Contour ---
  if ! component_is_installed "phase6_contour" "$STATE_FILE"; then
    log_step "Installing Contour (Gateway API controller)..."
    ensure_namespace "projectcontour"
    # Note: Images need to be imported first
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm install contour bitnami/contour \
      -n projectcontour \
      --set contour.gatewayAPIEnabled=true \
      --set envoy.service.type=LoadBalancer \
      --set envoy.service.annotations."metallb\.universe\.tf/loadBalancerIPs"="$(get_metallb_apps_ip)" \
      2>&1 | tail -3
    wait_for_pods "projectcontour" 120
    log_success "Contour installed"
    mark_component_installed "phase6_contour" "$STATE_FILE"
  fi

  # --- Install kpack ---
  if ! component_is_installed "phase6_kpack" "$STATE_FILE"; then
    log_step "Installing kpack v0.17.0..."
    kubectl apply -f https://github.com/buildpacks-community/kpack/releases/download/v0.17.0/release-0.17.0.yaml 2>&1 | tail -3
    wait_for_pods "kpack" 120
    log_success "kpack installed"
    mark_component_installed "phase6_kpack" "$STATE_FILE"
  fi

  # --- Patch kpack with ARM64 images ---
  if ! component_is_installed "phase6_kpack_arm64" "$STATE_FILE"; then
    log_step "Patching kpack with ARM64 images (native, no QEMU)..."
    local KPACK_TAG="0.17.0-arm64"
    local KPACK_REGISTRY="${REGISTRY:-artifactory.cfapps.cool}/docker-local"

    # Check if ARM64 images exist in registry
    if crane manifest "${KPACK_REGISTRY}/kpack/controller:${KPACK_TAG}" &>/dev/null; then
      # Patch controller and webhook deployments
      kubectl set image -n kpack deploy/kpack-controller \
        "controller=${KPACK_REGISTRY}/kpack/controller:${KPACK_TAG}" 2>&1 | tail -1
      kubectl set image -n kpack deploy/kpack-webhook \
        "webhook=${KPACK_REGISTRY}/kpack/webhook:${KPACK_TAG}" 2>&1 | tail -1

      # Patch build helper image references
      kubectl set env -n kpack deploy/kpack-controller \
        "BUILD_INIT_IMAGE=${KPACK_REGISTRY}/kpack/build-init:${KPACK_TAG}" \
        "BUILD_WAITER_IMAGE=${KPACK_REGISTRY}/kpack/build-waiter:${KPACK_TAG}" \
        "REBASE_IMAGE=${KPACK_REGISTRY}/kpack/rebase:${KPACK_TAG}" \
        "COMPLETION_IMAGE=${KPACK_REGISTRY}/kpack/completion:${KPACK_TAG}" 2>&1 | tail -1

      # Force re-pull to replace cached AMD64 images
      kubectl patch deploy kpack-controller -n kpack \
        -p '{"spec":{"template":{"spec":{"containers":[{"name":"controller","imagePullPolicy":"Always"}]}}}}' 2>&1 | tail -1
      kubectl patch deploy kpack-webhook -n kpack \
        -p '{"spec":{"template":{"spec":{"containers":[{"name":"webhook","imagePullPolicy":"Always"}]}}}}' 2>&1 | tail -1

      wait_for_pods "kpack" 120
      log_success "kpack patched with ARM64 images"
    else
      log_warn "ARM64 images not found in registry — build them first with k8/services/kpack/build-arm64.sh"
      log_warn "kpack will run under QEMU emulation (unstable)"
    fi
    mark_component_installed "phase6_kpack_arm64" "$STATE_FILE"
  fi

  # --- Install Service Binding Runtime ---
  if ! component_is_installed "phase6_servicebinding" "$STATE_FILE"; then
    log_step "Installing Service Binding Runtime..."
    kubectl apply -f https://github.com/servicebinding/runtime/releases/download/v1.0.0/servicebinding-runtime-v1.0.0.yaml 2>&1 | tail -3
    wait_for_pods "servicebinding-system" 60
    log_success "Service Binding Runtime installed"
    mark_component_installed "phase6_servicebinding" "$STATE_FILE"
  fi

  # --- Setup local registry for Korifi ---
  if ! component_is_installed "phase6_local_registry" "$STATE_FILE"; then
    log_step "Setting up local registry for Korifi builds..."
    local LOCAL_REGISTRY="${PLATFORM_DOMAIN:-development.cfapps.cool}"
    local LOCAL_AK="https://artifacts.${LOCAL_REGISTRY}"

    # Get admin credentials from OpenBao
    local AK_ADMIN_PASS
    AK_ADMIN_PASS=$(kubectl exec -n openbao openbao-0 -- bao kv get -field=admin_password secret/artifact-keeper/app 2>/dev/null)

    # Login to get token
    local AK_TOKEN
    AK_TOKEN=$(curl -sk "${LOCAL_AK}/api/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"admin\",\"password\":\"${AK_ADMIN_PASS}\"}" | \
      python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

    # Create korifi Docker repo (idempotent — ignore if exists)
    curl -sk "${LOCAL_AK}/api/v1/repositories" \
      -H "Authorization: Bearer ${AK_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"key":"korifi","name":"Korifi Container Images","format":"docker","repo_type":"local","is_public":true}' 2>&1 | tail -1

    # Ensure repo is public (for kpack pull access)
    local REPO_ID
    REPO_ID=$(curl -sk "${LOCAL_AK}/api/v1/repositories/korifi" \
      -H "Authorization: Bearer ${AK_TOKEN}" 2>/dev/null | \
      python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
    if [ -n "$REPO_ID" ]; then
      curl -sk -X PATCH "${LOCAL_AK}/api/v1/repositories/korifi" \
        -H "Authorization: Bearer ${AK_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"is_public":true}' 2>&1 | tail -1
    fi

    # Store korifi registry credentials in OpenBao
    kubectl exec -n openbao openbao-0 -- bao kv put secret/korifi/registry \
      username="admin" password="${AK_ADMIN_PASS}" \
      registry="artifacts.${LOCAL_REGISTRY}" repo="korifi" 2>&1 | tail -1

    log_success "Local registry configured (artifacts.${LOCAL_REGISTRY}/korifi)"
    mark_component_installed "phase6_local_registry" "$STATE_FILE"
  fi

  # --- Create CF namespaces and registry credentials ---
  if ! component_is_installed "phase6_namespaces" "$STATE_FILE"; then
    log_step "Creating CF namespaces..."
    local LOCAL_REGISTRY="${PLATFORM_DOMAIN:-development.cfapps.cool}"
    ensure_namespace "cf"
    ensure_namespace "korifi"
    ensure_namespace "korifi-gateway"

    # Get admin credentials from OpenBao for local registry
    local AK_ADMIN_PASS
    AK_ADMIN_PASS=$(kubectl exec -n openbao openbao-0 -- bao kv get -field=admin_password secret/artifact-keeper/app 2>/dev/null)

    # Registry credentials for kpack builds (cf namespace)
    kubectl -n cf create secret docker-registry image-registry-credentials \
      --docker-server="artifacts.${LOCAL_REGISTRY}" \
      --docker-username="admin" \
      --docker-password="${AK_ADMIN_PASS}" \
      --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tail -1

    # Registry credentials for kpack controller (kpack namespace)
    local AUTH_B64
    AUTH_B64=$(echo -n "admin:${AK_ADMIN_PASS}" | base64)
    kubectl create secret generic kpack-registry-auth \
      --from-literal=config.json="{\"auths\":{\"artifacts.${LOCAL_REGISTRY}\":{\"username\":\"admin\",\"password\":\"${AK_ADMIN_PASS}\",\"auth\":\"${AUTH_B64}\"}}}" \
      -n kpack --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tail -1

    # Mount registry auth into kpack controller
    kubectl get deploy kpack-controller -n kpack -o json | python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d['spec']['template']['spec']['containers'][0]
# Add DOCKER_CONFIG env var
envs = [e for e in c.get('env', []) if e['name'] != 'DOCKER_CONFIG']
envs.append({'name': 'DOCKER_CONFIG', 'value': '/home/nonroot/.docker'})
c['env'] = envs
# Add volume mount
vms = [vm for vm in c.get('volumeMounts', []) if vm['mountPath'] != '/home/nonroot/.docker']
vms.append({'name': 'registry-auth', 'mountPath': '/home/nonroot/.docker', 'readOnly': True})
c['volumeMounts'] = vms
# Add volume
vols = d['spec']['template']['spec'].get('volumes', [])
vols = [v for v in vols if v['name'] != 'registry-auth']
vols.append({'name': 'registry-auth', 'secret': {'secretName': 'kpack-registry-auth'}})
d['spec']['template']['spec']['volumes'] = vols
json.dump(d, sys.stdout)
" | kubectl apply -f - 2>&1 | tail -1

    log_success "CF namespaces and credentials created"
    mark_component_installed "phase6_namespaces" "$STATE_FILE"
  fi

  # --- Mirror buildpack images to local registry ---
  if ! component_is_installed "phase6_mirror_buildpacks" "$STATE_FILE"; then
    log_step "Mirroring buildpack images to local registry..."
    local LOCAL_REGISTRY="${PLATFORM_DOMAIN:-development.cfapps.cool}"
    local LOCAL_PREFIX="artifacts.${LOCAL_REGISTRY}/korifi"

    if command -v crane &>/dev/null; then
      local AK_ADMIN_PASS
      AK_ADMIN_PASS=$(kubectl exec -n openbao openbao-0 -- bao kv get -field=admin_password secret/artifact-keeper/app 2>/dev/null)
      crane auth login "artifacts.${LOCAL_REGISTRY}" -u admin -p "${AK_ADMIN_PASS}" 2>/dev/null

      # Mirror buildpacks (ARM64)
      for bp in java:21.4.0 nodejs ruby procfile go php httpd; do
        local bp_name="${bp%%:*}"
        crane cp --platform linux/arm64 "paketobuildpacks/${bp}" "${LOCAL_PREFIX}/buildpacks/${bp_name}:latest" 2>/dev/null && \
          log_success "  Mirrored ${bp_name}" || log_warn "  Failed to mirror ${bp_name}"
      done

      # Mirror stack images (ARM64)
      crane cp --platform linux/arm64 "paketobuildpacks/build-jammy-full:latest" "${LOCAL_PREFIX}/stacks/build-jammy-full:latest" 2>/dev/null && \
        log_success "  Mirrored build-jammy-full" || log_warn "  Failed to mirror build-jammy-full"
      crane cp --platform linux/arm64 "paketobuildpacks/run-jammy-full:latest" "${LOCAL_PREFIX}/stacks/run-jammy-full:latest" 2>/dev/null && \
        log_success "  Mirrored run-jammy-full" || log_warn "  Failed to mirror run-jammy-full"

      log_success "Buildpack images mirrored to local registry"
    else
      log_warn "crane not found — skipping mirror. Install: go install github.com/google/go-containerregistry/cmd/crane@latest"
      log_warn "Run k8/services/kpack/mirror-buildpacks.sh manually after installing crane"
    fi
    mark_component_installed "phase6_mirror_buildpacks" "$STATE_FILE"
  fi

  # --- Install Korifi ---
  if ! component_is_installed "phase6_korifi" "$STATE_FILE"; then
    log_step "Installing Korifi v0.18.0..."
    local LOCAL_REGISTRY="${PLATFORM_DOMAIN:-development.cfapps.cool}"
    local LOCAL_PREFIX="artifacts.${LOCAL_REGISTRY}/korifi"
    helm install korifi \
      https://github.com/cloudfoundry/korifi/releases/download/v0.18.0/korifi-0.18.0.tgz \
      --namespace="korifi" \
      --set=generateIngressCertificates=true \
      --set=rootNamespace="cf" \
      --set=adminUserName="cf-admin" \
      --set=api.apiServer.url="api.${CF_DOMAIN}" \
      --set=defaultAppDomainName="${CF_DOMAIN}" \
      --set=containerRepositoryPrefix="${LOCAL_PREFIX}/" \
      --set=kpackImageBuilder.builderRepository="${LOCAL_PREFIX}/kpack-builder" \
      --set=networking.gatewayClass="contour" \
      --set=networking.gatewayNamespace="korifi-gateway" \
      --set=experimental.managedServices.enabled=true \
      --wait --timeout=10m \
      2>&1 | tail -5

    wait_for_pods "korifi" 180
    log_success "Korifi installed"
    mark_component_installed "phase6_korifi" "$STATE_FILE"
  fi

  # --- Configure Buildpacks (local images) ---
  if ! component_is_installed "phase6_buildpacks" "$STATE_FILE"; then
    log_step "Configuring buildpacks (Java, Go, Node.js, PHP, Ruby, httpd, procfile)..."
    local LOCAL_REGISTRY="${PLATFORM_DOMAIN:-development.cfapps.cool}"
    local LOCAL_PREFIX="artifacts.${LOCAL_REGISTRY}/korifi"

    # Set ClusterStore to local buildpack images
    kubectl get clusterstore cf-default-buildpacks -o json | python3 -c "
import json, sys
cs = json.load(sys.stdin)
prefix = '${LOCAL_PREFIX}'
bps = ['java','nodejs','ruby','procfile','go','php','httpd']
cs['spec']['sources'] = [{'image': f'{prefix}/buildpacks/{bp}:latest'} for bp in bps]
json.dump(cs, sys.stdout)
" | kubectl apply -f - 2>&1 | tail -1

    # Set ClusterStack to local stack images
    kubectl get clusterstack cf-default-stack -o json | python3 -c "
import json, sys
cs = json.load(sys.stdin)
prefix = '${LOCAL_PREFIX}'
cs['spec']['buildImage']['image'] = f'{prefix}/stacks/build-jammy-full:latest'
cs['spec']['runImage']['image'] = f'{prefix}/stacks/run-jammy-full:latest'
json.dump(cs, sys.stdout)
" | kubectl apply -f - 2>&1 | tail -1

    # Patch ClusterLifecycle to use ARM64 lifecycle image from ghcr.io
    local LIFECYCLE_ARM64_DIGEST
    LIFECYCLE_ARM64_DIGEST=$(crane manifest ghcr.io/buildpacks-community/kpack/lifecycle 2>/dev/null \
      | python3 -c "import json,sys; m=json.load(sys.stdin); [print(p['digest']) for p in m.get('manifests',[]) if p.get('platform',{}).get('architecture')=='arm64']" 2>/dev/null)
    if [ -n "${LIFECYCLE_ARM64_DIGEST}" ]; then
      kubectl patch clusterlifecycle default-lifecycle --type merge \
        -p "{\"spec\":{\"image\":\"ghcr.io/buildpacks-community/kpack/lifecycle@${LIFECYCLE_ARM64_DIGEST}\"}}" 2>&1 | tail -1
    else
      log_warn "Could not determine ARM64 lifecycle digest — ClusterLifecycle may need manual patching"
    fi

    # Add all buildpacks to ClusterBuilder order
    kubectl get clusterbuilder cf-kpack-cluster-builder -o json | python3 -c "
import json, sys
cb = json.load(sys.stdin)
existing = {g['id'] for o in cb['spec']['order'] for g in o['group']}
needed = [
    'paketo-buildpacks/java',
    'paketo-buildpacks/go',
    'paketo-buildpacks/nodejs',
    'paketo-buildpacks/php',
    'paketo-buildpacks/ruby',
    'paketo-buildpacks/httpd',
    'paketo-buildpacks/procfile',
]
for bp in needed:
    if bp not in existing:
        cb['spec']['order'].append({'group': [{'id': bp}]})
json.dump(cb, sys.stdout)
" | kubectl apply -f - 2>&1 | tail -1

    log_success "Buildpacks configured with local images"
    mark_component_installed "phase6_buildpacks" "$STATE_FILE"
  fi

  # --- Patch Contour Gateway API config ---
  if ! component_is_installed "phase6_contour_gateway" "$STATE_FILE"; then
    log_step "Patching Contour ConfigMap for Gateway API..."

    # Enable BackendTLSPolicy v1alpha3 (required by Contour v1.33.x)
    local btlsp_served
    btlsp_served=$(kubectl get crd backendtlspolicies.gateway.networking.k8s.io -o json 2>/dev/null | \
      python3 -c "import json,sys; crd=json.load(sys.stdin); print(next((str(v.get('served')) for v in crd['spec']['versions'] if v['name']=='v1alpha3'),'missing'))" 2>/dev/null || echo "missing")
    if [ "$btlsp_served" = "False" ]; then
      kubectl get crd backendtlspolicies.gateway.networking.k8s.io -o json | \
        python3 -c "
import json, sys
crd = json.load(sys.stdin)
for v in crd['spec']['versions']:
    if v['name'] == 'v1alpha3':
        v['served'] = True
json.dump(crd, sys.stdout)
" | kubectl apply -f - 2>&1 | tail -1
      log_success "BackendTLSPolicy v1alpha3 enabled"
    fi

    # Patch Contour ConfigMap to reference korifi gateway
    kubectl get configmap contour -n projectcontour -o json | \
      python3 -c "
import json, sys
cm = json.load(sys.stdin)
old = cm['data']['contour.yaml']
new = old.replace(
    '# Specify the Gateway API configuration.\n# gateway:\n#   namespace: projectcontour\n#   name: contour',
    'gateway:\n  gatewayRef:\n    namespace: korifi-gateway\n    name: korifi'
)
cm['data']['contour.yaml'] = new
json.dump(cm, sys.stdout)
" | kubectl apply -f - 2>&1 | tail -1

    # Restart Contour to apply changes
    kubectl rollout restart deploy/contour -n projectcontour 2>&1 | tail -1
    kubectl rollout status deploy/contour -n projectcontour --timeout=120s 2>&1 | tail -1

    # Verify gateway is programmed
    local gw_status
    gw_status=$(kubectl get gateway korifi -n korifi-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
    if [ "$gw_status" = "True" ]; then
      log_success "Contour Gateway API configured (PROGRAMMED=True)"
    else
      log_warn "Gateway status: $gw_status — may need manual investigation"
    fi
    mark_component_installed "phase6_contour_gateway" "$STATE_FILE"
  fi

  # --- Configure TLS cert reflection for Korifi ---
  if ! component_is_installed "phase6_cert_reflection" "$STATE_FILE"; then
    log_step "Configuring TLS certificate reflection for Korifi..."

    # Delete self-signed cert created by Korifi (replaced by reflected LE cert)
    kubectl delete certificate korifi-workloads-ingress-cert -n korifi 2>/dev/null || true

    # ReferenceGrant: allow Gateway in korifi-gateway to use Secrets in korifi
    cat <<'RGEOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-cert-ref
  namespace: korifi
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: Gateway
    namespace: korifi-gateway
  to:
  - group: ""
    kind: Secret
RGEOF

    # Update Gateway to use reflected wildcard-apps-tls from korifi namespace
    kubectl get gateway korifi -n korifi-gateway -o json | python3 -c "
import json, sys
gw = json.load(sys.stdin)
for l in gw['spec']['listeners']:
    if l['name'] == 'https-apps' and 'tls' in l:
        l['tls']['certificateRefs'] = [{'group': '', 'kind': 'Secret', 'name': 'wildcard-apps-tls', 'namespace': 'korifi'}]
json.dump(gw, sys.stdout)
" | kubectl apply -f - 2>&1 | tail -1

    # Verify Gateway is programmed with LE cert
    sleep 5
    local gw_status
    gw_status=$(kubectl get gateway korifi -n korifi-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
    if [ "$gw_status" = "True" ]; then
      log_success "TLS cert reflection configured (Let's Encrypt wildcard via Reflector)"
    else
      log_warn "Gateway PROGRAMMED=$gw_status — check ReferenceGrant and reflected secret"
    fi
    mark_component_installed "phase6_cert_reflection" "$STATE_FILE"
  fi

  # --- Create cf-admin credentials ---
  if ! component_is_installed "phase6_cf_admin" "$STATE_FILE"; then
    log_step "Creating cf-admin user credentials..."
    local CF_ADMIN_DIR="${HOME}/.kube"

    # Generate private key
    openssl genrsa -out "${CF_ADMIN_DIR}/cf-admin.key" 4096 2>/dev/null

    # Generate CSR
    openssl req -new -key "${CF_ADMIN_DIR}/cf-admin.key" -out /tmp/cf-admin.csr -subj "/CN=cf-admin" 2>/dev/null

    # Delete existing CSR if present (re-run safety)
    kubectl delete csr cf-admin 2>/dev/null || true

    # Submit CSR to Kubernetes
    local CSR_B64
    CSR_B64=$(cat /tmp/cf-admin.csr | base64 | tr -d '\n')
    cat <<CSREOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: cf-admin
spec:
  request: ${CSR_B64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
  - client auth
CSREOF

    # Approve CSR
    kubectl certificate approve cf-admin 2>&1 | tail -1

    # Wait briefly for certificate to be issued
    sleep 2

    # Extract signed certificate
    kubectl get csr cf-admin -o jsonpath='{.status.certificate}' | base64 -d > "${CF_ADMIN_DIR}/cf-admin.crt"

    # Create ClusterRoleBinding
    cat <<'CRBEOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cf-admin-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: korifi-controllers-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: cf-admin
CRBEOF

    # Add cf-admin context to existing kubeconfig
    local MAIN_KUBECONFIG="${CF_ADMIN_DIR}/config-${LIMA_VM_NAME}"
    local CLUSTER_SERVER CLUSTER_CA
    CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    CLUSTER_CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

    # Build temporary kubeconfig for cf-admin
    local TMP_CFKUBECONFIG
    TMP_CFKUBECONFIG=$(mktemp)

    kubectl config set-cluster k3s-cf \
      --server="${CLUSTER_SERVER}" \
      --certificate-authority=<(echo "${CLUSTER_CA}" | base64 -d) \
      --embed-certs=true \
      --kubeconfig="${TMP_CFKUBECONFIG}" 2>/dev/null

    kubectl config set-credentials cf-admin \
      --client-certificate="${CF_ADMIN_DIR}/cf-admin.crt" \
      --client-key="${CF_ADMIN_DIR}/cf-admin.key" \
      --embed-certs=true \
      --kubeconfig="${TMP_CFKUBECONFIG}" 2>/dev/null

    kubectl config set-context cf-admin \
      --cluster=k3s-cf \
      --user=cf-admin \
      --kubeconfig="${TMP_CFKUBECONFIG}" 2>/dev/null

    # Merge cf-admin context into main kubeconfig
    cp "${MAIN_KUBECONFIG}" "${MAIN_KUBECONFIG}.bak"
    KUBECONFIG="${MAIN_KUBECONFIG}:${TMP_CFKUBECONFIG}" \
      kubectl config view --flatten > "${MAIN_KUBECONFIG}.merged"
    mv "${MAIN_KUBECONFIG}.merged" "${MAIN_KUBECONFIG}"
    rm -f "${TMP_CFKUBECONFIG}"

    # Switch back to main context
    kubectl --kubeconfig="${MAIN_KUBECONFIG}" config use-context "k3s-${LIMA_VM_NAME}" 2>/dev/null

    # Verify permissions with cf-admin context
    local can_list
    can_list=$(kubectl --kubeconfig="${MAIN_KUBECONFIG}" --context=cf-admin auth can-i list cforgs.korifi.cloudfoundry.org --all-namespaces 2>/dev/null || echo "no")
    if [ "$can_list" = "yes" ]; then
      log_success "cf-admin context merged into ${MAIN_KUBECONFIG}"
    else
      log_warn "cf-admin context merged but permission check failed"
    fi

    rm -f /tmp/cf-admin.csr
    mark_component_installed "phase6_cf_admin" "$STATE_FILE"
  fi

  write_credentials
  mark_phase_complete 6 "$STATE_FILE"
  echo ""
  log_success "Phase 6 complete — Cloud Foundry (Korifi)"
  echo ""
  echo -e "  ${BOLD}CF API:${NC}     https://api.${CF_DOMAIN}"
  echo -e "  ${BOLD}App Domain:${NC} *.${CF_DOMAIN}"
  echo ""
  echo -e "  ${BOLD}Kubeconfig:${NC} export KUBECONFIG=~/.kube/config-${LIMA_VM_NAME}"
  echo -e "  ${BOLD}Contexts:${NC}"
  echo -e "    kubectl config use-context k3s-${LIMA_VM_NAME}   # Cluster Admin"
  echo -e "    kubectl config use-context cf-admin      # CF Operations"
  echo ""
  echo -e "  ${BOLD}Next steps:${NC}"
  echo -e "  brew install cloudfoundry/tap/cf-cli@8"
  echo -e "  cf api https://api.${CF_DOMAIN} --skip-ssl-validation"
  echo -e "  kubectl config use-context cf-admin && cf login"
  echo -e "  cf create-org dev && cf target -o dev"
  echo -e "  cf create-space test && cf target -s test"
  echo -e "  cf push my-app"
  echo ""
}

# =============================================================================
# Phase 7 — CF Service Brokers
# =============================================================================
# CloudNativePG, RabbitMQ Operator, Universal OSBAPI Broker
# =============================================================================
install_phase_7() {
  log_phase "Phase 7 — CF Service Brokers"
  load_config
  export KUBECONFIG="${HOME}/.kube/config-${LIMA_VM_NAME}"

  # --- Install CloudNativePG operator ---
  if ! component_is_installed "phase7_cnpg" "$STATE_FILE"; then
    log_step "Installing CloudNativePG operator..."
    helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
    helm install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace 2>&1 | tail -1
    wait_for_pods "cnpg-system" 120
    log_success "CloudNativePG operator installed"
    mark_component_installed "phase7_cnpg" "$STATE_FILE"
  fi

  # --- Install RabbitMQ Cluster Operator ---
  if ! component_is_installed "phase7_rabbitmq_operator" "$STATE_FILE"; then
    log_step "Installing RabbitMQ Cluster Operator..."
    kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml 2>&1 | tail -3
    wait_for_pods "rabbitmq-system" 120
    log_success "RabbitMQ Cluster Operator installed"
    mark_component_installed "phase7_rabbitmq_operator" "$STATE_FILE"
  fi

  # --- Create cf-services namespace ---
  if ! component_is_installed "phase7_namespace" "$STATE_FILE"; then
    log_step "Creating cf-services namespace..."
    ensure_namespace "cf-services"

    # Pull secret for broker image
    kubectl -n cf-services create secret docker-registry artifact-keeper-pull \
      --docker-server="${REGISTRY:-artifactory.cfapps.cool}" \
      --docker-username="${REGISTRY_USER:-admin}" \
      --docker-password="${REGISTRY_PASS:-}" \
      --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tail -1

    log_success "cf-services namespace created"
    mark_component_installed "phase7_namespace" "$STATE_FILE"
  fi

  # --- Store broker credentials in OpenBao ---
  if ! component_is_installed "phase7_secrets" "$STATE_FILE"; then
    log_step "Storing broker credentials in OpenBao..."
    local BROKER_PASS
    BROKER_PASS=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)
    kubectl exec -n openbao openbao-0 -- bao kv put secret/cf-service-broker/auth \
      username="admin" password="${BROKER_PASS}" 2>&1 | tail -1
    log_success "Broker credentials stored (password: ${BROKER_PASS})"
    mark_component_installed "phase7_secrets" "$STATE_FILE"
  fi

  # --- Garage Admin Token ---
  if ! component_is_installed "phase7_garage_admin_token" "$STATE_FILE"; then
    log_step "Configuring Garage admin token..."

    local GARAGE_TOKEN
    GARAGE_TOKEN=$(openssl rand -hex 32)

    # Store in OpenBao
    kubectl exec -n openbao openbao-0 -- bao kv put secret/garage/admin-token \
      token="${GARAGE_TOKEN}" 2>&1 | tail -1

    # Update Garage ConfigMap with token
    sed "s/GARAGE_ADMIN_TOKEN_PLACEHOLDER/${GARAGE_TOKEN}/g" \
      "${K8_DIR}/platform/garage/configmap.yaml" | kubectl apply -f - 2>&1 | tail -1

    # Restart Garage to pick up new config
    kubectl rollout restart statefulset/garage -n garage 2>&1 | tail -1
    wait_for_pods "garage" 120

    # Apply ExternalSecret so ESO syncs token to cf-services namespace
    kubectl apply -f "${K8_DIR}/services/cf-service-broker/externalsecret-garage.yaml" 2>&1 | tail -1

    log_success "Garage admin token configured"
    mark_component_installed "phase7_garage_admin_token" "$STATE_FILE"
  fi

  # --- Build and push broker image ---
  if ! component_is_installed "phase7_broker_build" "$STATE_FILE"; then
    log_step "Building CF Service Broker..."
    local BROKER_SRC="${K8_DIR}/services/cf-service-broker/src"

    if command -v go &>/dev/null && command -v crane &>/dev/null; then
      local BUILD_DIR
      BUILD_DIR=$(mktemp -d)

      CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
        -C "${BROKER_SRC}" -ldflags "-s -w" \
        -o "${BUILD_DIR}/broker" . 2>&1 | tail -1

      local BROKER_REGISTRY="${REGISTRY:-artifactory.cfapps.cool}/docker-local"
      local BROKER_IMAGE="${BROKER_REGISTRY}/cf-service-broker:1.3.0-arm64"
      local BASE_IMAGE="gcr.io/distroless/static:nonroot"
      local TMPDIR_IMG LAYER
      TMPDIR_IMG=$(mktemp -d)
      mkdir -p "${TMPDIR_IMG}/app"
      cp "${BUILD_DIR}/broker" "${TMPDIR_IMG}/app/broker"
      LAYER=$(mktemp)
      (cd "${TMPDIR_IMG}" && tar cf "${LAYER}" app/)

      crane append --base "${BASE_IMAGE}" --new_tag "${BROKER_IMAGE}" --new_layer "${LAYER}" --platform linux/arm64 2>/dev/null
      crane mutate "${BROKER_IMAGE}" --entrypoint "/app/broker" --tag "${BROKER_IMAGE}" 2>/dev/null

      rm -rf "${BUILD_DIR}" "${TMPDIR_IMG}" "${LAYER}"
      log_success "Broker image built and pushed: ${BROKER_IMAGE}"
    else
      log_warn "go or crane not found — build broker manually: k8/services/cf-service-broker/src"
    fi
    mark_component_installed "phase7_broker_build" "$STATE_FILE"
  fi

  # --- Deploy broker ---
  if ! component_is_installed "phase7_broker_deploy" "$STATE_FILE"; then
    log_step "Deploying CF Service Broker..."

    # Get broker password from OpenBao
    local BROKER_PASS
    BROKER_PASS=$(kubectl exec -n openbao openbao-0 -- bao kv get -field=password secret/cf-service-broker/auth 2>/dev/null)

    # Update deployment with password from OpenBao
    sed "s/vxfSHItmMi82oL1vrGhV/${BROKER_PASS}/g" \
      "${K8_DIR}/services/cf-service-broker/deployment.yaml" | kubectl apply -f - 2>&1 | tail -1

    wait_for_pods "cf-services" 60
    log_success "CF Service Broker deployed"
    mark_component_installed "phase7_broker_deploy" "$STATE_FILE"
  fi

  # --- Register broker with Korifi ---
  if ! component_is_installed "phase7_broker_register" "$STATE_FILE"; then
    log_step "Registering service broker with Korifi..."

    local BROKER_PASS
    BROKER_PASS=$(kubectl exec -n openbao openbao-0 -- bao kv get -field=password secret/cf-service-broker/auth 2>/dev/null)

    # Switch to cf-admin context
    kubectl config use-context cf-admin 2>/dev/null || true

    cf create-service-broker k8s-services admin "${BROKER_PASS}" \
      http://cf-service-broker.cf-services.svc.cluster.local 2>&1 | tail -1

    cf enable-service-access postgresql 2>&1 | tail -1
    cf enable-service-access valkey 2>&1 | tail -1
    cf enable-service-access rabbitmq 2>&1 | tail -1
    cf enable-service-access s3 2>&1 | tail -1

    # Switch back
    kubectl config use-context k3s-${LIMA_VM_NAME} 2>/dev/null || true

    log_success "Service broker registered — cf marketplace shows all services"
    mark_component_installed "phase7_broker_register" "$STATE_FILE"
  fi

  write_credentials
  mark_phase_complete 7 "$STATE_FILE"
  echo ""
  log_success "Phase 7 complete — CF Service Brokers"
  echo ""
  echo -e "  ${BOLD}Services:${NC}"
  echo -e "    postgresql   small, medium   PostgreSQL 18 via CloudNativePG"
  echo -e "    valkey       small           Valkey (Redis-compatible)"
  echo -e "    rabbitmq     small           RabbitMQ message broker"
  echo -e "    s3           default         S3-compatible object storage (Garage)"
  echo ""
  echo -e "  ${BOLD}Usage:${NC}"
  echo -e "    cf marketplace"
  echo -e "    cf create-service postgresql small my-db"
  echo -e "    cf bind-service my-app my-db"
  echo ""
}

# =============================================================================
# Phase 8 — kappman (Korifi App Manager)
# =============================================================================
# Spring Boot app deployed via cf push with auto-configured Korifi integration
# =============================================================================
install_phase_8() {
  log_phase "Phase 8 — kappman (Korifi App Manager)"
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  fi
  export KUBECONFIG="${HOME}/.kube/config-${LIMA_VM_NAME}"

  # Load APPS_DOMAIN from config.env if not in install-config
  local KAPPMAN_CONFIG_ENV
  KAPPMAN_CONFIG_ENV="$(cd "$(dirname "$0")/.." && pwd)/k8/config.env"
  if [[ -f "$KAPPMAN_CONFIG_ENV" ]]; then
    source "$KAPPMAN_CONFIG_ENV"
  fi
  local CF_DOMAIN="${APPS_DOMAIN:-app.cfapps.cool}"
  local KAPPMAN_DIR
  KAPPMAN_DIR="$(cd "$(dirname "$0")/.." && pwd)/apps/kappman"

  if [[ ! -d "$KAPPMAN_DIR" ]]; then
    log_error "kappman source not found at $KAPPMAN_DIR"
    exit 1
  fi

  # --- Ensure Korifi is installed (check state file OR live cluster) ---
  if ! phase_is_complete 6 "$STATE_FILE"; then
    # Fallback: check if Korifi is actually running
    if ! kubectl get deployment -n korifi korifi-api-deployment >/dev/null 2>&1; then
      log_error "Phase 6 (Korifi) must be installed first"
      exit 1
    fi
    log_info "Korifi detected in cluster (no state file)"
  fi

  # --- Create kappman ServiceAccount with Korifi admin privileges ---
  if ! component_is_installed "phase8_sa" "$STATE_FILE"; then
    log_step "Creating kappman-cf-admin ServiceAccount..."

    # ServiceAccount in korifi namespace
    kubectl create serviceaccount kappman-cf-admin -n korifi 2>/dev/null || true

    # ClusterRoleBinding for korifi-controllers-admin
    kubectl create clusterrolebinding kappman-cf-admin-binding \
      --clusterrole=korifi-controllers-admin \
      --serviceaccount=korifi:kappman-cf-admin 2>/dev/null || true

    # Add RoleBindings to cf root namespace
    kubectl create rolebinding kappman-admin -n cf \
      --clusterrole=korifi-controllers-admin \
      --serviceaccount=korifi:kappman-cf-admin 2>/dev/null || true
    kubectl create rolebinding kappman-root-ns-user -n cf \
      --clusterrole=korifi-controllers-root-namespace-user \
      --serviceaccount=korifi:kappman-cf-admin 2>/dev/null || true

    # Add RoleBindings to all existing CF org/space namespaces
    for ns in $(kubectl get rolebindings -A -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
namespaces = set()
for item in data['items']:
    for s in item.get('subjects', []):
        if s.get('name') == 'cf-admin':
            namespaces.add(item['metadata']['namespace'])
for ns in sorted(namespaces):
    print(ns)
" 2>/dev/null); do
      kubectl create rolebinding kappman-admin -n "$ns" \
        --clusterrole=korifi-controllers-admin \
        --serviceaccount=korifi:kappman-cf-admin 2>/dev/null || true
      kubectl create rolebinding kappman-org-user -n "$ns" \
        --clusterrole=korifi-controllers-organization-user \
        --serviceaccount=korifi:kappman-cf-admin 2>/dev/null || true
      kubectl create rolebinding kappman-space-dev -n "$ns" \
        --clusterrole=korifi-controllers-space-developer \
        --serviceaccount=korifi:kappman-cf-admin 2>/dev/null || true
    done

    log_success "kappman-cf-admin ServiceAccount created with Korifi admin privileges"
    mark_component_installed "phase8_sa" "$STATE_FILE"
  fi

  # --- Generate long-lived token (requires cluster-admin context) ---
  log_step "Generating Korifi API token..."
  local CF_TOKEN
  CF_TOKEN=$(kubectl --context=k3s-${LIMA_VM_NAME} create token kappman-cf-admin -n korifi --duration=8760h 2>/dev/null \
    || kubectl create token kappman-cf-admin -n korifi --duration=8760h)
  log_success "Token generated (valid for 1 year)"

  # --- Switch to cf-admin context for CF CLI operations ---
  kubectl config use-context cf-admin 2>/dev/null

  # --- Login to CF ---
  log_step "Logging in to CF API..."
  cf api "https://api.${CF_DOMAIN}" --skip-ssl-validation 2>&1 | tail -1
  cf auth cf-admin 2>&1 | tail -1

  # --- Create kappman org and space (idempotent) ---
  if ! component_is_installed "phase8_org_space" "$STATE_FILE"; then
    log_step "Creating kappman org and space..."

    if ! cf org kappman >/dev/null 2>&1; then
      cf create-org kappman 2>&1 | tail -1
    else
      log_info "Org 'kappman' already exists"
    fi

    cf target -o kappman 2>&1 | tail -1

    if ! cf space app >/dev/null 2>&1; then
      cf create-space app 2>&1 | tail -1
    else
      log_info "Space 'app' already exists"
    fi

    cf target -o kappman -s app 2>&1 | tail -1

    # Grant kappman SA access to the new org/space namespaces
    sleep 3  # Wait for Korifi to create the namespaces
    for ns in $(kubectl get ns -o name 2>/dev/null | grep -v '^namespace/kube\|^namespace/default\|^namespace/local' | sed 's|namespace/||'); do
      kubectl create rolebinding kappman-admin -n "$ns" \
        --clusterrole=korifi-controllers-admin \
        --serviceaccount=korifi:kappman-cf-admin 2>/dev/null || true
      kubectl create rolebinding kappman-org-user -n "$ns" \
        --clusterrole=korifi-controllers-organization-user \
        --serviceaccount=korifi:kappman-cf-admin 2>/dev/null || true
      kubectl create rolebinding kappman-space-dev -n "$ns" \
        --clusterrole=korifi-controllers-space-developer \
        --serviceaccount=korifi:kappman-cf-admin 2>/dev/null || true
    done

    log_success "Org 'kappman' / Space 'app' ready"
    mark_component_installed "phase8_org_space" "$STATE_FILE"
  fi

  cf target -o kappman -s app 2>&1 | tail -1

  # --- Create PostgreSQL service for kappman ---
  if ! component_is_installed "phase8_db" "$STATE_FILE"; then
    log_step "Creating PostgreSQL service for kappman..."

    if ! cf service kappman-db >/dev/null 2>&1; then
      cf create-service postgresql small kappman-db 2>&1 | tail -1

      log_step "Waiting for kappman-db service to be ready..."
      local retries=0
      while [[ $retries -lt 60 ]]; do
        local svc_status
        svc_status=$(cf service kappman-db 2>/dev/null | grep "status:" | awk '{print $NF}' || echo "pending")
        if [[ "$svc_status" == "succeeded" ]]; then
          break
        fi
        retries=$((retries + 1))
        sleep 5
      done
    else
      log_info "Service 'kappman-db' already exists"
    fi

    log_success "PostgreSQL service 'kappman-db' ready"
    mark_component_installed "phase8_db" "$STATE_FILE"
  fi

  # --- Build kappman JAR ---
  if ! component_is_installed "phase8_build" "$STATE_FILE"; then
    log_step "Building kappman JAR..."
    pushd "$KAPPMAN_DIR" > /dev/null
    ./gradlew bootJar 2>&1 | tail -3
    popd > /dev/null

    if [[ ! -f "${KAPPMAN_DIR}/build/libs/kappman-0.0.1-SNAPSHOT.jar" ]]; then
      log_error "Build failed — JAR not found"
      exit 1
    fi

    log_success "kappman JAR built"
    mark_component_installed "phase8_build" "$STATE_FILE"
  fi

  # --- Push kappman to Korifi ---
  if ! component_is_installed "phase8_push" "$STATE_FILE"; then
    log_step "Pushing kappman to Korifi..."
    pushd "$KAPPMAN_DIR" > /dev/null
    cf push 2>&1 | tail -5
    popd > /dev/null

    log_success "kappman pushed to Korifi"
    mark_component_installed "phase8_push" "$STATE_FILE"
  fi

  # --- Set CF_PASSWORD (Korifi API token) ---
  log_step "Configuring Korifi API token..."
  cf set-env kappman CF_PASSWORD "$CF_TOKEN" 2>&1 | tail -1

  # --- Set PostgreSQL datasource from service binding ---
  log_step "Restarting kappman with configuration..."
  cf restart kappman 2>&1 | tail -3

  # --- Verify ---
  log_step "Verifying kappman deployment..."
  sleep 10
  local health_status
  health_status=$(curl -sk "https://kappman.${CF_DOMAIN}/actuator/health" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','UNKNOWN'))" 2>/dev/null || echo "UNREACHABLE")

  if [[ "$health_status" == "UP" ]]; then
    log_success "kappman is healthy"
  else
    log_warn "kappman health check returned: $health_status (may need time to start)"
  fi

  # Switch back to k3s-${LIMA_VM_NAME} context
  kubectl config use-context k3s-${LIMA_VM_NAME} 2>/dev/null

  write_credentials
  mark_phase_complete 8 "$STATE_FILE"
  echo ""
  log_success "Phase 8 complete — kappman (Korifi App Manager)"
  echo ""
  echo -e "  ${BOLD}URL:${NC}       https://kappman.${CF_DOMAIN}"
  echo -e "  ${BOLD}Login:${NC}     admin / change_me"
  echo -e "  ${BOLD}Version:${NC}   V1.0.0"
  echo ""
  echo -e "  ${BOLD}Features:${NC}"
  echo -e "    Dashboard, Organizations, Spaces, Applications"
  echo -e "    Services, Marketplace, Buildpacks, Korifi Status"
  echo -e "    User Management (Admin)"
  echo ""
}

# =============================================================================
# Status — Show installation status
# =============================================================================
cmd_status() {
  log_phase "Installation Status"

  # --- Phase completion status ---
  print_section "Phases"
  local phase_names=(
    "Foundation (Lima, K3s, OpenBao, ESO, MetalLB, Traefik, cert-manager)"
    "Platform (ArgoCD, Portainer, Garage, Technitium, Velero)"
    "Monitoring (Loki, Mimir, Tempo, Alloy, KSM, node-exporter, Grafana)"
    "Services (artifact-keeper, PostgreSQL, Meilisearch)"
    "GitLab CE"
    "Cloud Foundry / Korifi [OPTIONAL]"
    "CF Service Brokers [OPTIONAL]"
    "kappman — Korifi App Manager [OPTIONAL]"
  )
  for i in 1 2 3 4 5 6 7 8; do
    local status_color="$RED"
    local status_text="Not installed"
    if phase_is_complete "$i" "$STATE_FILE"; then
      status_color="$GREEN"
      local ts
      ts=$(grep "^PHASE_${i}_TIMESTAMP=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "unknown")
      status_text="Complete ($ts)"
    fi
    printf "  ${BOLD}Phase %d${NC}  %-60s ${status_color}%s${NC}\n" "$i" "${phase_names[$((i-1))]}" "$status_text"
  done
  echo ""

  # --- Component status ---
  if [[ -f "$STATE_FILE" ]]; then
    print_section "Components"
    local components=(
      "LIMA_K3S:Lima VM + K3s"
      "PULL_SECRETS:Pull Secrets"
      "OPENBAO:OpenBao"
      "ESO:External Secrets Operator"
      "METALLB:MetalLB"
      "TRAEFIK:Traefik"
      "CERTMANAGER:cert-manager"
      "ARGOCD:ArgoCD"
      "PORTAINER:Portainer"
      "GARAGE:Garage"
      "TECHNITIUM:Technitium DNS"
      "VELERO:Velero"
      "LOKI:Loki"
      "MIMIR:Mimir"
      "TEMPO:Tempo"
      "ALLOY:Alloy"
      "KUBE_STATE_METRICS:kube-state-metrics"
      "NODE_EXPORTER:node-exporter"
      "GRAFANA:Grafana"
      "phase6_qemu:QEMU user-static"
      "phase6_gateway_api:Gateway API CRDs"
      "phase6_contour:Contour"
      "phase6_kpack:kpack"
      "phase6_servicebinding:Service Binding Runtime"
      "phase6_namespaces:CF Namespaces"
      "phase6_korifi:Korifi"
      "phase7_cnpg:CloudNativePG"
      "phase7_rabbitmq_operator:RabbitMQ Operator"
      "phase8_sa:kappman ServiceAccount"
      "phase8_org_space:kappman Org/Space"
      "phase8_db:kappman Database"
      "phase8_push:kappman Deployment"
    )
    for entry in "${components[@]}"; do
      local key="${entry%%:*}"
      local label="${entry#*:}"
      if component_is_installed "$key" "$STATE_FILE"; then
        local ts
        ts=$(grep "^COMPONENT_${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")
        printf "  ${GREEN}[x]${NC} %-30s ${DIM}%s${NC}\n" "$label" "$ts"
      else
        printf "  ${DIM}[ ]${NC} %-30s\n" "$label"
      fi
    done
    echo ""
  fi

  # --- Configuration status ---
  print_section "Configuration"
  if [[ -f "$CONFIG_FILE" ]]; then
    log_success "Configuration file exists at $CONFIG_FILE"
  else
    log_warn "No configuration file found. Run: ./install.sh zero"
  fi
  echo ""

  # --- Live cluster status ---
  if [[ -f "${HOME}/.kube/config-${LIMA_VM_NAME}" ]]; then
    export KUBECONFIG="${HOME}/.kube/config-${LIMA_VM_NAME}"
    print_section "Cluster Health"
    if kubectl get nodes --request-timeout=5s &>/dev/null; then
      kubectl get nodes -o wide 2>/dev/null | sed 's/^/  /'
      echo ""

      # Service endpoints
      if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        print_section "Service Endpoints"
        local -a svc_names=("Traefik" "ArgoCD" "Portainer" "Grafana" "Technitium DNS")
        local -a svc_urls=(
          "https://traefik.${BASE_DOMAIN}"
          "https://argocd.${BASE_DOMAIN}"
          "https://portainer.${BASE_DOMAIN}"
          "https://grafana.${BASE_DOMAIN}"
          "https://dns.${BASE_DOMAIN}"
        )
        for i in "${!svc_names[@]}"; do
          local code
          code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 \
            --max-time 3 -k "${svc_urls[$i]}" 2>/dev/null || echo "000")
          local color="$RED" label="DOWN"
          if [[ "$code" =~ ^(200|301|302|303|307|308|401|403)$ ]]; then
            color="$GREEN"
            label="UP"
          fi
          printf "  ${BOLD}%-20s${NC} %-45s ${color}%s (%s)${NC}\n" \
            "${svc_names[$i]}" "${svc_urls[$i]}" "$label" "$code"
        done
        echo ""
      fi
    else
      log_warn "Cluster not reachable. Is the Lima VM running?"
      log_info "Start with: ${K8_DIR}/stack.sh start"
    fi
  else
    log_warn "No kubeconfig found. Phase 1 has not been run yet."
  fi
}

# =============================================================================
# Validate — Check all prerequisites
# =============================================================================
cmd_validate() {
  validate_prerequisites
}

# =============================================================================
# Continue from a given phase — offer next phases interactively
# =============================================================================
continue_from_phase() {
  local completed_phase="$1"

  if [[ "$completed_phase" -lt 2 ]] && phase_is_complete 1 "$STATE_FILE"; then
    echo ""
    log_info "Phase 2 deploys: ArgoCD, Portainer, Garage S3, Technitium DNS, Velero"
    if ask_yes_no "Continue with Phase 2 (Platform)?" "y"; then
      install_phase_2
    else return 0; fi
  fi

  if [[ "$completed_phase" -lt 3 ]] && phase_is_complete 2 "$STATE_FILE"; then
    echo ""
    log_info "Phase 3 deploys: Grafana, Loki, Mimir, Tempo, Alloy, kube-state-metrics, node-exporter"
    if ask_yes_no "Continue with Phase 3 (Monitoring)?" "y"; then
      install_phase_3
    else return 0; fi
  fi

  if [[ "$completed_phase" -lt 4 ]] && phase_is_complete 3 "$STATE_FILE"; then
    echo ""
    log_info "Phase 4 deploys: artifact-keeper (Backend + Web UI), PostgreSQL, Meilisearch, Trivy"
    if ask_yes_no "Continue with Phase 4 (Services)?" "y"; then
      install_phase_4
    else return 0; fi
  fi

  if [[ "$completed_phase" -lt 5 ]] && phase_is_complete 4 "$STATE_FILE"; then
    echo ""
    log_info "Phase 5 deploys: GitLab CE + GitLab Runner (CI/CD)"
    if ask_yes_no "Continue with Phase 5 (GitLab CE)?" "y"; then
      install_phase_5
    else return 0; fi
  fi

  if phase_is_complete 5 "$STATE_FILE"; then
    echo ""
    log_info "Phase 6 deploys: Korifi (Cloud Foundry on K8s) + kpack + Contour [OPTIONAL]"
    if ask_yes_no "Continue with Phase 6 (Cloud Foundry)?" "n"; then
      install_phase_6
    fi

    echo ""
    log_info "Phase 7 deploys: OSBAPI Service Brokers (PostgreSQL, Valkey, RabbitMQ, S3) [OPTIONAL, requires Go]"
    if ask_yes_no "Continue with Phase 7 (Service Brokers)?" "n"; then
      install_phase_7
    fi
  fi

  echo ""
  log_success "Installation complete!"
  cmd_status
}

# =============================================================================
# Interactive full setup — Run zero + all phases
# =============================================================================
cmd_full_setup() {
  cmd_zero

  echo ""
  if ask_yes_no "Validate prerequisites now?" "y"; then
    if ! cmd_validate; then
      log_error "Prerequisites not met. Fix the issues above and re-run."
      exit 1
    fi
  fi

  echo ""
  log_info "Phase 1 deploys: Lima VM, K3s, OpenBao, ESO, MetalLB, Traefik, cert-manager"
  if ask_yes_no "Begin Phase 1 (Foundation) installation?" "y"; then
    install_phase_1
  fi

  continue_from_phase 1
}

# =============================================================================
# Usage
# =============================================================================
usage() {
  cat <<EOF

${BOLD}K8s DevOps Stack — Distribution Installer${NC}

Usage: $(basename "$0") <command> [args]

${BOLD}Commands:${NC}
  ${CYAN}(none)${NC}          Interactive full setup (zero + all phases)
  ${CYAN}zero${NC}            Iteration Zero — gather all configuration interactively
  ${CYAN}phase <N>${NC}       Install a specific phase (1-8):
                    1: Foundation (Lima, K3s, OpenBao, ESO, MetalLB, Traefik, cert-manager)
                    2: Platform (ArgoCD, Portainer, Garage, Technitium, Velero)
                    3: Monitoring (Loki, Mimir, Tempo, Alloy, KSM, node-exporter, Grafana)
                    4: Services (artifact-keeper, PostgreSQL, Meilisearch)
                    5: GitLab CE
                    6: Cloud Foundry / Korifi [OPTIONAL] (requires phases 1-3)
                    7: CF Service Brokers [OPTIONAL] (requires phase 6)
                    8: kappman — Korifi App Manager [OPTIONAL] (requires phases 6+7)
  ${CYAN}status${NC}          Show installation status and service health
  ${CYAN}validate${NC}        Validate all prerequisites

${BOLD}Examples:${NC}
  ./install.sh                  # Full interactive setup
  ./install.sh zero             # Only gather configuration
  ./install.sh phase 1          # Install foundation layer
  ./install.sh phase 3          # Install monitoring stack
  ./install.sh status           # Check what's installed
  ./install.sh validate         # Check prerequisites

${BOLD}Files:${NC}
  .install-config    Saved configuration (secrets, gitignored)
  .install-state     Installation progress tracking (gitignored)

EOF
}

# =============================================================================
# Main
# =============================================================================
main() {
  print_banner

  local command="${1:-}"
  shift || true

  case "$command" in
    zero)
      cmd_zero
      ;;
    phase)
      local phase_num="${1:-}"
      if [[ -z "$phase_num" ]]; then
        log_error "Usage: ./install.sh phase <1-7>"
        exit 1
      fi
      case "$phase_num" in
        1) install_phase_1 ;;
        2) install_phase_2 ;;
        3) install_phase_3 ;;
        4) install_phase_4 ;;
        5) install_phase_5 ;;
        6) install_phase_6 ;;
        7) install_phase_7 ;;
        *)
          log_error "Unknown phase: $phase_num (valid: 1-7)"
          exit 1
          ;;
      esac
      # After completing a phase, offer to continue with next phases
      continue_from_phase "$phase_num"
      ;;
    status)
      cmd_status
      ;;
    validate)
      cmd_validate
      ;;
    -h|--help|help)
      usage
      ;;
    "")
      cmd_full_setup
      ;;
    *)
      log_error "Unknown command: $command"
      usage
      exit 1
      ;;
  esac
}

main "$@"
