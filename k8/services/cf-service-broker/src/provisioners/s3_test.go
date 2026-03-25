package provisioners

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"net/http"
	"net/http/httptest"
	"testing"

	k8sclient "github.com/cfapps/cf-service-broker/k8s"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

// xmlListBucketResult is a minimal S3 ListBucketResult for test responses.
type xmlListBucketResult struct {
	XMLName     xml.Name      `xml:"ListBucketResult"`
	IsTruncated bool          `xml:"IsTruncated"`
	Contents    []xmlContents `xml:"Contents"`
}

type xmlContents struct {
	Key string `xml:"Key"`
}

func newTestS3Client(adminURL, s3URL string) *S3 {
	return &S3{
		AdminURL:   adminURL,
		AdminToken: "test-token",
		S3Endpoint: s3URL,
	}
}

func newFakeK8sClient() *k8sclient.Client {
	return &k8sclient.Client{
		Typed: fake.NewSimpleClientset(),
	}
}

func preCreateS3Secret(t *testing.T, client *k8sclient.Client, name, namespace string) {
	t.Helper()
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "s3-" + name + "-credentials",
			Namespace: namespace,
			Labels: map[string]string{
				"cf-service-broker/instance-id": name,
				"cf-service-broker/service":     "s3",
			},
		},
		Data: map[string][]byte{
			"access_key_id":     []byte("GKtestkey"),
			"secret_access_key": []byte("testsecret"),
			"bucket":            []byte("s3-" + name),
			"bucket_id":         []byte("bucket-id-123"),
			"endpoint":          []byte("http://garage.garage.svc.cluster.local:3900"),
			"region":            []byte("garage"),
		},
	}
	_, err := client.Typed.CoreV1().Secrets(namespace).Create(context.Background(), secret, metav1.CreateOptions{})
	if err != nil {
		t.Fatalf("failed to pre-create secret: %v", err)
	}
}

func TestS3Provision(t *testing.T) {
	keyCreated := false
	bucketCreated := false
	allowCalled := false

	mux := http.NewServeMux()

	mux.HandleFunc("POST /v1/key", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		keyCreated = true
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"accessKeyId":     "GKtestkey",
			"secretAccessKey": "testsecret",
		})
	})

	mux.HandleFunc("POST /v1/bucket", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		bucketCreated = true
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"id":          "bucket-id-123",
			"globalAlias": "s3-testinstance",
		})
	})

	mux.HandleFunc("POST /v1/bucket/allow", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		allowCalled = true
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{})
	})

	adminServer := httptest.NewServer(mux)
	defer adminServer.Close()

	s3 := newTestS3Client(adminServer.URL, "http://s3.example.com")
	client := newFakeK8sClient()

	err := s3.Provision(context.Background(), client, "testinstance", "test-ns", "plan-1")
	if err != nil {
		t.Fatalf("Provision failed: %v", err)
	}

	if !keyCreated {
		t.Error("expected POST /v1/key to be called")
	}
	if !bucketCreated {
		t.Error("expected POST /v1/bucket to be called")
	}
	if !allowCalled {
		t.Error("expected POST /v1/bucket/allow to be called")
	}

	secret, err := client.Typed.CoreV1().Secrets("test-ns").Get(context.Background(), "s3-testinstance-credentials", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("expected secret to exist: %v", err)
	}

	if secret.Labels["cf-service-broker/instance-id"] != "testinstance" {
		t.Errorf("wrong instance-id label: %s", secret.Labels["cf-service-broker/instance-id"])
	}
	if secret.Labels["cf-service-broker/service"] != "s3" {
		t.Errorf("wrong service label: %s", secret.Labels["cf-service-broker/service"])
	}

	expectedKeys := []string{"access_key_id", "secret_access_key", "bucket", "bucket_id", "endpoint", "region"}
	for _, key := range expectedKeys {
		if _, ok := secret.StringData[key]; !ok {
			// Also check Data (fake client may store in Data)
			if _, ok2 := secret.Data[key]; !ok2 {
				t.Errorf("secret missing key: %s", key)
			}
		}
	}

	if v := secret.StringData["access_key_id"]; v != "GKtestkey" {
		t.Errorf("wrong access_key_id: %s", v)
	}
	if v := secret.StringData["bucket"]; v != "s3-testinstance" {
		t.Errorf("wrong bucket: %s", v)
	}
}

func TestS3GetCredentials(t *testing.T) {
	client := newFakeK8sClient()
	preCreateS3Secret(t, client, "testinstance", "test-ns")

	s3 := newTestS3Client("http://admin.example.com", "http://s3.example.com")
	creds, err := s3.GetCredentials(context.Background(), client, "testinstance", "test-ns")
	if err != nil {
		t.Fatalf("GetCredentials failed: %v", err)
	}

	expectedFields := []string{"type", "access_key_id", "secret_access_key", "endpoint", "bucket", "region", "uri"}
	for _, field := range expectedFields {
		if _, ok := creds[field]; !ok {
			t.Errorf("credentials missing field: %s", field)
		}
	}

	if creds["type"] != "s3" {
		t.Errorf("wrong type: %v", creds["type"])
	}
	if creds["path_style"] != true {
		t.Errorf("expected path_style=true, got: %v", creds["path_style"])
	}
	if creds["access_key_id"] != "GKtestkey" {
		t.Errorf("wrong access_key_id: %v", creds["access_key_id"])
	}
	if creds["bucket"] != "s3-testinstance" {
		t.Errorf("wrong bucket: %v", creds["bucket"])
	}
	if creds["region"] != "garage" {
		t.Errorf("wrong region: %v", creds["region"])
	}
}

func TestS3IsReady(t *testing.T) {
	client := newFakeK8sClient()
	preCreateS3Secret(t, client, "testinstance", "test-ns")

	s3 := newTestS3Client("http://admin.example.com", "http://s3.example.com")
	ready, state, err := s3.IsReady(context.Background(), client, "testinstance", "test-ns")
	if err != nil {
		t.Fatalf("IsReady failed: %v", err)
	}
	if !ready {
		t.Error("expected ready=true")
	}
	if state != "succeeded" {
		t.Errorf("expected state=succeeded, got: %s", state)
	}
}

func TestS3IsReadyNotFound(t *testing.T) {
	client := newFakeK8sClient()

	s3 := newTestS3Client("http://admin.example.com", "http://s3.example.com")
	ready, state, err := s3.IsReady(context.Background(), client, "noexist", "test-ns")
	if err == nil {
		t.Error("expected error when secret not found")
	}
	if ready {
		t.Error("expected ready=false")
	}
	if state != "provisioning" {
		t.Errorf("expected state=provisioning, got: %s", state)
	}
}

func TestS3Deprovision(t *testing.T) {
	keyDeleted := false
	bucketDeleted := false
	listCalled := false

	// Minimal empty S3 ListBucketResult XML
	emptyListXML, _ := xml.Marshal(xmlListBucketResult{IsTruncated: false})
	emptyListXML = append([]byte(`<?xml version="1.0" encoding="UTF-8"?>`), emptyListXML...)

	s3Mux := http.NewServeMux()
	s3Mux.HandleFunc("GET /{bucket}", func(w http.ResponseWriter, r *http.Request) {
		listCalled = true
		w.Header().Set("Content-Type", "application/xml")
		w.Write(emptyListXML)
	})
	s3Server := httptest.NewServer(s3Mux)
	defer s3Server.Close()

	adminMux := http.NewServeMux()
	adminMux.HandleFunc("DELETE /v1/bucket", func(w http.ResponseWriter, r *http.Request) {
		bucketDeleted = true
		w.WriteHeader(http.StatusNoContent)
	})
	adminMux.HandleFunc("DELETE /v1/key", func(w http.ResponseWriter, r *http.Request) {
		keyDeleted = true
		w.WriteHeader(http.StatusNoContent)
	})
	adminServer := httptest.NewServer(adminMux)
	defer adminServer.Close()

	client := newFakeK8sClient()
	preCreateS3Secret(t, client, "testinstance", "test-ns")

	s3 := newTestS3Client(adminServer.URL, s3Server.URL)
	err := s3.Deprovision(context.Background(), client, "testinstance", "test-ns")
	if err != nil {
		t.Fatalf("Deprovision returned error: %v", err)
	}

	if !listCalled {
		t.Error("expected S3 list objects to be called")
	}
	if !bucketDeleted {
		t.Error("expected DELETE /v1/bucket to be called")
	}
	if !keyDeleted {
		t.Error("expected DELETE /v1/key to be called")
	}

	_, err = client.Typed.CoreV1().Secrets("test-ns").Get(context.Background(), "s3-testinstance-credentials", metav1.GetOptions{})
	if err == nil {
		t.Error("expected secret to be deleted")
	}
}
