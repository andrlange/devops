#!/bin/bash
# Build kpack ARM64 container images and push to artifact-keeper registry
#
# Prerequisites:
#   - Go 1.24+ (brew install go)
#   - crane (go install github.com/google/go-containerregistry/cmd/crane@latest)
#   - Registry credentials configured (crane auth login)
#
# Usage:
#   ./build-arm64.sh                    # Build + push all images
#   ./build-arm64.sh --deploy           # Build + push + patch running kpack
#
set -euo pipefail

REGISTRY="${REGISTRY:-artifactory.cfapps.cool/docker-local}"
REGISTRY_USER="${REGISTRY_USER:-admin}"
VERSION="0.17.1"
TAG="${VERSION}-arm64"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
BUILD_DIR=$(mktemp -d)
BASE_IMAGE="gcr.io/distroless/static:nonroot"

export PATH="${HOME}/go/bin:${PATH}"

BINARIES=(controller webhook build-init build-waiter rebase completion)

# Check prerequisites
command -v go >/dev/null 2>&1 || { echo "ERROR: go not found. Install with: brew install go"; exit 1; }
command -v crane >/dev/null 2>&1 || { echo "ERROR: crane not found. Install with: go install github.com/google/go-containerregistry/cmd/crane@latest"; exit 1; }

# Isolate DOCKER_CONFIG so crane never invokes the macOS Docker Desktop
# credential helper (credsStore: desktop) — which pops a TCC "access data from
# other apps" prompt per image. An empty config makes crane store auth inline.
export DOCKER_CONFIG="${DOCKER_CONFIG:-$(mktemp -d)}"
[ -f "${DOCKER_CONFIG}/config.json" ] || printf '{}' > "${DOCKER_CONFIG}/config.json"

if [ ! -d "${SRC_DIR}" ]; then
  echo "Cloning kpack v${VERSION} sources..."
  git clone --depth 1 --branch "v${VERSION}" https://github.com/buildpacks-community/kpack.git "${SRC_DIR}"
fi

echo "=== Building kpack ${VERSION} ARM64 images ==="
echo "Registry: ${REGISTRY}"
echo ""

# Step 1: Compile all binaries natively (ARM64 on Apple Silicon)
echo "--- Compiling Go binaries ---"
for binary in "${BINARIES[@]}"; do
  echo -n "  ${binary}... "
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
    -C "${SRC_DIR}" \
    -ldflags "-s -w -X 'github.com/pivotal/kpack/cmd.Version=${VERSION}'" \
    -o "${BUILD_DIR}/${binary}" "./cmd/${binary}"
  echo "$(du -h "${BUILD_DIR}/${binary}" | cut -f1)"
done
echo ""

# Step 2: Build OCI images with crane and push
# controller/webhook use /app, build helpers use /cnb/process/<name>
# (bash 3.2 compatible — macOS ships no `declare -A`)
binary_path() {
  case "$1" in
    controller|webhook) echo "/app" ;;
    build-init)         echo "/cnb/process/build-init" ;;
    build-waiter)       echo "/cnb/process/build-waiter" ;;
    rebase)             echo "/cnb/process/rebase" ;;
    completion)         echo "/cnb/process/completion" ;;
  esac
}

echo "--- Building and pushing OCI images ---"
for binary in "${BINARIES[@]}"; do
  IMAGE="${REGISTRY}/kpack/${binary}:${TAG}"
  TARGET="$(binary_path "$binary")"
  echo -n "  ${binary} -> ${IMAGE} (${TARGET})... "

  # Create layer tarball with binary at expected path
  TMPDIR_BP=$(mktemp -d)
  TARGET_DIR=$(dirname "${TARGET}")
  mkdir -p "${TMPDIR_BP}/${TARGET_DIR#/}"
  cp "${BUILD_DIR}/${binary}" "${TMPDIR_BP}/${TARGET_DIR#/}/$(basename "${TARGET}")"
  LAYER=$(mktemp)
  (cd "${TMPDIR_BP}" && tar cf "${LAYER}" .)

  # Append layer to distroless base and set entrypoint
  crane append --base "${BASE_IMAGE}" --new_tag "${IMAGE}" --new_layer "${LAYER}" --platform linux/arm64 >/dev/null 2>&1
  crane mutate "${IMAGE}" --entrypoint "${TARGET}" --tag "${IMAGE}" >/dev/null 2>&1

  rm -rf "${TMPDIR_BP}" "${LAYER}"
  echo "done"
done

rm -rf "${BUILD_DIR}"
echo ""
echo "=== All kpack ARM64 images built and pushed ==="

# Step 3: Optionally deploy to running cluster
if [ "${1:-}" = "--deploy" ]; then
  echo ""
  echo "--- Deploying to cluster ---"

  kubectl set image -n kpack deploy/kpack-controller \
    "controller=${REGISTRY}/kpack/controller:${TAG}"
  kubectl set image -n kpack deploy/kpack-webhook \
    "webhook=${REGISTRY}/kpack/webhook:${TAG}"

  kubectl set env -n kpack deploy/kpack-controller \
    "BUILD_INIT_IMAGE=${REGISTRY}/kpack/build-init:${TAG}" \
    "BUILD_WAITER_IMAGE=${REGISTRY}/kpack/build-waiter:${TAG}" \
    "REBASE_IMAGE=${REGISTRY}/kpack/rebase:${TAG}" \
    "COMPLETION_IMAGE=${REGISTRY}/kpack/completion:${TAG}"

  kubectl patch deploy kpack-controller -n kpack \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"controller","imagePullPolicy":"Always"}]}}}}'
  kubectl patch deploy kpack-webhook -n kpack \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"webhook","imagePullPolicy":"Always"}]}}}}'

  echo "Waiting for rollout..."
  kubectl rollout status deploy/kpack-controller -n kpack --timeout=120s
  kubectl rollout status deploy/kpack-webhook -n kpack --timeout=120s
  echo "kpack ARM64 deployment complete"
else
  echo "To deploy to the cluster, run:"
  echo "  $0 --deploy"
  echo ""
  echo "Or manually:"
  echo "  kubectl set image -n kpack deploy/kpack-controller controller=${REGISTRY}/kpack/controller:${TAG}"
  echo "  kubectl set image -n kpack deploy/kpack-webhook webhook=${REGISTRY}/kpack/webhook:${TAG}"
  echo "  kubectl set env -n kpack deploy/kpack-controller \\"
  echo "    BUILD_INIT_IMAGE=${REGISTRY}/kpack/build-init:${TAG} \\"
  echo "    BUILD_WAITER_IMAGE=${REGISTRY}/kpack/build-waiter:${TAG} \\"
  echo "    REBASE_IMAGE=${REGISTRY}/kpack/rebase:${TAG} \\"
  echo "    COMPLETION_IMAGE=${REGISTRY}/kpack/completion:${TAG}"
fi
