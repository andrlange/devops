# Phase 4: Services — artifact-keeper

## Overview

**Goal:** Deploy the artifact-keeper Artifact Registry on the K8s cluster. artifact-keeper manages container images, Helm charts, and generic artifacts with PostgreSQL as the database, Meilisearch as the search index, and Garage S3 as the storage backend.

**Prerequisites:**
- Phase 3 (Monitoring) fully completed
- Garage S3 bucket `artifacts` created and API keys stored in OpenBao
- External Secrets Operator (ESO) with ClusterSecretStore `openbao` configured
- Container images imported into the registry:
  - `andrlange/artifact-keeper-backend:v1.1.0-rc.8-patched`
  - `andrlange/artifact-keeper-web:v1.1.0-rc.8-patched`
  - `postgres:17.9`
  - `getmeili/meilisearch:v1.39.0`
  - `aquasecurity/trivy:0.69.3`

**Architecture:**

```
                     ┌──────────────────────────────────────┐
                     │      Traefik IngressRoute            │
                     │  artifacts.development.cfapps.cool   │
                     └──────────┬───────────┬───────────────┘
                                │           │
          /api/,/v2/,/helm/,    │           │  / (catch-all)
          /generic/,/health,    │           │
          /metrics              │           │
                                ▼           ▼
                     ┌──────────────┐  ┌──────────────┐
                     │   Backend    │  │   Web UI     │
                     │  (Port 8080) │  │  (Port 3000) │
                     │  v1.1.0-rc.8 │  │  v1.1.0-rc.8 │
                     │   -patched   │  │   -patched   │
                     └──┬───┬───┬───┘  └──────────────┘
                        │   │   │
              ┌─────────┘   │   └─────────┐
              ▼             ▼             ▼
       ┌────────────┐ ┌────────────┐ ┌────────────┐
       │ PostgreSQL │ │Meilisearch │ │  Garage S3 │
       │   17.9     │ │  v1.39.0   │ │ "artifacts"│
       │ StatefulSet│ │ Deployment │ │  (external) │
       └────────────┘ └────────────┘ └────────────┘
                        │
                        ▼
                 ┌────────────┐
                 │   Trivy    │
                 │  v0.69.3   │
                 │ (Port 8090)│
                 │(Deployment)│
                 └────────────┘
```

**Components and Versions:**

| Component                | Version              | Deployment Method    |
|--------------------------|----------------------|----------------------|
| artifact-keeper Backend  | v1.1.0-rc.8-patched  | Kustomize (Deployment) |
| artifact-keeper Web UI   | v1.1.0-rc.8-patched  | Kustomize (Deployment) |
| PostgreSQL               | 17.9                 | Kustomize (StatefulSet) |
| Meilisearch              | v1.39.0              | Kustomize (Deployment) |
| Trivy Scanner            | 0.69.3               | Kustomize (Deployment) |

**All container images are sourced from the internal Artifactory registry (`artifactory.cfapps.cool`) and are ARM64-compatible.**

---

## 4.1 Kustomization Structure

artifact-keeper is fully deployed with Kustomize. All resources reside in the `artifact-keeper` namespace.

### Kustomization

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: artifact-keeper
resources:
  - namespace.yaml
  - external-secrets.yaml
  # PostgreSQL
  - postgresql/pvc.yaml
  - postgresql/statefulset.yaml
  - postgresql/service.yaml
  # Meilisearch
  - meilisearch/pvc.yaml
  - meilisearch/deployment.yaml
  - meilisearch/service.yaml
  # artifact-keeper backend
  - artifact-keeper/configmap.yaml
  - artifact-keeper/deployment.yaml
  - artifact-keeper/service.yaml
  # artifact-keeper web frontend
  - artifact-keeper/deployment-web.yaml
  - artifact-keeper/service-web.yaml
  # Trivy Scanner
  - trivy/deployment.yaml
  - trivy/service.yaml
  # Ingress
  - ingressroute.yaml
commonLabels:
  app.kubernetes.io/part-of: artifact-keeper
  app.kubernetes.io/managed-by: kustomize
```

### Installation

```bash
kubectl apply -k k8/services/artifact-keeper
```

---

## 4.2 PostgreSQL (Database)

### Description

PostgreSQL 17.9 serves as the primary database for artifact-keeper. It stores metadata for artifacts, users, and repositories.

### Deployment

- **Mode:** StatefulSet (for stable network identity and persistent storage)
- **Replicas:** 1
- **Image:** `artifactory.cfapps.cool/docker-local/postgres:17.9-arm64`
- **Port:** 5432
- **Service:** `postgres` (ClusterIP)

### Credentials

Database credentials are synchronized from OpenBao via ExternalSecret:

```yaml
- secretKey: POSTGRES_USER
  remoteRef:
    key: secret/artifact-keeper/postgres
    property: username
- secretKey: POSTGRES_PASSWORD
  remoteRef:
    key: secret/artifact-keeper/postgres
    property: password
- secretKey: POSTGRES_DB
  remoteRef:
    key: secret/artifact-keeper/postgres
    property: database
```

The resulting Secret `postgres-credentials` is referenced by both the PostgreSQL StatefulSet and the Backend Deployment.

### Persistence

PostgreSQL uses a PVC (Persistent Volume Claim) via the local-path provisioner.

---

## 4.3 Meilisearch (Search Index)

### Description

Meilisearch v1.39.0 provides fast full-text search across all artifacts. The backend service automatically indexes new artifacts.

### Deployment

- **Mode:** Deployment
- **Replicas:** 1
- **Image:** `artifactory.cfapps.cool/docker-local/getmeili/meilisearch:v1.39.0-arm64`
- **Port:** 7700
- **Service:** `meilisearch` (ClusterIP)
- **Persistence:** PVC via local-path provisioner

### Credentials

The Meilisearch master key is synchronized from OpenBao via ExternalSecret:

```yaml
- secretKey: MEILI_MASTER_KEY
  remoteRef:
    key: secret/artifact-keeper/meilisearch
    property: master_key
```

---

## 4.4 artifact-keeper Backend

### Description

The backend service is the central API component. It manages artifacts, authenticates users, and coordinates communication with PostgreSQL, Meilisearch, and Garage S3.

### Deployment

- **Replicas:** 1
- **Strategy:** Recreate (no rolling update, as DB migrations run)
- **Image:** `artifactory.cfapps.cool/docker-local/andrlange/artifact-keeper-backend:v1.1.0-rc.8-patched-arm64`
- **Port:** 8080
- **Service:** `artifact-keeper` (ClusterIP)

### Init Containers

The backend deployment uses two init containers to ensure dependencies are ready:

1. **wait-for-postgres:** Waits until PostgreSQL is reachable (`pg_isready`)
2. **wait-for-meilisearch:** Waits until the Meilisearch health endpoint responds

### Configuration (ConfigMap)

Non-sensitive configuration is stored in the ConfigMap `artifact-keeper-config`:

```yaml
DATABASE_HOST: postgres
DATABASE_PORT: "5432"
MEILISEARCH_URL: http://meilisearch:7700
S3_ENDPOINT: http://garage.garage.svc:3900
S3_BUCKET: artifacts
S3_REGION: garage
STORAGE_PATH: /data/storage
BACKUP_PATH: /data/backups
```

### Environment Variables

The backend container uses a combination of:

- **ConfigMap references:** S3 endpoint, bucket, region, Meilisearch URL, storage paths
- **Secret references (individual):** PostgreSQL credentials (for DATABASE_URL composition), S3 credentials, Meilisearch API key
- **Secret reference (envFrom):** `artifact-keeper-credentials` for JWT_SECRET, ADMIN_PASSWORD, MIGRATION_ENCRYPTION_KEY

The `DATABASE_URL` is composed in the pod from individual Secret values:

```yaml
- name: DATABASE_URL
  value: postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/$(POSTGRES_DB)
```

### Health Checks

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 30

readinessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 5
```

### Resources

```yaml
resources:
  requests:
    memory: 256Mi
    cpu: 250m
  limits:
    memory: 512Mi
    cpu: 500m
```

---

## 4.5 artifact-keeper Web UI

### Description

The Web UI is a Next.js-based frontend that uses the backend's REST API. It provides a graphical interface for managing and browsing artifacts.

### Deployment

- **Replicas:** 1
- **Image:** `artifactory.cfapps.cool/docker-local/andrlange/artifact-keeper-web:v1.1.0-rc.8-patched-arm64`
- **Port:** 3000
- **Service:** `artifact-keeper-web` (ClusterIP)

### Configuration

```yaml
env:
  - name: NEXT_PUBLIC_API_URL
    value: "https://artifacts.development.cfapps.cool/api"
```

The API URL points to the external URL so that browser requests are routed through the ingress.

### Health Checks

```yaml
readinessProbe:
  httpGet:
    path: /
    port: http
  initialDelaySeconds: 10
  periodSeconds: 10

livenessProbe:
  httpGet:
    path: /
    port: http
  initialDelaySeconds: 15
  periodSeconds: 30
```

### Resources

```yaml
resources:
  requests:
    memory: 128Mi
    cpu: 100m
  limits:
    memory: 256Mi
    cpu: 250m
```

---

## 4.6 IngressRoute (Traefik)

### Description

artifact-keeper uses a single Traefik IngressRoute with path-based routing to forward requests to either the backend or the Web UI.

### Host

```
artifacts.development.cfapps.cool
```

### Routing Rules

| Path | Target Service | Port | Description |
|------|---------------|------|-------------|
| `/api/` | artifact-keeper | 8080 | REST API |
| `/v2/` | artifact-keeper | 8080 | Docker Registry API (OCI) |
| `/helm/` | artifact-keeper | 8080 | Helm Chart Repository |
| `/generic/` | artifact-keeper | 8080 | Generic Artifact Storage |
| `/health` | artifact-keeper | 8080 | Health Check Endpoint |
| `/metrics` | artifact-keeper | 8080 | Prometheus Metrics |
| `/` (catch-all) | artifact-keeper-web | 3000 | Web UI (Priority 1) |

The Web UI route has `priority: 1` (lowest priority), so all more specific paths take precedence.

### TLS

```yaml
tls: {}
```

The IngressRoute uses the default TLSStore with the wildcard certificate for `*.development.cfapps.cool`.

---

## 4.7 Trivy Scanner (Vulnerability Scanning)

### Description

Trivy runs as a server-mode deployment alongside artifact-keeper and provides a vulnerability scanning API. The artifact-keeper backend service uses Trivy to scan container images and artifacts for security vulnerabilities.

### Deployment

- **Mode:** Deployment
- **Replicas:** 1
- **Image:** `artifactory.cfapps.cool/docker-local/aquasecurity/trivy:0.69.3-arm64`
- **Port:** 8090
- **Service:** `trivy` (ClusterIP)
- **Command:** `trivy server --listen 0.0.0.0:8090`

### Integration with artifact-keeper

The artifact-keeper backend service is connected to Trivy via two environment variables. These are set in the ConfigMap `artifact-keeper-config`:

```yaml
TRIVY_URL: http://trivy:8090
SCAN_WORKSPACE_PATH: /tmp/trivy-scan
```

#### For Docker Compose (Development)

When using a Docker Compose environment, a `trivy` service must be added and the `TRIVY_URL` environment variable set in the backend service:

```yaml
trivy:
  image: aquasecurity/trivy:0.69.3
  command: ["server", "--listen", "0.0.0.0:8090"]
  ports:
    - "8090:8090"

backend:
  environment:
    - TRIVY_URL=http://trivy:8090
    - SCAN_WORKSPACE_PATH=/tmp/trivy-scan
```

---

## 4.8 ExternalSecrets

### Description

All credentials are synchronized from OpenBao via the External Secrets Operator (ESO). There are four ExternalSecrets:

### Overview

| ExternalSecret | Target Secret | OpenBao Path | Contained Keys |
|---|---|---|---|
| `postgres-credentials` | `postgres-credentials` | `secret/artifact-keeper/postgres` | POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB |
| `meilisearch-credentials` | `meilisearch-credentials` | `secret/artifact-keeper/meilisearch` | MEILI_MASTER_KEY |
| `artifact-keeper-credentials` | `artifact-keeper-credentials` | `secret/artifact-keeper/app` | JWT_SECRET, ADMIN_PASSWORD, MIGRATION_ENCRYPTION_KEY |
| `garage-s3-credentials` | `garage-s3-credentials` | `secret/garage/artifacts` | S3_ACCESS_KEY, S3_SECRET_KEY |

All ExternalSecrets use the `ClusterSecretStore` named `openbao` and have a refresh interval of 1 hour.

### Creating OpenBao Secrets

The following paths must be populated in OpenBao before deployment:

```bash
# PostgreSQL
bao kv put secret/artifact-keeper/postgres \
  username=artifact_keeper \
  password=<GENERATED_PASSWORD> \
  database=artifact_keeper

# Meilisearch
bao kv put secret/artifact-keeper/meilisearch \
  master_key=<GENERATED_KEY>

# Application Secrets
bao kv put secret/artifact-keeper/app \
  jwt_secret=<GENERATED_SECRET> \
  admin_password=<GENERATED_PASSWORD> \
  migration_encryption_key=<GENERATED_KEY>

# Garage S3 (if not already present)
bao kv put secret/garage/artifacts \
  access_key=<GARAGE_ACCESS_KEY> \
  secret_key=<GARAGE_SECRET_KEY>
```

---

## 4.9 Admin Access

| Parameter | Value |
|---|---|
| **URL** | `https://artifacts.development.cfapps.cool` |
| **Username** | `admin` |
| **Password** | Generated password from OpenBao (`secret/artifact-keeper/app` → `admin_password`) |

---

## Resource Overview

Total resource consumption of the artifact-keeper stack:

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---|---|---|---|
| Backend | 250m | 500m | 256 Mi | 512 Mi |
| Web UI | 100m | 250m | 128 Mi | 256 Mi |
| PostgreSQL | - | - | - | - |
| Meilisearch | - | - | - | - |
| **Total (approx.)** | **~350m+** | **~750m+** | **~384 Mi+** | **~768 Mi+** |

*Values for PostgreSQL and Meilisearch depend on their respective configuration and are not listed here.*

---

## Deployment Order

The components are deployed as a unit via Kustomize (`kubectl apply -k`). The init containers in the backend ensure the correct startup order:

1. **Namespace** and **ExternalSecrets** are created
2. **PostgreSQL** starts (StatefulSet)
3. **Meilisearch** starts (Deployment)
4. **Backend** waits for PostgreSQL and Meilisearch (init containers), then starts
5. **Web UI** starts (no pod-level dependencies)
6. **IngressRoute** makes the service externally accessible

---

## Files

```
k8/services/artifact-keeper/
├── kustomization.yaml
├── namespace.yaml
├── external-secrets.yaml
├── ingressroute.yaml
├── artifact-keeper/
│   ├── configmap.yaml
│   ├── deployment.yaml
│   ├── deployment-web.yaml
│   ├── service.yaml
│   └── service-web.yaml
├── postgresql/
│   ├── pvc.yaml
│   ├── statefulset.yaml
│   └── service.yaml
├── meilisearch/
│   ├── pvc.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── trivy/
    ├── deployment.yaml
    └── service.yaml
```
