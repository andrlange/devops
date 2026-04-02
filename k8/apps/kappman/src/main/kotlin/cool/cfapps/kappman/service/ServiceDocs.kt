package cool.cfapps.kappman.service

object ServiceDocs {

    data class Docs(
        val displayName: String,
        val docsOverview: String,
        val docsParameters: String? = null,
        val docsCredentials: String? = null,
        val docsCreateService: String? = null
    )

    private val docs = mapOf(
        "postgresql" to Docs(
            displayName = "PostgreSQL",
            docsOverview = """<p>Managed <strong>PostgreSQL 18</strong> database powered by CloudNativePG.</p>
<ul>
<li>Single-instance deployment with local-path storage</li>
<li>Automatic credentials via CloudNativePG operator</li>
<li>Plans: <code>small</code> (256Mi/1Gi), <code>medium</code> (512Mi/5Gi)</li>
</ul>""",
            docsCredentials = """<p>Binding credentials include:</p>
<pre><code>{
  "type": "postgresql",
  "hostname": "pg-&lt;id&gt;.cf-services.svc.cluster.local",
  "port": "5432",
  "database": "app",
  "username": "app",
  "password": "&lt;generated&gt;",
  "uri": "postgres://app:&lt;pw&gt;@&lt;host&gt;:5432/app",
  "jdbcUrl": "jdbc:postgresql://&lt;host&gt;:5432/app"
}</code></pre>""",
            docsCreateService = """<h6>Create a PostgreSQL Instance</h6>
<pre><code>cf create-service postgresql small my-db
cf create-service postgresql medium my-large-db</code></pre>
<h6>Bind to an Application</h6>
<pre><code>cf bind-service my-app my-db
cf restage my-app</code></pre>
<p>The application receives connection details via <code>VCAP_SERVICES</code> environment variable or service bindings at <code>/bindings/my-db/</code>.</p>"""
        ),

        "valkey" to Docs(
            displayName = "Valkey",
            docsOverview = """<p><strong>Valkey</strong> — Redis-compatible in-memory key-value store.</p>
<ul>
<li>Password-protected, single-instance StatefulSet</li>
<li>Persistent storage via local-path</li>
<li>Plan: <code>small</code> (128Mi/1Gi)</li>
</ul>""",
            docsCredentials = """<p>Binding credentials include:</p>
<pre><code>{
  "type": "redis",
  "hostname": "valkey-&lt;id&gt;.cf-services.svc.cluster.local",
  "port": "6379",
  "password": "&lt;generated&gt;",
  "uri": "redis://:&lt;pw&gt;@&lt;host&gt;:6379"
}</code></pre>""",
            docsCreateService = """<h6>Create a Valkey Instance</h6>
<pre><code>cf create-service valkey small my-cache</code></pre>
<h6>Bind to an Application</h6>
<pre><code>cf bind-service my-app my-cache
cf restage my-app</code></pre>
<p>Use the <code>uri</code> from the binding credentials to connect with any Redis-compatible client.</p>"""
        ),

        "rabbitmq" to Docs(
            displayName = "RabbitMQ",
            docsOverview = """<p><strong>RabbitMQ</strong> message broker via the RabbitMQ Cluster Operator.</p>
<ul>
<li>Single-instance cluster with management UI</li>
<li>AMQP 0-9-1 protocol</li>
<li>Plan: <code>small</code> (256Mi/1Gi)</li>
</ul>""",
            docsCredentials = """<p>Binding credentials include:</p>
<pre><code>{
  "type": "rabbitmq",
  "hostname": "rmq-&lt;id&gt;.cf-services.svc.cluster.local",
  "port": "5672",
  "username": "default_user_...",
  "password": "&lt;generated&gt;",
  "uri": "amqp://&lt;user&gt;:&lt;pw&gt;@&lt;host&gt;:5672/%2f",
  "http_api_uri": "http://&lt;user&gt;:&lt;pw&gt;@&lt;host&gt;:15672/api",
  "vhost": "/"
}</code></pre>""",
            docsCreateService = """<h6>Create a RabbitMQ Instance</h6>
<pre><code>cf create-service rabbitmq small my-mq</code></pre>
<h6>Bind to an Application</h6>
<pre><code>cf bind-service my-app my-mq
cf restage my-app</code></pre>
<p>Use the <code>uri</code> (AMQP) or <code>http_api_uri</code> (Management API) from the binding credentials.</p>"""
        ),

        "s3" to Docs(
            displayName = "S3 Object Storage",
            docsOverview = """<p><strong>S3-compatible object storage</strong> powered by Garage.</p>
<ul>
<li>Dedicated bucket per service instance</li>
<li>AWS S3-compatible API (path-style)</li>
<li>Plan: <code>default</code></li>
</ul>""",
            docsCredentials = """<p>Binding credentials include:</p>
<pre><code>{
  "type": "s3",
  "access_key_id": "&lt;generated&gt;",
  "secret_access_key": "&lt;generated&gt;",
  "endpoint": "http://garage.garage.svc.cluster.local:3900",
  "bucket": "&lt;bucket-name&gt;",
  "region": "garage",
  "path_style": true,
  "uri": "s3://&lt;key&gt;:&lt;secret&gt;@&lt;endpoint&gt;/&lt;bucket&gt;"
}</code></pre>""",
            docsCreateService = """<h6>Create an S3 Bucket</h6>
<pre><code>cf create-service s3 default my-bucket</code></pre>
<h6>Bind to an Application</h6>
<pre><code>cf bind-service my-app my-bucket
cf restage my-app</code></pre>
<p>Use <code>access_key_id</code>, <code>secret_access_key</code>, <code>endpoint</code>, and <code>bucket</code> from the binding credentials with any S3-compatible client (AWS SDK, MinIO client, etc.). Set <code>path_style=true</code>.</p>"""
        ),

        "postgres-ai" to Docs(
            displayName = "PostgreSQL AI Enabled",
            docsOverview = """<p><strong>PostgreSQL 17</strong> with AI/ML extensions, powered by the Timescale HA image and CloudNativePG.</p>
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
<p>Built-in full-text search (<code>tsvector</code>/<code>tsquery</code>) is always available.</p>""",
            docsCredentials = """<p>Binding credentials include an <code>extensions</code> array listing all enabled extensions:</p>
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
}</code></pre>""",
            docsCreateService = """<h6>Create a PostgreSQL AI Instance</h6>
<pre><code>cf create-service postgres-ai small my-vector-db
cf create-service postgres-ai medium my-large-ai-db</code></pre>
<h6>Bind to an Application</h6>
<pre><code>cf bind-service my-app my-vector-db
cf restage my-app</code></pre>
<p>All AI/ML extensions are pre-activated. Use <code>pgvector</code> for vector similarity search:</p>
<pre><code>CREATE TABLE items (id serial, embedding vector(1536));
INSERT INTO items (embedding) VALUES ('[0.1, 0.2, ...]');
SELECT * FROM items ORDER BY embedding &lt;-&gt; '[0.3, 0.4, ...]' LIMIT 5;</code></pre>"""
        ),

        "openbao-secrets" to Docs(
            displayName = "OpenBao Secret Container",
            docsOverview = """<p>Managed <strong>secret container</strong> in OpenBao with AppRole-based access.</p>
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
</ol>""",
            docsCredentials = """<p>Binding credentials provide AppRole authentication details:</p>
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
GET /v1/cf-secrets/data/instance-&lt;id&gt;/my-key</code></pre>""",
            docsCreateService = """<h6>Create a Secret Container</h6>
<pre><code>cf create-service openbao-secrets default my-secrets</code></pre>
<h6>Bind to an Application</h6>
<pre><code>cf bind-service my-app my-secrets
cf restage my-app</code></pre>
<p>The application receives <code>role_id</code> and <code>secret_id</code> for AppRole authentication. Use these to login to OpenBao and manage secrets under the dedicated path.</p>"""
        ),

        "ai-connector" to Docs(
            displayName = "AI Model Connector",
            docsOverview = """<p>Connect your application to external <strong>AI model providers</strong> (Ollama, LM Studio) via the OpenAI-compatible API.</p>
<ul>
<li>Automatic credential injection into service bindings</li>
<li>Single or multi-endpoint configuration</li>
<li>OpenAI-compatible <code>/v1/models</code> and <code>/v1/chat/completions</code></li>
<li>Default ports: Ollama <code>11434</code>, LM Studio <code>1234</code></li>
</ul>""",
            docsParameters = """<p>Parameters are <strong>required</strong> when creating this service.</p>
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
</table>""",
            docsCredentials = """<h6>Single Endpoint</h6>
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
</ol>""",
            docsCreateService = """<h6>Create with Single Endpoint (Ollama)</h6>
<pre><code>cf create-service ai-connector default my-ollama \
  -c '{"provider":"ollama","host":"192.168.64.1","port":11434}'</code></pre>
<h6>Create with Single Endpoint (LM Studio)</h6>
<pre><code>cf create-service ai-connector default my-lmstudio \
  -c '{"provider":"lmstudio","host":"192.168.64.1","port":1234}'</code></pre>
<h6>Create with Multiple Endpoints</h6>
<pre><code>cf create-service ai-connector default my-ai \
  -c '{"endpoints":[
    {"name":"ollama","provider":"ollama","host":"192.168.64.1","port":11434},
    {"name":"lmstudio","provider":"lmstudio","host":"192.168.64.1","port":1234}
  ]}'</code></pre>
<h6>With API Key (if required)</h6>
<pre><code>cf create-service ai-connector default my-ai \
  -c '{"provider":"ollama","host":"10.0.1.50","port":11434,"api_key":"sk-xxx"}'</code></pre>
<h6>Bind to an Application</h6>
<pre><code>cf bind-service my-app my-ollama
cf restage my-app</code></pre>
<p>The application receives <code>base_url</code> and <code>models_url</code> for the OpenAI-compatible API. Use any OpenAI SDK client to interact with the models.</p>"""
        )
    )

    fun forService(name: String): Docs? = docs[name]

    fun asMetadataMap(name: String): Map<String, Any> {
        val d = docs[name] ?: return emptyMap()
        val map = mutableMapOf<String, Any>(
            "displayName" to d.displayName,
            "docsOverview" to d.docsOverview
        )
        d.docsParameters?.let { map["docsParameters"] = it }
        d.docsCredentials?.let { map["docsCredentials"] = it }
        d.docsCreateService?.let { map["docsCreateService"] = it }
        return map
    }
}
