#!/usr/bin/env bash
# Phase 9: Marketplace Extension 1 — AI/ML Services
# Shared logic used by both install.sh and extend-marketplace-1.sh

run_phase_9() {
  phase_timer_start 9

  log_phase "Phase 9 — Marketplace Extension 1: AI/ML Services"
  load_config
  # install.sh already exports the platform kubeconfig; the standalone extend
  # script may not. Prefer an existing valid KUBECONFIG, else the per-VM file.
  # (The old hardcoded ${INSTALL_DIR}/kubeconfig does not exist and broke every
  # kubectl/bao call in this phase.)
  if [[ -z "${KUBECONFIG:-}" || ! -f "${KUBECONFIG}" ]]; then
    export KUBECONFIG="${HOME}/.kube/config-${LIMA_VM_NAME:-k3s-server}"
  fi
  # OpenBao CLI runs inside the pod — host 'bao' is not an installer prerequisite.
  bao() { kubectl exec -n openbao openbao-0 -- bao "$@"; }
  ensure_openbao_login

  # Authenticate the cf CLI as the Korifi admin (Step 5/8 need it). cf stores the
  # session in ~/.cf, so briefly switch to the cf-admin kubeconfig context to mint
  # it, then switch back so kubectl keeps using the cluster-admin context.
  local _kube_ctx; _kube_ctx="$(kubectl config current-context 2>/dev/null || echo "k3s-${LIMA_VM_NAME:-k3s-server}")"
  kubectl config use-context cf-admin >/dev/null 2>&1 || true
  cf api "https://api.${APPS_DOMAIN:-app.cfapps.cool}" --skip-ssl-validation >/dev/null 2>&1 || true
  cf auth cf-admin >/dev/null 2>&1 || true
  kubectl config use-context "${_kube_ctx}" >/dev/null 2>&1 || true

  local BROKER_DIR="${INSTALL_DIR}/../services/cf-marketplace-broker"

  # --- Step 1: OpenBao setup (KV v2 + AppRole) ---
  if ! component_is_installed "phase9_openbao_setup" "$STATE_FILE"; then
    log_step "Configuring OpenBao: KV v2 engine + AppRole auth"

    # Enable KV v2 engine for cf-secrets (idempotent)
    bao secrets enable -path=cf-secrets -version=2 kv 2>/dev/null || true
    log_info "KV v2 engine 'cf-secrets/' enabled (or already exists)"

    # Enable AppRole auth (idempotent)
    bao auth enable approle 2>/dev/null || true
    log_info "AppRole auth enabled (or already exists)"

    # Store broker token in OpenBao for ESO
    local BROKER_TOKEN
    BROKER_TOKEN=$(bao token create -policy=root -ttl=8760h -format=json | jq -r '.auth.client_token')
    bao kv put secret/marketplace-broker/openbao-token token="$BROKER_TOKEN"
    log_info "Marketplace broker token stored in OpenBao"

    mark_component_installed "phase9_openbao_setup" "$STATE_FILE"
  fi

  # --- Step 2: Build and push broker image ---
  if ! component_is_installed "phase9_broker_image" "$STATE_FILE"; then
    log_step "Building marketplace broker image"

    local BROKER_SRC="${INSTALL_DIR}/../services/cf-marketplace-broker/src"
    local BROKER_IMAGE="artifactory.cfapps.cool/docker-local/cf-marketplace-broker:1.2.0-arm64"  # Wave 10: go 1.26.4 / k8s.io v0.36.1
    local BASE_IMAGE="artifactory.cfapps.cool/docker-local/gcr.io/distroless/static:nonroot-arm64"

    if command -v go &>/dev/null && command -v crane &>/dev/null; then
      local BUILD_DIR
      BUILD_DIR=$(mktemp -d)

      log_info "Cross-compiling broker for linux/arm64..."
      (cd "${BROKER_SRC}" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o "${BUILD_DIR}/broker" .)

      local TMPDIR_IMG
      TMPDIR_IMG=$(mktemp -d)
      mkdir -p "${TMPDIR_IMG}/app"
      cp "${BUILD_DIR}/broker" "${TMPDIR_IMG}/app/broker"
      chmod +x "${TMPDIR_IMG}/app/broker"

      local LAYER
      LAYER=$(mktemp)
      (cd "${TMPDIR_IMG}" && tar cf "${LAYER}" app/)

      # Best-effort push: the broker image is a pre-published artifact, so a
      # failed push (no registry write creds) must NOT abort the install — the
      # deploy pulls the existing image via artifact-keeper-pull.
      if crane append --base "${BASE_IMAGE}" --new_tag "${BROKER_IMAGE}" --new_layer "${LAYER}" --platform linux/arm64 --insecure 2>/dev/null \
         && crane mutate "${BROKER_IMAGE}" --entrypoint "/app/broker" --tag "${BROKER_IMAGE}" --insecure 2>/dev/null; then
        log_success "Broker image built and pushed: ${BROKER_IMAGE}"
      else
        log_warn "Broker push skipped/failed (no registry write creds?) — deploy will use pre-published ${BROKER_IMAGE}"
      fi

      rm -rf "${BUILD_DIR}" "${TMPDIR_IMG}" "${LAYER}"
    else
      log_warn "go or crane not found — build broker manually: k8/services/cf-marketplace-broker/src"
    fi

    mark_component_installed "phase9_broker_image" "$STATE_FILE"
  fi

  # --- Step 2a: Update existing service broker with metadata ---
  if ! component_is_installed "phase9_existing_broker_update" "$STATE_FILE"; then
    log_step "Updating existing service broker to v1.7.0 (Wave 10: go 1.26.4 / k8s.io v0.36.1; RabbitMQ 4.3.1; workload images from artifactory)"

    local EXISTING_BROKER_SRC="${INSTALL_DIR}/../services/cf-service-broker/src"
    local EXISTING_BROKER_IMAGE="artifactory.cfapps.cool/docker-local/cf-service-broker:1.7.0-arm64"
    local BASE_IMAGE="artifactory.cfapps.cool/docker-local/gcr.io/distroless/static:nonroot-arm64"

    if command -v go &>/dev/null && command -v crane &>/dev/null; then
      local BUILD_DIR
      BUILD_DIR=$(mktemp -d)

      log_info "Cross-compiling existing broker for linux/arm64..."
      (cd "${EXISTING_BROKER_SRC}" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o "${BUILD_DIR}/broker" .)

      local TMPDIR_IMG
      TMPDIR_IMG=$(mktemp -d)
      mkdir -p "${TMPDIR_IMG}/app"
      cp "${BUILD_DIR}/broker" "${TMPDIR_IMG}/app/broker"
      chmod +x "${TMPDIR_IMG}/app/broker"

      local LAYER
      LAYER=$(mktemp)
      (cd "${TMPDIR_IMG}" && tar cf "${LAYER}" app/)

      if crane append --base "${BASE_IMAGE}" --new_tag "${EXISTING_BROKER_IMAGE}" --new_layer "${LAYER}" --platform linux/arm64 --insecure 2>/dev/null \
         && crane mutate "${EXISTING_BROKER_IMAGE}" --entrypoint "/app/broker" --tag "${EXISTING_BROKER_IMAGE}" --insecure 2>/dev/null; then
        log_success "Existing broker image built and pushed: ${EXISTING_BROKER_IMAGE}"
      else
        log_warn "Existing broker push skipped/failed (no registry write creds?) — using pre-published ${EXISTING_BROKER_IMAGE}"
      fi

      rm -rf "${BUILD_DIR}" "${TMPDIR_IMG}" "${LAYER}"

      kubectl set image deployment/cf-service-broker -n cf-services \
        broker="${EXISTING_BROKER_IMAGE}"
      kubectl rollout status deployment/cf-service-broker -n cf-services --timeout=60s || true
      log_success "Existing broker updated to v1.7.0"
    else
      log_warn "go or crane not found — update broker manually"
    fi

    mark_component_installed "phase9_existing_broker_update" "$STATE_FILE"
  fi

  # --- Step 3: Deploy ExternalSecret ---
  if ! component_is_installed "phase9_externalsecret" "$STATE_FILE"; then
    log_step "Deploying ExternalSecret for OpenBao token"

    kubectl apply -f "${BROKER_DIR}/externalsecret-openbao.yaml"
    log_info "Waiting for ExternalSecret to sync..."
    kubectl wait --for=condition=Ready externalsecret/marketplace-broker-openbao-token -n cf-services --timeout=60s
    log_success "ExternalSecret synced"

    mark_component_installed "phase9_externalsecret" "$STATE_FILE"
  fi

  # --- Step 4: Deploy broker ---
  if ! component_is_installed "phase9_broker_deploy" "$STATE_FILE"; then
    log_step "Deploying marketplace broker"

    kubectl apply -f "${BROKER_DIR}/deployment.yaml"
    wait_for_pods "cf-services" "app=cf-marketplace-broker" 120
    log_success "Marketplace broker running"

    mark_component_installed "phase9_broker_deploy" "$STATE_FILE"
  fi

  # --- Step 5: Register broker with Korifi ---
  if ! component_is_installed "phase9_broker_register" "$STATE_FILE"; then
    log_step "Registering marketplace broker with Korifi"

    local BROKER_PASSWORD
    BROKER_PASSWORD=$(kubectl get secret marketplace-broker-openbao-token -n cf-services -o jsonpath='{.data.token}' | base64 -d)

    local BROKER_URL="http://cf-marketplace-broker.cf-services.svc.cluster.local"

    # Global broker (matches Phase 7's k8s-services broker; 'cf enable-service-access'
    # below is global-only, and a global broker needs no targeted space). Idempotent:
    # skip if already registered so a re-run doesn't fail on "already exists".
    if cf service-brokers 2>/dev/null | grep -q "marketplace-broker"; then
      log_info "Marketplace broker already registered"
    else
      local retries=5
      for i in $(seq 1 $retries); do
        if cf create-service-broker marketplace-broker marketplace-broker "$BROKER_PASSWORD" "$BROKER_URL" 2>/dev/null; then
          log_success "Marketplace broker registered"
          break
        fi
        if [[ $i -eq $retries ]]; then
          log_error "Failed to register marketplace broker after $retries attempts"
          return 1
        fi
        log_info "Retry $i/$retries..."
        sleep 5
      done
    fi

    # Enable service access
    cf enable-service-access postgres-ai 2>/dev/null || true
    cf enable-service-access openbao-secrets 2>/dev/null || true
    cf enable-service-access ai-connector 2>/dev/null || true

    mark_component_installed "phase9_broker_register" "$STATE_FILE"
  fi

  # --- Step 6: Run integration tests ---
  if ! component_is_installed "phase9_test" "$STATE_FILE"; then
    log_step "Running marketplace broker integration tests"

    local BROKER_PASSWORD
    BROKER_PASSWORD=$(kubectl get secret marketplace-broker-openbao-token -n cf-services -o jsonpath='{.data.token}' | base64 -d)

    local TEST_DIR="${INSTALL_DIR}/../services/cf-marketplace-broker/test"
    (
      cd "${TEST_DIR}"
      BROKER_URL=http://cf-marketplace-broker.cf-services.svc:80 \
      BROKER_USER=marketplace-broker \
      BROKER_PASSWORD="${BROKER_PASSWORD}" \
      go test -v -timeout 300s ./...
    ) && {
      log_success "Integration tests passed"
      mark_component_installed "phase9_test" "$STATE_FILE"
    } || {
      log_warn "Some integration tests failed (non-blocking) — check output above"
      mark_component_installed "phase9_test" "$STATE_FILE"
    }
  fi

  # --- Step 7: Update credentials doc ---
  if ! component_is_installed "phase9_docs" "$STATE_FILE"; then
    log_step "Updating stack credentials.md (marketplace broker)"

    # Regenerate the ONE unified credentials.md owned by write_credentials
    # (${K8_DIR}/../credentials.md, full overwrite). It now includes the
    # marketplace-broker row read from the cf-services secret. The old code
    # appended to ${INSTALL_DIR}/credentials.md — a DIFFERENT file — so the
    # Phase 9 creds ended up split from phases 1-8.
    if declare -f write_credentials >/dev/null 2>&1; then
      write_credentials
      log_success "credentials.md updated (unified, includes marketplace broker)"
    else
      log_warn "write_credentials not available (standalone run) — broker password is in the cf-services secret 'marketplace-broker-openbao-token'"
    fi

    mark_component_installed "phase9_docs" "$STATE_FILE"
  fi

  # --- Step 8: Update kappman ---
  if ! component_is_installed "phase9_kappman_update" "$STATE_FILE"; then
    log_step "Updating kappman to V1.1.0 (parameters + service docs)"

    local KAPPMAN_DIR="${INSTALL_DIR}/../apps/kappman"
    cf target -o kappman -s app >/dev/null 2>&1 || true   # cf push needs a targeted space
    (cd "$KAPPMAN_DIR" && cf push kappman) && {
      log_success "kappman updated to V1.1.0"
    } || {
      log_warn "kappman update failed — update manually with: cd k8/apps/kappman && cf push kappman"
    }

    mark_component_installed "phase9_kappman_update" "$STATE_FILE"
  fi

  mark_phase_complete 9 "$STATE_FILE"
  phase_timer_stop 9

  log_success "Phase 9 complete — Marketplace Extension 1: AI/ML Services"
  echo ""
  echo -e "  ${BOLD}Services:${NC}"
  echo -e "    PostgreSQL AI Enabled  — pgvector, pgvectorscale, PostGIS, full-text search"
  echo -e "    OpenBao Secret Container — application-managed secrets with AppRole"
  echo -e "    AI Model Connector     — Ollama / LM Studio via OpenAI-compatible API"
  echo ""
}
