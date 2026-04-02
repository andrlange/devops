package test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"testing"
	"time"
)

const (
	openbaoServiceID   = "b1a2c3d4-e5f6-7890-abcd-200000000002"
	openbaoDefaultPlan = "c2d3e4f5-a1b2-7890-abcd-200000000021"
)

func TestOpenBaoSecretsLifecycle(t *testing.T) {
	instanceID := "test-bao-01"
	bindingID := "bind-bao-01"

	status, err := osb.Provision(instanceID, ProvisionRequest{
		ServiceID:        openbaoServiceID,
		PlanID:           openbaoDefaultPlan,
		OrganizationGUID: "test-org",
		SpaceGUID:        "test-space",
	})
	if err != nil {
		t.Fatalf("Provision failed: %v", err)
	}
	if status != 202 {
		t.Fatalf("Expected 202, got %d", status)
	}

	if err := osb.WaitForReady(instanceID, 30*time.Second); err != nil {
		t.Fatalf("WaitForReady failed: %v", err)
	}

	bindResp, status, err := osb.Bind(instanceID, bindingID, BindRequest{
		ServiceID: openbaoServiceID,
		PlanID:    openbaoDefaultPlan,
	})
	if err != nil {
		t.Fatalf("Bind failed: %v", err)
	}
	if status != 200 && status != 201 {
		t.Fatalf("Bind expected 200/201, got %d", status)
	}

	creds := bindResp.Credentials
	t.Logf("Credentials: type=%v, vault_addr=%v, secret_path=%v", creds["type"], creds["vault_addr"], creds["secret_path"])

	if creds["type"] != "openbao-secrets" {
		t.Errorf("Expected type openbao-secrets, got %v", creds["type"])
	}

	vaultAddr, _ := creds["vault_addr"].(string)
	roleID, _ := creds["role_id"].(string)
	secretID, _ := creds["secret_id"].(string)
	secretPath, _ := creds["secret_path"].(string)

	if roleID == "" || secretID == "" {
		t.Fatalf("Missing role_id or secret_id")
	}

	// AppRole login
	loginBody, _ := json.Marshal(map[string]string{
		"role_id":   roleID,
		"secret_id": secretID,
	})
	loginResp, err := http.Post(vaultAddr+"/v1/auth/approle/login", "application/json", bytes.NewReader(loginBody))
	if err != nil {
		t.Fatalf("AppRole login failed: %v", err)
	}
	defer loginResp.Body.Close()

	var loginResult map[string]interface{}
	json.NewDecoder(loginResp.Body).Decode(&loginResult)
	auth, _ := loginResult["auth"].(map[string]interface{})
	clientToken, _ := auth["client_token"].(string)
	if clientToken == "" {
		t.Fatalf("Failed to get client token from AppRole login")
	}
	t.Log("AppRole login succeeded")

	// Write a secret
	testSecret := map[string]interface{}{
		"data": map[string]interface{}{"value": "hello-from-test"},
	}
	secretData, _ := json.Marshal(testSecret)
	writeReq, _ := http.NewRequest("PUT", vaultAddr+"/v1/"+secretPath+"/test-key", bytes.NewReader(secretData))
	writeReq.Header.Set("X-Vault-Token", clientToken)
	writeReq.Header.Set("Content-Type", "application/json")
	writeResp, err := http.DefaultClient.Do(writeReq)
	if err != nil {
		t.Fatalf("Write secret failed: %v", err)
	}
	writeResp.Body.Close()
	if writeResp.StatusCode >= 400 {
		t.Fatalf("Write secret returned %d", writeResp.StatusCode)
	}
	t.Log("Secret written successfully")

	// Read the secret
	readReq, _ := http.NewRequest("GET", vaultAddr+"/v1/"+secretPath+"/test-key", nil)
	readReq.Header.Set("X-Vault-Token", clientToken)
	readResp, err := http.DefaultClient.Do(readReq)
	if err != nil {
		t.Fatalf("Read secret failed: %v", err)
	}
	defer readResp.Body.Close()
	readBody, _ := io.ReadAll(readResp.Body)

	var readResult map[string]interface{}
	json.Unmarshal(readBody, &readResult)
	data, _ := readResult["data"].(map[string]interface{})
	innerData, _ := data["data"].(map[string]interface{})
	if innerData["value"] != "hello-from-test" {
		t.Errorf("Expected 'hello-from-test', got %v", innerData["value"])
	}
	t.Log("Secret read and verified")

	// Delete test secret
	delReq, _ := http.NewRequest("DELETE", vaultAddr+"/v1/"+secretPath+"/test-key", nil)
	delReq.Header.Set("X-Vault-Token", clientToken)
	http.DefaultClient.Do(delReq)

	status, err = osb.Unbind(instanceID, bindingID, openbaoServiceID, openbaoDefaultPlan)
	if err != nil {
		t.Fatalf("Unbind failed: %v", err)
	}

	status, err = osb.Deprovision(instanceID, openbaoServiceID, openbaoDefaultPlan)
	if err != nil {
		t.Fatalf("Deprovision failed: %v", err)
	}

	if err := osb.WaitForGone(instanceID, 30*time.Second); err != nil {
		t.Logf("Warning: WaitForGone: %v", err)
	}

	fmt.Println("OpenBao Secrets lifecycle test passed")
}
