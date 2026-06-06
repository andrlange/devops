# Upgrade to Stack v1.2.0

Stack v1.2.0 is the result of the **"latest everywhere"** upgrade campaign: every component was
moved to its current release, all broker-managed workloads are now pulled from `artifactory.cfapps.cool`,
and the container registry (artifact-keeper) itself was upgraded to 1.2.0. This is a drop-in replacement
for v1.1.2 — same install flow, newer images.

## Fresh Installation

Remove any previous installer files and download v1.2.0 in one command:

```bash
rm -f installer.sh stack.tgz && \
  curl -sfL https://artifactory.cfapps.cool/api/v1/repositories/generic/download/installer-v1.2.0.sh -o installer.sh && \
  curl -sfL https://artifactory.cfapps.cool/api/v1/repositories/generic/download/stack-v1.2.0.tgz -o stack.tgz && \
  bash installer.sh
```

This downloads both artifacts, then launches the interactive installer which deploys all 9 phases automatically.

> **Prerequisite change:** the installer pre-flight now requires **Go ≥ 1.26.4** (was 1.26). If your Go is
> older, the installer will offer to `brew upgrade go`. Everything else (macOS 26+, Apple M4+, kubectl 1.28+,
> Helm 3.12+, Lima 1.0+, CF CLI 8+) is unchanged.

## Extending an Existing Environment

If you already have a running v1.1.x stack, you can pull the new images and roll the changed workloads
without re-running the full installer.

### Step 1: Update the stack files

```bash
cd ~/devops-stack
rm -f installer.sh stack.tgz
curl -sfL https://artifactory.cfapps.cool/api/v1/repositories/generic/download/stack-v1.2.0.tgz -o stack.tgz
tar xzf stack.tgz
```

### Step 2: Mirror the new images to your registry

v1.2.0 references newer image tags. Mirror them into `artifactory.cfapps.cool/docker-local` (additive,
skip-existing):

```bash
cd ~/devops-stack/k8
REGISTRY_TOKEN=<your-push-token> ./mirror-platform-images.sh
```

### Step 3: Roll the changed workloads

```bash
# artifact-keeper Trivy scanner -> 0.71.0
kubectl -n artifact-keeper set image deploy/trivy \
  trivy=artifactory.cfapps.cool/docker-local/aquasecurity/trivy:0.71.0-arm64

# CF service brokers
kubectl -n korifi set image deploy/cf-service-broker \
  cf-service-broker=artifactory.cfapps.cool/docker-local/cf-service-broker:1.7.0-arm64
kubectl -n korifi set image deploy/cf-marketplace-broker \
  cf-marketplace-broker=artifactory.cfapps.cool/docker-local/cf-marketplace-broker:1.2.0-arm64
```

> Use `kubectl set image` (not a manifest re-apply) so the OpenBao-seeded broker credentials and the
> domain placeholders substituted at install time are preserved.

### Step 4: Verify

```bash
cf marketplace          # still 7 offerings across both brokers
kubectl -n artifact-keeper get pods   # trivy 1/1 Running on 0.71.0
```

## What's New in v1.2.0

### Service brokers & broker-managed workloads
- **cf-service-broker 1.7.0** and **cf-marketplace-broker 1.2.0** — rebuilt on **Go 1.26.4** /
  `k8s.io/* v0.36.1`.
- **RabbitMQ 4.3.1** — instances created via `cf create-service rabbitmq` now run
  `rabbitmq:4.3.1-management-arm64`, pulled from artifactory (not ghcr.io).
- **Valkey 8.1-alpine** and **CloudNativePG PostgreSQL 18.1** provisioned instances also now pull
  exclusively from artifactory (`docker-local`), with `imagePullSecrets: artifact-keeper-pull` stamped on
  every managed CR.
- All three broker-managed workload images are part of the install-path inventory
  (`mirror-platform-images.sh`), so a fresh install on a naked system serves them locally.

### Operators
- **CloudNativePG** Helm chart **0.28.2** (was 0.27.1).
- **RabbitMQ Cluster Operator** manifest **v2.21.0** (was v2.20.0; stays on ghcr.io).

### Registry / platform
- **artifact-keeper 1.2.0** — the registry powering `artifactory.cfapps.cool` was upgraded rc.8 → 1.2.0
  (on-disk storage-layout migration, meilisearch → OpenSearch). All 46 platform image references and the
  generic artifacts verified to pull cleanly post-migration.
- **Trivy 0.71.0** scanner for artifact-keeper image scanning.
- Registry housekeeping: 62 stale/superseded tags pruned; `docker-local` reduced from 93% → 46% usage.

### Installer
- Pre-flight **Go requirement bumped to 1.26.4** (matches the broker build toolchain).
- GitLab CE install path simplified to deploy **19.0.1** directly (the 18.11.4 in-place-upgrade stop is no
  longer mirrored — it was never on the fresh-install path).

### Deferred
- **Spring apps** (kappman + petclinic on Spring Boot 4.0.x / Java 25) are intentionally held back until the
  next upstream Spring release.
