package provisioners

import (
	"context"

	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
)

type Provisioner interface {
	Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string, params map[string]interface{}) error
	Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error
	IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error)
	GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error)
}

func ResourceName(instanceID string) string {
	if len(instanceID) > 8 {
		return instanceID[:8]
	}
	return instanceID
}
