#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# install-k3s.sh — Runs INSIDE the Lima VM to install and configure K3s
#
# Usage: install-k3s.sh <VM_IP>
#   VM_IP is added as a TLS SAN so kubectl works from the host.
# ------------------------------------------------------------------

VM_IP="${1:?Usage: install-k3s.sh <VM_IP>}"

echo "==> Installing K3s (VM IP: ${VM_IP})"

# ---- Prepare directories ----------------------------------------
sudo mkdir -p /etc/rancher/k3s
sudo mkdir -p /data/persistent

# ---- Write containerd registry config ---------------------------
# Allows K3s containerd to authenticate when pulling images that
# reference artifactory.cfapps.cool directly in their image specs.
# K3s system images continue to pull from their original sources.
sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<'REGISTRIES'
configs:
  "artifactory.cfapps.cool":
    auth:
      # Will be populated by bootstrap.sh with pull credentials
      username: ""
      password: ""
    tls:
      insecure_skip_verify: false
REGISTRIES

# ---- Install K3s -------------------------------------------------
# Pinned to the campaign target (Wave 2, 2026-06-05). Fresh installs go straight to 1.36;
# the existing cluster was upgraded in-place via the 1.34.5 -> 1.35.5 -> 1.36.1 hop.
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.1+k3s1" INSTALL_K3S_EXEC="server" sh -s - \
  --disable servicelb \
  --disable traefik \
  --write-kubeconfig-mode 644 \
  --tls-san "${VM_IP}" \
  --data-dir /var/lib/rancher/k3s \
  --default-local-storage-path /data/persistent

# ---- Wait for node to be Ready ----------------------------------
echo "==> Waiting for K3s node to become Ready..."

KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG

for i in $(seq 1 60); do
  if kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
    echo "==> Node is Ready after ~${i} seconds."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: Node did not become Ready within 60 seconds."
    kubectl get nodes 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

# ---- Print final status -----------------------------------------
echo ""
echo "==> K3s node status:"
kubectl get nodes -o wide
echo ""
echo "==> K3s installation complete."
