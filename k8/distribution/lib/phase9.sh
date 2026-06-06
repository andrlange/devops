#!/usr/bin/env bash
# Phase 9: Marketplace Extension 1 — AI/ML Services
# Shared logic used by both install.sh and extend-marketplace-1.sh

run_phase_9() {
  phase_timer_start 9

  log_phase "Phase 9 — Marketplace Extension 1: AI/ML Services"
  load_config
  local KUBECONFIG="${INSTALL_DIR}/kubeconfig"
  export KUBECONFIG
  ensure_openbao_login

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

      crane append --base "${BASE_IMAGE}" --new_tag "${BROKER_IMAGE}" --new_layer "${LAYER}" --platform linux/arm64 --insecure 2>/dev/null
      crane mutate "${BROKER_IMAGE}" --entrypoint "/app/broker" --tag "${BROKER_IMAGE}" --insecure 2>/dev/null

      rm -rf "${BUILD_DIR}" "${TMPDIR_IMG}" "${LAYER}"
      log_success "Broker image built and pushed: ${BROKER_IMAGE}"
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

      crane append --base "${BASE_IMAGE}" --new_tag "${EXISTING_BROKER_IMAGE}" --new_layer "${LAYER}" --platform linux/arm64 --insecure 2>/dev/null
      crane mutate "${EXISTING_BROKER_IMAGE}" --entrypoint "/app/broker" --tag "${EXISTING_BROKER_IMAGE}" --insecure 2>/dev/null

      rm -rf "${BUILD_DIR}" "${TMPDIR_IMG}" "${LAYER}"
      log_success "Existing broker image built and pushed: ${EXISTING_BROKER_IMAGE}"

      kubectl set image deployment/cf-service-broker -n cf-services \
        broker="${EXISTING_BROKER_IMAGE}"
      kubectl rollout status deployment/cf-service-broker -n cf-services --timeout=60s
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

    # Retry registration (broker may need a moment to be fully ready)
    local retries=5
    for i in $(seq 1 $retries); do
      if cf create-service-broker marketplace-broker marketplace-broker "$BROKER_PASSWORD" "$BROKER_URL" --space-scoped 2>/dev/null; then
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
    log_step "Writing marketplace broker credentials"

    local BROKER_PASSWORD
    BROKER_PASSWORD=$(kubectl get secret marketplace-broker-openbao-token -n cf-services -o jsonpath='{.data.token}' | base64 -d)

    cat >> "${INSTALL_DIR}/credentials.md" <<CREDS

## Marketplace Broker (Phase 9)
- **Broker URL:** http://cf-marketplace-broker.cf-services.svc.cluster.local
- **Username:** marketplace-broker
- **Password:** ${BROKER_PASSWORD}
- **Services:** postgres-ai, openbao-secrets, ai-connector
CREDS

    mark_component_installed "phase9_docs" "$STATE_FILE"
  fi

  # --- Step 8: Update kappman ---
  if ! component_is_installed "phase9_kappman_update" "$STATE_FILE"; then
    log_step "Updating kappman to V1.1.0 (parameters + service docs)"

    local KAPPMAN_DIR="${INSTALL_DIR}/../apps/kappman"
    (cd "$KAPPMAN_DIR" && cf push kappman) && {
      log_success "kappman updated to V1.1.0"
    } || {
      log_warn "kappman update failed — update manually with: cd k8/apps/kappman && cf push kappman"
    }

    mark_component_installed "phase9_kappman_update" "$STATE_FILE"
  fi

  mark_phase_complete 9 "$STATE_FILE"
  phase_timer_end 9

  log_success "Phase 9 complete — Marketplace Extension 1: AI/ML Services"
  echo ""
  echo -e "  ${BOLD}Services:${NC}"
  echo -e "    PostgreSQL AI Enabled  — pgvector, pgvectorscale, PostGIS, full-text search"
  echo -e "    OpenBao Secret Container — application-managed secrets with AppRole"
  echo -e "    AI Model Connector     — Ollama / LM Studio via OpenAI-compatible API"
  echo ""
}
