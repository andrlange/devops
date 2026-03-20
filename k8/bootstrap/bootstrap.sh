#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# bootstrap.sh — Master bootstrap script for K8s DevOps Stack
#
# Sets up the entire stack from scratch on the macOS host:
#   Lima VM -> K3s -> OpenBao -> ESO -> MetalLB -> Traefik -> cert-manager
#
# Each phase is a standalone function and can be called individually:
#   ./bootstrap.sh                  # Run all phases
#   ./bootstrap.sh phase_k3s        # Run a single phase
#   ./bootstrap.sh phase_traefik phase_certmanager  # Run specific phases
# =============================================================================

# --- Resolve paths -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Source configuration ----------------------------------------------------
if [[ ! -f "${K8_DIR}/config.env" ]]; then
  echo "ERROR: ${K8_DIR}/config.env not found." >&2
  exit 1
fi
# shellcheck source=../config.env
source "${K8_DIR}/config.env"

# --- Color helpers -----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; }
log_phase()   { echo -e "\n${BOLD}${CYAN}========== $* ==========${NC}\n"; }

# --- Helper functions --------------------------------------------------------

ensure_namespace() {
  local ns="$1"
  if kubectl get namespace "${ns}" &>/dev/null; then
    log_info "Namespace '${ns}' already exists"
  else
    kubectl create namespace "${ns}"
    log_success "Created namespace '${ns}'"
  fi
}

wait_for_pods() {
  local namespace="$1"
  local timeout="${2:-120}"
  log_info "Waiting for pods in namespace '${namespace}' to be ready (timeout: ${timeout}s)..."
  if ! kubectl wait --for=condition=Ready pods --all \
       -n "${namespace}" --timeout="${timeout}s" 2>/dev/null; then
    log_warn "Not all pods are Ready yet in '${namespace}'. Current status:"
    kubectl get pods -n "${namespace}" 2>/dev/null || true
    return 1
  fi
  log_success "All pods in '${namespace}' are Ready"
}

wait_for_ready() {
  local resource="$1"
  local namespace="$2"
  local timeout="${3:-120}"
  log_info "Waiting for ${resource} in '${namespace}' (timeout: ${timeout}s)..."
  if ! kubectl wait --for=condition=Ready "${resource}" \
       -n "${namespace}" --timeout="${timeout}s" 2>/dev/null; then
    log_warn "${resource} not Ready yet. Current status:"
    kubectl get "${resource}" -n "${namespace}" 2>/dev/null || true
    return 1
  fi
  log_success "${resource} in '${namespace}' is Ready"
}

helm_install_if_needed() {
  local release="$1"
  local chart_path="$2"
  local namespace="$3"
  if helm status "${release}" -n "${namespace}" &>/dev/null; then
    log_info "Helm release '${release}' already installed in '${namespace}'"
    return 0
  fi
  log_info "Building Helm dependencies for ${chart_path}..."
  helm dependency build "${chart_path}" 2>/dev/null || helm dependency update "${chart_path}"
  log_info "Installing Helm release '${release}' in '${namespace}'..."
  helm install "${release}" "${chart_path}" -n "${namespace}"
  log_success "Helm release '${release}' installed"
}

apply_if_exists() {
  local manifest="$1"
  if [[ ! -f "${manifest}" ]]; then
    log_error "Manifest not found: ${manifest}"
    return 1
  fi
  kubectl apply -f "${manifest}"
  log_success "Applied ${manifest##*/}"
}

# =============================================================================
# Phase: Check Prerequisites
# =============================================================================
check_prerequisites() {
  log_phase "Checking Prerequisites"

  local missing=()
  for cmd in limactl kubectl helm; do
    if command -v "${cmd}" &>/dev/null; then
      log_success "${cmd} found: $(command -v "${cmd}")"
    else
      log_error "${cmd} not found"
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing prerequisites: ${missing[*]}"
    log_info "Install with: brew install ${missing[*]}"
    exit 1
  fi

  log_success "All prerequisites satisfied"
}

# =============================================================================
# Phase: Create Lima VM and Install K3s
# =============================================================================
phase_k3s() {
  log_phase "Phase 1.1/1.2 — Lima VM + K3s"

  # --- Create and start Lima VM ---
  if limactl list --json 2>/dev/null | grep -q "\"name\":\"${LIMA_VM_NAME}\""; then
    log_info "Lima VM '${LIMA_VM_NAME}' already exists"
    local vm_status
    vm_status=$(limactl list --json 2>/dev/null \
      | grep "\"name\":\"${LIMA_VM_NAME}\"" \
      | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['status'])" 2>/dev/null || echo "unknown")
    if [[ "${vm_status}" != "Running" ]]; then
      log_info "Starting Lima VM..."
      limactl start "${LIMA_VM_NAME}"
    else
      log_info "Lima VM already running"
    fi
  else
    log_info "Creating Lima VM '${LIMA_VM_NAME}'..."
    limactl create --name="${LIMA_VM_NAME}" "${SCRIPT_DIR}/lima.yaml"
    log_info "Starting Lima VM..."
    limactl start "${LIMA_VM_NAME}"
    log_success "Lima VM created and started"
  fi

  # --- Get VM IP ---
  log_info "Retrieving VM IP address..."
  VM_IP=$(limactl shell "${LIMA_VM_NAME}" hostname -I | awk '{print $1}')
  if [[ -z "${VM_IP}" ]]; then
    log_error "Could not determine VM IP address"
    exit 1
  fi
  log_success "VM IP: ${VM_IP}"

  # --- Install K3s (idempotent — script checks if already installed) ---
  if limactl shell "${LIMA_VM_NAME}" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null; then
    log_info "K3s already installed in VM"
  else
    log_info "Installing K3s inside Lima VM..."
    limactl shell "${LIMA_VM_NAME}" /mnt/k8/bootstrap/install-k3s.sh "${VM_IP}"
    log_success "K3s installed"
  fi

  # --- Export kubeconfig ---
  local kubeconfig_dir="${HOME}/.kube"
  local kubeconfig_file="${kubeconfig_dir}/config-k3s"
  mkdir -p "${kubeconfig_dir}"

  log_info "Exporting kubeconfig to ${kubeconfig_file}..."
  limactl shell "${LIMA_VM_NAME}" sudo cat /etc/rancher/k3s/k3s.yaml \
    | sed "s/127\.0\.0\.1/${VM_IP}/g" \
    | sed "s/default/k3s-devops/g" \
    > "${kubeconfig_file}"
  chmod 600 "${kubeconfig_file}"
  export KUBECONFIG="${kubeconfig_file}"
  log_success "Kubeconfig written to ${kubeconfig_file}"

  # --- Wait for K3s node Ready ---
  log_info "Waiting for K3s node to become Ready..."
  if kubectl get nodes --request-timeout=120s 2>/dev/null | grep -q ' Ready'; then
    log_success "K3s node is Ready"
  else
    log_error "K3s node did not become Ready within 120s"
    kubectl get nodes 2>/dev/null || true
    exit 1
  fi

  echo ""
  log_info "Set KUBECONFIG to use this cluster:"
  echo -e "  ${BOLD}export KUBECONFIG=${kubeconfig_file}${NC}"
}

# =============================================================================
# Phase: Bootstrap Pull Secrets
# =============================================================================
phase_pull_secrets() {
  log_phase "Phase 1.2b — Bootstrap Pull Secrets"

  # --- Interactive: ask for credentials ---
  echo -e "${BOLD}Registry pull credentials for ${REGISTRY}${NC}"
  echo "These are needed for Helm chart image pulls before ESO is available."
  echo ""
  read -rp "Registry username: " REGISTRY_USER
  read -rsp "Registry password/token: " REGISTRY_PASS
  echo ""

  if [[ -z "${REGISTRY_USER}" || -z "${REGISTRY_PASS}" ]]; then
    log_error "Username and password must not be empty"
    exit 1
  fi

  # --- Create pull secrets in all bootstrap namespaces ---
  local namespaces=("openbao" "external-secrets" "metallb-system" "traefik" "cert-manager")

  for ns in "${namespaces[@]}"; do
    ensure_namespace "${ns}"

    if kubectl get secret "${REGISTRY_PULL_SECRET_NAME}" -n "${ns}" &>/dev/null; then
      log_info "Pull secret already exists in '${ns}'"
    else
      kubectl create secret docker-registry "${REGISTRY_PULL_SECRET_NAME}" \
        --docker-server="${REGISTRY}" \
        --docker-username="${REGISTRY_USER}" \
        --docker-password="${REGISTRY_PASS}" \
        -n "${ns}"
      log_success "Created pull secret in '${ns}'"
    fi
  done

  # --- Configure containerd registry credentials in the VM ---
  log_info "Configuring containerd registry credentials in K3s VM..."
  limactl shell "${LIMA_VM_NAME}" sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<EOF
configs:
  "${REGISTRY}":
    auth:
      username: "${REGISTRY_USER}"
      password: "${REGISTRY_PASS}"
    tls:
      insecure_skip_verify: false
EOF

  # Restart K3s to pick up the new registries.yaml
  log_info "Restarting K3s to apply registry configuration..."
  limactl shell "${LIMA_VM_NAME}" sudo systemctl restart k3s
  sleep 5

  # Wait for K3s to come back
  log_info "Waiting for K3s to come back online..."
  local attempts=0
  while ! kubectl get nodes &>/dev/null; do
    attempts=$((attempts + 1))
    if [[ ${attempts} -ge 30 ]]; then
      log_error "K3s did not come back within 30 seconds after restart"
      exit 1
    fi
    sleep 1
  done
  log_success "K3s is back online with registry credentials configured"
}

# =============================================================================
# Phase 1.3: OpenBao
# =============================================================================
phase_openbao() {
  log_phase "Phase 1.3 — OpenBao"

  ensure_namespace "openbao"

  helm_install_if_needed "openbao" "${K8_DIR}/services/openbao" "openbao"

  log_info "Waiting for OpenBao pods (this may take a minute)..."
  # OpenBao starts unsealed=false, so pods may not be "Ready" until init.
  # Wait for the pod to at least be Running.
  local attempts=0
  while true; do
    local phase
    phase=$(kubectl get pods -n openbao -l app.kubernetes.io/name=openbao \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    if [[ "${phase}" == "Running" ]]; then
      log_success "OpenBao pod is Running"
      break
    fi
    attempts=$((attempts + 1))
    if [[ ${attempts} -ge 120 ]]; then
      log_error "OpenBao pod did not reach Running state within 120s"
      kubectl get pods -n openbao 2>/dev/null || true
      exit 1
    fi
    sleep 1
  done

  # --- Interactive: Init + Unseal ---
  echo ""
  echo -e "${BOLD}${YELLOW}=== INTERACTIVE: OpenBao Init & Unseal ===${NC}"
  echo ""
  echo "OpenBao is running but needs to be initialized and unsealed."
  echo "In a separate terminal, run:"
  echo ""
  echo -e "  ${BOLD}export KUBECONFIG=\${HOME}/.kube/config-k3s${NC}"
  echo ""
  echo -e "  ${BOLD}# Initialize OpenBao${NC}"
  echo -e "  ${BOLD}kubectl exec -n openbao openbao-0 -- bao operator init${NC}"
  echo ""
  echo -e "  ${YELLOW}>> SAVE the unseal keys and root token in your password manager! <<${NC}"
  echo ""
  echo -e "  ${BOLD}# Unseal (repeat with 3 different keys)${NC}"
  echo -e "  ${BOLD}kubectl exec -n openbao openbao-0 -- bao operator unseal <key1>${NC}"
  echo -e "  ${BOLD}kubectl exec -n openbao openbao-0 -- bao operator unseal <key2>${NC}"
  echo -e "  ${BOLD}kubectl exec -n openbao openbao-0 -- bao operator unseal <key3>${NC}"
  echo ""
  read -rp "Press ENTER when OpenBao is initialized and unsealed... "
  echo ""

  # Verify OpenBao is unsealed
  local sealed
  sealed=$(kubectl exec -n openbao openbao-0 -- bao status -format=json 2>/dev/null \
           | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['sealed'])" 2>/dev/null || echo "true")
  if [[ "${sealed}" == "false" ]]; then
    log_success "OpenBao is unsealed and ready"
  else
    log_warn "OpenBao may still be sealed. Continuing anyway..."
  fi

  # --- Interactive: Bootstrap secrets ---
  echo ""
  echo -e "${BOLD}${YELLOW}=== INTERACTIVE: Bootstrap Secrets ===${NC}"
  echo ""
  echo "Please store the following secrets in OpenBao now:"
  echo ""
  echo "  - DNS provider credentials (GCP service account JSON, AWS keys)"
  echo "  - Registry pull credentials (for ESO to manage pull secrets)"
  echo "  - Any other secrets referenced by ExternalSecrets"
  echo ""
  echo "Example (in another terminal):"
  echo ""
  echo -e "  ${BOLD}kubectl exec -it -n openbao openbao-0 -- bao login${NC}"
  echo -e "  ${BOLD}kubectl exec -it -n openbao openbao-0 -- bao secrets enable -path=secret kv-v2${NC}"
  echo -e "  ${BOLD}kubectl exec -it -n openbao openbao-0 -- bao auth enable kubernetes${NC}"
  echo -e "  ${BOLD}kubectl exec -it -n openbao openbao-0 -- bao write auth/kubernetes/config \\${NC}"
  echo -e "  ${BOLD}  kubernetes_host=\"https://\\\$KUBERNETES_PORT_443_TCP_ADDR:443\"${NC}"
  echo ""
  echo -e "  ${BOLD}# Create policy for ESO${NC}"
  echo -e "  ${BOLD}kubectl exec -it -n openbao openbao-0 -- bao policy write external-secrets - <<'POLICY'${NC}"
  echo -e "  ${BOLD}path \"secret/data/*\" { capabilities = [\"read\"] }${NC}"
  echo -e "  ${BOLD}path \"secret/metadata/*\" { capabilities = [\"read\", \"list\"] }${NC}"
  echo -e "  ${BOLD}POLICY${NC}"
  echo ""
  echo -e "  ${BOLD}kubectl exec -it -n openbao openbao-0 -- bao write auth/kubernetes/role/external-secrets \\${NC}"
  echo -e "  ${BOLD}  bound_service_account_names=external-secrets \\${NC}"
  echo -e "  ${BOLD}  bound_service_account_namespaces=external-secrets \\${NC}"
  echo -e "  ${BOLD}  policies=external-secrets ttl=1h${NC}"
  echo ""
  echo -e "  ${BOLD}# Store secrets${NC}"
  echo -e "  ${BOLD}kubectl exec -it -n openbao openbao-0 -- bao kv put secret/dns/google-cloud \\${NC}"
  echo -e "  ${BOLD}  credentials=@/path/to/gcp-service-account.json${NC}"
  echo -e "  ${BOLD}kubectl exec -it -n openbao openbao-0 -- bao kv put secret/k8s/registry \\${NC}"
  echo -e "  ${BOLD}  server=\"https://artifactory.cfapps.cool\" \\${NC}"
  echo -e "  ${BOLD}  username=\"<pull-user>\" password=\"<pull-token>\"${NC}"
  echo ""
  read -rp "Press ENTER when bootstrap secrets have been stored... "

  log_success "OpenBao phase complete"
}

# =============================================================================
# Phase 1.4: External Secrets Operator (ESO)
# =============================================================================
phase_eso() {
  log_phase "Phase 1.4 — External Secrets Operator"

  ensure_namespace "external-secrets"

  helm_install_if_needed "external-secrets" "${K8_DIR}/platform/external-secrets" "external-secrets"

  log_info "Waiting for ESO pods..."
  wait_for_pods "external-secrets" 120

  # Apply ClusterSecretStore and registry pull secret ExternalSecret
  log_info "Applying ClusterSecretStore and registry pull secret..."
  apply_if_exists "${K8_DIR}/platform/external-secrets/cluster-secret-store.yaml"
  apply_if_exists "${K8_DIR}/platform/external-secrets/registry-pull-secret.yaml"

  # Wait for ClusterSecretStore to be valid
  log_info "Waiting for ClusterSecretStore to become valid..."
  local attempts=0
  while true; do
    local status
    status=$(kubectl get clustersecretstore -o jsonpath='{.items[0].status.conditions[0].status}' 2>/dev/null || echo "Unknown")
    if [[ "${status}" == "True" ]]; then
      log_success "ClusterSecretStore is valid"
      break
    fi
    attempts=$((attempts + 1))
    if [[ ${attempts} -ge 60 ]]; then
      log_warn "ClusterSecretStore did not become valid within 60s"
      kubectl get clustersecretstore 2>/dev/null || true
      break
    fi
    sleep 2
  done

  log_success "ESO phase complete"
}

# =============================================================================
# Phase 1.5: MetalLB
# =============================================================================
phase_metallb() {
  log_phase "Phase 1.5 — MetalLB"

  ensure_namespace "metallb-system"

  helm_install_if_needed "metallb" "${K8_DIR}/infrastructure/metallb" "metallb-system"

  log_info "Waiting for MetalLB pods..."
  wait_for_pods "metallb-system" 120

  # Apply IP address pool
  log_info "Applying MetalLB IP address pool..."
  apply_if_exists "${K8_DIR}/infrastructure/metallb/ip-pool.yaml"

  log_success "MetalLB phase complete"
}

# =============================================================================
# Phase 1.6: Traefik
# =============================================================================
phase_traefik() {
  log_phase "Phase 1.6 — Traefik"

  ensure_namespace "traefik"

  helm_install_if_needed "traefik" "${K8_DIR}/infrastructure/traefik" "traefik"

  # Wait for LoadBalancer IP assignment
  log_info "Waiting for Traefik LoadBalancer IP..."
  local attempts=0
  local lb_ip=""
  while true; do
    lb_ip=$(kubectl get svc -n traefik traefik \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "${lb_ip}" ]]; then
      break
    fi
    attempts=$((attempts + 1))
    if [[ ${attempts} -ge 60 ]]; then
      log_warn "LoadBalancer IP not assigned within 60s"
      kubectl get svc -n traefik 2>/dev/null || true
      break
    fi
    sleep 2
  done

  if [[ -n "${lb_ip}" ]]; then
    log_success "Traefik LoadBalancer IP: ${lb_ip}"
    echo ""
    echo -e "  ${BOLD}Add to your DNS or /etc/hosts:${NC}"
    echo -e "  ${lb_ip}  *.${BASE_DOMAIN}"
  else
    log_warn "No LoadBalancer IP assigned yet. Check MetalLB and Traefik configuration."
  fi

  log_success "Traefik phase complete"
}

# =============================================================================
# Phase 1.7: cert-manager
# =============================================================================
phase_certmanager() {
  log_phase "Phase 1.7 — cert-manager"

  ensure_namespace "cert-manager"

  helm_install_if_needed "cert-manager" "${K8_DIR}/infrastructure/cert-manager" "cert-manager"

  log_info "Waiting for cert-manager pods..."
  wait_for_pods "cert-manager" 120

  # Apply DNS ExternalSecret, ClusterIssuer, and wildcard certificate
  log_info "Applying cert-manager resources..."
  apply_if_exists "${K8_DIR}/infrastructure/cert-manager/dns-external-secret.yaml"

  # Wait a moment for the ExternalSecret to sync before applying the issuer
  log_info "Waiting for DNS credentials ExternalSecret to sync..."
  sleep 5

  # ClusterIssuer uses envsubst for GCP_PROJECT_ID from config.env
  if [[ -z "${GCP_PROJECT_ID:-}" ]]; then
    log_warn "GCP_PROJECT_ID is empty in config.env — ClusterIssuer will need updating later"
  fi
  envsubst < "${K8_DIR}/infrastructure/cert-manager/clusterissuer.yaml" | kubectl apply -f -
  log_success "Applied clusterissuer.yaml"
  apply_if_exists "${K8_DIR}/infrastructure/cert-manager/wildcard-certificate.yaml"

  # Wait for the wildcard certificate to be issued
  log_info "Waiting for wildcard certificate to be issued (this may take a few minutes)..."
  local attempts=0
  while true; do
    local ready
    ready=$(kubectl get certificate -n traefik \
            -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "${ready}" == "True" ]]; then
      log_success "Wildcard certificate issued successfully"
      break
    fi
    attempts=$((attempts + 1))
    if [[ ${attempts} -ge 90 ]]; then
      log_warn "Certificate not issued within 3 minutes. Check cert-manager logs."
      kubectl get certificate -A 2>/dev/null || true
      kubectl get certificaterequest -A 2>/dev/null || true
      break
    fi
    sleep 2
  done

  log_success "cert-manager phase complete"
}

# =============================================================================
# Phase: TLS Store (post cert-manager)
# =============================================================================
phase_tls_store() {
  log_phase "Applying TLS Store"

  apply_if_exists "${K8_DIR}/infrastructure/traefik/tls-store.yaml"

  log_success "TLS Store applied"
}

# =============================================================================
# Print Status Summary
# =============================================================================
print_summary() {
  log_phase "Bootstrap Complete — Status Summary"

  echo -e "${BOLD}Cluster Nodes:${NC}"
  kubectl get nodes -o wide 2>/dev/null || echo "  (unable to reach cluster)"
  echo ""

  echo -e "${BOLD}Namespaces:${NC}"
  kubectl get namespaces 2>/dev/null || true
  echo ""

  echo -e "${BOLD}Pods (all namespaces):${NC}"
  kubectl get pods -A 2>/dev/null || true
  echo ""

  echo -e "${BOLD}Services (LoadBalancer):${NC}"
  kubectl get svc -A --field-selector spec.type=LoadBalancer 2>/dev/null || true
  echo ""

  echo -e "${BOLD}Certificates:${NC}"
  kubectl get certificates -A 2>/dev/null || true
  echo ""

  local lb_ip
  lb_ip=$(kubectl get svc -n traefik traefik \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")

  echo -e "${BOLD}${GREEN}Endpoints:${NC}"
  echo -e "  Traefik LB IP:   ${lb_ip}"
  echo -e "  Base domain:     *.${BASE_DOMAIN}"
  echo ""

  local kubeconfig_file="${HOME}/.kube/config-k3s"
  echo -e "${BOLD}Next steps:${NC}"
  echo -e "  1. export KUBECONFIG=${kubeconfig_file}"
  echo -e "  2. Add DNS records pointing *.${BASE_DOMAIN} to ${lb_ip}"
  echo -e "  3. Continue with Phase 2: ./stack.sh deploy platform"
  echo ""
}

# =============================================================================
# Main — Run all phases or specific ones
# =============================================================================
main() {
  echo -e "${BOLD}${CYAN}"
  echo "  _  ___   ___       ____              _____ _             _    "
  echo " | |/ / | | __|___  |  _ \\  _____   __/ ____| |_ __ _  __| | __"
  echo " | ' /| |_| _|/ __| | | | |/ _ \\ \\ / / (___ | __/ _\` |/ _\` |/ /"
  echo " | . \\|  _  |_\\__ \\ | |_| |  __/\\ V / \\___ \\| || (_| | (_| |  \\ "
  echo " |_|\\_\\_| |_(_)___/ |____/ \\___| \\_/  |____/ \\__\\__,_|\\__,_|\\_\\"
  echo -e "${NC}"
  echo -e "${BOLD}  K8s DevOps Stack — Bootstrap${NC}"
  echo ""

  if [[ $# -gt 0 ]]; then
    # Run specific phases
    for phase in "$@"; do
      if declare -f "${phase}" &>/dev/null; then
        "${phase}"
      else
        log_error "Unknown phase: ${phase}"
        echo "Available phases: check_prerequisites phase_k3s phase_pull_secrets"
        echo "                  phase_openbao phase_eso phase_metallb phase_traefik"
        echo "                  phase_certmanager phase_tls_store print_summary"
        exit 1
      fi
    done
  else
    # Run everything
    check_prerequisites
    phase_k3s
    phase_pull_secrets
    phase_openbao
    phase_eso
    phase_metallb
    phase_traefik
    phase_certmanager
    phase_tls_store
    print_summary
  fi
}

main "$@"
