#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# set-arch.sh — Setzt Image-Tag-Suffixe in allen Helm values.yaml
# =============================================================================
# Liest ARCH aus config.env und aktualisiert alle Image-Tags.
# Verwendung:
#   ./set-arch.sh            # Verwendet ARCH aus config.env
#   ./set-arch.sh amd64      # Ueberschreibt mit amd64
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

TARGET_ARCH="${1:-${ARCH}}"

# Mapping: base_tag -> wird zu base_tag-${ARCH}
# Format: "values_file|yaml_path|base_tag"
IMAGE_TAGS=(
  "services/openbao/values.yaml|tag|2.5.1"
  "platform/external-secrets/values.yaml|tag|v0.16.1"
  "infrastructure/metallb/values.yaml|tag|v0.15.3"
  "infrastructure/traefik/values.yaml|tag|v3.6.10"
  "infrastructure/cert-manager/values.yaml|tag|v1.20.0"
)

echo "Setting image architecture to: ${TARGET_ARCH}"
echo ""

for entry in "${IMAGE_TAGS[@]}"; do
  IFS='|' read -r file field base_tag <<< "$entry"
  filepath="${SCRIPT_DIR}/${file}"

  if [[ ! -f "$filepath" ]]; then
    echo "  SKIP: ${file} (not found)"
    continue
  fi

  # Replace any existing tag variant (base, -arm64, -amd64) with the target
  sed -i '' -E "s/(${field}: \"?${base_tag})(-arm64|-amd64)?(\"?)/\1-${TARGET_ARCH}\3/g" "$filepath"
  echo "  OK:   ${file} -> ${base_tag}-${TARGET_ARCH}"
done

# Update ARCH in config.env
sed -i '' "s/^ARCH=.*/ARCH=\"${TARGET_ARCH}\"/" "${SCRIPT_DIR}/config.env"
echo ""
echo "config.env ARCH set to: ${TARGET_ARCH}"
echo ""
echo "Done. Verify with: grep -r 'tag:' k8/*/values.yaml k8/*/*/values.yaml"
