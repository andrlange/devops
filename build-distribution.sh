#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Output directory ──────────────────────────────────────────────────────────
DIST_DIR="${SCRIPT_DIR}/dist"
if [[ -d "${DIST_DIR}" ]]; then
  rm -rf "${DIST_DIR}"
fi
mkdir -p "${DIST_DIR}"

# ── Collect optional top-level paths ─────────────────────────────────────────
TAR_EXTRAS=()

if [[ -f "${SCRIPT_DIR}/GETTING_STARTED.md" ]]; then
  TAR_EXTRAS+=(GETTING_STARTED.md)
else
  echo "WARNING: GETTING_STARTED.md not found — skipping (will be created in a later task)"
fi

if [[ -d "${SCRIPT_DIR}/demos" ]]; then
  TAR_EXTRAS+=(demos/)
else
  echo "WARNING: demos/ directory not found — skipping"
fi

# ── Build stack.tgz ───────────────────────────────────────────────────────────
echo "Building dist/stack.tgz …"
tar czf "${DIST_DIR}/stack.tgz" \
  --exclude='.git' \
  --exclude='.DS_Store' \
  --exclude='.env' \
  --exclude='.env.local' \
  --exclude='.install-config' \
  --exclude='.install-state' \
  --exclude='credentials.md' \
  --exclude='.superpowers' \
  --exclude='source' \
  --exclude='artifactory' \
  --exclude='otel' \
  --exclude='.gradle' \
  --exclude='build' \
  --exclude='node_modules' \
  -C "${SCRIPT_DIR}" \
  k8/ \
  "${TAR_EXTRAS[@]}"

# ── Compute SHA-256 checksum ──────────────────────────────────────────────────
CHECKSUM=$(shasum -a 256 "${DIST_DIR}/stack.tgz" | cut -d' ' -f1)

# ── Produce dist/installer.sh with real checksum ──────────────────────────────
sed "s/EXPECTED_CHECKSUM=\"PLACEHOLDER\"/EXPECTED_CHECKSUM=\"${CHECKSUM}\"/" \
  "${SCRIPT_DIR}/installer.sh" > "${DIST_DIR}/installer.sh"
chmod +x "${DIST_DIR}/installer.sh"

# ── Summary ───────────────────────────────────────────────────────────────────
INSTALLER_SIZE=$(du -sh "${DIST_DIR}/installer.sh" | cut -f1)
STACK_SIZE=$(du -sh "${DIST_DIR}/stack.tgz"        | cut -f1)

echo ""
echo "═══════════════════════════════════════════════"
echo "  Distribution Build Complete"
echo "═══════════════════════════════════════════════"
printf "  installer.sh:  %s\n"  "${INSTALLER_SIZE}"
printf "  stack.tgz:     %s\n"  "${STACK_SIZE}"
printf "  Checksum:      %s\n"  "${CHECKSUM}"
printf "  Output:        %s\n"  "dist/"
echo "═══════════════════════════════════════════════"
