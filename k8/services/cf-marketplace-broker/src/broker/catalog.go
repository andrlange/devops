package broker

import (
	"github.com/pivotal-cf/brokerapi/v11/domain"
)

const (
	PostgresAIServiceID     = "b1a2c3d4-e5f6-7890-abcd-100000000001"
	OpenBaoSecretsServiceID = "b1a2c3d4-e5f6-7890-abcd-200000000002"
	AIConnectorServiceID    = "b1a2c3d4-e5f6-7890-abcd-300000000003"

	PostgresAISmallPlanID    = "c2d3e4f5-a1b2-7890-abcd-100000000011"
	PostgresAIMediumPlanID   = "c2d3e4f5-a1b2-7890-abcd-100000000012"
	OpenBaoDefaultPlanID     = "c2d3e4f5-a1b2-7890-abcd-200000000021"
	AIConnectorDefaultPlanID = "c2d3e4f5-a1b2-7890-abcd-300000000031"
)

func serviceCatalog() []domain.Service {
	return []domain.Service{
		{
			ID:          PostgresAIServiceID,
			Name:        "postgres-ai",
			Description: "PostgreSQL 17 with pgvector, pgvectorscale, PostGIS, full-text search, and AI/ML extensions",
			Bindable:    true,
			Tags:        []string{"postgresql", "ai", "vector", "ml", "database"},
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
			Plans: []domain.ServicePlan{
				{
					ID:          PostgresAISmallPlanID,
					Name:        "small",
					Description: "1 instance, 512Mi RAM, 2Gi storage — pgvector, pgvectorscale, PostGIS, pg_trgm, fuzzystrmatch, pgcrypto, uuid-ossp, unaccent, pg_stat_statements",
					Free:        domain.FreeValue(true),
				},
				{
					ID:          PostgresAIMediumPlanID,
					Name:        "medium",
					Description: "1 instance, 1Gi RAM, 10Gi storage — pgvector, pgvectorscale, PostGIS, pg_trgm, fuzzystrmatch, pgcrypto, uuid-ossp, unaccent, pg_stat_statements",
					Free:        domain.FreeValue(true),
				},
			},
			PlanUpdatable: false,
		},
		{
			ID:          OpenBaoSecretsServiceID,
			Name:        "openbao-secrets",
			Description: "Managed secret container in OpenBao with AppRole access for application-managed secrets",
			Bindable:    true,
			Tags:        []string{"secrets", "vault", "openbao", "security"},
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
			Plans: []domain.ServicePlan{
				{
					ID:          OpenBaoDefaultPlanID,
					Name:        "default",
					Description: "Dedicated KV v2 path, AppRole with 24h TTL",
					Free:        domain.FreeValue(true),
				},
			},
			PlanUpdatable: false,
		},
		{
			ID:          AIConnectorServiceID,
			Name:        "ai-connector",
			Description: "Connect to external AI model providers (Ollama, LM Studio) via OpenAI-compatible API",
			Bindable:    true,
			Tags:        []string{"ai", "llm", "ollama", "lmstudio", "connector"},
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
			Plans: []domain.ServicePlan{
				{
					ID:          AIConnectorDefaultPlanID,
					Name:        "default",
					Description: "External AI endpoint connector (Ollama, LM Studio)",
					Free:        domain.FreeValue(true),
				},
			},
			PlanUpdatable: false,
		},
	}
}
