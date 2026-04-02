# Preparation: K8s DevOps Stack

This document describes **all prerequisites** that must be met before the K8s DevOps Stack (Phases 1-4) can be deployed on a new system.

> **Important:** All steps must be completed in the specified order. Missing prerequisites will cause errors during bootstrapping.

---

## Hardware Requirements

| Component | Minimum | Recommended |
|---|---|---|
| Processor | Apple Silicon M4 | M4 Pro / M4 Max |
| RAM | 64 GB | 64 GB+ (GitLab CE alone requires 4-10 GB RAM) |
| Free disk space | 200 GB | 300 GB+ |
| Internet connection | Stable | Stable, ideally >100 Mbit/s |

The Lima VM is configured by default with the following resources (adjustable in `config.env`):

- **CPUs:** 8 cores
- **RAM:** 48 GB (the rest is reserved for macOS) — GitLab CE requires 4-10 GB RAM, so at least 48 GB should be allocated for the VM
- **Disk:** 200 GB

A stable internet connection is required for:

- Downloading the Ubuntu 24.04 ARM64 cloud image (~700 MB)
- K3s installation (~200 MB)
- Helm chart downloads
- Let's Encrypt ACME communication (DNS-01 Challenge)
- GitLab CE container image (~1.5 GB — import takes correspondingly longer)
- GitLab Runner + Helper container images

---

## Software Requirements

### macOS and Homebrew

Homebrew must be installed. If not already present:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Required Tools

All tools can be installed via Homebrew:

```bash
# Lima — Lightweight VM Manager for macOS
brew install lima

# Kubernetes CLI
brew install kubectl

# Helm — Kubernetes Package Manager
brew install helm

# Skopeo — Container Image Tool (for importing into artifact-keeper)
brew install skopeo

# jq — JSON processor (for scripts)
brew install jq

# envsubst — Substitute environment variables in templates
brew install gettext
```

### Verify Versions

```bash
limactl --version        # >= 1.0.0
kubectl version --client # >= 1.30
helm version             # >= 3.15
skopeo --version         # >= 1.15
jq --version             # >= 1.7
envsubst --version       # GNU gettext
```

### socket_vmnet (Network Prerequisite)

`socket_vmnet` is required so that the Lima VM receives a vzNAT network with a reachable IP address in the `192.168.64.0/24` subnet. Without this package, MetalLB L2 will not work.

```bash
# Installation
brew install socket_vmnet

# One-time setup (requires sudo)
sudo brew services start socket_vmnet
```

Verification:

```bash
# Check service status
sudo brew services list | grep socket_vmnet
# Expected output: socket_vmnet started
```

> **Note:** `socket_vmnet` requires root privileges because it creates a virtual network interface. The service must be started automatically after every macOS reboot (this is ensured by `brew services`).

### Optional Tools

```bash
# Google Cloud CLI (for GCP Cloud DNS setup)
brew install google-cloud-sdk

# AWS CLI (if using Route53 instead of Cloud DNS)
brew install awscli

# k9s — Terminal-based Kubernetes UI
brew install k9s
```

---

## Network Requirements

### vzNAT Network

The Lima VM uses the Apple Virtualization.framework with vzNAT (shared networking):

- **Subnet:** `192.168.64.0/24` (assigned by macOS)
- **Gateway:** `192.168.64.1` (macOS host)
- **DNS:** `192.168.64.1`
- The VM receives an IP address in this subnet (e.g., `192.168.64.2`)

**Advantages of vzNAT:**

- **Portable:** Works on any network, independent of DHCP configuration, corporate firewalls, or network changes
- **Isolated:** The virtual subnet is separated from the physical network
- **Stable:** No IP changes when switching networks (e.g., home office to office)

### MetalLB IP Pool

MetalLB operates in L2 mode and advertises IP addresses in the vzNAT subnet:

- **IP Range:** `192.168.64.200 - 192.168.64.210` (configurable in `config.env`)
- These IPs are assigned to `LoadBalancer` services (Traefik, etc.)
- **Port 22 (SSH):** GitLab SSH access runs on a separate MetalLB LoadBalancer IP (`192.168.64.202`) to avoid conflicts with the default SSH port on the Traefik IP
- The range is in the upper part of the subnet to avoid conflicts with the VM IP

**No conflicts with the physical network:** Since vzNAT uses its own virtual subnet, there are no overlaps with the physical LAN, Wi-Fi, or VPN.

### Firewall

If a local firewall is active (e.g., Little Snitch, Lulu), the following connections must be allowed:

- `socket_vmnet` → network access
- `lima` / `qemu` → network access
- Outbound: HTTPS (port 443) for ACME, Helm repos, image downloads

---

## DNS Preparation

### Two Wildcard Domains

The stack uses two separate wildcard domains:

| Domain | Purpose | Examples |
|---|---|---|
| `*.development.cfapps.cool` | Platform & Management Services | ArgoCD, Grafana, Portainer, OpenBao |
| `*.app.cfapps.cool` | Application Workloads | Custom applications (Phase 6) |

#### Platform Services (development.cfapps.cool)

| Service | URL |
|---|---|
| ArgoCD | `argocd.development.cfapps.cool` |
| Grafana | `grafana.development.cfapps.cool` |
| Portainer | `portainer.development.cfapps.cool` |
| OpenBao | `openbao.development.cfapps.cool` |
| artifact-keeper | `artifacts.development.cfapps.cool` |

#### Application Workloads (app.cfapps.cool)

For custom applications deployed in Phase 6 (e.g., `myapp.app.cfapps.cool`).

### Configure DNS Records

At the DNS provider (e.g., Google Cloud DNS, Cloudflare, Route53), **two** wildcard A records must be created, both pointing to the same Traefik LoadBalancer IP:

```
*.development.cfapps.cool  →  192.168.64.200
*.app.cfapps.cool          →  192.168.64.200
```

The IP `192.168.64.200` is the first address in the MetalLB pool and is assigned to Traefik. Both domains point to the same Traefik ingress — routing is handled via host-based IngressRoutes.

> **Note:** If custom domains are used, `PLATFORM_DOMAIN` and `APPS_DOMAIN` in `config.env` must be adjusted accordingly.

### TLS Certificates

cert-manager issues **separate** wildcard certificates for each domain:

| Certificate | Domain | Secret Name | Usage |
|---|---|---|---|
| Platform Wildcard | `*.development.cfapps.cool` | Default TLSStore | `tls: {}` in IngressRoutes |
| Apps Wildcard | `*.app.cfapps.cool` | `wildcard-apps-tls` | `tls: { secretName: wildcard-apps-tls }` in IngressRoutes |

Both certificates are validated via DNS-01 Challenge. Since both domains belong to the same DNS zone `cfapps.cool`, the same GCP Cloud DNS Service Account is used.

### DNS-01 Challenge Provider

DNS-01 validation is required for Let's Encrypt wildcard certificates. The stack supports two providers:

1. **Google Cloud DNS** (default) — see section "GCP Service Account"
2. **AWS Route53** (alternative) — see section "AWS Route53"

At least one provider must be configured for cert-manager to be able to issue wildcard certificates.

---

## GCP Service Account (for Cloud DNS)

cert-manager requires a GCP Service Account with access to Cloud DNS in order to solve DNS-01 challenges for Let's Encrypt wildcard certificates.

### Prerequisites

- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- GCP project exists (default: `cfapps-cool`)
- Cloud DNS zone for the domain is set up

### Quick Guide

```bash
# 1. Create Service Account
gcloud iam service-accounts create cert-manager-dns \
  --display-name="cert-manager DNS-01 solver" \
  --project=cfapps-cool

# 2. Assign role (roles/dns.admin = minimum for DNS-01)
gcloud projects add-iam-policy-binding cfapps-cool \
  --member="serviceAccount:cert-manager-dns@cfapps-cool.iam.gserviceaccount.com" \
  --role="roles/dns.admin"

# 3. Download JSON key
gcloud iam service-accounts keys create gcp-dns-credentials.json \
  --iam-account=cert-manager-dns@cfapps-cool.iam.gserviceaccount.com \
  --project=cfapps-cool
```

The JSON file will be stored in OpenBao during bootstrapping and then deleted locally.

> **Detailed guide:** See [`docs/gcp-dns-service-account.md`](../de/gcp-dns-service-account.md)

---

## AWS Route53 (Alternative)

If AWS Route53 is used instead of Google Cloud DNS:

### Create IAM User

```bash
aws iam create-user --user-name cert-manager-dns
```

### Assign IAM Policy

Minimal policy for cert-manager:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:GetChange",
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/*"
    }
  ]
}
```

### Create Access Keys

```bash
aws iam create-access-key --user-name cert-manager-dns
```

The following values are required:

- **Access Key ID** (e.g., `AKIA...`)
- **Secret Access Key** (e.g., `wJal...`)

These credentials will be stored in OpenBao during bootstrapping.

### Adjust config.env

```bash
ACME_DNS_ZONES_ROUTE53="my-domain.de"
ACME_DNS_ZONES_CLOUDDNS=""   # Disable Cloud DNS if using Route53 only
```

---

## Container Registry (artifact-keeper)

The stack pulls **all** container images from its own artifact-keeper registry. This ensures that:

- No external dependencies exist at runtime
- Rate limits from Docker Hub / GHCR / Quay do not apply
- Only vetted images run in the cluster
- Architecture-specific tags can be used

### Prerequisites

artifact-keeper must be reachable at the configured URL:

```
https://artifactory.cfapps.cool
```

If a different URL is used, `REGISTRY` in `config.env` must be adjusted.

### Import Images

All required container images are listed in `container-images.txt`. The import script uses `skopeo` to import images in an architecture-specific manner:

```bash
# Import all images (multi-arch)
./import-all-containers.sh

# Import only ARM64 images
./import-all-containers.sh --arch-only arm64

# Import only images for Phase 1
./import-all-containers.sh --phase 1

# Dry run — shows what would be imported
./import-all-containers.sh --dry-run

# Locally on the server (fast, no TLS)
./import-all-containers.sh --local
```

### Image Tag Schema

Images are stored with an architecture-specific suffix:

```
artifactory.cfapps.cool/docker-local/<image>:<tag>-arm64
artifactory.cfapps.cool/docker-local/<image>:<tag>-amd64
```

Example:

```
artifactory.cfapps.cool/docker-local/openbao/openbao:2.5.1-arm64
```

### Credentials

Two sets of credentials are required:

| Purpose | Description |
|---|---|
| **Admin credentials** | For `import-all-containers.sh` — write access to the registry |
| **Read-only credentials** | For K8s pull secrets — read-only access for pulling images |

The read-only credentials are stored as a Kubernetes Secret (`artifact-keeper-pull`) in the cluster so that K3s can pull images from the registry.

Additionally, the file `/etc/rancher/k3s/registries.yaml` is configured in the VM so that K3s containerd authenticates directly against the registry (see `bootstrap/install-k3s.sh`).

---

## Password Manager

The following secrets are generated during bootstrapping and **must be stored securely outside of Git** (e.g., 1Password, Bitwarden, KeePass):

### OpenBao Unseal Keys

During OpenBao initialization, the following are generated:

| Secret | Quantity | Note |
|---|---|---|
| **Unseal Keys** | 5 | Threshold: 3 out of 5 are required for unsealing |
| **Root Token** | 1 | For initial configuration, restrict access afterwards |

> **NEVER store in Git!** OpenBao unseal keys and root token must only be stored in a password manager.

### Additional Secrets

| Secret | Usage |
|---|---|
| artifact-keeper admin password | Image import into the registry |
| artifact-keeper read-only password | K8s pull secret |
| GCP JSON key (`gcp-dns-credentials.json`) | Stored in OpenBao, delete locally |
| AWS Access Key / Secret Key | If Route53 is used |
| ArgoCD admin password | Generated during installation |

---

## Configuration (config.env)

The file `config.env` in the project root contains all configurable parameters. It is read by `bootstrap.sh` and `stack.sh`.

### Complete Parameter Description

#### Architecture

| Parameter | Default | Description |
|---|---|---|
| `ARCH` | `arm64` | Target architecture for container images. Determines the tag suffix: `image:tag-${ARCH}` |

#### Lima VM

| Parameter | Default | Description |
|---|---|---|
| `LIMA_VM_NAME` | `k3s-server` | Name of the Lima VM |
| `LIMA_CPUS` | `8` | Number of CPU cores for the VM |
| `LIMA_MEMORY_GB` | `48` | RAM in GB for the VM |
| `LIMA_DISK_GB` | `200` | Disk space in GB for the VM |

#### Network

| Parameter | Default | Description |
|---|---|---|
| `NETWORK_SUBNET` | `192.168.64.0/24` | vzNAT subnet (assigned by macOS) |
| `NETWORK_GATEWAY` | `192.168.64.1` | Gateway IP (macOS host) |
| `NETWORK_DNS` | `192.168.64.1` | DNS server for the VM |
| `METALLB_IP_RANGE` | `192.168.64.200-192.168.64.210` | IP pool for MetalLB LoadBalancer services |

#### Domain and TLS

| Parameter | Default | Description |
|---|---|---|
| `PLATFORM_DOMAIN` | `development.cfapps.cool` | Domain for Platform & Management Services (`<service>.PLATFORM_DOMAIN`) |
| `APPS_DOMAIN` | `app.cfapps.cool` | Domain for Application Workloads (`<service>.APPS_DOMAIN`) |
| `ACME_EMAIL` | `admin@cfapps.cool` | Email address for Let's Encrypt registration |
| `GCP_PROJECT_ID` | `cfapps-cool` | GCP project ID for Cloud DNS |
| `ACME_DNS_ZONES_CLOUDDNS` | `cfapps.cool` | DNS zones validated via Google Cloud DNS |
| `ACME_DNS_ZONES_ROUTE53` | *(empty)* | DNS zones validated via AWS Route53 |

#### Container Registry

| Parameter | Default | Description |
|---|---|---|
| `REGISTRY` | `artifactory.cfapps.cool` | URL of the container registry |
| `REGISTRY_REPO` | `docker-local` | Repository name in the registry |
| `REGISTRY_PULL_SECRET_NAME` | `artifact-keeper-pull` | Name of the K8s pull secret |

#### Persistent Storage

| Parameter | Default | Description |
|---|---|---|
| `PV_BASE_PATH` | `/data/persistent` | Base path for Persistent Volumes in the VM |

---

## Checklist Before Starting

Complete all items before running `bootstrap.sh`:

### Hardware

- [ ] Apple Silicon Mac (M4 or newer)
- [ ] At least 64 GB RAM
- [ ] At least 200 GB free disk space

### Software

- [ ] Homebrew installed
- [ ] `limactl` installed (>= 1.0.0)
- [ ] `kubectl` installed (>= 1.30)
- [ ] `helm` installed (>= 3.15)
- [ ] `skopeo` installed (>= 1.15)
- [ ] `jq` installed (>= 1.7)
- [ ] `envsubst` installed (GNU gettext)
- [ ] `socket_vmnet` installed and started (`sudo brew services start socket_vmnet`)

### Network and DNS

- [ ] `socket_vmnet` service is running (`sudo brew services list | grep socket_vmnet`)
- [ ] Wildcard DNS record configured (`*.development.cfapps.cool → 192.168.64.200`)
- [ ] Wildcard DNS record configured (`*.app.cfapps.cool → 192.168.64.200`)
- [ ] DNS records tested (`dig +short test.development.cfapps.cool` and `dig +short test.app.cfapps.cool`)

### Credentials

- [ ] GCP Service Account created and JSON key downloaded **or** AWS IAM user with Route53 permissions created
- [ ] artifact-keeper is running and reachable (`curl -s https://artifactory.cfapps.cool/health`)
- [ ] All container images imported (`./import-all-containers.sh` completed successfully)
- [ ] artifact-keeper admin credentials prepared
- [ ] artifact-keeper read-only credentials prepared
- [ ] Password manager ready for OpenBao unseal keys

### Configuration

- [ ] `config.env` reviewed and adjusted as needed (domain, IP range, registry URL, GCP project)
- [ ] If using custom domains: `PLATFORM_DOMAIN`, `APPS_DOMAIN`, and `ACME_DNS_ZONES_*` parameters updated
- [ ] If using custom registry: `REGISTRY` and `REGISTRY_REPO` parameters updated

---

> **Next step:** Once all checklist items are completed, you can proceed with Phase 1 (Foundation) — see the bootstrapping documentation.
