# Distribution Package Design

**Date:** 2026-03-28
**Status:** Approved
**Author:** Andreas + Claude

## Overview

Package the entire K8s DevOps stack as a distributable archive so colleagues on Apple Silicon Macs (M4+, 64GB+ RAM) can deploy the full platform independently. The distribution consists of two files: `installer.sh` (pre-flight wizard) and `stack.tgz` (the stack itself).

## Deliverables

Two files handed to each colleague:

| File | Purpose |
|------|---------|
| `installer.sh` | Pre-flight wizard: system checks, tool installation, token validation, unpacking |
| `stack.tgz` | Archive containing `k8/` and `demos/` directories |

## Architecture: Monolithic Installer (Approach A)

Clear separation of concerns:

- `installer.sh` = Host preparation (system checks, tools, credentials, unpack)
- `distribution/install.sh` = Stack deployment (existing, phased, interactive)

```
Colleague receives: installer.sh + stack.tgz
        |
        v
   installer.sh
   +-- System-Check (macOS 26.3+, M4+, 64GB, 500GB)
   +-- Token-Validation (docker login against artifactory.cfapps.cool)
   +-- Tool-Installation (brew, kubectl, helm, limactl, ...)
   +-- Unpack stack.tgz -> ~/devops-stack/ (or user-chosen path)
   +-- Write credentials into install directory
   +-- Message: "cd ~/devops-stack/k8/distribution && ./install.sh"
        |
        v
   install.sh (existing)
   +-- Iteration Zero (Domain, Network, DNS Provider, Passwords)
   +-- Phase 1-7 (fully automated, no manual steps)
   +-- credentials.md updated after each phase
```

## installer.sh Specification

### Step 1: System Prerequisites (hard gate — abort on failure)

| Check | Minimum | Command |
|-------|---------|---------|
| macOS Version | 26.3+ | `sw_vers -productVersion` |
| Chip | M4+ (M4, M5, M6, ...) | `system_profiler SPHardwareDataType \| grep Chip` — parse number after "M", require >= 4 |
| Architecture | ARM64 | `uname -m` |
| Free Disk | 500GB | `df -g /` |
| RAM | 64GB | `sysctl -n hw.memsize` — convert to GB |

Failure message: "Your system does not meet the minimum requirements. <specific reason>"

### Step 2: Registry Authentication

```
+----------------------------------------------------------+
|  Registry Authentication                                  |
|                                                          |
|  This stack uses a private container registry at         |
|  artifactory.cfapps.cool. You need credentials to        |
|  proceed. Credentials are provided by your administrator.|
+----------------------------------------------------------+

Registry username: ________
API Token: ________
```

- Validate via `docker login artifactory.cfapps.cool -u <user> -p <token>`
- On success: store in `<install-dir>/.registry-credentials` (chmod 600)
- On failure: retry up to 3 times, then abort
- No token = abort: "Cannot proceed without registry access."

### Step 3: Host Tools (install if missing, with confirmation)

**Required tools:**

| Tool | Install Method | Min. Version |
|------|---------------|-------------|
| Homebrew | Official installer script | - |
| limactl | `brew install lima` | 1.0+ |
| kubectl | `brew install kubectl` | 1.28+ |
| helm | `brew install helm` | 3.12+ |
| jq | `brew install jq` | - |
| envsubst | `brew install gettext` | - |
| skopeo | `brew install skopeo` | - |
| crane | `brew install crane` | - |
| cf CLI | `brew install cloudfoundry/tap/cf-cli@8` | 8+ |
| docker | Docker Desktop (manual install prompt) | - |

**Optional tools (offered separately):**

| Tool | Install Method |
|------|---------------|
| argocd | `brew install argocd` |
| velero | `brew install velero` |
| k9s | `brew install k9s` |

**Flow:**
1. Check all tools, display status table (installed/missing/version)
2. If brew missing: install brew first (requires sudo)
3. "X required tools missing. Install automatically? [Y/n]"
4. "Install optional tools? (argocd, velero, k9s) [y/N]"
5. sudo prompt where needed (brew, Docker Desktop)
6. If user declines required tools: abort with message

### Step 4: Unpack & Configure

1. Ask for install directory (default: `~/devops-stack`)
2. Extract `stack.tgz` to chosen directory
3. Write `.registry-credentials` into `<install-dir>/k8/`
4. Print next steps message

## stack.tgz Specification

### Contents

```
stack/
+-- k8/                    # Complete k8/ directory
|   +-- distribution/      # install.sh + libs (existing)
|   +-- bootstrap/
|   +-- infrastructure/
|   +-- platform/
|   +-- monitoring/
|   +-- services/
|   +-- apps/
|   +-- velero/
|   +-- config.env
|   +-- stack.sh
|   +-- set-arch.sh
|   +-- docs/
+-- demos/                 # Demo applications
+-- GETTING_STARTED.md     # English guide
```

### Excluded from archive

- `.git/` directories
- `.env`, `.env.local`, `.install-config`, `.install-state`
- `credentials.md` (generated during installation)
- `source/` (artifact-keeper build source)
- `artifactory/` (local Docker Compose instance)
- `.DS_Store`
- `otel/` (legacy)
- `.superpowers/`

### Build script

`build-distribution.sh` in repo root creates `stack.tgz`:

```bash
./build-distribution.sh    # -> produces installer.sh + stack.tgz
```

## Domain Configuration

Two wildcard domains required:

- Platform: `*.development.<BASE_DOMAIN>` (ArgoCD, Grafana, GitLab, etc.)
- Apps: `*.app.<BASE_DOMAIN>` (Application workloads)

Configured during `install.sh` Iteration Zero. The installer.sh does NOT ask for domains — that is handled by the existing install.sh flow.

### DNS Provider Support

| Provider | Credentials Needed |
|----------|--------------------|
| Google Cloud DNS | Project ID + Service Account JSON key |
| AWS Route 53 | Access Key ID + Secret Key + Region |
| Both | All of the above |

DNS setup (creating service accounts/IAM users) is the **only manual step** — documented in GETTING_STARTED.md with step-by-step CLI commands.

## credentials.md

Generated automatically during installation, updated after each phase.

```markdown
# Stack Credentials
# WARNING: Development environment only - do not use in production
# Generated: <date> | Domain: <domain>

## Platform Access
| Service    | URL                              | Username | Password    |
|------------|----------------------------------|----------|-------------|
| ArgoCD     | https://argocd.development....   | admin    | <generated> |
| Grafana    | https://grafana.development....  | admin    | <generated> |
| ...

## Infrastructure
| Service    | Details                          |
|------------|----------------------------------|
| OpenBao    | Unseal Keys: ... / Root Token: ...|
| Garage S3  | Admin Key: ... / Secret: ...     |
| Registry   | artifactory.cfapps.cool (svc-stack) |

## Databases
| Service    | Host (in-cluster)      | User | Password    |
|------------|------------------------|------|-------------|
| PostgreSQL | postgres.svc:5432      | ...  | <generated> |
```

- Location: `<install-dir>/credentials.md`
- Permissions: `chmod 600`
- Referenced in GETTING_STARTED.md

## GETTING_STARTED.md

English-language guide with these sections:

1. **Prerequisites** — Hardware requirements, what you need from your administrator
2. **Quick Start** — Run installer.sh, then distribution/install.sh
3. **DNS Setup**
   - Google Cloud DNS: create project, enable API, create service account with `dns.admin` role, export JSON key (gcloud CLI commands)
   - AWS Route 53: create IAM user, attach Route53FullAccess policy, create access key (aws CLI commands)
4. **Installation Phases** — Brief description of phases 1-7, which are optional
5. **Post-Installation** — Service URLs, credentials.md reference, stack.sh usage
6. **Troubleshooting** — Lima VM issues, ImagePullBackOff, certificate problems, OpenBao sealed, MetalLB issues
7. **Updating** — How to pull new images, update the stack

## Automation Requirements

**No manual steps during installation.** Specifically:

- OpenBao init/unseal: automated (keys and root token captured and written to credentials.md)
- All Helm installs: automated via existing install.sh
- GitLab runner registration: automated via existing install.sh
- Pull secret creation: automated using stored registry credentials
- Certificate issuance: automated via cert-manager (requires DNS provider credentials)

The **only manual prerequisite** is DNS provider setup (GCP/AWS service account creation), documented in GETTING_STARTED.md.

## Registry Access

- Registry: `artifactory.cfapps.cool`
- Service Account: `svc-stack` (read-only)
- Auth method: API token as Basic Auth password (patched in artifact-keeper v1.1.0-rc.8-patched)
- Each colleague receives a personal token (revokable independently)
- Token validated during installer.sh via `docker login`

## Security Considerations

- API tokens are read-only (`read:artifacts`, `read:repositories` scopes)
- Tokens are revokable per-person by the administrator
- `.registry-credentials` stored with chmod 600
- `credentials.md` stored with chmod 600
- No secrets in stack.tgz
- OpenBao unseal keys only in credentials.md (never in git)
