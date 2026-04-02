package broker

import (
	"github.com/pivotal-cf/brokerapi/v11/domain"
)

const (
	PostgreSQLServiceID  = "d1a5c0f2-7b3e-4a1d-9c8f-0e2b4a6d8c1e"
	ValkeyServiceID      = "e2b6d1f3-8c4f-5b2e-0d9a-1f3c5b7e9d2f"
	RabbitMQServiceID    = "f3c7e2a4-9d5a-6c3f-1e0b-2a4d6c8f0e3a"

	PostgreSQLSmallPlanID  = "a1b2c3d4-1111-1111-1111-000000000001"
	PostgreSQLMediumPlanID = "a1b2c3d4-1111-1111-1111-000000000002"
	ValkeySmallPlanID      = "a1b2c3d4-2222-2222-2222-000000000001"
	RabbitMQSmallPlanID    = "a1b2c3d4-3333-3333-3333-000000000001"

	S3ServiceID         = "a4d8f2b1-6e3c-4f7a-8b9d-5c1e3a7f2d4b"
	S3DefaultPlanID     = "b5e9a3c2-7f4d-5a8b-9c0e-6d2f4b8a1c5e"
)

func serviceCatalog() []domain.Service {
	return []domain.Service{
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
			Plans: []domain.ServicePlan{
				{
					ID:          PostgreSQLSmallPlanID,
					Name:        "small",
					Description: "1 instance, 256Mi RAM, 1Gi storage",
					Free:        domain.FreeValue(true),
				},
				{
					ID:          PostgreSQLMediumPlanID,
					Name:        "medium",
					Description: "1 instance, 512Mi RAM, 5Gi storage",
					Free:        domain.FreeValue(true),
				},
			},
			PlanUpdatable: false,
		},
		{
			ID:          ValkeyServiceID,
			Name:        "valkey",
			Description: "Valkey (Redis-compatible) key-value store",
			Bindable:    true,
			Tags:        []string{"valkey", "redis", "cache", "key-value"},
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
			Plans: []domain.ServicePlan{
				{
					ID:          ValkeySmallPlanID,
					Name:        "small",
					Description: "1 instance, 128Mi RAM, 1Gi storage",
					Free:        domain.FreeValue(true),
				},
			},
			PlanUpdatable: false,
		},
		{
			ID:          RabbitMQServiceID,
			Name:        "rabbitmq",
			Description: "RabbitMQ message broker",
			Bindable:    true,
			Tags:        []string{"rabbitmq", "amqp", "messaging"},
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
			Plans: []domain.ServicePlan{
				{
					ID:          RabbitMQSmallPlanID,
					Name:        "small",
					Description: "1 instance, 256Mi RAM, 1Gi storage",
					Free:        domain.FreeValue(true),
				},
			},
			PlanUpdatable: false,
		},
		{
			ID:          S3ServiceID,
			Name:        "s3",
			Description: "S3-compatible object storage powered by Garage",
			Bindable:    true,
			Tags:        []string{"s3", "object-storage", "garage"},
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
			Plans: []domain.ServicePlan{
				{
					ID:          S3DefaultPlanID,
					Name:        "default",
					Description: "Dedicated S3 bucket with read/write access",
					Free:        domain.FreeValue(true),
				},
			},
			PlanUpdatable: false,
		},
	}
}
