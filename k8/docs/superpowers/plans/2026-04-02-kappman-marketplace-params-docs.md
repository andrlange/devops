# Kappman Marketplace Parameters + Service Documentation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add JSON parameters support to service creation and tabbed documentation modals for all 7 services in the kappman Marketplace UI, with metadata served by brokers.

**Architecture:** Both brokers add `docsOverview`/`docsParameters`/`docsCredentials` HTML strings to their OSBAPI catalog metadata. Kappman reads `broker_catalog.metadata` from the CF v3 API and renders info-button modals with Bootstrap nav-tabs. The create-instance form conditionally shows a JSON textarea when `docsParameters` exists. Phase 9 installer updates both broker images and redeploys kappman.

**Tech Stack:** Go 1.26 (brokers), Kotlin/Spring Boot 4.0.3 + Thymeleaf (kappman), Bootstrap 5 dark theme

**Spec:** `k8/docs/superpowers/specs/2026-04-02-kappman-marketplace-params-docs-design.md`

---

## File Structure

```
# Broker changes (metadata only)
k8/services/cf-service-broker/src/broker/catalog.go          # Add metadata to 4 services
k8/services/cf-marketplace-broker/src/broker/catalog.go      # Add metadata to 3 services

# Kappman changes
k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/cfapi/CfApiService.kt        # Add parameters to createServiceInstance
k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/service/ServiceController.kt  # Accept parameters param
k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/service/MarketplaceController.kt  # Pass brokerCatalog metadata
k8/apps/kappman/src/main/resources/templates/marketplace/catalog.html             # Info button + docs modal
k8/apps/kappman/src/main/resources/templates/marketplace/create-instance.html     # Parameters textarea + params modal
k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/config/GlobalModelAttributes.kt  # Version bump V1.1.0

# Installer changes
k8/distribution/lib/phase9.sh             # Add existing broker update + kappman update steps
k8/services/cf-service-broker/deployment.yaml  # Image tag bump 1.3.1 → 1.4.0
```

---

### Task 1: Add Metadata to cf-service-broker Catalog (4 services)

**Files:**
- Modify: `k8/services/cf-service-broker/src/broker/catalog.go`

- [ ] **Step 1: Add metadata to postgresql service**

In `k8/services/cf-service-broker/src/broker/catalog.go`, replace the postgresql service entry. Change:

```go
		{
			ID:          PostgreSQLServiceID,
			Name:        "postgresql",
			Description: "PostgreSQL 18 via CloudNativePG",
			Bindable:    true,
			Tags:        []string{"postgresql", "sql", "database"},
```

To:

```go
		{
			ID:          PostgreSQLServiceID,
			Name:        "postgresql",
			Description: "PostgreSQL 18 via CloudNativePG",
			Bindable:    true,
			Tags:        []string{"postgresql", "sql", "database"},
			Metadata: &domain.ServiceMetadata{
				DisplayName: "PostgreSQL",
				AdditionalMetadata: map[string]interface{}{
					"docsOverview": `<p>Managed <strong>PostgreSQL 18</strong> database powered by CloudNativePG.</p>
<ul>
<li>Single-instance deployment with local-path storage</li>
<li>Automatic credentials via CloudNativePG operator</li>
<li>Plans: <code>small</code> (256Mi/1Gi), <code>medium</code> (512Mi/5Gi)</li>
</ul>`,
					"docsCredentials": `<p>Binding credentials include:</p>
<pre><code>{
  "type": "postgresql",
  "hostname": "pg-&lt;id&gt;.cf-services.svc.cluster.local",
  "port": "5432",
  "database": "app",
  "username": "app",
  "password": "&lt;generated&gt;",
  "uri": "postgres://app:&lt;pw&gt;@&lt;host&gt;:5432/app",
  "jdbcUrl": "jdbc:postgresql://&lt;host&gt;:5432/app"
}</code></pre>`,
				},
			},
```

- [ ] **Step 2: Add metadata to valkey service**

Replace the valkey service entry, adding after `Tags`:

```go
			Metadata: &domain.ServiceMetadata{
				DisplayName: "Valkey",
				AdditionalMetadata: map[string]interface{}{
					"docsOverview": `<p><strong>Valkey</strong> — Redis-compatible in-memory key-value store.</p>
<ul>
<li>Password-protected, single-instance StatefulSet</li>
<li>Persistent storage via local-path</li>
<li>Plan: <code>small</code> (128Mi/1Gi)</li>
</ul>`,
					"docsCredentials": `<p>Binding credentials include:</p>
<pre><code>{
  "type": "redis",
  "hostname": "valkey-&lt;id&gt;.cf-services.svc.cluster.local",
  "port": "6379",
  "password": "&lt;generated&gt;",
  "uri": "redis://:&lt;pw&gt;@&lt;host&gt;:6379"
}</code></pre>`,
				},
			},
```

- [ ] **Step 3: Add metadata to rabbitmq service**

Replace the rabbitmq service entry, adding after `Tags`:

```go
			Metadata: &domain.ServiceMetadata{
				DisplayName: "RabbitMQ",
				AdditionalMetadata: map[string]interface{}{
					"docsOverview": `<p><strong>RabbitMQ</strong> message broker via the RabbitMQ Cluster Operator.</p>
<ul>
<li>Single-instance cluster with management UI</li>
<li>AMQP 0-9-1 protocol</li>
<li>Plan: <code>small</code> (256Mi/1Gi)</li>
</ul>`,
					"docsCredentials": `<p>Binding credentials include:</p>
<pre><code>{
  "type": "rabbitmq",
  "hostname": "rmq-&lt;id&gt;.cf-services.svc.cluster.local",
  "port": "5672",
  "username": "default_user_...",
  "password": "&lt;generated&gt;",
  "uri": "amqp://&lt;user&gt;:&lt;pw&gt;@&lt;host&gt;:5672/%2f",
  "http_api_uri": "http://&lt;user&gt;:&lt;pw&gt;@&lt;host&gt;:15672/api",
  "vhost": "/"
}</code></pre>`,
				},
			},
```

- [ ] **Step 4: Add metadata to s3 service**

Replace the s3 service entry, adding after `Tags`:

```go
			Metadata: &domain.ServiceMetadata{
				DisplayName: "S3 Object Storage",
				AdditionalMetadata: map[string]interface{}{
					"docsOverview": `<p><strong>S3-compatible object storage</strong> powered by Garage.</p>
<ul>
<li>Dedicated bucket per service instance</li>
<li>AWS S3-compatible API (path-style)</li>
<li>Plan: <code>default</code></li>
</ul>`,
					"docsCredentials": `<p>Binding credentials include:</p>
<pre><code>{
  "type": "s3",
  "access_key_id": "&lt;generated&gt;",
  "secret_access_key": "&lt;generated&gt;",
  "endpoint": "http://garage.garage.svc.cluster.local:3900",
  "bucket": "&lt;bucket-name&gt;",
  "region": "garage",
  "path_style": true,
  "uri": "s3://&lt;key&gt;:&lt;secret&gt;@&lt;endpoint&gt;/&lt;bucket&gt;"
}</code></pre>`,
				},
			},
```

- [ ] **Step 5: Verify build**

```bash
cd k8/services/cf-service-broker/src && go build . && echo "BUILD OK"
```

Expected: BUILD OK

- [ ] **Step 6: Commit**

```bash
git add k8/services/cf-service-broker/src/broker/catalog.go
git commit -m "feat(service-broker): add documentation metadata to all 4 services"
```

---

### Task 2: Add Metadata to cf-marketplace-broker Catalog (3 services)

**Files:**
- Modify: `k8/services/cf-marketplace-broker/src/broker/catalog.go`

- [ ] **Step 1: Add metadata to postgres-ai service**

In `k8/services/cf-marketplace-broker/src/broker/catalog.go`, the postgres-ai entry already has `Metadata` with `DisplayName`. Replace it with the full metadata including docs:

Change:

```go
			Metadata: &domain.ServiceMetadata{
				DisplayName: "PostgreSQL AI Enabled",
			},
```

To:

```go
			Metadata: &domain.ServiceMetadata{
				DisplayName: "PostgreSQL AI Enabled",
				AdditionalMetadata: map[string]interface{}{
					"docsOverview": `<p><strong>PostgreSQL 17</strong> with AI/ML extensions, powered by the Timescale HA image and CloudNativePG.</p>
<h6>Included Extensions</h6>
<table class="table table-sm table-dark mt-2">
<tr><td><code>vector</code> (pgvector)</td><td>Vector similarity search — HNSW + IVFFlat indexes</td></tr>
<tr><td><code>vectorscale</code></td><td>DiskANN index for large-scale vector datasets</td></tr>
<tr><td><code>postgis</code></td><td>Geospatial data types and queries</td></tr>
<tr><td><code>pg_trgm</code></td><td>Trigram-based fuzzy text matching</td></tr>
<tr><td><code>fuzzystrmatch</code></td><td>Soundex, Levenshtein, Metaphone</td></tr>
<tr><td><code>pgcrypto</code></td><td>Cryptographic functions</td></tr>
<tr><td><code>uuid-ossp</code></td><td>UUID generation</td></tr>
<tr><td><code>unaccent</code></td><td>Accent-insensitive search</td></tr>
<tr><td><code>pg_stat_statements</code></td><td>Query performance monitoring</td></tr>
</table>
<p>Built-in full-text search (<code>tsvector</code>/<code>tsquery</code>) is always available.</p>`,
					"docsCredentials": `<p>Binding credentials include an <code>extensions</code> array listing all enabled extensions:</p>
<pre><code>{
  "type": "postgres-ai",
  "hostname": "pgai-&lt;id&gt;.cf-services.svc.cluster.local",
  "port": "5432",
  "database": "app",
  "username": "app",
  "password": "&lt;generated&gt;",
  "uri": "postgresql://app:&lt;pw&gt;@&lt;host&gt;:5432/app",
  "jdbcUrl": "jdbc:postgresql://&lt;host&gt;:5432/app",
  "extensions": ["vector","vectorscale","pg_trgm",...]
}</code></pre>`,
				},
			},
```

- [ ] **Step 2: Add metadata to openbao-secrets service**

Replace the openbao-secrets `Metadata`:

```go
			Metadata: &domain.ServiceMetadata{
				DisplayName: "OpenBao Secret Container",
				AdditionalMetadata: map[string]interface{}{
					"docsOverview": `<p>Managed <strong>secret container</strong> in OpenBao with AppRole-based access.</p>
<ul>
<li>Dedicated KV v2 path per instance</li>
<li>AppRole authentication with 24h token TTL</li>
<li>Applications can store and retrieve arbitrary key-value secrets</li>
</ul>
<h6>How It Works</h6>
<ol>
<li>Bind the service to your app to receive <code>role_id</code> + <code>secret_id</code></li>
<li>Use AppRole login to obtain a short-lived token</li>
<li>Read/write secrets at <code>secret_path</code></li>
</ol>`,
					"docsCredentials": `<p>Binding credentials provide AppRole authentication details:</p>
<pre><code>{
  "type": "openbao-secrets",
  "vault_addr": "http://openbao.openbao.svc.cluster.local:8200",
  "role_id": "&lt;approle-role-id&gt;",
  "secret_id": "&lt;approle-secret-id&gt;",
  "secret_path": "cf-secrets/data/instance-&lt;id&gt;",
  "auth_mount": "approle"
}</code></pre>
<h6>Usage Example</h6>
<pre><code># 1. Login with AppRole
POST /v1/auth/approle/login
{"role_id":"...","secret_id":"..."}

# 2. Write a secret
PUT /v1/cf-secrets/data/instance-&lt;id&gt;/my-key
{"data":{"username":"admin","password":"s3cret"}}

# 3. Read a secret
GET /v1/cf-secrets/data/instance-&lt;id&gt;/my-key</code></pre>`,
				},
			},
```

- [ ] **Step 3: Add metadata to ai-connector service**

Replace the ai-connector `Metadata`:

```go
			Metadata: &domain.ServiceMetadata{
				DisplayName: "AI Model Connector",
				AdditionalMetadata: map[string]interface{}{
					"docsOverview": `<p>Connect your application to external <strong>AI model providers</strong> (Ollama, LM Studio) via the OpenAI-compatible API.</p>
<ul>
<li>Automatic credential injection into service bindings</li>
<li>Single or multi-endpoint configuration</li>
<li>OpenAI-compatible <code>/v1/models</code> and <code>/v1/chat/completions</code></li>
<li>Default ports: Ollama <code>11434</code>, LM Studio <code>1234</code></li>
</ul>`,
					"docsParameters": `<p>Parameters are <strong>required</strong> when creating this service.</p>
<h6>Single Endpoint</h6>
<pre><code>{
  "provider": "ollama",
  "host": "192.168.64.1",
  "port": 11434
}</code></pre>
<h6>Multiple Endpoints</h6>
<pre><code>{
  "endpoints": [
    {"name":"ollama","provider":"ollama","host":"192.168.64.1","port":11434},
    {"name":"lmstudio","provider":"lmstudio","host":"192.168.64.1","port":1234}
  ]
}</code></pre>
<h6>Fields</h6>
<table class="table table-sm table-dark mt-2">
<tr><th>Field</th><th>Required</th><th>Default</th><th>Description</th></tr>
<tr><td><code>provider</code></td><td>Yes</td><td>—</td><td><code>ollama</code> or <code>lmstudio</code></td></tr>
<tr><td><code>host</code></td><td>Yes</td><td>—</td><td>Hostname or IP address</td></tr>
<tr><td><code>port</code></td><td>No</td><td>ollama: 11434, lmstudio: 1234</td><td>Service port</td></tr>
<tr><td><code>api_key</code></td><td>No</td><td><code>""</code></td><td>Bearer token (if required)</td></tr>
<tr><td><code>name</code></td><td>No</td><td><code>&lt;provider&gt;-0</code></td><td>Endpoint label</td></tr>
</table>`,
					"docsCredentials": `<h6>Single Endpoint</h6>
<pre><code>{
  "type": "ai-connector",
  "base_url": "http://192.168.64.1:11434/v1",
  "provider": "ollama",
  "api_key": "",
  "models_url": "http://192.168.64.1:11434/v1/models"
}</code></pre>
<h6>Multiple Endpoints</h6>
<pre><code>{
  "type": "ai-connector",
  "endpoints": [
    {"name":"ollama","base_url":"http://192.168.64.1:11434/v1","provider":"ollama","models_url":"..."},
    {"name":"lmstudio","base_url":"http://192.168.64.1:1234/v1","provider":"lmstudio","models_url":"..."}
  ]
}</code></pre>
<h6>Usage</h6>
<ol>
<li>Call <code>models_url</code> to list available models</li>
<li>Call <code>base_url + "/chat/completions"</code> with model name and prompt</li>
</ol>`,
				},
			},
```

- [ ] **Step 4: Verify build**

```bash
cd k8/services/cf-marketplace-broker/src && go build . && echo "BUILD OK"
```

Expected: BUILD OK

- [ ] **Step 5: Commit**

```bash
git add k8/services/cf-marketplace-broker/src/broker/catalog.go
git commit -m "feat(marketplace-broker): add documentation metadata to all 3 services"
```

---

### Task 3: Kappman Backend — Parameters Support

**Files:**
- Modify: `k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/cfapi/CfApiService.kt`
- Modify: `k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/service/ServiceController.kt`

- [ ] **Step 1: Update CfApiService.createServiceInstance**

In `k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/cfapi/CfApiService.kt`, replace the `createServiceInstance` method (around line 152):

Change:

```kotlin
    fun createServiceInstance(name: String, spaceGuid: String, planGuid: String): CfServiceInstance? {
        val body = mapOf(
            "type" to "managed",
            "name" to name,
            "relationships" to mapOf(
                "space" to mapOf("data" to mapOf("guid" to spaceGuid)),
                "service_plan" to mapOf("data" to mapOf("guid" to planGuid))
            )
        )
        return cfApiClient.post("/v3/service_instances", body, CfServiceInstance::class.java)
    }
```

To:

```kotlin
    fun createServiceInstance(name: String, spaceGuid: String, planGuid: String, parameters: Map<String, Any>? = null): CfServiceInstance? {
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

- [ ] **Step 2: Update ServiceController.createService**

In `k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/service/ServiceController.kt`, add `ObjectMapper` import and inject it, then update the `createService` method.

Add import at top of file (after existing imports):

```kotlin
import com.fasterxml.jackson.core.type.TypeReference
import com.fasterxml.jackson.databind.ObjectMapper
```

Add `ObjectMapper` to the constructor:

Change:

```kotlin
class ServiceController(
    private val cfApiService: CfApiService,
    private val auditService: AuditService,
    private val userService: cool.cfapps.kappman.auth.UserService
) {
```

To:

```kotlin
class ServiceController(
    private val cfApiService: CfApiService,
    private val auditService: AuditService,
    private val userService: cool.cfapps.kappman.auth.UserService,
    private val objectMapper: ObjectMapper
) {
```

Replace the `createService` method (line 109-119):

Change:

```kotlin
    @PostMapping("/services")
    fun createService(@RequestParam name: String, @RequestParam spaceGuid: String, @RequestParam planGuid: String, redirectAttributes: RedirectAttributes): String {
        val svc = cfApiService.createServiceInstance(name, spaceGuid, planGuid)
        if (svc != null) {
            auditService.log("CREATE", "service_instance", svc.guid, "Created service: $name")
            redirectAttributes.addFlashAttribute("success", "Service '$name' created")
        } else {
            redirectAttributes.addFlashAttribute("error", "Failed to create service")
        }
        return "redirect:/services"
    }
```

To:

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
        if (svc != null) {
            auditService.log("CREATE", "service_instance", svc.guid, "Created service: $name")
            redirectAttributes.addFlashAttribute("success", "Service '$name' created")
        } else {
            redirectAttributes.addFlashAttribute("error", "Failed to create service")
        }
        return "redirect:/services"
    }
```

- [ ] **Step 3: Commit**

```bash
git add k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/cfapi/CfApiService.kt \
        k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/service/ServiceController.kt
git commit -m "feat(kappman): add JSON parameters support for service instance creation"
```

---

### Task 4: Kappman Backend — Pass Broker Metadata to Templates

**Files:**
- Modify: `k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/service/MarketplaceController.kt`

- [ ] **Step 1: Extract broker_catalog.metadata in catalog()**

The `CfServiceOffering` model already has `brokerCatalog: Map<String, Any>?` which maps to `broker_catalog` in the CF v3 API response. The metadata is at `brokerCatalog["metadata"]`. We need to extract this and pass it to the template as a flat map on each offering entry.

In `MarketplaceController.kt`, modify the `offeringEntries` mapping inside `catalog()`. Change line 65-70:

```kotlin
            mapOf(
                "offering" to offering,
                "plans" to planDetails,
                "instanceCount" to offeringInstances.size,
                "bindingCount" to totalBindings
            )
```

To:

```kotlin
            val catalogMetadata = (offering.brokerCatalog?.get("metadata") as? Map<*, *>)
                ?.mapKeys { it.key.toString() } ?: emptyMap()

            mapOf(
                "offering" to offering,
                "plans" to planDetails,
                "instanceCount" to offeringInstances.size,
                "bindingCount" to totalBindings,
                "catalogMetadata" to catalogMetadata
            )
```

- [ ] **Step 2: Pass metadata in plans() for create-instance page**

In the `plans()` method, also extract and pass the metadata. Change:

```kotlin
    @GetMapping("/{offeringGuid}/plans")
    fun plans(@PathVariable offeringGuid: String, model: Model): String {
        model.addAttribute("activePage", "marketplace")
        model.addAttribute("pageTitle", "Service Plans")
        val offerings = cfApiService.listOfferings()
        model.addAttribute("offering", offerings.find { it.guid == offeringGuid })
        model.addAttribute("plans", cfApiService.listPlans(offeringGuid))
        model.addAttribute("spaces", cfApiService.listSpaces())
        return "marketplace/create-instance"
    }
```

To:

```kotlin
    @GetMapping("/{offeringGuid}/plans")
    fun plans(@PathVariable offeringGuid: String, model: Model): String {
        model.addAttribute("activePage", "marketplace")
        model.addAttribute("pageTitle", "Service Plans")
        val offerings = cfApiService.listOfferings()
        val offering = offerings.find { it.guid == offeringGuid }
        model.addAttribute("offering", offering)
        model.addAttribute("plans", cfApiService.listPlans(offeringGuid))
        model.addAttribute("spaces", cfApiService.listSpaces())

        val catalogMetadata = (offering?.brokerCatalog?.get("metadata") as? Map<*, *>)
            ?.mapKeys { it.key.toString() } ?: emptyMap<String, Any>()
        model.addAttribute("catalogMetadata", catalogMetadata)

        return "marketplace/create-instance"
    }
```

- [ ] **Step 3: Commit**

```bash
git add k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/service/MarketplaceController.kt
git commit -m "feat(kappman): extract broker catalog metadata for marketplace templates"
```

---

### Task 5: Kappman UI — Marketplace Catalog with Info Button + Docs Modal

**Files:**
- Modify: `k8/apps/kappman/src/main/resources/templates/marketplace/catalog.html`

- [ ] **Step 1: Replace catalog.html with info button and docs modal**

Replace the entire content of `k8/apps/kappman/src/main/resources/templates/marketplace/catalog.html`:

```html
<!DOCTYPE html>
<html lang="en" data-bs-theme="dark" xmlns:th="http://www.thymeleaf.org">
<head th:replace="~{fragments/layout :: head('Marketplace')}"></head>
<body>
<div class="app-container">
    <nav th:replace="~{fragments/layout :: sidebar}"></nav>
    <div class="main-wrapper">
        <header th:replace="~{fragments/layout :: topbar}"></header>
        <main class="main-content">

            <div th:if="${#lists.isEmpty(offerings)}" class="empty-state">
                <i class="bi bi-shop d-block"></i>
                <p>No service offerings available</p>
            </div>

            <div class="row g-3" th:unless="${#lists.isEmpty(offerings)}">
                <div class="col-md-4" th:each="entry : ${offerings}">
                    <div class="content-card h-100">
                        <div class="d-flex justify-content-between align-items-start mb-2">
                            <h6 class="text-spring-green mb-0" th:text="${entry.offering.name}"></h6>
                            <button th:if="${entry.catalogMetadata != null and entry.catalogMetadata.containsKey('docsOverview')}"
                                    class="btn btn-sm btn-outline-secondary"
                                    data-bs-toggle="modal"
                                    th:data-bs-target="'#docsModal-' + ${entry.offering.guid}">
                                <i class="bi bi-info-circle"></i>
                            </button>
                        </div>
                        <p class="text-muted small mb-3" th:text="${entry.offering.description}"></p>

                        <!-- Stats -->
                        <div class="d-flex gap-2 mb-3">
                            <span class="badge bg-dark border">
                                <i class="bi bi-database me-1"></i>
                                <span th:text="${entry.instanceCount}"></span> instances
                            </span>
                            <span class="badge bg-dark border">
                                <i class="bi bi-link-45deg me-1"></i>
                                <span th:text="${entry.bindingCount}"></span> bindings
                            </span>
                        </div>

                        <!-- Plans -->
                        <div class="small text-muted text-uppercase mb-1" style="font-size:10px;letter-spacing:0.5px;">Plans</div>
                        <div th:each="planEntry : ${entry.plans}" class="d-flex justify-content-between align-items-center mb-1 small">
                            <div>
                                <i class="bi bi-tag me-1 text-muted"></i>
                                <span th:text="${planEntry.plan.name}"></span>
                                <span class="text-muted" th:if="${planEntry.plan.description != ''}" th:text="' — ' + ${planEntry.plan.description}"></span>
                            </div>
                            <span class="badge bg-dark border" th:text="${planEntry.instanceCount} + ' inst.'"></span>
                        </div>

                        <div class="mt-3">
                            <a th:href="@{/marketplace/{guid}/plans(guid=${entry.offering.guid})}" class="btn btn-sm btn-outline-spring-green">
                                <i class="bi bi-plus-lg me-1"></i> Create Instance
                            </a>
                        </div>
                    </div>

                    <!-- Documentation Modal -->
                    <div th:if="${entry.catalogMetadata != null and entry.catalogMetadata.containsKey('docsOverview')}"
                         class="modal fade" th:id="'docsModal-' + ${entry.offering.guid}" tabindex="-1">
                        <div class="modal-dialog modal-lg">
                            <div class="modal-content" style="background: var(--spring-card); border-color: var(--spring-border);">
                                <div class="modal-header border-secondary">
                                    <h5 class="modal-title">
                                        <i class="bi bi-book me-2"></i>
                                        <span th:text="${entry.catalogMetadata.getOrDefault('displayName', entry.offering.name)}"></span>
                                    </h5>
                                    <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                                </div>
                                <div class="modal-body">
                                    <ul class="nav nav-tabs mb-3" role="tablist">
                                        <li class="nav-item">
                                            <button class="nav-link active" data-bs-toggle="tab"
                                                    th:data-bs-target="'#overview-' + ${entry.offering.guid}" type="button">Overview</button>
                                        </li>
                                        <li class="nav-item" th:if="${entry.catalogMetadata.containsKey('docsParameters')}">
                                            <button class="nav-link" data-bs-toggle="tab"
                                                    th:data-bs-target="'#parameters-' + ${entry.offering.guid}" type="button">Parameters</button>
                                        </li>
                                        <li class="nav-item" th:if="${entry.catalogMetadata.containsKey('docsCredentials')}">
                                            <button class="nav-link" data-bs-toggle="tab"
                                                    th:data-bs-target="'#credentials-' + ${entry.offering.guid}" type="button">Credentials</button>
                                        </li>
                                    </ul>
                                    <div class="tab-content">
                                        <div class="tab-pane fade show active" th:id="'overview-' + ${entry.offering.guid}"
                                             th:utext="${entry.catalogMetadata.get('docsOverview')}"></div>
                                        <div th:if="${entry.catalogMetadata.containsKey('docsParameters')}"
                                             class="tab-pane fade" th:id="'parameters-' + ${entry.offering.guid}"
                                             th:utext="${entry.catalogMetadata.get('docsParameters')}"></div>
                                        <div th:if="${entry.catalogMetadata.containsKey('docsCredentials')}"
                                             class="tab-pane fade" th:id="'credentials-' + ${entry.offering.guid}"
                                             th:utext="${entry.catalogMetadata.get('docsCredentials')}"></div>
                                    </div>
                                </div>
                                <div class="modal-footer border-secondary">
                                    <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Close</button>
                                </div>
                            </div>
                        </div>
                    </div>

                </div>
            </div>

        </main>
    </div>
</div>
<div th:replace="~{fragments/layout :: scripts}"></div>
</body>
</html>
```

- [ ] **Step 2: Commit**

```bash
git add k8/apps/kappman/src/main/resources/templates/marketplace/catalog.html
git commit -m "feat(kappman): add info button and tabbed docs modal to marketplace catalog"
```

---

### Task 6: Kappman UI — Create Instance Form with Parameters

**Files:**
- Modify: `k8/apps/kappman/src/main/resources/templates/marketplace/create-instance.html`

- [ ] **Step 1: Replace create-instance.html with parameters textarea and params docs modal**

Replace the entire content of `k8/apps/kappman/src/main/resources/templates/marketplace/create-instance.html`:

```html
<!DOCTYPE html>
<html lang="en" data-bs-theme="dark" xmlns:th="http://www.thymeleaf.org">
<head th:replace="~{fragments/layout :: head('Create Service Instance')}"></head>
<body>
<div class="app-container">
    <nav th:replace="~{fragments/layout :: sidebar}"></nav>
    <div class="main-wrapper">
        <header th:replace="~{fragments/layout :: topbar}"></header>
        <main class="main-content">

            <nav aria-label="breadcrumb">
                <ol class="breadcrumb">
                    <li class="breadcrumb-item"><a th:href="@{/marketplace}">Marketplace</a></li>
                    <li class="breadcrumb-item active" th:text="${offering?.name}"></li>
                </ol>
            </nav>

            <div class="content-card">
                <h6>Create Service Instance</h6>
                <form th:action="@{/services}" method="post">
                    <div class="mb-3">
                        <label class="form-label">Instance Name</label>
                        <input type="text" class="form-control" name="name" required>
                    </div>
                    <div class="mb-3">
                        <label class="form-label">Plan</label>
                        <select class="form-select" name="planGuid" required>
                            <option th:each="plan : ${plans}" th:value="${plan.guid}" th:text="${plan.name + ' — ' + plan.description}"></option>
                        </select>
                    </div>
                    <div class="mb-3">
                        <label class="form-label">Space</label>
                        <select class="form-select" name="spaceGuid" required>
                            <option th:each="space : ${spaces}" th:value="${space.guid}" th:text="${space.name}"></option>
                        </select>
                    </div>

                    <!-- Parameters (only for services that support them) -->
                    <div class="mb-3" th:if="${catalogMetadata != null and catalogMetadata.containsKey('docsParameters')}">
                        <label class="form-label">
                            Parameters (JSON)
                            <button type="button" class="btn btn-sm btn-link p-0 ms-1"
                                    data-bs-toggle="modal" data-bs-target="#paramsDocsModal">
                                <i class="bi bi-question-circle"></i>
                            </button>
                        </label>
                        <textarea class="form-control font-monospace" name="parameters"
                                  rows="5" placeholder='{"provider":"ollama","host":"192.168.64.1","port":11434}'></textarea>
                        <small class="text-muted">
                            <i class="bi bi-info-circle me-1"></i>Click <i class="bi bi-question-circle"></i> for parameter format
                        </small>
                    </div>

                    <button type="submit" class="btn btn-spring-green">Create</button>
                    <a th:href="@{/marketplace}" class="btn btn-secondary ms-2">Cancel</a>
                </form>
            </div>

            <!-- Parameters Documentation Modal -->
            <div th:if="${catalogMetadata != null and catalogMetadata.containsKey('docsParameters')}"
                 class="modal fade" id="paramsDocsModal" tabindex="-1">
                <div class="modal-dialog modal-lg">
                    <div class="modal-content" style="background: var(--spring-card); border-color: var(--spring-border);">
                        <div class="modal-header border-secondary">
                            <h5 class="modal-title">
                                <i class="bi bi-code-square me-2"></i>
                                Parameters — <span th:text="${offering?.name}"></span>
                            </h5>
                            <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                        </div>
                        <div class="modal-body" th:utext="${catalogMetadata.get('docsParameters')}">
                        </div>
                        <div class="modal-footer border-secondary">
                            <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Close</button>
                        </div>
                    </div>
                </div>
            </div>

        </main>
    </div>
</div>
<div th:replace="~{fragments/layout :: scripts}"></div>
</body>
</html>
```

- [ ] **Step 2: Commit**

```bash
git add k8/apps/kappman/src/main/resources/templates/marketplace/create-instance.html
git commit -m "feat(kappman): add JSON parameters textarea and docs modal to create-instance form"
```

---

### Task 7: Kappman Version Bump

**Files:**
- Modify: `k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/config/GlobalModelAttributes.kt`

- [ ] **Step 1: Bump version to V1.1.0**

In `k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/config/GlobalModelAttributes.kt`, change line 18:

```kotlin
        model.addAttribute("appVersion", "V1.0.0")
```

To:

```kotlin
        model.addAttribute("appVersion", "V1.1.0")
```

- [ ] **Step 2: Commit**

```bash
git add k8/apps/kappman/src/main/kotlin/cool/cfapps/kappman/config/GlobalModelAttributes.kt
git commit -m "chore(kappman): bump version to V1.1.0"
```

---

### Task 8: Installer — Update phase9.sh with Broker Updates + Kappman Redeploy

**Files:**
- Modify: `k8/distribution/lib/phase9.sh`
- Modify: `k8/services/cf-service-broker/deployment.yaml`

- [ ] **Step 1: Add existing broker update step to phase9.sh**

In `k8/distribution/lib/phase9.sh`, after the `phase9_broker_image` step (after line 71 `fi`), insert a new step for the existing broker:

```bash

  # --- Step 2a: Update existing service broker with metadata ---
  if ! component_is_installed "phase9_existing_broker_update" "$STATE_FILE"; then
    log_step "Updating existing service broker to v1.4.0 (adding service documentation)"

    local EXISTING_BROKER_SRC="${INSTALL_DIR}/../services/cf-service-broker/src"
    local EXISTING_BROKER_IMAGE="artifactory.cfapps.cool/docker-local/cf-service-broker:1.4.0-arm64"
    local BASE_IMAGE="gcr.io/distroless/static:nonroot"

    if command -v go &>/dev/null && command -v crane &>/dev/null; then
      local BUILD_DIR
      BUILD_DIR=$(mktemp -d)

      log_info "Cross-compiling existing broker for linux/arm64..."
      (cd "${EXISTING_BROKER_SRC}" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o "${BUILD_DIR}/broker" .)

      local TMPDIR_IMG
      TMPDIR_IMG=$(mktemp -d)
      mkdir -p "${TMPDIR_IMG}/app"
      cp "${BUILD_DIR}/broker" "${TMPDIR_IMG}/app/broker"
      chmod +x "${TMPDIR_IMG}/app/broker"

      local LAYER
      LAYER=$(mktemp)
      (cd "${TMPDIR_IMG}" && tar cf "${LAYER}" app/)

      crane append --base "${BASE_IMAGE}" --new_tag "${EXISTING_BROKER_IMAGE}" --new_layer "${LAYER}" --platform linux/arm64 --insecure 2>/dev/null
      crane mutate "${EXISTING_BROKER_IMAGE}" --entrypoint "/app/broker" --tag "${EXISTING_BROKER_IMAGE}" --insecure 2>/dev/null

      rm -rf "${BUILD_DIR}" "${TMPDIR_IMG}" "${LAYER}"
      log_success "Existing broker image built and pushed: ${EXISTING_BROKER_IMAGE}"

      kubectl set image deployment/cf-service-broker -n cf-services \
        broker="${EXISTING_BROKER_IMAGE}"
      kubectl rollout status deployment/cf-service-broker -n cf-services --timeout=60s
      log_success "Existing broker updated to v1.4.0"
    else
      log_warn "go or crane not found — update broker manually"
    fi

    mark_component_installed "phase9_existing_broker_update" "$STATE_FILE"
  fi
```

- [ ] **Step 2: Add kappman update step to phase9.sh**

Before the `mark_phase_complete 9` line (before line 171), insert a new step:

```bash

  # --- Step 8: Update kappman ---
  if ! component_is_installed "phase9_kappman_update" "$STATE_FILE"; then
    log_step "Updating kappman to V1.1.0 (parameters + service docs)"

    local KAPPMAN_DIR="${INSTALL_DIR}/../apps/kappman"
    (cd "$KAPPMAN_DIR" && cf push kappman) && {
      log_success "kappman updated to V1.1.0"
    } || {
      log_warn "kappman update failed — update manually with: cd k8/apps/kappman && cf push kappman"
    }

    mark_component_installed "phase9_kappman_update" "$STATE_FILE"
  fi
```

- [ ] **Step 3: Update deployment.yaml image tag**

In `k8/services/cf-service-broker/deployment.yaml`, change the image tag from `1.3.1-arm64` to `1.4.0-arm64`:

Change:

```yaml
          image: artifactory.cfapps.cool/docker-local/cf-service-broker:1.3.1-arm64
```

To:

```yaml
          image: artifactory.cfapps.cool/docker-local/cf-service-broker:1.4.0-arm64
```

- [ ] **Step 4: Verify phase9.sh syntax**

```bash
bash -n k8/distribution/lib/phase9.sh && echo "OK"
```

Expected: OK

- [ ] **Step 5: Commit**

```bash
git add k8/distribution/lib/phase9.sh k8/services/cf-service-broker/deployment.yaml
git commit -m "feat(installer): add broker updates and kappman redeploy to Phase 9"
```

---

### Task 9: Build, Deploy and Verify

- [ ] **Step 1: Build and push updated broker images**

```bash
# Existing broker v1.4.0
cd k8/services/cf-service-broker/src
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /tmp/cf-service-broker .
# Use crane to push (same pattern as phase9.sh)

# Marketplace broker v1.1.0
cd k8/services/cf-marketplace-broker/src
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /tmp/cf-marketplace-broker .
# Use crane to push
```

- [ ] **Step 2: Update existing broker in cluster**

```bash
limactl shell k3s-server -- kubectl set image deployment/cf-service-broker -n cf-services \
  broker=artifactory.cfapps.cool/docker-local/cf-service-broker:1.4.0-arm64
limactl shell k3s-server -- kubectl rollout status deployment/cf-service-broker -n cf-services --timeout=60s
```

- [ ] **Step 3: Update marketplace broker in cluster**

```bash
limactl shell k3s-server -- kubectl set image deployment/cf-marketplace-broker -n cf-services \
  broker=artifactory.cfapps.cool/docker-local/cf-marketplace-broker:1.1.0-arm64
limactl shell k3s-server -- kubectl rollout status deployment/cf-marketplace-broker -n cf-services --timeout=60s
```

- [ ] **Step 4: Verify catalog metadata via OSBAPI**

```bash
# Check existing broker catalog has metadata
BROKER_PWD=$(limactl shell k3s-server -- kubectl get secret ... )
curl -s -u admin:$BROKER_PWD http://cf-service-broker.cf-services.svc/v2/catalog | jq '.services[0].metadata'
```

Expected: JSON with `displayName`, `docsOverview`, `docsCredentials` keys.

- [ ] **Step 5: Redeploy kappman**

```bash
cd k8/apps/kappman && cf push kappman
```

- [ ] **Step 6: Verify kappman marketplace**

Open `https://kappman.development.cfapps.cool/marketplace` in browser. Verify:
- Each service card has an info button (top-right)
- Clicking info button opens a modal with tabs (Overview, Credentials; Parameters only for ai-connector)
- Creating an ai-connector service shows the JSON parameters textarea
- Version in footer shows V1.1.0

- [ ] **Step 7: Test ai-connector creation with parameters via kappman**

1. Go to Marketplace → AI Model Connector → Create Instance
2. Enter name, select plan and space
3. Paste `{"provider":"ollama","host":"192.168.64.1","port":11434}` in Parameters field
4. Click Create
5. Verify service appears in Services list

- [ ] **Step 8: Commit any final fixes**

```bash
git add -A && git commit -m "feat: verified kappman V1.1.0 with marketplace docs and parameters"
```
