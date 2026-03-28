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

These IPs are local to your Mac (vzNAT network) and remain stable across reboots.

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

The wizard deploys the stack in phases. Phases 1–5 are required. Phases 6–7 are optional.

| Phase | Components | Required |
|-------|-----------|----------|
| 1 | Foundation: Lima VM, K3s, OpenBao, ESO, MetalLB, Traefik, cert-manager | Yes |
| 2 | Platform: ArgoCD, Portainer, Garage S3, Technitium DNS, Velero | Yes |
| 3 | Monitoring: Grafana, Loki, Mimir, Tempo, Alloy, kube-state-metrics | Yes |
| 4 | Services: artifact-keeper, PostgreSQL, Meilisearch, Trivy | Yes |
| 5 | GitLab CE + Runner | Yes |
| 6 | Cloud Foundry (Korifi) | Optional |
| 7 | Service Brokers (PostgreSQL, Valkey, RabbitMQ, S3) | Optional (requires Go) |

Each phase must complete successfully before the next begins. The wizard will pause and wait for confirmation between phases.

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
./k8/stack.sh deletestack # Permanently remove a stack instance
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

---

## 7. Updating

```bash
# Restart a specific deployment to pull the latest image
kubectl rollout restart deployment/<name> -n <namespace>

# Restart the entire stack
./k8/stack.sh restart
```

---

## 8. Running Multiple Stacks

You can run multiple stack instances on the same Mac — for example, one for development and one for testing.

- Each stack gets its own Lima VM with a unique name
- Only one stack can be running at a time due to MetalLB IP conflicts
- During `install.sh` Iteration Zero, choose a unique VM name (e.g., `k3s-test`)
- `stack.sh start` shows a selection menu when multiple stacks exist
- `stack.sh deletestack` permanently removes a stack instance and all its data
