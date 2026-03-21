# CF Service Broker — Aufsetzen und Benutzen

## Uebersicht

Der CF Service Broker ist ein eigener OSBAPI v2-kompatibler Service Broker (Go), der drei Kubernetes-Operatoren als Cloud Foundry Marketplace Services bereitstellt. Developers koennen Services wie auf einer VM-basierten CF Plattform (Tanzu Application Service / PCF) nutzen:

```bash
cf marketplace
cf create-service postgresql small my-db
cf bind-service my-app my-db
```

### Architektur

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
  │  /v2/catalog          → Service-Katalog             │
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
  Operator         (direkt)      Operator
  (cnpg-system)                  (rabbitmq-system)
```

### Komponenten

| Komponente | Version | Namespace | Beschreibung |
|------------|---------|-----------|-------------|
| CF Service Broker | 1.2.0 | cf-services | Go OSBAPI Broker (pivotal-cf/brokerapi v11) |
| CloudNativePG | 1.28.1 | cnpg-system | PostgreSQL Operator (Helm) |
| RabbitMQ Cluster Operator | 2.19.2 | rabbitmq-system | RabbitMQ Operator (kubectl apply) |
| Valkey | 8.1 | cf-services | Direkt per StatefulSet (kein Operator) |

---

## Teil 1: Aufsetzen

### 1.1 Voraussetzungen

- Phase 1-6 vollstaendig deployed (Korifi laeuft)
- `experimental.managedServices.enabled=true` in Korifi Helm Values (standardmaessig gesetzt)
- OpenBao entsiegelt
- Go 1.24+ installiert (`brew install go`)
- crane installiert (`go install github.com/google/go-containerregistry/cmd/crane@latest`)

### 1.2 CloudNativePG Operator installieren

CloudNativePG ist der PostgreSQL-Operator. Er verwaltet PostgreSQL-Cluster als Kubernetes Custom Resources.

```bash
# Helm Repo hinzufuegen
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update cnpg

# Operator installieren
helm install cnpg cnpg/cloudnative-pg \
  -n cnpg-system \
  --create-namespace

# Warten bis der Operator bereit ist
kubectl wait --for=condition=Available deploy -n cnpg-system \
  -l app.kubernetes.io/name=cloudnative-pg --timeout=120s
```

**Validierung:**

```bash
kubectl get pods -n cnpg-system
# cnpg-cloudnative-pg-xxx   1/1   Running

kubectl get crd | grep cnpg
# clusters.postgresql.cnpg.io
# poolers.postgresql.cnpg.io
# scheduledbackups.postgresql.cnpg.io
```

### 1.3 RabbitMQ Cluster Operator installieren

Der offizielle RabbitMQ Cluster Operator verwaltet RabbitMQ-Cluster als Custom Resources.

```bash
# Operator installieren (offizielle Release-Manifeste)
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

# Warten bis der Operator bereit ist
kubectl wait --for=condition=Available deploy/rabbitmq-cluster-operator \
  -n rabbitmq-system --timeout=120s
```

**Validierung:**

```bash
kubectl get pods -n rabbitmq-system
# rabbitmq-cluster-operator-xxx   1/1   Running

kubectl get crd | grep rabbitmq
# rabbitmqclusters.rabbitmq.com
```

### 1.4 Valkey

Fuer Valkey wird kein Operator installiert. Der Service Broker verwaltet Valkey-Instanzen direkt als StatefulSets. Das Valkey Container Image (`valkey/valkey:8.1-alpine`) wird beim ersten `cf create-service` automatisch gepullt.

### 1.5 Service Broker bauen

Der Broker ist ein Go-Binary das nativ auf dem Mac (ARM64) kompiliert und als OCI Container Image in die Registry gepusht wird.

```bash
cd k8/services/cf-service-broker/src

# Go-Abhaengigkeiten laden
go mod tidy

# Nativ fuer ARM64 kompilieren
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o /tmp/cf-service-broker .

# OCI Image bauen und pushen
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

### 1.6 Broker Credentials einrichten

Der Broker schuetzt seine OSBAPI-Endpoints mit Basic Auth. Die Credentials werden in OpenBao gespeichert.

```bash
# Zufaelliges Passwort generieren
BROKER_PASS=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)

# In OpenBao speichern
kubectl exec -n openbao openbao-0 -- bao kv put secret/cf-service-broker/auth \
  username="admin" password="${BROKER_PASS}"

# Passwort merken (wird fuer die Registrierung benoetigt)
echo "Broker-Passwort: ${BROKER_PASS}"
```

### 1.7 Broker deployen

```bash
# Namespace erstellen
kubectl create namespace cf-services

# Pull-Secret fuer Container Registry
kubectl -n cf-services create secret docker-registry artifact-keeper-pull \
  --docker-server="artifactory.cfapps.cool" \
  --docker-username="admin" \
  --docker-password="<REGISTRY_PASS>"

# Deployment anwenden (Passwort in deployment.yaml anpassen)
kubectl apply -f k8/services/cf-service-broker/deployment.yaml

# Warten bis bereit
kubectl wait --for=condition=Available deploy/cf-service-broker \
  -n cf-services --timeout=60s
```

**Was deployt wird:**

| Ressource | Name | Beschreibung |
|-----------|------|-------------|
| ServiceAccount | cf-service-broker | Identitaet fuer K8s API-Zugriff |
| ClusterRole | cf-service-broker | Rechte fuer Operator-CRDs, Secrets, StatefulSets |
| ClusterRoleBinding | cf-service-broker | Verknuepfung SA → ClusterRole |
| Deployment | cf-service-broker | Broker-Container (1 Replica, 64Mi RAM) |
| Service | cf-service-broker | ClusterIP Service auf Port 80 → 8080 |

**Validierung:**

```bash
# Broker-Pod laeuft?
kubectl get pods -n cf-services -l app=cf-service-broker

# Health-Check
kubectl run --rm -it --restart=Never curl-test --image=curlimages/curl -- \
  curl -s http://cf-service-broker.cf-services.svc.cluster.local/healthz
# {"status":"ok"}

# Catalog-Endpoint (mit Auth)
kubectl run --rm -it --restart=Never curl-test --image=curlimages/curl -- \
  curl -s -u admin:<BROKER_PASS> \
  http://cf-service-broker.cf-services.svc.cluster.local/v2/catalog \
  -H "X-Broker-API-Version: 2.17"
```

### 1.8 Broker bei Korifi registrieren

```bash
# Als cf-admin einloggen
kubectl config use-context cf-admin
cf api https://api.app.cfapps.cool --skip-ssl-validation
cf login

# Broker registrieren
cf create-service-broker k8s-services admin <BROKER_PASS> \
  http://cf-service-broker.cf-services.svc.cluster.local

# Services fuer alle Orgs freischalten
cf enable-service-access postgresql
cf enable-service-access valkey
cf enable-service-access rabbitmq

# Marketplace pruefen
cf marketplace
# offering     plans           description                                 broker
# postgresql   small, medium   PostgreSQL 18 via CloudNativePG             k8s-services
# valkey       small           Valkey (Redis-compatible) key-value store   k8s-services
# rabbitmq     small           RabbitMQ message broker                     k8s-services
```

---

## Teil 2: Services benutzen

### 2.1 PostgreSQL

#### Service erstellen

```bash
# Small Plan (256Mi RAM, 1Gi Storage)
cf create-service postgresql small my-db

# Medium Plan (512Mi RAM, 5Gi Storage)
cf create-service postgresql medium my-db-large

# Status pruefen (warten bis "create succeeded")
cf services
```

#### Was im Cluster passiert

Der Broker erstellt einen CloudNativePG `Cluster` CRD im `cf-services` Namespace:

```bash
kubectl get clusters.postgresql.cnpg.io -n cf-services
# NAME          INSTANCES   READY   STATUS
# pg-xxxxxxxx   1           1       Cluster in healthy state
```

CloudNativePG erstellt automatisch:
- Einen PostgreSQL Pod (`pg-xxxxxxxx-1`)
- Einen Read-Write Service (`pg-xxxxxxxx-rw`)
- Ein Credentials Secret (`pg-xxxxxxxx-app`)
- Eine Datenbank `app` mit Owner `app`

#### An eine App binden

```bash
# Direkt im manifest.yml:
# services:
#   - my-db

# Oder manuell:
cf bind-service my-app my-db
cf restage my-app
```

#### Credentials pruefen

```bash
cf create-service-key my-db my-db-key
cf service-key my-db my-db-key
```

**Credentials-Format:**

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

`java-cfenv-boot` erkennt PostgreSQL automatisch aus `VCAP_SERVICES`:

```xml
<dependency>
    <groupId>io.pivotal.cfenv</groupId>
    <artifactId>java-cfenv-boot</artifactId>
    <version>3.2.0</version>
</dependency>
```

Keine manuelle DataSource-Konfiguration noetig — `spring.datasource.*` wird automatisch gesetzt.

---

### 2.2 Valkey (Redis-kompatibel)

#### Service erstellen

```bash
cf create-service valkey small my-cache
cf services  # warten bis "create succeeded"
```

#### Was im Cluster passiert

Der Broker erstellt direkt (ohne Operator):
- Ein Credentials Secret (`valkey-xxxxxxxx-credentials`)
- Einen Service (`valkey-xxxxxxxx`)
- Ein StatefulSet (`valkey-xxxxxxxx`) mit Valkey 8.1

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
# application.yml (wird automatisch via java-cfenv-boot gesetzt)
spring.data.redis.host=${vcap.services.my-cache.credentials.hostname}
spring.data.redis.port=${vcap.services.my-cache.credentials.port}
spring.data.redis.password=${vcap.services.my-cache.credentials.password}
```

**Hinweis:** Valkey ist vollstaendig Redis-kompatibel. Alle Redis-Clients (Jedis, Lettuce, Spring Data Redis) funktionieren unveraendert.

---

### 2.3 RabbitMQ

#### Service erstellen

```bash
cf create-service rabbitmq small my-mq
cf services  # warten bis "create succeeded"
```

#### Was im Cluster passiert

Der Broker erstellt einen `RabbitmqCluster` CRD im `cf-services` Namespace:

```bash
kubectl get rabbitmqclusters -n cf-services
# NAME          ALLREPLICASREADY   RECONCILESUCCESS   AGE
# rmq-xxxxxxxx  True               True               5m
```

Der RabbitMQ Operator erstellt automatisch:
- Einen RabbitMQ Pod (`rmq-xxxxxxxx-server-0`)
- Einen Service (`rmq-xxxxxxxx`)
- Ein Credentials Secret (`rmq-xxxxxxxx-default-user`)
- Das Management Plugin (Port 15672)

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

`java-cfenv-boot` setzt automatisch `spring.rabbitmq.host`, `spring.rabbitmq.port`, `spring.rabbitmq.username`, `spring.rabbitmq.password`.

---

## Teil 3: Haeufige Operationen

### Service loeschen

```bash
# Erst alle Bindings entfernen
cf unbind-service my-app my-db

# Dann Service-Keys loeschen
cf delete-service-key my-db my-db-key -f

# Service loeschen
cf delete-service my-db -f
```

Der Broker loescht alle zugehoerigen K8s-Ressourcen (CRD, Pods, Services, Secrets, PVCs).

### Alle Services anzeigen

```bash
# Im aktuellen Space
cf services

# Marketplace mit Plan-Details
cf marketplace -e postgresql
```

### Service-Instanzen im Cluster pruefen

```bash
# Alle provisionierten Instanzen
kubectl get all -n cf-services -l cf-service-broker/service

# PostgreSQL-Cluster
kubectl get clusters.postgresql.cnpg.io -n cf-services

# Valkey StatefulSets
kubectl get statefulsets -n cf-services -l cf-service-broker/service=valkey

# RabbitMQ-Cluster
kubectl get rabbitmqclusters -n cf-services

# Instanz-State (ConfigMap)
kubectl get configmap broker-instances -n cf-services -o yaml
```

### Broker-Logs pruefen

```bash
kubectl logs -n cf-services -l app=cf-service-broker --tail=20
```

### Broker aktualisieren

Nach Code-Aenderungen am Broker:

```bash
# 1. Neu kompilieren
cd k8/services/cf-service-broker/src
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o /tmp/cf-service-broker .

# 2. Neues Image bauen und pushen (Tag erhoehen)
# ... (siehe Abschnitt 1.5)

# 3. Deployment aktualisieren
kubectl set image -n cf-services deploy/cf-service-broker \
  broker=artifactory.cfapps.cool/docker-local/cf-service-broker:<neuer-tag>

# 4. Rollout abwarten
kubectl rollout status deploy/cf-service-broker -n cf-services
```

### Broker neu registrieren

Falls der Broker-Katalog geaendert wurde (z.B. neue Plans hinzugefuegt):

```bash
cf update-service-broker k8s-services admin <BROKER_PASS> \
  http://cf-service-broker.cf-services.svc.cluster.local
```

---

## Teil 4: Troubleshooting

### Service bleibt auf "create in progress"

```bash
# Broker-Logs pruefen
kubectl logs -n cf-services -l app=cf-service-broker --tail=20

# CRD-Status pruefen (Beispiel PostgreSQL)
kubectl describe clusters.postgresql.cnpg.io -n cf-services

# Haeufige Ursachen:
# - Operator nicht installiert (CRD existiert nicht)
# - Kein Storage verfuegbar (PVC pending)
# - Image Pull Fehler (Registry nicht erreichbar)
```

### Bind schlaegt fehl

```bash
# Credentials-Secret pruefen
kubectl get secrets -n cf-services | grep credentials

# PostgreSQL: Secret heisst pg-<id>-app
# Valkey: Secret heisst valkey-<id>-credentials
# RabbitMQ: Secret heisst rmq-<id>-default-user

# Falls Secret nicht existiert: Service ist noch nicht ready
cf services  # muss "create succeeded" zeigen
```

### Deprovision schlaegt fehl

```bash
# Manuelle Bereinigung
kubectl delete clusters.postgresql.cnpg.io -n cf-services <name>
kubectl delete rabbitmqclusters -n cf-services <name>
kubectl delete statefulset,svc,secret -n cf-services -l cf-service-broker/instance-id=<id>
kubectl delete pvc -n cf-services -l cf-service-broker/instance-id=<id>

# ConfigMap-Eintrag bereinigen
kubectl edit configmap broker-instances -n cf-services
# Entsprechenden Eintrag loeschen
```

### Marketplace leer

```bash
# Broker-Registrierung pruefen
cf service-brokers
# k8s-services   http://cf-service-broker.cf-services.svc.cluster.local

# Service-Zugriff pruefen
cf service-access
# Alle Services muessen "all" in der "access" Spalte zeigen

# Falls Broker nicht registriert:
cf create-service-broker k8s-services admin <PASS> \
  http://cf-service-broker.cf-services.svc.cluster.local
cf enable-service-access postgresql
cf enable-service-access valkey
cf enable-service-access rabbitmq
```

---

## Teil 5: Broker-Internals

### OSBAPI Endpunkte

| Methode | Endpunkt | Beschreibung |
|---------|----------|-------------|
| GET | /v2/catalog | Service-Katalog (Services + Plans) |
| PUT | /v2/service_instances/:id | Provision (async, 202 Accepted) |
| DELETE | /v2/service_instances/:id | Deprovision |
| GET | /v2/service_instances/:id/last_operation | Status-Polling (provisioning → succeeded) |
| PUT | /v2/service_instances/:id/service_bindings/:bid | Bind (sync, Credentials zurueckgeben) |
| DELETE | /v2/service_instances/:id/service_bindings/:bid | Unbind (no-op) |
| GET | /healthz | Health-Check (ohne Auth) |

### Provision-Ablauf

1. Korifi sendet `PUT /v2/service_instances/:id` mit `service_id` und `plan_id`
2. Broker identifiziert den Provisioner (PostgreSQL, Valkey oder RabbitMQ)
3. Provisioner erstellt K8s-Ressourcen im `cf-services` Namespace:
   - PostgreSQL: `Cluster` CRD (CloudNativePG)
   - Valkey: `Secret` + `Service` + `StatefulSet`
   - RabbitMQ: `RabbitmqCluster` CRD
4. Broker speichert Instanz-State in ConfigMap `broker-instances`
5. Broker returned `202 Accepted` (asynchron)
6. Korifi pollt `GET /v2/service_instances/:id/last_operation`
7. Broker prueft CRD/StatefulSet Status Conditions
8. Sobald ready: returned `succeeded`

### Bind-Ablauf

1. Korifi sendet `PUT /v2/service_instances/:id/service_bindings/:bid`
2. Broker liest das Credentials-Secret des Operators:
   - PostgreSQL: `pg-<id>-app` (von CloudNativePG erstellt)
   - Valkey: `valkey-<id>-credentials` (vom Broker erstellt)
   - RabbitMQ: `rmq-<id>-default-user` (vom RabbitMQ Operator erstellt)
3. Broker konstruiert Credentials-Map und returned sie
4. Korifi injiziert die Credentials in `VCAP_SERVICES` der App

### Instanz-State

Der Broker speichert den State aller provisionierten Instanzen in einer ConfigMap:

```bash
kubectl get configmap broker-instances -n cf-services -o yaml
```

Jeder Eintrag ist ein JSON-Objekt:

```json
{
  "service_id": "d1a5c0f2-7b3e-4a1d-9c8f-0e2b4a6d8c1e",
  "plan_id": "a1b2c3d4-1111-1111-1111-000000000001",
  "name": "43d87a1e",
  "namespace": "cf-services"
}
```

### Go-Quellcode

Der Broker-Quellcode liegt in `k8/services/cf-service-broker/src/`:

| Datei | Beschreibung |
|-------|-------------|
| `main.go` | HTTP Server, brokerapi.New(), /healthz Endpoint |
| `broker/broker.go` | ServiceBroker Interface (Provision, Bind, Deprovision, LastOperation) |
| `broker/catalog.go` | Service-Katalog mit Service IDs, Plan IDs und Beschreibungen |
| `broker/state.go` | ConfigMap-basierte Instanz-Verwaltung (CRUD) |
| `provisioners/provisioner.go` | Provisioner Interface |
| `provisioners/postgresql.go` | CloudNativePG Cluster CRD erstellen/loeschen/pruefen |
| `provisioners/valkey.go` | StatefulSet + Service + Secret erstellen/loeschen |
| `provisioners/rabbitmq.go` | RabbitmqCluster CRD erstellen/loeschen/pruefen |
| `k8s/client.go` | Kubernetes Dynamic + Typed Client Initialisierung |

### Neuen Service hinzufuegen

Um einen weiteren Service (z.B. MongoDB) hinzuzufuegen:

1. Neuen Provisioner in `provisioners/mongodb.go` erstellen (Interface implementieren)
2. Service und Plan IDs in `broker/catalog.go` hinzufuegen
3. Provisioner in `broker/broker.go` registrieren (`b.provisioners[MongoDBServiceID] = ...`)
4. Broker neu kompilieren und deployen
5. `cf update-service-broker` ausfuehren
6. `cf enable-service-access mongodb`
