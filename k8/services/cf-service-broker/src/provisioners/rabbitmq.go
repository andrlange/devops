package provisioners

import (
	"context"
	"fmt"

	k8sclient "github.com/cfapps/cf-service-broker/k8s"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

var rmqGVR = schema.GroupVersionResource{
	Group:    "rabbitmq.com",
	Version:  "v1beta1",
	Resource: "rabbitmqclusters",
}

type RabbitMQ struct{}

func (r *RabbitMQ) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string) error {
	cluster := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "rabbitmq.com/v1beta1",
			"kind":       "RabbitmqCluster",
			"metadata": map[string]interface{}{
				"name":      "rmq-" + name,
				"namespace": namespace,
				"labels": map[string]interface{}{
					"cf-service-broker/instance-id": name,
					"cf-service-broker/service":     "rabbitmq",
				},
			},
			"spec": map[string]interface{}{
				"replicas": int64(1),
				"resources": map[string]interface{}{
					"requests": map[string]interface{}{
						"cpu":    "100m",
						"memory": "256Mi",
					},
					"limits": map[string]interface{}{
						"memory": "512Mi",
					},
				},
				"persistence": map[string]interface{}{
					"storageClassName": "local-path",
					"storage":          "1Gi",
				},
				"rabbitmq": map[string]interface{}{
					"additionalConfig": "default_user_tags.administrator = true\n",
				},
			},
		},
	}

	_, err := client.Dynamic.Resource(rmqGVR).Namespace(namespace).Create(ctx, cluster, metav1.CreateOptions{})
	return err
}

func (r *RabbitMQ) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	return client.Dynamic.Resource(rmqGVR).Namespace(namespace).Delete(ctx, "rmq-"+name, metav1.DeleteOptions{})
}

func (r *RabbitMQ) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	obj, err := client.Dynamic.Resource(rmqGVR).Namespace(namespace).Get(ctx, "rmq-"+name, metav1.GetOptions{})
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
		if cond["type"] == "AllReplicasReady" && cond["status"] == "True" {
			return true, "succeeded", nil
		}
	}
	return false, "provisioning", nil
}

func (r *RabbitMQ) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	secretName := "rmq-" + name + "-default-user"
	secret, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, secretName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("credentials secret %s not found: %w", secretName, err)
	}

	host := string(secret.Data["host"])
	username := string(secret.Data["username"])
	password := string(secret.Data["password"])
	port := string(secret.Data["port"])

	if port == "" {
		port = "5672"
	}

	// Use FQDN for cross-namespace access from CF app pods
	fqdn := fmt.Sprintf("%s.%s.svc.cluster.local", host, namespace)

	return map[string]interface{}{
		"type":         "rabbitmq",
		"hostname":     fqdn,
		"host":         fqdn,
		"port":         port,
		"username":     username,
		"password":     password,
		"uri":          fmt.Sprintf("amqp://%s:%s@%s:%s", username, password, fqdn, port),
		"http_api_uri": fmt.Sprintf("http://%s:%s@%s:15672/api", username, password, fqdn),
		"vhost":        "/",
	}, nil
}
