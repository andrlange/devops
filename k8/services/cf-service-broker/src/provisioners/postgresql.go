package provisioners

import (
	"context"
	"fmt"

	k8sclient "github.com/cfapps/cf-service-broker/k8s"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

var cnpgGVR = schema.GroupVersionResource{
	Group:    "postgresql.cnpg.io",
	Version:  "v1",
	Resource: "clusters",
}

type PostgreSQL struct{}

func (p *PostgreSQL) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string) error {
	memory := "256Mi"
	memoryLimit := "512Mi"
	storage := "1Gi"
	cpu := "100m"

	if planID == "a1b2c3d4-1111-1111-1111-000000000002" { // medium
		memory = "512Mi"
		memoryLimit = "1Gi"
		storage = "5Gi"
		cpu = "250m"
	}

	cluster := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "postgresql.cnpg.io/v1",
			"kind":       "Cluster",
			"metadata": map[string]interface{}{
				"name":      "pg-" + name,
				"namespace": namespace,
				"labels": map[string]interface{}{
					"cf-service-broker/instance-id": name,
					"cf-service-broker/service":     "postgresql",
				},
			},
			"spec": map[string]interface{}{
				"instances": int64(1),
				// Pin the PG-server image to the artifactory mirror (-arm64) instead of the CNPG
				// operator's ghcr.io default, so fresh installs pull from one offline-capable source.
				"imageName": "artifactory.cfapps.cool/docker-local/ghcr.io/cloudnative-pg/postgresql:18.1-system-trixie-arm64",
				"imagePullSecrets": []interface{}{
					map[string]interface{}{"name": "artifact-keeper-pull"},
				},
				"postgresql": map[string]interface{}{
					"parameters": map[string]interface{}{
						"max_connections": "100",
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
						"database": "app",
						"owner":    "app",
					},
				},
			},
		},
	}

	_, err := client.Dynamic.Resource(cnpgGVR).Namespace(namespace).Create(ctx, cluster, metav1.CreateOptions{})
	return err
}

func (p *PostgreSQL) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	return client.Dynamic.Resource(cnpgGVR).Namespace(namespace).Delete(ctx, "pg-"+name, metav1.DeleteOptions{})
}

func (p *PostgreSQL) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	obj, err := client.Dynamic.Resource(cnpgGVR).Namespace(namespace).Get(ctx, "pg-"+name, metav1.GetOptions{})
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

func (p *PostgreSQL) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	secretName := "pg-" + name + "-app"
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

	// Use FQDN for cross-namespace access from CF app pods
	fqdn := fmt.Sprintf("%s.%s.svc.cluster.local", host, namespace)

	return map[string]interface{}{
		"type":     "postgresql",
		"hostname": fqdn,
		"port":     port,
		"name":     dbname,
		"database": dbname,
		"username": username,
		"password": password,
		"host":     fqdn,
		"uri":      fmt.Sprintf("postgres://%s:%s@%s:%s/%s", username, password, fqdn, port, dbname),
		"jdbcUrl":  fmt.Sprintf("jdbc:postgresql://%s:%s/%s?user=%s&password=%s", fqdn, port, dbname, username, password),
	}, nil
}
