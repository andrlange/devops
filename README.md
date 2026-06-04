# K8s DevOps Stack — A Self-Contained Developer Platform

A complete, GitOps-managed **developer platform** that runs on a single Apple Silicon Mac. It turns
one machine into a private cloud: push an app with `cf push`, get a URL, a database, a message queue,
object storage, real TLS, metrics, logs, traces, and backups — all without a public cloud account.

The platform's headline is a **Cloud Foundry experience powered by [Korifi](https://www.cloudfoundry.org/technology/korifi/)**,
sitting on top of a Kubernetes **Container-as-a-Service** layer, wrapped in a full **DevOps stack** for
secrets, artifacts, storage, DNS, networking, certificates, and disaster recovery.

> Everything runs in a lightweight Linux VM (Lima) on macOS, on a portable virtual network, with all
> container images served from a private registry — so the whole platform is reproducible and works
> the same on any developer's machine.

---

## What you can do with it

- **`cf push` your app** — bring source code or a JAR; the platform builds an OCI image with Cloud
  Native Buildpacks and runs it, gives it a route and a real HTTPS certificate.
- **Self-serve backing services** — `cf create-service` a PostgreSQL, Valkey (Redis-compatible),
  RabbitMQ, S3 bucket, an AI-enabled PostgreSQL, a managed secret container, or an AI model connector,
  then `cf bind-service` it to your app. Credentials are injected automatically.
- **Manage the platform from a UI** — **kappman**, a web PaaS console for Korifi, plus dashboards for
  GitOps, containers, storage, DNS, backups, and observability.
- **Run a complete inner-loop and CI** — host Git and pipelines, store build artifacts, scan them for
  vulnerabilities, and promote releases.
- **Operate it like production** — centralized secrets, scheduled backups, real wildcard certificates,
  internal DNS, and a full metrics/logs/traces stack.

---

## The platform in layers

```
┌────────────────────────────────────────────────────────────────────────────────┐
│  PaaS — Application Platform (Cloud Foundry experience)                        │
│                                                                                │
│   cf push ──▶  Korifi (CF API + orchestration on Kubernetes)                   │
│               • Cloud Native Buildpacks build (kpack)                          │
│               • Gateway routing + automatic TLS                                │
│               • kappman — web console / PaaS UI for Korifi                     │
│                                                                                │
│   Service Broker Ecosystem (Open Service Broker API)                           │
│   ┌──────────────────────────────┬────────────────────────────────────────┐    │
│   │ Core services                │ Marketplace / advanced services        │    │
│   │ • PostgreSQL  • Valkey       │ • AI-enabled PostgreSQL (pgvector…)    │    │
│   │ • RabbitMQ    • S3 buckets   │ • Managed secret containers            │    │
│   │                              │ • AI model connectors                  │    │
│   └──────────────────────────────┴────────────────────────────────────────┘    │
├────────────────────────────────────────────────────────────────────────────────┤
│  CaaS — Container Platform                                                     │
│   • Kubernetes (K3s) — the cluster everything runs on                          │
│   • ArgoCD — GitOps, App-of-Apps continuous delivery of the whole stack        │
│   • Portainer — cluster & workload management UI                               │
├────────────────────────────────────────────────────────────────────────────────┤
│  DevOps Stack — Platform Services                                              │
│   Secrets · Artifacts · Object Storage · Backup · DNS · Networking · TLS ·     │
│   Observability · Git & CI                                                     │
├────────────────────────────────────────────────────────────────────────────────┤
│  Foundation                                                                    │
│   • Lima VM (Linux on macOS, Apple Virtualization.framework)                   │
│   • Portable virtual network + software load balancer                          │
│   • Private container registry as the single image source                      │
└────────────────────────────────────────────────────────────────────────────────┘
```

---

## PaaS — the Cloud Foundry layer (the main event)

**Korifi** re-implements the Cloud Foundry developer API on top of Kubernetes. Developers keep the
familiar, productive workflow — `cf push`, `cf create-service`, `cf bind-service`, `cf logs` — while
everything underneath is standard Kubernetes objects.

- **Build & run:** source or artifacts are turned into runnable OCI images by **Cloud Native
  Buildpacks** (via kpack), so there are no hand-written Dockerfiles for typical apps.
- **Routing & TLS:** apps get a hostname under the apps domain and a real, automatically-issued
  wildcard certificate via the Gateway layer.
- **Multi-tenancy:** organizations and spaces map cleanly onto namespaces and roles.

### Service Broker ecosystem

A pair of **Open Service Broker API** brokers turn stateful infrastructure into self-service catalog
entries. Developers never touch the operators directly — they just request a service and bind it:

| Service | What it gives the developer |
|---|---|
| **PostgreSQL** | A managed relational database instance (provisioned by a Postgres operator) |
| **Valkey** | A Redis-compatible in-memory key/value store |
| **RabbitMQ** | A managed message broker (provisioned by a RabbitMQ operator) |
| **S3** | An S3-compatible bucket with scoped credentials |
| **AI-enabled PostgreSQL** | Postgres with vector search and geospatial/AI extensions for RAG & ML workloads |
| **Managed secrets** | An application-scoped secret container with its own access credentials |
| **AI model connector** | A binding to local/remote LLM endpoints via an OpenAI-compatible API |

Binding a service injects its credentials into the app automatically, the Cloud Foundry way.

### kappman — the PaaS console

**kappman** is a web application-manager UI for the Korifi platform: browse orgs/spaces and apps,
explore the service marketplace with per-service documentation, and create/bind services from the
browser. It itself runs *as an app on the platform* — a real example of the PaaS hosting its own tools.

---

## CaaS — the container platform

- **Kubernetes (K3s):** a lightweight, fully-conformant cluster that hosts every workload. Single-node
  by default, with room to grow to multiple nodes.
- **ArgoCD (GitOps):** the entire stack is described declaratively and reconciled from Git using the
  App-of-Apps pattern — the cluster continuously converges to the desired state, and changes are made
  by committing, not by clicking.
- **Portainer:** a management UI for those who want to inspect and operate workloads directly.

---

## DevOps stack — the platform services

Everything a real platform needs to be operable and secure, integrated out of the box:

| Capability | Component | What it provides |
|---|---|---|
| **Credential management** | OpenBao + External Secrets Operator | Central secrets vault; secrets are synced into the cluster on demand and **never stored in Git** |
| **Artifact registry** | artifact-keeper | Private registry for container/OCI images, Helm charts, and generic artifacts, with built-in vulnerability scanning — the single source for every image the platform runs |
| **Object storage** | Garage (S3-compatible) | The shared S3 backend for backups, observability data, and app buckets |
| **Platform backup** | Velero | Scheduled, restorable backups of cluster state and persistent volumes into S3 |
| **DNS** | Technitium | Internal DNS zones and resolution, with a management UI |
| **Networking** | Software load balancer + ingress/gateway | Stable cluster IPs and host-based routing for every service and app |
| **TLS / certificates** | cert-manager + Let's Encrypt | Real, automatically-renewed **wildcard certificates** via DNS-01 — no self-signed warnings |
| **Observability** | Grafana + Loki + Mimir + Tempo + collectors | Unified metrics, logs, and traces with dashboards, backed by S3 |
| **Git & CI/CD** | GitLab CE + Runner | Self-hosted source control and pipelines, with runners that build on the cluster |

### How the pieces reinforce each other

- **One image source:** every component pulls from **artifact-keeper**, making the platform
  reproducible and portable across machines and networks.
- **One secret source:** **OpenBao** holds all credentials; **External Secrets** projects them where
  needed — DNS provider keys, registry pulls, service credentials.
- **One storage backend:** **Garage** S3 serves backups (Velero), observability (Loki/Mimir/Tempo),
  the artifact registry, and developer buckets.
- **Real certificates everywhere:** platform services and apps both get trusted wildcard TLS.

---

## Architecture & design principles

- **GitOps-first:** the desired state lives in this repository; ArgoCD makes it real. Operational
  changes are commits, not console clicks.
- **Apple Silicon native:** runs in a Linux VM via macOS Virtualization.framework, with ARM64 images
  throughout. Targeted at modern Apple Silicon Macs with ample RAM.
- **Portable networking:** a NAT-based virtual network with a software load balancer means the
  platform travels between Wi-Fi networks without reconfiguration.
- **Private by default:** all images come from the internal registry; secrets stay in the vault.
- **Two cooperating planes:**
  - the **local platform plane** — the Kubernetes stack on the developer's Mac, and
  - the **shared services plane** — a remote artifact-keeper registry (plus supporting edge, secrets,
    and monitoring services) that distributes images and installers to colleagues, so an entire team
    can stand up identical platforms.

---

## Repository layout

```
k8/
├── config.env          # Network, registry, domain, and architecture configuration
├── stack.sh            # Master lifecycle script: start / stop / status / restart / backup
├── set-arch.sh         # Switch image architecture (arm64/amd64) across all charts
├── bootstrap/          # One-time setup: VM + Kubernetes + GitOps
├── infrastructure/     # Load balancing, ingress, certificates
├── platform/           # GitOps, management UI, object storage, DNS, secrets, backup
├── monitoring/         # Metrics, logs, traces, dashboards
├── services/           # Vault, artifact registry, Git, and service brokers
├── apps/               # Application workloads (e.g. kappman)
├── velero/             # Backup configuration and schedules
└── docs/               # Specifications and operational guides
distribution/           # Lean, repeatable installer package for any Apple Silicon Mac
demos/                  # Example applications (e.g. a Spring Boot PetClinic)
plans/                  # Design and implementation plans
```

---

## Getting started

The platform is deployed in ordered phases — foundation, container platform, monitoring, services,
Git, Cloud Foundry, and the service brokers — and is managed from a single script.

```bash
# Bring the whole platform up (and check its health)
./k8/stack.sh start
./k8/stack.sh status

# Take a backup, or stop the platform
./k8/stack.sh backup
./k8/stack.sh stop
```

For a guided first install on a fresh machine, use the **distribution installer** (an `installer.sh`
plus a packaged stack archive) which runs pre-flight checks and walks through configuration. See
[`GETTING_STARTED.md`](GETTING_STARTED.md) for the full walkthrough, and `k8/docs/` for design
specifications and day-2 operations.

---

## In one sentence

> A reproducible, GitOps-driven private cloud on a single Mac: a Cloud Foundry developer experience
> (Korifi) with a self-service service marketplace and the **kappman** console, on a Kubernetes +
> ArgoCD container platform, backed by a complete DevOps stack for secrets, artifacts, storage,
> backup, DNS, networking, real certificates, and observability.
