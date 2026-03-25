package broker

import (
	"context"
	"fmt"
	"log"

	k8sclient "github.com/cfapps/cf-service-broker/k8s"
	"github.com/cfapps/cf-service-broker/provisioners"
	"github.com/pivotal-cf/brokerapi/v11/domain"
	"github.com/pivotal-cf/brokerapi/v11/domain/apiresponses"
)

type GarageConfig struct {
	AdminURL   string
	AdminToken string
	S3Endpoint string
}

type Broker struct {
	client       *k8sclient.Client
	namespace    string
	provisioners map[string]provisioners.Provisioner
}

func New(client *k8sclient.Client, namespace, valkeyImage string, garage GarageConfig) *Broker {
	return &Broker{
		client:    client,
		namespace: namespace,
		provisioners: map[string]provisioners.Provisioner{
			PostgreSQLServiceID: &provisioners.PostgreSQL{},
			ValkeyServiceID:     &provisioners.Valkey{Image: valkeyImage},
			RabbitMQServiceID:   &provisioners.RabbitMQ{},
			S3ServiceID: &provisioners.S3{
				AdminURL:   garage.AdminURL,
				AdminToken: garage.AdminToken,
				S3Endpoint: garage.S3Endpoint,
			},
		},
	}
}

func (b *Broker) Services(ctx context.Context) ([]domain.Service, error) {
	return serviceCatalog(), nil
}

func (b *Broker) Provision(ctx context.Context, instanceID string, details domain.ProvisionDetails, asyncAllowed bool) (domain.ProvisionedServiceSpec, error) {
	if !asyncAllowed {
		return domain.ProvisionedServiceSpec{}, apiresponses.ErrAsyncRequired
	}

	prov, ok := b.provisioners[details.ServiceID]
	if !ok {
		return domain.ProvisionedServiceSpec{}, fmt.Errorf("unknown service ID: %s", details.ServiceID)
	}

	name := provisioners.ResourceName(instanceID)

	// Idempotent: if instance already exists, return success
	if _, err := getInstance(ctx, b.client.Typed, b.namespace, instanceID); err == nil {
		log.Printf("Instance %s already exists, returning success", instanceID)
		return domain.ProvisionedServiceSpec{
			IsAsync:       true,
			OperationData: "provisioning",
			AlreadyExists: true,
		}, nil
	}

	log.Printf("Provisioning %s (plan=%s, name=%s)", details.ServiceID, details.PlanID, name)

	if err := prov.Provision(ctx, b.client, name, b.namespace, details.PlanID); err != nil {
		return domain.ProvisionedServiceSpec{}, fmt.Errorf("provision failed: %w", err)
	}

	if err := saveInstance(ctx, b.client.Typed, b.namespace, instanceID, InstanceState{
		ServiceID: details.ServiceID,
		PlanID:    details.PlanID,
		Name:      name,
		Namespace: b.namespace,
	}); err != nil {
		log.Printf("Warning: failed to save instance state: %v", err)
	}

	return domain.ProvisionedServiceSpec{
		IsAsync:       true,
		OperationData: "provisioning",
	}, nil
}

func (b *Broker) Deprovision(ctx context.Context, instanceID string, details domain.DeprovisionDetails, asyncAllowed bool) (domain.DeprovisionServiceSpec, error) {
	state, err := getInstance(ctx, b.client.Typed, b.namespace, instanceID)
	if err != nil {
		return domain.DeprovisionServiceSpec{}, apiresponses.ErrInstanceDoesNotExist
	}

	prov, ok := b.provisioners[state.ServiceID]
	if !ok {
		return domain.DeprovisionServiceSpec{}, fmt.Errorf("unknown service ID: %s", state.ServiceID)
	}

	log.Printf("Deprovisioning %s (name=%s)", state.ServiceID, state.Name)

	if err := prov.Deprovision(ctx, b.client, state.Name, state.Namespace); err != nil {
		log.Printf("Warning: deprovision error: %v", err)
	}

	_ = deleteInstance(ctx, b.client.Typed, b.namespace, instanceID)

	return domain.DeprovisionServiceSpec{}, nil
}

func (b *Broker) Bind(ctx context.Context, instanceID, bindingID string, details domain.BindDetails, asyncAllowed bool) (domain.Binding, error) {
	state, err := getInstance(ctx, b.client.Typed, b.namespace, instanceID)
	if err != nil {
		return domain.Binding{}, apiresponses.ErrInstanceDoesNotExist
	}

	prov, ok := b.provisioners[state.ServiceID]
	if !ok {
		return domain.Binding{}, fmt.Errorf("unknown service ID: %s", state.ServiceID)
	}

	creds, err := prov.GetCredentials(ctx, b.client, state.Name, state.Namespace)
	if err != nil {
		return domain.Binding{}, fmt.Errorf("failed to get credentials: %w", err)
	}

	return domain.Binding{Credentials: creds}, nil
}

func (b *Broker) Unbind(ctx context.Context, instanceID, bindingID string, details domain.UnbindDetails, asyncAllowed bool) (domain.UnbindSpec, error) {
	return domain.UnbindSpec{}, nil
}

func (b *Broker) LastOperation(ctx context.Context, instanceID string, details domain.PollDetails) (domain.LastOperation, error) {
	state, err := getInstance(ctx, b.client.Typed, b.namespace, instanceID)
	if err != nil {
		return domain.LastOperation{State: domain.Failed, Description: "instance not found"}, nil
	}

	prov, ok := b.provisioners[state.ServiceID]
	if !ok {
		return domain.LastOperation{State: domain.Failed, Description: "unknown service"}, nil
	}

	ready, desc, err := prov.IsReady(ctx, b.client, state.Name, state.Namespace)
	if err != nil {
		return domain.LastOperation{State: domain.InProgress, Description: desc}, nil
	}

	if ready {
		return domain.LastOperation{State: domain.Succeeded, Description: desc}, nil
	}
	return domain.LastOperation{State: domain.InProgress, Description: desc}, nil
}

func (b *Broker) GetInstance(ctx context.Context, instanceID string, details domain.FetchInstanceDetails) (domain.GetInstanceDetailsSpec, error) {
	state, err := getInstance(ctx, b.client.Typed, b.namespace, instanceID)
	if err != nil {
		return domain.GetInstanceDetailsSpec{}, apiresponses.ErrInstanceDoesNotExist
	}
	return domain.GetInstanceDetailsSpec{
		ServiceID: state.ServiceID,
		PlanID:    state.PlanID,
	}, nil
}

func (b *Broker) GetBinding(ctx context.Context, instanceID, bindingID string, details domain.FetchBindingDetails) (domain.GetBindingSpec, error) {
	return domain.GetBindingSpec{}, apiresponses.NewFailureResponseBuilder(
		fmt.Errorf("not supported"), 404, "not-found",
	).Build()
}

func (b *Broker) Update(ctx context.Context, instanceID string, details domain.UpdateDetails, asyncAllowed bool) (domain.UpdateServiceSpec, error) {
	return domain.UpdateServiceSpec{}, apiresponses.NewFailureResponseBuilder(
		fmt.Errorf("plan updates not supported"), 422, "not-supported",
	).Build()
}

func (b *Broker) LastBindingOperation(ctx context.Context, instanceID, bindingID string, details domain.PollDetails) (domain.LastOperation, error) {
	return domain.LastOperation{State: domain.Succeeded}, nil
}
