# Stack-Wide Upgrade — Planning & Scope

> **Status:** Scoping / planning entrypoint. **Collect & plan only — no implementation yet.**
> **Goal:** Coordinate a controlled upgrade of the *entire* DevOps platform — Lima VM → K3s
> → all in-cluster components → Go service brokers → Spring Boot apps/kappman → the **remote
> artifact-keeper** developer-platform server — without breaking any component of this repository.
> **Last inventory:** 2026-06-04 (versions below reflect what is currently pinned in this repo).
>
> **Decisions locked (2026-06-04):**
> 1. **Scope = latest everywhere** — bump every component to current latest stable.
> 2. **Spring Boot / Spring apps follow separately** — a full Spring update week happens *next week*;
>    kappman + petclinic (the Boot/Java/buildpack triple) are a **deferred follow-up wave**, planned
>    here but implemented after the Spring release. Remember: Spring apps trail the platform upgrade.
> 3. **artifact-keeper = patch-rebase + a re-platform, not a plain bump** — upstream is now **v1.2.0**,
>    but we run `v1.1.0-rc.8-**patched**` with our own custom patches. Both the in-cluster images *and*
>    the remote registry app must move to **1.2.0 with our 5 patches reconciled** (several likely now
>    upstream → drop). **⚠️ v1.2.0 also REMOVES Meilisearch in favor of OpenSearch 2.x** — this is the
>    biggest single item in the whole campaign (search-backend swap + reindex in *both* planes). See
>    Chapter 2 → "artifact-keeper patch reconciliation". Treat as its own mini-project.
> 4. **Unpinned components → pin-to-current first, then upgrade** (K3s, Reflector, CloudNativePG,
>    RabbitMQ Operator): capture exact running versions from the live cluster, commit, *then* bump.
> 5. **Plane B `otel/` LGTM aligned to in-cluster** monitoring versions.

This document is the single source of truth for the upgrade campaign. Chapter 1 is the
**complete component & dependency inventory** (the "what we must care about"). Later chapters
will hold the ordering, risk analysis, and per-component upgrade procedures (to be filled in
once we agree on target versions).

---

## Chapter 1 — Component & Dependency Inventory

Everything that exists in this repo and must be considered before touching a single version.
The platform is **two physically separate planes**:

- **Plane A — Local K3s stack** (this is what `installer.sh` / `stack.sh` deploys into the Lima VM).
- **Plane B — Remote developer-platform server** (Docker-Compose stacks under the repo root:
  `artifactory/`, `otel/`, `router/`, `vault/`) — this is the **remote artifact-keeper** and its
  surrounding edge/monitoring/secrets services that serve colleagues. Every image and artifact the
  local stack consumes is pulled from here, so **Plane B must be upgraded with extreme care and
  generally *first* for shared images, *last* for the registry app itself**.

### 1.0 — Cross-cutting concerns (read before anything)

| Concern | Detail | Why it matters for the upgrade |
|---|---|---|
| **Architecture suffix** | All images tagged `-arm64` (`ARCH=arm64` in `k8/config.env`). `k8/set-arch.sh` rewrites all `values.yaml`. | Every new image we mirror must exist as ARM64 and be re-tagged `-arm64`. |
| **Private registry** | All images pulled from `artifactory.cfapps.cool/docker-local/` via pull secret `artifact-keeper-pull`. | A new version is unusable until it is **mirrored into the remote artifact-keeper**. This is the gating step for *every* image bump. |
| **Chart = App version rule** | CLAUDE.md: "Helm chart versions must exactly match app versions — mismatches cause silent failures." | Every Helm bump must move chart *and* image together. |
| **TLS / IngressRoute split** | Platform svcs use default TLSStore (`*.development.cfapps.cool`); app svcs use `wildcard-apps-tls` (`*.app.cfapps.cool`). | cert-manager / Traefik upgrades can break wildcard issuance. |
| **Secrets via ESO** | No secrets in Git; OpenBao → ESO → K8s Secrets. | OpenBao / ESO upgrades can desync every dependent secret. |
| **Storage = local-path** | No CSI snapshots; Velero uses Restic/Kopia. | StatefulSet image bumps (Postgres, GitLab, OpenBao, Garage) need data-migration care + a fresh Velero backup first. |
| **Distribution artifacts** | `build-distribution.sh` → `dist/installer.sh` + `dist/stack.tgz`, uploaded to the remote generic repo with a version suffix. | Any repo change must be re-packaged and re-uploaded; bump version (currently **v1.1.2**). |

### 1.1 — Plane A · Foundation (Lima VM + K3s)

| # | Component | Current | Pinned in | Notes / dependents |
|---|---|---|---|---|
| 1 | **Lima VM** | Ubuntu 24.04 ARM64, vz, 8 CPU / 48 GiB / 200 GiB | `k8/bootstrap/lima.yaml`, `k8/config.env` | vzNAT `192.168.64.0/24`. Base of everything. Guest-OS / Lima upgrade is the riskiest single step. |
| 2 | **K3s** | **unpinned** (`curl -sfL https://get.k3s.io`) | `k8/bootstrap/install-k3s.sh` | `--disable traefik,servicelb`. local-path at `/data/persistent`. **Must pin a version** before upgrading — currently floating. Drives the entire K8s API surface every chart depends on. |
| 3 | **Kubernetes Reflector** | **unpinned** (`helm install ... emberstack/reflector`) | `k8/distribution/install.sh:1163` | Cross-namespace secret reflection. Should be pinned. |

> ⚠️ Two **unpinned** components (K3s, Reflector). First action item: pin both so upgrades are deterministic.

### 1.2 — Plane A · Infrastructure

| Component | Image / App | Helm chart | Pinned in | Dependents |
|---|---|---|---|---|
| **MetalLB** | v0.15.3 | 0.15.3 | `k8/infrastructure/metallb/{Chart,values}.yaml` | LoadBalancer IPs for Traefik + GitLab SSH. |
| **Traefik** | v3.6.10 | 39.0.5 | `k8/infrastructure/traefik/{Chart,values}.yaml` | Ingress for every platform service; TLSStore. |
| **cert-manager** | v1.20.0 | 1.20.0 | `k8/infrastructure/cert-manager/{Chart,values}.yaml` | Wildcard certs via GCP Cloud DNS DNS-01. CRDs auto-installed. |

### 1.3 — Plane A · Platform

| Component | Image / App | Helm chart | Pinned in | Dependents |
|---|---|---|---|---|
| **ArgoCD** | v3.3.4 (redis 8.2.3) | 9.4.15 | `k8/platform/argocd/{Chart,values}.yaml` | Installed as a component, but **not** managing the stack (0 Application CRs — stack is Helm-managed). Upgrade like any other Helm release. |
| **External Secrets (ESO)** | v0.16.1 | 0.16.1 | `k8/platform/external-secrets/{Chart,values}.yaml` | Backed by OpenBao; feeds all secrets incl. registry pull secret. CRDs auto-installed. |
| **Portainer** | 2.39.1 (app 2.39.0) | 239.0.2 | `k8/platform/portainer/{Chart,values}.yaml` | Management UI. |
| **Garage (S3)** | v2.2.0 | (raw manifest, StatefulSet) | `k8/platform/garage/deployment.yaml:24` | **S3 backend for Velero, Loki, Mimir, Tempo, artifact-keeper.** High blast radius. |
| **Technitium DNS** | 14.3.0 | (raw manifest) | `k8/platform/technitium/deployment.yaml:21` | Internal DNS zones. |
| **Velero** | v1.18.0 (AWS plugin v1.14.0) | 12.0.0 (local `charts/velero`) | `k8/velero/{Chart,values}.yaml` | Backups → Garage. **Take a backup with the current version before any StatefulSet upgrade.** |
| **Velero UI** | 0.10.1 (**no -arm64 suffix**) | (raw) | `k8/velero/ui/values.yaml:3` | Only non-arch-tagged image — verify ARM64 manifest on bump. |

### 1.4 — Plane A · Secrets

| Component | Image / App | Helm chart | Pinned in | Dependents |
|---|---|---|---|---|
| **OpenBao** | 2.5.1 | 0.8.0 | `k8/services/openbao/{Chart,values}.yaml` | Standalone, TLS off. **Root of trust** — ESO + every secret depends on it. Unseal keys live in a password manager. Upgrade = backup + careful unseal dance. |

### 1.5 — Plane A · Monitoring (LGTM)

| Component | Image / App | Helm chart | Pinned in | Notes |
|---|---|---|---|---|
| **Grafana** | 12.4.1 | 10.5.15 | `k8/monitoring/grafana/{Chart,values}.yaml` | Dashboards/datasources. |
| **Loki** | 3.6.7 | 6.55.0 | `k8/monitoring/loki/{Chart,values}.yaml` | Garage bucket `loki-chunks`. |
| **Mimir** | 3.0.4 | **raw Deployment** (not mimir-distributed) | `k8/monitoring/mimir/deployment.yaml:20` | Garage bucket `mimir`. |
| **Tempo** | **2.9.0 running** / chart appVersion **2.10.3** ⚠️ | 1.24.4 | `k8/monitoring/tempo/{Chart,values}.yaml` | Garage bucket `tempo`. **Existing version mismatch — reconcile during upgrade.** |
| **Alloy** | v1.14.1 | 1.6.2 | `k8/monitoring/alloy/{Chart,values}.yaml` | DaemonSet collector. |
| **kube-state-metrics** | v2.18.0 | 7.2.2 | `k8/monitoring/kube-state-metrics/{Chart,values}.yaml` | Tracks K8s API objects → recheck on K3s bump. |
| **node-exporter** | v1.10.2 | 4.52.2 | `k8/monitoring/node-exporter/{Chart,values}.yaml` | Host metrics. |

### 1.6 — Plane A · Services (artifact-keeper in-cluster + GitLab)

| Component | Image / App | Pinned in | Dependents |
|---|---|---|---|
| **artifact-keeper backend** | v1.1.0-rc.8-**patched** → target **1.2.0+patches** | `k8/services/artifact-keeper/artifact-keeper/deployment.yaml:48` | Needs Postgres + Meilisearch + Garage S3. **Upstream is now 1.2.0; we carry custom patches — rebase patches onto 1.2.0, drop any now-upstream.** Same image must be re-mirrored to Plane B. |
| **artifact-keeper web** | v1.1.0-rc.8-**patched** → target **1.2.0+patches** | `.../deployment-web.yaml:22` | UI for above. Same patch-rebase concern. Upstream web CHANGELOG last seen at 1.1.0-rc.4. |
| **PostgreSQL (a-k)** | 17.9 | `.../postgresql/statefulset.yaml:23` | StatefulSet — major-version bumps need `pg_upgrade`/dump. |
| **Meilisearch** | v1.39.0 | `.../meilisearch/deployment.yaml:24` | **⚠️ REMOVED in artifact-keeper 1.2.0 → replaced by OpenSearch 2.x.** Not a bump — a search-backend swap + full reindex. Heavier (JVM) → recheck VM RAM. |
| **Trivy Scanner** | 0.69.3 | `.../trivy/deployment.yaml:22` | Vuln DB; benign to bump. |
| **GitLab CE** | 18.10.0-ce.0 | `k8/services/gitlab-ce/statefulset.yaml:23` | StatefulSet (data/config/logs). **One-minor-at-a-time upgrade path required** — never skip minors. |
| **GitLab Runner** | alpine-v18.10.0 | chart 0.87.0 · `k8/services/gitlab-ce/runner/{Chart,values}.yaml` | K8s executor in `gitlab-runner-jobs`; auto-registered via `install.sh`. Keep within one minor of GitLab CE. |

### 1.7 — Plane A · Apps (Korifi / Cloud Foundry stack)

| Component | Current | Pinned in | Notes |
|---|---|---|---|
| **Korifi** | v0.18.0 (Helm tgz) | `k8/distribution/install.sh:2228/2234` | CF-on-K8s: api, controllers, kpack-image-builder, statefulset-runner. Depends on Contour gateway + kpack + cert-manager. |
| **kpack** | 0.17.0 (ARM64, self-built) | `k8/services/kpack/build-arm64.sh:17`, `install.sh:2042` | **Go 1.24 self-build** (see 1.9). Builds app images. lifecycle pinned dynamically. |
| **Contour** | v1.33.2 | `install.sh:1995-1999` | Gateway API for Korifi routes. |
| **Envoy** | distroless-v1.35.9 | `install.sh:1998` | Ships with Contour quickstart. |
| **Service Binding Runtime** | 1.0.0 | `install.sh:2090` | Korifi service bindings. |
| **Paketo Java buildpack** | **21.4.0 (pinned)** | `install.sh:2208`, `k8/services/kpack/mirror-buildpacks.sh` | Pinned for Spring Boot 4.x (see memory). Other buildpacks (nodejs/ruby/go/php/httpd/procfile) = `latest`. |
| **Paketo stacks** | build/run-jammy-full:latest | `install.sh:2215-2216` | ClusterBuilder `cf-kpack-cluster-builder`. |

> **Known blocker (carry forward):** petclinic CF push is blocked by Paketo ca-certificates scanning
> Korifi binding mounts; `BPL_SPRING_CLOUD_BINDINGS_DISABLED=true` is the current workaround. Revisit
> when bumping the Java buildpack off 21.4.0.

### 1.8 — Plane A · Service Brokers & Operators (Phase 7)

| Component | Current | Pinned in | Notes |
|---|---|---|---|
| **CF Service Broker** (Go) | image 1.4.0-arm64 | `k8/services/cf-service-broker/` | Brokers postgresql/valkey/rabbitmq/s3. See 1.9. |
| **CF Marketplace Broker** (Go) | image 1.0.0-arm64 | `k8/services/cf-marketplace-broker/` | Brokers postgres-ai/openbao-secrets/ai-connector. See 1.9. |
| **CloudNativePG** | **unpinned** (`helm install cnpg/cloudnative-pg`) | `install.sh:2547-2548` | Operator for brokered Postgres (PG 18 / PG 17-AI). **Pin it.** |
| **RabbitMQ Cluster Operator** | **unpinned** (`releases/latest`) | `install.sh:2557` | Operator for brokered RabbitMQ. **Pin it.** |
| **Valkey** | 8.1-alpine | `cf-service-broker/src/main.go:34` (env `VALKEY_IMAGE`) | Provisioned per-instance. |

> Two more **unpinned** operators (CloudNativePG, RabbitMQ). Both must be pinned before upgrade.

### 1.9 — Go components we build ourselves (must rebuild + re-mirror)

These are **first-party Go binaries** — upgrading the toolchain or deps means rebuild, re-tag `-arm64`, push to remote artifact-keeper, redeploy.

| Module | Path | Go | Key deps | Builds |
|---|---|---|---|---|
| `github.com/cfapps/cf-service-broker` | `k8/services/cf-service-broker/src/go.mod` | **1.26.1** | brokerapi/v11 v11.0.16, k8s.io v0.35.3 | broker image 1.4.0 (Dockerfile `golang:1.26` → distroless static nonroot) |
| `github.com/cfapps/cf-marketplace-broker` | `k8/services/cf-marketplace-broker/src/go.mod` | **1.26.1** | brokerapi/v11 v11.0.16, k8s.io v0.35.3 | broker image 1.0.0 |
| `.../cf-marketplace-broker/test` | `.../test/go.mod` | 1.26.1 | lib/pq | integration tests |
| `github.com/pivotal/kpack` (vendored/self-built) | `k8/services/kpack/src/go.mod` | **1.24** (toolchain 1.24.1) | lifecycle v0.20.3, go-containerregistry v0.20.2, k8s.io v0.30.11 | kpack ARM64 binaries (controller/webhook/build-init/...) |

> ⚠️ The brokers pin `k8s.io v0.35.3` (≈ K8s 1.35) but kpack pins `k8s.io v0.30.11` (≈ K8s 1.30).
> **The running K3s version must stay compatible with both client-go lines** — this is a key
> constraint when choosing the target K3s version.
> Also note `artifactory/source/backend/.assets/go/go.mod` (module `test-package`, Go 1.22) — a build asset, low priority.

### 1.10 — Spring Boot / JVM apps

| App | Spring Boot | Kotlin | Java | Build | Deploy | Pinned in |
|---|---|---|---|---|---|---|
| **kappman** (Korifi App Manager) | **4.0.3** | 2.3.10 | 25 (temurin) | Gradle | `cf push` (Paketo java, `BP_JVM_VERSION=25`) → `kappman.app.cfapps.cool` | `k8/apps/kappman/build.gradle.kts`, `manifest.yml`, `Dockerfile` |
| **petclinic** (demo) | **4.0.4** | 2.3.10 | 25 | Gradle | `cf push` (Paketo java) → `petclinic.app.cfapps.cool` | `demos/petclinic/build.gradle.kts`, `manifest.yml` |

kappman deps of note: `java-cfenv-boot:4.0.0`, Flyway + flyway-database-postgresql, Spring Security/JPA, CloudNativePG `kappman-db`, CF admin RoleBindings (`korifi` ns; refresh via `stack.sh:1180`). petclinic also pulls Spring AI `2.0.0-M3`.

> Spring Boot 4.x ⇄ Java 25 ⇄ Paketo Java 21.4.0 are a **locked triple**. Don't bump one without the others.

### 1.11 — Plane B · Remote developer-platform server (Docker-Compose, repo root)

This is the **remote artifact-keeper** the user maintains for colleagues. Four independent compose stacks; each has its own `start.sh`/`stop.sh`/`backup.sh`. **Not** ARM-suffixed (server-side), **not** part of `stack.tgz` (excluded by `build-distribution.sh`).

| Stack | Dir | Images | Role | Upgrade caution |
|---|---|---|---|---|
| **artifact-keeper** (remote registry) | `artifactory/` | backend (Rust/Axum), web (Next.js 15), **PostgreSQL 18**, Meilisearch, Trivy+Grype, nginx:alpine | THE registry every `-arm64` image is pulled from; generic repo serves `installer-*.sh`/`stack-*.tgz`. Backend CHANGELOG at 1.1.0-rc.8 (2026-03-17). | **→ target 1.2.0 + our patches** (see locked decision #3). **Upgrade last & with a full `scripts/backup.sh` first.** If it's down, the whole local stack can't pull. PG 18 already. 663 MB backup zip present. |
| **OTEL / LGTM** | `otel/` | Mimir 2.15.0, Loki 3.4.2, Tempo 2.7.2, Grafana 11.5.2, otel-collector 0.120.0 | Remote monitoring (OpenBao + HAProxy dashboards). | **Align to in-cluster** (Loki 3.6.7 / Mimir 3.0.4 / Tempo target / Grafana 12.4.1) per decision #5. Note server-side (no `-arm64`). |
| **Edge router** | `router/` | haproxy:3.1-alpine, otel-collector 0.120.0 | TLS/edge routing in front of the remote services. | Front door — upgrade in a window; certs via its own config. |
| **OpenBao (remote)** | `vault/` | openbao/openbao:2.5.1, postgres:18, nginx:alpine, certbot/certbot:latest, otel-collector 0.120.0 | Remote secrets + Certbot TLS. | Matches in-cluster OpenBao 2.5.1 — keep them aligned. Backup zip `openbao-vault-2.5.1.zip` present. |

### 1.12 — Distribution & packaging (must be re-cut after any change)

| Artifact | Source | Current | Notes |
|---|---|---|---|
| `installer.sh` (host bootstrap) | `installer.sh` (root) | banner "v1.0" | Pre-flight: macOS 26.0+, M4+, 64 GB RAM, 500 GB disk; tools incl. **Go 1.26**, crane, CF CLI, Helm, kubectl. |
| `k8/distribution/install.sh` | in-tree | display "V1.0.0" | The big phased installer (Phases 1–8) — every pinned version above ultimately flows through here. |
| `dist/installer.sh` + `dist/stack.tgz` | `build-distribution.sh` | **v1.1.2** | Packs `k8/` + `demos/` + `GETTING_STARTED.md`; excludes Plane B dirs, `.env`, `.git`. Upload to remote generic repo with version suffix. |
| Upgrade notes | `UPGRADE-v1.1.2.md` | v1.1.2 | Per-release upgrade guide pattern (keep this convention). |

---

## Dependency & ordering map (for later chapters)

Upgrade waves implied by the above (top = do first):

```
Plane B shared images first ──► (mirror new -arm64 images into remote artifact-keeper)
        │                         this is the prerequisite for EVERY Plane A image bump
        ▼
1. Lima VM / guest OS                 (host window; snapshot VM first)
2. K3s  (PIN IT)                      (gates client-go: brokers@1.35 vs kpack@1.30)
3. Reflector (PIN) ─ MetalLB ─ Traefik ─ cert-manager
4. OpenBao  ──► ESO                   (root of trust; backup + unseal plan)
5. Garage  (S3 backend)              ──► Loki / Mimir / Tempo / Velero / artifact-keeper
6. ArgoCD, Portainer, Technitium, Velero(+UI)
7. Monitoring (Grafana/Loki/Mimir/Tempo/Alloy/KSM/node-exporter) — fix Tempo 2.9.0↔2.10.3 drift
8. artifact-keeper (in-cluster) + Postgres 17.9 + Meilisearch + Trivy
9. GitLab CE (one minor at a time) + Runner
10. Contour/Envoy ─ kpack (Go 1.24 rebuild) ─ Korifi ─ buildpacks/stacks
11. CloudNativePG (PIN) ─ RabbitMQ Operator (PIN) ─ Valkey
12. Go brokers (rebuild Go 1.26, re-mirror, redeploy)
13. Re-cut distribution (bump version) ─► upload to remote generic repo
14. Plane B: align `otel/` LGTM, upgrade `router/` + remote OpenBao, then **remote artifact-keeper → 1.2.0+patches LAST** (full backup first)
15. **[DEFERRED — next week]** Spring apps wave: kappman + petclinic (Boot/Java/buildpack locked triple), after the upstream Spring update week
```

## Decisions made & remaining inputs for Chapter 2

**Locked (see header):** scope = latest everywhere · Spring apps = deferred follow-up wave ·
artifact-keeper = rebase patches onto 1.2.0 · 4 unpinned = pin-to-current-then-upgrade ·
Plane B `otel/` = align to in-cluster.

**Still to determine when we write target versions:**
1. **Target K3s line** — must satisfy both broker client-go (v0.35.x) and kpack client-go (v0.30.x).
   Pick the K8s minor, then verify kpack supports it (may force a kpack bump → Go bump). This is the
   linchpin for the whole "latest everywhere" plan.
2. **artifact-keeper patch reconciliation** — diff our `v1.1.0-rc.8-patched` against upstream 1.2.0;
   classify each patch as (a) now upstream → drop, (b) still needed → re-apply, (c) obsolete. Needs
   the patch list / source under `artifactory/source/`.
3. **Backup/rollback gate** — Velero backup + Plane B `backup.sh` + Lima VM snapshot are mandatory
   pre-steps for each StatefulSet/registry wave. Define the rollback checkpoint per wave.
4. **Spring wave timing** — confirm exact target Boot/Java/Paketo-Java versions once next week's
   Spring release lands; revisit the petclinic ca-certificates binding-mount blocker then.

---

## Chapter 2 (partial) — Target Kubernetes line & client-go compatibility

> Research completed 2026-06-04 (web sources at end). This settles the linchpin question:
> *which K3s/K8s line can we run such that the Go brokers, Korifi, and kpack all function.*

### The three client-go anchors we must satisfy

| Component | We control it? | client-go (current) | Go | Source |
|---|---|---|---|---|
| **cf-service-broker / cf-marketplace-broker** | **Yes** (self-built) | **v0.35.3** (~K8s 1.35) | 1.26.1 | our `go.mod` |
| **Korifi** v0.18.0 (latest) | No (upstream) | **v0.35.2** (~K8s 1.35), imports `pivotal/kpack v0.17.1` | 1.25.7 | korifi v0.18.0 `go.mod` |
| **kpack** | Partly (we self-build ARM64 from src) | **v0.30.11** (~K8s 1.30) in our src / **0.34.3** on upstream `main`, but newest *release* v0.17.1 is still ~0.30 | 1.24 | our src + upstream |

### Landscape (latest available, June 2026)

- **K3s latest = v1.36.x** (K8s 1.36 GA 2026-04-22; latest patch ≥ v1.36.1+k3s1, 2026-05-13). Actively supported K8s minors: **1.34 / 1.35 / 1.36**.
- **client-go official skew policy:** a client is supported only **within ±1 minor** of the kube-apiserver.
- **Korifi latest = v0.18.0** — we are **already on it**; no Korifi bump needed. It uses client-go 0.35.2 → in-policy for 1.34–1.36.
- **kpack latest *release* = v0.17.1** (Dec 2024), still on client-go ~0.30. kpack `main` has moved to **client-go 0.34.3 / Go 1.24.5** but is **unreleased** — there is **no kpack release within ±1 of K8s 1.36**. (kpack v0.17.0+ also moved its images to **ghcr.io** — relevant to our mirroring step.)

### The core finding

**Strict "everything inside the official ±1 client-go skew" is NOT achievable** with today's released
components: the brokers want apiserver ≥ 1.34 (client-go 0.35), while the newest kpack *release*
(0.17.1, client-go ~0.30) is only in-policy up to ~K8s 1.31. Those windows don't overlap. So the
target is a **practical** compatibility decision, not a policy-clean one.

This is acceptable because **kpack only touches ultra-stable APIs** (pods, secrets, configmaps,
serviceaccounts + its own `*.kpack.io` CRDs), which is why it already runs today against our
**unpinned/floating K3s (currently ~1.36) on client-go 0.30** without issue. Wide skew is a real
support-policy gap but a low *practical* risk for kpack specifically.

### Recommendation — **target K3s v1.36.x (latest patch, pinned)**

Rationale:
1. Satisfies the locked "latest everywhere" decision.
2. **Brokers** (client-go 0.35.3, easily bumped to 0.36 since we build them on Go 1.26) → within ±1 of 1.36 ✓.
3. **Korifi v0.18.0** (client-go 0.35.2) → within ±1 of 1.36 ✓, and already latest.
4. **kpack** is the only out-of-policy piece — but it's pinned to 0.17.1 *by Korifi anyway*, uses only stable APIs, and already runs at higher skew today. Net skew actually **improves** vs the current floating state once we pin.

**kpack handling under this target (do all three):**
- Bump our self-built kpack **0.17.0 → 0.17.1** (matches Korifi v0.18.0's pinned kpack, picks up lifecycle 0.20.12 + the **ghcr.io** image source for mirroring).
- **Pin K3s** to a specific 1.36 patch (stop floating) so the skew is known and stable.
- **Track upstream** `buildpacks-community/kpack` for the first tagged release > 0.17.1 carrying client-go ≥ 0.34; adopt it when it lands to close the policy gap. (Optionally we *could* rebuild 0.17.x src with a bumped client-go ourselves since we own the src tree, but that diverges from what Korifi tests against — only do it if a real skew bug appears.)

**Conservative fallback — K3s v1.35.x:** if we want every first-party + Korifi client *exactly* in
policy, 1.35 makes brokers (0.35) and Korifi (0.35) an exact match and leaves only kpack out of
policy (same as always). This is the lower-risk choice but is one minor behind "latest." Recommend
1.36.x unless a 1.36-specific incompatibility surfaces during the monitoring/Korifi waves.

### Go toolchains (align during rebuilds)

Brokers Go 1.26.1 · Korifi Go 1.25.7 · kpack Go 1.24(.5) · installer requires Go 1.26. No conflict;
keep brokers on Go 1.26.x, leave kpack on the Go version its release ships with.

#### Sources
- K3s releases / 1.35 & 1.36: <https://docs.k3s.io/release-notes/v1.36.X>, <https://github.com/k3s-io/k3s/releases>, <https://docs.k3s.io/blog/2026/01/15/K3s-1.35-release>
- Kubernetes version-skew policy: <https://kubernetes.io/releases/version-skew-policy/>, <https://kubernetes.io/releases/>
- kpack releases & go.mod (main → client-go 0.34.3): <https://github.com/buildpacks-community/kpack/releases>, <https://github.com/buildpacks-community/kpack/blob/main/go.mod>
- Korifi v0.18.0 go.mod (client-go 0.35.2, pivotal/kpack v0.17.1): <https://github.com/cloudfoundry/korifi/releases>

## Chapter 2 (partial) — Should we fork kpack for K8s 1.36?

**Short answer: no — a hard fork is the wrong tool here.** It would solve a *policy* gap, not a
*functional* one, and it's both harder and lower-value than it looks.

Why not:
1. **No real failure to fix.** kpack only uses ultra-stable APIs (pods/secrets/configmaps/SAs + its
   own `*.kpack.io` CRDs). It already runs against our floating ~1.36 cluster today. The 1.36 problem
   is a support-policy skew, not a broken integration.
2. **Korifi pins kpack for us anyway.** Korifi v0.18.0 depends on `github.com/pivotal/kpack v0.17.1`
   as a Go library — its kpack-image-builder is compiled against the 0.17.1 API types. A divergent
   fork risks CRD/type drift against what Korifi expects, so we're effectively constrained to the
   0.17.x CRD surface regardless.
3. **The dependency bump is real work and upstream hasn't finished it either.** kpack's own `main` has
   only reached **client-go 0.34.3 / Go 1.24.5** (still 2 minors behind 1.36) despite 1.36 being out
   ~2 months — it's bounded by its `knative.dev/pkg` dependency (which vendors matching k8s libs) and
   the porting effort. A fork jumping 0.30→0.36 would have to do dependency surgery (incl. a
   knative.dev/pkg that supports 0.36, which may not exist yet) that upstream itself hasn't shipped.
4. **Perpetual maintenance.** A fork means we own every future rebase — security fixes, lifecycle
   bumps, the ghcr.io migration. For a single-maintainer, colleague-facing platform that's a bad trade.

Better options, in order of preference:

| Option | What | Skew vs 1.36 | Maintenance | When |
|---|---|---|---|---|
| **A. Release + pin + watch** *(recommended)* | Build kpack **0.17.1** (matches Korifi), pin K3s to a 1.36 patch, watch `buildpacks-community/kpack` releases; adopt the first release with client-go ≥0.34 when it ships. | ~6 minors (works in practice) | none | now |
| **B. Track upstream `main`** | We already self-build ARM64 from src — build from a *pinned `main` commit* (client-go 0.34.3) instead of a tag. This is "vendor newer source," **not a fork** (no divergent patches). | ~2 minors | low (bump commit) | if we want the gap smaller; verify Korifi 0.18.0 still accepts main's CRDs |
| **C. Drop to K3s 1.35** | Conservative target line; brokers + Korifi become exact-match, kpack unchanged. | kpack only, as always | none | if a 1.36-specific issue appears |
| **D. Minimal fork** | Only if a *real* 1.36 incompatibility appears **and** upstream is unresponsive: fork, bump only the deps, upstream the PR, retire the fork once merged. | 0 | high (temporary) | last resort |

**Recommendation:** Option **A** now (it strictly improves on today's floating state), keep **B** in
the back pocket if we want to shrink the skew, and treat a fork (**D**) as a last resort tied to an
actual bug — not a preemptive project.

---

## Chapter 2 (partial) — artifact-keeper patch reconciliation onto v1.2.0

> Investigated 2026-06-04. **Good news:** the "patched" build is clean and reproducible — a
> clone→patch→build→push pipeline driven by discrete patch files. **Bad news:** v1.2.0 is **not a
> version bump, it's a re-platform** (see ⚠️ below).

### How our patched build actually works

- `artifactory/source/backend` and `.../web` are **upstream git checkouts**
  (`github.com/artifact-keeper/artifact-keeper{,-web}.git`); the parent `andrlange/artifactory` repo
  tracks only our **patch files** + the build pipeline.
- `artifactory/scripts/build-containers.sh`: `clone` does `git clone --branch <REF>` then
  `git apply` each `source/patches/{backend,web}/*.patch`; image tag is auto-derived as
  **`<upstream-git-tag>-patched`** (so a v1.2.0 checkout produces `1.2.0-patched` automatically).
- So "rebase onto 1.2.0" = point `BACKEND_REF`/`WEB_REF` at the **v1.2.0** tags, re-apply the 5
  patches, fix the ones that no longer apply, rebuild, re-mirror.

### The 5 patches and their likely fate on v1.2.0

| Patch | What it does | Likely status on 1.2.0 | Action |
|---|---|---|---|
| **be/001** `fix-token-list-revoked-filter` | adds `AND revoked_at IS NULL` to token list query (token_service.rs) + sqlx cache | token area reworked upstream (v1.1.9 "refresh-token rotation via JTI blocklist", credential invalidation) → **likely upstream or code moved** | try apply; if fails, verify upstream behavior → **probably drop** |
| **be/002** `fix-user-tokens-list-revoked-filter` | same filter in users.rs handler + sqlx cache | same as above | same → **probably drop** |
| **be/003** `add-api-token-support-for-docker-v2-token` | accept API token as password in `docker login` Basic Auth on `/v2` token endpoint (oci_v2.rs) | v1.2.0 adds **"Repository-scoped access token management"** → feature area changed; may now be native | **rebase carefully**; may become partly/fully upstream |
| **web/001** `fix-permissions-target-select` | permissions page: target as repo dropdown vs text field | UI; uncertain | try apply; rebase if needed |
| **web/002** `fix-select-in-dialog-z-index` | z-index fix + drops `listScanConfigs` SDK import | adapts to SDK shape; SDK likely changed in 1.2.0 | **likely needs rebase** |

> The clean test for each patch: `git apply --3way` against the v1.2.0 checkout. Clean apply → keep.
> Reject → either the fix is upstream (drop it) or the code moved (manual rebase). Backend patches
> also ship `.sqlx/*.json` query-cache files — after rebasing, **regenerate with `cargo sqlx prepare`**
> against the 1.2.0 schema or the offline build will fail.

### ⚠️ The big one: v1.2.0 removes Meilisearch in favor of OpenSearch 2.x

This is the dominant cost of the artifact-keeper upgrade, **far bigger than the patch rebase**:

- **Plane A (in-cluster):** `k8/services/artifact-keeper/meilisearch/` must be **replaced by OpenSearch
  2.x** — new Deployment/StatefulSet (+ PVC, +heap/JVM sizing), new env wiring on the backend
  (`MEILI_*` → OpenSearch endpoint/creds), and the init container in `deployment.yaml` that probes
  Meilisearch. Search index must be **rebuilt/reindexed** (not migrated). OpenSearch is heavier (JVM)
  than Meilisearch — recheck Lima VM RAM headroom (48 GiB).
- **Plane B (remote registry):** `artifactory/docker-compose.yml` Meilisearch service → OpenSearch 2.x
  + its `.env` wiring + reindex.
- Other 1.2.0 headliners to fold in: virtual-repo aggregation, streaming OCI uploads, staging/
  promotion gates, password policies, repo-scoped tokens (see be/003 overlap), SBOM declared-deps.

### Proposed artifact-keeper sub-sequence (slots into wave 14/15)

1. Full Plane B `scripts/backup.sh` + Velero backup of in-cluster artifact-keeper PVCs.
2. `build-containers.sh clone` with `REF=v1.2.0`; `git apply --3way` patches; triage per table above;
   regenerate sqlx cache; rebuild → get `1.2.0-patched` images.
3. Stand up **OpenSearch 2.x** (Plane B compose first, then Plane A manifests); reindex.
4. Roll backend+web to `1.2.0-patched`, pointed at OpenSearch; verify search, docker login (be/003),
   permissions UI (web/001).
5. Re-mirror images + re-push distribution; update `k8/services/artifact-keeper/*` and remote compose.

## Chapter 2 — Target Version Matrix (latest stable, researched 2026-06-04)

> "Latest everywhere" per locked decision. Each row: **current → target**, Helm chart where relevant
> (chart *and* appVersion must move together), and the migration flag. **Spring apps, Java buildpack,
> and Korifi are intentionally NOT bumped** (deferred / already-latest). Re-mirror every new `-arm64`
> image into the remote artifact-keeper before deploying it.

### 🔴 High-risk upgrades (need their own procedure + backup + rollback)

| Component | Jump | Why it's high-risk |
|---|---|---|
| **External Secrets Operator** | v0.16.1 → **v2.5.0** | Major re-versioning (0.16→2.x). CRD `external-secrets.io/v1beta1` → **v1**; migrate manifests + upgrade CRDs *before* controller. Mis-step desyncs **every** secret. Highest-risk item in the campaign. |
| **artifact-keeper** | rc.8-patched → **1.2.0-patched** | **Meilisearch → OpenSearch 2.x re-platform** + 5-patch rebase. See dedicated Chapter 2 section. |
| **Grafana + Loki Helm charts** | repo move | OSS `grafana`/`loki` charts **left the `grafana` repo** — must switch to **`grafana-community`** repo (`https://grafana-community.github.io/helm-charts`). Loki chart renumbers 6.x → 17.x; Grafana app 13 removes AngularJS. |
| **Mimir (in-cluster)** | 3.0.4 → **3.1.0** | TSDB blocks must be **index v2**; store-gateways drop v1 index-header. Compact/migrate old Garage blocks first. Removed flags (`-target=flusher`, response-streaming flag). |
| **Mimir (remote Plane B)** | 2.15.0 → **3.0.x** | **Major 2→3**: config now ConfigMap-by-default (set `configStorageType: Secret` if external), MQE default engine, blue/green migration recommended. |
| **GitLab CE** | 18.10 → **19.0.1** | Must pass **required stop 18.11.4**; major 19.0. Path below. |
| **OpenBao chart** | 0.8.0 → **0.28.3** | Chart is *wildly* behind (0.8.0 shipped appVersion 2.1.1; we override image to 2.5.1). Diff `values.yaml` against 0.28.3 defaults; back up `file` storage PV; have unseal keys ready. |
| **Technitium DNS** | 14.3.0 → **15.2.0** | Major v15; snapshot PV (config auto-migrates forward, not downgrade-safe). |
| **Traefik chart** | 39.0.5 → **40.2.0** | Major chart bump; review `values.yaml` schema (ports/providers/CRD handling). App stays v3.x. |
| **OTEL Collector (Plane B)** | 0.120.0 → **0.153.0** | 33 minors of accumulated breaking changes; audit every receiver/processor/exporter in the pipeline config (Kafka franz-go only, key renames). |

### 2.1 Foundation

| Component | Current | Target | Notes |
|---|---|---|---|
| Lima (host tool) | (in use) | **v2.1.2** | Lima 2.x changed `lima.yaml` schema/defaults — validate `bootstrap/lima.yaml` against 2.x before recreating VM. |
| K3s | unpinned | **v1.36.x (pin latest 1.36 patch, ≥1.36.1+k3s1)** | Stop floating `get.k3s.io`. See Chapter 2 client-go analysis. |
| Kubernetes Reflector | unpinned | chart **10.0.47** / app **10.0.47** | Pin it. |

### 2.2 Infrastructure

| Component | Current (app / chart) | Target (app / chart) | Notes |
|---|---|---|---|
| MetalLB | v0.15.3 / 0.15.3 | **v0.16.1 / 0.16.1** | Minor; re-apply CRDs (chart won't auto-upgrade them). |
| Traefik | v3.6.10 / 39.0.5 | **v3.7.1 / 40.2.0** | 🔴 major chart bump — values schema review. |
| cert-manager | v1.20.0 / 1.20.0 | **v1.20.2 / 1.20.2** | Patch-only, safe. |

### 2.3 Platform

| Component | Current (app / chart) | Target (app / chart) | Notes |
|---|---|---|---|
| ArgoCD | v3.3.4 / 9.4.15 | **v3.4.3 / 9.5.18** | Minor; sync updated CRDs manually. |
| External Secrets | v0.16.1 / 0.16.1 | **v2.5.0 / 2.5.0** | 🔴 major; CRD v1beta1→v1 migration. |
| Portainer | 2.39.1 / 239.0.2 | **2.39.3 / 239.3.0** | Patch. |
| Garage | v2.2.0 / raw | **v2.3.0 / raw** | "No breaking changes from 2.2.0." Drop-in. |
| Technitium DNS | 14.3.0 / raw | **15.2.0 / raw** | 🔴 major v15; snapshot PV. |
| Velero | v1.18.0 / 12.0.0 | **v1.18.1 / 12.0.2** | Patch. AWS plugin **v1.14.0 → v1.14.1**. |
| Velero UI | 0.10.1 / (raw) | image **0.10.1** / chart **0.14.0** (appVersion 0.10.0) | Chart lags app — deploy chart 0.14.0, override `image.tag: 0.10.1`. |

### 2.4 Secrets

| Component | Current (app / chart) | Target (app / chart) | Notes |
|---|---|---|---|
| OpenBao | 2.5.1 (image override) / 0.8.0 | **v2.5.4 / 0.28.3** | 🔴 chart far behind — diff values; standalone `file` backend = no Raft migration, but backup PV + unseal keys ready. |

### 2.5 Monitoring (LGTM) — ⚠️ chart repo migration for Grafana & Loki

| Component | Current (app / chart) | Target (app / chart) | Notes |
|---|---|---|---|
| Grafana | 12.4.1 / 10.5.15 (old repo) | **12.4.3** (or 13.0.1) / chart **12.4.2** @ `grafana-community` | 🔴 switch repo. Staying 12.4.x avoids Angular-removal pain of 13; pick during this wave. |
| Loki | 3.6.7 / 6.55.0 (old repo) | **3.7.2 / 17.1.6** @ `grafana-community` | 🔴 switch repo (chart renumbers to 17.x). No Garage S3 schema break. |
| Mimir | 3.0.4 / raw | **3.1.0 / raw** | 🔴 TSDB index v2 required; migrate old blocks. Classic S3/Garage still supported (no forced Kafka). |
| Tempo | 2.9.0 / 1.24.4 | **2.10.5 / chart 2.2.0** @ `grafana-community` | Fixes the 2.9.0↔2.10.3 drift. **Avoid Tempo 3.0** (architecture rewrite, vParquet4, no downgrade). |
| Alloy | v1.14.1 / 1.6.2 | **v1.16.2 / 1.8.2** | Stays in `grafana` repo. Chart appVersion v1.16.1 — override image to v1.16.2 if wanted. |
| kube-state-metrics | 2.18.0 / 7.2.2 | **2.19.0 / 7.4.0** | Clean. |
| node-exporter | 1.10.2 / 4.52.2 | **1.11.1 / 4.55.0** | Clean. |

### 2.6 Services

| Component | Current | Target | Notes |
|---|---|---|---|
| PostgreSQL (in-cluster a-k) | 17.9 | **17.10** | Stay on 17.x (PG17 supported to Nov 2029). 18.x deferred — needs pg_upgrade. |
| Meilisearch | v1.39.0 | **removed → OpenSearch 2.x** | Part of artifact-keeper 1.2.0 re-platform. |
| Trivy | 0.69.3 | **0.71.0** | Minor. |
| artifact-keeper backend/web | rc.8-patched | **1.2.0-patched** | See dedicated section. |
| GitLab CE | 18.10.0-ce.0 | **19.0.1-ce.0** | 🔴 path: **18.10.7 → 18.11.4 (required stop) → 19.0.1**. Finish background migrations at each stop. |
| GitLab Runner | 18.10.0 / 0.87.0 | **19.0.1 / 0.89.1** | Step alongside CE (intermediate chart 0.88.3 = 18.11.x available). |

### 2.7 Apps (Korifi / CF)

| Component | Current | Target | Notes |
|---|---|---|---|
| Korifi | v0.18.0 | **v0.18.0 (no change)** | Already latest. |
| kpack (self-built) | 0.17.0 | **0.17.1** | Matches Korifi's pinned kpack; lifecycle 0.20.12; images now on **ghcr.io**. See fork analysis. |
| Contour | v1.33.2 | **v1.33.5** | Patch; pairs with Envoy v1.35.10. |
| Envoy | distroless-v1.35.9 | **distroless-v1.35.10** | Contour-pinned — do NOT jump to 1.38 independently. |
| Service Binding Runtime | 1.0.0 | **1.0.0 (no change)** | Already latest. |
| Paketo Java buildpack | 21.4.0 (pinned) | **keep 21.4.0** (latest is 22.0.0 — reference only) | DEFERRED to Spring wave; revisit ca-cert binding-mount blocker then. |
| Paketo jammy-full stacks | latest | **0.1.167** (reference) | Build/run share tag. |

### 2.8 Service Brokers & Operators

| Component | Current | Target | Notes |
|---|---|---|---|
| CloudNativePG | unpinned | **1.29.1 / chart 0.28.2** | Pin it. CRDs auto-applied by operator. |
| RabbitMQ Cluster Operator | unpinned (`latest`) | **2.21.0** | Pin it. ⚠️ **registry moved to `quay.io/rabbitmqoperator/cluster-operator`** (Docker Hub stopped at 2.19.2) — update mirror source. Upgrade triggers rolling reconcile of managed clusters. |
| Valkey | 8.1-alpine | **8.1.8-alpine** | Pin exact patch. |
| cf-service-broker (Go) | 1.4.0 | rebuild → bump client-go **0.35.3 → 0.36.1**, Go **1.26.4** | Re-tag `-arm64`, re-mirror, redeploy. |
| cf-marketplace-broker (Go) | 1.0.0 | rebuild → client-go **0.36.1**, Go **1.26.4** | Same. |

### 2.9 Go toolchain & libraries

| Item | Current | Target | Notes |
|---|---|---|---|
| Go | 1.26.1 | **1.26.4** | Patch; no language breaks. |
| k8s.io/client-go (brokers) | v0.35.3 | **v0.36.1** | Match K3s 1.36. |
| brokerapi | v11.0.16 | **v11.0.16 (stay on v11)** | v12.0.1 exists (major, import path `/v12`) — optional, not needed. |
| kpack client-go (self-built) | v0.30.11 | keep with release (0.17.1) / optionally main's 0.34.3 | Per fork analysis. |

### 2.10 Plane B — remote developer-platform server

| Image | Current | Target | Notes |
|---|---|---|---|
| OpenSearch (new, replaces Meilisearch) | — | **2.19.5** (2.x line) | JVM heap `-Xms=-Xmx` ≈ 50% container RAM; ~2× heap total RAM. ARM64 yes. |
| HAProxy (router) | 3.1-alpine | **3.2.19-alpine (LTS)** | Use 3.2 LTS, not the brand-new 3.4. |
| OTEL Collector Contrib | 0.120.0 | **0.153.0** | 🔴 audit pipeline config (33 minors of breaks). |
| Certbot | latest | **5.6.0** | — |
| Nginx | alpine | **1.30.2-alpine (stable)** | — |
| PostgreSQL (remote vault/artifactory) | 18 | **18.4** | Latest 18 patch. |
| **Remote LGTM align →** Grafana | 11.5.2 | **12.4.3** | 🔴 major 11→12 (Angular removed; audit dashboards). |
| Remote LGTM align → Loki | 3.4.2 | **3.6.7** | Promtail deprecated → Alloy. |
| Remote LGTM align → Tempo | 2.7.2 | **2.10.5** | ⚠️ tenant-ID validation now enforced — check existing tenant IDs. |
| Remote LGTM align → Mimir | 2.15.0 | **3.0.x** | 🔴 major 2→3 (see high-risk table). |

### 2.11 Distribution

After all of the above: re-run `build-distribution.sh`, **bump version v1.1.2 → v1.2.0** (aligns with
artifact-keeper), upload `installer-v1.2.0.sh` + `stack-v1.2.0.tgz` to the remote generic repo, write
`UPGRADE-v1.2.0.md`. Update `installer.sh`/`install.sh` banner versions and the Go 1.26 pre-flight to 1.26.4.

---

## Chapter 3 — Upgrade Waves: Execution Plan

> This chapter is the **authoritative sequence** and supersedes the rough "Dependency & ordering map"
> earlier in the doc. Commands use the repo's real paths and the `development.cfapps.cool` platform
> domain; replace placeholders in `<…>`. Where a config key depends on artifact-keeper 1.2.0 or a new
> chart's `values.yaml`, the step says so — **diff against the real file before applying**, don't trust
> a key from memory.

### 3.0 Conventions & standing gates

**What a wave is:** one atomic, independently verifiable, independently revertable change set. Never
two risky changes in flight. Five rules: *(1)* atomic+reversible, *(2)* backup gate before any stateful
wave, *(3)* mirror images ahead, *(4)* changes go in **source files** then `helm upgrade`/`kubectl apply`,
*(5)* low-blast-radius first within a wave.

> **★ Overriding goal — the INSTALL path must reach target state, not just the upgrade path.** A colleague
> running the installer on a *naked* Mac must get the fully-upgraded stack. So every wave's version change
> lands in the **source of truth** (`Chart.yaml`/`values.yaml`, raw manifests, `install.sh`, `config.env`,
> the distribution), never as a live-only `kubectl`/`helm` tweak. The Helm model helps: the same chart
> serves `helm install` (fresh) and `helm upgrade` (live). And the **remote registry must hold every
> target `-arm64` image** so a fresh install can pull it (that's what Wave 1 is for). Definition of done
> for each wave includes: *would a clean install from these files + registry produce target state?*

**Standard backup gate** (run the relevant lines before every stateful wave; tag with the wave #):
```bash
# Plane A — cluster + PVs
velero backup create wave<N>-pre --wait
kubectl get pvc -A                                   # record bound PVCs
# Host — Lima VM snapshot (newer Lima) or cold copy
limactl snapshot create k3s-server --tag wave<N> 2>/dev/null \
  || { limactl stop k3s-server && cp -a ~/.lima/k3s-server ~/.lima/k3s-server.wave<N> && limactl start k3s-server; }
# Plane B — per stack (run in the stack dir)
cd artifactory && ./scripts/backup.sh && cd -        # + otel/ vault/ as touched
```

**Upgrade flow — Helm, NOT ArgoCD** (confirmed Wave 0: the stack has **0 ArgoCD Application CRs**; it
is deployed via **direct Helm releases**, local wrapper charts `<name>-0.1.0` that vendor the upstream
chart under `charts/`). ArgoCD is installed as a *component* but does not manage the stack — so there is
no auto-sync to disable. A wave step is:
```bash
# 1. bump the wrapper chart: Chart.yaml (dependency version + appVersion) + values.yaml (image tag)
# 2. refresh the vendored dependency, then upgrade the single release:
helm dependency update k8/<layer>/<component>            # re-fetches charts/<dep>-<ver>.tgz
helm upgrade <release> k8/<layer>/<component> -n <ns>    # e.g. helm upgrade traefik k8/infrastructure/traefik -n traefik
git commit -am "wave<N>: <component> <old> -> <new>" && git push
# raw-manifest components (Garage, Mimir, Technitium) = edit the YAML tag + kubectl apply -f
```
Rollback for any wave = `git revert` the wave commit + `helm upgrade <release> …` back to the prior chart
(or `helm rollback <release> <prev-revision> -n <ns>`).

**Health baseline / verification probe** (green = safe to proceed):
```bash
helm ls -A | grep -iv deployed && echo "⚠ a release is not 'deployed'" || echo "all helm releases deployed"
kubectl get pods -A | grep -vE 'Running|Completed' || echo "no bad pods"
./k8/stack.sh status
# OpenBao + secret backbone
kubectl exec -n openbao openbao-0 -- bao status | grep -E 'Sealed|Initialized'
kubectl get clustersecretstore openbao -o jsonpath='{.status.conditions[-1].reason}{"\n"}'   # expect Valid
kubectl get externalsecrets -A -o json | jq -r '[.items[].status.conditions[-1].reason]|group_by(.)|map("\(length) \(.[0])")|.[]'
```

### 3.1 Wave map

_Status legend:_ ✅ done · 🔧 done + follow-up resolved · ⬜ not started · ⏸ deferred. Per-wave detail + commits in Chapter 4.

| # | Wave | Status | 🔴? | Gate | One-line exit criteria |
|---|---|---|---|---|---|
| 0 | Stabilize & checkpoint (pin the 4 floats to *current*) | ✅ done (922be1f) | | full backup | baseline green, rollback artifacts exist |
| 1 | Image supply chain (mirror targets; fix ghcr.io/quay.io sources) | ✅ done (67bb17d) | | — | every target image pullable from remote registry |
| 2 | Host foundation (Lima 2.x, K3s→1.36.x pinned) | ✅ done (39a4a52) | 🔴 | VM snapshot | pods reschedule, PVs intact, kpack builds |
| 3 | Networking & TLS edge (cert-manager→MetalLB→Traefik 40) | ✅ done (eb95e5e) | | — | all IngressRoutes serve, certs valid |
| 4 | **Secrets backbone (OpenBao → ESO v2)** | ✅ done (6d3e453) | 🔴 | Runbook A | all ExternalSecrets Ready |
| 5 | Storage & platform (Garage→ArgoCD→Portainer→Technitium 15→Velero) | ✅ done (474414e) | | backup | S3 R/W ok, ArgoCD healthy, backups run |
| 6 | Observability (KSM/NE/Alloy→Tempo→Loki/Grafana repo move→Mimir 3.1) | ✅ done (01c9e1d) | | bucket note | telemetry flowing, blocks migrated |
| 7 | **artifact-keeper in-cluster → 1.2.0 (OpenSearch)** | 🔧 done (08973d4) | 🔴 | Runbook B | search ok, docker-login ok |
| 8 | GitLab CE 18.10→18.11.4→19.0.1 + Runner | ✅ done (4d474aa) | | backup each hop | repos/CI green at each stop |
| 9 | CF/Korifi (kpack 0.17.1, Contour/Envoy; Korifi unchanged) | 🔧 done (dc118e6 + AK fix c993708/cccab7f; `cf push` verified) | | — | `cf push` builds+routes+TLS |
| 10 | Brokers & operators (CNPG 1.29.1, RabbitMQ 2.21.0, Go rebuild) | ✅ done (`cf marketplace`+bind verified) | | — | `cf marketplace` full, bind works |
| 11 | **Plane B — vault (OpenBao) + embedded LGTM** | ✅ done (descoped) | — | — | vault is demo-only, OUTSIDE this platform → out of scope |
| 12 | **Plane B — artifact-keeper → 1.2.0** | ✅ done | 🔴 | `plans/planeb-remote-runbook.md` | upgraded rc.8→1.2.0; pull-source verified from Plane A (46/46 + generic OK) |
| 13 | Re-cut distribution (v1.1.2→v1.2.0) | ⬜ not started | | — | fresh install from new artifacts works |
| 14 | ⏸ Spring apps (DEFERRED, after Spring release) | ⏸ deferred | | — | apps build+run on new triple |

**Progress: Waves 0–12 complete (Wave 11 vault descoped = demo-only/off-platform; Wave 12 artifact-keeper 1.2.0 done + consumer-verified). Next: Wave 13 (re-cut distribution v1.2.0). Wave 14 (Spring) deferred.**
**Dated operational TODO:** after **2026-08-03** (korifi `korifi-api-internal-cert` self-signed renewal),
`kubectl rollout restart deploy/korifi-api-deployment -n korifi` to clear the recurring `cf push`/`cf app` 500
(stale-CA on the log-cache /stats path). See Wave 9 log + memory `project_korifi_api_selfsigned_cert_restart`.

### 3.2 Routine waves — checklists

Each routine wave = bump `Chart.yaml`+`values.yaml` (or raw manifest tag) → `helm upgrade <release> k8/<path> -n <ns>`
(or `kubectl apply` for raw manifests) → probe → next. Rollback for all routine waves = `git revert` the
wave commit + `helm upgrade` back (or `helm rollback <release> <prev-rev> -n <ns>`).

- **Wave 0:** capture live versions of the 4 floats and pin them *as-is* first —
  `kubectl get nodes -o wide` (K3s), `helm ls -A` (Reflector/CNPG charts), `kubectl -n rabbitmq-system get deploy -o jsonpath` (op image). Commit those exact versions, *then* later waves bump them.
- **Wave 1:** mirror loop — for each target image: `crane copy --platform linux/arm64 <src> artifactory.cfapps.cool/docker-local/<repo>:<tag>-arm64`. Update mirror scripts for **kpack→ghcr.io** and **RabbitMQ op→quay.io**.
- **Wave 2:** pre-check removed APIs (`kubectl api-resources` deltas; scan manifests for any removed beta). In-place K3s upgrade or VM-rebuild+restore. Verify a `cf push` still builds (kpack skew check).
- **Wave 3:** order cert-manager (patch) → MetalLB (re-apply CRDs: `kubectl apply --server-side -f` the new CRDs) → Traefik (chart 39→40: `helm show values` diff first, watch every IngressRoute).
- **Wave 5:** Garage first, verify `aws --endpoint s3 ls` against Garage before touching dependents; Technitium 15 → snapshot PV first.
- **Wave 6:** Loki/Grafana → add `grafana-community` repo, switch chart source; Mimir → ensure TSDB blocks are index-v2 before the image bump.
- **Wave 8:** strictly `18.10.7 → 18.11.4 → 19.0.1`; after each hop `gitlab-rake db:background_migrations:status` must be clean before the next; runner chart steps 0.87→0.88.3→0.89.1.
- **Wave 9:** kpack 0.17.1 from ghcr.io mirror; Contour v1.33.5 + Envoy distroless-v1.35.10 (paired — don't bump Envoy alone); Korifi/Service-Binding unchanged; keep Paketo Java 21.4.0.
- **Wave 10:** ✅ done — CNPG 1.29.1/chart 0.28.2 and RabbitMQ op 2.21.0 (stays on **ghcr.io**, not quay.io — earlier note was wrong); rebuilt Go brokers — `go.mod`: `go 1.26.4`, `k8s.io/* v0.36.1`; `-arm64`, mirror, bump deployment tags (sb 1.5.0, mb 1.2.0). Operator upgrades rolled managed PG instances in place — both verified healthy.
- **Wave 13:** `./build-distribution.sh`; rename to `installer-v1.2.0.sh`/`stack-v1.2.0.tgz`; upload to remote generic repo (see root CLAUDE.md commands); bump installer pre-flight Go check to 1.26.4; write `UPGRADE-v1.2.0.md`.

---

### 3.3 Runbook A — Wave 4: Secrets backbone (OpenBao → ESO) 🔴

> ESO feeds every secret (registry pull, DNS creds, service creds). Order: **store first (OpenBao),
> then sync (ESO)**. ESO 0.16→v2 is a major re-version with a CRD `v1beta1→v1` migration.

**Backup gate**
```bash
velero backup create wave4-secrets --include-namespaces openbao,external-secrets --wait
kubectl get externalsecrets,clustersecretstores,secretstores,pushsecrets -A -o yaml > /tmp/eso-crs.bak.yaml
kubectl get secrets -A -o yaml > /tmp/all-secrets.bak.yaml     # the synced targets
# CONFIRM OpenBao unseal keys are in the password manager before proceeding
```

**Part 1 — OpenBao → v2.5.4 / chart 0.28.3**
```bash
helm repo add openbao https://openbao.github.io/openbao-helm && helm repo update
helm show values openbao/openbao --version 0.28.3 > /tmp/openbao-0.28.3.defaults.yaml
diff <(grep -v '^\s*#' k8/services/openbao/values.yaml) /tmp/openbao-0.28.3.defaults.yaml | less  # reconcile renamed keys
crane manifest artifactory.cfapps.cool/docker-local/openbao/openbao:2.5.4-arm64 >/dev/null && echo IMG_OK
# edit k8/services/openbao/Chart.yaml (version 0.28.3, appVersion 2.5.4) + values.yaml (image tag 2.5.4-arm64)
git commit -am "wave4: OpenBao 2.5.1->2.5.4, chart 0.8.0->0.28.3" && git push
helm dependency update k8/services/openbao && helm upgrade openbao k8/services/openbao -n openbao && kubectl -n openbao rollout status statefulset/openbao
# pod restarts SEALED — unseal (standalone file backend):
for k in <unseal-key-1> <unseal-key-2> <unseal-key-3>; do kubectl exec -n openbao openbao-0 -- bao operator unseal "$k"; done
kubectl exec -n openbao openbao-0 -- bao status        # Sealed: false
```

**Part 2 — ESO → v2.5.0 (CRD v1beta1 → v1)** 🔴
```bash
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
kubectl get crd externalsecrets.external-secrets.io -o jsonpath='{.spec.versions[*].name}'; echo  # served versions now
grep -rn "external-secrets.io/v1beta1" k8/            # every hit must move to .../v1
# 1) migrate manifests: bump apiVersion v1beta1 -> v1 on ExternalSecret/ClusterSecretStore/SecretStore/PushSecret
#    (read the ESO v1.0 + v2.0 release notes for any field renames before editing)
# 2) install the new CRDs (major jump — do CRDs before the controller):
helm show crds external-secrets/external-secrets --version 2.5.0 | kubectl apply --server-side -f -
# 3) bump k8/platform/external-secrets/Chart.yaml (2.5.0) + values.yaml (image v2.5.0-arm64); diff vs new defaults
git commit -am "wave4: ESO 0.16.1->2.5.0, CRDs v1beta1->v1" && git push
helm upgrade external-secrets k8/platform/external-secrets -n external-secrets && kubectl -n external-secrets rollout status deploy/external-secrets
```

**Verification**
```bash
kubectl get clustersecretstore -A                     # CONDITION Valid=True
kubectl get externalsecrets -A                         # STATUS SecretSynced, Ready=True (all)
kubectl -n <ns> get secret artifact-keeper-pull -o jsonpath='{.metadata.creationTimestamp}'; echo  # refreshed
# force a resync and confirm cert-manager DNS creds + registry pull still resolve
kubectl annotate externalsecret -A --all force-sync="$(date +%s)" --overwrite
```

**Rollback**
```bash
# ESO (do this first): revert the commit, restore old CRDs + CRs
git revert --no-edit <wave4-eso-commit> && git push && helm upgrade external-secrets k8/platform/external-secrets -n external-secrets
kubectl apply -f /tmp/eso-crs.bak.yaml     # NOTE: v1->v1beta1 is lossy; backup is the source of truth
# OpenBao: restore PVC then redeploy old chart, then unseal
velero restore create --from-backup wave4-secrets --include-namespaces openbao
# re-unseal as in Part 1
```

---

### 3.4 Runbook B — Wave 7: artifact-keeper (in-cluster) → 1.2.0 + OpenSearch 🔴

> The in-cluster artifact-keeper (Phase 4 service at `artifacts.development.cfapps.cool`) is
> self-contained — its own PostgreSQL, search, and Garage S3 bucket. v1.2.0 swaps **Meilisearch →
> OpenSearch 2.x** and needs our 5 patches rebased. Images are built by the `artifactory/` pipeline and
> pushed to the **remote** registry, then the in-cluster deployment pulls them.

**Backup gate**
```bash
velero backup create wave7-ak --include-namespaces <ak-namespace> --wait
kubectl exec -n <ns> <postgres-pod> -- pg_dump -U <user> <db> | gzip > /tmp/ak-pg.$(date +%F).sql.gz
# artifact blobs live in Garage S3 (already covered by the Garage bucket); note the bucket name
```

**Part 1 — build `1.2.0-patched` images (in `artifactory/`)**
```bash
cd artifactory
# drop any patch that is now upstream BEFORE cloning (see Ch.2 table: be/001, be/002 likely upstream)
#   rm source/patches/backend/001-*.patch source/patches/backend/002-*.patch   # only if confirmed upstream
BACKEND_REF=v1.2.0 WEB_REF=v1.2.0 ./scripts/build-containers.sh clone   # clones tag, git-applies remaining patches
# fix any rejected patch by hand, per-patch:
#   git -C source/backend apply --3way patches/backend/003-*.patch
#   git -C source/web     apply --3way patches/web/*.patch
( cd source/backend && cargo sqlx prepare --workspace )                  # regen sqlx cache for the 1.2.0 schema
./scripts/build-containers.sh push                                       # -> andrlange/artifact-keeper-{backend,web}:1.2.0-patched-arm64 in remote registry
cd -
```

**Part 2 — stand up OpenSearch 2.x**
```bash
crane manifest artifactory.cfapps.cool/docker-local/opensearchproject/opensearch:2.19.5-arm64 >/dev/null && echo IMG_OK
# create k8/services/artifact-keeper/opensearch/ : StatefulSet + PVC + Service
#   image: .../opensearchproject/opensearch:2.19.5-arm64
#   env:   discovery.type=single-node ; OPENSEARCH_JAVA_OPTS=-Xms2g -Xmx2g ; security per your setup
#   resources: request ~3Gi (heap*~1.5) — CHECK Lima 48Gi headroom
# add it to the artifact-keeper kustomization/ArgoCD app
git add k8/services/artifact-keeper/opensearch && git commit -m "wave7: add OpenSearch 2.19.5" && git push
kubectl apply -k k8/services/artifact-keeper/ && kubectl -n <ns> rollout status statefulset/opensearch
kubectl -n <ns> exec <opensearch-pod> -- curl -s localhost:9200/_cluster/health | grep -o '"status":"[a-z]*"'  # green/yellow
```

**Part 3 — cut backend + web over to 1.2.0**
```bash
# k8/services/artifact-keeper/artifact-keeper/deployment.yaml:
#   image -> .../artifact-keeper-backend:1.2.0-patched-arm64
#   replace MEILI_* env with the OpenSearch endpoint/creds env  (use the EXACT keys from the 1.2.0 config docs)
#   remove the Meilisearch init container + probe
# deployment-web.yaml: image -> .../artifact-keeper-web:1.2.0-patched-arm64
git commit -am "wave7: artifact-keeper rc.8-patched -> 1.2.0-patched (OpenSearch)" && git push
kubectl apply -k k8/services/artifact-keeper/ && kubectl -n <ns> rollout status deploy/artifact-keeper
# reindex into OpenSearch per the 1.2.0 admin API / job
```

**Part 4 — decommission Meilisearch**
```bash
git rm -r k8/services/artifact-keeper/meilisearch && git commit -m "wave7: drop Meilisearch" && git push
kubectl apply -k k8/services/artifact-keeper/
kubectl -n <ns> delete pvc <meilisearch-pvc>          # only AFTER search is verified
```

**Verification**
```bash
curl -sk https://artifacts.development.cfapps.cool/healthz
# search returns hits; service-account docker login (patch be/003) works:
docker login artifacts.development.cfapps.cool -u <svc-account> -p <api-token>
# permissions page (patch web/001) shows the repo dropdown in the browser
```

**Rollback**
```bash
git revert --no-edit <wave7-cutover-commit> <wave7-drop-meili-commit> && git push   # restores rc.8-patched + Meilisearch manifests
kubectl apply -k k8/services/artifact-keeper/
velero restore create --from-backup wave7-ak --include-namespaces <ak-namespace>     # if PVC/DB damaged
# or DB-only: gunzip -c /tmp/ak-pg.*.sql.gz | kubectl exec -i -n <ns> <pg-pod> -- psql -U <user> <db>
```

---

### 3.5 Runbook C — Waves 11–12: Plane B remote server (registry LAST) 🔴

> Independent Docker-Compose stacks on the remote server. Wave 11 can run **in parallel** with Plane A.
> Wave 12 (the registry) is strictly **last** — while it's down nothing can pull.

**Wave 11 — align `otel/`, `router/`, `vault/`** (per stack)
```bash
cd <stack>            # otel | router | vault
./scripts/backup.sh   # or ./stop.sh after a manual snapshot
# edit docker-compose.yml image tags to the Ch.2 §2.10 targets
./stop.sh && ./start.sh
docker compose ps     # all healthy
```
- **router/**: HAProxy `3.2.19-alpine` (LTS), otel-collector `0.153.0` — **audit the collector pipeline config** (33 minors of breaks) before restart.
- **vault/**: OpenBao `2.5.4`, postgres `18.4`, certbot `5.6.0`, nginx `1.30.2-alpine`; keep it aligned with the in-cluster OpenBao.
- **otel/ Mimir 2.15 → 3.0 is MAJOR** — config moves to a ConfigMap (set `configStorageType: Secret` if you externalize), MQE becomes default. **Do blue/green** (stand up new Mimir, dual-write, cut reads over) per the Grafana migration guide rather than in-place. Grafana 11→12 removes AngularJS — audit dashboards first.

**Wave 12 — remote artifact-keeper → 1.2.0 (the pull source)**
```bash
cd artifactory
./scripts/backup.sh                       # full DB + artifacts (the 663MB-class zip). MANDATORY.
# announce a short maintenance window — pulls will be briefly unavailable
```
1. Reuse the `1.2.0-patched` images built in Wave 7 (already in the registry), or rebuild here if the remote tree differs.
2. Edit `artifactory/docker-compose.yml`:
   - `artifact-keeper-backend` / `-web` → `1.2.0-patched`
   - **replace the `meilisearch` service with `opensearchproject/opensearch:2.19.5`** (env `discovery.type=single-node`, `OPENSEARCH_JAVA_OPTS`, a data volume)
   - rewire backend `MEILI_*` → OpenSearch (exact keys from 1.2.0 docs)
   - `postgres:18.4`, `nginx:1.30.2-alpine`, `certbot/certbot:5.6.0`, otel `0.153.0`
3. Apply + reindex:
```bash
./stop.sh && ./start.sh
# trigger the 1.2.0 reindex; wait for OpenSearch green
```

**Verification (from a Plane A host — proves the supply chain is intact)**
```bash
crane manifest artifactory.cfapps.cool/docker-local/openbao/openbao:2.5.4-arm64 >/dev/null && echo PULL_OK
curl -sk https://artifactory.cfapps.cool/healthz
BASE=https://artifactory.cfapps.cool/api/v1/repositories/generic/download
curl -sfL "$BASE/installer-v1.2.0.sh" -o /tmp/i.sh && echo GENERIC_REPO_OK
```

**Rollback (must be fast — this is the pull source)**
```bash
cd artifactory
./stop.sh
git checkout docker-compose.yml          # restore previous compose (previous image tags pinned)
./scripts/restore.sh <latest-backup>     # DB + artifacts
./start.sh
# keep the previous-version images retained in the registry until Wave 12 is signed off
```

---

*The plan is complete through Chapter 3. Execution starts at Wave 0 (pin-to-current + baseline). Each
🔴 wave has its runbook above; routine waves follow the §3.2 checklist. Spring (Wave 14) is scheduled
after next week's Spring release.*

---

## Chapter 4 — Execution Log

> Live record of the campaign. One entry per wave: status, what was done, evidence, and the commit.
> Updated and pushed after each wave (per standing instruction).

| Wave | Status | Date | Commit |
|---|---|---|---|
| 0 — Stabilize & checkpoint | ✅ complete (incl. OpenBao key-loss recovery) | 2026-06-05 | 922be1f |
| 1 — Image supply chain | ✅ complete (28 target images mirrored) | 2026-06-05 | 67bb17d |
| 2 — Host foundation (Lima + K3s) | ✅ complete (K3s 1.34.5→1.36.1) | 2026-06-05 | 39a4a52 |
| 3 — Networking & TLS edge | ✅ complete (cert-manager, MetalLB, Traefik) | 2026-06-05 | eb95e5e |
| 4 — Secrets backbone (OpenBao → ESO) 🔴 | ✅ complete (OpenBao 2.5.4, ESO 2.5.0) | 2026-06-05 | 6d3e453 |
| 5 — Storage & platform | ✅ complete (Garage, ArgoCD, Portainer, Technitium, Velero) | 2026-06-05 | _this commit_ |

### Wave 0 — Stabilize & checkpoint — ✅ DONE (922be1f)

**Goal:** deterministic starting point — pin the 4 floating components to their *current running*
versions, take full backups, and record a green health baseline before any version changes.

**Live versions captured (the "current" to pin):**

| Component | Running version | Note |
|---|---|---|
| K3s | **v1.34.5+k3s1** | was "unpinned" — actually 1.34, not 1.36. Wave 2 hop = 1.34→1.35→1.36. |
| Kubernetes Reflector | chart/app **10.0.24** | (latest 10.0.47) |
| CloudNativePG | chart **0.27.1** / app **1.28.1** | (latest 0.28.2 / 1.29.1) |
| RabbitMQ Cluster Operator | **2.20.0** (ghcr.io) | (latest 2.21.0, registry moving to quay.io) |

**Management-model correction (important):** the stack has **zero ArgoCD Application CRs** — it is
deployed via **direct Helm releases** (19 releases via `install.sh`/`stack.sh`), not ArgoCD App-of-Apps.
Local charts are thin wrappers (`<name>-0.1.0`) with a dependency on the upstream chart. **Chapter 3's
"`argocd app sync`" convention is therefore replaced by `helm upgrade <release> k8/<path> -n <ns>`**
(bump the wrapper's dependency version + `helm dependency update`). To be corrected in Ch.3 before Wave 2.

#### 🔴 BLOCKER — OpenBao unseal keys lost (resolved via re-seed plan)

- OpenBao is **initialized + sealed**; `k8/unseal.sh` keys **do not match the on-disk keyring**. Proven
  by testing all 10 three-key combinations — every one fails identically at reconstruction with
  `cipher: message authentication failed` (so it's a whole-set mismatch, not a mistyped share). The
  saved root token is **`s.`-format (legacy Vault)** while OpenBao 2.5.1 issues `hvs.` tokens → the
  saved creds are from a **different/older init** than the current data. Real keys appear unrecoverable.
- **No data loss, though:** ESO is one-way (OpenBao→K8s) with `deletionPolicy: Retain`, so all values are
  still live as K8s Secrets and were captured.
- **Recovery = data-preserving re-init.** Phase 1 (non-destructive) **DONE 2026-06-05**:
  - ✅ All **16 OpenBao paths reconstructed** from live K8s Secrets → `/tmp/openbao-reseed/reseed-map.json`
    (`secret/{dns/google-cloud, k8s/registry, garage/{admin,admin-token,artifacts,loki,mimir,tempo,velero},
    artifact-keeper/{app,postgres,meilisearch}, gitlab/{admin,runner}, grafana/admin,
    marketplace-broker/openbao-token}`).
  - ✅ 48 target secrets + all ExternalSecret specs + ClusterSecretStore exported to `/tmp/openbao-reseed/`.
  - ✅ Direct **tar backup** of the OpenBao data volume (`/openbao/data`) saved locally (Velero couldn't —
    see Garage finding).
  - ✅ Phase 2 (destructive re-init) **DONE 2026-06-05**: uninstalled OpenBao, wiped PVCs, reinstalled,
    `bao operator init` (new keys saved to gitignored `k8/unseal.sh` + recorded for password manager),
    unsealed, bootstrapped (KV-v2 at `secret/` + Kubernetes auth + `external-secrets` policy/role),
    **re-seeded all 18 paths** from `reseed-map.json`. Result: `ClusterSecretStore openbao` → **Valid**,
    **48/48 ExternalSecrets `SecretSynced`**, OpenBao Initialized+Unsealed. **Zero data loss.**
  - Forensic correction: a fresh OpenBao 2.5.1 init also produces an `s.`-prefixed token, so the token
    format was NOT diagnostic — the real cause stands (keys never matched this data; proven by the
    10-combo test).

**Pins applied (the 4 floats → current versions, for deterministic installs):**
- K3s → `INSTALL_K3S_VERSION="v1.34.5+k3s1"` (`k8/bootstrap/install-k3s.sh`)
- Reflector → `--version 10.0.24` (`install.sh`)
- CloudNativePG → `--version 0.27.1` (`install.sh`)
- RabbitMQ Operator → pinned download `v2.20.0` (`install.sh`)

**Side findings → housekeeping (both RESOLVED 2026-06-05, post-Wave-0):**
- ✅ Velero **Garage BSL** was `Unavailable` — root cause: `k8/velero/values.yaml` bucket `velero-backups`
  but the actual Garage bucket alias is `velero` (matching loki/mimir/tempo/artifacts; velero key has RWO).
  Fixed values.yaml → `velero`, `helm upgrade velero`, BSL now **Available**, test backup `Completed`
  (0 errors). (The earlier "velero-server cannot watch pods" log was boot-time transient — gone.)
- ✅ **Ch.3 corrected** to the real model: stack is **Helm-managed, not ArgoCD** — all `argocd app sync`
  steps replaced with `helm upgrade <release> k8/<path>` (or `kubectl apply -k` for artifact-keeper);
  health probe now uses `helm ls` + OpenBao/ESO checks.
- Lima snapshot is `unimplemented` on the vz backend → VM-snapshot gate not available; rely on per-component backups + reproducible install.

_Checklist:_
- [x] Platform started (VM + cluster up) — OpenBao came up sealed; **recovered via re-init**
- [x] Captured live versions of the 4 floats
- [x] OpenBao recovery (re-init + re-seed, 48/48 ExternalSecrets synced)
- [x] Pinned the 4 versions in git (as-is)
- [x] Health baseline recorded (node Ready v1.34.5, 0 bad pods, OpenBao unsealed, 48/48 synced)
- [x] Backups: OpenBao volume tar ✅ + reseed-map ✅ / Velero ❌ (Garage BSL down) / Lima snapshot ❌ (vz unsupported)
- [x] Log committed + pushed

### Wave 1 — Image supply chain — ✅ DONE (67bb17d)

**Goal:** mirror all target `-arm64` images into the remote registry (`artifactory.cfapps.cool/docker-local`)
so both the upgrade *and a clean install* can pull them; fix moved upstream sources.

- **New reusable tool:** `k8/mirror-platform-images.sh` — source-resolving (probes candidate upstream
  registries, uses the one that actually has the tag), idempotent (skips tags already present),
  additive-only (never overwrites). This is the install-path artifact that populates the registry.
- **Push auth:** the remote registry needed a write token. `svc-stack`/dev-token are pull-only and the
  `artifactory/.env` admin password is rejected by the remote; user issued a temporary RW token, stored
  in gitignored `tmp.secret` (revoke after migration). Note: the `k8/.env.local` "read-only" token
  actually has write — worth tightening later.
- **macOS prompt gotcha:** `~/.docker/config.json` has `credsStore: desktop`; crane invoking the Docker
  Desktop credential helper caused both the repeated "iTerm wants to access other apps' data" TCC prompts
  *and* multi-minute hangs. Fixed by running crane with a clean `DOCKER_CONFIG` (inline auth, no helper).
- **Mirrored 27 + 1 already-present = 28 target images** (0 unresolved, 0 failed) for waves 2–8:
  metallb v0.16.1, traefik v3.7.1, cert-manager v1.20.2 (×4), argocd v3.4.3 (quay.io), external-secrets
  v2.5.0 (ghcr.io), portainer 2.39.3, garage v2.3.0, technitium 15.2.0, velero v1.18.1 + aws-plugin
  v1.14.1, openbao 2.5.4 (quay.io), grafana 12.4.3 / loki 3.7.2 / mimir 3.1.0 / tempo 2.10.5 / alloy
  v1.16.2, kube-state-metrics v2.19.0, node-exporter v1.11.1, trivy 0.71.0 (ghcr.io), postgres 17.10,
  **opensearch 2.19.5** (Wave 7), gitlab-ce 18.11.4-ce.0 **and** 19.0.1-ce.0 (the required-stop hop),
  gitlab-runner alpine-v19.0.1.
- **Deferred to their waves (mirror just-in-time, moved sources):** kpack → **ghcr.io** (Wave 9),
  RabbitMQ operator → **ghcr.io** (Wave 10 — multi-arch, pulled direct, no mirror), Contour/Envoy (Wave 9), CloudNativePG → **ghcr.io** (Wave 10 — multi-arch, pulled direct).
  These aren't `docker-local` refs today and need per-wave handling.

_Checklist:_
- [x] Push auth resolved (temp RW token in `tmp.secret`, gitignored)
- [x] Built `k8/mirror-platform-images.sh` (source-resolving, idempotent, install-path tool)
- [x] Mirrored 28 target images (verified pullable) — 0 failures
- [x] Log committed + pushed

### Wave 2 — Host foundation (Lima + K3s) — ✅ DONE (39a4a52)

**Goal:** upgrade the substrate to the campaign target — K3s **1.34.5 → 1.36.1** — and ensure a fresh
install lands there too.

- **Lima:** already on 2.1.0 (latest line); `bootstrap/lima.yaml` validates. No risky VM rebuild needed.
  Tidied the Lima-2.x deprecation: top-level `rosetta` → `vmOpts.vz.rosetta` (install-path correctness).
- **Install path:** `k8/bootstrap/install-k3s.sh` pinned `INSTALL_K3S_VERSION` → **v1.36.1+k3s1** (a fresh
  install goes straight to 1.36; no hop needed for a clean system).
- **Live upgrade (in-place, one minor at a time, exact `--disable servicelb,traefik` flags preserved):**
  - Pre-flight: fresh OpenBao data tar + **Velero `wave2-pre` resources backup (Completed, 0 errors)**;
    all apiservices Available; CRD groups all operator-served (no core beta APIs removed by 1.35/1.36).
  - Hop 1 → **v1.35.5+k3s1**: node Ready, **0 bad pods, OpenBao stayed unsealed** (in-place upgrade kept
    workload pods running — only the control plane restarted), 48/48 ExternalSecrets synced.
  - Hop 2 → **v1.36.1+k3s1**: node Ready, 0 bad pods, OpenBao unsealed, ClusterSecretStore Valid, 48/48 synced.
- **kpack client-go skew check (the linchpin):** kpack (client-go 0.30) **works fine on K8s 1.36** —
  controller+webhook Running, CRDs served (3 Images / 4 Builds readable), ClusterBuilder ready, **no
  client-go/API errors** in logs. Confirms the Chapter 2 call: wide skew is a policy gap, not a functional
  one. (Full `cf push` validation deferred to Wave 9.) Korifi api+controllers healthy.

_Checklist:_
- [x] Pre-flight backup (Velero resources + OpenBao tar)
- [x] Install-path pinned to v1.36.1+k3s1; lima.yaml 2.x-clean
- [x] Live hop 1.34.5 → 1.35.5 → 1.36.1, healthy after each
- [x] kpack/Korifi verified functional on 1.36
- [x] Log committed + pushed

### Wave 3 — Networking & TLS edge — ✅ DONE (eb95e5e)

**Goal:** upgrade the edge (cert-manager, MetalLB, Traefik) on both the live cluster and the install path.
Mechanism per component: bump wrapper `Chart.yaml` (dep + appVersion) + `values.yaml` image tag →
`helm dependency update` (vendors the new dep `.tgz`) → `helm upgrade`. Vendored `charts/*.tgz` are
committed so a fresh `helm install` uses the same versions. Pre-flight: Velero `wave3-pre` (Completed).

- **cert-manager 1.20.0 → 1.20.2** (patch): all 4 images on v1.20.2-arm64, rollout clean, wildcard certs
  stay Ready. (Note: the controller image tag had a different indent than cainjector/webhook/acmesolver —
  needed a separate edit.)
- **MetalLB 0.15.3 → 0.16.1** (minor): controller+speaker on v0.16.1-arm64, LB IPs intact (200–203),
  L2Advertisement present. **Breaking-default caught:** chart 0.16 turns on **`frrk8s` by default** (extra
  pods pulling an un-mirrored `quay.io/metallb/frr-k8s` image, only for BGP/FRR). We run **L2 mode** →
  set `frrk8s.enabled: false` to keep the lean native-speaker setup.
- **Traefik chart 39.0.5 → 40.2.0 / app v3.6.10 → v3.7.1** (🔴 major chart): all our value keys still
  exist in the 40.2.0 schema; `--dry-run` passed; upgrade clean, single v3.7.1 pod. Routing+TLS verified
  via the LB IP — argocd **200**, grafana **302**, artifacts **200**, served cert `*.sys.cfapps.cool`.

**Discovery → RESOLVED (2026-06-05):** the live platform domain is `sys.cfapps.cool`. Investigation showed
`development.cfapps.cool` in the manifests is a **sed PLACEHOLDER** — `install.sh:261` does
`sed s/development.cfapps.cool/${PLATFORM_DOMAIN}/g` at install time, so the live `sys` came from the
configured `PLATFORM_DOMAIN`. **Fix (per user: domain should be `sys.cfapps.cool`):** changed the *default*
in `config.env` (`PLATFORM_DOMAIN=sys.cfapps.cool`) + all `${PLATFORM_DOMAIN:-…}` fallbacks in
`install.sh`/`stack.sh` from development→sys. **Left the manifest placeholders untouched** (they're the
sed source). Verified: `stack.sh status` now shows `*.sys.cfapps.cool` endpoints, all UP (argocd 200,
grafana 302, artifacts 200). Fresh installs now default to sys and substitute placeholders → sys.

_Checklist:_
- [x] cert-manager → 1.20.2 (certs Ready)
- [x] MetalLB → 0.16.1, frrk8s disabled (L2 intact, IPs 200–203)
- [x] Traefik → 40.2.0 / v3.7.1 (schema-checked, ingress+TLS verified 200/302)
- [x] Vendored chart deps committed (install-path)
- [x] Log committed + pushed

### Wave 4 — Secrets backbone (OpenBao → ESO) 🔴 — ✅ DONE (6d3e453)

**Goal:** OpenBao 0.8.0→0.28.3 / 2.5.1→2.5.4, then ESO 0.16.1→2.5.0 — the critical secret path. Order:
store first, then sync. Pre-flight: Velero `wave4-pre` (Completed) + fresh ESO-CR export + OpenBao data tar.

**Risk-reducer found in recon:** live ESO CRs are **already `external-secrets.io/v1`** (CRD storage=v1),
so there was **no v1beta1→v1 data migration** to do. Target charts confirmed (openbao 0.28.3=v2.5.4,
external-secrets 2.5.0=v2.5.0).

- **OpenBao → 2.5.4 / chart 0.28.3:** values keys compatible. `helm upgrade` **failed first** — the new
  chart changes an immutable StatefulSet field (the `volumeClaimTemplates` block; names match but
  labels/spec differ). Fix (reusable for GitLab/Postgres later): `kubectl delete sts openbao
  --cascade=orphan` (keeps pod + PVCs) → `helm upgrade` (recreates STS, adopts pod; selector+serviceName
  matched) → `kubectl delete pod openbao-0` (OnDelete strategy → recreate on 2.5.4, **reuses
  `data-openbao-0`**) → `bash k8/unseal.sh`. Result: 2.5.4 unsealed, **data preserved**, ESO still Valid + 48/48.
- **ESO → 2.5.0 (major):** migrated **14 real repo manifests** `external-secrets.io/v1beta1` → `/v1`
  (install-path; docs `.md` left as-is). `installCRDs: true` still valid in 2.5.0; values keys compatible;
  dry-run clean. `helm upgrade` rolled controller+webhook+cert-controller to v2.5.0. **ClusterSecretStore
  Valid, all 48 ExternalSecrets SecretSynced, 0 bad pods.**

_Checklist:_
- [x] Pre-flight backup + exports
- [x] OpenBao → 2.5.4 (orphan-recreate STS, data preserved, unsealed)
- [x] ESO repo manifests v1beta1 → v1 (install-path)
- [x] ESO → 2.5.0; ClusterSecretStore Valid, 48/48 SecretSynced
- [x] Vendored chart deps committed; log committed + pushed

### Wave 5 — Storage & platform — ✅ DONE (474414e)

**Goal:** Garage → ArgoCD → Portainer → Technitium → Velero, on both live + install path. Pre-flight:
Velero `wave5-pre` (resources) + `wave5-technitium` (PV fs-backup, major upgrade).

**Reusable learning — domain on `helm upgrade`:** components whose **chart values carry a domain**
(argocd `global.domain`, portainer `domain`) must be upgraded with `--set <domain>=…sys.cfapps.cool`,
else the repo's `development.cfapps.cool` placeholder reverts the live domain. Raw-manifest components
with a domain *env* (technitium) → use `kubectl set image` (image-only) to avoid reverting it.

- **Garage v2.2.0 → v2.3.0** (raw STS): `kubectl apply` hit the immutable-STS-field error → used
  `kubectl set image` (image-only). BSL went Unavailable for ~30s during the restart, **recovered to
  Available** on re-validation. S3 buckets intact.
- **ArgoCD v3.3.4 → v3.4.3** (chart 9.4.15 → 9.5.18): `--set argo-cd.global.domain=argocd.sys.cfapps.cool`;
  redis kept at 8.2.3-alpine-arm64 (still in registry, dry-run confirmed). All pods on v3.4.3, argocd.sys 200.
- **Portainer 2.39.0 → 2.39.3** (chart 239.0.2 → 239.3.0): `--set domain=sys.cfapps.cool`. portainer.sys 200.
- **Technitium 14.3.0 → 15.2.0** (🔴 major, raw Deployment): `kubectl set image` (preserves the live
  `dns.sys…` env). Config PV auto-migrated to v15; DNS still resolves internal zones (argocd.sys → LB IP).
- **Velero v1.18.0 → v1.18.1** (file:// vendored chart 12.0.0 → **12.0.2** replaced, Chart.lock regen) +
  **AWS plugin v1.14.0 → v1.14.1**. node-agent on v1.18.1. **Test backup Completed (0 errors)** end-to-end.
- **Velero UI** already at target (chart 0.14.0 / image 0.10.1) — no change.

**Verified:** all platform endpoints UP on sys (argocd/portainer/artifacts/backup/dns 200, grafana/gitlab
302, vault 307, s3 403=up), 0 bad pods, 48/48 ExternalSecrets synced.

_Checklist:_
- [x] Garage v2.3.0 (S3/BSL verified)
- [x] ArgoCD v3.4.3, Portainer 2.39.3 (domains pinned to sys)
- [x] Technitium 15.2.0 (major; PV migrated, DNS verified)
- [x] Velero v1.18.1 + plugin v1.14.1 (vendored chart 12.0.2; test backup passed)
- [x] Vendored chart deps committed; log committed + pushed

### Wave 6 — Monitoring (LGTM) — ✅ DONE (01c9e1d)

**Goal:** KSM/node-exporter/Alloy → Tempo → Loki/Grafana (grafana-community repo move) → Mimir 3.1, on
both live + install path. Pre-flight: Velero `wave6-monitoring` (monitoring,mimir) — Completed.

**Order & results (low→high blast radius):**
- **kube-state-metrics 2.18.0 → 2.19.0** (chart 7.2.2 → 7.4.0, prometheus-community). Clean.
- **node-exporter 1.10.2 → 1.11.1** (chart 4.52.2 → 4.55.0, prometheus-community). Clean.
- **Alloy v1.14.1 → v1.16.2** (chart 1.6.2 → 1.8.2, stays in grafana repo). Chart pins config-reloader
  `v0.91.0@sha256:…` (amd64 digest) → mirrored `prometheus-config-reloader:v0.91.0-arm64` and pinned
  `configReloader.image.tag` + `digest: ""` to drop the digest.
- **Tempo 2.9.0 → 2.10.5** (chart **repo move** grafana → `grafana-community`, 1.24.4 → **2.2.0**
  single-binary; fixes the prior 2.9.0↔2.10.3 drift). STS selector + `storage` VCT unchanged → in-place.
  S3 creds passed via a temp `-f` overlay (sourced from the live configmap; never committed — `install.sh`
  still sed-patches the `TEMPO_S3_*_PLACEHOLDER`s on a fresh install).
- **Loki 3.6.7 → 3.7.2** (chart **repo move** grafana → `grafana-community`, 6.55.0 → **17.1.6**; schema
  fully compatible). Creds via env from `loki-s3-credentials`. STS selector + `storage` VCT unchanged.
- **Grafana 12.4.1 → 12.4.3** (image-tag only). **Kept chart `grafana/grafana` 10.5.15** — the
  `grafana-community/grafana` 12.x charts ship appVersion **13.0.1** (AngularJS removed); staying on the
  frozen old-repo chart bumps the binary to 12.4.3 without the 13.0 dashboard-audit risk (deferred).
- **Mimir 3.0.4 → 3.1.0** (raw Deployment): `kubectl set image`. Already on 3.x so all TSDB blocks are
  index-v2 (no block migration needed); config carries no removed flags. New emptyDir rebuilds
  sparse-index-headers from Garage on start (benign warnings).

**🔴 Helm/ESO release-manifest fix (loki, grafana, tempo):** their revision-1 manifests (pre-Wave-4)
embedded `external-secrets.io/v1beta1` ExternalSecrets; that CRD version is gone, so `helm upgrade`
failed building the *current* release. Patched each stored `sh.helm.release.v1.<r>.v1` secret
`v1beta1 → v1` (metadata only; live objects already v1). Then SSA field-ownership conflicts
(`before-first-apply` owns `.spec.data`) → resolved by `kubectl delete externalsecret … --cascade=orphan`
(keeps the synced secret) before the upgrade so helm recreates+adopts it cleanly.

**🟢 Logging pipeline repaired (was never functional — 3 latent bugs, all fixed at source):**
1. `mounts.varlog`/`resources` were nested at `alloy.*` but the chart expects them under `alloy.alloy.*`
   → `/var/log` host mount was never created. Re-nested correctly.
2. `__path__` relabel used the default regex → `$1=uid/container`, `$2=empty` → double-slash glob
   (`/container//*.log`) Alloy v1.16's globber won't match. Added explicit `regex = "(.+)/(.+)"`.
3. `loki.source.file` does **not** glob-expand; inserted a `local.file_match "pods"` stage between
   `discovery.relabel` and `loki.source.file` (the documented Alloy file-discovery pattern).
   Also fixed wrong service DNS: Alloy `loki.write` + Grafana datasources pointed at `loki.loki.svc` /
   `tempo.tempo.svc:3100` — but both run in `monitoring` → corrected to `loki.monitoring.svc` /
   `tempo.monitoring.svc:3200`.

**Verified end-to-end:** Mimir `up` returns live targets; Alloy `files_active=99`,
`loki_write_sent_entries_total>3.2k` to `loki.monitoring.svc`; Loki has 24 namespaces + real log lines;
Grafana datasources Loki/Mimir/Tempo all **health=OK**. All 8 components at target, 0 bad pods.

_Checklist:_
- [x] KSM 2.19.0, node-exporter 1.11.1, Alloy v1.16.2 (config-reloader v0.91.0-arm64 mirrored)
- [x] Tempo 2.10.5, Loki 3.7.2 (both repo-moved to grafana-community)
- [x] Grafana 12.4.3 (image-only; chart kept at 10.5.15 to avoid Grafana 13/Angular)
- [x] Mimir 3.1.0 (raw; index-v2 confirmed)
- [x] Stored helm release manifests patched v1beta1→v1; ESO SSA conflicts resolved
- [x] Logging pipeline fixed (varlog mount, path regex, local.file_match, service DNS) — logs flow to Loki
- [x] Vendored chart deps committed; log committed + pushed

### Wave 7 — artifact-keeper (in-cluster) → 1.2.0 + OpenSearch 🔴 — 🔧 DONE (08973d4; AK storage follow-up resolved in Wave 9)

**Goal:** rc.8-patched → 1.2.0, Meilisearch → OpenSearch, on both live + install path. Pre-flight:
Velero `wave7-ak` (Completed) + logical `pg_dump` (177K, 92 tables) to `/tmp/ak-pg-wave7.sql.gz`.

**★ Strategy change (confirmed with user) — official upstream images, NO custom build.** Recon showed all
5 custom patches are now upstream in 1.2.0, so the documented "build `-patched` images" pipeline (clone /
git-apply / `cargo sqlx prepare` / multi-arch buildx / Docker Hub) is unnecessary:
- be/001, be/002 (revoked-token filter): upstream — `WHERE … AND revoked_at IS NULL` (profile.rs, users.rs).
- be/003 (API-token-as-docker-password): upstream — oci_v2.rs tries `validate_api_token(&password)`.
- web/001 (permissions repo dropdown): upstream — `repositoriesApi` + `targetOptions` + groups.
- web/002 (Select z-index): only-cosmetic, base `select.tsx` now ships `z-50`+`position` — dropped.
We mirror the official `ghcr.io/artifact-keeper/{backend,web}:1.2.0` (arm64) →
`docker-local/ghcr.io/artifact-keeper/…:1.2.0-arm64`, plus `opensearchproject/opensearch:2.19.5-arm64`.

**OpenSearch** (`k8/services/artifact-keeper/opensearch/` — StatefulSet+Service, VCT 5Gi): single-node,
`DISABLE_SECURITY_PLUGIN=true` (internal-only, plain http, no creds → no OpenBao secret), 1g heap
(`-Xms1g -Xmx1g`), `discovery.type=single-node` (skips bootstrap checks incl. vm.max_map_count). Green.

**v1.2.0 env-contract changes (caught by reading config.rs — would have silently broken storage):**
- `STORAGE_BACKEND` now defaults to **filesystem** → must set `=s3` explicitly (added to configmap).
- S3 cred env renamed `S3_ACCESS_KEY`/`S3_SECRET_KEY` → **`S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY`**
  (same underlying secret keys). Search env `MEILISEARCH_*` → `OPENSEARCH_URL`. Reindex is automatic
  (backend `is_index_empty()` → background `full_reindex` on startup) + manual `POST /api/admin/reindex`.

**🔴 Migration path rc.8 (v71) → 1.2.0 (v113): upstream bug + the v1.1.9-hop fix.** v1.2.0's
`migration_repair::repair_release_1_1_9_divergence` does `SELECT (checksum WHERE version=73),(…74),(…75)`
decoded as a **non-Option** `(Vec<u8>,Vec<u8>,Vec<u8>)`; that scalar-subquery row always exists but
returns NULL columns when 73/74/75 are absent — which they are coming from rc.8 (v71) → backend
CrashLoop `decoding column 0: unexpected null`. The repair assumes a **v1.1.9** install. Fix without
patching the image: temporary `kubectl set image` hop to **1.1.9-arm64** (mirrored) which applies
migrations 72–75 to v75 (search "not configured", migrations run regardless), then `set image` back to
1.2.0 — its repair now finds the 1.1.9 checksums, rewrites them (issue #1277 path), applies 76–113. A
**fresh install needs no hop** (empty DB applies all migrations cleanly with the 1.2.0 image).

**Cutover verified:** "Database migrations complete" (v113); OpenSearch indexes created;
`S3_ACCESS_KEY_ID/…` + "S3 connectivity probe succeeded", `Storage backends available: [filesystem, s3]`;
**background reindex 62 artifacts + 1 repository** into OpenSearch (artifacts index 62 docs, green);
`artifacts.sys /health 200`, web UI 200, `/api/v1/search/quick` + `/trending` 200. Meilisearch
decommissioned (workload + PVC + ExternalSecret deleted; manifests `git rm`).

**Install-path:** `kubectl apply -k` already pulls in `opensearch/` + drops `meilisearch/` via the updated
kustomization; install.sh: removed the obsolete meili OpenBao master_key, Meilisearch→OpenSearch strings;
`container-images.txt` swapped meili→opensearch + added the two ghcr `1.2.0` images. NOTE: the live
ingressroute + web `NEXT_PUBLIC_API_URL` carry the `development.cfapps.cool` *placeholder*; `kubectl apply`
(unlike install.sh's sed) reverted them → patched the live objects to `sys` (git keeps the placeholder).

_Checklist:_
- [x] All 5 patches verified upstream → run official `ghcr.io/artifact-keeper/*:1.2.0` (no custom build)
- [x] OpenSearch 2.19.5 stood up (1g heap, security off); Meilisearch decommissioned
- [x] Backend 1.2.0 + Web 1.2.0; STORAGE_BACKEND=s3, S3_ACCESS_KEY_ID/SECRET keys, OPENSEARCH_URL
- [x] rc.8→1.1.9→1.2.0 migration hop (upstream repair-null bug); v113, reindex 62 artifacts
- [x] Verified: health 200, web 200, search 200, S3 storage OK; install.sh + container-images.txt updated
- [x] Committed + pushed

### Wave 8 — GitLab CE 18.10 → 19.0.1 + Runner 🔴 — ✅ DONE (4d474aa)

**Goal:** GitLab CE `18.10.0 → 19.0.1` via required stops, Runner `18.10.0 → 19.0.1`, on both live +
install path. Pre-flight: Velero `wave8-gitlab` (gitlab,gitlab-runner) — Completed (rollback point to 18.10.0).

GitLab CE is a single **omnibus StatefulSet** (bundled PG/Redis/Gitaly, data on 3 PVCs); upgrade =
image bump + restart, omnibus runs `gitlab-ctl reconfigure` + DB migrations on startup (~8–12 min/hop).
Bumped via `kubectl set image` (raw-STS, image-only — preserves the gitlab.rb configmap + live env).
**Required-stop path (one minor at a time, migration-gated):**
- **18.10.0 → 18.10.7** (latest 18.10 patch): bg-migrations clean (0). ✓
- **18.10.7 → 18.11.4** (required stop): 1 active bg-migration `BackfillNamespaceTemplateSettings`
  self-completed via Sidekiq → bg clean (0), 0 failed. ✓ (gate: `batched_background_migrations`
  `status <> 3` must be 0 before crossing the next stop.)
- **18.11.4 → 19.0.1** (major): 0 down schema migs, 0 failed; **18 post-19.0 bg-migrations queued** and
  drain via Sidekiq (final target, not gated — they finish in the background, 0 failed).

Verified at each stop: in-pod `/-/readiness` 200, `gitlab.sys/users/sign_in` 200. (`/-/health` & `/-/readiness`
404 *externally* = GitLab's monitoring-IP allowlist, normal.) Final version `gitlab-ce 19.0.1`.

**Runner:** consolidated to a single hop (runner is forward/back-compatible and was ≤ CE throughout, so
the intermediate 0.88.3 was unnecessary). Chart **0.87.0 → 0.89.1** / image **alpine-v18.10.0 →
alpine-v19.0.1**, vendored `charts/gitlab-runner-0.89.1.tgz`. `helm upgrade --set gitlab-runner.gitlabUrl=
https://gitlab.sys.cfapps.cool/` (else the development.cfapps.cool placeholder reverts the live URL).
🔴 Same **stored-release v1beta1** issue as Wave 6 (runner release rev-1 embeds an ESO v1beta1 secret) →
patched `sh.helm.release.v1.gitlab-runner.v1` v1beta1→v1 + `--cascade=orphan` ES delete (keeps the
registration secret) before the upgrade. Runner binary 19.0.1, "Configuration loaded", ES re-synced.

**Install-path:** git = final 19.0.1 / runner 0.89.1 (a fresh install initializes GitLab at 19.0.1 directly —
no hop; the 18.10.7/18.11.4 stops are live-upgrade-only). Images 18.10.7-ce.0, 18.11.4-ce.0, 19.0.1-ce.0
(arm64) + runner alpine-v18.11.3/v19.0.1 mirrored.

**Side-fix (user-reported):** Traefik dashboard `traefik.sys` was 404 — live IngressRoute carried the
`traefik.development.cfapps.cool` placeholder (reverted by the Wave 3 traefik helm upgrade). values.yaml
uses the placeholder (install.sh seds it → install path fine); patched the **live** route to `sys` →
root 302 / `/dashboard/` 200.

_Checklist:_
- [x] CE 18.10.0 → 18.10.7 → 18.11.4 → 19.0.1 (required stops; bg-migrations gated clean at each stop)
- [x] Runner chart 0.87.0 → 0.89.1, image alpine-v19.0.1 (vendored); gitlabUrl pinned to sys; ES re-synced
- [x] Stored runner helm-release patched v1beta1→v1 (Wave 6 pattern)
- [x] Verified 19.0.1 healthy, runner connected (binary 19.0.1); post-19.0 bg-migrations draining (0 failed)
- [x] Traefik dashboard live route fixed to sys; committed + pushed

### Wave 9 — CF/Korifi + kpack + Contour/Envoy — 🔧 DONE (dc118e6; AK fix c993708/cccab7f; cf push verified)

**Goal:** kpack → 0.17.1, Contour → v1.33.5, Envoy → distroless-v1.35.10 (paired), Korifi unchanged
(v0.18.0, already latest). Pre-flight: Velero `wave9-cf` (korifi,kpack,projectcontour,korifi-gateway).

**kpack 0.17.0 → 0.17.1 — self-built native arm64 (plan note was wrong).** Upstream kpack 0.17.1 ghcr
images are **amd64-only** (no arm64, no `-arm64` tags) — confirmed via `crane config` (arch=amd64). So the
plan's "from ghcr.io, no self-build" does NOT hold for arm64; we must self-build (as 0.17.0 was). Bumped
`k8/services/kpack/build-arm64.sh` to 0.17.1 + made it bash-3.2-safe (replaced `declare -A` with a `case`
function), re-cloned src@v0.17.1, native `GOARCH=arm64` compiled the 6 binaries + crane-pushed to
`docker-local/kpack/*:0.17.1-arm64` (verified arch=arm64), then `kubectl set image` + `set env`
(BUILD_INIT/WAITER/REBASE/COMPLETION). Controller/webhook on 0.17.1 (commit 43e0081), no emulation.
install.sh: kpack v0.17.1 release URL + KPACK_TAG.

**Contour v1.33.3 → v1.33.5 / Envoy distroless-v1.35.9 → v1.35.10 (paired).** Deployed from upstream
quickstart (ghcr.io/docker.io direct). `kubectl set image` on `deploy/contour` (contour) + `ds/envoy`
(shutdown-manager, envoy-initconfig → contour v1.33.5; envoy → distroless-v1.35.10). Pods healthy,
CF API route `api.app/v3` 200, no contour errors. install.sh: pinned quickstart to
`raw.githubusercontent.com/projectcontour/contour/v1.33.5/examples/render/contour.yaml` (was "latest";
now reproducible) + pre-pull refs v1.33.5/v1.35.10; mirrored both to the registry (`-arm64`).

**🔴 DISCOVERED — Wave 7 regression, tracked as follow-up (user decision: finish Contour/Envoy, fix AK
separately).** The kpack restart forced a fresh image re-resolution, exposing that the **in-cluster
artifact-keeper 1.2.0 OCI registry serves manifests unreliably**: backend logs `"oci_tags row found but
storage file missing"` and images **flap** (java/stacks 0/5, then java 3/3, then 0/5 again; 6 buildpacks
stable 5/5). The old kpack controller had masked this with cached digests. Authorized repair (clear stale
`:latest` tag + re-push fresh — AK 1.2.0 does NOT update an existing tag on re-push) **fixed 6/7
buildpacks** but does NOT converge for java + the 2 jammy stacks (manifest PUT → 201 but content doesn't
reliably serve back). Root cause is an AK 1.2.0 storage read-path/consistency bug, NOT kpack. **No working
functionality regressed** — cf push was already blocked (petclinic Paketo ca-certs) and the old "ready"
ClusterBuilder was cosmetic (builds would have failed on stack pull anyway). Rollback to rc.8 is hard (DB
migrated to v113). **kpack ClusterStore/Builder remain not-ready until the AK registry is fixed** — see
follow-up below.

_Checklist:_
- [x] kpack 0.17.1 self-built **native arm64** (upstream is amd64-only) + deployed; build-arm64.sh + install.sh updated
- [x] Contour v1.33.5 + Envoy distroless-v1.35.10 (paired); CF API route 200; quickstart pinned + mirrored
- [x] Korifi unchanged (v0.18.0 latest)
- [x] **RESOLVED (commits c993708/cccab7f): AK kpack/CF manifest failure.** Root cause = korifi repo on
      filesystem/emptyDir (ephemeral), wiped by Wave 7's restart → converted korifi to s3 (Garage), durable.
      The "flapping read bug" was a zsh `:l` modifier artifact in repair commands (`$bp:latest`→`${bp:l}atest`)
      → re-pushed 6 buildpacks to correct tags (bash). kpack ClusterStack/Store/Builder all Ready; pipeline
      restored. (cf push may still hit the separate petclinic Paketo ca-certs issue.)
- [x] Committed + pushed
- [x] **cf push smoke test PASSED (2026-06-06):** Go app → kpack build → droplet to artifacts.sys (s3) →
      pod 1/1 → Contour/Envoy route → `https://cf-smoke.app.cfapps.cool` HTTP 200. Build pipeline fully healthy.
- [x] **Side-fix:** `cf push`/`cf app`/`cf logs` returned 500 on the log-cache /stats path
      (`x509: unknown authority`) — korifi `korifi-api-internal-cert` is **self-signed** and renewed 2026-06-04;
      korifi-api held a stale CA. `kubectl rollout restart deploy/korifi-api-deployment -n korifi` fixed it
      (verified `cf app` shows live stats). **Recurs ~every 90d (next renewal 2026-08-03)** → restart again;
      dated TODO in §3.1 + memory `project_korifi_api_selfsigned_cert_restart`.

### Wave 10 — Brokers & operators — ✅ DONE (2026-06-06)
**Operators (bumped in place; both already pull multi-arch images directly from ghcr.io — preserved that
existing pattern, no artifactory mirror needed):**
- **CloudNativePG** chart `0.27.1`→`0.28.2`, app `1.28.1`→`1.29.1` (`helm upgrade cnpg` + install.sh bumped).
  Operator rolled both managed PG clusters in place ("Primary instance is being restarted without a switchover",
  single-instance → brief downtime, PVC data preserved). **Verified both `pg-d4e347fa` + `pg-f27a2d50` returned
  to healthy state** (PG 18.1 unchanged).
- **RabbitMQ cluster-operator** `v2.20.0`→`v2.21.0` (`kubectl apply` upstream manifest + install.sh URL bumped).
  Operator pod Ready. No managed RabbitMQ clusters live → zero-risk. **CORRECTION:** the plan note said the
  image "moves to quay.io" — it does **not**; v2.21.0 manifest still uses `ghcr.io/rabbitmq/cluster-operator:2.21.0`
  (multi-arch). §2.6 note was wrong; image source unchanged.

**RabbitMQ server pinned to 4.3.1** (separate follow-up, broker `1.6.0`): operator 2.21.0 defaults the
managed RabbitMQ server image to **4.2.6-management** (compiled-in default, pulled direct from Docker Hub —
no `DEFAULT_RABBITMQ_IMAGE` env in the manifest). The operator does not version-gate, so pinned
`spec.image: rabbitmq:4.3.1-management` in the broker provisioner (`provisioners/rabbitmq.go`). 4.3.1-management
is a multi-arch index incl. `linux/arm64`, pulled direct from Docker Hub — matches the operator's own default
and the CNPG PG-server upstream-pull pattern (no artifactory mirror). **Verified:** `cf create-service rabbitmq`
→ operator stamps `rabbitmq:4.3.1-management`, pod AllReplicasReady, `rabbitmqctl version` = **4.3.1**, bind
returns full amqp creds; test instance deleted.

**All broker-managed workload images moved to the artifactory mirror (broker `1.7.0`):** previously the
cf-service-broker's three provisioned services pulled direct from upstream (postgres = CNPG operator default
ghcr.io; rabbitmq + valkey = Docker Hub). For offline / rate-limit safety and consistency with the
marketplace-broker (which already used `timescaledb-ha:pg17-arm64` from artifactory), mirrored all three as
`-arm64` and repointed the provisioners (+ `imagePullSecrets: artifact-keeper-pull`):
- `rabbitmq:4.3.1-management` → `docker-local/rabbitmq:4.3.1-management-arm64` (`provisioners/rabbitmq.go` `spec.image`)
- `valkey/valkey:8.1-alpine` → `docker-local/valkey/valkey:8.1-alpine-arm64` (`VALKEY_IMAGE` env + `valkey.go` pull secret)
- `ghcr.io/cloudnative-pg/postgresql:18.1-system-trixie` → `docker-local/ghcr.io/cloudnative-pg/postgresql:18.1-system-trixie-arm64` (`postgresql.go` `spec.imageName`)
Added all three to `mirror-platform-images.sh` (install-path inventory). **Verified:** `cf create-service`
for postgres/valkey/rabbitmq all provision 1/1 with images pulled **from artifactory**; test instances deleted.
(NOTE: the cnpg/rabbitmq OPERATOR controller images still pull multi-arch direct from ghcr.io — intentional.)

**Remote registry cleanup (2026-06-06):** the campaign's mirroring was additive-only, so `docker-local` had
accumulated to **25.0 GB / 26.8 GB (93%)**. Removed **62 stale tags** — korifi Mar-21 build orphans (this
registry; in-cluster Korifi uses `artifacts.sys`), all `-amd64` (arm64-only stack), and superseded arm64
versions incl. 3× old GitLab CE upgrade hops → **12.36 GB (46%), 14.49 GB free** (~12.65 GB reclaimed).
**KEPT:** all current versions, ghcr AK `1.1.9` (Wave-12 migration hop) + `1.2.0`, and `andrlange/*` rc.8 +
meilisearch (remote AK/Plane B may still run those until Wave 12). Delete mechanism (OCI DELETE is disabled in
this AK build): `DELETE /api/v1/repositories/docker-local/artifacts/{path}` with the listing `path` field
**`%2F`-encoded** + an **admin** user (dev/svc-stack tokens can push but not delete); then `POST
/api/v1/admin/storage-gc`. See memory `reference_ak_registry_delete_api`. TODO: trim the GitLab `18.11.4` hop
from `mirror-platform-images.sh` in Wave 13 (fresh installs go straight to 19.0.1).

**Go brokers (rebuilt + re-pushed to artifactory `docker-local`):** both `go.mod` → `go 1.26.4`, `k8s.io/*`
`v0.35.3`→`v0.36.1`, `go mod tidy`, built `linux/arm64`, mirrored via crane.
- `cf-service-broker` `1.4.0`→`1.5.0`→`1.6.0`→**`1.7.0-arm64`** (1.6.0 = RabbitMQ 4.3.1 pin; 1.7.0 = workload images from artifactory)
- `cf-marketplace-broker` (live `1.1.0`, source-drifted at `1.0.0`) →**`1.2.0-arm64`** (digest `b5c85a20`)
- Source reconciled: `deployment.yaml` (both), `lib/phase9.sh` (both build steps 1.0.0→1.2.0 / 1.4.0→1.5.0),
  `install.sh` phase7 build tag (stale `1.3.1`→`1.5.0` to match deployment.yaml — was a latent fresh-install
  ImagePullBackOff). Live deploy via `kubectl set image` (preserves OpenBao-seded broker password).
- `go vet` clean both; mb has no tests; the 2 `TestS3*` failures in sb are **pre-existing** (Garage admin API
  v1/v2 mock drift, HTTP-only, unrelated to the k8s bump — proven identical on pre-Wave-10 committed code).

**Exit criteria MET:** `cf marketplace` lists all 7 offerings across both brokers (`k8s-services`:
postgresql/valkey/rabbitmq/s3 · `marketplace-broker`: postgres-ai/ai-connector/openbao-secrets). **Bind
verified** via `cf create-service-key petclinic-db wave10-test` against the upgraded sb 1.5.0 + CNPG-1.29.1
cluster `pg-f27a2d50` — full credentials returned (incl. `type` field); test key deleted.

### Wave 11 — Plane B vault (OpenBao) — ✅ DONE (DESCOPED, user 2026-06-06)
**Out of scope for this platform.** The remote `vault/` (OpenBao) stack is **demo-only and lives OUTSIDE this
platform** — it is not a dependency of Plane A and is not aligned as part of this campaign. Marked done/descoped.
(The `plans/planeb-remote-runbook.md` retains the vault phase as reference if it is ever wanted, but it is not
required here. The in-cluster OpenBao — the one Plane A actually uses — was already upgraded in Wave 4.)

### Wave 12 — Remote artifact-keeper → 1.2.0 — ✅ DONE (2026-06-06)
The pull source (artifactory.cfapps.cool) was upgraded **rc.8 → 1.2.0** (on-disk storage-layout migration
`{repo}/oc/oci-* → {repo}/oci-*` + generic-repo layout fix; 61 orphaned tags pruned). **Consumer-side verified
from Plane A:** all **46/46** referenced docker-local images resolve manifest **and** config blob, both generic
artifacts (`installer-v1.1.2.sh`, `stack-v1.1.2.tgz`) download with valid integrity — **zero migration
regressions**. One pre-existing break found+fixed (not migration-caused): `trivy/deployment.yaml` pinned the
Wave-10-deleted `0.69.3-arm64` → bumped to `0.71.0-arm64` (commit 942d1b5). Runbook `plans/planeb-remote-runbook.md`
Phase 3 documents the procedure (official ghcr 1.2.0, meili→OpenSearch 2.19.5, env contract, rc.8→1.1.9→1.2.0
hop, reindex). **Registry note:** OCI manifest-DELETE is disabled; effective delete = admin-*user* (tokens can
push + catalog-delist only); see memory `reference_ak_registry_delete_api`.

### Wave 13 — Re-cut distribution (v1.1.2 → v1.2.0) — ⬜ NOT STARTED
`./build-distribution.sh`; rename installer-v1.2.0.sh / stack-v1.2.0.tgz; upload to remote generic repo; bump
installer pre-flight Go check to 1.26.4; write UPGRADE-v1.2.0.md. Exit: fresh install from new artifacts works.

### Wave 14 — Spring apps — ⏸ DEFERRED
kappman + petclinic (Spring Boot 4.0.x / Java 25 / Paketo Java 21.4.0 locked triple), after next week's
upstream Spring release. NOTE: petclinic cf push also blocked by Paketo ca-certificates scanning Korifi
binding mounts (separate; see memory project_petclinic_cf_push).
