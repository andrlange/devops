#!/usr/bin/env bash
# =============================================================================
# helm.sh — Helm helper functions
# =============================================================================
# Assumes colors.sh has been sourced.
# =============================================================================

# Install a Helm release if not already present
# Usage: helm_install_if_needed <release> <chart_path> <namespace> [extra_args...]
helm_install_if_needed() {
  local release="$1"
  local chart_path="$2"
  local namespace="$3"
  shift 3
  local extra_args=("$@")

  if helm status "$release" -n "$namespace" &>/dev/null; then
    log_info "Helm release '$release' already installed in '$namespace'"
    return 0
  fi

  helm_dependency_build "$chart_path"

  log_info "Installing Helm release '$release' in '$namespace'..."
  if helm install "$release" "$chart_path" -n "$namespace" "${extra_args[@]}" 2>&1; then
    log_success "Helm release '$release' installed"
  else
    log_error "Failed to install Helm release '$release'"
    return 1
  fi
}

# Upgrade a Helm release (install if not present)
# Usage: helm_upgrade <release> <chart_path> <namespace> [extra_args...]
helm_upgrade() {
  local release="$1"
  local chart_path="$2"
  local namespace="$3"
  shift 3
  local extra_args=("$@")

  helm_dependency_build "$chart_path"

  log_info "Upgrading Helm release '$release' in '$namespace'..."
  if helm upgrade --install "$release" "$chart_path" -n "$namespace" "${extra_args[@]}" 2>&1; then
    log_success "Helm release '$release' upgraded"
  else
    log_error "Failed to upgrade Helm release '$release'"
    return 1
  fi
}

# Build Helm chart dependencies
helm_dependency_build() {
  local chart_path="$1"

  if [[ ! -f "${chart_path}/Chart.yaml" ]]; then
    log_debug "No Chart.yaml at $chart_path — skipping dependency build"
    return 0
  fi

  # Check if chart has dependencies defined
  if ! grep -q "dependencies:" "${chart_path}/Chart.yaml" 2>/dev/null; then
    log_debug "No dependencies in ${chart_path}/Chart.yaml"
    return 0
  fi

  log_info "Building Helm dependencies for ${chart_path}..."
  if helm dependency build "$chart_path" 2>/dev/null; then
    log_debug "Dependencies built successfully"
  elif helm dependency update "$chart_path" 2>/dev/null; then
    log_debug "Dependencies updated successfully"
  else
    log_warn "Could not build/update dependencies for ${chart_path}"
    return 1
  fi
}

# Ensure a Kubernetes namespace exists
ensure_namespace() {
  local ns="$1"
  if kubectl get namespace "$ns" &>/dev/null; then
    log_debug "Namespace '$ns' already exists"
  else
    kubectl create namespace "$ns"
    log_success "Created namespace '$ns'"
  fi
}

# Apply a manifest file if it exists
apply_manifest() {
  local manifest="$1"
  if [[ ! -f "$manifest" ]]; then
    log_error "Manifest not found: $manifest"
    return 1
  fi
  if kubectl apply -f "$manifest" 2>&1; then
    log_success "Applied ${manifest##*/}"
  else
    log_error "Failed to apply ${manifest##*/}"
    return 1
  fi
}

# Apply a manifest with envsubst
apply_manifest_envsubst() {
  local manifest="$1"
  if [[ ! -f "$manifest" ]]; then
    log_error "Manifest not found: $manifest"
    return 1
  fi
  if envsubst < "$manifest" | kubectl apply -f - 2>&1; then
    log_success "Applied ${manifest##*/} (with envsubst)"
  else
    log_error "Failed to apply ${manifest##*/}"
    return 1
  fi
}

# Wait for all pods in a namespace to be Ready
wait_for_pods() {
  local namespace="$1"
  local timeout="${2:-120}"
  log_info "Waiting for pods in '$namespace' to be ready (timeout: ${timeout}s)..."
  if kubectl wait --for=condition=Ready pods --all \
       -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
    log_success "All pods in '$namespace' are Ready"
    return 0
  else
    log_warn "Not all pods are Ready yet in '$namespace'"
    kubectl get pods -n "$namespace" 2>/dev/null || true
    return 1
  fi
}

# Wait for a specific pod to reach Running phase
wait_for_pod_running() {
  local namespace="$1"
  local label_selector="$2"
  local timeout="${3:-120}"

  log_info "Waiting for pod ($label_selector) in '$namespace' to be Running..."
  local attempts=0
  while true; do
    local phase
    phase=$(kubectl get pods -n "$namespace" -l "$label_selector" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
    if [[ "$phase" == "Running" ]]; then
      log_success "Pod ($label_selector) in '$namespace' is Running"
      return 0
    fi
    attempts=$((attempts + 1))
    if [[ $attempts -ge $timeout ]]; then
      log_error "Pod ($label_selector) did not reach Running within ${timeout}s"
      kubectl get pods -n "$namespace" -l "$label_selector" 2>/dev/null || true
      return 1
    fi
    sleep 1
  done
}

# Get the LoadBalancer IP of a service
get_lb_ip() {
  local namespace="$1"
  local service="$2"
  local timeout="${3:-60}"

  local attempts=0
  local lb_ip=""
  while true; do
    lb_ip=$(kubectl get svc -n "$namespace" "$service" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$lb_ip" ]]; then
      echo "$lb_ip"
      return 0
    fi
    attempts=$((attempts + 1))
    if [[ $attempts -ge $((timeout / 2)) ]]; then
      return 1
    fi
    sleep 2
  done
}

# Check if a Helm release is deployed
helm_is_deployed() {
  local release="$1"
  local namespace="$2"
  helm status "$release" -n "$namespace" &>/dev/null
}
