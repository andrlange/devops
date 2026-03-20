# Phase 6: Cloud Foundry / Korifi (OPTIONAL)

## Uebersicht

**Ziel:** Cloud Foundry Erfahrung auf Kubernetes via Korifi -- `cf push` zum Deployen von Applikationen unter `*.app.cfapps.cool`. Service Binding fuer PostgreSQL, Redis und RabbitMQ ermoeglicht klassische CF-Workflows auf der bestehenden K8s-Infrastruktur.

**OPTIONAL:** Diese Phase kann vollstaendig uebersprungen werden. Der gesamte Stack funktioniert ohne Cloud Foundry. Korifi ist Beta-Software und dient primaer dazu, CF-Erfahrung in einer K8s-nativen Umgebung zu sammeln.

**Voraussetzungen:**
- Phase 1-3 (Foundation, Platform, Monitoring) vollstaendig abgeschlossen
- Phase 4 (Services) und Phase 5 (GitLab) sind **nicht** zwingend erforderlich
- QEMU user-static in der Lima VM installiert (fuer ARM64 Emulation)
- Container Images in die Registry importiert (siehe jeweilige Abschnitte)
- `cf` CLI auf dem Host installiert

**Korifi Version:** v0.18.0 (Beta)

**Ressourcenbedarf:**
- Korifi + Contour + kpack: ~800Mi-1Gi RAM zusaetzlich zum bestehenden Stack
- Jede deployte App: ~1Gi RAM default (konfigurierbar via `cf scale`)
- Builds: ~2Gi RAM temporaer (QEMU Emulation ist speicherintensiv)

**Architektur:**

```
    Developer Host                          Lima VM (K3s)
    ┌──────────┐                ┌───────────────────────────────────────────────┐
    │          │                │                                               │
    │  cf CLI ─┼───cf push─────▶│  Korifi API (api.app.cfapps.cool)             │
    │          │                │       │                                       │
    └──────────┘                │       ▼                                       │
                                │  ┌─────────────────────────────────────┐      │
                                │  │  Korifi Controllers                 │      │
                                │  │  (CFApp → CFPackage → CFBuild →     │      │
                                │  │   CFProcess → CFRoute)              │      │
                                │  └────────┬──────────┬─────────────────┘      │
                                │           │          │                        │
                                │           ▼          ▼                        │
                                │  ┌───────────────┐ ┌────────────────────┐     │
                                │  │ kpack         │ │ statefulset-runner │     │
                                │  │ (Buildpacks)  │ │ (App Runtime)      │     │
                                │  │               │ │                    │     │
                                │  │ Source Code   │ │ Container Image    │     │
                                │  │   ▼           │ │   ▼                │     │
                                │  │ Heroku        │ │ StatefulSet        │     │
                                │  │ builder:24    │ │ (1..N Instanzen)   │     │
                                │  │   ▼           │ │                    │     │
                                │  │ OCI Image     │ │                    │     │
                                │  │ → Registry    │ │                    │     │
                                │  └───────────────┘ └────────┬───────────┘     │
                                │                             │                 │
                                │                             ▼                 │
                                │  ┌─────────────────────────────────────┐      │
                                │  │  HTTPRoute (Gateway API)            │      │
                                │  │  my-app.app.cfapps.cool             │      │
                                │  └────────────────┬────────────────────┘      │
                                │                   │                           │
                                │                   ▼                           │
                                │  ┌─────────────────────────────────────┐      │
                                │  │  Contour (Gateway API Controller)   │      │
                                │  │  LoadBalancer: 192.168.64.203       │      │
                                │  └────────────────┬────────────────────┘      │
                                │                   │                           │
                                └───────────────────┼───────────────────────────┘
                                                    │
                                                    ▼
                                             ┌──────────────┐
                                             │   MetalLB    │
                                             │  L2 Mode     │
                                             └──────────────┘
                                                    │
                                                    ▼
                                               Browser / curl
                                          my-app.app.cfapps.cool
```

**Korifi Komponenten:**

| Komponente             | Beschreibung                                                |
|------------------------|-------------------------------------------------------------|
| API                    | CF API v3 kompatibel, empfaengt `cf push` und CLI-Befehle  |
| Controllers            | Reconciled CF CRDs → K8s-native Ressourcen                  |
| kpack-image-builder    | Baut Source Code via Cloud Native Buildpacks zu OCI Images  |
| statefulset-runner     | Erstellt StatefulSets fuer laufende App-Instanzen           |
| job-task-runner        | Fuehrt einmalige Tasks aus (`cf run-task`)                  |

**Custom Resource Definitions (CRDs):**

| CRD        | Beschreibung                                              |
|------------|-----------------------------------------------------------|
| CFOrg      | Organisation (Multi-Tenancy Einheit)                      |
| CFSpace    | Space innerhalb einer Org (Deployment-Ziel)               |
| CFApp      | Applikation mit Lifecycle-Management                      |
| CFPackage  | Source Code Package (Upload via `cf push`)                |
| CFBuild    | Build-Auftrag (Source → Image via kpack)                  |
| CFProcess  | Laufender Prozess (web, worker, etc.)                     |
| CFRoute    | HTTP Route (Domain + Path → App)                          |
| CFDomain   | DNS Domain (z.B. app.cfapps.cool)                         |

---

## ARM64 Einschraenkungen (WICHTIG)

> **kpack ist NICHT ARM64-kompatibel.** Der kpack Controller ist hardcoded fuer AMD64. Auf Apple Silicon (M4+) ist daher QEMU user-static Emulation in der Lima VM erforderlich.

**Auswirkungen:**

- **Build-Performance:** Deutlich langsamer unter QEMU Emulation. Ein einfacher Go-Build kann 3-5 Minuten statt 30 Sekunden dauern. Java-Builds koennen 10+ Minuten benoetigen.
- **Heroku builder:24** hat die beste ARM64 Buildpack-Unterstuetzung und wird empfohlen:
  - Go, Java, Node.js, Python, Ruby, PHP -- alle unterstuetzt
- **Paketo Buildpacks** sind nur fuer **Java** und **Rust** ARM64-kompatibel. Fuer andere Sprachen wird auf AMD64-Emulation zurueckgefallen.
- **QEMU Installation** ist zwingend erforderlich bevor kpack oder Korifi deployt werden.

```bash
# QEMU user-static in der Lima VM installieren
limactl shell k3s-server sudo apt install -y qemu-user-static

# Verifizieren, dass binfmt_misc registriert ist
limactl shell k3s-server ls /proc/sys/fs/binfmt_misc/
# Erwartete Ausgabe: qemu-x86_64 (u.a.)
```

---

## Voraussetzungen

### Checkliste

- [ ] Phase 1 (Foundation): K3s, MetalLB, Traefik, cert-manager, OpenBao, ESO
- [ ] Phase 2 (Platform): ArgoCD, Garage (fuer Container Registry falls genutzt)
- [ ] Phase 3 (Monitoring): Grafana, Loki (fuer Log-Aggregation der CF-Apps)
- [ ] QEMU user-static in Lima VM installiert (siehe 6.1)
- [ ] Contour als Gateway API Controller deployt (siehe 6.2)
- [ ] kpack installiert und konfiguriert (siehe 6.3)
- [ ] Service Binding Runtime installiert (siehe 6.4)
- [ ] DNS Eintraege konfiguriert
- [ ] cf CLI auf dem Host installiert

### DNS Eintraege

Folgende DNS-Eintraege muessen in Technitium (oder `/etc/hosts`) konfiguriert werden:

| Eintrag                  | Typ   | Ziel              | Beschreibung          |
|--------------------------|-------|-------------------|-----------------------|
| `api.app.cfapps.cool`   | A     | 192.168.64.203    | Korifi API Endpunkt   |
| `*.app.cfapps.cool`     | A     | 192.168.64.203    | App Wildcard Domain   |

Die IP `192.168.64.203` ist die separate MetalLB-IP fuer Contour (nicht Traefik).

### cf CLI installieren

```bash
# macOS (Homebrew)
brew install cloudfoundry/tap/cf-cli@8

# Verifizieren
cf version
# Erwartete Ausgabe: cf version 8.x.x
```

---

## 6.1 QEMU user-static installieren

QEMU user-static ermoeglicht die Ausfuehrung von AMD64-Binaries auf ARM64 via transparente Emulation. Dies ist erforderlich, da kpack und diverse Buildpack-Builder nur als AMD64-Images verfuegbar sind.

```bash
# Installation
limactl shell k3s-server sudo apt update
limactl shell k3s-server sudo apt install -y qemu-user-static

# Verifizieren
limactl shell k3s-server file /usr/bin/qemu-x86_64-static
# Erwartete Ausgabe: /usr/bin/qemu-x86_64-static: ELF 64-bit LSB executable, ARM aarch64

# binfmt_misc Registrierung pruefen
limactl shell k3s-server cat /proc/sys/fs/binfmt_misc/qemu-x86_64
# "enabled" muss in der Ausgabe erscheinen

# Test: AMD64 Binary ausfuehren
limactl shell k3s-server -- docker run --rm --platform linux/amd64 alpine uname -m
# Erwartete Ausgabe: x86_64
```

> **Hinweis:** Nach einem Neustart der Lima VM muss `binfmt_misc` moeglicherweise neu registriert werden. QEMU user-static wird jedoch normalerweise automatisch ueber systemd-binfmt beim Boot aktiviert.

---

## 6.2 Contour (Gateway API Controller)

### Warum Contour statt Traefik?

Korifi testet offiziell **nur mit Contour** als Gateway API Controller. Traefik's Gateway API Implementierung ist zwar vorhanden, aber mit Korifi ungetestet und es gibt bekannte Inkompatibilitaeten bei HTTPRoute-Features. Contour laeuft **parallel** zu Traefik auf einer **eigenen MetalLB IP** -- es gibt keine Konflikte.

| Eigenschaft     | Traefik (bestehend)        | Contour (neu fuer Korifi)  |
|-----------------|----------------------------|----------------------------|
| Rolle           | Ingress fuer alle Services | Gateway API fuer CF-Apps   |
| MetalLB IP      | 192.168.64.201             | 192.168.64.203             |
| Domains         | *.development.cfapps.cool  | *.app.cfapps.cool          |
| Gateway API     | nicht genutzt              | aktiv (GatewayClass)       |

### Namespace erstellen

```bash
kubectl create namespace projectcontour
```

### Helm Installation

```bash
# Helm Repo hinzufuegen
helm repo add projectcontour https://projectcontour.github.io/contour
helm repo update

# Contour installieren
helm install contour projectcontour/contour \
  --namespace projectcontour \
  --version 19.1.1 \
  --set contour.gatewayAPI.enabled=true \
  --set envoy.service.type=LoadBalancer \
  --set envoy.service.annotations."metallb\.universe\.tf/loadBalancerIPs"=192.168.64.203
```

### GatewayClass und Gateway erstellen

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: contour
spec:
  controllerName: projectcontour.io/gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: contour
  namespace: projectcontour
spec:
  gatewayClassName: contour
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 443
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: cf-wildcard-tls
            namespace: projectcontour
```

```bash
kubectl apply -f gateway.yaml
```

### Validierung

```bash
# Contour Pods pruefen
kubectl get pods -n projectcontour
# contour-xxx   Running
# envoy-xxx     Running

# LoadBalancer IP pruefen
kubectl get svc -n projectcontour envoy
# EXTERNAL-IP: 192.168.64.203

# GatewayClass pruefen
kubectl get gatewayclass contour
# ACCEPTED: True
```

---

## 6.3 kpack installieren

kpack baut Source Code via Cloud Native Buildpacks zu OCI Container Images. Es beobachtet `Image` CRDs und triggert automatisch Builds wenn sich Source Code oder Buildpacks aendern.

### kpack Release installieren

```bash
# kpack v0.15.1 installieren
kubectl apply -f https://github.com/buildpacks-community/kpack/releases/download/v0.15.1/release-v0.15.1.yaml

# Warten bis Controller bereit ist
kubectl wait --for=condition=Ready pods -l app=kpack-controller -n kpack --timeout=120s
```

### Container Registry Credentials

kpack benoetigt Zugriff auf eine Container Registry, um gebaute Images zu speichern. Hier wird die interne Artifactory-Registry verwendet.

```yaml
# registry-credentials.yaml
apiVersion: v1
kind: Secret
metadata:
  name: registry-credentials
  namespace: cf
  annotations:
    kpack.io/docker: artifactory.cfapps.cool
type: kubernetes.io/basic-auth
data:
  username: <base64-encoded>
  password: <base64-encoded>
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kpack-service-account
  namespace: cf
secrets:
  - name: registry-credentials
imagePullSecrets:
  - name: registry-credentials
```

```bash
kubectl apply -f registry-credentials.yaml
```

### ClusterStore, ClusterStack und ClusterBuilder

```yaml
# kpack-config.yaml
apiVersion: kpack.io/v1alpha2
kind: ClusterStore
metadata:
  name: default
spec:
  sources:
    - image: heroku/builder:24
---
apiVersion: kpack.io/v1alpha2
kind: ClusterStack
metadata:
  name: base
spec:
  id: "io.heroku.stacks.24"
  buildImage:
    image: heroku/heroku:24-cnb-build
  runImage:
    image: heroku/heroku:24-cnb
---
apiVersion: kpack.io/v1alpha2
kind: ClusterBuilder
metadata:
  name: default
spec:
  tag: artifactory.cfapps.cool/docker-local/korifi/kpack-builder
  stack:
    name: base
    kind: ClusterStack
  store:
    name: default
    kind: ClusterStore
  order:
    - group:
        - id: heroku/go
        - id: heroku/java
        - id: heroku/nodejs
        - id: heroku/python
        - id: heroku/ruby
        - id: heroku/php
  serviceAccountRef:
    name: kpack-service-account
    namespace: cf
```

```bash
kubectl apply -f kpack-config.yaml

# ClusterBuilder Status pruefen (kann einige Minuten dauern wegen Image-Pull)
kubectl get clusterbuilder default
# READY: True
```

> **Hinweis:** Der erste Build des ClusterBuilders dauert unter QEMU Emulation deutlich laenger (5-15 Minuten). Dies ist normal.

---

## 6.4 Service Binding Runtime

Die Service Binding Specification (servicebinding.io) ermoeglicht automatische Credential-Injection in App Container. Korifi nutzt dies fuer `cf bind-service`.

### Installation

```bash
# Service Binding Runtime v0.9.1
kubectl apply -f https://github.com/servicebinding/runtime/releases/download/v0.9.1/servicebinding-runtime-v0.9.1.yaml

# Warten bis Controller bereit ist
kubectl wait --for=condition=Ready pods -l control-plane=controller-manager \
  -n servicebinding-system --timeout=120s
```

### Validierung

```bash
# CRDs pruefen
kubectl get crd | grep servicebinding
# clusterworkloadresourcemappings.servicebinding.io
# servicebindings.servicebinding.io
```

---

## 6.5 Korifi deployen

### Namespace erstellen

```bash
kubectl create namespace cf
```

### Helm Installation

```bash
# Korifi Helm Repo hinzufuegen
helm repo add korifi https://cloudfoundry.github.io/korifi
helm repo update

# Korifi installieren
helm install korifi korifi/korifi \
  --namespace cf \
  --version 0.18.0 \
  --set rootNamespace=cf \
  --set api.apiServer.url=api.app.cfapps.cool \
  --set defaultAppDomainName=app.cfapps.cool \
  --set containerRepositoryPrefix=artifactory.cfapps.cool/docker-local/korifi/ \
  --set networking.gatewayClass=contour \
  --set experimental.managedServices.enabled=true \
  --set kpackImageBuilder.clusterBuilderName=default \
  --set api.authProxy.enabled=false
```

### Admin User konfigurieren

Korifi nutzt Kubernetes RBAC fuer die Authentifizierung. Ein Admin-User wird ueber ein ServiceAccount Token erstellt.

```yaml
# cf-admin.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cf-admin
  namespace: cf
---
apiVersion: v1
kind: Secret
metadata:
  name: cf-admin-token
  namespace: cf
  annotations:
    kubernetes.io/service-account.name: cf-admin
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cf-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: korifi-controllers-admin
subjects:
  - kind: ServiceAccount
    name: cf-admin
    namespace: cf
```

```bash
kubectl apply -f cf-admin.yaml

# Token auslesen
CF_ADMIN_TOKEN=$(kubectl get secret cf-admin-token -n cf -o jsonpath='{.data.token}' | base64 -d)
echo "$CF_ADMIN_TOKEN"
```

### CF API Login testen

```bash
# API Endpunkt setzen
cf api https://api.app.cfapps.cool --skip-ssl-validation

# Login mit Token
cf auth "$CF_ADMIN_TOKEN"

# Alternativ: kubeconfig-basierter Login
# cf login (nutzt den aktuellen kubeconfig Kontext)
```

### Validierung

```bash
# Korifi Pods pruefen
kubectl get pods -n cf
# korifi-api-xxx                Running
# korifi-controllers-xxx        Running
# korifi-kpack-image-builder-xxx Running
# korifi-statefulset-runner-xxx Running
# korifi-job-task-runner-xxx    Running

# CRDs pruefen
kubectl get crd | grep korifi
# cfapps.korifi.cloudfoundry.org
# cfbuilds.korifi.cloudfoundry.org
# cfdomains.korifi.cloudfoundry.org
# cforgs.korifi.cloudfoundry.org
# cfpackages.korifi.cloudfoundry.org
# cfprocesses.korifi.cloudfoundry.org
# cfroutes.korifi.cloudfoundry.org
# cfspaces.korifi.cloudfoundry.org

# API erreichbar?
curl -k https://api.app.cfapps.cool/v3/info
# {"build":"","cli_version":{"minimum":"","recommended":""},...}
```

---

## 6.6 cf push testen

### Org und Space erstellen

```bash
# API setzen und einloggen
cf api https://api.app.cfapps.cool --skip-ssl-validation
cf auth "$CF_ADMIN_TOKEN"

# Organisation erstellen
cf create-org dev
cf target -o dev

# Space erstellen
cf target -o dev
cf create-space test
cf target -s test
```

### Beispiel-App (Go)

```bash
# Verzeichnis erstellen
mkdir -p /tmp/cf-test-app && cd /tmp/cf-test-app

# main.go
cat > main.go << 'GOEOF'
package main

import (
    "fmt"
    "log"
    "net/http"
    "os"
)

func main() {
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }

    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprintf(w, "Hallo von Cloud Foundry auf K8s! (Korifi v0.18.0)\n")
    })

    log.Printf("Starte Server auf Port %s...\n", port)
    log.Fatal(http.ListenAndServe(":"+port, nil))
}
GOEOF

# go.mod
cat > go.mod << 'MODEOF'
module cf-test-app

go 1.22
MODEOF
```

### App deployen

```bash
cf push my-test-app

# Ausgabe beobachten:
# Staging app...
# Build created...
# Waiting for build to stage...
# App started!
# routes: my-test-app.app.cfapps.cool
```

> **Hinweis:** Der erste Build dauert unter QEMU Emulation deutlich laenger (5-10 Minuten), da Buildpack-Layer heruntergeladen und AMD64-Binaries emuliert werden. Folge-Builds sind schneller dank Layer-Caching.

### App testen

```bash
# App aufrufen
curl -k https://my-test-app.app.cfapps.cool
# Hallo von Cloud Foundry auf K8s! (Korifi v0.18.0)

# App Status pruefen
cf apps
# name           requested state   processes   routes
# my-test-app    started           web:1/1     my-test-app.app.cfapps.cool

# Logs anzeigen
cf logs my-test-app --recent

# App skalieren
cf scale my-test-app -i 2
```

---

## 6.7 Services bereitstellen

### Strategie

Fuer ein Single-Node Dev-Setup wird die einfachste Strategie empfohlen:

**K8s Operators + User-Provided Services (UPS)**

1. Service (PostgreSQL, Redis, RabbitMQ) wird via K8s Operator deployt
2. Credentials werden als User-Provided Service in CF registriert
3. `cf bind-service` injiziert die Credentials in die App via Service Binding

Diese Strategie ist am einfachsten und zuverlaessigsten. OSBAPI-basierte Managed Services sind experimentell und fuer Single-Node Dev-Setups zu komplex (siehe Abschnitt "Zukunft: OSBAPI").

---

### PostgreSQL (CloudNativePG Operator)

CloudNativePG ist der empfohlene PostgreSQL Operator fuer Kubernetes und vollstaendig ARM64-kompatibel.

#### Operator installieren

```bash
# Namespace
kubectl create namespace cnpg-system

# Helm Installation
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --version 0.23.0
```

#### PostgreSQL Cluster erstellen

```yaml
# postgres-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cf-postgres
  namespace: cf-services
spec:
  instances: 1
  storage:
    size: 5Gi
  postgresql:
    parameters:
      max_connections: "100"
      shared_buffers: "128MB"
  bootstrap:
    initdb:
      database: myapp
      owner: myapp
      secret:
        name: cf-postgres-credentials
---
apiVersion: v1
kind: Secret
metadata:
  name: cf-postgres-credentials
  namespace: cf-services
type: kubernetes.io/basic-auth
stringData:
  username: myapp
  password: changeme-use-openbao
```

```bash
kubectl create namespace cf-services
kubectl apply -f postgres-cluster.yaml

# Warten bis Cluster bereit ist
kubectl wait --for=condition=Ready cluster/cf-postgres -n cf-services --timeout=300s

# Connection String ermitteln
PG_HOST=$(kubectl get svc cf-postgres-rw -n cf-services -o jsonpath='{.spec.clusterIP}')
echo "postgres://myapp:changeme-use-openbao@${PG_HOST}:5432/myapp"
```

#### User-Provided Service erstellen

```bash
cf create-user-provided-service my-pg \
  -p "{\"uri\":\"postgres://myapp:changeme-use-openbao@${PG_HOST}:5432/myapp\"}"

# An App binden
cf bind-service my-test-app my-pg

# App restagen damit Bindings wirksam werden
cf restage my-test-app

# Bindings pruefen
cf env my-test-app
# VCAP_SERVICES enthaelt die PostgreSQL-Credentials
```

---

### Redis/Valkey

Fuer ein Single-Node Setup wird ein einfaches Bitnami Redis Helm Chart empfohlen (kein Cluster-Modus).

#### Installation

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install redis bitnami/redis \
  --namespace cf-services \
  --set architecture=standalone \
  --set auth.password=changeme-use-openbao \
  --set master.persistence.size=2Gi \
  --set master.resources.requests.memory=128Mi \
  --set master.resources.limits.memory=256Mi
```

#### User-Provided Service erstellen

```bash
REDIS_HOST=$(kubectl get svc redis-master -n cf-services -o jsonpath='{.spec.clusterIP}')

cf create-user-provided-service my-redis \
  -p "{\"uri\":\"redis://:changeme-use-openbao@${REDIS_HOST}:6379\"}"

# An App binden
cf bind-service my-test-app my-redis
cf restage my-test-app
```

---

### RabbitMQ

Der offizielle RabbitMQ Cluster Operator (von VMware/Broadcom) ermoeglicht deklarative RabbitMQ-Cluster via Custom Resources.

#### Operator installieren

```bash
# RabbitMQ Cluster Operator
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

# Warten bis Operator bereit ist
kubectl wait --for=condition=Ready pods -l app.kubernetes.io/component=rabbitmq-operator \
  -n rabbitmq-system --timeout=120s
```

#### RabbitMQ Cluster erstellen

```yaml
# rabbitmq-cluster.yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: cf-rabbitmq
  namespace: cf-services
spec:
  replicas: 1
  resources:
    requests:
      memory: 256Mi
    limits:
      memory: 512Mi
  persistence:
    storageClassName: local-path
    storage: 2Gi
  rabbitmq:
    additionalConfig: |
      default_user = myapp
      default_pass = changeme-use-openbao
```

```bash
kubectl apply -f rabbitmq-cluster.yaml

# Warten bis Cluster bereit ist
kubectl wait --for=condition=Ready rabbitmqcluster/cf-rabbitmq \
  -n cf-services --timeout=300s

# Connection String ermitteln
RABBIT_HOST=$(kubectl get svc cf-rabbitmq -n cf-services -o jsonpath='{.spec.clusterIP}')
echo "amqp://myapp:changeme-use-openbao@${RABBIT_HOST}:5672"
```

#### User-Provided Service erstellen

```bash
cf create-user-provided-service my-rabbitmq \
  -p "{\"uri\":\"amqp://myapp:changeme-use-openbao@${RABBIT_HOST}:5672\"}"

# An App binden
cf bind-service my-test-app my-rabbitmq
cf restage my-test-app
```

---

### Zukunft: OSBAPI (Open Service Broker API)

Korifi unterstuetzt experimentell Managed Services ueber die Open Service Broker API. Dies ermoeglicht `cf marketplace` und `cf create-service` statt manueller User-Provided Services.

**Aktivierung:**

```yaml
# In der Korifi Helm-Installation bereits aktiviert:
experimental:
  managedServices:
    enabled: true
```

**Voraussetzungen fuer OSBAPI:**

- Ein OSBAPI-kompatibler Service Broker muss deployt werden
- Crossplane koennte als Broker-Backend dienen (provisioniert K8s-native Ressourcen)
- Der Broker muss bei Korifi registriert werden: `cf create-service-broker`

**Bewertung fuer Single-Node Dev:**

Aktuell zu komplex. Die Kombination aus Crossplane + OSBAPI-Adapter + Provider-Konfiguration erfordert erheblichen Aufwand fuer wenig Mehrwert im Dev-Kontext. User-Provided Services sind die pragmatischere Loesung.

Sobald sich das Crossplane OSBAPI-Ecosystem stabilisiert hat, kann dies in einer zukuenftigen Iteration ergaenzt werden.

---

## Validierung

Folgende Punkte muessen nach der Installation geprueft werden:

- [ ] `cf api https://api.app.cfapps.cool --skip-ssl-validation` -- API erreichbar
- [ ] `cf auth "$CF_ADMIN_TOKEN"` -- Login funktioniert
- [ ] `cf create-org dev && cf create-space test` -- Org/Space erstellbar
- [ ] `cf push my-test-app` -- Build und Deploy erfolgreich
- [ ] `curl -k https://my-test-app.app.cfapps.cool` -- App unter Wildcard-Domain erreichbar
- [ ] `cf create-user-provided-service my-pg -p '{"uri":"..."}'` -- UPS erstellbar
- [ ] `cf bind-service my-test-app my-pg` -- Binding injiziert Credentials in VCAP_SERVICES
- [ ] `cf logs my-test-app --recent` -- Logs sind abrufbar
- [ ] `cf scale my-test-app -i 2` -- Skalierung funktioniert

---

## Bekannte Einschraenkungen

| Einschraenkung                          | Details                                                         |
|-----------------------------------------|-----------------------------------------------------------------|
| **Beta Software**                       | Korifi CRDs koennen sich zwischen Versionen aendern. Upgrades erfordern CRD-Migrationen. |
| **Nicht alle cf Befehle implementiert** | Siehe [Korifi Known Differences](https://github.com/cloudfoundry/korifi/blob/main/docs/known-differences.md). Fehlende Befehle: `cf ssh`, `cf marketplace` (ohne OSBAPI), `cf service-keys`. |
| **Builds langsam auf ARM64**            | QEMU Emulation verlangsamt Builds um Faktor 5-10x. Erster Build besonders langsam wegen fehlender Layer-Caches. |
| **Kein cf marketplace**                 | Ohne OSBAPI Broker ist `cf marketplace` leer. User-Provided Services als Workaround. |
| **Container Registry erforderlich**     | kpack muss gebaute Images in eine Registry pushen. Artifactory muss erreichbar und konfiguriert sein. |
| **Eigene Gateway**                      | Korifi erstellt eine eigene Contour Gateway -- nicht mit Traefik IngressRoutes mischen. CF-Apps laufen auf `*.app.cfapps.cool`, alle anderen Services weiterhin auf `*.development.cfapps.cool`. |
| **Kein Rolling Deployment**             | Korifi nutzt StatefulSets, kein Blue-Green oder Rolling Update wie PCF/TAS. |
| **Kein Buildpack-Caching**              | Unter QEMU kann Buildpack-Caching eingeschraenkt funktionieren. |

---

## Ressourcen

**Zusaetzlicher Speicherbedarf (ueber Phase 1-3 hinaus):**

| Komponente              | RAM           | Anmerkung                                  |
|-------------------------|---------------|--------------------------------------------|
| Contour (Envoy + ctrl) | ~200Mi        | Gateway API Controller                     |
| kpack Controller        | ~100Mi        | Build-Orchestrierung                       |
| Korifi (alle Pods)      | ~500Mi-700Mi  | API, Controllers, Builder, Runner          |
| Service Binding Runtime | ~50Mi         | Credential-Injection                       |
| **Gesamt Overhead**     | **~850Mi-1Gi**| Ohne Apps und Services                     |
| Jede CF App (default)   | ~1Gi          | Konfigurierbar via `cf scale -m`           |
| Build (temporaer)       | ~2Gi          | Waehrend kpack Build aktiv                 |
| CloudNativePG           | ~256Mi        | PostgreSQL Operator + Instanz              |
| Redis                   | ~128-256Mi    | Standalone Instanz                         |
| RabbitMQ                | ~256-512Mi    | Single-Node Cluster                        |

**Empfohlener freier RAM:** Mindestens 4Gi frei bevor Phase 6 begonnen wird.

---

## Referenzen

- Korifi Repository: <https://github.com/cloudfoundry/korifi>
- Korifi Dokumentation: <https://www.cloudfoundry.org/technology/korifi/>
- Cloud Native Buildpacks: <https://buildpacks.io/docs/>
- Paketo Buildpacks: <https://paketo.io/>
- Heroku Builder (multi-arch): <https://github.com/heroku/builder>
- kpack: <https://github.com/buildpacks-community/kpack>
- Contour: <https://projectcontour.io/>
- CloudNativePG: <https://cloudnative-pg.io/>
- RabbitMQ Cluster Operator: <https://www.rabbitmq.com/kubernetes/operator/operator-overview>
- Service Binding Spec: <https://servicebinding.io/>
- Gateway API: <https://gateway-api.sigs.k8s.io/>
