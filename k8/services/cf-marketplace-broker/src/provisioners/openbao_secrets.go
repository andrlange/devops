package provisioners

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
)

type OpenBaoSecrets struct {
	Addr  string
	Token string
}

func (o *OpenBaoSecrets) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string, params map[string]interface{}) error {
	instancePath := "instance-" + name

	// 1. Ensure KV v2 engine is mounted (idempotent — ignore "already mounted" errors)
	o.vaultRequest(ctx, "POST", "/v1/sys/mounts/cf-secrets", map[string]interface{}{
		"type": "kv",
		"options": map[string]interface{}{
			"version": "2",
		},
	})

	// 2. Create policy granting read/write on instance path
	policyName := "cf-secrets-" + name
	policyHCL := fmt.Sprintf(`
path "cf-secrets/data/%s/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "cf-secrets/metadata/%s/*" {
  capabilities = ["list", "read", "delete"]
}
`, instancePath, instancePath)

	if err := o.vaultRequest(ctx, "PUT", "/v1/sys/policies/acl/"+policyName, map[string]interface{}{
		"policy": policyHCL,
	}); err != nil {
		return fmt.Errorf("failed to create policy: %w", err)
	}

	// 3. Enable AppRole auth if not already enabled (idempotent)
	o.vaultRequest(ctx, "POST", "/v1/sys/auth/approle", map[string]interface{}{
		"type": "approle",
	})

	// 4. Create AppRole for this instance
	roleName := "cf-secrets-" + name
	if err := o.vaultRequest(ctx, "POST", "/v1/auth/approle/role/"+roleName, map[string]interface{}{
		"token_policies": []string{policyName},
		"token_ttl":      "24h",
		"token_max_ttl":  "48h",
	}); err != nil {
		return fmt.Errorf("failed to create approle: %w", err)
	}

	return nil
}

func (o *OpenBaoSecrets) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	roleName := "cf-secrets-" + name
	policyName := "cf-secrets-" + name
	instancePath := "instance-" + name

	// Delete AppRole
	o.vaultRequest(ctx, "DELETE", "/v1/auth/approle/role/"+roleName, nil)

	// Delete policy
	o.vaultRequest(ctx, "DELETE", "/v1/sys/policies/acl/"+policyName, nil)

	// Delete all secrets under instance path (metadata delete cascades data)
	o.vaultRequest(ctx, "DELETE", "/v1/cf-secrets/metadata/"+instancePath, nil)

	return nil
}

func (o *OpenBaoSecrets) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	roleName := "cf-secrets-" + name
	resp, err := o.vaultGet(ctx, "/v1/auth/approle/role/"+roleName)
	if err != nil {
		return false, "provisioning", nil
	}
	if resp != nil {
		return true, "succeeded", nil
	}
	return false, "provisioning", nil
}

func (o *OpenBaoSecrets) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	roleName := "cf-secrets-" + name
	instancePath := "instance-" + name

	// Get role_id
	roleIDResp, err := o.vaultGet(ctx, "/v1/auth/approle/role/"+roleName+"/role-id")
	if err != nil {
		return nil, fmt.Errorf("failed to get role_id: %w", err)
	}
	data, ok := roleIDResp["data"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("unexpected role_id response format")
	}
	roleID, _ := data["role_id"].(string)

	// Generate secret_id
	secretIDResp, err := o.vaultPost(ctx, "/v1/auth/approle/role/"+roleName+"/secret-id", nil)
	if err != nil {
		return nil, fmt.Errorf("failed to generate secret_id: %w", err)
	}
	data, ok = secretIDResp["data"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("unexpected secret_id response format")
	}
	secretID, _ := data["secret_id"].(string)

	return map[string]interface{}{
		"type":        "openbao-secrets",
		"vault_addr":  o.Addr,
		"role_id":     roleID,
		"secret_id":   secretID,
		"secret_path": "cf-secrets/data/" + instancePath,
		"auth_mount":  "approle",
	}, nil
}

// --- OpenBao HTTP helpers ---

func (o *OpenBaoSecrets) vaultRequest(ctx context.Context, method, path string, body map[string]interface{}) error {
	var bodyReader io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		bodyReader = bytes.NewReader(data)
	}

	req, err := http.NewRequestWithContext(ctx, method, o.Addr+path, bodyReader)
	if err != nil {
		return err
	}
	req.Header.Set("X-Vault-Token", o.Token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 && resp.StatusCode != 400 {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("vault %s %s returned %d: %s", method, path, resp.StatusCode, string(respBody))
	}
	return nil
}

func (o *OpenBaoSecrets) vaultGet(ctx context.Context, path string) (map[string]interface{}, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", o.Addr+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Vault-Token", o.Token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("vault GET %s returned %d", path, resp.StatusCode)
	}

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result, nil
}

func (o *OpenBaoSecrets) vaultPost(ctx context.Context, path string, body map[string]interface{}) (map[string]interface{}, error) {
	var bodyReader io.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		bodyReader = bytes.NewReader(data)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", o.Addr+path, bodyReader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-Vault-Token", o.Token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("vault POST %s returned %d", path, resp.StatusCode)
	}

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result, nil
}
