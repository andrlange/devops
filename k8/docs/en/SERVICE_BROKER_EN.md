# CF Service Broker — Setup and Usage

## Overview

The CF Service Broker is a custom OSBAPI v2-compatible service broker (Go) that exposes three Kubernetes operators as Cloud Foundry Marketplace services. Developers can consume services just like on a VM-based CF platform (Tanzu Application Service / PCF):

```bash
cf marketplace
cf create-service postgresql small my-db
cf bind-service my-app my-db
```

### Architecture

```
  Developer (cf CLI)
       │
       ▼
  Korifi API (api.app.cfapps.cool)
       │
       │  OSBAPI v2 (HTTP)
       ▼
  ┌─────────────────────────────────────────────────────┐
  │  Universal Service Broker                           │
  │  (cf-services Namespace)                            │
  │                                                     │
  │  /v2/catalog          → Service Catalog             │
  │  /v2/service_instances → Provision / Deprovision    │
  │  /v2/service_bindings  → Bind / Unbind              │
  │                                                     │
  │  Provisioners:                                      │
  │   postgresql → CloudNativePG Cluster CRD            │
  │   valkey     → StatefulSet + Service + Secret       │
  │   rabbitmq   → RabbitmqCluster CRD                  │
  └─────────────────────────────────────────────────────┘
       │              │              │
       ▼              ▼              ▼
  CloudNativePG    Valkey Pod    RabbitMQ Cluster
  Operator         (direct)      Operator
  (cnpg-system)                  (rabbitmq-system)
```

### Components

| Component | Version | Namespace | Description |
|-----------|---------|-----------|-------------|
| CF Service Broker | 1.2.0 | cf-services | Go OSBAPI Broker (pivotal-cf/brokerapi v11) |
| CloudNativePG | 1.28.1 | cnpg-system | PostgreSQL Operator (Helm) |
| RabbitMQ Cluster Operator | 2.19.2 | rabbitmq-system | RabbitMQ Operator (kubectl apply) |
| Valkey | 8.1 | cf-services | Deployed directly via StatefulSet (no operator) |

---

## Part 1: Setup

### 1.1 Prerequisites

- Phases 1-6 fully deployed (Korifi running)
- `experimental.managedServices.enabled=true` in Korifi Helm Values (enabled by default)
- OpenBao unsealed
- Go 1.24+ installed (`brew install go`)
- crane installed (`go install github.com/google/go-containerregistry/cmd/crane@latest`)

### 1.2 Install CloudNativePG Operator

CloudNativePG is the PostgreSQL operator. It manages PostgreSQL clusters as Kubernetes Custom Resources.

```bash
# Add Helm repo
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg

# Install the operator
helm install cnpg cnpg/cloudnative-pg \
  -n cnpg-system \
  --create-namespace

# Wait until the operator is ready
kubectl wait --for=condition=Available deploy -n cnpg-system \
  -l app.kubernetes.io/name=cloudnative-pg --timeout=120s
```

**Validation:**

```bash
kubectl get pods -n cnpg-system
# cnpg-cloudnative-pg-xxx   1/1   Running

kubectl get crd | grep cnpg
# clusters.postgresql.cnpg.io
# poolers.postgresql.cnpg.io
# scheduledbackups.postgresql.cnpg.io
```

### 1.3 Install RabbitMQ Cluster Operator

The official RabbitMQ Cluster Operator manages RabbitMQ clusters as Custom Resources.

```bash
# Install the operator (official release manifests)
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

# Wait until the operator is ready
kubectl wait --for=condition=Available deploy/rabbitmq-cluster-operator \
  -n rabbitmq-system --timeout=120s
```

**Validation:**

```bash
kubectl get pods -n rabbitmq-system
# rabbitmq-cluster-operator-xxx   1/1   Running

kubectl get crd | grep rabbitmq
# rabbitmqclusters.rabbitmq.com
```

### 1.4 Valkey

No operator is installed for Valkey. The service broker manages Valkey instances directly as StatefulSets. The Valkey container image (`valkey/valkey:8.1-alpine`) is pulled automatically on the first `cf create-service`.

### 1.5 Build the Service Broker

The broker is a Go binary compiled natively on the Mac (ARM64) and pushed as an OCI container image to the registry.

```bash
cd k8/services/cf-service-broker/src

# Download Go dependencies
go mod tidy

# Compile natively for ARM64
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o /tmp/cf-service-broker .

# Build and push the OCI image
export PATH="$HOME/go/bin:$PATH"
REGISTRY="artifactory.cfapps.cool/docker-local"
IMAGE="${REGISTRY}/cf-service-broker:1.2.0-arm64"
BASE="gcr.io/distroless/static:nonroot"

TMPDIR=$(mktemp -d)
mkdir -p "${TMPDIR}/app"
cp /tmp/cf-service-broker "${TMPDIR}/app/broker"
LAYER=$(mktemp)
(cd "${TMPDIR}" && tar cf "${LAYER}" app/)

crane append --base "${BASE}" --new_tag "${IMAGE}" --new_layer "${LAYER}" --platform linux/arm64
crane mutate "${IMAGE}" --entrypoint "/app/broker" --tag "${IMAGE}"
rm -rf "${TMPDIR}" "${LAYER}"
```

### 1.6 Configure Broker Credentials

The broker protects its OSBAPI endpoints with Basic Auth. The credentials are stored in OpenBao.

```bash
# Generate a random password
BROKER_PASS=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)

# Store in OpenBao
kubectl exec -n openbao openbao-0 -- bao kv put secret/cf-service-broker/auth \
  username="admin" password="${BROKER_PASS}"

# Note the password (needed for registration)
echo "Broker password: ${BROKER_PASS}"
```

### 1.7 Deploy the Broker

```bash
# Create the namespace
kubectl create namespace cf-services

# Pull secret for the container registry
kubectl -n cf-services create secret docker-registry artifact-keeper-pull \
  --docker-server="artifactory.cfapps.cool" \
  --docker-username="admin" \
  --docker-password="<REGISTRY_PASS>"

# Apply the deployment (update the password in deployment.yaml)
kubectl apply -f k8/services/cf-service-broker/deployment.yaml

# Wait until ready
kubectl wait --for=condition=Available deploy/cf-service-broker \
  -n cf-services --timeout=60s
```

**What gets deployed:**

| Resource | Name | Description |
|----------|------|-------------|
| ServiceAccount | cf-service-broker | Identity for K8s API access |
| ClusterRole | cf-service-broker | Permissions for operator CRDs, Secrets, StatefulSets |
| ClusterRoleBinding | cf-service-broker | Binding SA → ClusterRole |
| Deployment | cf-service-broker | Broker container (1 replica, 64Mi RAM) |
| Service | cf-service-broker | ClusterIP Service on port 80 → 8080 |

**Validation:**

```bash
# Is the broker pod running?
kubectl get pods -n cf-services -l app=cf-service-broker

# Health check
kubectl run --rm -it --restart=Never curl-test --image=curlimages/curl -- \
  curl -s http://cf-service-broker.cf-services.svc.cluster.local/healthz
# {"status":"ok"}

# Catalog endpoint (with auth)
kubectl run --rm -it --restart=Never curl-test --image=curlimages/curl -- \
  curl -s -u admin:<BROKER_PASS> \
  http://cf-service-broker.cf-services.svc.cluster.local/v2/catalog \
  -H "X-Broker-API-Version: 2.17"
```

### 1.8 Register the Broker with Korifi

```bash
# Log in as cf-admin
kubectl config use-context cf-admin
cf api https://api.app.cfapps.cool --skip-ssl-validation
cf login

# Register the broker
cf create-service-broker k8s-services admin <BROKER_PASS> \
  http://cf-service-broker.cf-services.svc.cluster.local

# Enable services for all orgs
cf enable-service-access postgresql
cf enable-service-access valkey
cf enable-service-access rabbitmq

# Verify the marketplace
cf marketplace
# offering     plans           description                                 broker
# postgresql   small, medium   PostgreSQL 18 via CloudNativePG             k8s-services
# valkey       small           Valkey (Redis-compatible) key-value store   k8s-services
# rabbitmq     small           RabbitMQ message broker                     k8s-services
```

---

## Part 2: Using Services

### 2.1 PostgreSQL

#### Create a Service

```bash
# Small plan (256Mi RAM, 1Gi Storage)
cf create-service postgresql small my-db

# Medium plan (512Mi RAM, 5Gi Storage)
cf create-service postgresql medium my-db-large

# Check status (wait until "create succeeded")
cf services
```

#### What Happens in the Cluster

The broker creates a CloudNativePG `Cluster` CRD in the `cf-services` namespace:

```bash
kubectl get clusters.postgresql.cnpg.io -n cf-services
# NAME          INSTANCES   READY   STATUS
# pg-xxxxxxxx   1           1       Cluster in healthy state
```

CloudNativePG automatically creates:
- A PostgreSQL pod (`pg-xxxxxxxx-1`)
- A read-write service (`pg-xxxxxxxx-rw`)
- A credentials secret (`pg-xxxxxxxx-app`)
- A database `app` with owner `app`

#### Bind to an App

```bash
# Directly in manifest.yml:
# services:
#   - my-db

# Or manually:
cf bind-service my-app my-db
cf restage my-app
```

#### Inspect Credentials

```bash
cf create-service-key my-db my-db-key
cf service-key my-db my-db-key
```

**Credentials format:**

```json
{
  "hostname": "pg-xxxxxxxx-rw",
  "port": "5432",
  "name": "app",
  "username": "app",
  "password": "...",
  "uri": "postgres://app:...@pg-xxxxxxxx-rw:5432/app",
  "jdbcUrl": "jdbc:postgresql://pg-xxxxxxxx-rw:5432/app?user=app&password=..."
}
```

#### Spring Boot Integration

`java-cfenv-boot` automatically detects PostgreSQL from `VCAP_SERVICES`:

```xml
<dependency>
    <groupId>io.pivotal.cfenv</groupId>
    <artifactId>java-cfenv-boot</artifactId>
    <version>3.2.0</version>
</dependency>
```

No manual DataSource configuration required -- `spring.datasource.*` is set automatically.

---

### 2.2 Valkey (Redis-Compatible)

#### Create a Service

```bash
cf create-service valkey small my-cache
cf services  # wait until "create succeeded"
```

#### What Happens in the Cluster

The broker creates directly (without an operator):
- A credentials secret (`valkey-xxxxxxxx-credentials`)
- A service (`valkey-xxxxxxxx`)
- A StatefulSet (`valkey-xxxxxxxx`) with Valkey 8.1

```bash
kubectl get statefulsets -n cf-services -l cf-service-broker/service=valkey
kubectl get svc -n cf-services -l cf-service-broker/service=valkey
```

#### Credentials

```bash
cf create-service-key my-cache my-cache-key
cf service-key my-cache my-cache-key
```

```json
{
  "hostname": "valkey-xxxxxxxx.cf-services.svc.cluster.local",
  "port": 6379,
  "password": "...",
  "uri": "redis://:...@valkey-xxxxxxxx.cf-services.svc.cluster.local:6379"
}
```

#### Spring Boot Integration

```properties
# application.yml (set automatically via java-cfenv-boot)
spring.data.redis.host=${vcap.services.my-cache.credentials.hostname}
spring.data.redis.port=${vcap.services.my-cache.credentials.port}
spring.data.redis.password=${vcap.services.my-cache.credentials.password}
```

**Note:** Valkey is fully Redis-compatible. All Redis clients (Jedis, Lettuce, Spring Data Redis) work without modification.

---

### 2.3 RabbitMQ

#### Create a Service

```bash
cf create-service rabbitmq small my-mq
cf services  # wait until "create succeeded"
```

#### What Happens in the Cluster

The broker creates a `RabbitmqCluster` CRD in the `cf-services` namespace:

```bash
kubectl get rabbitmqclusters -n cf-services
# NAME          ALLREPLICASREADY   RECONCILESUCCESS   AGE
# rmq-xxxxxxxx  True               True               5m
```

The RabbitMQ Operator automatically creates:
- A RabbitMQ pod (`rmq-xxxxxxxx-server-0`)
- A service (`rmq-xxxxxxxx`)
- A credentials secret (`rmq-xxxxxxxx-default-user`)
- The management plugin (port 15672)

#### Credentials

```bash
cf create-service-key my-mq my-mq-key
cf service-key my-mq my-mq-key
```

```json
{
  "hostname": "rmq-xxxxxxxx.cf-services.svc",
  "port": "5672",
  "username": "default_user_...",
  "password": "...",
  "uri": "amqp://user:pass@rmq-xxxxxxxx.cf-services.svc:5672",
  "http_api_uri": "http://user:pass@rmq-xxxxxxxx.cf-services.svc:15672/api",
  "vhost": "/"
}
```

#### Spring Boot Integration

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-amqp</artifactId>
</dependency>
```

`java-cfenv-boot` automatically sets `spring.rabbitmq.host`, `spring.rabbitmq.port`, `spring.rabbitmq.username`, `spring.rabbitmq.password`.

---

## Part 3: Common Operations

### Delete a Service

```bash
# First remove all bindings
cf unbind-service my-app my-db

# Then delete service keys
cf delete-service-key my-db my-db-key -f

# Delete the service
cf delete-service my-db -f
```

The broker deletes all associated K8s resources (CRD, pods, services, secrets, PVCs).

### List All Services

```bash
# In the current space
cf services

# Marketplace with plan details
cf marketplace -e postgresql
```

### Inspect Service Instances in the Cluster

```bash
# All provisioned instances
kubectl get all -n cf-services -l cf-service-broker/service

# PostgreSQL clusters
kubectl get clusters.postgresql.cnpg.io -n cf-services

# Valkey StatefulSets
kubectl get statefulsets -n cf-services -l cf-service-broker/service=valkey

# RabbitMQ clusters
kubectl get rabbitmqclusters -n cf-services

# Instance state (ConfigMap)
kubectl get configmap broker-instances -n cf-services -o yaml
```

### Check Broker Logs

```bash
kubectl logs -n cf-services -l app=cf-service-broker --tail=20
```

### Update the Broker

After code changes to the broker:

```bash
# 1. Recompile
cd k8/services/cf-service-broker/src
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o /tmp/cf-service-broker .

# 2. Build and push new image (increment the tag)
# ... (see Section 1.5)

# 3. Update the deployment
kubectl set image -n cf-services deploy/cf-service-broker \
  broker=artifactory.cfapps.cool/docker-local/cf-service-broker:<new-tag>

# 4. Wait for the rollout
kubectl rollout status deploy/cf-service-broker -n cf-services
```

### Re-register the Broker

If the broker catalog has changed (e.g., new plans added):

```bash
cf update-service-broker k8s-services admin <BROKER_PASS> \
  http://cf-service-broker.cf-services.svc.cluster.local
```

---

## Part 4: Troubleshooting

### Service Stays on "create in progress"

```bash
# Check broker logs
kubectl logs -n cf-services -l app=cf-service-broker --tail=20

# Check CRD status (example: PostgreSQL)
kubectl describe clusters.postgresql.cnpg.io -n cf-services

# Common causes:
# - Operator not installed (CRD does not exist)
# - No storage available (PVC pending)
# - Image pull error (registry unreachable)
```

### Bind Fails

```bash
# Check credentials secret
kubectl get secrets -n cf-services | grep credentials

# PostgreSQL: secret is named pg-<id>-app
# Valkey: secret is named valkey-<id>-credentials
# RabbitMQ: secret is named rmq-<id>-default-user

# If the secret does not exist: the service is not yet ready
cf services  # must show "create succeeded"
```

### Deprovision Fails

```bash
# Manual cleanup
kubectl delete clusters.postgresql.cnpg.io -n cf-services <name>
kubectl delete rabbitmqclusters -n cf-services <name>
kubectl delete statefulset,svc,secret -n cf-services -l cf-service-broker/instance-id=<id>
kubectl delete pvc -n cf-services -l cf-service-broker/instance-id=<id>

# Clean up ConfigMap entry
kubectl edit configmap broker-instances -n cf-services
# Remove the corresponding entry
```

### Marketplace is Empty

```bash
# Check broker registration
cf service-brokers
# k8s-services   http://cf-service-broker.cf-services.svc.cluster.local

# Check service access
cf service-access
# All services must show "all" in the "access" column

# If broker is not registered:
cf create-service-broker k8s-services admin <PASS> \
  http://cf-service-broker.cf-services.svc.cluster.local
cf enable-service-access postgresql
cf enable-service-access valkey
cf enable-service-access rabbitmq
```

---

## Part 5: Broker Internals

### OSBAPI Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /v2/catalog | Service catalog (services + plans) |
| PUT | /v2/service_instances/:id | Provision (async, 202 Accepted) |
| DELETE | /v2/service_instances/:id | Deprovision |
| GET | /v2/service_instances/:id/last_operation | Status polling (provisioning → succeeded) |
| PUT | /v2/service_instances/:id/service_bindings/:bid | Bind (sync, returns credentials) |
| DELETE | /v2/service_instances/:id/service_bindings/:bid | Unbind (no-op) |
| GET | /healthz | Health check (no auth required) |

### Provision Flow

1. Korifi sends `PUT /v2/service_instances/:id` with `service_id` and `plan_id`
2. Broker identifies the provisioner (PostgreSQL, Valkey, or RabbitMQ)
3. Provisioner creates K8s resources in the `cf-services` namespace:
   - PostgreSQL: `Cluster` CRD (CloudNativePG)
   - Valkey: `Secret` + `Service` + `StatefulSet`
   - RabbitMQ: `RabbitmqCluster` CRD
4. Broker stores instance state in ConfigMap `broker-instances`
5. Broker returns `202 Accepted` (asynchronous)
6. Korifi polls `GET /v2/service_instances/:id/last_operation`
7. Broker checks CRD/StatefulSet status conditions
8. Once ready: returns `succeeded`

### Bind Flow

1. Korifi sends `PUT /v2/service_instances/:id/service_bindings/:bid`
2. Broker reads the operator's credentials secret:
   - PostgreSQL: `pg-<id>-app` (created by CloudNativePG)
   - Valkey: `valkey-<id>-credentials` (created by the broker)
   - RabbitMQ: `rmq-<id>-default-user` (created by the RabbitMQ Operator)
3. Broker constructs the credentials map and returns it
4. Korifi injects the credentials into the app's `VCAP_SERVICES`

### Instance State

The broker stores the state of all provisioned instances in a ConfigMap:

```bash
kubectl get configmap broker-instances -n cf-services -o yaml
```

Each entry is a JSON object:

```json
{
  "service_id": "d1a5c0f2-7b3e-4a1d-9c8f-0e2b4a6d8c1e",
  "plan_id": "a1b2c3d4-1111-1111-1111-000000000001",
  "name": "43d87a1e",
  "namespace": "cf-services"
}
```

### Go Source Code

The broker source code is located in `k8/services/cf-service-broker/src/`:

| File | Description |
|------|-------------|
| `main.go` | HTTP server, brokerapi.New(), /healthz endpoint |
| `broker/broker.go` | ServiceBroker interface (Provision, Bind, Deprovision, LastOperation) |
| `broker/catalog.go` | Service catalog with service IDs, plan IDs, and descriptions |
| `broker/state.go` | ConfigMap-based instance management (CRUD) |
| `provisioners/provisioner.go` | Provisioner interface |
| `provisioners/postgresql.go` | Create/delete/check CloudNativePG Cluster CRD |
| `provisioners/valkey.go` | Create/delete StatefulSet + Service + Secret |
| `provisioners/rabbitmq.go` | Create/delete/check RabbitmqCluster CRD |
| `k8s/client.go` | Kubernetes Dynamic + Typed Client initialization |

### Adding a New Service

To add another service (e.g., MongoDB):

1. Create a new provisioner in `provisioners/mongodb.go` (implement the interface)
2. Add service and plan IDs in `broker/catalog.go`
3. Register the provisioner in `broker/broker.go` (`b.provisioners[MongoDBServiceID] = ...`)
4. Recompile and deploy the broker
5. Run `cf update-service-broker`
6. `cf enable-service-access mongodb`
