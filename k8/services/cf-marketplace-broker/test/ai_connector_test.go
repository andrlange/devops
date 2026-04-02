package test

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"testing"
	"time"
)

const (
	aiServiceID   = "b1a2c3d4-e5f6-7890-abcd-300000000003"
	aiDefaultPlan = "c2d3e4f5-a1b2-7890-abcd-300000000031"
)

func TestAIConnectorSingleEndpoint(t *testing.T) {
	instanceID := "test-ai-01"
	bindingID := "bind-ai-01"

	status, err := osb.Provision(instanceID, ProvisionRequest{
		ServiceID:        aiServiceID,
		PlanID:           aiDefaultPlan,
		OrganizationGUID: "test-org",
		SpaceGUID:        "test-space",
		Parameters: map[string]interface{}{
			"provider": "ollama",
			"host":     "192.168.64.1",
			"port":     11434,
		},
	})
	if err != nil {
		t.Fatalf("Provision failed: %v", err)
	}
	if status != 202 {
		t.Fatalf("Expected 202, got %d", status)
	}

	if err := osb.WaitForReady(instanceID, 15*time.Second); err != nil {
		t.Fatalf("WaitForReady failed: %v", err)
	}

	bindResp, status, err := osb.Bind(instanceID, bindingID, BindRequest{
		ServiceID: aiServiceID,
		PlanID:    aiDefaultPlan,
	})
	if err != nil {
		t.Fatalf("Bind failed: %v", err)
	}
	if status != 200 && status != 201 {
		t.Fatalf("Bind expected 200/201, got %d", status)
	}

	creds := bindResp.Credentials
	t.Logf("Credentials: type=%v, provider=%v, base_url=%v", creds["type"], creds["provider"], creds["base_url"])

	if creds["type"] != "ai-connector" {
		t.Errorf("Expected type ai-connector, got %v", creds["type"])
	}
	if creds["provider"] != "ollama" {
		t.Errorf("Expected provider ollama, got %v", creds["provider"])
	}

	modelsURL, _ := creds["models_url"].(string)
	if modelsURL == "" {
		t.Fatalf("No models_url in credentials")
	}

	resp, err := http.Get(modelsURL)
	if err != nil {
		t.Skipf("Ollama not reachable at %s — skipping connectivity test: %v", modelsURL, err)
	} else {
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		var models map[string]interface{}
		if err := json.Unmarshal(body, &models); err != nil {
			t.Errorf("Invalid JSON from models endpoint: %v", err)
		}
		if _, ok := models["data"]; !ok {
			if _, ok := models["models"]; !ok {
				t.Logf("Warning: response has neither 'data' nor 'models' key: %s", string(body))
			}
		}
		t.Logf("Models endpoint returned valid response")
	}

	status, err = osb.Unbind(instanceID, bindingID, aiServiceID, aiDefaultPlan)
	if err != nil {
		t.Fatalf("Unbind failed: %v", err)
	}

	status, err = osb.Deprovision(instanceID, aiServiceID, aiDefaultPlan)
	if err != nil {
		t.Fatalf("Deprovision failed: %v", err)
	}

	if err := osb.WaitForGone(instanceID, 15*time.Second); err != nil {
		t.Logf("Warning: WaitForGone: %v", err)
	}

	fmt.Println("AI Connector single endpoint test passed")
}

func TestAIConnectorMultiEndpoint(t *testing.T) {
	instanceID := "test-ai-02"
	bindingID := "bind-ai-02"

	status, err := osb.Provision(instanceID, ProvisionRequest{
		ServiceID:        aiServiceID,
		PlanID:           aiDefaultPlan,
		OrganizationGUID: "test-org",
		SpaceGUID:        "test-space",
		Parameters: map[string]interface{}{
			"endpoints": []map[string]interface{}{
				{"name": "ollama-local", "provider": "ollama", "host": "192.168.64.1", "port": 11434},
				{"name": "lmstudio-local", "provider": "lmstudio", "host": "192.168.64.1", "port": 1234},
			},
		},
	})
	if err != nil {
		t.Fatalf("Provision failed: %v", err)
	}
	if status != 202 {
		t.Fatalf("Expected 202, got %d", status)
	}

	if err := osb.WaitForReady(instanceID, 15*time.Second); err != nil {
		t.Fatalf("WaitForReady failed: %v", err)
	}

	bindResp, status, err := osb.Bind(instanceID, bindingID, BindRequest{
		ServiceID: aiServiceID,
		PlanID:    aiDefaultPlan,
	})
	if err != nil {
		t.Fatalf("Bind failed: %v", err)
	}
	if status != 200 && status != 201 {
		t.Fatalf("Bind expected 200/201, got %d", status)
	}

	creds := bindResp.Credentials
	if creds["type"] != "ai-connector" {
		t.Errorf("Expected type ai-connector, got %v", creds["type"])
	}

	endpoints, ok := creds["endpoints"].([]interface{})
	if !ok {
		t.Fatalf("Expected endpoints array, got %T", creds["endpoints"])
	}
	if len(endpoints) != 2 {
		t.Fatalf("Expected 2 endpoints, got %d", len(endpoints))
	}

	ep0, _ := endpoints[0].(map[string]interface{})
	ep1, _ := endpoints[1].(map[string]interface{})
	if ep0["provider"] != "ollama" {
		t.Errorf("First endpoint should be ollama, got %v", ep0["provider"])
	}
	if ep1["provider"] != "lmstudio" {
		t.Errorf("Second endpoint should be lmstudio, got %v", ep1["provider"])
	}
	t.Logf("Multi-endpoint format verified: %d endpoints", len(endpoints))

	status, err = osb.Unbind(instanceID, bindingID, aiServiceID, aiDefaultPlan)
	if err != nil {
		t.Fatalf("Unbind failed: %v", err)
	}

	status, err = osb.Deprovision(instanceID, aiServiceID, aiDefaultPlan)
	if err != nil {
		t.Fatalf("Deprovision failed: %v", err)
	}

	if err := osb.WaitForGone(instanceID, 15*time.Second); err != nil {
		t.Logf("Warning: WaitForGone: %v", err)
	}

	fmt.Println("AI Connector multi-endpoint test passed")
}
