# Getting Started

This guide walks you through installing the K8s DevOps Stack on an Apple Silicon Mac. You will run two scripts: `installer.sh` to prepare your machine, and `install.sh` to deploy the stack interactively.

---

## 1. Prerequisites

- **Hardware:** Apple Silicon Mac — M4, M5 or newer (Pro, Max, or Ultra recommended)
- **macOS:** 26.0 or later
- **RAM:** 64 GB minimum
- **Disk:** 500 GB free space
- **Registry credentials:** Username and API token provided by your administrator

No other software needs to be installed manually. The installer handles everything else.

---

## 2. Quick Start

```bash
# Step 1 — Run on the downloaded archive location
bash installer.sh
```

This script performs system checks, installs required tools, authenticates with the container registry, and unpacks the stack.

```bash
# Step 2 — Run the interactive installation wizard
cd ~/devops-stack/k8/distribution
./install.sh
```

The wizard prompts for your domain, DNS provider credentials, and passwords, then deploys the stack in phases.

> **Before running `install.sh`,** complete the DNS setup described in the next section.

---

## 3. DNS Setup

The stack uses wildcard TLS certificates issued by cert-manager via DNS-01 challenge. You must configure DNS records and a service account with DNS write access before starting the installation.

### DNS A-Records

After Phase 1 deploys MetalLB, add these A-records to your DNS zone:

| Record | Points to |
|--------|-----------|
| `*.development.<your-domain>` | `192.168.64.200` |
| `*.app.<your-domain>` | `192.168.64.203` |

These IPs are fixed — macOS Virtualization.framework (vzNAT) always assigns the `192.168.64.0/24` subnet. MetalLB allocates from `192.168.64.200-210`. These IPs are local to your Mac and identical on every Apple Silicon Mac.

### Google Cloud DNS

```bash
# 1. Create or select a GCP project
gcloud projects create my-dns-project --name="DNS Project"
gcloud config set project my-dns-project

# 2. Enable Cloud DNS API
gcloud services enable dns.googleapis.com

# 3. Create a DNS zone
gcloud dns managed-zones create my-zone \
  --dns-name="example.com." \
  --description="Stack DNS zone"

# 4. Create a service account for cert-manager
gcloud iam service-accounts create cert-manager \
  --display-name="cert-manager DNS solver"

# 5. Grant dns.admin role
gcloud projects add-iam-policy-binding my-dns-project \
  --member="serviceAccount:cert-manager@my-dns-project.iam.gserviceaccount.com" \
  --role="roles/dns.admin"

# 6. Export JSON key
gcloud iam service-accounts keys create gcp-dns-key.json \
  --iam-account="cert-manager@my-dns-project.iam.gserviceaccount.com"
```

Keep `gcp-dns-key.json` — you will need it when `install.sh` prompts for DNS credentials during Iteration Zero.

### AWS Route 53

```bash
# 1. Create IAM user
aws iam create-user --user-name cert-manager-dns

# 2. Attach Route53 policy
aws iam attach-user-policy \
  --user-name cert-manager-dns \
  --policy-arn arn:aws:iam::aws:policy/AmazonRoute53FullAccess

# 3. Create access key
aws iam create-access-key --user-name cert-manager-dns
```

Save the `AccessKeyId` and `SecretAccessKey` — you will need them when `install.sh` prompts for DNS credentials during Iteration Zero.

---

## 4. Installation Phases

The wizard deploys the stack in 9 phases. All phases run automatically when using `./install.sh` without arguments.

| Phase | Components | Description |
|-------|-----------|-------------|
| 1 | Foundation | Lima VM, K3s, OpenBao, ESO, MetalLB, Traefik, cert-manager |
| 2 | Platform | ArgoCD, Portainer, Garage S3, Technitium DNS, Velero |
| 3 | Monitoring | Grafana, Loki, Mimir, Tempo, Alloy, kube-state-metrics, node-exporter |
| 4 | Services | artifact-keeper (Container Registry), PostgreSQL, Meilisearch, Trivy |
| 5 | GitLab CE | GitLab CE + GitLab Runner (CI/CD) |
| 6 | Cloud Foundry | Korifi (CF on K8s), kpack, Contour Gateway, Buildpacks |
| 7 | Service Brokers | OSBAPI Broker: PostgreSQL, Valkey, RabbitMQ, S3 (requires Go) |
| 8 | kappman | Korifi Apps Manager UI (Spring Boot, deployed via `cf push`) |
| 9 | Marketplace Extension 1 | PostgreSQL AI Enabled, OpenBao Secrets, AI Connector [OPTIONAL] |

Each phase tracks completion state and can be resumed individually with `./install.sh phase <N>`. A timing summary is displayed after each phase.

---

## 4a. Extending an Existing Installation

If you already have a running stack (Phase 7+) and want to add AI/ML marketplace services without re-running the full installer:

```bash
cd ~/devops-stack/k8/distribution
./extend-marketplace-1.sh
```

This adds three new services to the Cloud Foundry marketplace:

| Service | Description |
|---------|-------------|
| **postgres-ai** | PostgreSQL 17 with pgvector, pgvectorscale, PostGIS, full-text search |
| **openbao-secrets** | Application-managed secrets in OpenBao with AppRole access |
| **ai-connector** | Connect to external Ollama / LM Studio instances |

For new installations, these services are included automatically as Phase 9.

**Usage examples:**
```bash
cf create-service postgres-ai small my-vector-db
cf create-service openbao-secrets default my-secrets
cf create-service ai-connector default my-ai -c '{"provider":"ollama","host":"192.168.64.1","port":11434}'
```

---

## 5. Post-Installation

### Credentials

All service passwords, tokens, and unseal keys are written to `credentials.md` in your stack directory at the end of the installation. Store this file securely and do not commit it to version control.

### Stack Management

```bash
./k8/stack.sh start       # Start the stack
./k8/stack.sh stop        # Stop the stack
./k8/stack.sh status      # Check status of all components
./k8/stack.sh restart     # Restart the stack
./k8/stack.sh switch      # Switch between K8s admin and CF admin context
./k8/stack.sh deletestack # Permanently remove a stack instance
```

### Switching Contexts (Kubernetes vs Cloud Foundry)

The stack uses two kubectl contexts:

| Context | Purpose | When to use |
|---------|---------|-------------|
| `k3s-<vm-name>` | Cluster admin | Managing K8s resources, Helm, debugging pods |
| `cf-admin` | CF admin | `cf push`, `cf create-service`, CF CLI operations |

Switch manually:
```bash
# Kubernetes admin (default)
kubectl config use-context k3s-<vm-name>

# Cloud Foundry admin (for cf CLI)
kubectl config use-context cf-admin
cf api https://api.<apps-domain> --skip-ssl-validation
cf auth cf-admin
```

Or use `stack.sh switch`:
```bash
./k8/stack.sh switch      # Toggle between k3s admin and cf-admin contexts
```

### Service URLs

Replace `<domain>` with the domain you configured during installation.

| Service | URL |
|---------|-----|
| ArgoCD | `https://argocd.development.<domain>` |
| Grafana | `https://grafana.development.<domain>` |
| GitLab | `https://gitlab.development.<domain>` |
| Portainer | `https://portainer.development.<domain>` |

---

## 6. Troubleshooting

### Pod startup warnings during installation

During installation, you will see warnings like:

```
[WARN] Not all pods Ready yet in 'garage' — retrying in 30s...
```

**This is normal.** Container images need to be pulled from the registry, which can take 30 seconds to several minutes depending on image size and network speed. The installer automatically retries after 30 seconds and will continue even if some pods are still starting.

Large components like ArgoCD, GitLab CE, and Grafana may take 2-5 minutes to become fully ready. The installer handles this gracefully — you do not need to intervene.

### Common issues

| Problem | Solution |
|---------|----------|
| Lima VM won't start | `limactl stop <name> && limactl start <name>`. Check `limactl list` for status. |
| Pods stuck in `ImagePullBackOff` | Registry credentials are wrong. Check `kubectl get events -A`. Re-run the installer with the correct token. |
| Certificate not issued | DNS records have not propagated. Check `kubectl describe certificate -A`. Verify A-records point to `192.168.64.200` and `192.168.64.203`. |
| OpenBao sealed after restart | Run `./k8/stack.sh start` — auto-unseal is attempted automatically. If manual unseal is needed, see `credentials.md` for unseal keys. |
| No LoadBalancer IP assigned | MetalLB L2 requires vzNAT networking. Verify the Lima VM type: `limactl info | jq '.vmType'` should return `"vz"`. |
| `kubectl` connection refused | Wrong kubeconfig context. Run `./k8/stack.sh context` to verify, or `./k8/stack.sh start` to re-export the kubeconfig. |
| Installation interrupted | Re-run `./install.sh phase <N>` to resume from where it stopped. Completed components are tracked and skipped automatically. |
| Portainer shows "timed out" | Portainer locks itself if you don't create an admin account within 5 minutes of installation. Restart the pod: `kubectl rollout restart deployment portainer -n portainer`, then immediately open the Portainer URL and set your admin password. |

---

## 7. Updating

```bash
# Restart a specific deployment to pull the latest image
kubectl rollout restart deployment/<name> -n <namespace>

# Restart the entire stack
./k8/stack.sh restart
```

---

## 8. Cloud Foundry: Organizations, Spaces and kappman

### Creating Orgs and Spaces

```bash
# Switch to CF admin context
./k8/stack.sh switch

# Login to CF API
cf api https://api.<apps-domain> --skip-ssl-validation
cf auth cf-admin

# Create an org and space
cf create-org my-org
cf target -o my-org
cf create-space dev
cf target -o my-org -s dev

# Deploy an app
cf push my-app
```

### kappman (Korifi Apps Manager UI)

kappman provides a web dashboard for managing Cloud Foundry orgs, spaces, apps, and services.

- URL: `https://kappman.<apps-domain>`
- Default login: `admin` / `change_me`

**Visibility rule:** kappman can see all orgs and spaces that it has been granted access to via Kubernetes RoleBindings.

- Orgs/spaces created **by kappman** in the UI are visible immediately
- Orgs/spaces created **via cf CLI** require a RoleBinding refresh:

```bash
./k8/stack.sh refresh-kappman
```

This scans all CF-managed Kubernetes namespaces and ensures kappman has the required RoleBindings. Run it after creating orgs or spaces via the cf CLI.

### Service Marketplace

After Phase 7, the following services are available:

```bash
cf marketplace
```

| Service | Plans | Description |
|---------|-------|-------------|
| postgresql | small, medium | PostgreSQL 18 via CloudNativePG |
| valkey | small | Valkey (Redis-compatible) key-value store |
| rabbitmq | small | RabbitMQ message broker |
| s3 | default | S3-compatible object storage (Garage) |
| postgres-ai | small | PostgreSQL 17 with pgvector, pgvectorscale, PostGIS, full-text search |
| openbao-secrets | default | Application-managed secrets in OpenBao with AppRole access |
| ai-connector | default | Connect to external Ollama / LM Studio instances |

```bash
# Create a service
cf create-service postgresql small my-db

# Bind to an app
cf bind-service my-app my-db
cf restart my-app
```

---

## 9. Running Multiple Stacks

You can run multiple stack instances on the same Mac — for example, one for development and one for testing.

- Each stack gets its own Lima VM with a unique name
- Only one stack can be running at a time due to MetalLB IP conflicts
- During `install.sh` Iteration Zero, choose a unique VM name (e.g., `k3s-test`)
- `stack.sh start` shows a selection menu when multiple stacks exist
- `stack.sh deletestack` permanently removes a stack instance and all its data
