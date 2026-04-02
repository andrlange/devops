package broker

import (
	"context"
	"encoding/json"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const configMapName = "broker-marketplace-instances"

type InstanceState struct {
	ServiceID string                 `json:"service_id"`
	PlanID    string                 `json:"plan_id"`
	Name      string                 `json:"name"`
	Namespace string                 `json:"namespace"`
	Params    map[string]interface{} `json:"params,omitempty"`
}

func saveInstance(ctx context.Context, client kubernetes.Interface, ns, instanceID string, state InstanceState) error {
	cm, err := getOrCreateConfigMap(ctx, client, ns)
	if err != nil {
		return err
	}

	data, err := json.Marshal(state)
	if err != nil {
		return err
	}

	if cm.Data == nil {
		cm.Data = make(map[string]string)
	}
	cm.Data[instanceID] = string(data)

	_, err = client.CoreV1().ConfigMaps(ns).Update(ctx, cm, metav1.UpdateOptions{})
	return err
}

func getInstance(ctx context.Context, client kubernetes.Interface, ns, instanceID string) (*InstanceState, error) {
	cm, err := client.CoreV1().ConfigMaps(ns).Get(ctx, configMapName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("instance %s not found", instanceID)
	}

	raw, ok := cm.Data[instanceID]
	if !ok {
		return nil, fmt.Errorf("instance %s not found", instanceID)
	}

	var state InstanceState
	if err := json.Unmarshal([]byte(raw), &state); err != nil {
		return nil, err
	}
	return &state, nil
}

func deleteInstance(ctx context.Context, client kubernetes.Interface, ns, instanceID string) error {
	cm, err := client.CoreV1().ConfigMaps(ns).Get(ctx, configMapName, metav1.GetOptions{})
	if err != nil {
		return nil
	}

	delete(cm.Data, instanceID)
	_, err = client.CoreV1().ConfigMaps(ns).Update(ctx, cm, metav1.UpdateOptions{})
	return err
}

func getOrCreateConfigMap(ctx context.Context, client kubernetes.Interface, ns string) (*corev1.ConfigMap, error) {
	cm, err := client.CoreV1().ConfigMaps(ns).Get(ctx, configMapName, metav1.GetOptions{})
	if err == nil {
		return cm, nil
	}
	if !errors.IsNotFound(err) {
		return nil, err
	}

	cm = &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      configMapName,
			Namespace: ns,
		},
		Data: make(map[string]string),
	}
	return client.CoreV1().ConfigMaps(ns).Create(ctx, cm, metav1.CreateOptions{})
}
