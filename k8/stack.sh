#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# K8s DevOps Stack — Master Management Script
# =============================================================================
# Runs on the HOST (macOS). Manages Lima VM + K3s cluster lifecycle.
# Usage: ./stack.sh {start|stop|status|restart|backup} [options]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/config.env" ]]; then
    echo "ERROR: ${SCRIPT_DIR}/config.env not found" >&2
    exit 1
fi
# shellcheck source=config.env
source "${SCRIPT_DIR}/config.env"

KUBECONFIG_HOST="${HOME}/.kube/config-k3s"

# Domain fallbacks (support both old BASE_DOMAIN and new PLATFORM_DOMAIN/APPS_DOMAIN)
PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-${BASE_DOMAIN:-development.cfapps.cool}}"
APPS_DOMAIN="${APPS_DOMAIN:-app.cfapps.cool}"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
header(){ printf "\n${BOLD}${CYAN}=== %s ===${NC}\n\n" "$*"; }

# Print a table row: label, value, optional color
row() {
    local label="$1" value="$2" color="${3:-$NC}"
    printf "  ${BOLD}%-22s${NC} ${color}%s${NC}\n" "${label}:" "$value"
}

# Check if a command exists
require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        err "$1 is not installed"
        return 1
    fi
}

# Check if Lima VM is running
vm_is_running() {
    limactl list --json 2>/dev/null \
        | jq -e --arg name "$LIMA_VM_NAME" \
            'select(.name == $name and .status == "Running")' &>/dev/null
}

# Get Lima VM IP address
vm_ip() {
    limactl shell "$LIMA_VM_NAME" hostname -I 2>/dev/null | awk '{print $1}'
}

# Run kubectl with a timeout, suppress errors if requested
kube() {
    kubectl --request-timeout=10s "$@"
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
cmd_start() {
    header "Starting K8s DevOps Stack"

    # 1. Check Lima
    info "Checking prerequisites..."
    require_cmd limactl
    require_cmd kubectl
    require_cmd jq

    # 2. Start Lima VM
    if vm_is_running; then
        ok "Lima VM '${LIMA_VM_NAME}' is already running"
    else
        info "Starting Lima VM '${LIMA_VM_NAME}'..."
        limactl start "$LIMA_VM_NAME" 2>&1 | tail -3
        ok "Lima VM started"
    fi

    # 3. Wait for K3s API server
    info "Waiting for K3s API server..."
    local retries=12
    for ((i=1; i<=retries; i++)); do
        if kubectl get nodes --request-timeout=5s &>/dev/null; then
            ok "K3s API server is reachable"
            break
        fi
        if [[ $i -eq $retries ]]; then
            err "K3s API server not reachable after 60s"
            exit 1
        fi
        sleep 5
    done

    # 4. Update kubeconfig on host
    info "Updating kubeconfig on host..."
    local vm_addr
    vm_addr="$(vm_ip)"
    if [[ -n "$vm_addr" ]]; then
        limactl shell "$LIMA_VM_NAME" sudo cat /etc/rancher/k3s/k3s.yaml 2>/dev/null \
            | sed "s/127\.0\.0\.1/${vm_addr}/g" \
            | sed "s/default/k3s-${LIMA_VM_NAME}/g" \
            > "${KUBECONFIG_HOST}.k3s-tmp"
        # Merge with existing kubeconfig if present
        if [[ -f "$KUBECONFIG_HOST" ]]; then
            KUBECONFIG="${KUBECONFIG_HOST}:${KUBECONFIG_HOST}.k3s-tmp" \
                kubectl config view --flatten > "${KUBECONFIG_HOST}.merged"
            mv "${KUBECONFIG_HOST}.merged" "$KUBECONFIG_HOST"
            rm -f "${KUBECONFIG_HOST}.k3s-tmp"
        else
            mv "${KUBECONFIG_HOST}.k3s-tmp" "$KUBECONFIG_HOST"
        fi
        chmod 600 "$KUBECONFIG_HOST"
        kubectl config use-context "k3s-${LIMA_VM_NAME}" &>/dev/null || true
        ok "Kubeconfig updated (VM IP: ${vm_addr})"
    else
        warn "Could not determine VM IP — skipping kubeconfig update"
    fi

    # 5. Wait for core pods (all phases)
    info "Waiting for core pods..."
    local core_namespaces=(
        kube-system
        openbao
        external-secrets
        metallb-system
        traefik
        cert-manager
    )
    for ns in "${core_namespaces[@]}"; do
        wait_for_namespace "$ns" 60 || true
    done

    # 5b. Auto-unseal OpenBao (required before ESO can sync secrets)
    auto_unseal_openbao

    # 6. Wait for platform pods
    info "Waiting for platform pods..."
    local platform_namespaces=(
        argocd
        portainer
        garage
        technitium
        velero
    )
    for ns in "${platform_namespaces[@]}"; do
        wait_for_namespace "$ns" 30 || true
    done

    # 6b. Ensure Velero BSL default is set
    if kube get namespace velero &>/dev/null; then
        local bsl_name
        bsl_name=$(kubectl get backupstoragelocation -n velero --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
        if [ -n "$bsl_name" ]; then
            kubectl patch backupstoragelocation "$bsl_name" -n velero \
                --type='json' -p='[{"op":"add","path":"/spec/default","value":true}]' 2>/dev/null || true
        fi
    fi

    # 7. Wait for monitoring pods
    local monitoring_namespaces=(
        loki
        mimir
        tempo
        grafana
        alloy
        monitoring
    )
    for ns in "${monitoring_namespaces[@]}"; do
        wait_for_namespace "$ns" 30 || true
    done

    # 8. Wait for service pods
    local service_namespaces=(
        artifact-keeper
        gitlab
        gitlab-runner
    )
    for ns in "${service_namespaces[@]}"; do
        wait_for_namespace "$ns" 30 || true
    done

    # 9. Optional: CF namespaces
    local cf_namespaces=(korifi korifi-gateway cf)
    for ns in "${cf_namespaces[@]}"; do
        if kube get namespace "$ns" &>/dev/null; then
            wait_for_namespace "$ns" 30 || true
        fi
    done

    # 10. OpenBao seal status
    check_openbao_seal

    # 11. ArgoCD sync status
    check_argocd_sync

    # 12. Print endpoint table
    print_endpoints

    ok "Stack is up"
}

# Wait for all pods in a namespace to be Ready (up to $2 seconds)
wait_for_namespace() {
    local ns="$1" timeout="${2:-60}"
    # Skip if namespace does not exist
    if ! kube get namespace "$ns" &>/dev/null; then
        return 0
    fi
    # Skip if no pods
    local pod_count
    pod_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$pod_count" -eq 0 ]]; then
        return 0
    fi
    info "  Waiting for pods in ${ns}..."
    if kubectl wait --for=condition=Ready pods --all \
        -n "$ns" --timeout="${timeout}s" &>/dev/null; then
        ok "  All pods ready in ${ns}"
    else
        warn "  Some pods in ${ns} are not ready after ${timeout}s"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------
cmd_stop() {
    local do_backup=false
    for arg in "$@"; do
        [[ "$arg" == "--backup" ]] && do_backup=true
    done

    header "Stopping K8s DevOps Stack"

    if $do_backup; then
        info "Backup requested before shutdown"
        cmd_backup
    fi

    require_cmd limactl

    if vm_is_running; then
        info "Stopping Lima VM '${LIMA_VM_NAME}'..."
        limactl stop "$LIMA_VM_NAME"
        ok "Lima VM stopped"
    else
        ok "Lima VM '${LIMA_VM_NAME}' is already stopped"
    fi
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
cmd_status() {
    header "K8s DevOps Stack Status"

    require_cmd limactl
    require_cmd kubectl
    require_cmd jq

    # 1. Lima VM status
    printf "${BOLD}Lima VM${NC}\n"
    if vm_is_running; then
        local ip cpus memory disk
        ip="$(vm_ip)"
        cpus="${LIMA_CPUS}"
        memory="${LIMA_MEMORY_GB}GB"
        disk="${LIMA_DISK_GB}GB"
        row "Status"    "Running"   "$GREEN"
        row "IP"        "${ip:-unknown}"
        row "Resources" "${cpus} CPU / ${memory} RAM / ${disk} Disk"
    else
        row "Status" "Stopped" "$RED"
        return 0
    fi
    echo

    # 2. K3s node status
    printf "${BOLD}K3s Nodes${NC}\n"
    if kubectl get nodes --request-timeout=5s &>/dev/null; then
        kubectl get nodes -o wide 2>/dev/null | sed 's/^/  /'
    else
        warn "K3s API not reachable"
        return 0
    fi
    echo

    # 3. Resource usage
    printf "${BOLD}Resource Usage${NC}\n"
    kubectl top nodes 2>/dev/null | sed 's/^/  /' || info "  metrics-server not available"
    echo

    # 3b. VM disk usage
    printf "${BOLD}VM Disk${NC}\n"
    local disk_info
    disk_info=$(limactl shell "$LIMA_VM_NAME" df -h / 2>/dev/null | tail -1)
    if [[ -n "$disk_info" ]]; then
        local disk_size disk_used disk_avail disk_pct
        disk_size=$(echo "$disk_info" | awk '{print $2}')
        disk_used=$(echo "$disk_info" | awk '{print $3}')
        disk_avail=$(echo "$disk_info" | awk '{print $4}')
        disk_pct=$(echo "$disk_info" | awk '{print $5}')
        local pct_num=${disk_pct%%%}
        local color="$GREEN"
        [[ $pct_num -ge 80 ]] && color="$YELLOW"
        [[ $pct_num -ge 90 ]] && color="$RED"
        row "Total"     "$disk_size"
        row "Used"      "$disk_used ($disk_pct)" "$color"
        row "Available" "$disk_avail"
    else
        warn "  Could not read VM disk usage"
    fi
    echo

    # 4. Namespace overview
    printf "${BOLD}Namespaces${NC}\n"
    printf "  ${BOLD}%-24s %-8s %-8s %-8s${NC}\n" "NAMESPACE" "TOTAL" "READY" "NOT-READY"
    while IFS= read -r ns; do
        local total ready not_ready
        total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ready=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
            | awk '$3=="Running" || $3=="Completed" {print}' | wc -l | tr -d ' ')
        not_ready=$((total - ready))
        local color="$GREEN"
        [[ $not_ready -gt 0 ]] && color="$YELLOW"
        [[ $total -eq 0 ]] && color="$NC"
        printf "  %-24s %-8s ${GREEN}%-8s${NC} ${color}%-8s${NC}\n" \
            "$ns" "$total" "$ready" "$not_ready"
    done < <(kubectl get namespaces --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
    echo

    # 5. OpenBao seal status
    check_openbao_seal

    # 6. ArgoCD sync status
    check_argocd_sync

    # 7. Certificate expiry dates
    printf "${BOLD}TLS Certificates${NC}\n"
    if kubectl get certificates --all-namespaces --no-headers &>/dev/null 2>&1; then
        local cert_output
        cert_output=$(kubectl get certificates --all-namespaces \
            -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,EXPIRY:.status.notAfter" \
            2>/dev/null)
        if [[ -n "$cert_output" ]]; then
            echo "$cert_output" | sed 's/^/  /'
        else
            info "  No certificates found"
        fi
    else
        info "  cert-manager not deployed or no certificates"
    fi
    echo

    # 8. Endpoints with reachability
    print_endpoints_with_check
}

# ---------------------------------------------------------------------------
# restart
# ---------------------------------------------------------------------------
cmd_restart() {
    cmd_stop "$@"
    cmd_start
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
cmd_backup() {
    header "Velero Backup"

    require_cmd kubectl

    # Check velero CLI
    if ! command -v velero &>/dev/null; then
        # Fall back to kubectl
        warn "velero CLI not installed — using kubectl"
        kubectl_velero_backup
        return
    fi

    info "Creating Velero backup..."
    local backup_name="manual-$(date +%Y%m%d-%H%M%S)"

    velero backup create "$backup_name" --wait
    ok "Backup '${backup_name}' completed"

    info "Backup details:"
    velero backup describe "$backup_name" | sed 's/^/  /'
}

kubectl_velero_backup() {
    if ! kube get namespace velero &>/dev/null; then
        err "Velero is not deployed (namespace 'velero' not found)"
        exit 1
    fi

    local backup_name="manual-$(date +%Y%m%d-%H%M%S)"
    info "Creating backup '${backup_name}' via kubectl..."

    kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${backup_name}
  namespace: velero
spec:
  includedNamespaces:
  - '*'
  storageLocation: default
  ttl: 720h0m0s
YAML

    info "Waiting for backup to complete (timeout 10m)..."
    local retries=60
    for ((i=1; i<=retries; i++)); do
        local phase
        phase=$(kubectl get backup "$backup_name" -n velero \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        case "$phase" in
            Completed)
                ok "Backup '${backup_name}' completed successfully"
                return 0
                ;;
            Failed|PartiallyFailed)
                err "Backup '${backup_name}' failed (phase: ${phase})"
                return 1
                ;;
        esac
        sleep 10
    done
    err "Backup timed out after 10 minutes"
    return 1
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

auto_unseal_openbao() {
    if ! kube get namespace openbao &>/dev/null; then
        return
    fi
    local unseal_script="${SCRIPT_DIR}/unseal.sh"
    if [[ ! -f "$unseal_script" ]]; then
        return
    fi

    # Wait for OpenBao pod to be running
    local pod
    for ((i=1; i<=12; i++)); do
        pod=$(kubectl get pods -n openbao -l app.kubernetes.io/name=openbao \
            --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
        if [[ -n "$pod" ]]; then
            local phase
            phase=$(kubectl get pod -n openbao "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
            [[ "$phase" == "Running" ]] && break
        fi
        sleep 5
    done

    if [[ -z "$pod" ]]; then
        warn "OpenBao pod not found — skipping auto-unseal"
        return
    fi

    # Check if already unsealed
    local sealed
    sealed=$(kubectl exec -n openbao "$pod" -- bao status -format=json 2>/dev/null \
        | jq -r '.sealed' 2>/dev/null || echo "unknown")

    if [[ "$sealed" == "false" ]]; then
        ok "OpenBao is already unsealed"
        return
    fi

    info "Auto-unsealing OpenBao..."
    # Extract unseal keys from unseal.sh (lines with 'bao operator unseal')
    local keys
    keys=$(grep 'bao operator unseal' "$unseal_script" | sed 's/.*unseal //' | tr -d '\r')
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        kubectl exec -n openbao "$pod" -- bao operator unseal "$key" &>/dev/null || true
    done <<< "$keys"

    # Verify
    sealed=$(kubectl exec -n openbao "$pod" -- bao status -format=json 2>/dev/null \
        | jq -r '.sealed' 2>/dev/null || echo "unknown")
    if [[ "$sealed" == "false" ]]; then
        ok "OpenBao auto-unsealed successfully"
        # Give ESO a moment to sync secrets
        sleep 5
    else
        warn "OpenBao auto-unseal failed — manual unseal required"
    fi
}

check_openbao_seal() {
    if ! kube get namespace openbao &>/dev/null; then
        return
    fi
    printf "${BOLD}OpenBao${NC}\n"
    local pod
    pod=$(kubectl get pods -n openbao -l app.kubernetes.io/name=openbao \
        --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
    if [[ -z "$pod" ]]; then
        warn "  No OpenBao pod found"
        return
    fi
    local sealed
    sealed=$(kubectl exec -n openbao "$pod" -- bao status -format=json 2>/dev/null \
        | jq -r '.sealed' 2>/dev/null || echo "unknown")
    if [[ "$sealed" == "false" ]]; then
        row "Seal Status" "Unsealed" "$GREEN"
    elif [[ "$sealed" == "true" ]]; then
        row "Seal Status" "SEALED — manual unseal required!" "$RED"
    else
        row "Seal Status" "Unknown (pod may be initializing)" "$YELLOW"
    fi
    echo
}

check_argocd_sync() {
    if ! kube get namespace argocd &>/dev/null; then
        return
    fi
    printf "${BOLD}ArgoCD Applications${NC}\n"
    local apps
    apps=$(kubectl get applications.argoproj.io -n argocd --no-headers \
        -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status" \
        2>/dev/null || true)
    if [[ -n "$apps" ]]; then
        echo "$apps" | while IFS= read -r line; do
            printf "  %s\n" "$line"
        done
    else
        info "  No ArgoCD applications found"
    fi
    echo
}

# Build the list of all endpoints dynamically
get_endpoints() {
    # Format: "Name|URL"
    local endpoints=(
        # Phase 1 - Foundation
        "Traefik Dashboard|https://traefik.${PLATFORM_DOMAIN}"
        # Phase 2 - Platform
        "ArgoCD|https://argocd.${PLATFORM_DOMAIN}"
        "Portainer|https://portainer.${PLATFORM_DOMAIN}"
        "S3 (Garage)|https://s3.${PLATFORM_DOMAIN}"
        "S3 Manager|https://s3-manager.${PLATFORM_DOMAIN}"
        "Technitium DNS|https://dns.${PLATFORM_DOMAIN}"
        "Velero Backup|https://backup.${PLATFORM_DOMAIN}"
        # Phase 3 - Monitoring
        "Grafana|https://grafana.${PLATFORM_DOMAIN}"
        # Phase 4 - Services
        "artifact-keeper|https://artifacts.${PLATFORM_DOMAIN}"
        "OpenBao|https://vault.${PLATFORM_DOMAIN}"
    )

    # Phase 5 - GitLab (only if namespace exists)
    if kube get namespace gitlab &>/dev/null 2>&1; then
        endpoints+=(
            "GitLab CE|https://gitlab.${PLATFORM_DOMAIN}"
        )
    fi

    # Phase 6 - Cloud Foundry (only if namespace exists)
    if kube get namespace korifi &>/dev/null 2>&1; then
        endpoints+=(
            "CF API|https://api.${APPS_DOMAIN}"
        )
    fi

    printf '%s\n' "${endpoints[@]}"
}

print_endpoints() {
    printf "${BOLD}Endpoints${NC}\n"
    while IFS='|' read -r name url; do
        row "$name" "$url"
    done < <(get_endpoints)
    echo

    # SSH services
    if kube get namespace gitlab &>/dev/null 2>&1; then
        printf "${BOLD}SSH Services${NC}\n"
        row "GitLab SSH" "ssh git@192.168.64.202"
        echo
    fi

    # DNS services
    if kube get namespace technitium &>/dev/null 2>&1; then
        printf "${BOLD}DNS Service${NC}\n"
        local dns_ip
        dns_ip=$(kubectl get svc technitium-dns -n technitium -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "192.168.64.201")
        row "Technitium DNS" "${dns_ip}:53"
        echo
    fi
}

print_endpoints_with_check() {
    printf "${BOLD}Endpoints${NC}\n"
    while IFS='|' read -r name url; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 \
            --max-time 5 -k "$url" 2>/dev/null || echo "000")
        local color="$RED"
        local status_label="DOWN (${code})"
        if [[ "$code" =~ ^(200|301|302|303|307|308|401|403)$ ]]; then
            color="$GREEN"
            status_label="UP (${code})"
        fi
        printf "  ${BOLD}%-22s${NC} %-50s ${color}%s${NC}\n" \
            "${name}:" "$url" "$status_label"
    done < <(get_endpoints)
    echo
}

# ---------------------------------------------------------------------------
# Renew Certificates
# ---------------------------------------------------------------------------
cmd_renewcerts() {
    header "Renewing TLS Certificates"

    local certs
    certs=$(kubectl get certificates -A -o json 2>/dev/null)
    local count
    count=$(echo "$certs" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        warn "No certificates found"
        return
    fi

    info "Found ${count} certificate(s)"
    echo

    # Show current certificate status
    printf "  ${BOLD}%-40s %-10s %-12s %s${NC}\n" "CERTIFICATE" "NAMESPACE" "READY" "EXPIRY"
    echo "$certs" | python3 -c "
import json, sys
certs = json.load(sys.stdin).get('items', [])
for c in certs:
    name = c['metadata']['name']
    ns = c['metadata']['namespace']
    ready = 'Unknown'
    for cond in c.get('status', {}).get('conditions', []):
        if cond['type'] == 'Ready':
            ready = cond['status']
    expiry = c.get('status', {}).get('notAfter', 'n/a')
    print(f'  {name:40s} {ns:10s} {ready:12s} {expiry}')
"
    echo

    # Trigger renewal by deleting the secrets — cert-manager will re-issue
    info "Triggering renewal..."
    echo "$certs" | python3 -c "
import json, sys
certs = json.load(sys.stdin).get('items', [])
for c in certs:
    ns = c['metadata']['namespace']
    secret = c['spec'].get('secretName', '')
    if secret:
        print(f'{ns}/{secret}')
" | while IFS='/' read -r ns secret; do
        kubectl delete secret "$secret" -n "$ns" 2>/dev/null && \
            ok "  Deleted ${ns}/${secret} — cert-manager will re-issue" || \
            warn "  Could not delete ${ns}/${secret}"
    done

    echo
    info "Waiting for certificates to be re-issued..."
    sleep 10

    # Check status after renewal
    local all_ready=true
    kubectl get certificates -A --no-headers 2>/dev/null | while read -r ns name ready secret age; do
        if [[ "$ready" == "True" ]]; then
            ok "  ${ns}/${name}: Ready"
        else
            warn "  ${ns}/${name}: ${ready} (may still be issuing)"
            all_ready=false
        fi
    done

    echo
    # Verify reflected secrets are updated
    if kubectl get secret wildcard-apps-tls -n korifi &>/dev/null; then
        local issuer
        issuer=$(kubectl get secret wildcard-apps-tls -n korifi -o jsonpath='{.data.tls\.crt}' | \
            base64 -d | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer= //')
        if [[ "$issuer" == *"Let's Encrypt"* ]]; then
            ok "Reflected cert in korifi namespace: ${issuer}"
        else
            warn "Reflected cert issuer: ${issuer}"
        fi
    fi

    echo
    ok "Certificate renewal triggered"
    info "Run './stack.sh status' to verify all endpoints"
}

# ---------------------------------------------------------------------------
# Extend Disk
# ---------------------------------------------------------------------------
cmd_extenddisk() {
    local new_size="${1:-}"
    if [[ -z "$new_size" ]]; then
        err "Usage: $(basename "$0") extenddisk <size-in-gb>"
        err "Example: $(basename "$0") extenddisk 300"
        exit 1
    fi

    # Validate: must be a number
    if ! [[ "$new_size" =~ ^[0-9]+$ ]]; then
        err "Size must be a number (in GB), got: ${new_size}"
        exit 1
    fi

    local lima_yaml="${HOME}/.lima/${LIMA_VM_NAME}/lima.yaml"
    if [[ ! -f "$lima_yaml" ]]; then
        err "Lima config not found: ${lima_yaml}"
        exit 1
    fi

    # Get current disk size
    local current_size
    current_size=$(grep '^disk:' "$lima_yaml" | head -1 | sed 's/disk: *//;s/GiB//')
    if [[ -z "$current_size" ]]; then
        err "Could not determine current disk size from ${lima_yaml}"
        exit 1
    fi

    # Validate: new size must be larger
    if [[ "$new_size" -le "$current_size" ]]; then
        err "New size (${new_size}GB) must be larger than current size (${current_size}GB)"
        exit 1
    fi

    header "Extending VM Disk"
    info "Current size: ${current_size}GB"
    info "New size:     ${new_size}GB"
    echo

    # Check if VM is running
    local needs_restart=false
    if vm_is_running; then
        warn "VM must be stopped to resize disk"
        info "Stopping VM..."
        limactl stop "$LIMA_VM_NAME" 2>&1 | tail -1
        needs_restart=true
    fi

    # Update lima.yaml
    sed -i '' "s/^disk: .*GiB/disk: ${new_size}GiB/" "$lima_yaml"
    ok "Updated ${lima_yaml}: disk: ${new_size}GiB"

    # Start VM (Lima auto-resizes disk on boot)
    info "Starting VM (disk will be resized automatically)..."
    limactl start "$LIMA_VM_NAME" 2>&1 | tail -3
    ok "VM started with ${new_size}GB disk"

    # Verify
    echo
    local disk_info
    disk_info=$(limactl shell "$LIMA_VM_NAME" df -h / 2>/dev/null | tail -1)
    local disk_total
    disk_total=$(echo "$disk_info" | awk '{print $2}')
    ok "Verified disk size: ${disk_total}"

    # Resize filesystem if needed (usually automatic)
    limactl shell "$LIMA_VM_NAME" sudo resize2fs /dev/vda1 2>/dev/null || true

    if [[ "$needs_restart" == "true" ]]; then
        echo
        info "Run './stack.sh start' to bring the full stack back up"
    fi
}

# ---------------------------------------------------------------------------
# Change Memory
# ---------------------------------------------------------------------------
cmd_extendmem() {
    local new_size="${1:-}"
    if [[ -z "$new_size" ]]; then
        err "Usage: $(basename "$0") extendmem <size-in-gb>"
        err "Example: $(basename "$0") extendmem 32"
        exit 1
    fi

    if ! [[ "$new_size" =~ ^[0-9]+$ ]]; then
        err "Size must be a number (in GB), got: ${new_size}"
        exit 1
    fi

    if [[ "$new_size" -lt 8 ]]; then
        err "Minimum memory is 8GB"
        exit 1
    fi

    local lima_yaml="${HOME}/.lima/${LIMA_VM_NAME}/lima.yaml"
    if [[ ! -f "$lima_yaml" ]]; then
        err "Lima config not found: ${lima_yaml}"
        exit 1
    fi

    local current_size
    current_size=$(grep '^memory:' "$lima_yaml" | head -1 | sed 's/memory: *//;s/GiB//')
    if [[ -z "$current_size" ]]; then
        err "Could not determine current memory from ${lima_yaml}"
        exit 1
    fi

    if [[ "$new_size" -eq "$current_size" ]]; then
        info "Memory is already ${current_size}GB"
        return 0
    fi

    header "Changing VM Memory"
    info "Current: ${current_size}GB"
    info "New:     ${new_size}GB"
    echo

    local needs_restart=false
    if vm_is_running; then
        warn "VM must be stopped to change memory"
        info "Stopping VM..."
        limactl stop "$LIMA_VM_NAME" 2>&1 | tail -1
        needs_restart=true
    fi

    sed -i '' "s/^memory: .*GiB/memory: ${new_size}GiB/" "$lima_yaml"
    ok "Updated ${lima_yaml}: memory: ${new_size}GiB"

    info "Starting VM with ${new_size}GB memory..."
    limactl start "$LIMA_VM_NAME" 2>&1 | tail -3
    ok "VM started with ${new_size}GB memory"

    if [[ "$needs_restart" == "true" ]]; then
        echo
        info "Run './stack.sh start' to bring the full stack back up"
    fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}K8s DevOps Stack Manager${NC}

Usage: $(basename "$0") <command> [options]

Commands:
  start        Start the Lima VM and K3s cluster
  stop         Stop the Lima VM (--backup to backup first)
  status       Show cluster and service status
  restart      Stop then start the stack
  backup       Create a Velero backup
  renewcerts   Force renewal of all TLS certificates
  extenddisk   Extend VM disk size (e.g. extenddisk 300)
  extendmem    Change VM memory in GB (e.g. extendmem 32)

Options:
  --backup    (stop only) Run a Velero backup before stopping

Examples:
  $(basename "$0") start
  $(basename "$0") stop --backup
  $(basename "$0") status
  $(basename "$0") extenddisk 300
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    # Ensure KUBECONFIG is set for all commands
    export KUBECONFIG="${KUBECONFIG_HOST}"

    local command="${1:-}"
    shift || true

    case "$command" in
        start)      cmd_start ;;
        stop)       cmd_stop "$@" ;;
        status)     cmd_status ;;
        restart)    cmd_restart "$@" ;;
        backup)     cmd_backup ;;
        renewcerts) cmd_renewcerts ;;
        extenddisk) cmd_extenddisk "$@" ;;
        extendmem)  cmd_extendmem "$@" ;;
        -h|--help|help)
            usage ;;
        "")
            usage
            exit 1 ;;
        *)
            err "Unknown command: ${command}"
            usage
            exit 1 ;;
    esac
}

main "$@"
