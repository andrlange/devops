# Phase 7: CF Service Brokers

## Uebersicht

**Ziel:** Vollstaendige Cloud Foundry Service-Erfahrung auf Korifi — `cf marketplace`, `cf create-service`, `cf bind-service` fuer PostgreSQL, Valkey und RabbitMQ.

Ein universeller OSBAPI Service Broker (Go) steuert drei K8s-Operatoren an und stellt sie als CF Marketplace Services bereit.

**Architektur:**

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

## Voraussetzungen

- Phase 1-6 vollstaendig deployed
- Korifi mit `experimental.managedServices.enabled=true` (bereits gesetzt)
- Go 1.24+ und crane auf dem Host (fuer Broker-Build)

## Service-Katalog

| Service | Plans | Beschreibung | Operator |
|---------|-------|-------------|----------|
| `postgresql` | small (256Mi, 1Gi), medium (512Mi, 5Gi) | PostgreSQL 18 via CloudNativePG | CloudNativePG |
| `valkey` | small (128Mi, 1Gi) | Valkey (Redis-kompatibler) Key-Value Store | Direkt (StatefulSet) |
| `rabbitmq` | small (256Mi, 1Gi) | RabbitMQ Message Broker | RabbitMQ Cluster Operator |

## Installation

### 7.1 Operatoren installieren

```bash
# CloudNativePG
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace

# RabbitMQ Cluster Operator
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

# Valkey: kein Operator noetig (Broker verwaltet direkt)
```

### 7.2 Service Broker bauen

```bash
cd k8/services/cf-service-broker/src

# Nativ kompilieren (ARM64)
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o /tmp/cf-service-broker .

# OCI Image bauen und pushen (Pattern wie kpack)
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

### 7.3 Broker Credentials in OpenBao speichern

```bash
BROKER_PASS=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)
kubectl exec -n openbao openbao-0 -- bao kv put secret/cf-service-broker/auth \
  username="admin" password="${BROKER_PASS}"
echo "Broker-Passwort: ${BROKER_PASS}"
```

### 7.4 Broker deployen

```bash
kubectl create namespace cf-services
kubectl apply -f k8/services/cf-service-broker/deployment.yaml
kubectl wait --for=condition=Available deploy/cf-service-broker -n cf-services --timeout=60s
```

### 7.5 Broker bei Korifi registrieren

```bash
kubectl config use-context cf-admin
cf create-service-broker k8s-services admin <BROKER_PASS> \
  http://cf-service-broker.cf-services.svc.cluster.local
cf enable-service-access postgresql
cf enable-service-access valkey
cf enable-service-access rabbitmq
```

### 7.6 Validierung

```bash
# Marketplace pruefen
cf marketplace
# offering     plans           description
# postgresql   small, medium   PostgreSQL 18 via CloudNativePG
# valkey       small           Valkey (Redis-compatible) key-value store
# rabbitmq     small           RabbitMQ message broker

# Service provisionieren
cf create-service postgresql small my-pg
cf create-service valkey small my-cache
cf create-service rabbitmq small my-mq

# Status pruefen (warten bis "create succeeded")
cf services

# Credentials abrufen
cf create-service-key my-pg my-pg-key
cf service-key my-pg my-pg-key

# An App binden
cf bind-service my-app my-pg
cf restage my-app
cf env my-app  # VCAP_SERVICES enthaelt PostgreSQL Credentials

# Aufraemen
cf delete-service my-pg -f
```

## Broker-Implementierung

### Go-Paketstruktur

```
src/
├── main.go              # HTTP Server, /healthz, brokerapi.New()
├── broker/
│   ├── broker.go        # ServiceBroker Interface (Provision/Bind/Deprovision)
│   ├── catalog.go       # Service-Katalog mit Plans
│   └── state.go         # ConfigMap-basierte Instanz-Verwaltung
├── provisioners/
│   ├── provisioner.go   # Interface
│   ├── postgresql.go    # CloudNativePG Cluster CRD
│   ├── valkey.go        # StatefulSet + Service + Secret
│   └── rabbitmq.go      # RabbitmqCluster CRD
└── k8s/
    └── client.go        # Dynamic + Typed K8s Client
```

### OSBAPI Flows

**Provision (async):**
1. Broker empfaengt `PUT /v2/service_instances/:id`
2. Erstellt Operator-CRD oder K8s-Ressourcen in `cf-services` Namespace
3. Speichert Instanz-State in ConfigMap `broker-instances`
4. Returned `202 Accepted`
5. Korifi pollt `GET /v2/service_instances/:id/last_operation`
6. Broker prueft CRD Status Conditions bis Ready

**Bind (sync):**
1. Broker empfaengt `PUT /v2/service_instances/:id/service_bindings/:bid`
2. Liest Credentials aus Operator-erstelltem Secret
3. Returned Credentials (hostname, port, username, password, uri)

**Deprovision:**
1. Broker empfaengt `DELETE /v2/service_instances/:id`
2. Loescht CRD/Ressourcen + PVCs
3. Entfernt Instanz aus ConfigMap

### Credentials-Format

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

## Bekannte Einschraenkungen

| Einschraenkung | Details |
|----------------|---------|
| Single-Node | Alle Services laufen mit 1 Instanz (Dev-Setup) |
| Kein Plan-Update | `cf update-service` wird nicht unterstuetzt |
| Valkey ohne Operator | Direkt als StatefulSet verwaltet, kein HA |
| Keine Backups | Service-Instanzen werden nicht automatisch gesichert |
| Namespace-fest | Alle Instanzen landen in `cf-services` |
