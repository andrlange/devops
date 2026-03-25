# Garage S3 Service Broker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add S3 object storage (via Garage) as a 4th service to the existing OSBAPI Universal Broker, enabling `cf create-service s3 default my-bucket`.

**Architecture:** New `S3` provisioner calls the Garage Admin HTTP API (port 3903) to create buckets and API keys. Credentials are stored in a K8s Secret and returned during bind. The broker constructor gains a `GarageConfig` parameter. Garage ConfigMap gains an `admin_token`.

**Tech Stack:** Go 1.26, Garage Admin API v1, K8s client-go, brokerapi/v11

**Spec:** `k8/docs/superpowers/specs/2026-03-25-garage-s3-service-broker-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `k8/services/cf-service-broker/src/provisioners/s3.go` | Create | S3 provisioner: Garage Admin API client, provision/deprovision/bind logic |
| `k8/services/cf-service-broker/src/provisioners/s3_test.go` | Create | Unit tests for S3 provisioner (HTTP mock for Garage API) |
| `k8/services/cf-service-broker/src/broker/catalog.go` | Modify | Add S3 service ID, plan ID, catalog entry |
| `k8/services/cf-service-broker/src/broker/broker.go` | Modify | Add GarageConfig struct, update New() to register S3 provisioner |
| `k8/services/cf-service-broker/src/main.go` | Modify | Parse GARAGE_* env vars, pass GarageConfig to broker.New() |
| `k8/services/cf-service-broker/deployment.yaml` | Modify | Image tag 1.3.0, add GARAGE_* env vars |
| `k8/services/cf-service-broker/externalsecret-garage.yaml` | Create | ESO ExternalSecret: syncs garage admin token from OpenBao to K8s Secret |
| `k8/platform/garage/configmap.yaml` | Modify | Add admin_token to [admin] section |
| `k8/distribution/install.sh` | Modify | Garage admin token setup, cf enable-service-access s3 |

---

## Task 1: Add S3 to the Service Catalog

**Files:**
- Modify: `k8/services/cf-service-broker/src/broker/catalog.go`

- [ ] **Step 1: Add S3 service and plan constants**

Add after `RabbitMQSmallPlanID` (line 15):

```go
S3ServiceID         = "a4d8f2b1-6e3c-4f7a-8b9d-5c1e3a7f2d4b"
S3DefaultPlanID     = "b5e9a3c2-7f4d-5a8b-9c0e-6d2f4b8a1c5e"
```

- [ ] **Step 2: Add S3 catalog entry**

Add a 4th entry to the `serviceCatalog()` return slice, after the RabbitMQ entry (after line 73):

```go
{
    ID:          S3ServiceID,
    Name:        "s3",
    Description: "S3-compatible object storage powered by Garage",
    Bindable:    true,
    Tags:        []string{"s3", "object-storage", "garage"},
    Plans: []domain.ServicePlan{
        {
            ID:          S3DefaultPlanID,
            Name:        "default",
            Description: "Dedicated S3 bucket with read/write access",
            Free:        domain.FreeValue(true),
        },
    },
    PlanUpdatable: false,
},
```

- [ ] **Step 3: Verify compilation**

Run: `cd k8/services/cf-service-broker/src && go build ./...`
Expected: compiles with no errors

- [ ] **Step 4: Commit**

```bash
git add k8/services/cf-service-broker/src/broker/catalog.go
git commit -m "feat(broker): add S3 service to OSBAPI catalog"
```

---

## Task 2: Implement the S3 Provisioner

**Files:**
- Create: `k8/services/cf-service-broker/src/provisioners/s3.go`
- Create: `k8/services/cf-service-broker/src/provisioners/s3_test.go`

- [ ] **Step 1: Write the test file with Garage Admin API mock**

Create `k8/services/cf-service-broker/src/provisioners/s3_test.go`:

```go
package provisioners

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	k8sclient "github.com/cfapps/cf-service-broker/k8s"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestS3Provision(t *testing.T) {
	// Mock Garage Admin API
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/key", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Error("missing or incorrect bearer token")
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		json.NewEncoder(w).Encode(map[string]interface{}{
			"accessKeyId":     "GK1234567890abcdef",
			"secretAccessKey": "abcdef1234567890abcdef1234567890",
			"name":            "s3-testinst",
		})
	})
	mux.HandleFunc("POST /v1/bucket", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"id":            "bucket-uuid-1234",
			"globalAliases": []string{"s3-testinst"},
		})
	})
	mux.HandleFunc("POST /v1/bucket/allow", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]interface{}
		json.NewDecoder(r.Body).Decode(&body)
		if body["bucketId"] != "bucket-uuid-1234" {
			t.Errorf("unexpected bucketId: %v", body["bucketId"])
		}
		if body["accessKeyId"] != "GK1234567890abcdef" {
			t.Errorf("unexpected accessKeyId: %v", body["accessKeyId"])
		}
		json.NewEncoder(w).Encode(map[string]interface{}{"id": "bucket-uuid-1234"})
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	fakeClient := fake.NewSimpleClientset()
	client := &k8sclient.Client{Typed: fakeClient}

	s3 := &S3{
		AdminURL:   server.URL,
		AdminToken: "test-token",
		S3Endpoint: "http://garage.garage.svc.cluster.local:3900",
	}

	err := s3.Provision(context.Background(), client, "testinst", "cf-services", "any-plan")
	if err != nil {
		t.Fatalf("Provision failed: %v", err)
	}

	// Verify secret was created
	secret, err := fakeClient.CoreV1().Secrets("cf-services").Get(
		context.Background(), "s3-testinst-credentials", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("Secret not found: %v", err)
	}
	if string(secret.Data["access_key_id"]) != "GK1234567890abcdef" {
		t.Errorf("unexpected access_key_id: %s", secret.Data["access_key_id"])
	}
	if string(secret.Data["bucket"]) != "s3-testinst" {
		t.Errorf("unexpected bucket: %s", secret.Data["bucket"])
	}
	if string(secret.Data["bucket_id"]) != "bucket-uuid-1234" {
		t.Errorf("unexpected bucket_id: %s", secret.Data["bucket_id"])
	}
	if secret.Labels["cf-service-broker/service"] != "s3" {
		t.Errorf("unexpected service label: %s", secret.Labels["cf-service-broker/service"])
	}
}

func TestS3GetCredentials(t *testing.T) {
	fakeClient := fake.NewSimpleClientset(&corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "s3-testinst-credentials",
			Namespace: "cf-services",
		},
		Data: map[string][]byte{
			"access_key_id":     []byte("GK1234567890abcdef"),
			"secret_access_key": []byte("secretkey123"),
			"bucket":            []byte("s3-testinst"),
			"bucket_id":         []byte("bucket-uuid-1234"),
			"endpoint":          []byte("http://garage.garage.svc.cluster.local:3900"),
			"region":            []byte("garage"),
		},
	})
	client := &k8sclient.Client{Typed: fakeClient}

	s3 := &S3{S3Endpoint: "http://garage.garage.svc.cluster.local:3900"}

	creds, err := s3.GetCredentials(context.Background(), client, "testinst", "cf-services")
	if err != nil {
		t.Fatalf("GetCredentials failed: %v", err)
	}
	if creds["type"] != "s3" {
		t.Errorf("unexpected type: %v", creds["type"])
	}
	if creds["bucket"] != "s3-testinst" {
		t.Errorf("unexpected bucket: %v", creds["bucket"])
	}
	if creds["path_style"] != true {
		t.Errorf("expected path_style=true")
	}
	if creds["access_key_id"] != "GK1234567890abcdef" {
		t.Errorf("unexpected access_key_id: %v", creds["access_key_id"])
	}
}

func TestS3IsReady(t *testing.T) {
	fakeClient := fake.NewSimpleClientset(&corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "s3-testinst-credentials",
			Namespace: "cf-services",
		},
		Data: map[string][]byte{"bucket": []byte("s3-testinst")},
	})
	client := &k8sclient.Client{Typed: fakeClient}

	s3 := &S3{}

	ready, desc, err := s3.IsReady(context.Background(), client, "testinst", "cf-services")
	if err != nil {
		t.Fatalf("IsReady failed: %v", err)
	}
	if !ready {
		t.Error("expected ready=true")
	}
	if desc != "succeeded" {
		t.Errorf("unexpected desc: %s", desc)
	}
}

func TestS3IsReadyNotFound(t *testing.T) {
	fakeClient := fake.NewSimpleClientset()
	client := &k8sclient.Client{Typed: fakeClient}

	s3 := &S3{}

	ready, desc, _ := s3.IsReady(context.Background(), client, "testinst", "cf-services")
	if ready {
		t.Error("expected ready=false")
	}
	if desc != "provisioning" {
		t.Errorf("unexpected desc: %s", desc)
	}
}

func TestS3Deprovision(t *testing.T) {
	deletedBucket := false
	deletedKey := false

	mux := http.NewServeMux()
	// Mock S3 ListObjectsV2 — return empty bucket
	mux.HandleFunc("GET /s3-testinst", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		w.Write([]byte(`<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><Name>s3-testinst</Name></ListBucketResult>`))
	})
	mux.HandleFunc("DELETE /v1/bucket", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("id") != "bucket-uuid-1234" {
			t.Errorf("unexpected bucket id: %s", r.URL.Query().Get("id"))
		}
		deletedBucket = true
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("DELETE /v1/key", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("id") != "GK1234567890abcdef" {
			t.Errorf("unexpected key id: %s", r.URL.Query().Get("id"))
		}
		deletedKey = true
		w.WriteHeader(http.StatusOK)
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	fakeClient := fake.NewSimpleClientset(&corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "s3-testinst-credentials",
			Namespace: "cf-services",
		},
		Data: map[string][]byte{
			"access_key_id":     []byte("GK1234567890abcdef"),
			"secret_access_key": []byte("secretkey123"),
			"bucket":            []byte("s3-testinst"),
			"bucket_id":         []byte("bucket-uuid-1234"),
		},
	})
	client := &k8sclient.Client{Typed: fakeClient}

	s3 := &S3{
		AdminURL:   server.URL,
		AdminToken: "test-token",
		S3Endpoint: server.URL,
	}

	err := s3.Deprovision(context.Background(), client, "testinst", "cf-services")
	if err != nil {
		t.Fatalf("Deprovision failed: %v", err)
	}
	if !deletedBucket {
		t.Error("bucket was not deleted")
	}
	if !deletedKey {
		t.Error("key was not deleted")
	}

	// Verify secret was deleted
	_, err = fakeClient.CoreV1().Secrets("cf-services").Get(
		context.Background(), "s3-testinst-credentials", metav1.GetOptions{})
	if err == nil {
		t.Error("secret should have been deleted")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd k8/services/cf-service-broker/src && go test ./provisioners/ -v -run TestS3`
Expected: FAIL — `S3` type not defined

- [ ] **Step 3: Write the S3 provisioner implementation**

Create `k8/services/cf-service-broker/src/provisioners/s3.go`:

```go
package provisioners

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"

	k8sclient "github.com/cfapps/cf-service-broker/k8s"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type S3 struct {
	AdminURL   string
	AdminToken string
	S3Endpoint string
}

func (s *S3) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string) error {
	resName := "s3-" + name

	// 1. Create Garage API key
	keyResp, err := s.garageRequest(ctx, "POST", "/v1/key", map[string]interface{}{
		"name": resName,
	})
	if err != nil {
		return fmt.Errorf("create key: %w", err)
	}

	accessKeyID, _ := keyResp["accessKeyId"].(string)
	secretAccessKey, _ := keyResp["secretAccessKey"].(string)
	if accessKeyID == "" || secretAccessKey == "" {
		return fmt.Errorf("create key: missing accessKeyId or secretAccessKey in response")
	}

	// 2. Create Garage bucket
	bucketResp, err := s.garageRequest(ctx, "POST", "/v1/bucket", map[string]interface{}{
		"globalAlias": resName,
	})
	if err != nil {
		return fmt.Errorf("create bucket: %w", err)
	}

	bucketID, _ := bucketResp["id"].(string)
	if bucketID == "" {
		return fmt.Errorf("create bucket: missing id in response")
	}

	// 3. Grant key access to bucket
	_, err = s.garageRequest(ctx, "POST", "/v1/bucket/allow", map[string]interface{}{
		"bucketId":    bucketID,
		"accessKeyId": accessKeyID,
		"permissions": map[string]interface{}{
			"read":  true,
			"write": true,
			"owner": false,
		},
	})
	if err != nil {
		return fmt.Errorf("allow bucket: %w", err)
	}

	// 4. Store credentials in K8s Secret
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      resName + "-credentials",
			Namespace: namespace,
			Labels: map[string]string{
				"cf-service-broker/instance-id": name,
				"cf-service-broker/service":     "s3",
			},
		},
		StringData: map[string]string{
			"access_key_id":     accessKeyID,
			"secret_access_key": secretAccessKey,
			"bucket":            resName,
			"bucket_id":         bucketID,
			"endpoint":          s.S3Endpoint,
			"region":            "garage",
		},
	}
	_, err = client.Typed.CoreV1().Secrets(namespace).Create(ctx, secret, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("create credentials secret: %w", err)
	}

	return nil
}

func (s *S3) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	resName := "s3-" + name

	// Read secret for bucket_id and access_key_id
	secret, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, resName+"-credentials", metav1.GetOptions{})
	if err != nil {
		log.Printf("Warning: credentials secret %s not found, skipping API cleanup: %v", resName+"-credentials", err)
		return nil
	}

	bucketID := string(secret.Data["bucket_id"])
	accessKeyID := string(secret.Data["access_key_id"])
	bucket := string(secret.Data["bucket"])

	// Empty the bucket via S3 API (Garage rejects non-empty bucket deletes)
	if bucket != "" && accessKeyID != "" {
		if err := s.emptyBucket(ctx, bucket, accessKeyID, string(secret.Data["secret_access_key"])); err != nil {
			log.Printf("Warning: empty bucket %s: %v", bucket, err)
		}
	}

	// Delete bucket via Admin API
	if bucketID != "" {
		_, err := s.garageDelete(ctx, "/v1/bucket?id="+bucketID)
		if err != nil {
			log.Printf("Warning: delete bucket %s: %v", bucketID, err)
		}
	}

	// Delete API key
	if accessKeyID != "" {
		_, err := s.garageDelete(ctx, "/v1/key?id="+accessKeyID)
		if err != nil {
			log.Printf("Warning: delete key %s: %v", accessKeyID, err)
		}
	}

	// Delete credentials secret
	_ = client.Typed.CoreV1().Secrets(namespace).Delete(ctx, resName+"-credentials", metav1.DeleteOptions{})

	return nil
}

func (s *S3) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	resName := "s3-" + name
	_, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, resName+"-credentials", metav1.GetOptions{})
	if err != nil {
		return false, "provisioning", err
	}
	return true, "succeeded", nil
}

func (s *S3) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	resName := "s3-" + name
	secret, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, resName+"-credentials", metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("credentials secret %s not found: %w", resName+"-credentials", err)
	}

	accessKeyID := string(secret.Data["access_key_id"])
	secretAccessKey := string(secret.Data["secret_access_key"])
	bucket := string(secret.Data["bucket"])
	endpoint := string(secret.Data["endpoint"])
	region := string(secret.Data["region"])

	return map[string]interface{}{
		"type":              "s3",
		"access_key_id":     accessKeyID,
		"secret_access_key": secretAccessKey,
		"endpoint":          endpoint,
		"bucket":            bucket,
		"region":            region,
		"path_style":        true,
		"uri":               fmt.Sprintf("s3://%s@%s/%s", accessKeyID, strings.TrimPrefix(strings.TrimPrefix(endpoint, "http://"), "https://"), bucket),
	}, nil
}

// garageRequest sends a JSON request to the Garage Admin API and returns the parsed response.
func (s *S3) garageRequest(ctx context.Context, method, path string, body map[string]interface{}) (map[string]interface{}, error) {
	jsonBody, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, method, s.AdminURL+path, bytes.NewReader(jsonBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+s.AdminToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("garage API %s %s returned %d: %s", method, path, resp.StatusCode, string(respBody))
	}

	var result map[string]interface{}
	if len(respBody) > 0 {
		if err := json.Unmarshal(respBody, &result); err != nil {
			return nil, fmt.Errorf("parse response: %w", err)
		}
	}
	return result, nil
}

// garageDelete sends a DELETE request to the Garage Admin API.
func (s *S3) garageDelete(ctx context.Context, path string) (int, error) {
	req, err := http.NewRequestWithContext(ctx, "DELETE", s.AdminURL+path, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+s.AdminToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, fmt.Errorf("garage API DELETE %s returned %d: %s", path, resp.StatusCode, string(body))
	}
	return resp.StatusCode, nil
}

// emptyBucket deletes all objects in a bucket using the S3 ListObjectsV2 + DeleteObject API.
// Uses unsigned requests with the bucket owner's credentials via query parameters.
func (s *S3) emptyBucket(ctx context.Context, bucket, accessKeyID, secretAccessKey string) error {
	// Use simple unsigned S3 API calls — Garage supports path-style
	for {
		// List objects
		listURL := fmt.Sprintf("%s/%s?list-type=2&max-keys=1000", s.S3Endpoint, bucket)
		req, err := http.NewRequestWithContext(ctx, "GET", listURL, nil)
		if err != nil {
			return err
		}

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		if resp.StatusCode != 200 {
			return fmt.Errorf("list objects returned %d: %s", resp.StatusCode, string(body))
		}

		var result struct {
			Contents []struct {
				Key string `xml:"Key"`
			} `xml:"Contents"`
		}
		if err := xml.Unmarshal(body, &result); err != nil {
			return fmt.Errorf("parse list response: %w", err)
		}

		if len(result.Contents) == 0 {
			return nil // bucket is empty
		}

		// Delete each object
		for _, obj := range result.Contents {
			delURL := fmt.Sprintf("%s/%s/%s", s.S3Endpoint, bucket, obj.Key)
			delReq, err := http.NewRequestWithContext(ctx, "DELETE", delURL, nil)
			if err != nil {
				return err
			}
			delResp, err := http.DefaultClient.Do(delReq)
			if err != nil {
				return err
			}
			delResp.Body.Close()
		}
	}
}
```

**Note:** The `emptyBucket` method uses unsigned S3 requests. Since the Garage S3 endpoint is internal and the bucket's access key has read/write permissions, this works for simple cases. If Garage requires signed requests, the implementation will need AWS Signature V4 signing — in that case, use the admin key configured on the broker. During implementation, test against the actual Garage instance and add signing if needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd k8/services/cf-service-broker/src && go test ./provisioners/ -v -run TestS3`
Expected: All 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add k8/services/cf-service-broker/src/provisioners/s3.go k8/services/cf-service-broker/src/provisioners/s3_test.go
git commit -m "feat(broker): implement S3 provisioner with Garage Admin API"
```

---

## Task 3: Wire S3 Provisioner into the Broker

**Files:**
- Modify: `k8/services/cf-service-broker/src/broker/broker.go`
- Modify: `k8/services/cf-service-broker/src/main.go`

- [ ] **Step 1: Add GarageConfig and update broker.New()**

In `k8/services/cf-service-broker/src/broker/broker.go`, add the `GarageConfig` struct and update `New()`:

Replace `New()` function (lines 20-30):

```go
type GarageConfig struct {
	AdminURL   string
	AdminToken string
	S3Endpoint string
}

func New(client *k8sclient.Client, namespace, valkeyImage string, garage GarageConfig) *Broker {
	return &Broker{
		client:    client,
		namespace: namespace,
		provisioners: map[string]provisioners.Provisioner{
			PostgreSQLServiceID: &provisioners.PostgreSQL{},
			ValkeyServiceID:     &provisioners.Valkey{Image: valkeyImage},
			RabbitMQServiceID:   &provisioners.RabbitMQ{},
			S3ServiceID: &provisioners.S3{
				AdminURL:   garage.AdminURL,
				AdminToken: garage.AdminToken,
				S3Endpoint: garage.S3Endpoint,
			},
		},
	}
}
```

- [ ] **Step 2: Update main.go to parse Garage env vars**

In `k8/services/cf-service-broker/src/main.go`, add after `port` env parsing (after line 20):

```go
garageAdminURL := os.Getenv("GARAGE_ADMIN_URL")
garageAdminToken := os.Getenv("GARAGE_ADMIN_TOKEN")
garageS3Endpoint := os.Getenv("GARAGE_S3_ENDPOINT")
```

Add defaults after the existing defaults block (after line 36):

```go
if garageAdminURL == "" {
    garageAdminURL = "http://garage.garage.svc.cluster.local:3903"
}
if garageS3Endpoint == "" {
    garageS3Endpoint = "http://garage.garage.svc.cluster.local:3900"
}
```

Update the `broker.New()` call (line 43) to:

```go
b := broker.New(client, namespace, valkeyImage, broker.GarageConfig{
    AdminURL:   garageAdminURL,
    AdminToken: garageAdminToken,
    S3Endpoint: garageS3Endpoint,
})
```

Add a log line after the existing log lines (after line 62):

```go
log.Printf("  Garage Admin: %s", garageAdminURL)
```

- [ ] **Step 3: Verify compilation**

Run: `cd k8/services/cf-service-broker/src && go build ./...`
Expected: compiles with no errors

- [ ] **Step 4: Commit**

```bash
git add k8/services/cf-service-broker/src/broker/broker.go k8/services/cf-service-broker/src/main.go
git commit -m "feat(broker): wire S3 provisioner into broker with GarageConfig"
```

---

## Task 4: Configure Garage admin_token

**Files:**
- Modify: `k8/platform/garage/configmap.yaml`

- [ ] **Step 1: Add admin_token to Garage ConfigMap**

In `k8/platform/garage/configmap.yaml`, replace the `[admin]` section (lines 25-26):

```toml
    [admin]
    api_bind_addr = "[::]:3903"
    admin_token = "GARAGE_ADMIN_TOKEN_PLACEHOLDER"
```

The placeholder will be replaced by `install.sh` at deploy time with a generated token (same pattern as the broker password substitution on install.sh line 1758).

- [ ] **Step 2: Commit**

```bash
git add k8/platform/garage/configmap.yaml
git commit -m "feat(garage): add admin_token placeholder to admin API config"
```

---

## Task 5: Update Broker Deployment and Add ExternalSecret

**Files:**
- Modify: `k8/services/cf-service-broker/deployment.yaml`
- Create: `k8/services/cf-service-broker/externalsecret-garage.yaml`

- [ ] **Step 1: Create ExternalSecret for Garage admin token**

Create `k8/services/cf-service-broker/externalsecret-garage.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: garage-admin-token
  namespace: cf-services
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: garage-admin-token
  data:
    - secretKey: token
      remoteRef:
        key: secret/garage/admin-token
        property: token
```

- [ ] **Step 2: Bump image tag and add Garage env vars**

In `k8/services/cf-service-broker/deployment.yaml`:

Update image (line 61):
```yaml
          image: artifactory.cfapps.cool/docker-local/cf-service-broker:1.3.0-arm64
```

Add Garage env vars after the VALKEY_IMAGE env (after line 72):

```yaml
            - name: GARAGE_ADMIN_URL
              value: "http://garage.garage.svc.cluster.local:3903"
            - name: GARAGE_S3_ENDPOINT
              value: "http://garage.garage.svc.cluster.local:3900"
            - name: GARAGE_ADMIN_TOKEN
              valueFrom:
                secretKeyRef:
                  name: garage-admin-token
                  key: token
```

- [ ] **Step 3: Commit**

```bash
git add k8/services/cf-service-broker/deployment.yaml k8/services/cf-service-broker/externalsecret-garage.yaml
git commit -m "feat(broker): add Garage env vars, ExternalSecret, and bump to 1.3.0"
```

---

## Task 6: Update install.sh

**Files:**
- Modify: `k8/distribution/install.sh`

- [ ] **Step 1: Add Garage admin token generation in Phase 7**

In `k8/distribution/install.sh`, add a new block inside `install_phase_7()` before the broker build step (before line 1716, the `phase7_broker_build` block). Add a new guarded block:

```bash
  # --- Garage Admin Token ---
  if ! component_is_installed "phase7_garage_admin_token" "$STATE_FILE"; then
    log_step "Configuring Garage admin token..."

    local GARAGE_TOKEN
    GARAGE_TOKEN=$(openssl rand -hex 32)

    # Store in OpenBao
    kubectl exec -n openbao openbao-0 -- bao kv put secret/garage/admin-token \
      token="${GARAGE_TOKEN}" 2>&1 | tail -1

    # Update Garage ConfigMap with token
    sed "s/GARAGE_ADMIN_TOKEN_PLACEHOLDER/${GARAGE_TOKEN}/g" \
      "${K8_DIR}/platform/garage/configmap.yaml" | kubectl apply -f - 2>&1 | tail -1

    # Restart Garage to pick up new config
    kubectl rollout restart statefulset/garage -n garage 2>&1 | tail -1
    wait_for_pods "garage" 120

    # Apply ExternalSecret so ESO syncs token to cf-services namespace
    kubectl apply -f "${K8_DIR}/services/cf-service-broker/externalsecret-garage.yaml" 2>&1 | tail -1

    log_success "Garage admin token configured"
    mark_component_installed "phase7_garage_admin_token" "$STATE_FILE"
  fi
```

- [ ] **Step 2: Add `cf enable-service-access s3`**

In `k8/distribution/install.sh`, add after line 1781 (`cf enable-service-access rabbitmq`):

```bash
    cf enable-service-access s3 2>&1 | tail -1
```

- [ ] **Step 3: Update the broker image tag in install.sh**

In `k8/distribution/install.sh`, update line 1729:

```bash
      local BROKER_IMAGE="${BROKER_REGISTRY}/cf-service-broker:1.3.0-arm64"
```

- [ ] **Step 4: Add S3 to Phase 7 completion summary**

Find the Phase 7 summary output block (around line 1794) that lists services and add:

```bash
  echo -e "    s3             default         S3-compatible object storage (Garage)"
```

- [ ] **Step 5: Commit**

```bash
git add k8/distribution/install.sh
git commit -m "feat(install): add Garage admin token setup and S3 service access"
```

---

## Task 7: Build, Deploy, and Verify

This task requires a running K3s cluster.

- [ ] **Step 1: Build the updated broker image**

```bash
cd k8/services/cf-service-broker/src
go build -o /tmp/cf-service-broker .
# Then build and push container image via crane (same as install.sh pattern)
```

- [ ] **Step 2: Generate and configure Garage admin token**

```bash
export KUBECONFIG=~/.kube/config-k3s
GARAGE_TOKEN=$(openssl rand -hex 32)

# Store in OpenBao
kubectl exec -n openbao openbao-0 -- bao kv put secret/garage/admin-token token="${GARAGE_TOKEN}"

# Update Garage ConfigMap
kubectl get configmap garage-config -n garage -o yaml | \
  sed "s/GARAGE_ADMIN_TOKEN_PLACEHOLDER/${GARAGE_TOKEN}/" | kubectl apply -f -

# Restart Garage
kubectl rollout restart statefulset/garage -n garage
kubectl rollout status statefulset/garage -n garage --timeout=120s
```

- [ ] **Step 3: Create K8s secret for broker to read Garage token**

```bash
kubectl create secret generic garage-admin-token \
  --from-literal=token="${GARAGE_TOKEN}" \
  -n cf-services --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 4: Deploy updated broker**

```bash
kubectl apply -f k8/services/cf-service-broker/deployment.yaml
kubectl rollout status deployment/cf-service-broker -n cf-services --timeout=60s
```

- [ ] **Step 5: Verify catalog includes S3**

```bash
cf update-service-broker k8s-services admin "$(kubectl exec -n openbao openbao-0 -- bao kv get -field=password secret/cf-service-broker/auth)" \
  http://cf-service-broker.cf-services.svc.cluster.local
cf enable-service-access s3
cf marketplace
```

Expected: `s3` service appears with `default` plan.

- [ ] **Step 6: End-to-end test**

```bash
cf create-service s3 default test-bucket
# Wait for provisioning
cf services  # status should show "create succeeded"

cf create-service-key test-bucket test-key
cf service-key test-bucket test-key
# Should show: type, access_key_id, secret_access_key, endpoint, bucket, region, path_style, uri

# Cleanup
cf delete-service-key test-bucket test-key -f
cf delete-service test-bucket -f
```

- [ ] **Step 7: Commit any final adjustments**

```bash
git add -A
git commit -m "chore: finalize S3 service broker deployment"
```
