# Marketplace Extension 1: AI/ML Services Design

**Date:** 2026-04-02
**Status:** Draft
**Bundle Version:** 1.1.0

## Overview

A new OSBAPI-compliant service broker (`cf-marketplace-broker`) providing three AI/ML-focused services for the K8s DevOps Stack marketplace. Deployed as Phase 9 in new installations and via `extend-marketplace-1.sh` for existing environments.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Broker architecture | Standalone broker (separate from existing `cf-service-broker`) | Independent deployment, no regression risk, thematically different services |
| pgvector base image | `timescale/timescaledb-ha:pg17` | ARM64 + CloudNativePG compatible, includes pgvectorscale, PostGIS, RUM without custom build |
| OpenBao access model | Shared KV v2 engine + AppRole per instance | Secure (rotatable, TTL), efficient (no mount overhead per instance) |
| AI Connector binding format | OpenAI-compatible with multi-endpoint option | Both Ollama and LM Studio support OpenAI API; single client works for both |
| Installer integration | Phase 9 + extend script, shared state file | Unified truth via `.install-state`, no divergence between install paths |
| Test approach | Go CLI OSBAPI lifecycle tests | Direct broker testing without Korifi dependency |

## Service Catalog

### 1. PostgreSQL AI Enabled (`postgres-ai`)

| Field | Value |
|---|---|
| Service ID | `b1a2c3d4-e5f6-7890-abcd-100000000001` |
| Display Name | PostgreSQL AI Enabled |
| Description | PostgreSQL 17 with pgvector, pgvectorscale, PostGIS, full-text search, and AI/ML extensions |
| Tags | `postgresql`, `ai`, `vector`, `ml`, `database` |
| Bindable | true |

**Plans:**

| Plan | ID | Memory | Storage | Description |
|---|---|---|---|---|
| `small` | `c2d3e4f5-a1b2-7890-abcd-100000000011` | 512Mi | 2Gi | Development |
| `medium` | `c2d3e4f5-a1b2-7890-abcd-100000000012` | 1Gi | 10Gi | Production |

**Auto-activated extensions on provisioning:**

| Extension | Purpose |
|---|---|
| `vector` (pgvector) | Vector similarity search with HNSW + IVFFlat indexes |
| `vectorscale` (pgvectorscale) | DiskANN index for large-scale vector search |
| `pg_trgm` | Trigram-based fuzzy text matching |
| `fuzzystrmatch` | Soundex, Levenshtein, Metaphone |
| `pgcrypto` | Cryptographic functions |
| `uuid-ossp` | UUID generation |
| `postgis` | Geospatial data |
| `unaccent` | Accent-insensitive search |
| `pg_stat_statements` | Query monitoring |

Built-in PostgreSQL full-text search (tsvector/tsquery) is always available without extension.

**Provisioning:**
- Creates CloudNativePG `Cluster` CR named `pgai-<instanceID[:8]>`
- Image: `timescale/timescaledb-ha:pg17` (pulled via Artifactory)
- `bootstrap.initdb.postInitSQL` runs all `CREATE EXTENSION` statements
- Database `app` owned by user `app`

**Binding credentials:**
```json
{
  "type": "postgres-ai",
  "hostname": "pgai-<id>.cf-services.svc.cluster.local",
  "port": 5432,
  "database": "app",
  "username": "app",
  "password": "<generated>",
  "uri": "postgresql://app:<pw>@<host>:5432/app",
  "jdbcUrl": "jdbc:postgresql://<host>:5432/app",
  "extensions": ["vector","vectorscale","pg_trgm","fuzzystrmatch","pgcrypto","uuid-ossp","postgis","unaccent","pg_stat_statements"]
}
```

### 2. OpenBao Secret Container (`openbao-secrets`)

| Field | Value |
|---|---|
| Service ID | `b1a2c3d4-e5f6-7890-abcd-200000000002` |
| Display Name | OpenBao Secret Container |
| Description | Managed secret container in OpenBao with AppRole access for application-managed secrets |
| Tags | `secrets`, `vault`, `openbao`, `security` |
| Bindable | true |

**Plans:**

| Plan | ID | Description |
|---|---|---|
| `default` | `c2d3e4f5-a1b2-7890-abcd-200000000021` | Dedicated KV v2 path, AppRole with 24h TTL |

**Provisioning creates:**
1. KV v2 path `cf-secrets/data/instance-<id>/` in OpenBao
2. Policy `cf-secrets-<id>` granting read/write on that path
3. AppRole `cf-secrets-<id>` with the policy, token TTL 24h

**Deprovisioning deletes:** AppRole, policy, KV path (including all stored secrets).

**Binding credentials:**
```json
{
  "type": "openbao-secrets",
  "vault_addr": "http://openbao.openbao.svc.cluster.local:8200",
  "role_id": "<approle-role-id>",
  "secret_id": "<approle-secret-id>",
  "secret_path": "cf-secrets/data/instance-<id>",
  "auth_mount": "approle"
}
```

The application authenticates via AppRole login, then reads/writes secrets at `secret_path`.

### 3. AI Model Connector (`ai-connector`)

| Field | Value |
|---|---|
| Service ID | `b1a2c3d4-e5f6-7890-abcd-300000000003` |
| Display Name | AI Model Connector |
| Description | Connect to external AI model providers (Ollama, LM Studio) via OpenAI-compatible API |
| Tags | `ai`, `llm`, `ollama`, `lmstudio`, `connector` |
| Bindable | true |

**Plans:**

| Plan | ID | Description |
|---|---|---|
| `default` | `c2d3e4f5-a1b2-7890-abcd-300000000031` | External AI endpoint connector |

**Create-service parameters:**

Single endpoint (shortform):
```json
{
  "provider": "ollama",
  "host": "192.168.64.1",
  "port": 11434
}
```

Multiple endpoints:
```json
{
  "endpoints": [
    {
      "name": "ollama-local",
      "provider": "ollama",
      "host": "192.168.64.1",
      "port": 11434,
      "api_key": ""
    },
    {
      "name": "lmstudio-local",
      "provider": "lmstudio",
      "host": "192.168.64.1",
      "port": 1234,
      "api_key": ""
    }
  ]
}
```

**Provisioning:** Validates connectivity to endpoints (HTTP GET `/v1/models`), stores configuration in K8s Secret `ai-<instanceID[:8]>`.

**Binding credentials (single endpoint):**
```json
{
  "type": "ai-connector",
  "base_url": "http://192.168.64.1:11434/v1",
  "provider": "ollama",
  "api_key": "",
  "models_url": "http://192.168.64.1:11434/v1/models"
}
```

**Binding credentials (multi-endpoint):**
```json
{
  "type": "ai-connector",
  "endpoints": [
    {
      "name": "ollama-local",
      "base_url": "http://192.168.64.1:11434/v1",
      "provider": "ollama",
      "api_key": "",
      "models_url": "http://192.168.64.1:11434/v1/models"
    },
    {
      "name": "lmstudio-local",
      "base_url": "http://192.168.64.1:1234/v1",
      "provider": "lmstudio",
      "api_key": "",
      "models_url": "http://192.168.64.1:1234/v1/models"
    }
  ]
}
```

**Default ports:** Ollama: 11434, LM Studio: 1234.

## Broker Architecture

### Project Structure

```
k8/services/cf-marketplace-broker/
├── src/
│   ├── main.go                    # Entry point, HTTP server, env config
│   ├── broker/
│   │   ├── broker.go              # OSBAPI handler
│   │   ├── catalog.go             # 3 services, 4 plans
│   │   └── state.go               # ConfigMap: broker-marketplace-instances
│   ├── provisioners/
│   │   ├── provisioner.go         # Provisioner interface + ResourceName()
│   │   ├── postgres_ai.go         # CloudNativePG + Timescale + extensions init
│   │   ├── openbao_secrets.go     # OpenBao KV v2 + AppRole lifecycle
│   │   └── ai_connector.go        # Endpoint validation + K8s Secret
│   └── k8s/
│       └── client.go              # K8s client (typed + dynamic)
├── Dockerfile                     # Multi-stage: Go 1.26 → distroless
├── deployment.yaml                # SA, ClusterRole, Deployment, Service
├── externalsecret-openbao.yaml    # ESO: OpenBao token for broker
└── test/
    ├── main_test.go               # Setup: broker URL, auth, HTTP client
    ├── postgres_ai_test.go        # pgvector lifecycle test
    ├── openbao_test.go            # Secrets lifecycle test
    ├── ai_connector_test.go       # AI connector lifecycle test
    └── helpers.go                 # OSBAPI HTTP helpers
```

### Differences from Existing Broker

| Aspect | Existing (`cf-service-broker`) | New (`cf-marketplace-broker`) |
|---|---|---|
| ConfigMap | `broker-instances` | `broker-marketplace-instances` |
| Namespace | `cf-services` | `cf-services` |
| Image | `cf-service-broker:1.3.1-arm64` | `cf-marketplace-broker:1.0.0-arm64` |
| Port | 8080 | 8081 |
| RBAC | CNPG, RMQ, StatefulSets, Secrets | CNPG, Secrets, ConfigMaps |
| External dependency | Garage Admin API | OpenBao API |

### Environment Variables

```yaml
BROKER_USERNAME: "marketplace-broker"
BROKER_PASSWORD: <from OpenBao via ESO>
OPENBAO_ADDR: "http://openbao.openbao.svc.cluster.local:8200"
OPENBAO_TOKEN: <from ESO>
NAMESPACE: "cf-services"
PORT: "8081"
```

### RBAC (ClusterRole)

```yaml
rules:
  - apiGroups: ["postgresql.cnpg.io"]
    resources: ["clusters"]
    verbs: ["create", "delete", "get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["create", "delete", "get", "list", "update", "patch"]
```

### Provisioner Interface

Identical to the existing broker:

```go
type Provisioner interface {
    Provision(ctx context.Context, client *k8s.Client, name, namespace, planID string, params map[string]interface{}) error
    Deprovision(ctx context.Context, client *k8s.Client, name, namespace string) error
    IsReady(ctx context.Context, client *k8s.Client, name, namespace string) (bool, string, error)
    GetCredentials(ctx context.Context, client *k8s.Client, name, namespace string) (map[string]interface{}, error)
}
```

Note: `Provision` adds a `params map[string]interface{}` parameter (needed for AI Connector endpoint configuration). The existing broker's Provision does not take params — this is the only interface difference.

## Installer Integration

### Phase 9 Steps

| Step | Component ID | Action |
|---|---|---|
| 1 | `phase9_openbao_setup` | Activate KV v2 engine `cf-secrets/`, enable AppRole auth backend |
| 2 | `phase9_broker_image` | Build broker image, push to Artifactory |
| 3 | `phase9_externalsecret` | Deploy ESO ExternalSecret for OpenBao token |
| 4 | `phase9_broker_deploy` | Deploy SA, ClusterRole, Deployment, Service |
| 5 | `phase9_broker_register` | Register broker with Korifi (`cf create-service-broker`) |
| 6 | `phase9_test` | Run Go CLI OSBAPI test suite |
| 7 | `phase9_docs` | Write credentials to credentials.md |

Prerequisites: Phase 6 (Korifi) + Phase 7 (Service Brokers) must be complete.

### Code Organization

Phase 9 logic lives in `k8/distribution/lib/phase9.sh`, sourced by both:
- `install.sh` → `install_phase_9()` calls the function from `lib/phase9.sh`
- `extend-marketplace-1.sh` → standalone script that sources `lib/phase9.sh` directly

### Changes to `install.sh`

7 locations updated:
1. `install_phase_9()` — sources `lib/phase9.sh`
2. `continue_from_phase()` — Phase 9 block after Phase 8
3. `cmd_full_setup()` — adds `install_phase_9`
4. `main()` case — `9) install_phase_9 ;;`
5. `usage()` — Phase 9 documentation
6. `cmd_status()` — `phase_names` array + loop range to 9
7. `print_phase_timing()` — loop range to 9 (also fixes missing Phase 8)

### `extend-marketplace-1.sh`

```bash
#!/usr/bin/env bash
# Marketplace Extension 1: AI/ML Services
# Adds postgres-ai, openbao-secrets, ai-connector to existing installation

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/prerequisites.sh"
source "$SCRIPT_DIR/lib/helm.sh"
source "$SCRIPT_DIR/lib/interactive.sh"
source "$SCRIPT_DIR/lib/phase9.sh"

main() {
    print_banner "Marketplace Extension 1: AI/ML Services"
    load_config
    phase_is_complete 6 "$STATE_FILE" || die "Phase 6 (Korifi) required"
    phase_is_complete 7 "$STATE_FILE" || die "Phase 7 (Service Brokers) required"
    ensure_openbao_login
    run_phase_9   # Shared function from lib/phase9.sh
    log_success "Marketplace Extension 1 installed"
}

main "$@"
```

### GETTING_STARTED.md Update

New section added after the existing Installation Phases section:

```markdown
## Extending an Existing Installation

If you already have a running stack (Phase 7+) and want to add AI/ML marketplace
services without re-running the full installer:

    cd ~/devops-stack/k8/distribution
    ./extend-marketplace-1.sh

This adds three new services to the marketplace:
- **PostgreSQL AI Enabled** — pgvector, pgvectorscale, PostGIS, full-text search
- **OpenBao Secret Container** — application-managed secrets with AppRole access
- **AI Model Connector** — connect to Ollama / LM Studio instances

For new installations, these services are included automatically as Phase 9.
```

### Bundle Version

Distribution bundle version: **1.1.0**

```bash
VERSION="1.1.0"
./build-distribution.sh
# Push installer-v1.1.0.sh + stack-v1.1.0.tgz to Artifactory
```

## Test Suite

### Structure

```
k8/services/cf-marketplace-broker/test/
├── main_test.go          # Setup, broker URL/auth from env
├── postgres_ai_test.go   # pgvector lifecycle
├── openbao_test.go       # Secrets lifecycle
├── ai_connector_test.go  # AI connector lifecycle
└── helpers.go            # OSBAPI HTTP helpers
```

### Test Pattern (all services)

```
1. PUT    /v2/service_instances/:id                              → 202 Accepted
2. GET    /v2/service_instances/:id/last_operation               → Poll until succeeded
3. PUT    /v2/service_instances/:id/service_bindings/:bid        → 200 OK
4. Verify credentials (service-specific)
5. DELETE /v2/service_instances/:id/service_bindings/:bid        → 200 OK
6. DELETE /v2/service_instances/:id                              → 202 Accepted
7. GET    /v2/service_instances/:id/last_operation               → 410 Gone
```

### Credential Verification

**postgres-ai:**
- Connect with binding credentials via `lib/pq`
- `SELECT extname FROM pg_extension` — verify vector, vectorscale, pg_trgm, postgis present
- `CREATE TABLE test_vec (id serial, emb vector(3))` → insert → similarity query → drop

**openbao-secrets:**
- AppRole login with role_id + secret_id → obtain token
- `PUT <secret_path>/test-key` with `{"value":"hello"}` → write
- `GET <secret_path>/test-key` → read and verify
- `DELETE <secret_path>/test-key` → cleanup

**ai-connector:**
- HTTP GET on `models_url` → verify reachable, valid JSON response
- Validate response structure (`data[].id` array)
- `t.Skip` if endpoint not reachable (Ollama/LM Studio may not be running)

### Execution

```bash
# In Lima VM (from installer Phase 9 step 6):
BROKER_URL=http://cf-marketplace-broker.cf-services.svc:8081 \
BROKER_USER=marketplace-broker \
BROKER_PASSWORD=<password> \
go test -v -timeout 300s ./...
```
