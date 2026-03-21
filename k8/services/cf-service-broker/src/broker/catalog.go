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
)

func serviceCatalog() []domain.Service {
	return []domain.Service{
		{
			ID:          PostgreSQLServiceID,
			Name:        "postgresql",
			Description: "PostgreSQL 18 via CloudNativePG",
			Bindable:    true,
			Tags:        []string{"postgresql", "sql", "database"},
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
	}
}
