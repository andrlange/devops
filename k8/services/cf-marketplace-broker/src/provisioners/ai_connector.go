package provisioners

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"

	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type AIEndpoint struct {
	Name     string `json:"name"`
	Provider string `json:"provider"`
	Host     string `json:"host"`
	Port     int    `json:"port"`
	APIKey   string `json:"api_key,omitempty"`
}

type AIConnector struct{}

func (a *AIConnector) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string, params map[string]interface{}) error {
	endpoints, err := parseEndpoints(params)
	if err != nil {
		return fmt.Errorf("invalid parameters: %w", err)
	}

	if len(endpoints) == 0 {
		return fmt.Errorf("at least one endpoint is required")
	}

	// Validate connectivity (best-effort, log warnings but don't fail)
	for _, ep := range endpoints {
		baseURL := fmt.Sprintf("http://%s:%d/v1/models", ep.Host, ep.Port)
		if err := checkEndpoint(baseURL, ep.APIKey); err != nil {
			log.Printf("Warning: endpoint %s (%s:%d) not reachable: %v", ep.Name, ep.Host, ep.Port, err)
		}
	}

	// Store endpoint config in K8s Secret
	epData, _ := json.Marshal(endpoints)
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "ai-" + name,
			Namespace: namespace,
			Labels: map[string]string{
				"cf-marketplace-broker/instance-id": name,
				"cf-marketplace-broker/service":     "ai-connector",
			},
		},
		StringData: map[string]string{
			"endpoints": string(epData),
		},
	}

	_, err = client.Typed.CoreV1().Secrets(namespace).Create(ctx, secret, metav1.CreateOptions{})
	return err
}

func (a *AIConnector) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	err := client.Typed.CoreV1().Secrets(namespace).Delete(ctx, "ai-"+name, metav1.DeleteOptions{})
	if errors.IsNotFound(err) {
		return nil
	}
	return err
}

func (a *AIConnector) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	_, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, "ai-"+name, metav1.GetOptions{})
	if err != nil {
		return false, "provisioning", nil
	}
	return true, "succeeded", nil
}

func (a *AIConnector) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	secret, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, "ai-"+name, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("credentials secret ai-%s not found: %w", name, err)
	}

	var endpoints []AIEndpoint
	if err := json.Unmarshal(secret.Data["endpoints"], &endpoints); err != nil {
		return nil, fmt.Errorf("failed to parse endpoints: %w", err)
	}

	if len(endpoints) == 1 {
		ep := endpoints[0]
		baseURL := fmt.Sprintf("http://%s:%d/v1", ep.Host, ep.Port)
		return map[string]interface{}{
			"type":       "ai-connector",
			"base_url":   baseURL,
			"provider":   ep.Provider,
			"api_key":    ep.APIKey,
			"models_url": baseURL + "/models",
		}, nil
	}

	epList := make([]map[string]interface{}, len(endpoints))
	for i, ep := range endpoints {
		baseURL := fmt.Sprintf("http://%s:%d/v1", ep.Host, ep.Port)
		epList[i] = map[string]interface{}{
			"name":       ep.Name,
			"base_url":   baseURL,
			"provider":   ep.Provider,
			"api_key":    ep.APIKey,
			"models_url": baseURL + "/models",
		}
	}

	return map[string]interface{}{
		"type":      "ai-connector",
		"endpoints": epList,
	}, nil
}

// parseEndpoints handles both single-endpoint shortform and multi-endpoint format
func parseEndpoints(params map[string]interface{}) ([]AIEndpoint, error) {
	if params == nil {
		return nil, fmt.Errorf("parameters required")
	}

	// Multi-endpoint format: {"endpoints": [...]}
	if raw, ok := params["endpoints"]; ok {
		data, err := json.Marshal(raw)
		if err != nil {
			return nil, err
		}
		var endpoints []AIEndpoint
		if err := json.Unmarshal(data, &endpoints); err != nil {
			return nil, err
		}
		// Set defaults
		for i := range endpoints {
			if endpoints[i].Name == "" {
				endpoints[i].Name = fmt.Sprintf("%s-%d", endpoints[i].Provider, i)
			}
			if endpoints[i].Port == 0 {
				endpoints[i].Port = defaultPort(endpoints[i].Provider)
			}
		}
		return endpoints, nil
	}

	// Single-endpoint shortform: {"provider": "ollama", "host": "...", "port": ...}
	provider, _ := params["provider"].(string)
	host, _ := params["host"].(string)
	if provider == "" || host == "" {
		return nil, fmt.Errorf("provider and host are required")
	}

	port := defaultPort(provider)
	if p, ok := params["port"]; ok {
		switch v := p.(type) {
		case float64:
			port = int(v)
		case string:
			if parsed, err := strconv.Atoi(v); err == nil {
				port = parsed
			}
		}
	}

	apiKey, _ := params["api_key"].(string)
	name, _ := params["name"].(string)
	if name == "" {
		name = provider + "-0"
	}

	return []AIEndpoint{{
		Name:     name,
		Provider: provider,
		Host:     host,
		Port:     port,
		APIKey:   apiKey,
	}}, nil
}

func defaultPort(provider string) int {
	switch provider {
	case "ollama":
		return 11434
	case "lmstudio":
		return 1234
	default:
		return 8080
	}
}

func checkEndpoint(url, apiKey string) error {
	client := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return err
	}
	if apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}
