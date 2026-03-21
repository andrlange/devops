#!/bin/bash
# Mirror Paketo buildpack and stack images to local artifact-keeper registry
#
# This enables fully offline cf push operations by hosting all buildpack
# images in the local registry instead of pulling from Docker Hub.
#
# Prerequisites:
#   - crane (go install github.com/google/go-containerregistry/cmd/crane@latest)
#   - Registry credentials configured (crane auth login)
#
# Usage:
#   ./mirror-buildpacks.sh                    # Mirror all images
#   ./mirror-buildpacks.sh --update-kpack     # Mirror + update ClusterStore/Stack
#
set -euo pipefail

LOCAL_REGISTRY="${LOCAL_REGISTRY:-artifacts.development.cfapps.cool}"
LOCAL_PREFIX="${LOCAL_REGISTRY}/korifi"

export PATH="${HOME}/go/bin:${PATH}"

command -v crane >/dev/null 2>&1 || { echo "ERROR: crane not found. Install with: go install github.com/google/go-containerregistry/cmd/crane@latest"; exit 1; }

# Buildpack images to mirror
BUILDPACKS=(java nodejs ruby procfile go php httpd)

# Stack images to mirror
STACK_BUILD="paketobuildpacks/build-jammy-full"
STACK_RUN="paketobuildpacks/run-jammy-full"

echo "=== Mirroring Paketo buildpacks to ${LOCAL_REGISTRY} ==="
echo ""

echo "--- Buildpack images ---"
for bp in "${BUILDPACKS[@]}"; do
  SRC="paketobuildpacks/${bp}"
  DST="${LOCAL_PREFIX}/buildpacks/${bp}"
  echo -n "  ${SRC} -> ${DST}... "
  if crane cp "${SRC}" "${DST}" 2>/dev/null; then
    echo "done"
  else
    echo "FAILED"
  fi
done

echo ""
echo "--- Stack images ---"
for img in "${STACK_BUILD}" "${STACK_RUN}"; do
  name=$(basename "${img}")
  DST="${LOCAL_PREFIX}/stacks/${name}"
  echo -n "  ${img} -> ${DST}... "
  if crane cp "${img}" "${DST}" 2>/dev/null; then
    echo "done"
  else
    echo "FAILED"
  fi
done

echo ""
echo "=== Mirror complete ==="

if [ "${1:-}" = "--update-kpack" ]; then
  echo ""
  echo "--- Updating kpack ClusterStore to local images ---"
  kubectl get clusterstore cf-default-buildpacks -o json | python3 -c "
import json, sys
cs = json.load(sys.stdin)
prefix = '${LOCAL_PREFIX}'
cs['spec']['sources'] = [{'image': f\"{prefix}/buildpacks/{bp}\"} for bp in '${BUILDPACKS[*]}'.split()]
json.dump(cs, sys.stdout)
" | kubectl apply -f - 2>&1 | tail -1

  echo "--- Updating kpack ClusterStack to local images ---"
  kubectl get clusterstack cf-default-stack -o json | python3 -c "
import json, sys
cs = json.load(sys.stdin)
prefix = '${LOCAL_PREFIX}'
cs['spec']['buildImage']['image'] = f\"{prefix}/stacks/build-jammy-full\"
cs['spec']['runImage']['image'] = f\"{prefix}/stacks/run-jammy-full\"
json.dump(cs, sys.stdout)
" | kubectl apply -f - 2>&1 | tail -1

  echo ""
  echo "kpack updated to use local images. Builder will rebuild (may take a few minutes)."
  echo "Check status: kubectl get clusterbuilder cf-kpack-cluster-builder -o wide"
else
  echo ""
  echo "To update kpack to use local images, run:"
  echo "  $0 --update-kpack"
fi
