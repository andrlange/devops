#!/usr/bin/env bash
# =============================================================================
# Marketplace Extension 1: AI/ML Services
# =============================================================================
# Adds three new services to an existing K8s DevOps Stack installation:
#   - PostgreSQL AI Enabled (pgvector, pgvectorscale, PostGIS)
#   - OpenBao Secret Container (KV v2 + AppRole)
#   - AI Model Connector (Ollama, LM Studio)
#
# Prerequisites: Phase 6 (Korifi) + Phase 7 (Service Brokers) must be complete.
#
# Usage: ./extend-marketplace-1.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/prerequisites.sh"
source "$SCRIPT_DIR/lib/helm.sh"
source "$SCRIPT_DIR/lib/interactive.sh"
source "$SCRIPT_DIR/lib/phase9.sh"

main() {
  print_banner "Marketplace Extension 1: AI/ML Services"

  # Load configuration
  if [[ ! -f "$SCRIPT_DIR/.install-config" ]]; then
    log_error "No .install-config found. Run install.sh first."
    exit 1
  fi
  source "$SCRIPT_DIR/.install-config"

  STATE_FILE="${SCRIPT_DIR}/.install-state"
  INSTALL_DIR="$SCRIPT_DIR"

  # Check prerequisites
  if ! phase_is_complete 6 "$STATE_FILE"; then
    log_error "Phase 6 (Cloud Foundry / Korifi) is required but not complete."
    log_info "Run: ./install.sh phase 6"
    exit 1
  fi

  if ! phase_is_complete 7 "$STATE_FILE"; then
    log_error "Phase 7 (CF Service Brokers) is required but not complete."
    log_info "Run: ./install.sh phase 7"
    exit 1
  fi

  if phase_is_complete 9 "$STATE_FILE"; then
    log_success "Marketplace Extension 1 is already installed."
    exit 0
  fi

  echo ""
  log_info "This will install:"
  echo -e "  ${CYAN}PostgreSQL AI Enabled${NC}   — pgvector, pgvectorscale, PostGIS, full-text search"
  echo -e "  ${CYAN}OpenBao Secret Container${NC} — application-managed secrets with AppRole"
  echo -e "  ${CYAN}AI Model Connector${NC}      — Ollama / LM Studio via OpenAI-compatible API"
  echo ""

  if ! ask_yes_no "Proceed with installation?" "y"; then
    log_info "Aborted."
    exit 0
  fi

  run_phase_9

  echo ""
  log_success "Marketplace Extension 1 installed successfully!"
  echo ""
  echo -e "  Use ${BOLD}cf marketplace${NC} to see the new services."
  echo -e "  Use ${BOLD}cf create-service postgres-ai small my-db${NC} to create an AI-enabled database."
  echo ""
}

main "$@"
