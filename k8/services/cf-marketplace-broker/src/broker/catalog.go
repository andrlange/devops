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
