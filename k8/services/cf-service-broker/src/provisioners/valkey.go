package provisioners

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"

	k8sclient "github.com/cfapps/cf-service-broker/k8s"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
)

type Valkey struct {
	Image string
}

func (v *Valkey) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string) error {
	password := generatePassword()
	resName := "valkey-" + name
	host := fmt.Sprintf("%s.%s.svc.cluster.local", resName, namespace)

	// Create credentials secret
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      resName + "-credentials",
			Namespace: namespace,
			Labels: map[string]string{
				"cf-service-broker/instance-id": name,
				"cf-service-broker/service":     "valkey",
			},
		},
		StringData: map[string]string{
			"password": password,
			"host":     host,
			"port":     "6379",
			"uri":      fmt.Sprintf("redis://:%s@%s:6379", password, host),
		},
	}
	if _, err := client.Typed.CoreV1().Secrets(namespace).Create(ctx, secret, metav1.CreateOptions{}); err != nil {
		return err
	}

	// Create Service
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      resName,
			Namespace: namespace,
			Labels: map[string]string{
				"cf-service-broker/instance-id": name,
				"cf-service-broker/service":     "valkey",
			},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": resName},
			Ports: []corev1.ServicePort{
				{Port: 6379, TargetPort: intstr.FromInt32(6379)},
			},
		},
	}
	if _, err := client.Typed.CoreV1().Services(namespace).Create(ctx, svc, metav1.CreateOptions{}); err != nil {
		return err
	}

	// Create StatefulSet
	replicas := int32(1)
	ss := &appsv1.StatefulSet{
		ObjectMeta: metav1.ObjectMeta{
			Name:      resName,
			Namespace: namespace,
			Labels: map[string]string{
				"cf-service-broker/instance-id": name,
				"cf-service-broker/service":     "valkey",
			},
		},
		Spec: appsv1.StatefulSetSpec{
			Replicas:    &replicas,
			ServiceName: resName,
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": resName},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": resName},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  "valkey",
							Image: v.Image,
							Args:  []string{"--requirepass", "$(VALKEY_PASSWORD)"},
							Ports: []corev1.ContainerPort{{ContainerPort: 6379}},
							Env: []corev1.EnvVar{
								{
									Name: "VALKEY_PASSWORD",
									ValueFrom: &corev1.EnvVarSource{
										SecretKeyRef: &corev1.SecretKeySelector{
											LocalObjectReference: corev1.LocalObjectReference{Name: resName + "-credentials"},
											Key:                  "password",
										},
									},
								},
							},
							Resources: corev1.ResourceRequirements{
								Requests: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse("100m"),
									corev1.ResourceMemory: resource.MustParse("128Mi"),
								},
								Limits: corev1.ResourceList{
									corev1.ResourceMemory: resource.MustParse("256Mi"),
								},
							},
							VolumeMounts: []corev1.VolumeMount{
								{Name: "data", MountPath: "/data"},
							},
						},
					},
				},
			},
			VolumeClaimTemplates: []corev1.PersistentVolumeClaim{
				{
					ObjectMeta: metav1.ObjectMeta{Name: "data"},
					Spec: corev1.PersistentVolumeClaimSpec{
						AccessModes:      []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
						StorageClassName: strPtr("local-path"),
						Resources: corev1.VolumeResourceRequirements{
							Requests: corev1.ResourceList{
								corev1.ResourceStorage: resource.MustParse("1Gi"),
							},
						},
					},
				},
			},
		},
	}
	_, err := client.Typed.AppsV1().StatefulSets(namespace).Create(ctx, ss, metav1.CreateOptions{})
	return err
}

func (v *Valkey) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	resName := "valkey-" + name

	// Delete StatefulSet
	_ = client.Typed.AppsV1().StatefulSets(namespace).Delete(ctx, resName, metav1.DeleteOptions{})
	// Delete Service
	_ = client.Typed.CoreV1().Services(namespace).Delete(ctx, resName, metav1.DeleteOptions{})
	// Delete Secret
	_ = client.Typed.CoreV1().Secrets(namespace).Delete(ctx, resName+"-credentials", metav1.DeleteOptions{})
	// Delete PVC (StatefulSet doesn't auto-delete PVCs)
	_ = client.Typed.CoreV1().PersistentVolumeClaims(namespace).Delete(ctx, "data-"+resName+"-0", metav1.DeleteOptions{})

	return nil
}

func (v *Valkey) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	resName := "valkey-" + name
	ss, err := client.Typed.AppsV1().StatefulSets(namespace).Get(ctx, resName, metav1.GetOptions{})
	if err != nil {
		return false, "not found", err
	}

	if ss.Status.ReadyReplicas >= 1 {
		return true, "succeeded", nil
	}
	return false, "provisioning", nil
}

func (v *Valkey) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	resName := "valkey-" + name
	secret, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, resName+"-credentials", metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("credentials secret not found: %w", err)
	}

	return map[string]interface{}{
		"type":     "redis",
		"hostname": string(secret.Data["host"]),
		"host":     string(secret.Data["host"]),
		"port":     6379,
		"password": string(secret.Data["password"]),
		"uri":      string(secret.Data["uri"]),
	}, nil
}

func generatePassword() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func strPtr(s string) *string {
	return &s
}

