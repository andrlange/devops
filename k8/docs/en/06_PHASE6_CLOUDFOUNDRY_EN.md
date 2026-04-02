# Phase 6: Cloud Foundry / Korifi (OPTIONAL)

## Overview

**Goal:** Cloud Foundry experience on Kubernetes via Korifi -- `cf push` to deploy applications under `*.app.cfapps.cool`. Service Binding for PostgreSQL, Redis, and RabbitMQ enables classic CF workflows on the existing K8s infrastructure.

**OPTIONAL:** This phase can be skipped entirely. The full stack works without Cloud Foundry. Korifi is beta software and primarily serves to gain CF experience in a K8s-native environment.

**Prerequisites:**
- Phase 1-3 (Foundation, Platform, Monitoring) fully completed
- Phase 4 (Services) and Phase 5 (GitLab) are **not** strictly required
- QEMU user-static installed in the Lima VM (for ARM64 emulation)
- Container images imported into the registry (see respective sections)
- `cf` CLI installed on the host

**Korifi Version:** v0.18.0 (Beta)

**Resource Requirements:**
- Korifi + Contour + kpack: ~800Mi-1Gi RAM in addition to the existing stack
- Each deployed app: ~1Gi RAM by default (configurable via `cf scale`)
- Builds: ~2Gi RAM temporarily (QEMU emulation is memory-intensive)

**Architecture:**

```
    Developer Host                          Lima VM (K3s)
    ┌──────────┐                ┌───────────────────────────────────────────────┐
    │          │                │                                               │
    │  cf CLI ─┼───cf push─────▶│  Korifi API (api.app.cfapps.cool)             │
    │          │                │       │                                       │
    └──────────┘                │       ▼                                       │
                                │  ┌─────────────────────────────────────┐      │
                                │  │  Korifi Controllers                 │      │
                                │  │  (CFApp → CFPackage → CFBuild →     │      │
                                │  │   CFProcess → CFRoute)              │      │
                                │  └────────┬──────────┬─────────────────┘      │
                                │           │          │                        │
                                │           ▼          ▼                        │
                                │  ┌───────────────┐ ┌────────────────────┐     │
                                │  │ kpack         │ │ statefulset-runner │     │
                                │  │ (Buildpacks)  │ │ (App Runtime)      │     │
                                │  │               │ │                    │     │
                                │  │ Source Code   │ │ Container Image    │     │
                                │  │   ▼           │ │   ▼                │     │
                                │  │ Heroku        │ │ StatefulSet        │     │
                                │  │ builder:24    │ │ (1..N instances)   │     │
                                │  │   ▼           │ │                    │     │
                                │  │ OCI Image     │ │                    │     │
                                │  │ → Registry    │ │                    │     │
                                │  └───────────────┘ └────────┬───────────┘     │
                                │                             │                 │
                                │                             ▼                 │
                                │  ┌─────────────────────────────────────┐      │
                                │  │  HTTPRoute (Gateway API)            │      │
                                │  │  my-app.app.cfapps.cool             │      │
                                │  └────────────────┬────────────────────┘      │
                                │                   │                           │
                                │                   ▼                           │
                                │  ┌─────────────────────────────────────┐      │
                                │  │  Contour (Gateway API Controller)   │      │
                                │  │  LoadBalancer: 192.168.64.203       │      │
                                │  └────────────────┬────────────────────┘      │
                                │                   │                           │
                                └───────────────────┼───────────────────────────┘
                                                    │
                                                    ▼
                                             ┌──────────────┐
                                             │   MetalLB    │
                                             │  L2 Mode     │
                                             └──────────────┘
                                                    │
                                                    ▼
                                               Browser / curl
                                          my-app.app.cfapps.cool
```

**Korifi Components:**

| Component              | Description                                                 |
|------------------------|-------------------------------------------------------------|
| API                    | CF API v3 compatible, receives `cf push` and CLI commands   |
| Controllers            | Reconciles CF CRDs into K8s-native resources                |
| kpack-image-builder    | Builds source code into OCI images via Cloud Native Buildpacks |
| statefulset-runner     | Creates StatefulSets for running app instances              |
| job-task-runner        | Executes one-off tasks (`cf run-task`)                      |

**Custom Resource Definitions (CRDs):**

| CRD        | Description                                               |
|------------|-----------------------------------------------------------|
| CFOrg      | Organization (multi-tenancy unit)                         |
| CFSpace    | Space within an org (deployment target)                   |
| CFApp      | Application with lifecycle management                     |
| CFPackage  | Source code package (uploaded via `cf push`)               |
| CFBuild    | Build job (source -> image via kpack)                     |
| CFProcess  | Running process (web, worker, etc.)                       |
| CFRoute    | HTTP route (domain + path -> app)                         |
| CFDomain   | DNS domain (e.g., app.cfapps.cool)                        |

---

## ARM64 Limitations (IMPORTANT)

> **kpack is NOT ARM64-compatible.** The kpack controller is hardcoded for AMD64. On Apple Silicon (M4+), QEMU user-static emulation in the Lima VM is therefore required.

**Impact:**

- **Build Performance:** Significantly slower under QEMU emulation. A simple Go build can take 3-5 minutes instead of 30 seconds. Java builds can require 10+ minutes.
- **Heroku builder:24** has the best ARM64 buildpack support and is recommended:
  - Go, Java, Node.js, Python, Ruby, PHP -- all supported
- **Paketo Buildpacks** are ARM64-compatible only for **Java** and **Rust**. For other languages, it falls back to AMD64 emulation.
- **QEMU installation** is mandatory before deploying kpack or Korifi.

```bash
# Install QEMU user-static in the Lima VM
limactl shell k3s-server sudo apt install -y qemu-user-static

# Verify that binfmt_misc is registered
limactl shell k3s-server ls /proc/sys/fs/binfmt_misc/
# Expected output: qemu-x86_64 (among others)
```

---

## Prerequisites

### Checklist

- [ ] Phase 1 (Foundation): K3s, MetalLB, Traefik, cert-manager, OpenBao, ESO
- [ ] Phase 2 (Platform): ArgoCD, Garage (for container registry if used)
- [ ] Phase 3 (Monitoring): Grafana, Loki (for log aggregation of CF apps)
- [ ] QEMU user-static installed in Lima VM (see 6.1)
- [ ] Contour deployed as Gateway API Controller (see 6.2)
- [ ] kpack installed and configured (see 6.3)
- [ ] Service Binding Runtime installed (see 6.4)
- [ ] DNS records configured
- [ ] cf CLI installed on the host

### DNS Records

The following DNS records must be configured in Technitium (or `/etc/hosts`):

| Record                   | Type  | Target            | Description           |
|--------------------------|-------|-------------------|-----------------------|
| `api.app.cfapps.cool`   | A     | 192.168.64.203    | Korifi API endpoint   |
| `*.app.cfapps.cool`     | A     | 192.168.64.203    | App wildcard domain   |

The IP `192.168.64.203` is the separate MetalLB IP for Contour (not Traefik).

### Install cf CLI

```bash
# macOS (Homebrew)
brew install cloudfoundry/tap/cf-cli@8

# Verify
cf version
# Expected output: cf version 8.x.x
```

---

## 6.1 Install QEMU user-static

QEMU user-static enables execution of AMD64 binaries on ARM64 via transparent emulation. This is required because kpack and various buildpack builders are only available as AMD64 images.

```bash
# Installation
limactl shell k3s-server sudo apt update
limactl shell k3s-server sudo apt install -y qemu-user-static

# Verify
limactl shell k3s-server file /usr/bin/qemu-x86_64-static
# Expected output: /usr/bin/qemu-x86_64-static: ELF 64-bit LSB executable, ARM aarch64

# Check binfmt_misc registration
limactl shell k3s-server cat /proc/sys/fs/binfmt_misc/qemu-x86_64
# "enabled" must appear in the output

# Test: Execute an AMD64 binary
limactl shell k3s-server -- docker run --rm --platform linux/amd64 alpine uname -m
# Expected output: x86_64
```

> **Note:** After restarting the Lima VM, `binfmt_misc` may need to be re-registered. However, QEMU user-static is normally activated automatically via systemd-binfmt at boot.

---

## 6.2 Contour (Gateway API Controller)

### Why Contour Instead of Traefik?

Korifi is officially tested **only with Contour** as the Gateway API Controller. Traefik's Gateway API implementation exists but is untested with Korifi, and there are known incompatibilities with HTTPRoute features. Contour runs **in parallel** with Traefik on a **separate MetalLB IP** -- there are no conflicts.

| Property        | Traefik (existing)         | Contour (new for Korifi)   |
|-----------------|----------------------------|----------------------------|
| Role            | Ingress for all services   | Gateway API for CF apps    |
| MetalLB IP      | 192.168.64.201             | 192.168.64.203             |
| Domains         | *.development.cfapps.cool  | *.app.cfapps.cool          |
| Gateway API     | not used                   | active (GatewayClass)      |

### Create Namespace

```bash
kubectl create namespace projectcontour
```

### Helm Installation

```bash
# Add Helm repo
helm repo add projectcontour https://projectcontour.github.io/contour
helm repo update

# Install Contour
helm install contour projectcontour/contour \
  --namespace projectcontour \
  --version 19.1.1 \
  --set contour.gatewayAPI.enabled=true \
  --set envoy.service.type=LoadBalancer \
  --set envoy.service.annotations."metallb\.universe\.tf/loadBalancerIPs"=192.168.64.203
```

### Create GatewayClass and Gateway

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: contour
spec:
  controllerName: projectcontour.io/gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: contour
  namespace: projectcontour
spec:
  gatewayClassName: contour
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 443
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: cf-wildcard-tls
            namespace: projectcontour
```

```bash
kubectl apply -f gateway.yaml
```

### Validation

```bash
# Check Contour pods
kubectl get pods -n projectcontour
# contour-xxx   Running
# envoy-xxx     Running

# Check LoadBalancer IP
kubectl get svc -n projectcontour envoy
# EXTERNAL-IP: 192.168.64.203

# Check GatewayClass
kubectl get gatewayclass contour
# ACCEPTED: True
```

---

## 6.3 Install kpack

kpack builds source code into OCI container images via Cloud Native Buildpacks. It watches `Image` CRDs and automatically triggers builds when source code or buildpacks change.

### Install kpack Release

```bash
# Install kpack v0.15.1
kubectl apply -f https://github.com/buildpacks-community/kpack/releases/download/v0.15.1/release-v0.15.1.yaml

# Wait until controller is ready
kubectl wait --for=condition=Ready pods -l app=kpack-controller -n kpack --timeout=120s
```

### Container Registry Credentials

kpack requires access to a container registry to store built images. Here, the internal Artifactory registry is used.

```yaml
# registry-credentials.yaml
apiVersion: v1
kind: Secret
metadata:
  name: registry-credentials
  namespace: cf
  annotations:
    kpack.io/docker: artifactory.cfapps.cool
type: kubernetes.io/basic-auth
data:
  username: <base64-encoded>
  password: <base64-encoded>
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kpack-service-account
  namespace: cf
secrets:
  - name: registry-credentials
imagePullSecrets:
  - name: registry-credentials
```

```bash
kubectl apply -f registry-credentials.yaml
```

### ClusterStore, ClusterStack, and ClusterBuilder

The Korifi Helm installation automatically creates a ClusterStore (`cf-default-buildpacks`), ClusterStack (`cf-default-stack`), and ClusterBuilder (`cf-kpack-cluster-builder`) with Paketo Buildpacks. The default configuration includes Java, Go, Node.js, Ruby, and Procfile.

For additional languages (PHP, httpd/Apache), buildpacks must be added after the fact. The installer (`install.sh`) handles this automatically. Manually:

```bash
# Add buildpack to ClusterStore (example: PHP)
kubectl get clusterstore cf-default-buildpacks -o json | python3 -c "
import json, sys
cs = json.load(sys.stdin)
cs['spec']['sources'].append({'image': 'paketobuildpacks/php'})
json.dump(cs, sys.stdout)
" | kubectl apply -f -

# Add buildpack to ClusterBuilder
kubectl get clusterbuilder cf-kpack-cluster-builder -o json | python3 -c "
import json, sys
cb = json.load(sys.stdin)
cb['spec']['order'].append({'group': [{'id': 'paketo-buildpacks/php'}]})
json.dump(cb, sys.stdout)
" | kubectl apply -f -
```

**Available Buildpacks (automatically installed):**

| Buildpack | Language/Purpose | JDK/Runtime |
|-----------|------------------|-------------|
| `paketo-buildpacks/java` | Java, Spring Boot, Maven, Gradle | JDK 21+ (JDK 25 via `BP_JVM_VERSION=25`) |
| `paketo-buildpacks/go` | Go | Current Go version |
| `paketo-buildpacks/nodejs` | Node.js, npm, yarn | Current LTS |
| `paketo-buildpacks/php` | PHP, Composer | Current PHP version |
| `paketo-buildpacks/ruby` | Ruby, Bundler | Current Ruby version |
| `paketo-buildpacks/httpd` | Static files via Apache | Apache httpd |
| `paketo-buildpacks/procfile` | Procfile-based apps | Any |

**Control JDK version (e.g., JDK 25):**

```yaml
# In manifest.yml:
env:
  BP_JVM_VERSION: "25"
```

```bash
# Check ClusterBuilder status (may take a few minutes due to image pull)
kubectl get clusterbuilder cf-kpack-cluster-builder -o wide
# READY: True
```

> **Note:** The first ClusterBuilder build takes significantly longer under QEMU emulation (5-15 minutes). This is normal. After each change to the ClusterStore or ClusterBuilder, the builder image is rebuilt.

---

## 6.4 Service Binding Runtime

The Service Binding Specification (servicebinding.io) enables automatic credential injection into app containers. Korifi uses this for `cf bind-service`.

### Installation

```bash
# Service Binding Runtime v0.9.1
kubectl apply -f https://github.com/servicebinding/runtime/releases/download/v0.9.1/servicebinding-runtime-v0.9.1.yaml

# Wait until controller is ready
kubectl wait --for=condition=Ready pods -l control-plane=controller-manager \
  -n servicebinding-system --timeout=120s
```

### Validation

```bash
# Check CRDs
kubectl get crd | grep servicebinding
# clusterworkloadresourcemappings.servicebinding.io
# servicebindings.servicebinding.io
```

---

## 6.5 Deploy Korifi

### Create Namespace

```bash
kubectl create namespace cf
```

### Helm Installation

```bash
# Add Korifi Helm repo
helm repo add korifi https://cloudfoundry.github.io/korifi
helm repo update

# Install Korifi
helm install korifi korifi/korifi \
  --namespace cf \
  --version 0.18.0 \
  --set rootNamespace=cf \
  --set api.apiServer.url=api.app.cfapps.cool \
  --set defaultAppDomainName=app.cfapps.cool \
  --set containerRepositoryPrefix=artifactory.cfapps.cool/docker-local/korifi/ \
  --set networking.gatewayClass=contour \
  --set experimental.managedServices.enabled=true \
  --set kpackImageBuilder.clusterBuilderName=default \
  --set api.authProxy.enabled=false
```

### Activate Contour Gateway API

After the Contour installation, the ConfigMap must be patched so that Contour recognizes the Gateway object created by Korifi. Without this step, the Gateway remains in `Pending` status and the CF API is unreachable.

```bash
# Patch Contour ConfigMap: set Gateway reference to korifi-gateway/korifi
kubectl get configmap contour -n projectcontour -o json | \
  python3 -c "
import json, sys
cm = json.load(sys.stdin)
old = cm['data']['contour.yaml']
new = old.replace(
    '# Specify the Gateway API configuration.\n# gateway:\n#   namespace: projectcontour\n#   name: contour',
    'gateway:\n  gatewayRef:\n    namespace: korifi-gateway\n    name: korifi'
)
cm['data']['contour.yaml'] = new
json.dump(cm, sys.stdout)
" | kubectl apply -f -

# Restart Contour for the change to take effect
kubectl rollout restart deploy/contour -n projectcontour
kubectl rollout status deploy/contour -n projectcontour --timeout=60s
```

If Contour crashes after the restart with `no matches for kind "BackendTLSPolicy" in version "gateway.networking.k8s.io/v1alpha3"`, the CRD version must be enabled as served:

```bash
# Enable BackendTLSPolicy v1alpha3 as served (Contour v1.33.x requires this)
kubectl get crd backendtlspolicies.gateway.networking.k8s.io -o json | \
  python3 -c "
import json, sys
crd = json.load(sys.stdin)
for v in crd['spec']['versions']:
    if v['name'] == 'v1alpha3':
        v['served'] = True
json.dump(crd, sys.stdout)
" | kubectl apply -f -

# Restart Contour again
kubectl rollout restart deploy/contour -n projectcontour
kubectl rollout status deploy/contour -n projectcontour --timeout=60s
```

**Validation:**

```bash
# Gateway must show PROGRAMMED=True and have an ADDRESS
kubectl get gateway korifi -n korifi-gateway
# NAME     CLASS     ADDRESS          PROGRAMMED   AGE
# korifi   contour   192.168.64.203   True         ...

# CF API must be reachable
curl -sk https://api.app.cfapps.cool/v3/info | python3 -m json.tool
```

### Configure Admin User

Korifi uses Kubernetes RBAC for authentication. The `adminUserName` in the Helm configuration references a K8s user (CN in the certificate). Authentication is performed via a client certificate signed by the K8s API server.

#### Step 1: Create Certificate

```bash
# Generate private key
openssl genrsa -out ~/.kube/cf-admin.key 4096

# Create Certificate Signing Request (CSR)
# CN=cf-admin must match adminUserName in the Helm config
openssl req -new -key ~/.kube/cf-admin.key -out /tmp/cf-admin.csr -subj "/CN=cf-admin"
```

#### Step 2: Submit and Approve CSR in Kubernetes

```bash
# Create CSR as K8s resource
CSR_B64=$(cat /tmp/cf-admin.csr | base64 | tr -d '\n')
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: cf-admin
spec:
  request: ${CSR_B64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
  - client auth
EOF

# Approve CSR
kubectl certificate approve cf-admin

# Extract signed certificate
kubectl get csr cf-admin -o jsonpath='{.status.certificate}' | base64 -d > ~/.kube/cf-admin.crt

# Verify certificate
openssl x509 -in ~/.kube/cf-admin.crt -noout -subject -enddate
# subject= /CN=cf-admin
# notAfter=Mar 21 ... 2027 GMT
```

#### Step 3: Create ClusterRoleBinding

The Helm installation only creates a RoleBinding in the `cf` root namespace. For full admin access (creating orgs/spaces, deploying apps), a ClusterRoleBinding is required:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cf-admin-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: korifi-controllers-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: cf-admin
EOF
```

#### Step 4: Merge cf-admin Context into Existing Kubeconfig

Instead of a separate kubeconfig, the `cf-admin` context is integrated into the existing `config-k3s`. This way, a single `export KUBECONFIG=~/.kube/config-k3s` is sufficient.

```bash
# Reuse cluster information from existing kubeconfig
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Create temporary kubeconfig for cf-admin
TMP_CFKUBECONFIG=$(mktemp)

kubectl config set-cluster k3s-cf \
  --server="${CLUSTER_SERVER}" \
  --certificate-authority=<(echo "${CLUSTER_CA}" | base64 -d) \
  --embed-certs=true \
  --kubeconfig="${TMP_CFKUBECONFIG}"

kubectl config set-credentials cf-admin \
  --client-certificate=~/.kube/cf-admin.crt \
  --client-key=~/.kube/cf-admin.key \
  --embed-certs=true \
  --kubeconfig="${TMP_CFKUBECONFIG}"

kubectl config set-context cf-admin \
  --cluster=k3s-cf \
  --user=cf-admin \
  --kubeconfig="${TMP_CFKUBECONFIG}"

# Merge into existing kubeconfig
cp ~/.kube/config-k3s ~/.kube/config-k3s.bak
KUBECONFIG=~/.kube/config-k3s:${TMP_CFKUBECONFIG} \
  kubectl config view --flatten > ~/.kube/config-k3s.merged
mv ~/.kube/config-k3s.merged ~/.kube/config-k3s
rm -f "${TMP_CFKUBECONFIG}"

# Switch back to cluster admin context
kubectl config use-context k3s-devops
```

After the merge, two contexts are available:

```bash
kubectl config get-contexts
# CURRENT   NAME         CLUSTER      AUTHINFO     NAMESPACE
# *         k3s-devops   k3s-devops   k3s-devops            # Cluster Admin
#           cf-admin     k3s-cf       cf-admin               # CF Operations
```

#### Step 5: Validate Permissions

```bash
# cf-admin must be able to manage Korifi resources
kubectl --context=cf-admin auth can-i list cforgs.korifi.cloudfoundry.org --all-namespaces
# yes
```

### Test CF API Login

```bash
# Set API endpoint
cf api https://api.app.cfapps.cool --skip-ssl-validation

# Log in with cf-admin kubeconfig (automatically selects cf-admin credentials)
kubectl config use-context cf-admin
cf login
# Select "1. cf-admin" when prompted

# Alternatively, non-interactive (for scripts):
echo "1" | kubectl config use-context cf-admin
cf login

# Create first org and space
cf create-org dev
cf target -o dev
cf create-space test
cf target -s test
```

### Validation

```bash
# Check Korifi pods
kubectl get pods -n cf
# korifi-api-xxx                Running
# korifi-controllers-xxx        Running
# korifi-kpack-image-builder-xxx Running
# korifi-statefulset-runner-xxx Running
# korifi-job-task-runner-xxx    Running

# Check CRDs
kubectl get crd | grep korifi
# cfapps.korifi.cloudfoundry.org
# cfbuilds.korifi.cloudfoundry.org
# cfdomains.korifi.cloudfoundry.org
# cforgs.korifi.cloudfoundry.org
# cfpackages.korifi.cloudfoundry.org
# cfprocesses.korifi.cloudfoundry.org
# cfroutes.korifi.cloudfoundry.org
# cfspaces.korifi.cloudfoundry.org

# Is the API reachable?
curl -k https://api.app.cfapps.cool/v3/info
# {"build":"","cli_version":{"minimum":"","recommended":""},...}
```

---

## 6.6 Test cf push

### Create Org and Space

```bash
# Set API and log in
cf api https://api.app.cfapps.cool --skip-ssl-validation
cf auth "$CF_ADMIN_TOKEN"

# Create organization
cf create-org dev
cf target -o dev

# Create space
cf target -o dev
cf create-space test
cf target -s test
```

### Sample App (Go)

```bash
# Create directory
mkdir -p /tmp/cf-test-app && cd /tmp/cf-test-app

# main.go
cat > main.go << 'GOEOF'
package main

import (
    "fmt"
    "log"
    "net/http"
    "os"
)

func main() {
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }

    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprintf(w, "Hallo von Cloud Foundry auf K8s! (Korifi v0.18.0)\n")
    })

    log.Printf("Starte Server auf Port %s...\n", port)
    log.Fatal(http.ListenAndServe(":"+port, nil))
}
GOEOF

# go.mod
cat > go.mod << 'MODEOF'
module cf-test-app

go 1.22
MODEOF
```

### Deploy App

```bash
cf push my-test-app

# Observe output:
# Staging app...
# Build created...
# Waiting for build to stage...
# App started!
# routes: my-test-app.app.cfapps.cool
```

> **Note:** The first build takes significantly longer under QEMU emulation (5-10 minutes), as buildpack layers are downloaded and AMD64 binaries are emulated. Subsequent builds are faster thanks to layer caching.

### Test App

```bash
# Access app
curl -k https://my-test-app.app.cfapps.cool
# Hallo von Cloud Foundry auf K8s! (Korifi v0.18.0)

# Check app status
cf apps
# name           requested state   processes   routes
# my-test-app    started           web:1/1     my-test-app.app.cfapps.cool

# View logs
cf logs my-test-app --recent

# Scale app
cf scale my-test-app -i 2
```

---

## 6.7 Provisioning Services

### Strategy

For a single-node dev setup, the simplest strategy is recommended:

**K8s Operators + User-Provided Services (UPS)**

1. Service (PostgreSQL, Redis, RabbitMQ) is deployed via K8s operator
2. Credentials are registered as a User-Provided Service in CF
3. `cf bind-service` injects the credentials into the app via Service Binding

This strategy is the simplest and most reliable. OSBAPI-based managed services are experimental and too complex for single-node dev setups (see section "Future: OSBAPI").

---

### PostgreSQL (CloudNativePG Operator)

CloudNativePG is the recommended PostgreSQL operator for Kubernetes and is fully ARM64-compatible.

#### Install Operator

```bash
# Namespace
kubectl create namespace cnpg-system

# Helm installation
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --version 0.23.0
```

#### Create PostgreSQL Cluster

```yaml
# postgres-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cf-postgres
  namespace: cf-services
spec:
  instances: 1
  storage:
    size: 5Gi
  postgresql:
    parameters:
      max_connections: "100"
      shared_buffers: "128MB"
  bootstrap:
    initdb:
      database: myapp
      owner: myapp
      secret:
        name: cf-postgres-credentials
---
apiVersion: v1
kind: Secret
metadata:
  name: cf-postgres-credentials
  namespace: cf-services
type: kubernetes.io/basic-auth
stringData:
  username: myapp
  password: changeme-use-openbao
```

```bash
kubectl create namespace cf-services
kubectl apply -f postgres-cluster.yaml

# Wait until cluster is ready
kubectl wait --for=condition=Ready cluster/cf-postgres -n cf-services --timeout=300s

# Determine connection string
PG_HOST=$(kubectl get svc cf-postgres-rw -n cf-services -o jsonpath='{.spec.clusterIP}')
echo "postgres://myapp:changeme-use-openbao@${PG_HOST}:5432/myapp"
```

#### Create User-Provided Service

```bash
cf create-user-provided-service my-pg \
  -p "{\"uri\":\"postgres://myapp:changeme-use-openbao@${PG_HOST}:5432/myapp\"}"

# Bind to app
cf bind-service my-test-app my-pg

# Restage app for bindings to take effect
cf restage my-test-app

# Check bindings
cf env my-test-app
# VCAP_SERVICES contains the PostgreSQL credentials
```

---

### Redis/Valkey

For a single-node setup, a simple Bitnami Redis Helm chart is recommended (no cluster mode).

#### Installation

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install redis bitnami/redis \
  --namespace cf-services \
  --set architecture=standalone \
  --set auth.password=changeme-use-openbao \
  --set master.persistence.size=2Gi \
  --set master.resources.requests.memory=128Mi \
  --set master.resources.limits.memory=256Mi
```

#### Create User-Provided Service

```bash
REDIS_HOST=$(kubectl get svc redis-master -n cf-services -o jsonpath='{.spec.clusterIP}')

cf create-user-provided-service my-redis \
  -p "{\"uri\":\"redis://:changeme-use-openbao@${REDIS_HOST}:6379\"}"

# Bind to app
cf bind-service my-test-app my-redis
cf restage my-test-app
```

---

### RabbitMQ

The official RabbitMQ Cluster Operator (from VMware/Broadcom) enables declarative RabbitMQ clusters via Custom Resources.

#### Install Operator

```bash
# RabbitMQ Cluster Operator
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

# Wait until operator is ready
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/component=rabbitmq-operator \
  -n rabbitmq-system --timeout=120s
```

#### Create RabbitMQ Cluster

```yaml
# rabbitmq-cluster.yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: cf-rabbitmq
  namespace: cf-services
spec:
  replicas: 1
  resources:
    requests:
      memory: 256Mi
    limits:
      memory: 512Mi
  persistence:
    storageClassName: local-path
    storage: 2Gi
  rabbitmq:
    additionalConfig: |
      default_user = myapp
      default_pass = changeme-use-openbao
```

```bash
kubectl apply -f rabbitmq-cluster.yaml

# Wait until cluster is ready
kubectl wait --for=condition=Ready rabbitmqcluster/cf-rabbitmq \
  -n cf-services --timeout=300s

# Determine connection string
RABBIT_HOST=$(kubectl get svc cf-rabbitmq -n cf-services -o jsonpath='{.spec.clusterIP}')
echo "amqp://myapp:changeme-use-openbao@${RABBIT_HOST}:5672"
```

#### Create User-Provided Service

```bash
cf create-user-provided-service my-rabbitmq \
  -p "{\"uri\":\"amqp://myapp:changeme-use-openbao@${RABBIT_HOST}:5672\"}"

# Bind to app
cf bind-service my-test-app my-rabbitmq
cf restage my-test-app
```

---

### Future: OSBAPI (Open Service Broker API)

Korifi experimentally supports managed services via the Open Service Broker API. This enables `cf marketplace` and `cf create-service` instead of manual User-Provided Services.

**Activation:**

```yaml
# Already activated in the Korifi Helm installation:
experimental:
  managedServices:
    enabled: true
```

**Prerequisites for OSBAPI:**

- An OSBAPI-compatible service broker must be deployed
- Crossplane could serve as a broker backend (provisions K8s-native resources)
- The broker must be registered with Korifi: `cf create-service-broker`

**Assessment for Single-Node Dev:**

Currently too complex. The combination of Crossplane + OSBAPI adapter + provider configuration requires significant effort for little added value in a dev context. User-Provided Services are the more pragmatic solution.

Once the Crossplane OSBAPI ecosystem has stabilized, this can be added in a future iteration.

---

## Validation

The following items must be verified after installation:

- [ ] `cf api https://api.app.cfapps.cool --skip-ssl-validation` -- API reachable
- [ ] `cf auth "$CF_ADMIN_TOKEN"` -- Login works
- [ ] `cf create-org dev && cf create-space test` -- Org/Space can be created
- [ ] `cf push my-test-app` -- Build and deploy successful
- [ ] `curl -k https://my-test-app.app.cfapps.cool` -- App reachable under wildcard domain
- [ ] `cf create-user-provided-service my-pg -p '{"uri":"..."}'` -- UPS can be created
- [ ] `cf bind-service my-test-app my-pg` -- Binding injects credentials into VCAP_SERVICES
- [ ] `cf logs my-test-app --recent` -- Logs are retrievable
- [ ] `cf scale my-test-app -i 2` -- Scaling works

---

## Web UI / Dashboard

### Stratos (Not Compatible)

[Stratos](https://github.com/cloudfoundry/stratos) is the classic Cloud Foundry web UI. However, it is **not compatible with Korifi:**

- Stratos makes extensive use of the **CF V2 API**, which Korifi does not implement
- Even the V3 API coverage of Stratos and Korifi only partially overlaps
- The result would be a largely broken UI with many missing features

**ARM64 images** are now available via GHCR (`ghcr.io/cloudfoundry/stratos-ui`, `ghcr.io/cloudfoundry/stratos-backend`), but the incompatibility with Korifi renders deployment pointless.

### Recommended Tools

For a Korifi-based setup, the following tools are the right choice:

| Tool          | Purpose                                                | Status          |
|---------------|--------------------------------------------------------|-----------------|
| `cf` CLI      | Primary developer interface (cf push, cf apps)         | Installed       |
| Portainer     | Visualize K8s resources (apps = StatefulSets)          | Already deployed |
| Grafana       | Monitoring dashboards for CF apps and builds           | Already deployed |
| `kubectl`/k9s | Cluster-level debugging and troubleshooting            | Available       |

> **Note:** Once Korifi reaches 1.0 and the V3 API is fully implemented, Stratos or a dedicated Korifi UI project could become an option. As of v0.18.0, no compatible web UI exists.

---

## Known Limitations

| Limitation                              | Details                                                         |
|-----------------------------------------|-----------------------------------------------------------------|
| **Beta Software**                       | Korifi CRDs may change between versions. Upgrades require CRD migrations. |
| **Not all cf commands implemented**     | See [Korifi Known Differences](https://github.com/cloudfoundry/korifi/blob/main/docs/known-differences.md). Missing commands: `cf ssh`, `cf marketplace` (without OSBAPI), `cf service-keys`. |
| **Builds slow on ARM64**               | QEMU emulation slows builds by a factor of 5-10x. First build is especially slow due to missing layer caches. |
| **No cf marketplace**                  | Without an OSBAPI broker, `cf marketplace` is empty. User-Provided Services as workaround. |
| **Container registry required**        | kpack must push built images to a registry. Artifactory must be reachable and configured. |
| **Separate Gateway**                   | Korifi creates its own Contour Gateway -- do not mix with Traefik IngressRoutes. CF apps run on `*.app.cfapps.cool`, all other services continue on `*.development.cfapps.cool`. |
| **No rolling deployment**              | Korifi uses StatefulSets, not blue-green or rolling updates like PCF/TAS. |
| **No buildpack caching**              | Under QEMU, buildpack caching may have limited functionality. |

---

## Resources

**Additional Memory Requirements (beyond Phase 1-3):**

| Component               | RAM           | Note                                       |
|-------------------------|---------------|--------------------------------------------|
| Contour (Envoy + ctrl) | ~200Mi        | Gateway API Controller                     |
| kpack Controller        | ~100Mi        | Build orchestration                        |
| Korifi (all pods)       | ~500Mi-700Mi  | API, Controllers, Builder, Runner          |
| Service Binding Runtime | ~50Mi         | Credential injection                       |
| **Total Overhead**      | **~850Mi-1Gi**| Without apps and services                  |
| Each CF App (default)   | ~1Gi          | Configurable via `cf scale -m`             |
| Build (temporary)       | ~2Gi          | During active kpack build                  |
| CloudNativePG           | ~256Mi        | PostgreSQL operator + instance             |
| Redis                   | ~128-256Mi    | Standalone instance                        |
| RabbitMQ                | ~256-512Mi    | Single-node cluster                        |

**Recommended free RAM:** At least 4Gi free before starting Phase 6.

---

## References

- Korifi Repository: <https://github.com/cloudfoundry/korifi>
- Korifi Documentation: <https://www.cloudfoundry.org/technology/korifi/>
- Cloud Native Buildpacks: <https://buildpacks.io/docs/>
- Paketo Buildpacks: <https://paketo.io/>
- Heroku Builder (multi-arch): <https://github.com/heroku/builder>
- kpack: <https://github.com/buildpacks-community/kpack>
- Contour: <https://projectcontour.io/>
- CloudNativePG: <https://cloudnative-pg.io/>
- RabbitMQ Cluster Operator: <https://www.rabbitmq.com/kubernetes/operator/operator-overview>
- Service Binding Spec: <https://servicebinding.io/>
- Gateway API: <https://gateway-api.sigs.k8s.io/>
