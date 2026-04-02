# Kappman Marketplace: Parameters + Service Documentation Design

**Date:** 2026-04-02
**Status:** Draft
**Kappman Version:** 1.0.0 → 1.1.0

## Overview

Extend kappman (Korifi Apps Manager) with two features:

1. **JSON Parameters** in the Create Service Instance form — enables services like `ai-connector` that require configuration at creation time
2. **Service Documentation Popups** in the Marketplace — each service card gets an info button that opens a tabbed modal with Overview, Parameters, and Credentials documentation

Documentation content is served by the brokers via OSBAPI `metadata` fields, not hardcoded in kappman.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Documentation source | Broker metadata (OSBAPI) | Doku belongs to the broker, not the UI; new services get docs automatically |
| Popup style | Bootstrap modal with tabs | Matches existing kappman modal pattern (org/space creation) |
| Metadata structure | Three separate keys | `docsOverview`, `docsParameters`, `docsCredentials` — no JSON parsing needed |
| Parameters field visibility | Conditional on `docsParameters` | Only shown when the service supports parameters; avoids confusing users |
| Affected services | All 7 (both brokers) | Consistent UX — every service card has an info button |

## Broker Changes

### Metadata Keys

Each service in the OSBAPI catalog gets up to three metadata keys:

| Key | Type | Required | Content |
|---|---|---|---|
| `docsOverview` | HTML string | Yes (for info button to appear) | Service description, features, use cases |
| `docsParameters` | HTML string | No | Parameter format, examples, field table |
| `docsCredentials` | HTML string | No | Binding credential format with JSON examples |

HTML uses Bootstrap 5 dark-theme compatible classes: `table-sm table-dark`, `text-muted`, `<code>`, `<pre>`.

### cf-service-broker (v1.3.1 → v1.4.0)

Add metadata to existing 4 services in `catalog.go`:

**postgresql:**
- Overview: PostgreSQL 18 via CloudNativePG, single instance, local-path storage
- Parameters: none (no `docsParameters` key)
- Credentials: type, hostname, port, database, username, password, uri, jdbcUrl

**valkey:**
- Overview: Redis-compatible key-value store, password-protected
- Parameters: none
- Credentials: type, hostname, port, password, uri

**rabbitmq:**
- Overview: RabbitMQ message broker via Cluster Operator
- Parameters: none
- Credentials: type, hostname, port, username, password, uri, http_api_uri, vhost

**s3:**
- Overview: S3-compatible object storage powered by Garage
- Parameters: none
- Credentials: type, access_key_id, secret_access_key, endpoint, bucket, region, path_style, uri

### cf-marketplace-broker (v1.0.0 → v1.1.0)

Add metadata to all 3 services in `catalog.go`:

**postgres-ai:**
- Overview: PostgreSQL 17 with AI/ML extensions list (pgvector, pgvectorscale, PostGIS, pg_trgm, fuzzystrmatch, pgcrypto, uuid-ossp, unaccent, pg_stat_statements, full-text search)
- Parameters: none (no `docsParameters` key — plans handle sizing)
- Credentials: type, hostname, port, database, username, password, uri, jdbcUrl, extensions array

**openbao-secrets:**
- Overview: Managed secret container in OpenBao, AppRole-based access, 24h TTL
- Parameters: none
- Credentials: type, vault_addr, role_id, secret_id, secret_path, auth_mount + usage example (AppRole login → write → read)

**ai-connector:**
- Overview: Connect to Ollama/LM Studio via OpenAI-compatible API, single or multi-endpoint
- Parameters: single-endpoint shortform, multi-endpoint format, field table (provider, host, port, api_key), default ports
- Credentials: single-endpoint format (flat), multi-endpoint format (endpoints array), usage hints (models_url → chat/completions)

## Kappman Changes

### Marketplace Catalog (`catalog.html`)

**Info Button** on each service card (top-right, next to service name):

```html
<button class="btn btn-sm btn-outline-secondary"
        data-bs-toggle="modal"
        data-bs-target="#docsModal-{guid}"
        th:if="${entry.offering.metadata?.containsKey('docsOverview')}">
    <i class="bi bi-info-circle"></i>
</button>
```

**Documentation Modal** per service (appended to card or page bottom):

- ID: `docsModal-{offering.guid}`
- Size: `modal-lg`
- Style: `background: var(--spring-card); border-color: var(--spring-border);` (matches existing modals)
- Header: Service display name + close button
- Body: Bootstrap nav-tabs with up to 3 tabs
  - "Overview" tab → `th:utext="${entry.offering.metadata['docsOverview']}"` (always present)
  - "Parameters" tab → `th:utext="${entry.offering.metadata['docsParameters']}"` (only if key exists)
  - "Credentials" tab → `th:utext="${entry.offering.metadata['docsCredentials']}"` (only if key exists)
- Footer: Close button

### Create Instance Form (`create-instance.html`)

**Parameters Textarea** — shown only when `offering.metadata` contains `docsParameters`:

```html
<div class="mb-3" th:if="${offering.metadata?.containsKey('docsParameters')}">
    <label class="form-label">
        Parameters (JSON)
        <button type="button" class="btn btn-sm btn-link p-0 ms-1"
                data-bs-toggle="modal" data-bs-target="#docsModal-params">
            <i class="bi bi-question-circle"></i>
        </button>
    </label>
    <textarea class="form-control font-monospace" name="parameters"
              rows="5" placeholder='{"provider":"ollama","host":"192.168.64.1","port":11434}'></textarea>
    <small class="text-muted">
        <i class="bi bi-info-circle me-1"></i>See service documentation for parameter format
    </small>
</div>
```

A mini documentation modal on the create-instance page shows just the Parameters tab content for quick reference.

### MarketplaceController.kt

The `plans()` method already passes the `offering` object to the template. The `offering.metadata` field from the CF API contains the broker's metadata. No controller changes needed if the CF API model correctly maps metadata.

**Verify:** `CfServiceOffering` model must include `metadata: Map<String, Any>?`. If not, add it.

### ServiceController.kt

```kotlin
@PostMapping("/services")
fun createService(
    @RequestParam name: String,
    @RequestParam spaceGuid: String,
    @RequestParam planGuid: String,
    @RequestParam(required = false) parameters: String?,
    redirectAttributes: RedirectAttributes
): String {
    val params: Map<String, Any>? = if (!parameters.isNullOrBlank()) {
        try {
            objectMapper.readValue(parameters, object : TypeReference<Map<String, Any>>() {})
        } catch (e: Exception) {
            redirectAttributes.addFlashAttribute("error", "Invalid JSON parameters: ${e.message}")
            return "redirect:/marketplace"
        }
    } else null

    val svc = cfApiService.createServiceInstance(name, spaceGuid, planGuid, params)
    // ... rest unchanged
}
```

### CfApiService.kt

```kotlin
fun createServiceInstance(
    name: String,
    spaceGuid: String,
    planGuid: String,
    parameters: Map<String, Any>? = null
): CfServiceInstance? {
    val body = mutableMapOf<String, Any>(
        "type" to "managed",
        "name" to name,
        "relationships" to mapOf(
            "space" to mapOf("data" to mapOf("guid" to spaceGuid)),
            "service_plan" to mapOf("data" to mapOf("guid" to planGuid))
        )
    )
    if (parameters != null) {
        body["parameters"] = parameters
    }
    return cfApiClient.post("/v3/service_instances", body, CfServiceInstance::class.java)
}
```

## Installer Integration

### Phase 9 Addition

New step in `lib/phase9.sh` after `phase9_broker_register`:

| Step | Component ID | Action |
|---|---|---|
| 8 | `phase9_kappman_update` | Rebuild and redeploy kappman with v1.1.0 via `cf push` |

```bash
# --- Step 8: Update kappman ---
if ! component_is_installed "phase9_kappman_update" "$STATE_FILE"; then
    log_step "Updating kappman to v1.1.0 (parameters + service docs)"
    
    local KAPPMAN_DIR="${INSTALL_DIR}/../apps/kappman"
    (cd "$KAPPMAN_DIR" && cf push kappman)
    
    mark_component_installed "phase9_kappman_update" "$STATE_FILE"
fi
```

This works for both `install.sh` (Phase 9) and `extend-marketplace-1.sh` since they share `run_phase_9`.

### Broker Image Updates

Phase 9 must also update the existing broker:

| Step | Component ID | Action |
|---|---|---|
| 2a | `phase9_existing_broker_update` | Build cf-service-broker:1.4.0-arm64 with metadata, push to Artifactory, `kubectl set image` |

The marketplace broker (1.1.0) gets its metadata from the start since it's built fresh in Phase 9.

### Version Summary

| Component | Before | After |
|---|---|---|
| kappman | V1.0.0 | V1.1.0 |
| cf-service-broker | 1.3.1 | 1.4.0 |
| cf-marketplace-broker | 1.0.0 | 1.1.0 |

## CF API Model Requirement

Kappman's `CfServiceOffering` data class must include the `metadata` field from the CF v3 API response. The `/v3/service_offerings` endpoint returns:

```json
{
  "guid": "...",
  "name": "ai-connector",
  "description": "...",
  "metadata": {
    "annotations": {},
    "labels": {}
  },
  "broker_catalog": {
    "metadata": {
      "displayName": "AI Model Connector",
      "docsOverview": "<p>...</p>",
      "docsParameters": "<p>...</p>",
      "docsCredentials": "<p>...</p>"
    }
  }
}
```

The documentation metadata lives under `broker_catalog.metadata` in the CF v3 API response (this is where Korifi exposes the OSBAPI catalog metadata). Kappman must read from `brokerCatalog.metadata.docsOverview` etc.

**Verify:** Check that Korifi actually passes through `broker_catalog.metadata` from the OSBAPI catalog. If it doesn't, this needs a workaround (e.g., annotations or a sidecar config).
