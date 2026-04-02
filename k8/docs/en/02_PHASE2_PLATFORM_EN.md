# Phase 2: Platform

## Overview

Phase 2 deploys the core platform services that serve as the foundation for the entire stack:

- **ArgoCD** - GitOps Continuous Delivery
- **Portainer** - Kubernetes Management UI
- **Garage** - S3-compatible Object Storage (backend for Loki, Mimir, Tempo, Velero)
- **S3 Manager** - Web UI for bucket and file management
- **Technitium DNS** - Internal DNS server with Web UI
- **Velero** - Backup and Restore

**Prerequisite:** Phase 1 (Foundation) must be fully completed. This means: Lima VM is running, K3s is installed, OpenBao + ESO are configured, MetalLB + Traefik + cert-manager are deployed.

---

## 2.1 ArgoCD

ArgoCD is used as the GitOps controller and manages all subsequent deployments in the cluster.

### Helm Installation

ArgoCD uses the official `argo-cd` Helm Chart (version 9.4.15) with ArgoCD v3.3.4.

```bash
# Create namespace
kubectl create namespace argocd

# Fetch Helm dependencies
cd k8/platform/argocd
helm dependency build

# Install
helm install argocd . -n argocd -f values.yaml
```

**Chart configuration** (`Chart.yaml`):
- Chart: `argo-cd` version `9.4.15`
- Repository: `https://argoproj.github.io/argo-helm`

**Key values.yaml settings:**
- `server.insecure: "true"` - TLS termination is handled by Traefik, not by ArgoCD itself
- `dex.enabled: false` - No SSO/OIDC, local admin login only
- Images are pulled from the local Artifactory registry (`artifactory.cfapps.cool/docker-local/...`)
- Service type: `ClusterIP` (access only via IngressRoute)

### Redis Sub-Image

ArgoCD requires Redis as a cache. The Redis image (`redis:8.2.3-alpine-arm64`) must be imported separately into the Artifactory registry, as it is not bundled with the ArgoCD image:

```bash
# Import Redis image for ARM64 into Artifactory
docker pull redis:8.2.3-alpine
docker tag redis:8.2.3-alpine artifactory.cfapps.cool/docker-local/library/redis:8.2.3-alpine-arm64
docker push artifactory.cfapps.cool/docker-local/library/redis:8.2.3-alpine-arm64
```

### IngressRoute

The IngressRoute makes ArgoCD accessible at `argocd.development.cfapps.cool`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`argocd.development.cfapps.cool`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
  tls: {}
```

```bash
kubectl apply -f ingressroute.yaml
```

### Retrieving the Admin Password

The initial admin password is automatically generated and stored in a Secret:

```bash
# Retrieve admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

# Login via CLI
argocd login argocd.development.cfapps.cool --username admin --password <PASSWORD>

# Change password (recommended)
argocd account update-password
```

### App-of-Apps Pattern

ArgoCD uses the App-of-Apps pattern. A root Application watches the `platform/argocd/applications/` directory and automatically creates all Application manifests defined therein:

```yaml
# platform/argocd/applications/root.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "<GIT_REPO_URL>"
    targetRevision: main
    path: platform/argocd/applications
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

```bash
# Deploy root Application
kubectl apply -f platform/argocd/applications/root.yaml
```

The `syncPolicy` with `prune: true` and `selfHeal: true` ensures that:
- Resources no longer present in Git are automatically deleted
- Manually modified resources are automatically reverted to the Git state

---

## 2.2 Portainer

Portainer CE provides a Web UI for managing the Kubernetes cluster.

### Helm Installation

Portainer uses the official Helm Chart (version 239.0.2) with Portainer CE v2.39.0.

```bash
# Create namespace
kubectl create namespace portainer

# Fetch Helm dependencies
cd k8/platform/portainer
helm dependency build

# Install
helm install portainer . -n portainer -f values.yaml
```

**Key values.yaml settings:**
- Service type: `ClusterIP`
- TLS force disabled (`tls.force: false`) - TLS is terminated by Traefik
- Persistent storage: 1Gi on `local-path` StorageClass
- Image: `portainer-ce:2.39.0-arm64` from Artifactory

### IngressRoute

Portainer is accessible at `portainer.development.cfapps.cool`. The IngressRoute must be created manually:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: portainer
  namespace: portainer
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`portainer.development.cfapps.cool`)
      kind: Rule
      services:
        - name: portainer
          port: 9000
  tls: {}
```

```bash
kubectl apply -f ingressroute.yaml
```

### IMPORTANT: Security Timeout

Portainer has a built-in security mechanism: the admin password **must be set within 5 minutes** of the first start. After that, Portainer locks itself for security reasons and must be restarted.

```bash
# Open in the browser immediately after deployment:
# https://portainer.development.cfapps.cool

# If the timeout has expired, restart the pod:
kubectl -n portainer rollout restart deployment portainer
# Then immediately set the password in the browser!
```

---

## 2.3 Garage (S3 Object Storage)

Garage is a lightweight, S3-compatible object storage. It serves as the backend for Velero, Loki, Mimir, Tempo, and artifact-keeper.

### Kustomize Deployment

Garage is deployed not via Helm but via Kustomize as a StatefulSet.

```bash
# Create namespace
kubectl create namespace garage

# Apply all manifests
kubectl apply -k k8/platform/garage/
```

The StatefulSet creates two PersistentVolumeClaims:
- `garage-data` (100Gi) - Actual object data
- `garage-meta` (1Gi) - Metadata (LMDB database)

### garage.toml Configuration

The configuration is provided via a ConfigMap:

```toml
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "lmdb"

replication_factor = 1
rpc_bind_addr = "[::]:3901"
rpc_secret = "<RPC_SECRET>"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"
root_domain = ".s3.development.cfapps.cool"

[s3_web]
bind_addr = "[::]:3902"
root_domain = ".web.development.cfapps.cool"

[admin]
api_bind_addr = "[::]:3903"
```

**Important parameters:**
- `replication_factor = 1` - Single-node setup, no replication
- `rpc_secret` - Must be a random 32-byte hex string
- S3 API on port 3900, Admin API on port 3903

```bash
# Generate RPC secret (for reconfiguration)
openssl rand -hex 32
```

### Configuring the Node Layout

After the first start, the node layout must be configured. This assigns a capacity and zone to the Garage node:

```bash
# Determine pod name
GARAGE_POD=$(kubectl -n garage get pod -l app.kubernetes.io/name=garage -o jsonpath='{.items[0].metadata.name}')

# Display node ID
kubectl -n garage exec $GARAGE_POD -- garage status

# Assign layout (use the node ID from the previous command)
kubectl -n garage exec $GARAGE_POD -- garage layout assign <NODE_ID> \
  --zone default \
  --capacity 100GB \
  --tags k3s-node

# Apply layout
kubectl -n garage exec $GARAGE_POD -- garage layout apply --version 1
```

**Note:** The node layout persists across restarts and does not need to be reconfigured.

### Creating Buckets

The following buckets are required for the stack:

```bash
# Create buckets
for BUCKET in velero-backups loki-chunks mimir-blocks tempo-traces artifacts; do
  kubectl -n garage exec $GARAGE_POD -- garage bucket create $BUCKET
  echo "Bucket '$BUCKET' created"
done
```

### Creating API Keys and Storing Them in OpenBao

A separate API key with access to the respective bucket is created for each service:

```bash
# Example: Create API key for Velero
kubectl -n garage exec $GARAGE_POD -- garage key create velero-service-key

# Display key information (note the Access Key ID and Secret Access Key)
kubectl -n garage exec $GARAGE_POD -- garage key info velero-service-key

# Set bucket permissions (read + write)
kubectl -n garage exec $GARAGE_POD -- garage bucket allow velero-backups \
  --read --write --key velero-service-key

# Same procedure for all services:
for SVC_BUCKET in "loki-svc-key:loki-chunks" "mimir-svc-key:mimir-blocks" "tempo-svc-key:tempo-traces" "artifacts-svc-key:artifacts"; do
  KEY_NAME="${SVC_BUCKET%%:*}"
  BUCKET_NAME="${SVC_BUCKET##*:}"
  kubectl -n garage exec $GARAGE_POD -- garage key create $KEY_NAME
  kubectl -n garage exec $GARAGE_POD -- garage bucket allow $BUCKET_NAME \
    --read --write --key $KEY_NAME
done

# Create admin key for S3 Manager (access to all buckets)
kubectl -n garage exec $GARAGE_POD -- garage key create admin-key
for BUCKET in velero-backups loki-chunks mimir-blocks tempo-traces artifacts; do
  kubectl -n garage exec $GARAGE_POD -- garage bucket allow $BUCKET \
    --read --write --owner --key admin-key
done
```

**Storing credentials in OpenBao:**

```bash
# Example: Store Velero S3 credentials in OpenBao
bao kv put secret/velero/s3-credentials \
  ACCESS_KEY_ID="<ACCESS_KEY>" \
  SECRET_ACCESS_KEY="<SECRET_KEY>"

# Admin key for S3 Manager
bao kv put secret/garage/admin-s3-credentials \
  ACCESS_KEY_ID="<ADMIN_ACCESS_KEY>" \
  SECRET_ACCESS_KEY="<ADMIN_SECRET_KEY>"
```

### IngressRoutes

Garage exposes two endpoints:

| URL | Port | Purpose |
|-----|------|---------|
| `s3.development.cfapps.cool` | 3900 | S3 API endpoint |
| `garage.development.cfapps.cool` | 3902 | Web interface |

```bash
kubectl apply -f k8/platform/garage/ingressroute.yaml
```

---

## 2.4 S3 Manager

The S3 Manager (cloudlena/s3manager) provides a Web UI for managing buckets and files in Garage.

### Kustomize Deployment

```bash
kubectl apply -k k8/platform/garage/s3-manager/
```

**Configuration:**
- Connects internally to Garage via `garage.garage.svc:3900`
- Uses the admin API key from the Secret `garage-admin-s3-credentials`
- SSL is disabled (internal communication)
- Object deletion is enabled (`ALLOW_DELETE: "true"`)
- Region: `garage`

### IngressRoute

Accessible at `s3-manager.development.cfapps.cool`:

```bash
kubectl apply -f k8/platform/garage/s3-manager/ingressroute.yaml
```

---

## 2.5 Technitium DNS

Technitium DNS provides an internal DNS server with a Web UI.

### Kustomize Deployment

```bash
# Create namespace
kubectl create namespace technitium

# Apply deployment
kubectl apply -k k8/platform/technitium/
```

Technitium is deployed as a Deployment with `strategy: Recreate` (no rolling update, as DNS data can only be used by a single instance at a time). Data is persisted in a PVC `technitium-data` under `/etc/dns`.

### LoadBalancer Service for DNS

DNS queries (port 53) are served via a LoadBalancer Service with a fixed MetalLB IP:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: technitium-dns
  annotations:
    metallb.universe.tf/loadBalancerIPs: "192.168.64.201"
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: technitium
  ports:
    - name: dns-tcp
      port: 53
      targetPort: dns-tcp
      protocol: TCP
    - name: dns-udp
      port: 53
      targetPort: dns-udp
      protocol: UDP
```

The fixed IP `192.168.64.201` is assigned via the MetalLB annotation. This makes the DNS server reachable from the Lima network at this IP.

```bash
# Test DNS resolution
dig @192.168.64.201 google.com
```

### Web UI IngressRoute

The Technitium Web UI (port 5380) is accessible via a separate ClusterIP Service and an IngressRoute at `dns.development.cfapps.cool`:

```bash
kubectl apply -f k8/platform/technitium/ingressroute.yaml
```

---

## 2.6 Velero

Velero backs up Kubernetes resources and PersistentVolumes to Garage S3.

### Helm Installation

Velero uses the official Helm Chart (version 12.0.0) with Velero v1.18.0.

```bash
# Create namespace
kubectl create namespace velero

# Fetch Helm dependencies
cd k8/velero
helm dependency build

# Install
helm install velero . -n velero -f values.yaml
```

**Key values.yaml settings:**
- `snapshotsEnabled: false` - No CSI Volume Snapshots (local-path-provisioner does not support this)
- `defaultVolumesToFsBackup: true` - All volumes are backed up via filesystem backup (Kopia/Restic)
- `deployNodeAgent: true` - Node Agent for fsBackup is deployed as a DaemonSet
- AWS S3 Plugin (`velero-plugin-for-aws:v1.14.0-arm64`) as InitContainer

### S3 Credentials via ExternalSecret

The S3 credentials are loaded from OpenBao via an ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: velero-s3-credentials
  namespace: velero
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: velero-s3-credentials
  data:
    - secretKey: cloud
      remoteRef:
        key: secret/velero/s3-credentials
        property: credentials-file
```

The resulting Secret is referenced in the Velero values.yaml as `credentials.existingSecret: velero-s3-credentials`.

### BackupStorageLocation

The BackupStorageLocation points to the `velero-backups` bucket in Garage:

```yaml
backupStorageLocation:
  - name: garage
    provider: aws
    bucket: velero-backups
    config:
      region: garage
      s3ForcePathStyle: "true"
      s3Url: http://garage.garage.svc:3900
```

- `s3ForcePathStyle: "true"` is required because Garage expects path-style URLs (not virtual-hosted-style)
- The internal service endpoint `garage.garage.svc:3900` is used

### Daily Backup Schedule

A daily backup schedule backs up all namespaces at 02:00 UTC:

```bash
# Create schedule
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --ttl 168h \
  --default-volumes-to-fs-backup

# Verify schedule
velero schedule get

# Trigger a manual backup (for testing)
velero backup create manual-test-backup \
  --default-volumes-to-fs-backup

# Check backup status
velero backup get
velero backup describe manual-test-backup --details
```

**Parameters:**
- `--schedule="0 2 * * *"` - Daily at 02:00 UTC
- `--ttl 168h` - Backups are automatically deleted after 7 days
- `--default-volumes-to-fs-backup` - PVs are backed up via filesystem backup

---

## Important Notes

### IngressRoutes and TLS

All IngressRoutes use `tls: {}` without further configuration. This uses the default TLSStore, which was configured by cert-manager with the Let's Encrypt wildcard certificate for `*.development.cfapps.cool`. Example:

```yaml
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`<service>.development.cfapps.cool`)
      kind: Rule
      services:
        - name: <service>
          port: <port>
  tls: {}    # Uses the default TLSStore with wildcard certificate
```

### Portainer Security Timeout

Portainer locks admin registration after 5 minutes. If the pod is restarted without prior registration, the pod must be restarted again:

```bash
kubectl -n portainer rollout restart deployment portainer
```

### Garage Node Layout

The node layout is persisted in the Garage metadata. After a pod or cluster restart, the layout does **not** need to be reconfigured. Reconfiguration is only necessary when:
- A new node is added to the cluster
- The capacity of an existing node needs to be changed
- A node is removed

### Image Registry

All container images are pulled from the local Artifactory registry (`artifactory.cfapps.cool/docker-local/...`). The pull secret `artifact-keeper-pull` must be present in every namespace:

```bash
# Copy pull secret to a new namespace (example)
kubectl get secret artifact-keeper-pull -n default -o yaml \
  | sed 's/namespace: default/namespace: <NEW_NAMESPACE>/' \
  | kubectl apply -f -
```

### Overview of All URLs (Phase 2)

| Service | URL | Purpose |
|---------|-----|---------|
| ArgoCD | `https://argocd.development.cfapps.cool` | GitOps UI |
| Portainer | `https://portainer.development.cfapps.cool` | Cluster Management UI |
| Garage S3 API | `https://s3.development.cfapps.cool` | S3-compatible endpoint |
| Garage Web | `https://garage.development.cfapps.cool` | Garage Web interface |
| S3 Manager | `https://s3-manager.development.cfapps.cool` | Bucket/File Management UI |
| Technitium DNS | `https://dns.development.cfapps.cool` | DNS Management Web UI |
| Technitium DNS | `192.168.64.201:53` | DNS resolution (TCP/UDP) |
