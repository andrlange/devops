#!/usr/bin/env bash
# =============================================================================
# mirror-platform-images.sh — populate the artifact-keeper registry with the
# -arm64 platform images the stack pulls. Serves BOTH the upgrade and the
# INSTALL path (a naked-system install pulls everything from this registry).
#
# Usage:
#   REGISTRY_TOKEN=<push-token> ./k8/mirror-platform-images.sh            # mirror all
#   REGISTRY_TOKEN=<push-token> ./k8/mirror-platform-images.sh grafana   # filter by substring
#   (token also read from ./tmp.secret or k8/.env.local AK_TOKEN)
#
# Safe: only ADDS new tags (never overwrites). Idempotent (skips tags already
# present). Source-resolving: tries candidate upstream registries and uses the
# first that actually has the tag, so a wrong guess can't push a bad image.
# =============================================================================
set -uo pipefail

REGISTRY="artifactory.cfapps.cool"
REPO="docker-local"
ARCH="linux/arm64"
SUFFIX="-arm64"
FILTER="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN="${REGISTRY_TOKEN:-}"
[ -z "$TOKEN" ] && [ -f "${SCRIPT_DIR}/../tmp.secret" ] && TOKEN="$(cat "${SCRIPT_DIR}/../tmp.secret")"
[ -z "$TOKEN" ] && [ -f "${SCRIPT_DIR}/.env.local" ] && TOKEN="$(grep -E '^AK_TOKEN=' "${SCRIPT_DIR}/.env.local" | cut -d= -f2- | tr -d '"')"
[ -z "$TOKEN" ] && { echo "ERROR: no push token (REGISTRY_TOKEN / tmp.secret / k8/.env.local)"; exit 1; }
command -v crane >/dev/null || { echo "ERROR: crane not installed"; exit 1; }

printf '%s' "$TOKEN" | crane auth login "$REGISTRY" -u admin --password-stdin >/dev/null 2>&1 || true

# Image table:  DEST_PATH | TARGET_TAG | CANDIDATE_SRC_REPOS (space-separated, no tag)
# DEST = $REGISTRY/$REPO/<DEST_PATH>:<TARGET_TAG><SUFFIX>
# The first candidate repo that has :<TARGET_TAG> (arm64) wins.
TABLE=$(cat <<'TBL'
# --- Wave 2/3 infrastructure ---
metallb/controller|v0.16.1|quay.io/metallb/controller
metallb/speaker|v0.16.1|quay.io/metallb/speaker
traefik|v3.7.1|docker.io/library/traefik
jetstack/cert-manager-controller|v1.20.2|quay.io/jetstack/cert-manager-controller
jetstack/cert-manager-webhook|v1.20.2|quay.io/jetstack/cert-manager-webhook
jetstack/cert-manager-cainjector|v1.20.2|quay.io/jetstack/cert-manager-cainjector
jetstack/cert-manager-acmesolver|v1.20.2|quay.io/jetstack/cert-manager-acmesolver
# --- Wave 5 platform ---
argoproj/argocd|v3.4.3|quay.io/argoproj/argocd
external-secrets/external-secrets|v2.5.0|ghcr.io/external-secrets/external-secrets oci.external-secrets.io/external-secrets/external-secrets
portainer/portainer-ce|2.39.3|docker.io/portainer/portainer-ce
dxflrs/garage|v2.3.0|docker.io/dxflrs/garage
technitium/dns-server|15.2.0|docker.io/technitium/dns-server
velero/velero|v1.18.1|docker.io/velero/velero
velero/velero-plugin-for-aws|v1.14.1|docker.io/velero/velero-plugin-for-aws
# --- Wave 4 secrets ---
openbao/openbao|2.5.4|quay.io/openbao/openbao ghcr.io/openbao/openbao docker.io/openbao/openbao
# --- Wave 6 monitoring (grafana images stay on docker hub; helm CHART repo moved, images did not) ---
grafana/grafana|12.4.3|docker.io/grafana/grafana
grafana/loki|3.7.2|docker.io/grafana/loki
grafana/mimir|3.1.0|docker.io/grafana/mimir
grafana/tempo|2.10.5|docker.io/grafana/tempo
grafana/alloy|v1.16.2|docker.io/grafana/alloy
registry.k8s.io/kube-state-metrics/kube-state-metrics|v2.19.0|registry.k8s.io/kube-state-metrics/kube-state-metrics
quay.io/prometheus/node-exporter|v1.11.1|quay.io/prometheus/node-exporter
# --- Wave 7 services ---
aquasecurity/trivy|0.71.0|ghcr.io/aquasecurity/trivy docker.io/aquasec/trivy
postgres|17.10|docker.io/library/postgres
opensearchproject/opensearch|2.19.5|docker.io/opensearchproject/opensearch
# --- Wave 8 gitlab (CE must pass required stop 18.11.4 -> 19.0.1) ---
gitlab/gitlab-ce|18.11.4-ce.0|docker.io/gitlab/gitlab-ce
gitlab/gitlab-ce|19.0.1-ce.0|docker.io/gitlab/gitlab-ce
gitlab-org/gitlab-runner|alpine-v19.0.1|docker.io/gitlab/gitlab-runner registry.gitlab.com/gitlab-org/gitlab-runner
# --- Wave 10 broker-managed workload images (provisioned on demand by cf-service-broker) ---
rabbitmq|4.3.1-management|docker.io/library/rabbitmq
valkey/valkey|8.1-alpine|docker.io/valkey/valkey
ghcr.io/cloudnative-pg/postgresql|18.1-system-trixie|ghcr.io/cloudnative-pg/postgresql
# NOTE: the cnpg/rabbitmq OPERATOR controller images pull multi-arch direct from ghcr.io
# (no mirror); kpack@ghcr.io + contour/envoy are mirrored just-in-time in Wave 9.
TBL
)

ok=0; skip=0; fail=0; unresolved=0
while IFS='|' read -r destpath tag cands; do
  [[ "$destpath" =~ ^[[:space:]]*# ]] && continue
  [ -z "$destpath" ] && continue
  [ -n "$FILTER" ] && [[ "$destpath" != *"$FILTER"* ]] && continue
  dest="${REGISTRY}/${REPO}/${destpath}:${tag}${SUFFIX}"
  # idempotent skip
  if crane manifest "$dest" >/dev/null 2>&1; then
    echo "  ⏭  skip (present): ${destpath}:${tag}${SUFFIX}"; skip=$((skip+1)); continue
  fi
  # resolve source
  src=""
  for c in $cands; do
    if crane manifest --platform "$ARCH" "${c}:${tag}" >/dev/null 2>&1; then src="${c}:${tag}"; break; fi
  done
  if [ -z "$src" ]; then echo "  ❓ UNRESOLVED upstream for ${destpath}:${tag} (tried: $cands)"; unresolved=$((unresolved+1)); continue; fi
  if crane copy "$src" "$dest" --platform "$ARCH" >/dev/null 2>&1; then
    echo "  ✅ ${src}  →  ${destpath}:${tag}${SUFFIX}"; ok=$((ok+1))
  else
    echo "  ❌ FAILED ${src} → ${dest}"; fail=$((fail+1))
  fi
done <<< "$TABLE"

echo "-----------------------------------------------------------------------"
echo "mirrored: $ok | skipped(present): $skip | unresolved: $unresolved | failed: $fail"
[ $fail -eq 0 ] && [ $unresolved -eq 0 ]
