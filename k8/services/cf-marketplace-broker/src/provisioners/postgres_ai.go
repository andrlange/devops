package provisioners

import (
	"context"

	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
)

type PostgresAI struct{}

func (p *PostgresAI) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string, params map[string]interface{}) error {
	return nil // stub
}
func (p *PostgresAI) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	return nil
}
func (p *PostgresAI) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	return false, "stub", nil
}
func (p *PostgresAI) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	return nil, nil
}
