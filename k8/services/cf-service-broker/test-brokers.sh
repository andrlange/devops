#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# test-brokers.sh — End-to-end test for all 4 OSBAPI Service Brokers
# =============================================================================
# Creates a test org/space, provisions each service, binds to a test app,
# verifies the binding credentials, then cleans everything up.
#
# Usage:
#   ./test-brokers.sh                    # Run all tests
#   ./test-brokers.sh postgresql         # Test only PostgreSQL
#   ./test-brokers.sh valkey             # Test only Valkey
#   ./test-brokers.sh rabbitmq           # Test only RabbitMQ
#   ./test-brokers.sh s3                 # Test only S3
#
# Prerequisites:
#   - cf CLI logged in (cf auth cf-admin)
#   - Service broker registered (cf marketplace shows services)
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

TEST_ORG="broker-test-org"
TEST_SPACE="broker-test-space"
TEST_APP="broker-test-app"
PASSED=0
FAILED=0
TESTS=()

log_info()  { echo -e "${BOLD}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[PASS]${NC}  $*"; PASSED=$((PASSED + 1)); }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; FAILED=$((FAILED + 1)); }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_step()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# --- Verify prerequisites ---
check_prereqs() {
  log_step "Checking prerequisites"

  if ! cf target &>/dev/null; then
    log_fail "Not logged in to CF. Run: cf api <url> --skip-ssl-validation && cf auth cf-admin"
    exit 1
  fi
  log_ok "CF CLI logged in"

  local services
  services=$(cf marketplace 2>/dev/null | grep -c "^\(postgresql\|valkey\|rabbitmq\|s3\)" || echo "0")
  if [[ "$services" -eq 0 ]]; then
    log_fail "No broker services found in marketplace. Is the broker registered?"
    exit 1
  fi
  log_ok "Service broker registered ($services services in marketplace)"
}

# --- Setup test org/space ---
setup() {
  log_step "Setting up test environment"

  if ! cf org "$TEST_ORG" &>/dev/null; then
    cf create-org "$TEST_ORG" >/dev/null 2>&1
    log_ok "Created org: $TEST_ORG"
  else
    log_info "Org $TEST_ORG already exists"
  fi

  cf target -o "$TEST_ORG" >/dev/null 2>&1

  if ! cf space "$TEST_SPACE" &>/dev/null; then
    cf create-space "$TEST_SPACE" >/dev/null 2>&1
    log_ok "Created space: $TEST_SPACE"
  else
    log_info "Space $TEST_SPACE already exists"
  fi

  cf target -o "$TEST_ORG" -s "$TEST_SPACE" >/dev/null 2>&1
  log_ok "Target: $TEST_ORG / $TEST_SPACE"
}

# --- Wait for service to be ready ---
wait_for_service() {
  local svc_name="$1"
  local timeout="${2:-120}"
  local elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(cf service "$svc_name" 2>/dev/null | grep "status:" | awk '{print $NF}' || echo "pending")
    if [[ "$status" == "succeeded" ]]; then
      return 0
    elif [[ "$status" == "failed" ]]; then
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

# --- Test a single service broker ---
test_service() {
  local svc_type="$1"
  local svc_plan="$2"
  local svc_instance="test-${svc_type}"
  local binding_name="test-${svc_type}-binding"

  log_step "Testing: ${svc_type} (plan: ${svc_plan})"

  # 1. Create service instance
  log_info "Creating service instance: $svc_instance"
  if cf create-service "$svc_type" "$svc_plan" "$svc_instance" >/dev/null 2>&1; then
    log_ok "Service instance created: $svc_instance"
  else
    log_fail "Failed to create service instance: $svc_instance"
    return 1
  fi

  # 2. Wait for provisioning
  log_info "Waiting for $svc_instance to be ready..."
  if wait_for_service "$svc_instance" 120; then
    log_ok "Service instance ready: $svc_instance"
  else
    log_fail "Service instance not ready after 120s: $svc_instance"
    # Cleanup
    cf delete-service "$svc_instance" -f >/dev/null 2>&1 || true
    return 1
  fi

  # 3. Create service key (binding without app)
  log_info "Creating service key: $binding_name"
  if cf create-service-key "$svc_instance" "$binding_name" >/dev/null 2>&1; then
    log_ok "Service key created: $binding_name"
  else
    log_fail "Failed to create service key: $binding_name"
    cf delete-service "$svc_instance" -f >/dev/null 2>&1 || true
    return 1
  fi

  # 4. Verify credentials
  log_info "Verifying credentials..."
  local creds
  creds=$(cf service-key "$svc_instance" "$binding_name" 2>/dev/null)

  local valid=true
  case "$svc_type" in
    postgresql)
      echo "$creds" | grep -q "hostname" || valid=false
      echo "$creds" | grep -q "port" || valid=false
      echo "$creds" | grep -q "username" || valid=false
      echo "$creds" | grep -q "password" || valid=false
      echo "$creds" | grep -q "database" || valid=false
      ;;
    valkey)
      echo "$creds" | grep -q "host" || valid=false
      echo "$creds" | grep -q "port" || valid=false
      ;;
    rabbitmq)
      echo "$creds" | grep -q "host" || valid=false
      echo "$creds" | grep -q "port" || valid=false
      echo "$creds" | grep -q "username" || valid=false
      echo "$creds" | grep -q "password" || valid=false
      ;;
    s3)
      echo "$creds" | grep -q "access_key_id" || valid=false
      echo "$creds" | grep -q "secret_access_key" || valid=false
      echo "$creds" | grep -q "bucket" || valid=false
      echo "$creds" | grep -q "endpoint" || valid=false
      ;;
  esac

  if [[ "$valid" == "true" ]]; then
    log_ok "Credentials valid for $svc_type"
  else
    log_fail "Credentials incomplete for $svc_type"
    echo "$creds" | head -15
  fi

  # 5. Cleanup — delete key and service
  log_info "Cleaning up $svc_instance..."
  cf delete-service-key "$svc_instance" "$binding_name" -f >/dev/null 2>&1 || true
  cf delete-service "$svc_instance" -f >/dev/null 2>&1 || true

  # Wait for deletion
  local del_attempts=0
  while cf service "$svc_instance" &>/dev/null; do
    del_attempts=$((del_attempts + 1))
    [[ $del_attempts -ge 24 ]] && break
    sleep 5
  done

  if ! cf service "$svc_instance" &>/dev/null; then
    log_ok "Service instance deleted: $svc_instance"
  else
    log_warn "Service instance still exists (may be deleting): $svc_instance"
  fi

  return 0
}

# --- Cleanup test environment ---
cleanup() {
  log_step "Cleaning up test environment"

  cf target -o "$TEST_ORG" -s "$TEST_SPACE" >/dev/null 2>&1 || true

  # Delete any remaining service instances
  for svc in test-postgresql test-valkey test-rabbitmq test-s3; do
    if cf service "$svc" &>/dev/null; then
      cf delete-service-key "$svc" "test-${svc#test-}-binding" -f >/dev/null 2>&1 || true
      cf delete-service "$svc" -f >/dev/null 2>&1 || true
      log_info "Deleted: $svc"
    fi
  done

  # Wait for services to be deleted
  sleep 10

  # Delete space and org
  cf delete-space "$TEST_SPACE" -o "$TEST_ORG" -f >/dev/null 2>&1 || true
  cf delete-org "$TEST_ORG" -f >/dev/null 2>&1 || true
  log_ok "Test environment cleaned up"
}

# --- Print summary ---
summary() {
  log_step "Test Summary"
  echo -e "  ${GREEN}Passed: $PASSED${NC}"
  echo -e "  ${RED}Failed: $FAILED${NC}"
  echo -e "  Total:  $((PASSED + FAILED))"
  echo ""
  if [[ $FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}ALL TESTS PASSED${NC}"
  else
    echo -e "  ${RED}${BOLD}SOME TESTS FAILED${NC}"
  fi
  echo ""
}

# --- Main ---
main() {
  local filter="${1:-all}"

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║  Service Broker End-to-End Test                  ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""

  check_prereqs
  setup

  case "$filter" in
    all)
      test_service "postgresql" "small"
      test_service "valkey" "small"
      test_service "rabbitmq" "small"
      test_service "s3" "default"
      ;;
    postgresql|valkey|rabbitmq|s3)
      local plan="small"
      [[ "$filter" == "s3" ]] && plan="default"
      test_service "$filter" "$plan"
      ;;
    *)
      echo "Usage: $0 [all|postgresql|valkey|rabbitmq|s3]"
      exit 1
      ;;
  esac

  cleanup
  summary

  [[ $FAILED -eq 0 ]] && exit 0 || exit 1
}

main "$@"
