package provisioners

import (
	"context"

	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
)

type AIConnector struct{}

func (a *AIConnector) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string, params map[string]interface{}) error {
	return nil
}
func (a *AIConnector) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	return nil
}
func (a *AIConnector) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	return false, "stub", nil
}
func (a *AIConnector) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	return nil, nil
}
