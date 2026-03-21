# K8s DevOps Stack

## Project Overview

Kubernetes-based DevOps environment on Apple Silicon Macs (M4+, 64GB+). Single-node K3s cluster in a Lima VM with multi-node expansion capability. Migrates existing Docker Compose stacks (Vault/OpenBao, artifact-keeper, OTEL monitoring) into a unified GitOps-managed K8s platform.

## Current State

- **Phase 1 (Foundation):** Deployed — Lima VM, K3s, OpenBao, ESO, MetalLB, Traefik, cert-manager, Kubernetes Reflector
- **Phase 2 (Platform):** Deployed — ArgoCD, Portainer, Garage, Technitium, Velero, Velero UI
- **Phase 3 (Monitoring):** Deployed — Grafana, Loki, Mimir, Tempo, Alloy, kube-state-metrics, node-exporter
- **Phase 4 (Services):** Deployed — artifact-keeper (Backend + Web UI v1.1.0-rc.8-patched) + PostgreSQL 17.9 + Meilisearch v1.39.0 + Trivy Scanner v0.69.3
- **Phase 5 (GitLab CE):** Deployed — GitLab CE 18.10.0 + GitLab Runner (automated registration via distribution/install.sh)
- **Phase 6 (Apps):** Deployed — Korifi v0.18.0 (CF on K8s) + kpack ARM64 + Contour Gateway

## Tech Stack

- **K8s Distribution:** K3s in Lima VM (Ubuntu 24.04 ARM64, Apple Virtualization.framework)
- **GitOps:** ArgoCD (App-of-Apps pattern)
- **Ingress:** Traefik + MetalLB (L2 mode)
- **TLS:** cert-manager with Let's Encrypt wildcard via DNS-01 (Google Cloud DNS + Route53)
- **Secret Management:** OpenBao + External Secrets Operator (ESO)
- **Object Storage:** Garage (S3-compatible), S3 Manager (cloudlena/s3manager) for web UI
- **Monitoring:** Grafana + Loki + Mimir + Tempo + Alloy + kube-state-metrics + node-exporter (backends → Garage S3)
- **DNS:** Technitium DNS (internal zones + Web-UI)
- **Management UI:** Portainer
- **Backup:** Velero → Garage S3, Velero UI (otwld/velero-ui)
- **Artifact Registry:** artifact-keeper (PostgreSQL + Meilisearch + Garage S3)
- **Git Hosting:** GitLab CE 18.10.0 + GitLab Runner (CI/CD)
- **Namespaces:** gitlab, gitlab-runner, gitlab-runner-jobs

## Directory Structure

```
k8/
├── config.env                # Network, registry, arch, domain configuration
├── set-arch.sh               # Set image tag architecture suffix across all charts
├── stack.sh                  # Master script: start/stop/status/restart/backup
├── bootstrap/                # One-time setup: Lima VM + K3s + ArgoCD
├── infrastructure/           # MetalLB, Traefik, cert-manager
├── platform/                 # ArgoCD, Portainer, Garage, Technitium, ESO
├── monitoring/               # Grafana, Loki, Mimir, Tempo, Alloy
├── services/                 # OpenBao, artifact-keeper, GitLab CE
├── apps/                     # Future application workloads
├── velero/                   # Backup configuration + schedules
└── docs/                     # Phase documentation, specs, operational guides
distribution/                 # Lean installer package (outside k8/)
plans/                        # Implementation plans
```

## Distribution

The `distribution/` directory contains the lean installer package, inspired by Pivotal Labs methodology:

- **Iteration Zero:** Bootstrap and initial platform setup
- **Implementation:** Phased deployment of all stack components
- **Operations:** Day-2 operations, upgrades, troubleshooting

The distribution packages the entire stack for repeatable deployment on any Apple Silicon Mac.

## Architecture-Configurable Image Tags

All container images use architecture-specific tags with a `-arm64` or `-amd64` suffix (e.g., `openbao:2.5.1-arm64`). The target architecture is set in `k8/config.env` via the `ARCH` variable.

Run `k8/set-arch.sh` to update all Helm `values.yaml` files at once:

```bash
./k8/set-arch.sh          # Uses ARCH from config.env (default: arm64)
./k8/set-arch.sh amd64    # Override to amd64
```

## Networking (vzNAT)

Lima VM uses vzNAT networking via macOS Virtualization.framework on the `192.168.64.0/24` subnet. This is portable across networks (no bridging, no host network dependency).

- **Gateway/DNS:** `192.168.64.1`
- **MetalLB IP Pool:** `192.168.64.200–192.168.64.210` (upper range of subnet)
- **SSH Service (GitLab):** `192.168.64.202` (Port 22, separate MetalLB LoadBalancer IP)
- **Domain patterns:**
  - PLATFORM_DOMAIN: `<service>.development.cfapps.cool` (Platform & Management services)
  - APPS_DOMAIN: `<service>.app.cfapps.cool` (Application workloads)

## Container Registry

All container images are pulled from artifact-keeper at `artifactory.cfapps.cool/docker-local/`. The pull secret name is `artifact-keeper-pull`, configured in `k8/config.env`.

## Key Conventions

- Each service directory contains either `Chart.yaml` + `values.yaml` (Helm) or `kustomization.yaml`
- ArgoCD Application manifests live in `platform/argocd/applications/`
- Secrets are NEVER stored in Git — they live in OpenBao, synced via ESO
- All manifests must be ARM64-compatible (Apple Silicon)
- Domain patterns: `<service>.development.cfapps.cool` (platform), `<service>.app.cfapps.cool` (apps)

## Important Notes

- K3s runs with `--disable traefik,servicelb` — both are deployed separately via Helm
- Lima VM config is in `bootstrap/lima.yaml` — this IS the infrastructure definition
- Lima VM MUST use vzNAT/shared networking (socket_vmnet) for MetalLB L2 to work
- Velero uses Restic/Kopia for PV backups (local-path-provisioner has no CSI snapshot support)
- OpenBao unseal keys must be stored in a password manager, never in Git
- Garage serves as S3 backend for Velero, Loki, Mimir, Tempo, and artifact-keeper
- DNS provider credentials (GCP, AWS) are stored in OpenBao, referenced via ESO
- GitLab Runner registration is automated via `distribution/install.sh` (creates runner token, registers runner, configures executor)
- Helm chart versions must exactly match app versions — mismatches cause silent failures
- Platform service IngressRoutes use `tls: {}` (default TLSStore with `*.development.cfapps.cool` wildcard cert)
- App service IngressRoutes use `tls: { secretName: wildcard-apps-tls }` (separate `*.app.cfapps.cool` wildcard cert)
- Some Helm charts use a `registry`/`repository` split; others need the full URL in `repository`
- Mimir runs as a standalone Deployment (not the mimir-distributed chart)

## Documents

- Design Specification: `k8/docs/superpowers/specs/2026-03-19-k8s-devops-stack-design.md`
- GCP DNS Setup: `k8/docs/gcp-dns-service-account.md`
- Implementation Plan: `plans/implementation-plan.md`
