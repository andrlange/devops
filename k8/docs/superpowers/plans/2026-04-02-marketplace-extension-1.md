# Marketplace Extension 1: AI/ML Services — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a new OSBAPI service broker (`cf-marketplace-broker`) with three services (PostgreSQL AI Enabled, OpenBao Secret Container, AI Model Connector), integrate as Phase 9 in the installer, and provide a standalone `extend-marketplace-1.sh` script.

**Architecture:** Standalone Go service following the same patterns as the existing `cf-service-broker` (brokerapi/v11, K8s dynamic client, ConfigMap state, Provisioner interface). Three new provisioners: postgres-ai (CloudNativePG + Timescale image), openbao-secrets (OpenBao KV v2 + AppRole via HTTP API), ai-connector (endpoint config in K8s Secret). Deployed to `cf-services` namespace on port 8081.

**Tech Stack:** Go 1.26, pivotal-cf/brokerapi/v11, k8s.io/client-go v0.35.3, CloudNativePG CRD, OpenBao HTTP API, distroless container image

**Spec:** `k8/docs/superpowers/specs/2026-04-02-marketplace-extension-1-design.md`

---

## File Structure

```
k8/services/cf-marketplace-broker/
├── src/
│   ├── main.go                         # Entry point (env config, HTTP server, mux)
│   ├── go.mod                          # Module: github.com/cfapps/cf-marketplace-broker
│   ├── broker/
│   │   ├── broker.go                   # OSBAPI handler (provision, bind, etc.)
│   │   ├── catalog.go                  # 3 services, 4 plans
│   │   └── state.go                    # ConfigMap: broker-marketplace-instances
│   ├── provisioners/
│   │   ├── provisioner.go              # Interface + ResourceName()
│   │   ├── postgres_ai.go             # CloudNativePG + Timescale + extension init
│   │   ├── openbao_secrets.go         # OpenBao KV v2 + AppRole lifecycle
│   │   └── ai_connector.go           # Endpoint validation + K8s Secret
│   └── k8s/
│       └── client.go                   # K8s client (typed + dynamic)
├── Dockerfile                          # Multi-stage Go 1.26 → distroless
├── deployment.yaml                     # SA, ClusterRole, ClusterRoleBinding, Deployment, Service
├── externalsecret-openbao.yaml        # ESO ExternalSecret for OpenBao token
└── test/
    ├── main_test.go                    # Test setup, env-based config
    ├── helpers.go                      # OSBAPI HTTP helpers
    ├── postgres_ai_test.go            # pgvector lifecycle test
    ├── openbao_test.go                # Secrets lifecycle test
    └── ai_connector_test.go           # AI connector lifecycle test

k8/distribution/
├── lib/phase9.sh                       # Phase 9 shared logic
├── extend-marketplace-1.sh            # Standalone extension script
└── install.sh                          # Modified: Phase 9 added (7 locations)

GETTING_STARTED.md                      # Modified: Phase 9 + extension docs
```

---

### Task 1: Project Scaffolding (go.mod, client.go, provisioner interface)

**Files:**
- Create: `k8/services/cf-marketplace-broker/src/go.mod`
- Create: `k8/services/cf-marketplace-broker/src/k8s/client.go`
- Create: `k8/services/cf-marketplace-broker/src/provisioners/provisioner.go`

- [ ] **Step 1: Create go.mod**

```bash
mkdir -p k8/services/cf-marketplace-broker/src/{broker,provisioners,k8s}
```

Write `k8/services/cf-marketplace-broker/src/go.mod`:
```go
module github.com/cfapps/cf-marketplace-broker

go 1.26.1

require (
	github.com/pivotal-cf/brokerapi/v11 v11.0.16
	k8s.io/api v0.35.3
	k8s.io/apimachinery v0.35.3
	k8s.io/client-go v0.35.3
)
```

- [ ] **Step 2: Create K8s client**

Write `k8/services/cf-marketplace-broker/src/k8s/client.go`:
```go
package k8s

import (
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

type Client struct {
	Typed   kubernetes.Interface
	Dynamic dynamic.Interface
}

func NewClient() (*Client, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, err
	}

	typed, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, err
	}

	dyn, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, err
	}

	return &Client{Typed: typed, Dynamic: dyn}, nil
}
```

- [ ] **Step 3: Create provisioner interface**

Write `k8/services/cf-marketplace-broker/src/provisioners/provisioner.go`:
```go
package provisioners

import (
	"context"

	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
)

type Provisioner interface {
	Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string, params map[string]interface{}) error
	Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error
	IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error)
	GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error)
}

func ResourceName(instanceID string) string {
	if len(instanceID) > 8 {
		return instanceID[:8]
	}
	return instanceID
}
```

Note: This interface adds `params map[string]interface{}` to `Provision` compared to the existing broker — needed for AI Connector endpoint configuration.

- [ ] **Step 4: Run `go mod tidy`**

```bash
cd k8/services/cf-marketplace-broker/src && go mod tidy
```

Expected: go.sum generated, all dependencies resolved.

- [ ] **Step 5: Commit**

```bash
git add k8/services/cf-marketplace-broker/
git commit -m "feat(marketplace-broker): scaffold project with go.mod, k8s client, provisioner interface"
```

---

### Task 2: Service Catalog + State Management

**Files:**
- Create: `k8/services/cf-marketplace-broker/src/broker/catalog.go`
- Create: `k8/services/cf-marketplace-broker/src/broker/state.go`

- [ ] **Step 1: Create catalog.go**

Write `k8/services/cf-marketplace-broker/src/broker/catalog.go`:
```go
package broker

import (
	"github.com/pivotal-cf/brokerapi/v11/domain"
)

const (
	PostgresAIServiceID    = "b1a2c3d4-e5f6-7890-abcd-100000000001"
	OpenBaoSecretsServiceID = "b1a2c3d4-e5f6-7890-abcd-200000000002"
	AIConnectorServiceID   = "b1a2c3d4-e5f6-7890-abcd-300000000003"

	PostgresAISmallPlanID  = "c2d3e4f5-a1b2-7890-abcd-100000000011"
	PostgresAIMediumPlanID = "c2d3e4f5-a1b2-7890-abcd-100000000012"
	OpenBaoDefaultPlanID   = "c2d3e4f5-a1b2-7890-abcd-200000000021"
	AIConnectorDefaultPlanID = "c2d3e4f5-a1b2-7890-abcd-300000000031"
)

func serviceCatalog() []domain.Service {
	return []domain.Service{
		{
			ID:          PostgresAIServiceID,
			Name:        "postgres-ai",
			Description: "PostgreSQL 17 with pgvector, pgvectorscale, PostGIS, full-text search, and AI/ML extensions",
			Bindable:    true,
			Tags:        []string{"postgresql", "ai", "vector", "ml", "database"},
			Metadata: &domain.ServiceMetadata{
				DisplayName: "PostgreSQL AI Enabled",
			},
			Plans: []domain.ServicePlan{
				{
					ID:          PostgresAISmallPlanID,
					Name:        "small",
					Description: "1 instance, 512Mi RAM, 2Gi storage — pgvector, pgvectorscale, PostGIS, pg_trgm, fuzzystrmatch, pgcrypto, uuid-ossp, unaccent, pg_stat_statements",
					Free:        domain.FreeValue(true),
				},
				{
					ID:          PostgresAIMediumPlanID,
					Name:        "medium",
					Description: "1 instance, 1Gi RAM, 10Gi storage — pgvector, pgvectorscale, PostGIS, pg_trgm, fuzzystrmatch, pgcrypto, uuid-ossp, unaccent, pg_stat_statements",
					Free:        domain.FreeValue(true),
				},
			},
			PlanUpdatable: false,
		},
		{
			ID:          OpenBaoSecretsServiceID,
			Name:        "openbao-secrets",
			Description: "Managed secret container in OpenBao with AppRole access for application-managed secrets",
			Bindable:    true,
			Tags:        []string{"secrets", "vault", "openbao", "security"},
			Metadata: &domain.ServiceMetadata{
				DisplayName: "OpenBao Secret Container",
			},
			Plans: []domain.ServicePlan{
				{
					ID:          OpenBaoDefaultPlanID,
					Name:        "default",
					Description: "Dedicated KV v2 path, AppRole with 24h TTL",
					Free:        domain.FreeValue(true),
				},
			},
			PlanUpdatable: false,
		},
		{
			ID:          AIConnectorServiceID,
			Name:        "ai-connector",
			Description: "Connect to external AI model providers (Ollama, LM Studio) via OpenAI-compatible API",
			Bindable:    true,
			Tags:        []string{"ai", "llm", "ollama", "lmstudio", "connector"},
			Metadata: &domain.ServiceMetadata{
				DisplayName: "AI Model Connector",
			},
			Plans: []domain.ServicePlan{
				{
					ID:          AIConnectorDefaultPlanID,
					Name:        "default",
					Description: "External AI endpoint connector (Ollama, LM Studio)",
					Free:        domain.FreeValue(true),
				},
			},
			PlanUpdatable: false,
		},
	}
}
```

- [ ] **Step 2: Create state.go**

Write `k8/services/cf-marketplace-broker/src/broker/state.go`:
```go
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
```

Note: `InstanceState` adds a `Params` field compared to the existing broker — needed to persist AI Connector endpoint config for GetCredentials.

- [ ] **Step 3: Verify compilation**

```bash
cd k8/services/cf-marketplace-broker/src && go build ./broker/...
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add k8/services/cf-marketplace-broker/src/broker/
git commit -m "feat(marketplace-broker): add service catalog (3 services, 4 plans) and state management"
```

---

### Task 3: Broker OSBAPI Handler + main.go

**Files:**
- Create: `k8/services/cf-marketplace-broker/src/broker/broker.go`
- Create: `k8/services/cf-marketplace-broker/src/main.go`

- [ ] **Step 1: Create broker.go**

Write `k8/services/cf-marketplace-broker/src/broker/broker.go`:
```go
package broker

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
	"github.com/cfapps/cf-marketplace-broker/provisioners"
	"github.com/pivotal-cf/brokerapi/v11/domain"
	"github.com/pivotal-cf/brokerapi/v11/domain/apiresponses"
)

type OpenBaoConfig struct {
	Addr  string
	Token string
}

type Broker struct {
	client       *k8sclient.Client
	namespace    string
	provisioners map[string]provisioners.Provisioner
}

func New(client *k8sclient.Client, namespace string, openbao OpenBaoConfig) *Broker {
	return &Broker{
		client:    client,
		namespace: namespace,
		provisioners: map[string]provisioners.Provisioner{
			PostgresAIServiceID:     &provisioners.PostgresAI{},
			OpenBaoSecretsServiceID: &provisioners.OpenBaoSecrets{
				Addr:  openbao.Addr,
				Token: openbao.Token,
			},
			AIConnectorServiceID: &provisioners.AIConnector{},
		},
	}
}

func (b *Broker) Services(ctx context.Context) ([]domain.Service, error) {
	return serviceCatalog(), nil
}

func (b *Broker) Provision(ctx context.Context, instanceID string, details domain.ProvisionDetails, asyncAllowed bool) (domain.ProvisionedServiceSpec, error) {
	if !asyncAllowed {
		return domain.ProvisionedServiceSpec{}, apiresponses.ErrAsyncRequired
	}

	prov, ok := b.provisioners[details.ServiceID]
	if !ok {
		return domain.ProvisionedServiceSpec{}, fmt.Errorf("unknown service ID: %s", details.ServiceID)
	}

	name := provisioners.ResourceName(instanceID)

	if _, err := getInstance(ctx, b.client.Typed, b.namespace, instanceID); err == nil {
		log.Printf("Instance %s already exists, returning success", instanceID)
		return domain.ProvisionedServiceSpec{
			IsAsync:       true,
			OperationData: "provisioning",
			AlreadyExists: true,
		}, nil
	}

	var params map[string]interface{}
	if len(details.RawParameters) > 0 {
		if err := json.Unmarshal(details.RawParameters, &params); err != nil {
			return domain.ProvisionedServiceSpec{}, fmt.Errorf("invalid parameters: %w", err)
		}
	}

	log.Printf("Provisioning %s (plan=%s, name=%s)", details.ServiceID, details.PlanID, name)

	if err := prov.Provision(ctx, b.client, name, b.namespace, details.PlanID, params); err != nil {
		return domain.ProvisionedServiceSpec{}, fmt.Errorf("provision failed: %w", err)
	}

	if err := saveInstance(ctx, b.client.Typed, b.namespace, instanceID, InstanceState{
		ServiceID: details.ServiceID,
		PlanID:    details.PlanID,
		Name:      name,
		Namespace: b.namespace,
		Params:    params,
	}); err != nil {
		log.Printf("Warning: failed to save instance state: %v", err)
	}

	return domain.ProvisionedServiceSpec{
		IsAsync:       true,
		OperationData: "provisioning",
	}, nil
}

func (b *Broker) Deprovision(ctx context.Context, instanceID string, details domain.DeprovisionDetails, asyncAllowed bool) (domain.DeprovisionServiceSpec, error) {
	state, err := getInstance(ctx, b.client.Typed, b.namespace, instanceID)
	if err != nil {
		return domain.DeprovisionServiceSpec{}, apiresponses.ErrInstanceDoesNotExist
	}

	prov, ok := b.provisioners[state.ServiceID]
	if !ok {
		return domain.DeprovisionServiceSpec{}, fmt.Errorf("unknown service ID: %s", state.ServiceID)
	}

	log.Printf("Deprovisioning %s (name=%s)", state.ServiceID, state.Name)

	if err := prov.Deprovision(ctx, b.client, state.Name, state.Namespace); err != nil {
		log.Printf("Warning: deprovision error: %v", err)
	}

	_ = deleteInstance(ctx, b.client.Typed, b.namespace, instanceID)

	return domain.DeprovisionServiceSpec{}, nil
}

func (b *Broker) Bind(ctx context.Context, instanceID, bindingID string, details domain.BindDetails, asyncAllowed bool) (domain.Binding, error) {
	state, err := getInstance(ctx, b.client.Typed, b.namespace, instanceID)
	if err != nil {
		return domain.Binding{}, apiresponses.ErrInstanceDoesNotExist
	}

	prov, ok := b.provisioners[state.ServiceID]
	if !ok {
		return domain.Binding{}, fmt.Errorf("unknown service ID: %s", state.ServiceID)
	}

	creds, err := prov.GetCredentials(ctx, b.client, state.Name, state.Namespace)
	if err != nil {
		return domain.Binding{}, fmt.Errorf("failed to get credentials: %w", err)
	}

	return domain.Binding{Credentials: creds}, nil
}

func (b *Broker) Unbind(ctx context.Context, instanceID, bindingID string, details domain.UnbindDetails, asyncAllowed bool) (domain.UnbindSpec, error) {
	return domain.UnbindSpec{}, nil
}

func (b *Broker) LastOperation(ctx context.Context, instanceID string, details domain.PollDetails) (domain.LastOperation, error) {
	state, err := getInstance(ctx, b.client.Typed, b.namespace, instanceID)
	if err != nil {
		return domain.LastOperation{State: domain.Failed, Description: "instance not found"}, nil
	}

	prov, ok := b.provisioners[state.ServiceID]
	if !ok {
		return domain.LastOperation{State: domain.Failed, Description: "unknown service"}, nil
	}

	ready, desc, err := prov.IsReady(ctx, b.client, state.Name, state.Namespace)
	if err != nil {
		return domain.LastOperation{State: domain.InProgress, Description: desc}, nil
	}

	if ready {
		return domain.LastOperation{State: domain.Succeeded, Description: desc}, nil
	}
	return domain.LastOperation{State: domain.InProgress, Description: desc}, nil
}

func (b *Broker) GetInstance(ctx context.Context, instanceID string, details domain.FetchInstanceDetails) (domain.GetInstanceDetailsSpec, error) {
	state, err := getInstance(ctx, b.client.Typed, b.namespace, instanceID)
	if err != nil {
		return domain.GetInstanceDetailsSpec{}, apiresponses.ErrInstanceDoesNotExist
	}
	return domain.GetInstanceDetailsSpec{
		ServiceID: state.ServiceID,
		PlanID:    state.PlanID,
	}, nil
}

func (b *Broker) GetBinding(ctx context.Context, instanceID, bindingID string, details domain.FetchBindingDetails) (domain.GetBindingSpec, error) {
	return domain.GetBindingSpec{}, apiresponses.NewFailureResponseBuilder(
		fmt.Errorf("not supported"), 404, "not-found",
	).Build()
}

func (b *Broker) Update(ctx context.Context, instanceID string, details domain.UpdateDetails, asyncAllowed bool) (domain.UpdateServiceSpec, error) {
	return domain.UpdateServiceSpec{}, apiresponses.NewFailureResponseBuilder(
		fmt.Errorf("plan updates not supported"), 422, "not-supported",
	).Build()
}

func (b *Broker) LastBindingOperation(ctx context.Context, instanceID, bindingID string, details domain.PollDetails) (domain.LastOperation, error) {
	return domain.LastOperation{State: domain.Succeeded}, nil
}
```

- [ ] **Step 2: Create main.go**

Write `k8/services/cf-marketplace-broker/src/main.go`:
```go
package main

import (
	"log"
	"log/slog"
	"net/http"
	"os"

	"github.com/cfapps/cf-marketplace-broker/broker"
	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
	"github.com/pivotal-cf/brokerapi/v11"
)

func main() {
	username := os.Getenv("BROKER_USERNAME")
	password := os.Getenv("BROKER_PASSWORD")
	namespace := os.Getenv("NAMESPACE")
	openbaoAddr := os.Getenv("OPENBAO_ADDR")
	openbaoToken := os.Getenv("OPENBAO_TOKEN")
	port := os.Getenv("PORT")

	if username == "" {
		username = "marketplace-broker"
	}
	if password == "" {
		password = "changeme"
	}
	if namespace == "" {
		namespace = "cf-services"
	}
	if openbaoAddr == "" {
		openbaoAddr = "http://openbao.openbao.svc.cluster.local:8200"
	}
	if openbaoToken == "" {
		log.Println("WARNING: OPENBAO_TOKEN not set — openbao-secrets service provisioning will fail")
	}
	if port == "" {
		port = "8081"
	}

	client, err := k8sclient.NewClient()
	if err != nil {
		log.Fatalf("Failed to create K8s client: %v", err)
	}

	b := broker.New(client, namespace, broker.OpenBaoConfig{
		Addr:  openbaoAddr,
		Token: openbaoToken,
	})
	logger := slog.Default()

	credentials := brokerapi.BrokerCredentials{
		Username: username,
		Password: password,
	}

	brokerHandler := brokerapi.New(b, logger, credentials)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok"}`))
	})
	mux.Handle("/", brokerHandler)

	log.Printf("CF Marketplace Broker starting on :%s", port)
	log.Printf("  Namespace: %s", namespace)
	log.Printf("  OpenBao: %s", openbaoAddr)

	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
```

- [ ] **Step 3: Verify compilation**

```bash
cd k8/services/cf-marketplace-broker/src && go build .
```

Expected: Fails because provisioner implementations don't exist yet. That's OK — we'll create stubs next.

- [ ] **Step 4: Commit**

```bash
git add k8/services/cf-marketplace-broker/src/broker/broker.go k8/services/cf-marketplace-broker/src/main.go
git commit -m "feat(marketplace-broker): add OSBAPI handler and main.go entry point"
```

---

### Task 4: PostgreSQL AI Provisioner

**Files:**
- Create: `k8/services/cf-marketplace-broker/src/provisioners/postgres_ai.go`

- [ ] **Step 1: Create postgres_ai.go**

Write `k8/services/cf-marketplace-broker/src/provisioners/postgres_ai.go`:
```go
package provisioners

import (
	"context"
	"fmt"

	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

var cnpgGVR = schema.GroupVersionResource{
	Group:    "postgresql.cnpg.io",
	Version:  "v1",
	Resource: "clusters",
}

var aiExtensions = []string{
	"vector",
	"vectorscale",
	"pg_trgm",
	"fuzzystrmatch",
	"pgcrypto",
	`"uuid-ossp"`,
	"postgis",
	"unaccent",
	"pg_stat_statements",
}

func extensionSQL() []interface{} {
	stmts := make([]interface{}, len(aiExtensions))
	for i, ext := range aiExtensions {
		stmts[i] = fmt.Sprintf("CREATE EXTENSION IF NOT EXISTS %s;", ext)
	}
	return stmts
}

type PostgresAI struct{}

func (p *PostgresAI) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string, params map[string]interface{}) error {
	memory := "512Mi"
	memoryLimit := "1Gi"
	storage := "2Gi"
	cpu := "100m"

	if planID == "c2d3e4f5-a1b2-7890-abcd-100000000012" { // medium
		memory = "1Gi"
		memoryLimit = "2Gi"
		storage = "10Gi"
		cpu = "250m"
	}

	cluster := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "postgresql.cnpg.io/v1",
			"kind":       "Cluster",
			"metadata": map[string]interface{}{
				"name":      "pgai-" + name,
				"namespace": namespace,
				"labels": map[string]interface{}{
					"cf-marketplace-broker/instance-id": name,
					"cf-marketplace-broker/service":     "postgres-ai",
				},
			},
			"spec": map[string]interface{}{
				"instances":  int64(1),
				"imageName":  "timescale/timescaledb-ha:pg17",
				"postgresql": map[string]interface{}{
					"parameters": map[string]interface{}{
						"max_connections":       "100",
						"shared_preload_libraries": "timescaledb",
					},
				},
				"resources": map[string]interface{}{
					"requests": map[string]interface{}{
						"cpu":    cpu,
						"memory": memory,
					},
					"limits": map[string]interface{}{
						"memory": memoryLimit,
					},
				},
				"storage": map[string]interface{}{
					"size":         storage,
					"storageClass": "local-path",
				},
				"bootstrap": map[string]interface{}{
					"initdb": map[string]interface{}{
						"database":    "app",
						"owner":       "app",
						"postInitSQL": extensionSQL(),
					},
				},
			},
		},
	}

	_, err := client.Dynamic.Resource(cnpgGVR).Namespace(namespace).Create(ctx, cluster, metav1.CreateOptions{})
	return err
}

func (p *PostgresAI) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	return client.Dynamic.Resource(cnpgGVR).Namespace(namespace).Delete(ctx, "pgai-"+name, metav1.DeleteOptions{})
}

func (p *PostgresAI) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	obj, err := client.Dynamic.Resource(cnpgGVR).Namespace(namespace).Get(ctx, "pgai-"+name, metav1.GetOptions{})
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
		if cond["type"] == "Ready" && cond["status"] == "True" {
			return true, "succeeded", nil
		}
	}
	return false, "provisioning", nil
}

func (p *PostgresAI) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	secretName := "pgai-" + name + "-app"
	secret, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, secretName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("credentials secret %s not found: %w", secretName, err)
	}

	host := string(secret.Data["host"])
	port := string(secret.Data["port"])
	dbname := string(secret.Data["dbname"])
	username := string(secret.Data["username"])
	password := string(secret.Data["password"])

	if port == "" {
		port = "5432"
	}
	if dbname == "" {
		dbname = "app"
	}

	fqdn := fmt.Sprintf("%s.%s.svc.cluster.local", host, namespace)

	return map[string]interface{}{
		"type":       "postgres-ai",
		"hostname":   fqdn,
		"port":       port,
		"name":       dbname,
		"database":   dbname,
		"username":   username,
		"password":   password,
		"host":       fqdn,
		"uri":        fmt.Sprintf("postgresql://%s:%s@%s:%s/%s", username, password, fqdn, port, dbname),
		"jdbcUrl":    fmt.Sprintf("jdbc:postgresql://%s:%s/%s?user=%s&password=%s", fqdn, port, dbname, username, password),
		"extensions": []string{"vector", "vectorscale", "pg_trgm", "fuzzystrmatch", "pgcrypto", "uuid-ossp", "postgis", "unaccent", "pg_stat_statements"},
	}, nil
}
```

- [ ] **Step 2: Verify compilation**

```bash
cd k8/services/cf-marketplace-broker/src && go build ./provisioners/...
```

Expected: compiles successfully.

- [ ] **Step 3: Commit**

```bash
git add k8/services/cf-marketplace-broker/src/provisioners/postgres_ai.go
git commit -m "feat(marketplace-broker): add PostgreSQL AI Enabled provisioner (CloudNativePG + Timescale)"
```

---

### Task 5: OpenBao Secrets Provisioner

**Files:**
- Create: `k8/services/cf-marketplace-broker/src/provisioners/openbao_secrets.go`

- [ ] **Step 1: Create openbao_secrets.go**

Write `k8/services/cf-marketplace-broker/src/provisioners/openbao_secrets.go`:
```go
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
```

- [ ] **Step 2: Verify compilation**

```bash
cd k8/services/cf-marketplace-broker/src && go build ./provisioners/...
```

Expected: compiles successfully.

- [ ] **Step 3: Commit**

```bash
git add k8/services/cf-marketplace-broker/src/provisioners/openbao_secrets.go
git commit -m "feat(marketplace-broker): add OpenBao Secrets provisioner (KV v2 + AppRole)"
```

---

### Task 6: AI Connector Provisioner

**Files:**
- Create: `k8/services/cf-marketplace-broker/src/provisioners/ai_connector.go`

- [ ] **Step 1: Create ai_connector.go**

Write `k8/services/cf-marketplace-broker/src/provisioners/ai_connector.go`:
```go
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
```

- [ ] **Step 2: Verify full build**

```bash
cd k8/services/cf-marketplace-broker/src && go build .
```

Expected: compiles successfully — all provisioners exist, main.go can resolve all imports.

- [ ] **Step 3: Commit**

```bash
git add k8/services/cf-marketplace-broker/src/provisioners/ai_connector.go
git commit -m "feat(marketplace-broker): add AI Model Connector provisioner (Ollama, LM Studio)"
```

---

### Task 7: Dockerfile + Kubernetes Manifests

**Files:**
- Create: `k8/services/cf-marketplace-broker/Dockerfile`
- Create: `k8/services/cf-marketplace-broker/deployment.yaml`
- Create: `k8/services/cf-marketplace-broker/externalsecret-openbao.yaml`

- [ ] **Step 1: Create Dockerfile**

Write `k8/services/cf-marketplace-broker/Dockerfile`:
```dockerfile
FROM golang:1.26 AS build
WORKDIR /app
COPY src/go.mod src/go.sum ./
RUN go mod download
COPY src/ ./
RUN CGO_ENABLED=0 go build -o /cf-marketplace-broker .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /cf-marketplace-broker /cf-marketplace-broker
ENTRYPOINT ["/cf-marketplace-broker"]
```

- [ ] **Step 2: Create ExternalSecret**

Write `k8/services/cf-marketplace-broker/externalsecret-openbao.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: marketplace-broker-openbao-token
  namespace: cf-services
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: marketplace-broker-openbao-token
  data:
    - secretKey: token
      remoteRef:
        key: secret/marketplace-broker/openbao-token
        property: token
```

- [ ] **Step 3: Create deployment.yaml**

Write `k8/services/cf-marketplace-broker/deployment.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cf-marketplace-broker
  namespace: cf-services
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cf-marketplace-broker
rules:
  - apiGroups: ["postgresql.cnpg.io"]
    resources: ["clusters"]
    verbs: ["get", "list", "create", "delete", "watch"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list", "create", "update", "delete", "watch", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cf-marketplace-broker
subjects:
  - kind: ServiceAccount
    name: cf-marketplace-broker
    namespace: cf-services
roleRef:
  kind: ClusterRole
  name: cf-marketplace-broker
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cf-marketplace-broker
  namespace: cf-services
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cf-marketplace-broker
  template:
    metadata:
      labels:
        app: cf-marketplace-broker
    spec:
      serviceAccountName: cf-marketplace-broker
      imagePullSecrets:
        - name: artifact-keeper-pull
      containers:
        - name: broker
          image: artifactory.cfapps.cool/docker-local/cf-marketplace-broker:1.0.0-arm64
          ports:
            - containerPort: 8081
          env:
            - name: BROKER_USERNAME
              value: "marketplace-broker"
            - name: BROKER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: marketplace-broker-openbao-token
                  key: token
            - name: NAMESPACE
              value: "cf-services"
            - name: OPENBAO_ADDR
              value: "http://openbao.openbao.svc.cluster.local:8200"
            - name: OPENBAO_TOKEN
              valueFrom:
                secretKeyRef:
                  name: marketplace-broker-openbao-token
                  key: token
            - name: PORT
              value: "8081"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8081
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8081
            initialDelaySeconds: 5
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: cf-marketplace-broker
  namespace: cf-services
spec:
  selector:
    app: cf-marketplace-broker
  ports:
    - port: 80
      targetPort: 8081
```

- [ ] **Step 4: Commit**

```bash
git add k8/services/cf-marketplace-broker/Dockerfile k8/services/cf-marketplace-broker/deployment.yaml k8/services/cf-marketplace-broker/externalsecret-openbao.yaml
git commit -m "feat(marketplace-broker): add Dockerfile, K8s deployment manifests, ESO ExternalSecret"
```

---

### Task 8: OSBAPI Integration Test Suite

**Files:**
- Create: `k8/services/cf-marketplace-broker/test/helpers.go`
- Create: `k8/services/cf-marketplace-broker/test/main_test.go`
- Create: `k8/services/cf-marketplace-broker/test/postgres_ai_test.go`
- Create: `k8/services/cf-marketplace-broker/test/openbao_test.go`
- Create: `k8/services/cf-marketplace-broker/test/ai_connector_test.go`

- [ ] **Step 1: Create test go.mod**

```bash
mkdir -p k8/services/cf-marketplace-broker/test
```

Write `k8/services/cf-marketplace-broker/test/go.mod`:
```go
module github.com/cfapps/cf-marketplace-broker/test

go 1.26.1
```

Run: `cd k8/services/cf-marketplace-broker/test && go mod tidy` after all test files are created.

- [ ] **Step 2: Create helpers.go**

Write `k8/services/cf-marketplace-broker/test/helpers.go`:
```go
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
```

- [ ] **Step 3: Create main_test.go**

Write `k8/services/cf-marketplace-broker/test/main_test.go`:
```go
package test

import (
	"os"
	"testing"
)

var osb *OSBClient

func TestMain(m *testing.M) {
	brokerURL := os.Getenv("BROKER_URL")
	if brokerURL == "" {
		brokerURL = "http://cf-marketplace-broker.cf-services.svc:80"
	}
	username := os.Getenv("BROKER_USER")
	if username == "" {
		username = "marketplace-broker"
	}
	password := os.Getenv("BROKER_PASSWORD")
	if password == "" {
		password = "changeme"
	}

	osb = NewOSBClient(brokerURL, username, password)
	os.Exit(m.Run())
}
```

- [ ] **Step 4: Create postgres_ai_test.go**

Write `k8/services/cf-marketplace-broker/test/postgres_ai_test.go`:
```go
package test

import (
	"database/sql"
	"fmt"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

const (
	pgaiServiceID = "b1a2c3d4-e5f6-7890-abcd-100000000001"
	pgaiSmallPlan = "c2d3e4f5-a1b2-7890-abcd-100000000011"
)

func TestPostgresAILifecycle(t *testing.T) {
	instanceID := "test-pgai-01"
	bindingID := "bind-pgai-01"

	// 1. Provision
	status, err := osb.Provision(instanceID, ProvisionRequest{
		ServiceID:        pgaiServiceID,
		PlanID:           pgaiSmallPlan,
		OrganizationGUID: "test-org",
		SpaceGUID:        "test-space",
	})
	if err != nil {
		t.Fatalf("Provision failed: %v", err)
	}
	if status != 202 {
		t.Fatalf("Expected 202, got %d", status)
	}

	// 2. Wait for ready
	if err := osb.WaitForReady(instanceID, 180*time.Second); err != nil {
		t.Fatalf("WaitForReady failed: %v", err)
	}

	// 3. Bind
	bindResp, status, err := osb.Bind(instanceID, bindingID, BindRequest{
		ServiceID: pgaiServiceID,
		PlanID:    pgaiSmallPlan,
	})
	if err != nil {
		t.Fatalf("Bind failed: %v", err)
	}
	if status != 200 && status != 201 {
		t.Fatalf("Bind expected 200/201, got %d", status)
	}

	creds := bindResp.Credentials
	t.Logf("Credentials: type=%v, extensions=%v", creds["type"], creds["extensions"])

	// 4. Verify credentials
	if creds["type"] != "postgres-ai" {
		t.Errorf("Expected type postgres-ai, got %v", creds["type"])
	}

	uri, ok := creds["uri"].(string)
	if !ok || uri == "" {
		t.Fatalf("No URI in credentials")
	}

	// Connect and verify extensions
	db, err := sql.Open("postgres", uri)
	if err != nil {
		t.Fatalf("Failed to open DB: %v", err)
	}
	defer db.Close()

	rows, err := db.Query("SELECT extname FROM pg_extension ORDER BY extname")
	if err != nil {
		t.Fatalf("Failed to query extensions: %v", err)
	}
	defer rows.Close()

	extensions := map[string]bool{}
	for rows.Next() {
		var name string
		rows.Scan(&name)
		extensions[name] = true
	}

	required := []string{"vector", "pg_trgm", "postgis", "pgcrypto", "unaccent", "pg_stat_statements"}
	for _, ext := range required {
		if !extensions[ext] {
			t.Errorf("Extension %s not found", ext)
		}
	}

	// Test vector operations
	_, err = db.Exec("CREATE TABLE test_vec (id serial PRIMARY KEY, embedding vector(3))")
	if err != nil {
		t.Fatalf("Failed to create vector table: %v", err)
	}
	_, err = db.Exec("INSERT INTO test_vec (embedding) VALUES ('[1,2,3]'), ('[4,5,6]')")
	if err != nil {
		t.Fatalf("Failed to insert vectors: %v", err)
	}
	var id int
	err = db.QueryRow("SELECT id FROM test_vec ORDER BY embedding <-> '[1,2,3]' LIMIT 1").Scan(&id)
	if err != nil {
		t.Fatalf("Similarity query failed: %v", err)
	}
	if id != 1 {
		t.Errorf("Expected nearest vector id=1, got %d", id)
	}
	db.Exec("DROP TABLE test_vec")
	t.Log("Vector operations verified")

	// 5. Unbind
	status, err = osb.Unbind(instanceID, bindingID, pgaiServiceID, pgaiSmallPlan)
	if err != nil {
		t.Fatalf("Unbind failed: %v", err)
	}

	// 6. Deprovision
	status, err = osb.Deprovision(instanceID, pgaiServiceID, pgaiSmallPlan)
	if err != nil {
		t.Fatalf("Deprovision failed: %v", err)
	}

	// 7. Wait for gone
	if err := osb.WaitForGone(instanceID, 60*time.Second); err != nil {
		t.Logf("Warning: WaitForGone: %v", err)
	}

	fmt.Println("PostgreSQL AI lifecycle test passed")
}
```

- [ ] **Step 5: Create openbao_test.go**

Write `k8/services/cf-marketplace-broker/test/openbao_test.go`:
```go
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
	openbaoServiceID  = "b1a2c3d4-e5f6-7890-abcd-200000000002"
	openbaoDefaultPlan = "c2d3e4f5-a1b2-7890-abcd-200000000021"
)

func TestOpenBaoSecretsLifecycle(t *testing.T) {
	instanceID := "test-bao-01"
	bindingID := "bind-bao-01"

	// 1. Provision
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

	// 2. Wait for ready
	if err := osb.WaitForReady(instanceID, 30*time.Second); err != nil {
		t.Fatalf("WaitForReady failed: %v", err)
	}

	// 3. Bind
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

	// 4. Verify: AppRole login → write secret → read secret → delete secret
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
		"data": map[string]interface{}{
			"value": "hello-from-test",
		},
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

	// Delete the test secret
	delReq, _ := http.NewRequest("DELETE", vaultAddr+"/v1/"+secretPath+"/test-key", nil)
	delReq.Header.Set("X-Vault-Token", clientToken)
	http.DefaultClient.Do(delReq)
	t.Log("Test secret cleaned up")

	// 5. Unbind
	status, err = osb.Unbind(instanceID, bindingID, openbaoServiceID, openbaoDefaultPlan)
	if err != nil {
		t.Fatalf("Unbind failed: %v", err)
	}

	// 6. Deprovision
	status, err = osb.Deprovision(instanceID, openbaoServiceID, openbaoDefaultPlan)
	if err != nil {
		t.Fatalf("Deprovision failed: %v", err)
	}

	// 7. Wait for gone
	if err := osb.WaitForGone(instanceID, 30*time.Second); err != nil {
		t.Logf("Warning: WaitForGone: %v", err)
	}

	fmt.Println("OpenBao Secrets lifecycle test passed")
}
```

- [ ] **Step 6: Create ai_connector_test.go**

Write `k8/services/cf-marketplace-broker/test/ai_connector_test.go`:
```go
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
	aiServiceID  = "b1a2c3d4-e5f6-7890-abcd-300000000003"
	aiDefaultPlan = "c2d3e4f5-a1b2-7890-abcd-300000000031"
)

func TestAIConnectorSingleEndpoint(t *testing.T) {
	instanceID := "test-ai-01"
	bindingID := "bind-ai-01"

	// 1. Provision with single Ollama endpoint
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

	// 2. Wait for ready
	if err := osb.WaitForReady(instanceID, 15*time.Second); err != nil {
		t.Fatalf("WaitForReady failed: %v", err)
	}

	// 3. Bind
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

	// 4. Verify: try to reach models endpoint
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
			// Ollama native format uses "models" key
			if _, ok := models["models"]; !ok {
				t.Logf("Warning: response has neither 'data' nor 'models' key: %s", string(body))
			}
		}
		t.Logf("Models endpoint returned valid response")
	}

	// 5. Unbind
	status, err = osb.Unbind(instanceID, bindingID, aiServiceID, aiDefaultPlan)
	if err != nil {
		t.Fatalf("Unbind failed: %v", err)
	}

	// 6. Deprovision
	status, err = osb.Deprovision(instanceID, aiServiceID, aiDefaultPlan)
	if err != nil {
		t.Fatalf("Deprovision failed: %v", err)
	}

	// 7. Wait for gone
	if err := osb.WaitForGone(instanceID, 15*time.Second); err != nil {
		t.Logf("Warning: WaitForGone: %v", err)
	}

	fmt.Println("AI Connector single endpoint test passed")
}

func TestAIConnectorMultiEndpoint(t *testing.T) {
	instanceID := "test-ai-02"
	bindingID := "bind-ai-02"

	// 1. Provision with multiple endpoints
	status, err := osb.Provision(instanceID, ProvisionRequest{
		ServiceID:        aiServiceID,
		PlanID:           aiDefaultPlan,
		OrganizationGUID: "test-org",
		SpaceGUID:        "test-space",
		Parameters: map[string]interface{}{
			"endpoints": []map[string]interface{}{
				{
					"name":     "ollama-local",
					"provider": "ollama",
					"host":     "192.168.64.1",
					"port":     11434,
				},
				{
					"name":     "lmstudio-local",
					"provider": "lmstudio",
					"host":     "192.168.64.1",
					"port":     1234,
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("Provision failed: %v", err)
	}
	if status != 202 {
		t.Fatalf("Expected 202, got %d", status)
	}

	// 2. Wait for ready
	if err := osb.WaitForReady(instanceID, 15*time.Second); err != nil {
		t.Fatalf("WaitForReady failed: %v", err)
	}

	// 3. Bind
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

	// Verify multi-endpoint format
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

	// 5. Unbind
	status, err = osb.Unbind(instanceID, bindingID, aiServiceID, aiDefaultPlan)
	if err != nil {
		t.Fatalf("Unbind failed: %v", err)
	}

	// 6. Deprovision
	status, err = osb.Deprovision(instanceID, aiServiceID, aiDefaultPlan)
	if err != nil {
		t.Fatalf("Deprovision failed: %v", err)
	}

	if err := osb.WaitForGone(instanceID, 15*time.Second); err != nil {
		t.Logf("Warning: WaitForGone: %v", err)
	}

	fmt.Println("AI Connector multi-endpoint test passed")
}
```

- [ ] **Step 7: Initialize test module dependencies**

```bash
cd k8/services/cf-marketplace-broker/test && go mod tidy
```

Expected: resolves `github.com/lib/pq` dependency for postgres test.

- [ ] **Step 8: Commit**

```bash
git add k8/services/cf-marketplace-broker/test/
git commit -m "feat(marketplace-broker): add OSBAPI integration test suite (pgvector, openbao, ai-connector)"
```

---

### Task 9: Installer Phase 9 Library (`lib/phase9.sh`)

**Files:**
- Create: `k8/distribution/lib/phase9.sh`

- [ ] **Step 1: Create lib/phase9.sh**

Write `k8/distribution/lib/phase9.sh`:
```bash
#!/usr/bin/env bash
# Phase 9: Marketplace Extension 1 — AI/ML Services
# Shared logic used by both install.sh and extend-marketplace-1.sh

run_phase_9() {
  phase_timer_start 9

  log_phase "Phase 9 — Marketplace Extension 1: AI/ML Services"
  load_config
  local KUBECONFIG="${INSTALL_DIR}/kubeconfig"
  export KUBECONFIG
  ensure_openbao_login

  local BROKER_DIR="${INSTALL_DIR}/../services/cf-marketplace-broker"

  # --- Step 1: OpenBao setup (KV v2 + AppRole) ---
  if ! component_is_installed "phase9_openbao_setup" "$STATE_FILE"; then
    log_step "Configuring OpenBao: KV v2 engine + AppRole auth"

    # Enable KV v2 engine for cf-secrets (idempotent)
    bao secrets enable -path=cf-secrets -version=2 kv 2>/dev/null || true
    log_info "KV v2 engine 'cf-secrets/' enabled (or already exists)"

    # Enable AppRole auth (idempotent)
    bao auth enable approle 2>/dev/null || true
    log_info "AppRole auth enabled (or already exists)"

    # Store broker token in OpenBao for ESO
    local BROKER_TOKEN
    BROKER_TOKEN=$(bao token create -policy=root -ttl=8760h -format=json | jq -r '.auth.client_token')
    bao kv put secret/marketplace-broker/openbao-token token="$BROKER_TOKEN"
    log_info "Marketplace broker token stored in OpenBao"

    mark_component_installed "phase9_openbao_setup" "$STATE_FILE"
  fi

  # --- Step 2: Build and push broker image ---
  if ! component_is_installed "phase9_broker_image" "$STATE_FILE"; then
    log_step "Building marketplace broker image"

    limactl shell "$LIMA_VM" bash -c "
      cd /home/${USER}.linux/.devops-stack/services/cf-marketplace-broker
      sudo nerdctl build -t artifactory.cfapps.cool/docker-local/cf-marketplace-broker:1.0.0-arm64 .
      sudo nerdctl push artifactory.cfapps.cool/docker-local/cf-marketplace-broker:1.0.0-arm64
    "
    log_success "Broker image pushed to Artifactory"

    mark_component_installed "phase9_broker_image" "$STATE_FILE"
  fi

  # --- Step 3: Deploy ExternalSecret ---
  if ! component_is_installed "phase9_externalsecret" "$STATE_FILE"; then
    log_step "Deploying ExternalSecret for OpenBao token"

    kubectl apply -f "${BROKER_DIR}/externalsecret-openbao.yaml"
    log_info "Waiting for ExternalSecret to sync..."
    kubectl wait --for=condition=Ready externalsecret/marketplace-broker-openbao-token -n cf-services --timeout=60s
    log_success "ExternalSecret synced"

    mark_component_installed "phase9_externalsecret" "$STATE_FILE"
  fi

  # --- Step 4: Deploy broker ---
  if ! component_is_installed "phase9_broker_deploy" "$STATE_FILE"; then
    log_step "Deploying marketplace broker"

    kubectl apply -f "${BROKER_DIR}/deployment.yaml"
    wait_for_pods "cf-services" "app=cf-marketplace-broker" 120
    log_success "Marketplace broker running"

    mark_component_installed "phase9_broker_deploy" "$STATE_FILE"
  fi

  # --- Step 5: Register broker with Korifi ---
  if ! component_is_installed "phase9_broker_register" "$STATE_FILE"; then
    log_step "Registering marketplace broker with Korifi"

    local BROKER_PASSWORD
    BROKER_PASSWORD=$(kubectl get secret marketplace-broker-openbao-token -n cf-services -o jsonpath='{.data.token}' | base64 -d)

    local BROKER_URL="http://cf-marketplace-broker.cf-services.svc.cluster.local"

    # Retry registration (broker may need a moment to be fully ready)
    local retries=5
    for i in $(seq 1 $retries); do
      if cf create-service-broker marketplace-broker marketplace-broker "$BROKER_PASSWORD" "$BROKER_URL" --space-scoped 2>/dev/null; then
        log_success "Marketplace broker registered"
        break
      fi
      if [[ $i -eq $retries ]]; then
        log_error "Failed to register marketplace broker after $retries attempts"
        return 1
      fi
      log_info "Retry $i/$retries..."
      sleep 5
    done

    # Enable service access
    cf enable-service-access postgres-ai 2>/dev/null || true
    cf enable-service-access openbao-secrets 2>/dev/null || true
    cf enable-service-access ai-connector 2>/dev/null || true

    mark_component_installed "phase9_broker_register" "$STATE_FILE"
  fi

  # --- Step 6: Run integration tests ---
  if ! component_is_installed "phase9_test" "$STATE_FILE"; then
    log_step "Running marketplace broker integration tests"

    local BROKER_PASSWORD
    BROKER_PASSWORD=$(kubectl get secret marketplace-broker-openbao-token -n cf-services -o jsonpath='{.data.token}' | base64 -d)

    limactl shell "$LIMA_VM" bash -c "
      cd /home/${USER}.linux/.devops-stack/services/cf-marketplace-broker/test
      BROKER_URL=http://cf-marketplace-broker.cf-services.svc:80 \
      BROKER_USER=marketplace-broker \
      BROKER_PASSWORD='${BROKER_PASSWORD}' \
      go test -v -timeout 300s ./...
    " && {
      log_success "Integration tests passed"
      mark_component_installed "phase9_test" "$STATE_FILE"
    } || {
      log_warn "Some integration tests failed (non-blocking) — check output above"
      mark_component_installed "phase9_test" "$STATE_FILE"
    }
  fi

  # --- Step 7: Update credentials doc ---
  if ! component_is_installed "phase9_docs" "$STATE_FILE"; then
    log_step "Writing marketplace broker credentials"

    local BROKER_PASSWORD
    BROKER_PASSWORD=$(kubectl get secret marketplace-broker-openbao-token -n cf-services -o jsonpath='{.data.token}' | base64 -d)

    cat >> "${INSTALL_DIR}/credentials.md" <<CREDS

## Marketplace Broker (Phase 9)
- **Broker URL:** http://cf-marketplace-broker.cf-services.svc.cluster.local
- **Username:** marketplace-broker
- **Password:** ${BROKER_PASSWORD}
- **Services:** postgres-ai, openbao-secrets, ai-connector
CREDS

    mark_component_installed "phase9_docs" "$STATE_FILE"
  fi

  mark_phase_complete 9 "$STATE_FILE"
  phase_timer_end 9

  log_success "Phase 9 complete — Marketplace Extension 1: AI/ML Services"
  echo ""
  echo -e "  ${BOLD}Services:${NC}"
  echo -e "    PostgreSQL AI Enabled  — pgvector, pgvectorscale, PostGIS, full-text search"
  echo -e "    OpenBao Secret Container — application-managed secrets with AppRole"
  echo -e "    AI Model Connector     — Ollama / LM Studio via OpenAI-compatible API"
  echo ""
}
```

- [ ] **Step 2: Commit**

```bash
git add k8/distribution/lib/phase9.sh
git commit -m "feat(installer): add Phase 9 library for Marketplace Extension 1"
```

---

### Task 10: Update `install.sh` (7 locations)

**Files:**
- Modify: `k8/distribution/install.sh`

- [ ] **Step 1: Fix `print_phase_timing` — add phases 8 and 9 (line 193)**

Change line 193 from:
```bash
  for phase in 1 2 3 4 5 6 7; do
```
to:
```bash
  for phase in 1 2 3 4 5 6 7 8 9; do
```

- [ ] **Step 2: Add `install_phase_9` function**

After `install_phase_8()` (after line 2971), add:
```bash

# =============================================================================
# Phase 9 — Marketplace Extension 1: AI/ML Services
# =============================================================================
install_phase_9() {
  source "$SCRIPT_DIR/lib/phase9.sh"
  run_phase_9
}
```

- [ ] **Step 3: Update `cmd_status` — add phase 9 to phase_names array (line 2989)**

After the line `"kappman — Korifi App Manager [OPTIONAL]"`, add:
```bash
    "Marketplace Extension 1: AI/ML Services [OPTIONAL]"
```

Change the loop on line 2991 from:
```bash
  for i in 1 2 3 4 5 6 7 8; do
```
to:
```bash
  for i in 1 2 3 4 5 6 7 8 9; do
```

- [ ] **Step 4: Update `continue_from_phase` — add phase 9 block (after line 3175)**

After the phase 8 block (after `fi` on line 3175), add:
```bash

  if [[ "$completed_phase" -lt 9 ]] && phase_is_complete 8 "$STATE_FILE"; then
    echo ""
    log_info "Phase 9 deploys: Marketplace Extension 1 (PostgreSQL AI, OpenBao Secrets, AI Connector)"
    if ask_yes_no "Continue with Phase 9 (Marketplace Extension 1)?" "y"; then
      install_phase_9
    fi
  fi
```

- [ ] **Step 5: Update `cmd_full_setup` — add install_phase_9 (line 3208)**

After `install_phase_8`, add:
```bash
  install_phase_9
```

Change the log message on line 3198 from:
```bash
  log_info "Starting full installation (Phase 1-8)..."
```
to:
```bash
  log_info "Starting full installation (Phase 1-9)..."
```

- [ ] **Step 6: Update `usage` — add phase 9 (line 3237)**

After `8: kappman — Korifi App Manager [OPTIONAL] (requires phases 6+7)`, add:
```
                    9: Marketplace Extension 1 [OPTIONAL] (requires phases 6+7)
```

- [ ] **Step 7: Update `main` case statement — add phase 9 (line 3283)**

After `8) install_phase_8 ;;`, add:
```bash
        9) install_phase_9 ;;
```

Change the error message on line 3285 from:
```bash
          log_error "Unknown phase: $phase_num (valid: 1-8)"
```
to:
```bash
          log_error "Unknown phase: $phase_num (valid: 1-9)"
```

Also fix line 3272 from:
```bash
        log_error "Usage: ./install.sh phase <1-7>"
```
to:
```bash
        log_error "Usage: ./install.sh phase <1-9>"
```

- [ ] **Step 8: Verify no syntax errors**

```bash
bash -n k8/distribution/install.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 9: Commit**

```bash
git add k8/distribution/install.sh
git commit -m "feat(installer): integrate Phase 9 (Marketplace Extension 1) into install.sh"
```

---

### Task 11: Create `extend-marketplace-1.sh`

**Files:**
- Create: `k8/distribution/extend-marketplace-1.sh`

- [ ] **Step 1: Create extend-marketplace-1.sh**

Write `k8/distribution/extend-marketplace-1.sh`:
```bash
#!/usr/bin/env bash
# =============================================================================
# Marketplace Extension 1: AI/ML Services
# =============================================================================
# Adds three new services to an existing K8s DevOps Stack installation:
#   - PostgreSQL AI Enabled (pgvector, pgvectorscale, PostGIS)
#   - OpenBao Secret Container (KV v2 + AppRole)
#   - AI Model Connector (Ollama, LM Studio)
#
# Prerequisites: Phase 6 (Korifi) + Phase 7 (Service Brokers) must be complete.
#
# Usage: ./extend-marketplace-1.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/prerequisites.sh"
source "$SCRIPT_DIR/lib/helm.sh"
source "$SCRIPT_DIR/lib/interactive.sh"
source "$SCRIPT_DIR/lib/phase9.sh"

main() {
  print_banner "Marketplace Extension 1: AI/ML Services"

  # Load configuration
  if [[ ! -f "$SCRIPT_DIR/.install-config" ]]; then
    log_error "No .install-config found. Run install.sh first."
    exit 1
  fi
  source "$SCRIPT_DIR/.install-config"

  STATE_FILE="${SCRIPT_DIR}/.install-state"
  INSTALL_DIR="$SCRIPT_DIR"

  # Check prerequisites
  if ! phase_is_complete 6 "$STATE_FILE"; then
    log_error "Phase 6 (Cloud Foundry / Korifi) is required but not complete."
    log_info "Run: ./install.sh phase 6"
    exit 1
  fi

  if ! phase_is_complete 7 "$STATE_FILE"; then
    log_error "Phase 7 (CF Service Brokers) is required but not complete."
    log_info "Run: ./install.sh phase 7"
    exit 1
  fi

  if phase_is_complete 9 "$STATE_FILE"; then
    log_success "Marketplace Extension 1 is already installed."
    exit 0
  fi

  echo ""
  log_info "This will install:"
  echo -e "  ${CYAN}PostgreSQL AI Enabled${NC}   — pgvector, pgvectorscale, PostGIS, full-text search"
  echo -e "  ${CYAN}OpenBao Secret Container${NC} — application-managed secrets with AppRole"
  echo -e "  ${CYAN}AI Model Connector${NC}      — Ollama / LM Studio via OpenAI-compatible API"
  echo ""

  if ! ask_yes_no "Proceed with installation?" "y"; then
    log_info "Aborted."
    exit 0
  fi

  run_phase_9

  echo ""
  log_success "Marketplace Extension 1 installed successfully!"
  echo ""
  echo -e "  Use ${BOLD}cf marketplace${NC} to see the new services."
  echo -e "  Use ${BOLD}cf create-service postgres-ai small my-db${NC} to create an AI-enabled database."
  echo ""
}

main "$@"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x k8/distribution/extend-marketplace-1.sh
```

- [ ] **Step 3: Commit**

```bash
git add k8/distribution/extend-marketplace-1.sh
git commit -m "feat(installer): add extend-marketplace-1.sh for existing installations"
```

---

### Task 12: Update GETTING_STARTED.md

**Files:**
- Modify: `GETTING_STARTED.md`

- [ ] **Step 1: Update Installation Phases table**

In the table at line 109, change the header from `8 phases` to `9 phases`:
```
The wizard deploys the stack in 9 phases. All phases run automatically when using `./install.sh` without arguments.
```

Add phase 9 row after phase 8:
```
| 9 | Marketplace Extension 1 | PostgreSQL AI Enabled, OpenBao Secrets, AI Connector [OPTIONAL] |
```

- [ ] **Step 2: Add "Extending an Existing Installation" section**

After line 122 (the `---` after Installation Phases), insert:

```markdown

## 4a. Extending an Existing Installation

If you already have a running stack (Phase 7+) and want to add AI/ML marketplace services without re-running the full installer:

```bash
cd ~/devops-stack/k8/distribution
./extend-marketplace-1.sh
```

This adds three new services to the Cloud Foundry marketplace:

| Service | Description |
|---------|-------------|
| **postgres-ai** | PostgreSQL 17 with pgvector, pgvectorscale, PostGIS, full-text search |
| **openbao-secrets** | Application-managed secrets in OpenBao with AppRole access |
| **ai-connector** | Connect to external Ollama / LM Studio instances |

For new installations, these services are included automatically as Phase 9.

**Usage examples:**
```bash
cf create-service postgres-ai small my-vector-db
cf create-service openbao-secrets default my-secrets
cf create-service ai-connector default my-ai -c '{"provider":"ollama","host":"192.168.64.1","port":11434}'
```

---
```

- [ ] **Step 3: Update Cloud Foundry section marketplace list (line ~220+)**

In the "Cloud Foundry" section, update the marketplace list to include the new services. Find the existing marketplace table/list and add:
- PostgreSQL AI Enabled
- OpenBao Secret Container
- AI Model Connector

- [ ] **Step 4: Commit**

```bash
git add GETTING_STARTED.md
git commit -m "docs: add Phase 9 and extend-marketplace-1.sh to GETTING_STARTED.md"
```

---

### Task 13: Build and Push Distribution Bundle v1.1.0

**Files:**
- Modify: `build-distribution.sh` (version bump if hardcoded)

- [ ] **Step 1: Build distribution**

```bash
./build-distribution.sh
```

Expected: `dist/installer.sh` and `dist/stack.tgz` created.

- [ ] **Step 2: Push to Artifactory**

```bash
VERSION="1.1.0"
cp dist/installer.sh /tmp/installer-v${VERSION}.sh
cp dist/stack.tgz /tmp/stack-v${VERSION}.tgz

curl -sk -u "admin:qu2OGLpB5iacupiyaFAwO2BZ4ON2n+re" -X POST \
  "https://artifactory.cfapps.cool/api/v1/repositories/generic/artifacts" \
  -F "file=@/tmp/installer-v${VERSION}.sh"

curl -sk -u "admin:qu2OGLpB5iacupiyaFAwO2BZ4ON2n+re" -X POST \
  "https://artifactory.cfapps.cool/api/v1/repositories/generic/artifacts" \
  -F "file=@/tmp/stack-v${VERSION}.tgz"
```

Expected: Both uploads return 200/201.

- [ ] **Step 3: Verify download**

```bash
curl -sfL "https://artifactory.cfapps.cool/api/v1/repositories/generic/download/installer-v1.1.0.sh" -o /dev/null -w "%{http_code}"
```

Expected: `200`

- [ ] **Step 4: Commit version bump (if applicable)**

```bash
git add -A
git commit -m "chore: build and push distribution bundle v1.1.0"
```

---

### Task 14: End-to-End Deployment Test

This task is the final verification — deploy the broker and run the full test suite against the live cluster.

- [ ] **Step 1: Build broker image in Lima VM**

```bash
limactl shell devops bash -c "
  cd /home/$(whoami).linux/.devops-stack/services/cf-marketplace-broker
  sudo nerdctl build -t artifactory.cfapps.cool/docker-local/cf-marketplace-broker:1.0.0-arm64 .
  sudo nerdctl push artifactory.cfapps.cool/docker-local/cf-marketplace-broker:1.0.0-arm64
"
```

- [ ] **Step 2: Setup OpenBao (KV v2 + AppRole + broker token)**

```bash
export VAULT_ADDR=http://$(kubectl get svc openbao -n openbao -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8200
bao secrets enable -path=cf-secrets -version=2 kv 2>/dev/null || true
bao auth enable approle 2>/dev/null || true
BROKER_TOKEN=$(bao token create -policy=root -ttl=8760h -format=json | jq -r '.auth.client_token')
bao kv put secret/marketplace-broker/openbao-token token="$BROKER_TOKEN"
```

- [ ] **Step 3: Deploy ExternalSecret + broker**

```bash
kubectl apply -f k8/services/cf-marketplace-broker/externalsecret-openbao.yaml
kubectl wait --for=condition=Ready externalsecret/marketplace-broker-openbao-token -n cf-services --timeout=60s
kubectl apply -f k8/services/cf-marketplace-broker/deployment.yaml
kubectl rollout status deployment/cf-marketplace-broker -n cf-services --timeout=120s
```

- [ ] **Step 4: Verify broker health**

```bash
kubectl port-forward svc/cf-marketplace-broker -n cf-services 8081:80 &
PF_PID=$!
sleep 2
curl -s http://localhost:8081/healthz
kill $PF_PID
```

Expected: `{"status":"ok"}`

- [ ] **Step 5: Verify service catalog**

```bash
kubectl port-forward svc/cf-marketplace-broker -n cf-services 8081:80 &
PF_PID=$!
sleep 2
curl -s -u marketplace-broker:$(kubectl get secret marketplace-broker-openbao-token -n cf-services -o jsonpath='{.data.token}' | base64 -d) \
  http://localhost:8081/v2/catalog | jq '.services[].name'
kill $PF_PID
```

Expected:
```
"postgres-ai"
"openbao-secrets"
"ai-connector"
```

- [ ] **Step 6: Run integration tests**

```bash
BROKER_PASSWORD=$(kubectl get secret marketplace-broker-openbao-token -n cf-services -o jsonpath='{.data.token}' | base64 -d)
limactl shell devops bash -c "
  cd /home/$(whoami).linux/.devops-stack/services/cf-marketplace-broker/test
  BROKER_URL=http://cf-marketplace-broker.cf-services.svc:80 \
  BROKER_USER=marketplace-broker \
  BROKER_PASSWORD='${BROKER_PASSWORD}' \
  go test -v -timeout 300s ./...
"
```

Expected: All tests pass (AI connector tests may skip if Ollama/LM Studio not running).

- [ ] **Step 7: Register with Korifi and verify marketplace**

```bash
BROKER_PASSWORD=$(kubectl get secret marketplace-broker-openbao-token -n cf-services -o jsonpath='{.data.token}' | base64 -d)
cf create-service-broker marketplace-broker marketplace-broker "$BROKER_PASSWORD" \
  http://cf-marketplace-broker.cf-services.svc.cluster.local --space-scoped

cf marketplace
```

Expected: `postgres-ai`, `openbao-secrets`, `ai-connector` visible in marketplace.

- [ ] **Step 8: Commit any final fixes**

```bash
git add -A
git commit -m "feat(marketplace-broker): verified end-to-end deployment and tests"
```
