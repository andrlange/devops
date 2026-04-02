package provisioners

import (
	"context"

	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
)

type OpenBaoSecrets struct {
	Addr  string
	Token string
}

func (o *OpenBaoSecrets) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string, params map[string]interface{}) error {
	return nil
}
func (o *OpenBaoSecrets) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	return nil
}
func (o *OpenBaoSecrets) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	return false, "stub", nil
}
func (o *OpenBaoSecrets) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	return nil, nil
}
