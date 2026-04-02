# Phase 7: CF Service Brokers

## Overview

**Goal:** Full Cloud Foundry service experience on Korifi — `cf marketplace`, `cf create-service`, `cf bind-service` for PostgreSQL, Valkey, and RabbitMQ.

A universal OSBAPI Service Broker (Go) interfaces with three K8s operators and exposes them as CF Marketplace services.

**Architecture:**

```
Developer Host                          Lima VM (K3s)
┌──────────┐                ┌────────────────────────────────────────────────┐
│          │                │                                                │
│  cf CLI ─┼── cf create ──▶│  Korifi API                                    │
│          │   -service     │       │                                        │
└──────────┘                │       ▼                                        │
                            │  ┌──────────────────────────────────────┐      │
                            │  │  CF Service Broker (OSBAPI v2)       │      │
                            │  │  cf-services Namespace               │      │
                            │  │                                      │      │
                            │  │  Services:                           │      │
                            │  │   postgresql → CloudNativePG CRD     │      │
                            │  │   valkey     → StatefulSet + Svc     │      │
                            │  │   rabbitmq   → RabbitmqCluster CRD   │      │
                            │  └──────────────────────────────────────┘      │
                            │       │              │              │          │
                            │       ▼              ▼              ▼          │
                            │  CloudNativePG   Valkey Pod    RabbitMQ        │
                            │  Operator        (direct)      Operator        │
                            │  (cnpg-system)                 (rabbitmq-      │
                            │                                 system)        │
                            └────────────────────────────────────────────────┘
```

## Prerequisites

- Phases 1-6 fully deployed
- Korifi with `experimental.managedServices.enabled=true` (already set)
- Go 1.24+ and crane on the host (for building the broker)

## Service Catalog

| Service | Plans | Description | Operator |
|---------|-------|-------------|----------|
| `postgresql` | small (256Mi, 1Gi), medium (512Mi, 5Gi) | PostgreSQL 18 via CloudNativePG | CloudNativePG |
| `valkey` | small (128Mi, 1Gi) | Valkey (Redis-compatible) key-value store | Direct (StatefulSet) |
| `rabbitmq` | small (256Mi, 1Gi) | RabbitMQ message broker | RabbitMQ Cluster Operator |

## Installation

### 7.1 Install Operators

```bash
# CloudNativePG
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace

# RabbitMQ Cluster Operator
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

# Valkey: no operator needed (broker manages directly)
```

### 7.2 Build Service Broker

```bash
cd k8/services/cf-service-broker/src

# Native compilation (ARM64)
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o /tmp/cf-service-broker .

# Build and push OCI image (same pattern as kpack)
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

### 7.3 Store Broker Credentials in OpenBao

```bash
BROKER_PASS=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)
kubectl exec -n openbao openbao-0 -- bao kv put secret/cf-service-broker/auth \
  username="admin" password="${BROKER_PASS}"
echo "Broker password: ${BROKER_PASS}"
```

### 7.4 Deploy Broker

```bash
kubectl create namespace cf-services
kubectl apply -f k8/services/cf-service-broker/deployment.yaml
kubectl wait --for=condition=Available deploy/cf-service-broker -n cf-services --timeout=60s
```

### 7.5 Register Broker with Korifi

```bash
kubectl config use-context cf-admin
cf create-service-broker k8s-services admin <BROKER_PASS> \
  http://cf-service-broker.cf-services.svc.cluster.local
cf enable-service-access postgresql
cf enable-service-access valkey
cf enable-service-access rabbitmq
```

### 7.6 Validation

```bash
# Check marketplace
cf marketplace
# offering     plans           description
# postgresql   small, medium   PostgreSQL 18 via CloudNativePG
# valkey       small           Valkey (Redis-compatible) key-value store
# rabbitmq     small           RabbitMQ message broker

# Provision a service
cf create-service postgresql small my-pg
cf create-service valkey small my-cache
cf create-service rabbitmq small my-mq

# Check status (wait until "create succeeded")
cf services

# Retrieve credentials
cf create-service-key my-pg my-pg-key
cf service-key my-pg my-pg-key

# Bind to an app
cf bind-service my-app my-pg
cf restage my-app
cf env my-app  # VCAP_SERVICES contains PostgreSQL credentials

# Clean up
cf delete-service my-pg -f
```

## Broker Implementation

### Go Package Structure

```
src/
├── main.go              # HTTP Server, /healthz, brokerapi.New()
├── broker/
│   ├── broker.go        # ServiceBroker interface (Provision/Bind/Deprovision)
│   ├── catalog.go       # Service catalog with plans
│   └── state.go         # ConfigMap-based instance management
├── provisioners/
│   ├── provisioner.go   # Interface
│   ├── postgresql.go    # CloudNativePG Cluster CRD
│   ├── valkey.go        # StatefulSet + Service + Secret
│   └── rabbitmq.go      # RabbitmqCluster CRD
└── k8s/
    └── client.go        # Dynamic + Typed K8s client
```

### OSBAPI Flows

**Provision (async):**
1. Broker receives `PUT /v2/service_instances/:id`
2. Creates operator CRD or K8s resources in `cf-services` namespace
3. Stores instance state in ConfigMap `broker-instances`
4. Returns `202 Accepted`
5. Korifi polls `GET /v2/service_instances/:id/last_operation`
6. Broker checks CRD status conditions until Ready

**Bind (sync):**
1. Broker receives `PUT /v2/service_instances/:id/service_bindings/:bid`
2. Reads credentials from operator-created Secret
3. Returns credentials (hostname, port, username, password, uri)

**Deprovision:**
1. Broker receives `DELETE /v2/service_instances/:id`
2. Deletes CRD/resources + PVCs
3. Removes instance from ConfigMap

### Credentials Format

**PostgreSQL:**
```json
{
  "hostname": "pg-xxx-rw",
  "port": "5432",
  "name": "app",
  "username": "app",
  "password": "...",
  "uri": "postgres://app:...@pg-xxx-rw:5432/app",
  "jdbcUrl": "jdbc:postgresql://pg-xxx-rw:5432/app?user=app&password=..."
}
```

**Valkey:**
```json
{
  "hostname": "valkey-xxx.cf-services.svc.cluster.local",
  "port": 6379,
  "password": "...",
  "uri": "redis://:...@valkey-xxx.cf-services.svc.cluster.local:6379"
}
```

**RabbitMQ:**
```json
{
  "hostname": "rmq-xxx.cf-services.svc",
  "port": "5672",
  "username": "...",
  "password": "...",
  "uri": "amqp://user:pass@rmq-xxx.cf-services.svc:5672",
  "http_api_uri": "http://user:pass@rmq-xxx.cf-services.svc:15672/api",
  "vhost": "/"
}
```

## Known Limitations

| Limitation | Details |
|------------|---------|
| Single-Node | All services run with 1 instance (dev setup) |
| No Plan Update | `cf update-service` is not supported |
| Valkey without Operator | Managed directly as StatefulSet, no HA |
| No Backups | Service instances are not automatically backed up |
| Fixed Namespace | All instances are created in `cf-services` |
