# Phase 1 — Foundation

## Overview

### Phase Objective

Phase 1 lays the foundation for the entire K8s DevOps Stack. By the end of this phase, a fully functional K3s cluster runs inside a Lima VM on Apple Silicon, complete with secret management (OpenBao + ESO), load balancing (MetalLB), ingress (Traefik), and automated TLS certificate management (cert-manager). All subsequent phases (Platform, Monitoring, Services) build on this infrastructure.

### Component Overview with Versions

| Component | Version | Helm Chart Version | Namespace | Description |
|---|---|---|---|---|
| Lima VM | vzNAT | - | - | Virtualization via Apple Virtualization.framework |
| K3s | latest | - | kube-system | Lightweight Kubernetes distribution |
| OpenBao | 2.5.1 | 0.8.0 | openbao | Secret management (Vault-compatible fork) |
| External Secrets Operator | v0.16.1 | 0.16.1 | external-secrets | Synchronizes secrets from OpenBao into Kubernetes |
| MetalLB | v0.15.3 | 0.15.3 | metallb-system | L2 load balancer for bare-metal / VMs |
| Traefik | v3.6.10 | 39.0.5 | traefik | Ingress controller with dashboard |
| cert-manager | v1.20.0 | 1.20.0 | cert-manager | Automatic TLS certificates via Let's Encrypt |

### Dependency Chain

```
Lima VM
  └── K3s
        ├── OpenBao (Secret Management)
        │     └── External Secrets Operator (reads from OpenBao)
        │           └── cert-manager (DNS credentials via ESO)
        ├── MetalLB (LoadBalancer IPs)
        │     └── Traefik (receives IP from MetalLB)
        │           └── cert-manager (wildcard certificate in Traefik namespace)
        └── stack.sh (management on the host)
```

The installation order is: Lima VM -> K3s -> Pull Secrets -> OpenBao -> ESO -> MetalLB -> Traefik -> cert-manager -> TLS Store.

---

## 1.1 Lima VM

### What Is Installed and Why

Lima provides a Linux VM on macOS that runs on Apple's native `Virtualization.framework` (vmType: `vz`). This is the most performant option on Apple Silicon and offers:

- Near-native speed on ARM64
- vzNAT networking, which enables MetalLB L2 advertisements on the host network
- Rosetta translation for x86_64 binaries (as a fallback)

The VM is operated in `plain` mode — meaning Lima does not install its own guest agent. Mounts are defined through the VM configuration.

### Configuration Details

| Parameter | Value | Description |
|---|---|---|
| vmType | `vz` | Apple Virtualization.framework |
| plain | `true` | No Lima guest agent |
| CPUs | 8 | Configurable in `config.env` (LIMA_CPUS) |
| RAM | 48 GiB | Configurable in `config.env` (LIMA_MEMORY_GB) |
| Disk | 200 GiB | Configurable in `config.env` (LIMA_DISK_GB) |
| OS | Ubuntu 24.04 ARM64 | Cloud image |
| Network | vzNAT | Shared networking, subnet 192.168.64.0/24 |
| Rosetta | enabled | x86_64 emulation via binfmt |
| SSH | forwardAgent: true | SSH agent is forwarded |
| Mount | `/Users/andreas/development/devops/k8` -> `/mnt/k8` | Read-only |

**Configuration file:** `k8/bootstrap/lima.yaml`

### Provisioning

On the first VM start, the following packages are automatically installed and kernel modules loaded:

- **Packages:** curl, jq, open-iscsi, nfs-common, bash-completion, ca-certificates, gnupg
- **Kernel modules:** br_netfilter, ip_vs, ip_vs_rr, ip_vs_wrr, ip_vs_sh, nf_conntrack
- **sysctl settings:** IP forwarding, bridge netfilter, increased inotify limits
- **Directory:** `/data/persistent` is created as the base for persistent volumes

### Commands for Creating and Starting

```bash
# Create the VM
limactl create --name=k3s-server k8/bootstrap/lima.yaml

# Start the VM
limactl start k3s-server

# Open a shell into the VM
limactl shell k3s-server
```

### Validation

```bash
# Check VM status
limactl list

# Expected output: k3s-server with status "Running"

# Determine the VM IP
limactl shell k3s-server hostname -I

# Check kernel modules
limactl shell k3s-server lsmod | grep -E "br_netfilter|ip_vs"

# Check persistent volume directory
limactl shell k3s-server ls -la /data/persistent
```

---

## 1.2 K3s

### Installation with Disabled Components

K3s is installed with explicitly disabled components, as these are deployed separately via Helm:

- `--disable servicelb` — MetalLB is used instead
- `--disable traefik` — Traefik is installed as a separate Helm chart (full control over version and configuration)

**Installation script:** `k8/bootstrap/install-k3s.sh`

```bash
# Execute inside the Lima VM:
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
  --disable servicelb \
  --disable traefik \
  --write-kubeconfig-mode 644 \
  --tls-san "<VM_IP>" \
  --data-dir /var/lib/rancher/k3s \
  --default-local-storage-path /data/persistent
```

The `--tls-san` parameter adds the VM IP as a Subject Alternative Name to the K3s API server certificate. This allows kubectl to access it from the macOS host.

### registries.yaml Configuration

K3s containerd is configured to pull images from the private registry `artifactory.cfapps.cool`. The file is created during installation and later populated with the actual credentials by `bootstrap.sh`:

**Path inside the VM:** `/etc/rancher/k3s/registries.yaml`

```yaml
configs:
  "artifactory.cfapps.cool":
    auth:
      username: "<set by bootstrap.sh>"
      password: "<set by bootstrap.sh>"
    tls:
      insecure_skip_verify: false
```

After setting the credentials, K3s is restarted:

```bash
limactl shell k3s-server sudo systemctl restart k3s
```

### kubeconfig Export

The bootstrap.sh script automatically exports the kubeconfig to the macOS host:

```bash
# Run manually if needed:
VM_IP=$(limactl shell k3s-server hostname -I | awk '{print $1}')

limactl shell k3s-server sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127\.0\.0\.1/${VM_IP}/g" \
  | sed "s/default/k3s-devops/g" \
  > ~/.kube/config-k3s

chmod 600 ~/.kube/config-k3s
export KUBECONFIG=~/.kube/config-k3s
```

For permanent use in the shell:

```bash
echo 'export KUBECONFIG=~/.kube/config-k3s' >> ~/.zshrc
```

### Validation

```bash
export KUBECONFIG=~/.kube/config-k3s

# Check node status
kubectl get nodes -o wide
# Expected: 1 node with status "Ready"

# Verify disabled components — no Traefik/ServiceLB pods
kubectl get pods -n kube-system | grep -E "traefik|svclb"
# Expected: no results

# K3s version
kubectl version --short
```

---

## 1.3 OpenBao

### Helm Chart Installation

OpenBao is deployed as a standalone server (no HA) with file storage. All container images are pulled from the private registry.

**Directory:** `k8/services/openbao/`

| Parameter | Value |
|---|---|
| Helm Chart | openbao/openbao v0.8.0 |
| Image | `artifactory.cfapps.cool/docker-local/openbao/openbao:2.5.1-arm64` |
| Mode | Standalone (no HA) |
| Storage | File-based, 10Gi PV (local-path) |
| Audit Storage | 2Gi PV (local-path) |
| UI | Enabled (ClusterIP Service) |
| Injector | Disabled (ESO is used instead) |

```bash
# Create namespace
kubectl create namespace openbao

# Create pull secret (prompted interactively by bootstrap.sh)
kubectl create secret docker-registry artifact-keeper-pull \
  --docker-server=artifactory.cfapps.cool \
  --docker-username="<username>" \
  --docker-password="<password>" \
  -n openbao

# Load Helm dependencies and install
cd k8/services/openbao
helm dependency build
helm install openbao . -n openbao

# Wait until the pod is running (will NOT be Ready, as it is still sealed)
kubectl get pods -n openbao -w
```

### Initialization and Unseal

OpenBao must be initialized once. During this process, 5 unseal keys and a root token are generated. To unseal, 3 of the 5 keys are required (Shamir's Secret Sharing, threshold 3/5).

```bash
# Initialization
kubectl exec -n openbao openbao-0 -- bao operator init

# IMPORTANT: Store the unseal keys and root token in a password manager IMMEDIATELY!
# They will NOT be displayed again.

# Unseal (use 3 different keys)
kubectl exec -n openbao openbao-0 -- bao operator unseal <UNSEAL_KEY_1>
kubectl exec -n openbao openbao-0 -- bao operator unseal <UNSEAL_KEY_2>
kubectl exec -n openbao openbao-0 -- bao operator unseal <UNSEAL_KEY_3>
```

### Enable KV v2 Engine

```bash
# Log in with root token
kubectl exec -it -n openbao openbao-0 -- bao login
# Enter root token

# Enable KV v2 secret engine at the path "secret"
kubectl exec -it -n openbao openbao-0 -- bao secrets enable -path=secret kv-v2
```

### Configure Kubernetes Auth Method

The Kubernetes auth method allows pods (specifically ESO) to authenticate with OpenBao using their ServiceAccount.

```bash
# Enable Kubernetes auth
kubectl exec -it -n openbao openbao-0 -- bao auth enable kubernetes

# Configure Kubernetes auth (uses the in-cluster API server)
kubectl exec -it -n openbao openbao-0 -- bao write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
```

### Create ESO Policy and Role

ESO requires a policy with read permissions on the secrets and a Kubernetes auth role bound to the ESO ServiceAccount.

```bash
# Create policy
kubectl exec -it -n openbao openbao-0 -- bao policy write external-secrets - <<'POLICY'
path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }
POLICY

# Create Kubernetes auth role for ESO
kubectl exec -it -n openbao openbao-0 -- bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h
```

### Store Bootstrap Secrets

The following secrets are stored in OpenBao and later synchronized into Kubernetes secrets by ESO:

**DNS Credentials (for cert-manager DNS-01 challenge):**

```bash
# GCP service account JSON for Cloud DNS
kubectl exec -it -n openbao openbao-0 -- bao kv put secret/dns/google-cloud \
  credentials=@/path/to/gcp-service-account.json
```

Note: The file must first be copied into the pod, or the content can be passed directly as a string:

```bash
# Alternative: pass JSON content directly
kubectl exec -it -n openbao openbao-0 -- bao kv put secret/dns/google-cloud \
  credentials='{"type":"service_account","project_id":"cfapps-cool",...}'
```

**Registry Pull Credentials (for ESO-managed pull secrets):**

```bash
kubectl exec -it -n openbao openbao-0 -- bao kv put secret/k8s/registry \
  server="https://artifactory.cfapps.cool" \
  username="<pull-user>" \
  password="<pull-token>"
```

### Validation

```bash
# Check pod status
kubectl get pods -n openbao
# Expected: openbao-0 Running 1/1

# Check seal status
kubectl exec -n openbao openbao-0 -- bao status
# Expected: Sealed = false

# Check secret engine
kubectl exec -n openbao openbao-0 -- bao secrets list
# Expected: secret/ of type kv (version 2)

# Check auth methods
kubectl exec -n openbao openbao-0 -- bao auth list
# Expected: kubernetes/ of type kubernetes

# Check stored secrets
kubectl exec -n openbao openbao-0 -- bao kv list secret/
# Expected: dns/ and k8s/ as subdirectories
```

---

## 1.4 External Secrets Operator (ESO)

### Installation and ClusterSecretStore

ESO is installed to automatically synchronize secrets from OpenBao into Kubernetes secrets. This eliminates the need to store any secrets in Git.

**Directory:** `k8/platform/external-secrets/`

| Parameter | Value |
|---|---|
| Helm Chart | external-secrets v0.16.1 |
| Image | `artifactory.cfapps.cool/docker-local/external-secrets/external-secrets:v0.16.1-arm64` |
| CRDs | Installed alongside the chart (installCRDs: true) |
| Components | Controller, Webhook, CertController |

```bash
# Create namespace
kubectl create namespace external-secrets

# Create pull secret
kubectl create secret docker-registry artifact-keeper-pull \
  --docker-server=artifactory.cfapps.cool \
  --docker-username="<username>" \
  --docker-password="<password>" \
  -n external-secrets

# Load Helm dependencies and install
cd k8/platform/external-secrets
helm dependency build
helm install external-secrets . -n external-secrets

# Wait until all pods are ready
kubectl wait --for=condition=Ready pods --all -n external-secrets --timeout=120s
```

The **ClusterSecretStore** connects ESO with OpenBao via the Kubernetes auth method:

**File:** `k8/platform/external-secrets/cluster-secret-store.yaml`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: openbao
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "external-secrets"
```

```bash
# Apply ClusterSecretStore
kubectl apply -f k8/platform/external-secrets/cluster-secret-store.yaml
```

### ClusterExternalSecret for Registry Pull Secrets

A `ClusterExternalSecret` ensures that a pull secret for the private registry is automatically created in every namespace. This eliminates the need for manual secret management on a per-namespace basis.

**File:** `k8/platform/external-secrets/registry-pull-secret.yaml`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterExternalSecret
metadata:
  name: artifact-keeper-pull
spec:
  namespaceSelectors:
    - matchLabels: {}
  externalSecretSpec:
    refreshInterval: 1h
    secretStoreRef:
      kind: ClusterSecretStore
      name: openbao
    target:
      name: artifact-keeper-pull
      template:
        type: kubernetes.io/dockerconfigjson
        data:
          .dockerconfigjson: |
            {"auths":{"{{ .server }}":{"username":"{{ .username }}","password":"{{ .password }}"}}}
    data:
      - secretKey: server
        remoteRef:
          key: secret/k8s/registry
          property: server
      - secretKey: username
        remoteRef:
          key: secret/k8s/registry
          property: username
      - secretKey: password
        remoteRef:
          key: secret/k8s/registry
          property: password
```

```bash
# Apply ClusterExternalSecret
kubectl apply -f k8/platform/external-secrets/registry-pull-secret.yaml
```

### Validation

```bash
# Check ESO pods
kubectl get pods -n external-secrets
# Expected: 3 pods (controller, webhook, cert-controller) all Running

# Check ClusterSecretStore status
kubectl get clustersecretstore
# Expected: openbao with status "Valid" / condition "True"

# Check ClusterExternalSecret
kubectl get clusterexternalsecret
# Expected: artifact-keeper-pull present

# Verify that pull secrets have been created in namespaces
kubectl get secret artifact-keeper-pull --all-namespaces
# Expected: secret present in all namespaces
```

---

## 1.5 MetalLB

### L2 Mode with vzNAT Subnet

MetalLB provides LoadBalancer IPs that reside within the vzNAT subnet of the Lima VM. In L2 mode, MetalLB responds to ARP requests for the assigned IPs, allowing the macOS host to reach them directly.

**Directory:** `k8/infrastructure/metallb/`

| Parameter | Value |
|---|---|
| Helm Chart | metallb v0.15.3 |
| Controller Image | `artifactory.cfapps.cool/docker-local/metallb/controller:v0.15.3-arm64` |
| Speaker Image | `artifactory.cfapps.cool/docker-local/metallb/speaker:v0.15.3-arm64` |
| FRR | Disabled (only L2 mode is needed) |

```bash
# Create namespace
kubectl create namespace metallb-system

# Create pull secret
kubectl create secret docker-registry artifact-keeper-pull \
  --docker-server=artifactory.cfapps.cool \
  --docker-username="<username>" \
  --docker-password="<password>" \
  -n metallb-system

# Load Helm dependencies and install
cd k8/infrastructure/metallb
helm dependency build
helm install metallb . -n metallb-system

# Wait until all pods are ready
kubectl wait --for=condition=Ready pods --all -n metallb-system --timeout=120s
```

### IP Address Pool Configuration

**File:** `k8/infrastructure/metallb/ip-pool.yaml`

The IP pool defines the range `192.168.64.200-192.168.64.210` (11 IPs) in the upper portion of the vzNAT subnet to avoid collisions with DHCP addresses assigned to the VM. The `L2Advertisement` ensures that MetalLB responds to ARP requests for these IPs.

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.64.200-192.168.64.210
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
```

```bash
# Apply IP pool and L2 advertisement
kubectl apply -f k8/infrastructure/metallb/ip-pool.yaml
```

### Validation

```bash
# Check MetalLB pods
kubectl get pods -n metallb-system
# Expected: controller and speaker pods Running

# Check IP address pool
kubectl get ipaddresspool -n metallb-system
# Expected: default-pool with address range 192.168.64.200-192.168.64.210

# Check L2 advertisement
kubectl get l2advertisement -n metallb-system
# Expected: default present

# Test: Create a LoadBalancer service and verify an IP is assigned
kubectl create deployment nginx-test --image=nginx --port=80 -n default
kubectl expose deployment nginx-test --type=LoadBalancer --port=80 -n default
kubectl get svc nginx-test -n default
# Expected: EXTERNAL-IP from the range 192.168.64.200-210

# Clean up
kubectl delete deployment nginx-test -n default
kubectl delete svc nginx-test -n default
```

---

## 1.6 Traefik

### LoadBalancer Service via MetalLB

Traefik is deployed as the ingress controller and receives a fixed LoadBalancer IP from MetalLB. All HTTP(S) requests to `*.development.cfapps.cool` are routed through this IP.

**Directory:** `k8/infrastructure/traefik/`

| Parameter | Value |
|---|---|
| Helm Chart | traefik v39.0.5 |
| Image | `artifactory.cfapps.cool/docker-local/traefik:v3.6.10-arm64` |
| Service Type | LoadBalancer |
| Kubernetes CRD Provider | Enabled (cross-namespace allowed) |
| Kubernetes Ingress Provider | Enabled |

```bash
# Create namespace
kubectl create namespace traefik

# Create pull secret
kubectl create secret docker-registry artifact-keeper-pull \
  --docker-server=artifactory.cfapps.cool \
  --docker-username="<username>" \
  --docker-password="<password>" \
  -n traefik

# Load Helm dependencies and install
cd k8/infrastructure/traefik
helm dependency build
helm install traefik . -n traefik

# Wait for LoadBalancer IP
kubectl get svc -n traefik traefik -w
# Expected: EXTERNAL-IP is assigned (e.g., 192.168.64.200)
```

### HTTP->HTTPS Redirect

Traefik is configured to automatically redirect all HTTP requests (port 80) to HTTPS (port 443):

```yaml
additionalArguments:
  - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
  - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
  - "--entrypoints.websecure.http.tls"
```

### Dashboard IngressRoute

The Traefik dashboard is accessible at `https://traefik.development.cfapps.cool`:

```yaml
ingressRoute:
  dashboard:
    enabled: true
    matchRule: Host(`traefik.development.cfapps.cool`)
    entryPoints:
      - websecure
```

### TLSStore for Wildcard Certificate

After installing cert-manager and issuing the wildcard certificate, a TLSStore is configured to set the wildcard certificate as the default certificate for all HTTPS connections.

**File:** `k8/infrastructure/traefik/tls-store.yaml`

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: traefik
spec:
  defaultCertificate:
    secretName: wildcard-development-tls
```

```bash
# Apply TLSStore (AFTER cert-manager installation)
kubectl apply -f k8/infrastructure/traefik/tls-store.yaml
```

### Validation

```bash
# Check Traefik pods
kubectl get pods -n traefik
# Expected: traefik pod Running

# Check LoadBalancer IP
kubectl get svc -n traefik traefik
# Expected: EXTERNAL-IP assigned (e.g., 192.168.64.200)

# Test HTTP redirect (from macOS host)
LB_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -v http://${LB_IP} 2>&1 | grep "Location:"
# Expected: Location: https://... (301 Redirect)

# Dashboard accessible (after DNS configuration)
curl -k https://traefik.development.cfapps.cool
# Or via /etc/hosts: <LB_IP> traefik.development.cfapps.cool
```

---

## 1.7 cert-manager

### DNS-01 Challenge with Cloud DNS

cert-manager uses the DNS-01 challenge to obtain wildcard certificates from Let's Encrypt. Validation is performed via Google Cloud DNS: cert-manager creates a TXT record in the `cfapps.cool` zone, Let's Encrypt verifies it, and the certificate is issued.

**Directory:** `k8/infrastructure/cert-manager/`

| Parameter | Value |
|---|---|
| Helm Chart | cert-manager v1.20.0 |
| Controller Image | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-controller:v1.20.0-arm64` |
| CAInjector Image | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-cainjector:v1.20.0-arm64` |
| Webhook Image | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-webhook:v1.20.0-arm64` |
| ACME Solver Image | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-acmesolver:v1.20.0-arm64` |
| CRDs | Installed alongside the chart |
| Startup API Check | Disabled |

```bash
# Create namespace
kubectl create namespace cert-manager

# Create pull secret
kubectl create secret docker-registry artifact-keeper-pull \
  --docker-server=artifactory.cfapps.cool \
  --docker-username="<username>" \
  --docker-password="<password>" \
  -n cert-manager

# Load Helm dependencies and install
cd k8/infrastructure/cert-manager
helm dependency build
helm install cert-manager . -n cert-manager

# Wait until all pods are ready
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=120s
```

The DNS credentials are synchronized from OpenBao via ESO:

**File:** `k8/infrastructure/cert-manager/dns-external-secret.yaml`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: google-cloud-dns
  namespace: cert-manager
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: google-cloud-dns-credentials
  data:
    - secretKey: credentials.json
      remoteRef:
        key: secret/dns/google-cloud
        property: credentials
```

```bash
# Apply DNS ExternalSecret
kubectl apply -f k8/infrastructure/cert-manager/dns-external-secret.yaml

# Wait until the secret has been synchronized
kubectl get secret google-cloud-dns-credentials -n cert-manager
```

### ClusterIssuer Configuration

**File:** `k8/infrastructure/cert-manager/clusterissuer.yaml`

The ClusterIssuer uses the ACME production server from Let's Encrypt and Google Cloud DNS for the DNS-01 challenge. The variable `${GCP_PROJECT_ID}` is substituted by `envsubst` from `config.env` (value: `cfapps-cool`).

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@cfapps.cool
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - dns01:
          cloudDNS:
            project: "${GCP_PROJECT_ID}"
            serviceAccountSecretRef:
              name: google-cloud-dns-credentials
              key: credentials.json
        selector:
          dnsZones:
            - "cfapps.cool"
```

```bash
# Apply ClusterIssuer (with envsubst for GCP_PROJECT_ID)
source k8/config.env
envsubst < k8/infrastructure/cert-manager/clusterissuer.yaml | kubectl apply -f -
```

### Wildcard Certificate

**File:** `k8/infrastructure/cert-manager/wildcard-certificate.yaml`

The certificate is created in the `traefik` namespace, as Traefik uses it as the default certificate.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-development
  namespace: traefik
spec:
  secretName: wildcard-development-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "*.development.cfapps.cool"
    - "development.cfapps.cool"
```

```bash
# Request wildcard certificate
kubectl apply -f k8/infrastructure/cert-manager/wildcard-certificate.yaml

# Configure TLSStore (Traefik uses the wildcard certificate as default)
kubectl apply -f k8/infrastructure/traefik/tls-store.yaml
```

### Validation

```bash
# Check cert-manager pods
kubectl get pods -n cert-manager
# Expected: 3 pods (controller, cainjector, webhook) all Running

# Check ClusterIssuer
kubectl get clusterissuer
# Expected: letsencrypt-prod with status "True" / "Ready"

# Check DNS credentials secret
kubectl get secret google-cloud-dns-credentials -n cert-manager
# Expected: secret present

# Check certificate status
kubectl get certificate -n traefik
# Expected: wildcard-development with READY=True

# Show certificate details
kubectl describe certificate wildcard-development -n traefik

# Check CertificateRequest (for troubleshooting)
kubectl get certificaterequest -n traefik

# Check secret containing the certificate
kubectl get secret wildcard-development-tls -n traefik
# Expected: secret of type kubernetes.io/tls present

# Test TLS connection (after DNS configuration)
LB_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -v --resolve "traefik.development.cfapps.cool:443:${LB_IP}" \
  https://traefik.development.cfapps.cool 2>&1 | grep "subject:"
# Expected: subject: CN=*.development.cfapps.cool
```

---

## 1.8 stack.sh

### Description

`stack.sh` is the central management script for the entire K8s DevOps Stack. It runs on the macOS host and controls the lifecycle of the Lima VM and the K3s cluster.

**Path:** `k8/stack.sh`

The script reads its configuration from `k8/config.env` and manages the kubeconfig at `~/.kube/config-k3s`.

### Start/Stop/Status/Restart/Backup Commands

```bash
# Start the stack
# - Starts the Lima VM if stopped
# - Waits for the K3s API server
# - Updates kubeconfig on the host (VM IP may change)
# - Waits for core pods (kube-system, openbao, traefik)
# - Checks OpenBao seal status (hint for manual unseal)
# - Displays endpoints
./k8/stack.sh start

# Stop the stack
# - Stops the Lima VM (all pods are terminated)
./k8/stack.sh stop

# Stop the stack with a prior backup
# - Creates a Velero backup before stopping the VM
./k8/stack.sh stop --backup

# Show status
# - Lima VM status (IP, CPU, RAM, disk)
# - K3s node status
# - Namespace overview with pod counts (Ready/Not-Ready)
# - ArgoCD application sync status
# - TLS certificates with expiration dates
# - Endpoint reachability (HTTP status codes)
./k8/stack.sh status

# Restart the stack
# - Stops and starts the stack
./k8/stack.sh restart

# Create Velero backup
# - Uses the velero CLI if installed, otherwise kubectl
# - Creates a manual backup of all namespaces
./k8/stack.sh backup
```

### Status Output

The `status` command displays a comprehensive overview:

- **Lima VM:** Status, IP address, resources (CPU/RAM/disk)
- **K3s Nodes:** Node status with details
- **Namespaces:** Tabular overview with total/ready/not-ready pod counts
- **OpenBao:** Seal status (sealed/unsealed) with a warning if sealed
- **ArgoCD:** Sync and health status of all applications
- **TLS Certificates:** Name, namespace, ready status, expiration date
- **Endpoints:** URL and reachability (UP/DOWN with HTTP status code) for all services

---

## Automated Bootstrap

All phases can be executed with a single command:

```bash
# Complete bootstrap (all phases)
./k8/bootstrap/bootstrap.sh

# Execute a single phase
./k8/bootstrap/bootstrap.sh phase_k3s
./k8/bootstrap/bootstrap.sh phase_pull_secrets
./k8/bootstrap/bootstrap.sh phase_openbao
./k8/bootstrap/bootstrap.sh phase_eso
./k8/bootstrap/bootstrap.sh phase_metallb
./k8/bootstrap/bootstrap.sh phase_traefik
./k8/bootstrap/bootstrap.sh phase_certmanager
./k8/bootstrap/bootstrap.sh phase_tls_store

# Combine multiple phases
./k8/bootstrap/bootstrap.sh phase_traefik phase_certmanager
```

**Prerequisites on the macOS host:**

```bash
# Install required tools
brew install lima kubectl helm
```

---

## Known Limitations

### Lima plain mode: Limited mounts

In `plain` mode, Lima does not install a guest agent in the VM. The mount from `k8/` to `/mnt/k8` is read-only (`writable: false`). Files that need to be modified inside the VM (e.g., `registries.yaml`) are written directly via `limactl shell` and `tee`, not through the mount.

### OpenBao must be manually unsealed after every VM restart

OpenBao uses Shamir's Secret Sharing and does not persist the unseal keys. After every restart of the Lima VM (or the OpenBao pod), OpenBao must be manually unsealed with 3 of the 5 unseal keys:

```bash
kubectl exec -n openbao openbao-0 -- bao operator unseal <KEY_1>
kubectl exec -n openbao openbao-0 -- bao operator unseal <KEY_2>
kubectl exec -n openbao openbao-0 -- bao operator unseal <KEY_3>
```

The `stack.sh start` command detects a sealed OpenBao and displays a warning.

### vzNAT subnet is determined by macOS

The vzNAT subnet (`192.168.64.0/24`) is assigned by macOS Virtualization.framework and cannot be freely chosen. The typical range is `192.168.64.0/24`, but it may change. If the subnet changes, the following values in `config.env` must be updated:

```bash
NETWORK_SUBNET="192.168.64.0/24"
NETWORK_GATEWAY="192.168.64.1"
NETWORK_DNS="192.168.64.1"
METALLB_IP_RANGE="192.168.64.200-192.168.64.210"
```

Additionally, the `ip-pool.yaml` for MetalLB must be updated.

### VM IP may change on restarts

The VM receives its IP via DHCP from the vzNAT interface. On VM restarts, the IP may change. `stack.sh start` automatically updates the kubeconfig with the new IP. If kubectl does not work after a restart:

```bash
# Manually update kubeconfig
VM_IP=$(limactl shell k3s-server hostname -I | awk '{print $1}')
limactl shell k3s-server sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127\.0\.0\.1/${VM_IP}/g" \
  | sed "s/default/k3s-devops/g" \
  > ~/.kube/config-k3s
```

### Container images from private registry

All container images are pulled from the private registry `artifactory.cfapps.cool`. Before installing each component, a pull secret (`artifact-keeper-pull`) must be created in the respective namespace. After ESO installation, the `ClusterExternalSecret` takes over this task automatically for all namespaces.

### DNS configuration required

For services to be reachable via `*.development.cfapps.cool`, a DNS entry (or `/etc/hosts`) must point the wildcard domain to the Traefik LoadBalancer IP:

```bash
# Determine LoadBalancer IP
LB_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Add to /etc/hosts (for local access)
sudo bash -c "echo '${LB_IP} traefik.development.cfapps.cool argocd.development.cfapps.cool grafana.development.cfapps.cool' >> /etc/hosts"
```
