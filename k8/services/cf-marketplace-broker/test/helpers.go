package test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

type OSBClient struct {
	BaseURL  string
	Username string
	Password string
	Client   *http.Client
}

func NewOSBClient(baseURL, username, password string) *OSBClient {
	return &OSBClient{
		BaseURL:  baseURL,
		Username: username,
		Password: password,
		Client:   &http.Client{Timeout: 30 * time.Second},
	}
}

type ProvisionRequest struct {
	ServiceID        string                 `json:"service_id"`
	PlanID           string                 `json:"plan_id"`
	OrganizationGUID string                 `json:"organization_guid"`
	SpaceGUID        string                 `json:"space_guid"`
	Parameters       map[string]interface{} `json:"parameters,omitempty"`
}

type BindRequest struct {
	ServiceID string `json:"service_id"`
	PlanID    string `json:"plan_id"`
}

type LastOperationResponse struct {
	State       string `json:"state"`
	Description string `json:"description"`
}

type BindResponse struct {
	Credentials map[string]interface{} `json:"credentials"`
}

func (c *OSBClient) Provision(instanceID string, req ProvisionRequest) (int, error) {
	body, _ := json.Marshal(req)
	r, err := http.NewRequest("PUT",
		fmt.Sprintf("%s/v2/service_instances/%s?accepts_incomplete=true", c.BaseURL, instanceID),
		bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	r.SetBasicAuth(c.Username, c.Password)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Broker-API-Version", "2.17")

	resp, err := c.Client.Do(r)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	return resp.StatusCode, nil
}

func (c *OSBClient) PollLastOperation(instanceID string) (*LastOperationResponse, int, error) {
	r, err := http.NewRequest("GET",
		fmt.Sprintf("%s/v2/service_instances/%s/last_operation", c.BaseURL, instanceID), nil)
	if err != nil {
		return nil, 0, err
	}
	r.SetBasicAuth(c.Username, c.Password)
	r.Header.Set("X-Broker-API-Version", "2.17")

	resp, err := c.Client.Do(r)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	var result LastOperationResponse
	body, _ := io.ReadAll(resp.Body)
	json.Unmarshal(body, &result)
	return &result, resp.StatusCode, nil
}

func (c *OSBClient) WaitForReady(instanceID string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		op, status, err := c.PollLastOperation(instanceID)
		if err != nil {
			return err
		}
		if status == 410 {
			return fmt.Errorf("instance gone (410)")
		}
		if op.State == "succeeded" {
			return nil
		}
		if op.State == "failed" {
			return fmt.Errorf("provisioning failed: %s", op.Description)
		}
		time.Sleep(3 * time.Second)
	}
	return fmt.Errorf("timeout waiting for instance %s", instanceID)
}

func (c *OSBClient) Bind(instanceID, bindingID string, req BindRequest) (*BindResponse, int, error) {
	body, _ := json.Marshal(req)
	r, err := http.NewRequest("PUT",
		fmt.Sprintf("%s/v2/service_instances/%s/service_bindings/%s", c.BaseURL, instanceID, bindingID),
		bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	r.SetBasicAuth(c.Username, c.Password)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Broker-API-Version", "2.17")

	resp, err := c.Client.Do(r)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	var result BindResponse
	respBody, _ := io.ReadAll(resp.Body)
	json.Unmarshal(respBody, &result)
	return &result, resp.StatusCode, nil
}

func (c *OSBClient) Unbind(instanceID, bindingID, serviceID, planID string) (int, error) {
	r, err := http.NewRequest("DELETE",
		fmt.Sprintf("%s/v2/service_instances/%s/service_bindings/%s?service_id=%s&plan_id=%s",
			c.BaseURL, instanceID, bindingID, serviceID, planID), nil)
	if err != nil {
		return 0, err
	}
	r.SetBasicAuth(c.Username, c.Password)
	r.Header.Set("X-Broker-API-Version", "2.17")

	resp, err := c.Client.Do(r)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	return resp.StatusCode, nil
}

func (c *OSBClient) Deprovision(instanceID, serviceID, planID string) (int, error) {
	r, err := http.NewRequest("DELETE",
		fmt.Sprintf("%s/v2/service_instances/%s?accepts_incomplete=true&service_id=%s&plan_id=%s",
			c.BaseURL, instanceID, serviceID, planID), nil)
	if err != nil {
		return 0, err
	}
	r.SetBasicAuth(c.Username, c.Password)
	r.Header.Set("X-Broker-API-Version", "2.17")

	resp, err := c.Client.Do(r)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	return resp.StatusCode, nil
}

func (c *OSBClient) WaitForGone(instanceID string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		_, status, err := c.PollLastOperation(instanceID)
		if err != nil {
			return err
		}
		if status == 410 {
			return nil
		}
		time.Sleep(3 * time.Second)
	}
	return fmt.Errorf("timeout waiting for instance %s to be gone", instanceID)
}
