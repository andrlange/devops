# Getting Started

This guide walks you through installing the K8s DevOps Stack on an Apple Silicon Mac. You will run two scripts: `installer.sh` to prepare your machine, and `install.sh` to deploy the stack interactively.

---

## 1. Prerequisites

Read this whole section first. With the items below, a colleague can install the stack end-to-end.

### 1.1 Hardware & OS

- **Hardware:** Apple Silicon Mac — M4, M5 or newer (Pro, Max, or Ultra recommended)
- **macOS:** 26.0 (Tahoe) or later
- **RAM:** 64 GB minimum (the Lima VM is sized to 48 GB)
- **Disk:** ~500 GB free (the VM disk grows to ~70 GB in use, 200 GB max)
- **Architecture:** arm64 only — the entire stack is ARM64

`installer.sh` verifies the Apple chip generation, macOS version, RAM and free disk up front and stops with a clear message if any requirement isn't met.

### 1.2 Command-line tools — `installer.sh` checks these and offers to install them

You do **not** need to install these by hand. `installer.sh` checks each tool and its minimum version; if any are missing it asks **"N required tool(s) missing. Install automatically? [Y/n]"** and installs them via Homebrew.

| Tool | Min version | Homebrew formula | Purpose |
|------|-------------|------------------|---------|
| Homebrew | — | — | Package manager. If missing, the installer offers to install it first (**needs your sudo password**). |
| Docker Desktop | — | `--cask docker` | Must be **running** before install — the installer pauses until you start it. |
| Lima | 1.0 | `lima` | Runs the K3s VM (Apple Virtualization.framework). |
| kubectl | 1.28 | `kubectl` | Kubernetes CLI. |
| Helm | 3.12 | `helm` | Chart installs. |
| jq | any | `jq` | JSON parsing. |
| envsubst | any | `gettext` | Templating. |
| skopeo | any | `skopeo` | Image inspection. |
| crane | any | `crane` | Image mirroring. |
| CF CLI | 8 | `cloudfoundry/tap/cf-cli@8` | `cf push` / services. |
| Go | 1.26.4 | `go` | Builds the service brokers + kappman. |

Optional tools the installer also offers: **ArgoCD CLI**, **Velero CLI**, **k9s**.

Only two things the installer can't do for you: installing **Homebrew** (needs sudo) and **starting Docker Desktop** (it waits for you).

### 1.3 Container-registry credentials — required

Every image is pulled from the private registry **`artifactory.cfapps.cool`**. `installer.sh` prompts for a **Registry username** and **API Token**, validates them against the registry, and will not proceed without working credentials.

> **You will receive the registry username and API token from Andreas.** Request them before you start.

### 1.4 DNS + DNS-01 credentials — required

The stack issues wildcard TLS certificates with cert-manager via a **DNS-01 challenge**, so you need a DNS zone you control plus a credential that can write records to it:

- **Recommended: Google Cloud DNS** — a managed zone + a service account with the `roles/dns.admin` role, exported as a JSON key. `install.sh` prompts for this key during Iteration Zero.
- Alternative: **AWS Route 53** — an IAM user with Route 53 write access.

Step-by-step commands are in **Section 3 (DNS Setup)**; the detailed GCP service-account walkthrough is also in `k8/docs/gcp-dns-service-account.md` inside the extracted stack. You'll also add two wildcard A-records pointing at the fixed MetalLB IPs (Section 3).

### 1.5 What `install.sh` asks you (Iteration Zero)

The first time you run `install.sh` it collects, once:

- **DNS zone** + platform/apps subdomain prefixes (defaults: `sys` and `app`)
- **DNS-01 provider credentials** (the GCP JSON key or Route 53 keys from 1.4)
- **Lima VM name** (default `k3s-server`; pick a unique name to run more than one stack)
- Admin **passwords** (auto-generated if you don't supply them)

Everything generated is written to `credentials.md` at the end — store it securely.

---

## 2. Quick Start

### Step 0 — Bootstrap from the registry

Download the installer and the stack archive straight from the registry and launch the installer in one command:

```bash
BASE=https://artifactory.cfapps.cool/api/v1/repositories/generic/download && \
  curl -sfL $BASE/installer-v1.2.0.sh -o installer.sh && \
  curl -sfL $BASE/stack-v1.2.0.tgz -o stack.tgz && \
  bash installer.sh
```

> These downloads are public, but `installer.sh` then prompts for the **registry username + API token** (Section 1.3) — **you get these from Andreas** — to pull container images.

`installer.sh` performs the system + tool checks (Section 1.2), installs any missing tools (with your confirmation), authenticates to the container registry, verifies the `stack.tgz` checksum, and unpacks the stack to `~/devops-stack`.

### Step 1 — Run the interactive installation wizard

```bash
cd ~/devops-stack/k8/distribution
./install.sh
```

The wizard prompts for your domain, DNS provider credentials, and passwords (Iteration Zero, Section 1.5), then deploys the stack in phases.

> **Before running `install.sh`,** complete the DNS setup described in the next section.

---

## 2a. What to expect during the run (and when it asks you something)

The install is mostly hands-off, but there are a few points where it **waits for a decision or for you to press ENTER**. Here's the whole flow in order:

### Before anything — have these ready
- **Registry username + API token** — *you get these from Andreas* (Section 1.3).
- **DNS-01 credential** — a GCP Cloud DNS service-account JSON key (recommended) or Route 53 keys (Section 1.4 / Section 3).
- Your **DNS zone** name and the **platform/apps subdomain** prefixes you want (defaults `sys` / `app`).

### `installer.sh` (bootstrap) — interactions
1. **System checks** (chip, macOS, RAM, disk) run automatically.
2. **Missing tools** → it asks **`N required tool(s) missing. Install automatically? [Y/n]`** → press **Enter/Y** to let it `brew install` them.
3. **Docker Desktop** must be running → if it isn't, it pauses with **`Please start Docker Desktop, then press Enter to continue…`**.
4. **Registry login** → prompts **`Registry username:`** and **`API Token:`** (the creds from Andreas), validates them, and logs in.
5. Verifies the `stack.tgz` checksum and unpacks to `~/devops-stack`.

### `install.sh` Iteration Zero — collect config, then confirm
On first run it collects everything once (press **Enter** to accept each default in `[...]`):
- **DNS zone** (e.g. `example.com`) + **platform/apps subdomain** prefixes (`sys` / `app`)
- **VM sizing** — CPUs / RAM (GB) / disk (GB)
- **DNS-01 provider credentials** (paste the GCP JSON key path / Route 53 keys)
- Admin **passwords** (auto-generated if left blank)

Then it shows a **Configuration Summary** and asks you to **confirm it `[Y/n]`** — this is your *"use this config?"* checkpoint. Answer **n** to re-enter anything.

### Phase 1 — the DNS pause (the one manual step mid-install)
After MetalLB comes up, Phase 1 prints the **two wildcard A-records** to create and **waits**:

```
Press ENTER when DNS records have been configured...
```

At this point, add these to your DNS zone (IPs are fixed on every Apple Silicon Mac), then press **ENTER**:

| Record | Points to |
|--------|-----------|
| `*.sys.<your-zone>`  | `192.168.64.200` |
| `*.app.<your-zone>`  | `192.168.64.203` |

(See Section 3 for the full DNS setup. cert-manager needs these to issue the wildcard TLS certs.)

### Optional later prompts
- **`Add KUBECONFIG to ~/.zshrc? [Y/n]`** — convenience; **Y** lets you run `kubectl` without exporting it each shell.
- **Optional phases (6–9)** — Cloud Foundry / brokers / kappman / AI services are optional and each asks **`Continue with Phase N (…)? [Y/n]`**. Press **n** to stop at a smaller footprint, **Y** for the full PaaS.

### What's NORMAL during phases (don't panic)
You'll see lots of these while images pull and pods start:

```
[WARN]    Not all pods Ready yet in 'garage' — retrying in 30s...
[WARN]    Some pods in '...' still not Ready. Continuing anyway.
```

**This is expected** — the installer is just waiting for containers to pull/start, retries automatically, and moves on. Big components (ArgoCD, GitLab, Grafana, Korifi) can take a few minutes each. Only an explicit `[ERROR]` that stops the script needs attention.

### Expected duration (example — Apple **M5**)

Roughly **~45 minutes end-to-end** for the full stack (all 9 phases) on an M5. Per-phase (first run, cold image cache):

```
  Phase 1  5m 42s     Foundation (Lima, K3s, OpenBao, ESO, MetalLB, Traefik, cert-manager)
  Phase 2  7m 10s     Platform (ArgoCD, Portainer, Garage, Technitium, Velero)
  Phase 3  3m 56s     Monitoring (Loki, Mimir, Tempo, Alloy, KSM, node-exporter, Grafana)
  Phase 4  1m 40s     Services (artifact-keeper, PostgreSQL, OpenSearch)
  Phase 5  5m 24s     GitLab CE
  Phase 6  12m 10s    Cloud Foundry / Korifi   ← longest (kpack builder assembly)
  Phase 7  1m 40s     CF Service Brokers
  Phase 8  2m 58s     kappman
  Phase 9  2m 2s      Marketplace Extension 1 (AI/ML)
```

A successful run ends with `[OK]  Installation complete!`, the timing summary, and an **Installation Status** report — all phases `Complete`, every component `[x]`, the node `Ready`, and the platform endpoints `UP`:

```
========== Installation Status ==========
Phases
  Phase 1  Foundation ...                                   Complete (…)
  … (all phases Complete)
Components
  [x] Lima VM + K3s        …
  [x] OpenBao              …
  … (every component checked)
Cluster Health
  lima-k3s-server   Ready   control-plane   …   v1.36.1+k3s1   …
Service Endpoints
  Traefik     https://traefik.sys.<zone>     UP (302)
  ArgoCD      https://argocd.sys.<zone>      UP (200)
  Portainer   https://portainer.sys.<zone>   UP (307)
  Grafana     https://grafana.sys.<zone>     UP (302)
  Technitium  https://dns.sys.<zone>         UP (200)
```

You can re-print this anytime with `./k8/stack.sh status`.

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

### CF admin credentials — how to authenticate

Cloud Foundry admin access is **certificate-based**, not password-based. The installer created a
dedicated kubeconfig context called **`cf-admin`** (a client cert mapped to Korifi's admin user), and the
`cf` CLI authenticates as whatever kubeconfig context is currently active. So you don't enter a password —
you switch context and authenticate against it:

```bash
# Toggle kubectl between the cluster-admin and cf-admin contexts (the "stack command")
./k8/stack.sh switch          # → switches to 'cf-admin' (run again to switch back)
./k8/stack.sh context         # show which context is active

# Point the cf CLI at your API and authenticate as the (cert-backed) admin
cf api https://api.<apps-domain> --skip-ssl-validation
cf auth cf-admin
```

- The **CF API URL** and the **kappman login** (`admin` / `change_me`) are recorded in `credentials.md`.
- There is **no CF admin password** to store — access is the `cf-admin` client cert in your kubeconfig. Keep your kubeconfig safe; that *is* the credential.
- Always `./k8/stack.sh switch` **back** to the `k3s-<vm>` context for normal `kubectl` work.

### First org, space, and app (push the html-demo)

A complete first run, from login to a live app:

```bash
# 1. Authenticate as CF admin
./k8/stack.sh switch
cf api https://api.<apps-domain> --skip-ssl-validation
cf auth cf-admin

# 2. Create an org + space and target them
cf create-org demo
cf target -o demo
cf create-space dev
cf target -o demo -s dev

# 3. Push the bundled html-demo (a tiny static site via the httpd buildpack)
cd ~/devops-stack/demos/html
cf push          # uses demos/html/manifest.yml (name: html-demo)

# 4. Open it
#    → https://html-demo.<apps-domain>
cf apps
cf app html-demo
```

The first `cf push` triggers a **kpack build** (source → droplet) and may take a couple of minutes while the
buildpack image is fetched; subsequent pushes are faster. A Java example (`demos/petclinic`, needs a
`postgresql` service — see the marketplace below) follows the same pattern.

> If you created the `demo` org/space via the CLI and don't see them in **kappman**, run
> `./k8/stack.sh refresh-kappman` (see below) — though on a current install kappman is a see-all admin and
> picks up new orgs automatically.

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
