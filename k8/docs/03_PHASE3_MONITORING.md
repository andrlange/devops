# Phase 3: Monitoring - Observability Stack

## Uebersicht

**Ziel:** Vollstaendiger Observability Stack fuer den K8s-Cluster mit den drei Saeulen der Observability: Logs, Metriken und Traces.

**Voraussetzungen:**
- Phase 2 (Platform) vollstaendig abgeschlossen
- Garage S3-Buckets erstellt und API-Keys in OpenBao hinterlegt:
  - `loki-chunks` (Log-Daten)
  - `mimir-blocks` (Metrik-Daten)
  - `tempo-traces` (Trace-Daten)
- External Secrets Operator (ESO) mit ClusterSecretStore `openbao` konfiguriert

**Architektur:**

```
                                    ┌───────────────┐
                                    │   Grafana     │
                                    │ (Frontend)    │
                                    └──┬───┬───┬────┘
                                       │   │   │
                          ┌────────────┘   │   └────────────┐
                          ▼                ▼                ▼
                    ┌──────────┐    ┌──────────┐     ┌──────────┐
                    │   Loki   │    │  Mimir   │     │  Tempo   │
                    │  (Logs)  │    │(Metriken)│     │ (Traces) │
                    └────┬─────┘    └────┬─────┘     └────┬─────┘
                         │               │                │
                         └───────┬───────┘                │
                                 │                        │
                         ┌───────┴───────┐                │
                         │  Garage S3    │◄───────────────┘
                         └───────────────┘

          ┌──────────────────────────────────────┐
          │           Alloy (DaemonSet)          │
          │  ┌────────┐ ┌────────┐ ┌──────────┐  │
          │  │  Logs  │ │Kubelet │ │cAdvisor  │  │
          │  │(Pods)  │ │Metrics │ │Metrics   │  │
          │  └───┬────┘ └───┬────┘ └────┬─────┘  │
          │      │          │           │        │
          │      ▼          └─────┬─────┘        │
          │   Loki.write     Mimir Remote Writ   │
          └──────────────────────────────────────┘
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   kube-state-metrics  node-exporter  kubelet/cAdvisor
```

**Komponenten und Versionen:**

| Komponente         | Version  | Helm Chart Version | Deployment-Art   |
|--------------------|----------|--------------------|------------------|
| Loki               | 3.6.7    | 6.55.0             | Helm (SingleBinary) |
| Mimir              | 3.0.4    | -                  | Kustomize (Standalone) |
| Tempo              | 2.10.3   | 1.24.4             | Helm             |
| Alloy              | v1.14.1  | 1.6.2              | Helm (DaemonSet) |
| Grafana            | 12.4.1   | 10.5.15            | Helm             |
| kube-state-metrics | -        | prometheus-community | Helm            |
| node-exporter      | -        | prometheus-community | Helm (DaemonSet) |

**Alle Container-Images werden ueber die interne Artifactory-Registry (`artifactory.cfapps.cool`) bezogen und sind ARM64-kompatibel.**

---

## 3.1 Loki (Log-Aggregation)

### Beschreibung

Loki ist das Log-Aggregations-Backend. Es empfaengt Logs von Alloy und speichert sie in Garage S3. Im Gegensatz zu Elasticsearch/OpenSearch indiziert Loki nur Labels (nicht den Log-Inhalt), was es ressourcenschonend macht.

### Deployment

- **Modus:** SingleBinary (`deploymentMode: SingleBinary`) - alle Loki-Komponenten laufen in einem einzigen Pod
- **Replicas:** 1
- **Namespace:** `loki`
- **Helm Chart:** `grafana/loki` Version 6.55.0
- **Persistenz:** 10 Gi PVC (local-path)

### Installation

```bash
helm dependency update k8/monitoring/loki
helm install loki k8/monitoring/loki -n loki --create-namespace
```

### S3-Backend Konfiguration

Loki speichert Chunks und Index-Daten im Garage S3-Bucket `loki-chunks`:

```yaml
storage:
  type: s3
  s3:
    endpoint: http://garage.garage.svc:3900
    bucketnames: loki-chunks
    region: garage
    s3ForcePathStyle: true
    access_key_id: ${ACCESS_KEY_ID}
    secret_access_key: ${SECRET_ACCESS_KEY}
```

Loki unterstuetzt Environment-Variable-Substitution in der Config (`${VAR}`). Die Credentials werden als Env-Vars aus dem Kubernetes Secret injiziert.

### Credentials via ExternalSecret

Die S3-Zugangsdaten werden automatisch aus OpenBao synchronisiert:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: loki-s3-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: loki-s3-credentials
  data:
    - secretKey: access_key
      remoteRef:
        key: secret/garage/loki
        property: access_key
    - secretKey: secret_key
      remoteRef:
        key: secret/garage/loki
        property: secret_key
```

Die Env-Vars werden im `singleBinary.extraEnv` Block gesetzt:

```yaml
singleBinary:
  extraEnv:
    - name: ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: loki-s3-credentials
          key: access_key
    - name: SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: loki-s3-credentials
          key: secret_key
```

### Schema-Konfiguration

```yaml
schemaConfig:
  configs:
    - from: "2024-04-01"
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: loki_index_
        period: 24h
```

- **Store:** TSDB (Time Series Database) - der aktuelle Standard-Store
- **Schema Version:** v13
- **Index-Periode:** 24 Stunden

### Wichtige Einstellungen

- `auth_enabled: false` - Multi-Tenancy ist deaktiviert (Single-Node Setup)
- `replication_factor: 1` - keine Replikation (Single-Node)
- Gateway, Caches, Self-Monitoring und Canary sind deaktiviert (unnoetig im SingleBinary-Modus)
- Backend/Read/Write-Komponenten auf 0 Replicas gesetzt (nicht benoetigt im SingleBinary-Modus)

### Ressourcen

```yaml
resources:
  requests:
    memory: 256Mi
    cpu: 250m
  limits:
    memory: 512Mi
    cpu: 500m
```

### Dateien

- `k8/monitoring/loki/Chart.yaml`
- `k8/monitoring/loki/values.yaml`
- `k8/monitoring/loki/templates/external-secret.yaml`

---

## 3.2 Mimir (Metriken)

### Beschreibung

Mimir ist das Metriken-Backend und empfaengt Metriken via Prometheus Remote Write von Alloy. Es bietet eine Prometheus-kompatible Query-API, sodass Grafana es als Prometheus-Datasource nutzen kann.

### Warum Kustomize statt Helm?

Das offizielle `mimir-distributed` Helm Chart ist fuer Multi-Node-Deployments konzipiert und extrem komplex (Dutzende Microservices). Fuer einen Single-Node-Cluster ist ein einfaches Standalone-Deployment mit `-target=all` wesentlich einfacher und ressourcenschonender.

### Deployment

- **Modus:** Standalone mit `-target=all` (alle Mimir-Komponenten in einem Prozess)
- **Replicas:** 1
- **Namespace:** `mimir`
- **Deployment-Methode:** Kustomize (ConfigMap + Deployment + Service + ExternalSecret)
- **Storage:** EmptyDir (keine PVC - Daten liegen in S3)

### Installation

```bash
kubectl create namespace mimir
kubectl apply -k k8/monitoring/mimir
```

### Kustomization Struktur

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: mimir
resources:
  - configmap.yaml
  - deployment.yaml
  - service.yaml
  - templates/external-secret.yaml
```

### Mimir-Konfiguration (ConfigMap)

Die komplette Mimir-Konfiguration liegt in einer ConfigMap:

```yaml
multitenancy_enabled: false

server:
  http_listen_port: 8080
  grpc_listen_port: 9095

common:
  storage:
    backend: s3
    s3:
      endpoint: garage.garage.svc:3900
      bucket_name: mimir-blocks
      region: garage
      insecure: true
      access_key_id: ${MIMIR_S3_ACCESS_KEY}
      secret_access_key: ${MIMIR_S3_SECRET_KEY}
```

**Wichtig:** Mimir unterstuetzt Environment-Variable-Expansion ueber das Flag `-config.expand-env=true`. Die Platzhalter `${MIMIR_S3_ACCESS_KEY}` und `${MIMIR_S3_SECRET_KEY}` werden zur Laufzeit durch die tatsaechlichen Werte ersetzt.

### Deployment-Konfiguration

```yaml
containers:
  - name: mimir
    image: artifactory.cfapps.cool/docker-local/grafana/mimir:3.0.4-arm64
    args:
      - -config.file=/etc/mimir/mimir.yaml
      - -target=all
      - -config.expand-env=true
    envFrom:
      - secretRef:
          name: mimir-s3-credentials
```

Die Credentials werden via `envFrom` als Umgebungsvariablen aus dem Secret geladen. Das Secret wird durch den ExternalSecret Operator aus OpenBao synchronisiert:

```yaml
data:
  - secretKey: MIMIR_S3_ACCESS_KEY
    remoteRef:
      key: secret/garage/mimir
      property: access_key
  - secretKey: MIMIR_S3_SECRET_KEY
    remoteRef:
      key: secret/garage/mimir
      property: secret_key
```

### Storage-Backends

| Komponente           | Backend     | Pfad             |
|----------------------|-------------|------------------|
| blocks_storage       | S3 (Garage) | mimir-blocks     |
| ruler_storage        | filesystem  | /data/ruler      |
| alertmanager_storage | filesystem  | /data/alertmanager |
| compactor            | filesystem  | /data/compactor  |
| tsdb                 | filesystem  | /data/tsdb       |

**Ruler und Alertmanager verwenden bewusst lokalen Speicher**, da diese Funktionen im aktuellen Setup nicht aktiv genutzt werden und kein separater S3-Bucket dafuer benoetigt wird.

### Ring-Konfiguration

Fuer den Single-Node-Betrieb:
- `instance_addr: 127.0.0.1` (Distributor und Ingester)
- `kvstore.store: memberlist` (kein separater KV-Store noetig)
- `replication_factor: 1`

### Service

```yaml
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8080
      targetPort: http
    - name: grpc
      port: 9095
      targetPort: grpc
```

Mimir ist cluster-intern unter `mimir.mimir.svc:8080` erreichbar. Grafana nutzt `http://mimir.mimir.svc:8080/prometheus` als Prometheus-kompatible Datasource.

### Readiness Probe

```yaml
readinessProbe:
  httpGet:
    path: /ready
    port: http
  initialDelaySeconds: 15
  periodSeconds: 10
```

### Ressourcen

```yaml
resources:
  requests:
    memory: 256Mi
    cpu: 250m
  limits:
    memory: 1Gi
    cpu: 500m
```

### Dateien

- `k8/monitoring/mimir/kustomization.yaml`
- `k8/monitoring/mimir/configmap.yaml`
- `k8/monitoring/mimir/deployment.yaml`
- `k8/monitoring/mimir/service.yaml`
- `k8/monitoring/mimir/templates/external-secret.yaml`

---

## 3.3 Tempo (Distributed Tracing)

### Beschreibung

Tempo ist das Tracing-Backend und empfaengt Traces via OTLP (OpenTelemetry Protocol). Es speichert Trace-Daten in Garage S3 und stellt sie ueber eine Query-API fuer Grafana bereit.

### Deployment

- **Replicas:** 1
- **Namespace:** `tempo`
- **Helm Chart:** `grafana/tempo` Version 1.24.4

### Installation

```bash
helm dependency update k8/monitoring/tempo
helm install tempo k8/monitoring/tempo -n tempo --create-namespace
```

### S3-Backend Konfiguration

```yaml
storage:
  trace:
    backend: s3
    s3:
      endpoint: garage.garage.svc:3900
      bucket: tempo-traces
      region: garage
      insecure: true
      forcepathstyle: true
      access_key: <KEY>
      secret_key: <SECRET>
```

### WICHTIG: Credentials-Handling bei Tempo

**Tempo unterstuetzt KEINE Environment-Variable-Substitution in der Konfigurationsdatei.** Dies ist ein wesentlicher Unterschied zu Loki und Mimir:

- Die S3-Credentials muessen **direkt in der Config** stehen
- Es gibt kein `-config.expand-env` Flag wie bei Mimir
- Die Config-Keys heissen `access_key` und `secret_key` (NICHT `access_key_id` und `secret_access_key` wie bei Loki/Mimir)

Da die Credentials in der values.yaml stehen, sollte diese Datei besonders geschuetzt werden. Es existiert ein ExternalSecret Template (`templates/external-secret.yaml`), aber die eigentliche Injection in die Tempo-Config erfordert andere Mechanismen als bei Loki/Mimir.

### OTLP Receiver

Tempo akzeptiert Traces ueber das OpenTelemetry Protocol:

| Protokoll | Port | Endpoint         |
|-----------|------|------------------|
| gRPC      | 4317 | `0.0.0.0:4317`  |
| HTTP      | 4318 | `0.0.0.0:4318`  |

Anwendungen koennen Traces direkt an `tempo.tempo.svc:4317` (gRPC) oder `tempo.tempo.svc:4318` (HTTP) senden.

### Ressourcen

```yaml
resources:
  requests:
    memory: 256Mi
    cpu: 250m
  limits:
    memory: 512Mi
    cpu: 500m
```

### Dateien

- `k8/monitoring/tempo/Chart.yaml`
- `k8/monitoring/tempo/values.yaml`
- `k8/monitoring/tempo/templates/external-secret.yaml`

---

## 3.4 Alloy (Collector)

### Beschreibung

Alloy ist der zentrale Daten-Collector (Nachfolger von Grafana Agent). Er laeuft als DaemonSet auf jedem Node und sammelt sowohl Logs als auch Metriken. Alloy verwendet eine deklarative Flow-basierte Konfiguration.

### Deployment

- **Modus:** DaemonSet (ein Pod pro Node)
- **Namespace:** `alloy`
- **Helm Chart:** `grafana/alloy` Version 1.6.2

### Installation

```bash
helm dependency update k8/monitoring/alloy
helm install alloy k8/monitoring/alloy -n alloy --create-namespace
```

### Log-Collection Pipeline

Die Log-Collection Pipeline besteht aus drei Stufen:

```
discovery.kubernetes "pods" → discovery.relabel "pods" → loki.source.file "pods"
  → loki.process "pods" → loki.write "default"
```

1. **Discovery:** `discovery.kubernetes "pods"` entdeckt automatisch alle Pods im Cluster
2. **Relabeling:** Extrahiert relevante Labels:
   - `namespace` - Kubernetes Namespace
   - `pod` - Pod-Name
   - `container` - Container-Name
   - `node` - Node-Name
   - `app` - App-Label (aus `app` oder `app.kubernetes.io/name`)
   - `__path__` - Pfad zu den Log-Dateien (`/var/log/pods/...`)
3. **Log-Opt-Out:** Pods mit der Annotation `alloy.grafana.com/logs.exclude: "true"` werden ausgeschlossen
4. **Processing:** CRI Log-Format Parsing und statisches Label `source=kubernetes`
5. **Shipping:** Logs werden an `http://loki.loki.svc:3100/loki/api/v1/push` gesendet

### Metrics-Collection Pipeline

Alloy sammelt Metriken aus vier Quellen:

#### 1. Kubelet-Metriken

```
discovery.kubernetes "nodes" → discovery.relabel "nodes" → prometheus.scrape "kubelet"
```

- Zugriff ueber den API Server Proxy: `kubernetes.default.svc:443/api/v1/nodes/<node>/proxy/metrics`
- Authentifizierung via ServiceAccount Token und CA-Zertifikat
- Scrape-Intervall: 60 Sekunden

#### 2. cAdvisor Container-Metriken

```
discovery.kubernetes "nodes" → discovery.relabel "cadvisor" → prometheus.scrape "cadvisor"
```

- Zugriff ueber den API Server Proxy: `kubernetes.default.svc:443/api/v1/nodes/<node>/proxy/metrics/cadvisor`
- Liefert Container-Level-Metriken (CPU, Memory, Filesystem, Network pro Container)
- Scrape-Intervall: 60 Sekunden

#### 3. kube-state-metrics (Auto-Discovery)

```
discovery.kubernetes "services" → discovery.relabel "kube_state_metrics" → prometheus.scrape "kube_state_metrics"
```

- Auto-Discovery ueber das Service-Label `app.kubernetes.io/name: kube-state-metrics`
- Scrape-Intervall: 60 Sekunden

#### 4. node-exporter (Auto-Discovery)

```
discovery.kubernetes "endpoints" → discovery.relabel "node_exporter" → prometheus.scrape "node_exporter"
```

- Auto-Discovery ueber das Service-Label `app.kubernetes.io/name` mit Regex `(node-exporter|prometheus-node-exporter)`
- Scrape-Intervall: 60 Sekunden

#### Remote Write

Alle Metriken werden via Prometheus Remote Write an Mimir gesendet:

```
prometheus.remote_write "mimir" {
  endpoint {
    url = "http://mimir.mimir.svc:8080/api/v1/push"
  }
}
```

### WICHTIG: RBAC-Konfiguration

Die Standard-ClusterRole des Alloy Helm Charts enthaelt **nicht** alle notwendigen Berechtigungen fuer das Scraping von Kubelet- und cAdvisor-Metriken. Die folgenden zusaetzlichen Regeln muessen konfiguriert werden:

```yaml
extraClusterPolicies:
  - apiGroups: [""]
    resources: ["nodes", "nodes/proxy", "nodes/metrics"]
    verbs: ["get", "list", "watch"]
```

Ohne diese Permissions liefern die kubelet- und cadvisor-Scraper keine Daten, was zu leeren Dashboards in Grafana fuehrt (siehe Abschnitt Fehlerbehebung).

### Volume Mounts

```yaml
mounts:
  varlog: true    # Mountet /var/log vom Host fuer Log-Collection
```

### Ressourcen

```yaml
resources:
  requests:
    memory: 128Mi
    cpu: 100m
  limits:
    memory: 512Mi
    cpu: 500m
```

### Dateien

- `k8/monitoring/alloy/Chart.yaml`
- `k8/monitoring/alloy/values.yaml`

---

## 3.5 kube-state-metrics

### Beschreibung

kube-state-metrics ist ein Service, der die Kubernetes API abfragt und Metriken ueber den Zustand von Kubernetes-Objekten generiert. Im Gegensatz zu kubelet/cAdvisor liefert es keine Ressourcen-Nutzungsdaten, sondern Informationen ueber den gewuenschten und aktuellen Zustand von Objekten.

### Bereitgestellte Metriken (Auswahl)

| Metrik-Praefix             | Beschreibung                          |
|----------------------------|---------------------------------------|
| `kube_pod_*`               | Pod-Status, Restarts, Phase           |
| `kube_deployment_*`        | Deployment Replicas, Conditions       |
| `kube_daemonset_*`         | DaemonSet Status                      |
| `kube_statefulset_*`       | StatefulSet Replicas                  |
| `kube_node_*`              | Node Status, Conditions               |
| `kube_namespace_*`         | Namespace-Informationen               |
| `kube_persistentvolume_*`  | PV/PVC Status und Kapazitaet          |
| `kube_resourcequota_*`     | Resource Quota Nutzung                |

### Deployment

- **Helm Chart:** `prometheus-community/kube-state-metrics`
- **Replicas:** 1

### Installation

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-state-metrics prometheus-community/kube-state-metrics -n monitoring --create-namespace
```

### Integration mit Alloy

kube-state-metrics wird automatisch von Alloy entdeckt ueber das Service-Label `app.kubernetes.io/name: kube-state-metrics`. Es ist keine manuelle Konfiguration der Scrape-Targets notwendig.

---

## 3.6 node-exporter

### Beschreibung

Der Prometheus Node Exporter laeuft als DaemonSet und sammelt Host-Level-Metriken von jedem Node. Er liefert detaillierte Informationen ueber die physische/virtuelle Hardware.

### Bereitgestellte Metriken (Auswahl)

| Metrik-Praefix         | Beschreibung                               |
|------------------------|--------------------------------------------|
| `node_cpu_*`           | CPU-Auslastung, Frequenz, Temperaturen     |
| `node_memory_*`        | RAM-Nutzung (total, free, cached, buffers) |
| `node_disk_*`          | Disk I/O (reads, writes, bytes)            |
| `node_filesystem_*`    | Filesystem-Auslastung (size, avail, free)  |
| `node_network_*`       | Netzwerk I/O (bytes, packets, errors)      |
| `node_load*`           | System Load (1m, 5m, 15m)                  |
| `node_boot_time_*`     | Boot-Zeitpunkt                             |
| `node_uname_info`      | Kernel/OS-Informationen                    |

### Deployment

- **Helm Chart:** `prometheus-community/prometheus-node-exporter`
- **Modus:** DaemonSet (ein Pod pro Node)

### Installation

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install node-exporter prometheus-community/prometheus-node-exporter -n monitoring --create-namespace
```

### Integration mit Alloy

node-exporter wird automatisch von Alloy entdeckt ueber das Service-Label `app.kubernetes.io/name` mit dem Regex-Match `(node-exporter|prometheus-node-exporter)`. Die Discovery laeuft ueber Kubernetes Endpoints, sodass die tatsaechlichen Pod-IPs als Scrape-Targets verwendet werden.

---

## 3.7 Grafana

### Beschreibung

Grafana ist das zentrale Frontend fuer den gesamten Observability Stack. Es visualisiert Logs (Loki), Metriken (Mimir) und Traces (Tempo) in einer einheitlichen Oberflaeche.

### Deployment

- **Version:** 12.4.1
- **Namespace:** `grafana`
- **Helm Chart:** `grafana/grafana` Version 10.5.15
- **Persistenz:** 2 Gi PVC (local-path)

### Installation

```bash
helm dependency update k8/monitoring/grafana
helm install grafana k8/monitoring/grafana -n grafana --create-namespace
```

### Admin-Credentials

Die Admin-Zugangsdaten werden automatisch aus OpenBao synchronisiert:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: grafana-admin-credentials
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  data:
    - secretKey: username
      remoteRef:
        key: secret/grafana/admin
        property: username
    - secretKey: password
      remoteRef:
        key: secret/grafana/admin
        property: password
```

In der Grafana-Konfiguration:

```yaml
admin:
  existingSecret: grafana-admin-credentials
  userKey: username
  passwordKey: password
```

### Provisioned Datasources

Drei Datasources werden automatisch beim Start provisioniert:

| Datasource | Typ        | URL                                        | Standard |
|------------|------------|--------------------------------------------|----------|
| Loki       | loki       | `http://loki.loki.svc:3100`                | Nein     |
| Mimir      | prometheus | `http://mimir.mimir.svc:8080/prometheus`   | Ja       |
| Tempo      | tempo      | `http://tempo.tempo.svc:3100`              | Nein     |

**Tempo-Integration:**
- Traces-to-Logs Verknuepfung mit Loki aktiviert (`tracesToLogsV2`)
- Node Graph Visualisierung aktiviert

### IngressRoute

Grafana ist extern erreichbar ueber:

```
https://grafana.development.cfapps.cool
```

Konfiguriert als Traefik IngressRoute:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`grafana.development.cfapps.cool`)
      kind: Rule
      services:
        - name: grafana
          port: 80
  tls: {}
```

### initChownData deaktiviert

```yaml
initChownData:
  enabled: false
```

Das Init-Container `initChownData` ist deaktiviert, da es bei Verwendung des local-path Provisioners zu Permission-Problemen kommen kann. Die PVC-Verzeichnisse haben bereits die korrekten Berechtigungen.

### Custom Dashboards

Dashboards werden ueber eine ConfigMap provisioniert:

```yaml
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: kubernetes
        orgId: 1
        folder: Kubernetes
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/kubernetes

dashboardsConfigMaps:
  kubernetes: grafana-dashboards-kubernetes
```

Die Dashboard-JSON-Dateien liegen in `k8/monitoring/grafana/dashboards/`.

### Ressourcen

```yaml
resources:
  requests:
    memory: 128Mi
    cpu: 100m
  limits:
    memory: 512Mi
    cpu: 500m
```

### Dateien

- `k8/monitoring/grafana/Chart.yaml`
- `k8/monitoring/grafana/values.yaml`
- `k8/monitoring/grafana/templates/ingressroute.yaml`
- `k8/monitoring/grafana/templates/external-secret.yaml`
- `k8/monitoring/grafana/dashboards/k8s-operations.json`

---

## Dashboard: K8s Operations

Das Custom Dashboard "K8s Operations" bietet eine umfassende Uebersicht ueber den Cluster-Zustand. Es ist in mehrere Bereiche unterteilt:

### Cluster Health

- **Node Status:** Anzahl aktiver Nodes
- **Running Pods:** Gesamtzahl laufender Pods
- **Pod Restarts:** Gesamtzahl der Container-Restarts (letzten 24h)
- **CPU Gauge:** Aktuelle CPU-Auslastung in Prozent
- **Memory Gauge:** Aktuelle RAM-Auslastung in Prozent
- **Disk Gauge:** Aktuelle Festplatten-Auslastung in Prozent

### Node Resources

- **CPU-Auslastung:** Zeitverlauf (user, system, iowait, idle)
- **Memory-Nutzung:** Zeitverlauf (used, cached, buffers, free)
- **System Load:** 1min, 5min, 15min Durchschnitte
- **Network I/O:** Empfangene und gesendete Bytes pro Sekunde
- **Disk I/O:** Read/Write Operations und Bytes pro Sekunde

### Workloads by Namespace

- **CPU by Namespace:** Gestapeltes Diagramm der CPU-Nutzung pro Namespace
- **Memory by Namespace:** Gestapeltes Diagramm der RAM-Nutzung pro Namespace

### Top Consumers

- **Top 10 CPU Pods:** Die 10 Pods mit dem hoechsten CPU-Verbrauch
- **Top 10 Memory Pods:** Die 10 Pods mit dem hoechsten Speicherverbrauch

### Container Restarts & Issues

- Tabelle mit Pods, die Restarts hatten
- Container-Status-Uebersicht (Running, Waiting, Terminated)

### Persistent Volumes Usage

- PVC-Auslastung (genutzt vs. verfuegbar)
- Warnungen bei hoher Auslastung

---

## Fehlerbehebung

### "no data" in Grafana Dashboards

**Symptom:** Dashboards zeigen keine Metriken an, obwohl alle Pods laufen.

**Ursache:** Alloy hat nicht genuegend RBAC-Berechtigungen, um Kubelet- und cAdvisor-Metriken ueber den API Server Proxy abzurufen.

**Loesung:** Sicherstellen, dass die ClusterRole die Permissions fuer `nodes/proxy` enthaelt:

```yaml
extraClusterPolicies:
  - apiGroups: [""]
    resources: ["nodes", "nodes/proxy", "nodes/metrics"]
    verbs: ["get", "list", "watch"]
```

**Diagnose:**

```bash
# Alloy-Logs pruefen
kubectl logs -n alloy -l app.kubernetes.io/name=alloy

# ClusterRole pruefen
kubectl get clusterrole -l app.kubernetes.io/name=alloy -o yaml

# Manuell testen ob der API Server Proxy funktioniert
kubectl get --raw "/api/v1/nodes/<node-name>/proxy/metrics" | head -5
```

### Community Dashboards zeigen "No data"

**Symptom:** Importierte Community Dashboards (z.B. von grafana.com) zeigen keine Daten, obwohl eigene Dashboards funktionieren.

**Ursache:** Viele Community Dashboards verwenden eine Template-Variable `cluster` in ihren PromQL-Queries (z.B. `{cluster="$cluster"}`). In einem Single-Node-Setup existiert dieses Label nicht, da kein Cluster-Name in den Metriken gesetzt wird.

**Loesung:**
- Dashboard-JSON bearbeiten und `cluster="$cluster"` aus allen Queries entfernen
- Oder: Im Dashboard die `cluster`-Variable auf einen leeren Wert setzen (sofern moeglich)
- Alternativ: Eigene Dashboards erstellen, die keine `cluster`-Variable verwenden (empfohlen)

### Mimir 502 Bad Gateway

**Symptom:** Grafana zeigt 502-Fehler bei Metrik-Abfragen.

**Ursache:** Falscher Service-Name in der Datasource-Konfiguration. Das `mimir-distributed` Helm Chart wuerde einen Service `mimir-gateway` erstellen. Da hier ein Kustomize-Deployment verwendet wird, heisst der Service einfach `mimir`.

**Loesung:** Sicherstellen, dass die Grafana Datasource-URL korrekt ist:

```
# Richtig (Kustomize Deployment):
http://mimir.mimir.svc:8080/prometheus

# Falsch (wuerde auf mimir-distributed Helm Chart verweisen):
http://mimir-gateway.mimir.svc/prometheus
```

### Loki "no data" trotz laufendem Alloy

**Diagnose:**

```bash
# Pruefen ob Alloy Logs an Loki sendet
kubectl logs -n alloy -l app.kubernetes.io/name=alloy | grep -i "loki\|error"

# Pruefen ob Loki erreichbar ist
kubectl exec -n alloy <alloy-pod> -- wget -qO- http://loki.loki.svc:3100/ready

# Pruefen ob S3-Credentials korrekt sind
kubectl get externalsecret -n loki loki-s3-credentials
kubectl get secret -n loki loki-s3-credentials
```

### Tempo empfaengt keine Traces

**Diagnose:**

```bash
# Pruefen ob OTLP Receiver laeuft
kubectl logs -n tempo -l app.kubernetes.io/name=tempo | grep -i "otlp\|receiver"

# Test-Trace senden (gRPC)
# Aus einem Pod im Cluster:
# grpcurl -plaintext tempo.tempo.svc:4317 list

# S3-Konnektivitaet pruefen
kubectl logs -n tempo -l app.kubernetes.io/name=tempo | grep -i "s3\|storage\|error"
```

---

## Ressourcen-Uebersicht

Gesamter Ressourcenverbrauch des Monitoring Stacks:

| Komponente         | CPU Request | CPU Limit | Memory Request | Memory Limit |
|--------------------|-------------|-----------|----------------|--------------|
| Loki               | 250m        | 500m      | 256 Mi         | 512 Mi       |
| Mimir              | 250m        | 500m      | 256 Mi         | 1 Gi         |
| Tempo              | 250m        | 500m      | 256 Mi         | 512 Mi       |
| Alloy (DaemonSet)  | 100m        | 500m      | 128 Mi         | 512 Mi       |
| Grafana            | 100m        | 500m      | 128 Mi         | 512 Mi       |
| kube-state-metrics | ~100m       | ~250m     | ~128 Mi        | ~256 Mi      |
| node-exporter      | ~100m       | ~250m     | ~64 Mi         | ~128 Mi      |
| **Gesamt (ca.)**   | **~1150m**  | **~3000m**| **~1216 Mi**   | **~3432 Mi** |

*Werte fuer kube-state-metrics und node-exporter sind Schaetzwerte (abhaengig von der Helm Chart Konfiguration).*

---

## Deploymentreihenfolge

Die Komponenten muessen in folgender Reihenfolge deployed werden:

1. **kube-state-metrics** und **node-exporter** (keine Abhaengigkeiten untereinander, koennen parallel deployed werden)
2. **Loki** (benoetigt S3-Credentials aus OpenBao)
3. **Mimir** (benoetigt S3-Credentials aus OpenBao)
4. **Tempo** (benoetigt S3-Credentials)
5. **Alloy** (benoetigt Loki und Mimir als Endpoints)
6. **Grafana** (benoetigt Loki, Mimir und Tempo als Datasources)

**Hinweis:** Loki, Mimir und Tempo koennen auch parallel deployed werden, da sie keine Abhaengigkeiten untereinander haben. Alloy und Grafana muessen jedoch warten, bis ihre jeweiligen Backends verfuegbar sind.
