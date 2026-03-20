# K8s DevOps Stack - Design Specification

## Overview

A Kubernetes-based DevOps environment running on Apple Silicon Macs (M4+, 64GB+) using K3s in a Lima VM. Designed as a single-node cluster with multi-node expansion capability. All configuration is Git-managed for full reproducibility and disaster recovery.

## Goals

- Replace existing Docker Compose stacks (Vault, artifact-keeper, OTEL) with a unified K8s platform
- GitOps-driven deployment via ArgoCD
- Wildcard TLS via Let's Encrypt with DNS-01 challenge (Google Cloud DNS + Route53)
- Graphical cluster management via Portainer
- Secret management via OpenBao + External Secrets Operator
- Local S3-compatible storage via Garage
- Full disaster recovery: restore on a replacement Mac in under 1 hour
- Master script for start/stop lifecycle management

## Architecture

### Virtualization Layer

- **Lima** with Apple Virtualization.framework (native ARM64, no QEMU overhead)
- VM: Ubuntu 24.04 ARM64
- Resources: 8+ cores, 48GB+ RAM, 200GB+ disk
- **Networking: `vzNAT` with shared network** (`socket_vmnet`) so the VM gets a routable IP on the host network. Required for MetalLB L2 mode to work (ARP announcements must reach the host LAN). Default Lima slirp/gvproxy networking will NOT work with MetalLB.
- Port forwarding: 80, 443 from host/router to VM's bridged IP
- kubeconfig exported to host `~/.kube/config`

### K3s Configuration

- Distribution: K3s (Rancher/SUSE), CNCF-certified
- Flags:
  - `--disable servicelb` (MetalLB replaces Klipper)
  - `--disable traefik` (Traefik deployed separately via Helm for version control)
  - `--write-kubeconfig-mode 644`
  - `--tls-san <external-ip/hostname>`
- Multi-node expansion: additional Lima VMs or physical Macs join via `k3s agent --server https://<server>:6443 --token <node-token>`

### Networking & Ingress

- **MetalLB** (L2 mode): assigns LoadBalancer IPs from a local pool (e.g., 192.168.x.200-210)
- **Traefik** Ingress Controller: deployed via Helm, receives LoadBalancer IP from MetalLB
  - SSL termination via cert-manager secrets
  - IngressRoute CRDs for routing
  - Middlewares: redirect-https, rate-limit, basic-auth
  - Traefik Dashboard exposed
- **cert-manager**: ClusterIssuer with DNS-01 challenge
  - Solver 1: Google Cloud DNS (`*.development.cfapps.cool`)
  - Solver 2: AWS Route53 (additional zones)
  - Wildcard certificate: `*.development.cfapps.cool`
  - Auto-renewal 30 days before expiry

### Namespace Structure

```
system/
├── metallb-system         MetalLB
├── traefik                Traefik Ingress + Dashboard
├── cert-manager           Certificate management
└── kube-system            K3s core components

platform/
├── argocd                 GitOps controller + Web-UI
├── portainer              Cluster management UI
├── garage                 S3-compatible object storage
├── technitium             Internal DNS server + Web-UI
└── external-secrets       ESO Operator + OpenBao ClusterSecretStore

monitoring/
├── grafana                Dashboards
├── loki                   Log aggregation
├── mimir                  Metrics (Prometheus-compatible)
└── tempo                  Distributed tracing

services/
├── openbao                Secret management + K8s auth
├── artifact-keeper        Artifact registry
│   ├── postgresql           Metadata storage
│   ├── meilisearch          Full-text search
│   └── S3 backend → Garage
└── gitlab-ce              GitLab CE (Phase 5, later)

backup/
└── velero                 Cluster backup + PV file-level backup

apps/                      Future application workloads
```

### Storage

#### Persistent Volumes
- **local-path-provisioner** (K3s built-in), StorageClass: `local-path`
- PV base path: `/data/persistent/<namespace>/<pvc-name>`
- Users: PostgreSQL, Meilisearch, OpenBao, Technitium, Grafana, Portainer

#### Object Storage (Garage)
- S3-compatible, written in Rust, lightweight
- Buckets:
  - `velero-backups` - cluster state + PV snapshots
  - `loki-chunks` - log data
  - `mimir-blocks` - metrics
  - `tempo-traces` - traces
  - `artifacts` - artifact-keeper S3 backend
- Multi-node capable when scaling out

### Secret Management

- **OpenBao** as central secret store (replaces Bitnami Sealed Secrets)
- **External Secrets Operator (ESO)** syncs OpenBao secrets into K8s secrets
- ArgoCD stores only secret references in Git, actual values come from OpenBao
- OpenBao unseal keys stored in password manager / secure offline backup

#### Bootstrap Secrets Strategy (Chicken-and-Egg)

During initial bootstrap, some secrets are needed before OpenBao/ESO are running (e.g., DNS provider credentials for cert-manager). Strategy:

1. **Phase 1:** Deploy OpenBao early (before cert-manager ClusterIssuers). OpenBao is a foundational service, not an application service.
2. **Phase 1:** Deploy ESO immediately after OpenBao. Configure `ClusterSecretStore` pointing to OpenBao.
3. **Phase 1:** Store DNS provider credentials (GCP service account, AWS access keys) in OpenBao manually via CLI/UI during bootstrap.
4. **Phase 1:** cert-manager ClusterIssuers reference K8s Secrets that ESO syncs from OpenBao.
5. **bootstrap.sh** includes an interactive step to seed initial secrets into OpenBao before proceeding.

### Internal DNS

- **Technitium DNS** deployed in cluster
- Authoritative for internal development zones (e.g., `*.dev.internal`)
- Conditional forwarding for external domains
- Built-in Web-UI for zone management
- REST API for automation
- Endpoint: `dns.development.cfapps.cool`

### Backup & Disaster Recovery

#### Layer 1: Git (declarative)
- All Helm values, Kustomize overlays, manifests
- ArgoCD Application definitions
- cert-manager Issuer/Certificate manifests
- Lima VM config (`lima.yaml`)
- Bootstrap scripts
- Secrets: NOT in Git (→ OpenBao)

#### Layer 2: Velero → Garage (S3)
- Cluster state (all namespaces)
- PV file-level backups via **Restic/Kopia** (local-path-provisioner does not support CSI snapshots)
- Schedule: daily, 7-day retention
- On-demand before upgrades
- **Dependency:** Garage must be operational before Velero can be deployed

#### Layer 3: Garage replication (optional)
- Bucket sync → external S3 (GCS/AWS) for off-site disaster recovery

#### Restore Procedure
1. `git clone k8/` → `bootstrap.sh` (Lima VM + K3s + ArgoCD)
2. OpenBao deploy + unseal (keys from password manager)
3. ArgoCD syncs all apps from Git (declarative state)
4. ESO pulls secrets from OpenBao → pods start
5. Velero restore → restores PV data from Garage/S3
- Target: full restore in under 1 hour

### Master Script (`stack.sh`)

```
stack.sh start      # Start Lima VM → K3s boots → pods come up → health check → print endpoints
stack.sh stop       # Optional backup → graceful VM shutdown
stack.sh status     # VM status, node status, pod health, endpoint list
stack.sh restart    # stop + start
stack.sh backup     # On-demand Velero backup
```

**Start flow:**
1. `limactl start k3s-server`
2. Wait for K3s API server ready
3. Export/update kubeconfig
4. Health check: ArgoCD apps synced, core pods running
5. Print status with all endpoints

**Stop flow:**
1. Optional: trigger Velero backup
2. `limactl stop k3s-server` (graceful shutdown)

### Endpoints

| Service | URL |
|---------|-----|
| ArgoCD | `argocd.development.cfapps.cool` |
| Portainer | `portainer.development.cfapps.cool` |
| Grafana | `grafana.development.cfapps.cool` |
| OpenBao | `vault.development.cfapps.cool` |
| artifact-keeper | `artifacts.development.cfapps.cool` |
| Garage | `s3.development.cfapps.cool` |
| Technitium DNS | `dns.development.cfapps.cool` |
| Traefik Dashboard | `traefik.development.cfapps.cool` |
| GitLab CE | `gitlab.development.cfapps.cool` (Phase 5) |

## Repository Structure

```
k8/
├── README.md
├── stack.sh                       # Master start/stop/status script
├── bootstrap/
│   ├── lima.yaml                  # Lima VM definition
│   ├── install-k3s.sh             # K3s installation + config
│   └── bootstrap.sh               # Full bootstrap (VM + K3s + ArgoCD)
│
├── infrastructure/
│   ├── metallb/
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── traefik/
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   └── cert-manager/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── clusterissuer.yaml
│
├── platform/
│   ├── argocd/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── applications/
│   │       ├── infrastructure.yaml
│   │       ├── platform.yaml
│   │       ├── monitoring.yaml
│   │       └── services.yaml
│   ├── portainer/
│   ├── garage/
│   ├── technitium/
│   └── external-secrets/
│
├── monitoring/
│   ├── grafana/
│   ├── loki/
│   ├── mimir/
│   └── tempo/
│
├── services/
│   ├── openbao/
│   ├── artifact-keeper/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── dependencies/
│   └── gitlab-ce/
│
├── apps/
│
└── velero/
    ├── Chart.yaml
    ├── values.yaml
    └── schedules/
        └── daily-backup.yaml
```

## Resource Budget (estimated, single-node 48GB VM)

| Service | Memory Request | Memory Limit | Notes |
|---------|---------------|-------------|-------|
| K3s system | 1 GB | 2 GB | control plane + kubelet |
| MetalLB | 64 MB | 128 MB | |
| Traefik | 128 MB | 256 MB | |
| cert-manager | 64 MB | 128 MB | |
| ArgoCD | 512 MB | 1 GB | |
| Portainer | 256 MB | 512 MB | |
| Garage | 512 MB | 1 GB | scales with bucket count |
| Technitium | 128 MB | 256 MB | |
| ESO | 64 MB | 128 MB | |
| OpenBao | 256 MB | 512 MB | |
| Grafana | 256 MB | 512 MB | |
| Loki | 512 MB | 1 GB | |
| Mimir | 512 MB | 1 GB | |
| Tempo | 256 MB | 512 MB | |
| artifact-keeper | 512 MB | 1 GB | |
| PostgreSQL | 512 MB | 1 GB | |
| Meilisearch | 256 MB | 512 MB | |
| Velero | 256 MB | 512 MB | |
| **Subtotal** | **~6 GB** | **~11 GB** | |
| GitLab CE (Phase 5) | 4 GB | 8 GB | largest single service |
| **Total with GitLab** | **~10 GB** | **~19 GB** | |
| **Remaining for apps** | **~29 GB** | | on a 48GB VM |

## Deployment Phases (revised)

1. **Phase 1 - Foundation:** Lima VM (vzNAT/shared networking), K3s, OpenBao, ESO, MetalLB, Traefik, cert-manager
   - OpenBao + ESO deployed early to provide secrets for cert-manager DNS credentials
   - `bootstrap.sh` includes interactive secret seeding into OpenBao
2. **Phase 2 - Platform:** ArgoCD, Portainer, Garage, Technitium, Velero
   - Garage must be running before Velero is deployed
   - ArgoCD takes over GitOps sync from this phase onward
3. **Phase 3 - Monitoring:** Grafana, Loki, Mimir, Tempo (migrate from Docker Compose)
   - All backends configured to use Garage S3 buckets
4. **Phase 4 - Services:** artifact-keeper + dependencies (migrate from Docker Compose)
5. **Phase 5 - GitLab CE:** Deploy when ready (resource-intensive: 4-8 GB RAM)
6. **Phase 6 - Apps:** Future application workloads

### Dependency Chain

```
Lima VM → K3s → OpenBao → ESO → cert-manager (ClusterIssuers)
                                      ↓
                               MetalLB → Traefik
                                      ↓
                               ArgoCD → Garage → Velero
                                      ↓
                               Loki/Mimir/Tempo (need Garage S3)
                                      ↓
                               artifact-keeper (needs PostgreSQL, Meilisearch, Garage)
                                      ↓
                               GitLab CE
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| K3s over MicroK8s/Talos | Lightest footprint, largest community, simplest multi-node |
| Lima over OrbStack | Free, open-source, native Apple Virt.framework |
| Traefik over Nginx Ingress | Nginx K8s Ingress Controller end-of-support concerns, Traefik actively maintained |
| MetalLB over Klipper | Stable LB IPs, multi-node ready |
| Garage over MinIO/SeaweedFS | Lightweight, Rust-based, ideal for single-node, scales to multi-node |
| OpenBao + ESO over Sealed Secrets | Already in stack, avoids Bitnami dependency, centralized secret management |
| Technitium over PowerDNS | Single container (DNS + UI + API), simpler for dev-only DNS |
| ArgoCD over Flux | Web-UI included, App-of-Apps pattern, wider adoption |
| Portainer for management UI | Web-based, simple, deployed in-cluster |
