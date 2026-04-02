package provisioners

import (
	"context"
	"fmt"

	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

var cnpgGVR = schema.GroupVersionResource{
	Group:    "postgresql.cnpg.io",
	Version:  "v1",
	Resource: "clusters",
}

var aiExtensions = []string{
	"vector",
	"vectorscale",
	"pg_trgm",
	"fuzzystrmatch",
	"pgcrypto",
	`"uuid-ossp"`,
	"postgis",
	"unaccent",
	"pg_stat_statements",
}

func extensionSQL() []interface{} {
	stmts := make([]interface{}, len(aiExtensions))
	for i, ext := range aiExtensions {
		stmts[i] = fmt.Sprintf("CREATE EXTENSION IF NOT EXISTS %s;", ext)
	}
	return stmts
}

type PostgresAI struct{}

func (p *PostgresAI) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string, params map[string]interface{}) error {
	memory := "512Mi"
	memoryLimit := "1Gi"
	storage := "2Gi"
	cpu := "100m"

	if planID == "c2d3e4f5-a1b2-7890-abcd-100000000012" { // medium
		memory = "1Gi"
		memoryLimit = "2Gi"
		storage = "10Gi"
		cpu = "250m"
	}

	cluster := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "postgresql.cnpg.io/v1",
			"kind":       "Cluster",
			"metadata": map[string]interface{}{
				"name":      "pgai-" + name,
				"namespace": namespace,
				"labels": map[string]interface{}{
					"cf-marketplace-broker/instance-id": name,
					"cf-marketplace-broker/service":     "postgres-ai",
				},
			},
			"spec": map[string]interface{}{
				"instances": int64(1),
				"imageName": "artifactory.cfapps.cool/docker-local/timescale/timescaledb-ha:pg17-arm64",
				"postgresql": map[string]interface{}{
					"parameters": map[string]interface{}{
						"max_connections":          "100",
						"shared_preload_libraries": "timescaledb",
					},
				},
				"resources": map[string]interface{}{
					"requests": map[string]interface{}{
						"cpu":    cpu,
						"memory": memory,
					},
					"limits": map[string]interface{}{
						"memory": memoryLimit,
					},
				},
				"storage": map[string]interface{}{
					"size":         storage,
					"storageClass": "local-path",
				},
				"bootstrap": map[string]interface{}{
					"initdb": map[string]interface{}{
						"database":    "app",
						"owner":       "app",
						"postInitSQL": extensionSQL(),
					},
				},
			},
		},
	}

	_, err := client.Dynamic.Resource(cnpgGVR).Namespace(namespace).Create(ctx, cluster, metav1.CreateOptions{})
	return err
}

func (p *PostgresAI) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	return client.Dynamic.Resource(cnpgGVR).Namespace(namespace).Delete(ctx, "pgai-"+name, metav1.DeleteOptions{})
}

func (p *PostgresAI) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	obj, err := client.Dynamic.Resource(cnpgGVR).Namespace(namespace).Get(ctx, "pgai-"+name, metav1.GetOptions{})
	if err != nil {
		return false, "not found", err
	}

	conditions, found, err := unstructured.NestedSlice(obj.Object, "status", "conditions")
	if err != nil || !found {
		return false, "provisioning", nil
	}

	for _, c := range conditions {
		cond, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		if cond["type"] == "Ready" && cond["status"] == "True" {
			return true, "succeeded", nil
		}
	}
	return false, "provisioning", nil
}

func (p *PostgresAI) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	secretName := "pgai-" + name + "-app"
	secret, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, secretName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("credentials secret %s not found: %w", secretName, err)
	}

	host := string(secret.Data["host"])
	port := string(secret.Data["port"])
	dbname := string(secret.Data["dbname"])
	username := string(secret.Data["username"])
	password := string(secret.Data["password"])

	if port == "" {
		port = "5432"
	}
	if dbname == "" {
		dbname = "app"
	}

	fqdn := fmt.Sprintf("%s.%s.svc.cluster.local", host, namespace)

	return map[string]interface{}{
		"type":       "postgres-ai",
		"hostname":   fqdn,
		"port":       port,
		"name":       dbname,
		"database":   dbname,
		"username":   username,
		"password":   password,
		"host":       fqdn,
		"uri":        fmt.Sprintf("postgresql://%s:%s@%s:%s/%s", username, password, fqdn, port, dbname),
		"jdbcUrl":    fmt.Sprintf("jdbc:postgresql://%s:%s/%s?user=%s&password=%s", fqdn, port, dbname, username, password),
		"extensions": []string{"vector", "vectorscale", "pg_trgm", "fuzzystrmatch", "pgcrypto", "uuid-ossp", "postgis", "unaccent", "pg_stat_statements"},
	}, nil
}
