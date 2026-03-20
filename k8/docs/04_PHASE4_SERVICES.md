# Phase 4: Services - artifact-keeper

## Uebersicht

**Ziel:** Deployment der artifact-keeper Artifact Registry auf dem K8s-Cluster. artifact-keeper verwaltet Container Images, Helm Charts und generische Artefakte mit PostgreSQL als Datenbank, Meilisearch als Suchindex und Garage S3 als Storage-Backend.

**Voraussetzungen:**
- Phase 3 (Monitoring) vollstaendig abgeschlossen
- Garage S3-Bucket `artifacts` erstellt und API-Keys in OpenBao hinterlegt
- External Secrets Operator (ESO) mit ClusterSecretStore `openbao` konfiguriert
- Container Images in die Registry importiert:
  - `andrlange/artifact-keeper-backend:v1.1.0-rc.8-patched`
  - `andrlange/artifact-keeper-web:v1.1.0-rc.8-patched`
  - `postgres:17.9`
  - `getmeili/meilisearch:v1.39.0`
  - `aquasecurity/trivy:0.69.3`

**Architektur:**

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
       │ StatefulSet│ │ Deployment │ │  (extern)  │
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

**Komponenten und Versionen:**

| Komponente               | Version              | Deployment-Art   |
|--------------------------|----------------------|------------------|
| artifact-keeper Backend  | v1.1.0-rc.8-patched  | Kustomize (Deployment) |
| artifact-keeper Web UI   | v1.1.0-rc.8-patched  | Kustomize (Deployment) |
| PostgreSQL               | 17.9                 | Kustomize (StatefulSet) |
| Meilisearch              | v1.39.0              | Kustomize (Deployment) |
| Trivy Scanner            | 0.69.3               | Kustomize (Deployment) |

**Alle Container-Images werden ueber die interne Artifactory-Registry (`artifactory.cfapps.cool`) bezogen und sind ARM64-kompatibel.**

---

## 4.1 Kustomization Struktur

artifact-keeper wird vollstaendig mit Kustomize deployt. Alle Ressourcen liegen im Namespace `artifact-keeper`.

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

## 4.2 PostgreSQL (Datenbank)

### Beschreibung

PostgreSQL 17.9 dient als primaere Datenbank fuer artifact-keeper. Es speichert Metadaten zu Artefakten, Benutzern und Repositories.

### Deployment

- **Modus:** StatefulSet (fuer stabile Netzwerk-Identitaet und persistenten Speicher)
- **Replicas:** 1
- **Image:** `artifactory.cfapps.cool/docker-local/postgres:17.9-arm64`
- **Port:** 5432
- **Service:** `postgres` (ClusterIP)

### Credentials

Die Datenbankzugangsdaten werden via ExternalSecret aus OpenBao synchronisiert:

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

Das resultierende Secret `postgres-credentials` wird sowohl vom PostgreSQL StatefulSet als auch vom Backend-Deployment referenziert.

### Persistenz

PostgreSQL verwendet ein PVC (Persistent Volume Claim) ueber den local-path Provisioner.

---

## 4.3 Meilisearch (Suchindex)

### Beschreibung

Meilisearch v1.39.0 bietet eine schnelle Volltextsuche ueber alle Artefakte. Der Backend-Service indiziert neue Artefakte automatisch.

### Deployment

- **Modus:** Deployment
- **Replicas:** 1
- **Image:** `artifactory.cfapps.cool/docker-local/getmeili/meilisearch:v1.39.0-arm64`
- **Port:** 7700
- **Service:** `meilisearch` (ClusterIP)
- **Persistenz:** PVC ueber local-path Provisioner

### Credentials

Der Meilisearch Master Key wird via ExternalSecret aus OpenBao synchronisiert:

```yaml
- secretKey: MEILI_MASTER_KEY
  remoteRef:
    key: secret/artifact-keeper/meilisearch
    property: master_key
```

---

## 4.4 artifact-keeper Backend

### Beschreibung

Der Backend-Service ist die zentrale API-Komponente. Er verwaltet Artefakte, authentifiziert Benutzer und koordiniert die Kommunikation mit PostgreSQL, Meilisearch und Garage S3.

### Deployment

- **Replicas:** 1
- **Strategy:** Recreate (kein Rolling Update, da DB-Migrationen laufen)
- **Image:** `artifactory.cfapps.cool/docker-local/andrlange/artifact-keeper-backend:v1.1.0-rc.8-patched-arm64`
- **Port:** 8080
- **Service:** `artifact-keeper` (ClusterIP)

### Init-Container

Das Backend-Deployment verwendet zwei Init-Container, die sicherstellen, dass Abhaengigkeiten bereit sind:

1. **wait-for-postgres:** Wartet bis PostgreSQL erreichbar ist (`pg_isready`)
2. **wait-for-meilisearch:** Wartet bis Meilisearch Health-Endpoint antwortet

### Konfiguration (ConfigMap)

Nicht-sensitive Konfiguration liegt in der ConfigMap `artifact-keeper-config`:

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

### Umgebungsvariablen

Der Backend-Container verwendet eine Kombination aus:

- **ConfigMap-Referenzen:** S3-Endpoint, Bucket, Region, Meilisearch-URL, Storage-Pfade
- **Secret-Referenzen (einzeln):** PostgreSQL-Credentials (fuer DATABASE_URL-Komposition), S3-Credentials, Meilisearch API Key
- **Secret-Referenz (envFrom):** `artifact-keeper-credentials` fuer JWT_SECRET, ADMIN_PASSWORD, MIGRATION_ENCRYPTION_KEY

Die `DATABASE_URL` wird im Pod aus den einzelnen Secret-Werten zusammengesetzt:

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

### Ressourcen

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

### Beschreibung

Die Web UI ist ein Next.js-basiertes Frontend, das die REST-API des Backends nutzt. Sie bietet eine grafische Oberflaeche zum Verwalten und Durchsuchen von Artefakten.

### Deployment

- **Replicas:** 1
- **Image:** `artifactory.cfapps.cool/docker-local/andrlange/artifact-keeper-web:v1.1.0-rc.8-patched-arm64`
- **Port:** 3000
- **Service:** `artifact-keeper-web` (ClusterIP)

### Konfiguration

```yaml
env:
  - name: NEXT_PUBLIC_API_URL
    value: "https://artifacts.development.cfapps.cool/api"
```

Die API-URL verweist auf die externe URL, damit Browser-Requests ueber den Ingress laufen.

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

### Ressourcen

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

### Beschreibung

artifact-keeper verwendet eine einzelne Traefik IngressRoute mit pfadbasiertem Routing, um Anfragen entweder an das Backend oder die Web UI weiterzuleiten.

### Host

```
artifacts.development.cfapps.cool
```

### Routing-Regeln

| Pfad | Ziel-Service | Port | Beschreibung |
|------|-------------|------|--------------|
| `/api/` | artifact-keeper | 8080 | REST API |
| `/v2/` | artifact-keeper | 8080 | Docker Registry API (OCI) |
| `/helm/` | artifact-keeper | 8080 | Helm Chart Repository |
| `/generic/` | artifact-keeper | 8080 | Generic Artifact Storage |
| `/health` | artifact-keeper | 8080 | Health Check Endpoint |
| `/metrics` | artifact-keeper | 8080 | Prometheus Metrics |
| `/` (catch-all) | artifact-keeper-web | 3000 | Web UI (Priority 1) |

Die Web-UI-Route hat `priority: 1` (niedrigste Prioritaet), sodass alle spezifischeren Pfade zuerst greifen.

### TLS

```yaml
tls: {}
```

Die IngressRoute verwendet den Default TLSStore mit dem Wildcard-Zertifikat fuer `*.development.cfapps.cool`.

---

## 4.7 Trivy Scanner (Vulnerability Scanning)

### Beschreibung

Trivy laeuft als Server-Mode-Deployment neben artifact-keeper und stellt eine Vulnerability-Scanning-API bereit. Der artifact-keeper Backend-Service nutzt Trivy, um Container Images und Artefakte auf Sicherheitsluecken zu pruefen.

### Deployment

- **Modus:** Deployment
- **Replicas:** 1
- **Image:** `artifactory.cfapps.cool/docker-local/aquasecurity/trivy:0.69.3-arm64`
- **Port:** 8090
- **Service:** `trivy` (ClusterIP)
- **Startbefehl:** `trivy server --listen 0.0.0.0:8090`

### Integration mit artifact-keeper

Der artifact-keeper Backend-Service wird ueber zwei Umgebungsvariablen mit Trivy verbunden. Diese werden in der ConfigMap `artifact-keeper-config` gesetzt:

```yaml
TRIVY_URL: http://trivy:8090
SCAN_WORKSPACE_PATH: /tmp/trivy-scan
```

#### Fuer Docker Compose (Entwicklung)

Beim Einsatz in einer Docker Compose Umgebung muss ein `trivy`-Service hinzugefuegt und die `TRIVY_URL`-Umgebungsvariable im Backend-Service gesetzt werden:

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

### Beschreibung

Alle Credentials werden ueber den External Secrets Operator (ESO) aus OpenBao synchronisiert. Es gibt vier ExternalSecrets:

### Uebersicht

| ExternalSecret | Target Secret | OpenBao Pfad | Enthaltene Keys |
|---|---|---|---|
| `postgres-credentials` | `postgres-credentials` | `secret/artifact-keeper/postgres` | POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB |
| `meilisearch-credentials` | `meilisearch-credentials` | `secret/artifact-keeper/meilisearch` | MEILI_MASTER_KEY |
| `artifact-keeper-credentials` | `artifact-keeper-credentials` | `secret/artifact-keeper/app` | JWT_SECRET, ADMIN_PASSWORD, MIGRATION_ENCRYPTION_KEY |
| `garage-s3-credentials` | `garage-s3-credentials` | `secret/garage/artifacts` | S3_ACCESS_KEY, S3_SECRET_KEY |

Alle ExternalSecrets verwenden den `ClusterSecretStore` namens `openbao` und haben ein Refresh-Intervall von 1 Stunde.

### OpenBao Secrets anlegen

Vor dem Deployment muessen folgende Pfade in OpenBao befuellt werden:

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

# Garage S3 (falls nicht bereits vorhanden)
bao kv put secret/garage/artifacts \
  access_key=<GARAGE_ACCESS_KEY> \
  secret_key=<GARAGE_SECRET_KEY>
```

---

## 4.9 Admin-Zugang

| Parameter | Wert |
|---|---|
| **URL** | `https://artifacts.development.cfapps.cool` |
| **Benutzername** | `admin` |
| **Passwort** | Generiertes Passwort aus OpenBao (`secret/artifact-keeper/app` → `admin_password`) |

---

## Ressourcen-Uebersicht

Gesamter Ressourcenverbrauch des artifact-keeper Stacks:

| Komponente | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---|---|---|---|
| Backend | 250m | 500m | 256 Mi | 512 Mi |
| Web UI | 100m | 250m | 128 Mi | 256 Mi |
| PostgreSQL | - | - | - | - |
| Meilisearch | - | - | - | - |
| **Gesamt (ca.)** | **~350m+** | **~750m+** | **~384 Mi+** | **~768 Mi+** |

*Werte fuer PostgreSQL und Meilisearch haengen von der jeweiligen Konfiguration ab und sind hier nicht aufgefuehrt.*

---

## Deploymentreihenfolge

Die Komponenten werden via Kustomize als Einheit deployt (`kubectl apply -k`). Die Init-Container im Backend stellen die korrekte Startreihenfolge sicher:

1. **Namespace** und **ExternalSecrets** werden angelegt
2. **PostgreSQL** startet (StatefulSet)
3. **Meilisearch** startet (Deployment)
4. **Backend** wartet auf PostgreSQL und Meilisearch (Init-Container), startet dann
5. **Web UI** startet (keine Abhaengigkeiten auf Pod-Ebene)
6. **IngressRoute** macht den Service extern erreichbar

---

## Dateien

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
