# Phase 3: Monitoring - Observability Stack

## Overview

**Goal:** Complete observability stack for the K8s cluster covering all three pillars of observability: logs, metrics, and traces.

**Prerequisites:**
- Phase 2 (Platform) fully completed
- Garage S3 buckets created and API keys stored in OpenBao:
  - `loki-chunks` (log data)
  - `mimir-blocks` (metric data)
  - `tempo-traces` (trace data)
- External Secrets Operator (ESO) configured with ClusterSecretStore `openbao`

**Architecture:**

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
                    │  (Logs)  │    │(Metrics) │     │ (Traces) │
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

**Components and Versions:**

| Component          | Version  | Helm Chart Version | Deployment Type  |
|--------------------|----------|--------------------|------------------|
| Loki               | 3.6.7    | 6.55.0             | Helm (SingleBinary) |
| Mimir              | 3.0.4    | -                  | Kustomize (Standalone) |
| Tempo              | 2.10.3   | 1.24.4             | Helm             |
| Alloy              | v1.14.1  | 1.6.2              | Helm (DaemonSet) |
| Grafana            | 12.4.1   | 10.5.15            | Helm             |
| kube-state-metrics | -        | prometheus-community | Helm            |
| node-exporter      | -        | prometheus-community | Helm (DaemonSet) |

**All container images are pulled from the internal Artifactory registry (`artifactory.cfapps.cool`) and are ARM64-compatible.**

---

## 3.1 Loki (Log Aggregation)

### Description

Loki is the log aggregation backend. It receives logs from Alloy and stores them in Garage S3. Unlike Elasticsearch/OpenSearch, Loki only indexes labels (not the log content itself), making it resource-efficient.

### Deployment

- **Mode:** SingleBinary (`deploymentMode: SingleBinary`) - all Loki components run in a single pod
- **Replicas:** 1
- **Namespace:** `loki`
- **Helm Chart:** `grafana/loki` Version 6.55.0
- **Persistence:** 10 Gi PVC (local-path)

### Installation

```bash
helm dependency update k8/monitoring/loki
helm install loki k8/monitoring/loki -n loki --create-namespace
```

### S3 Backend Configuration

Loki stores chunks and index data in the Garage S3 bucket `loki-chunks`:

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

Loki supports environment variable substitution in its config (`${VAR}`). The credentials are injected as environment variables from the Kubernetes Secret.

### Credentials via ExternalSecret

The S3 credentials are automatically synced from OpenBao:

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

The environment variables are set in the `singleBinary.extraEnv` block:

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

### Schema Configuration

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

- **Store:** TSDB (Time Series Database) - the current default store
- **Schema Version:** v13
- **Index Period:** 24 hours

### Important Settings

- `auth_enabled: false` - multi-tenancy is disabled (single-node setup)
- `replication_factor: 1` - no replication (single-node)
- Gateway, caches, self-monitoring, and canary are disabled (unnecessary in SingleBinary mode)
- Backend/Read/Write components set to 0 replicas (not needed in SingleBinary mode)

### Resources

```yaml
resources:
  requests:
    memory: 256Mi
    cpu: 250m
  limits:
    memory: 512Mi
    cpu: 500m
```

### Files

- `k8/monitoring/loki/Chart.yaml`
- `k8/monitoring/loki/values.yaml`
- `k8/monitoring/loki/templates/external-secret.yaml`

---

## 3.2 Mimir (Metrics)

### Description

Mimir is the metrics backend and receives metrics via Prometheus Remote Write from Alloy. It provides a Prometheus-compatible query API, allowing Grafana to use it as a Prometheus datasource.

### Why Kustomize Instead of Helm?

The official `mimir-distributed` Helm chart is designed for multi-node deployments and is extremely complex (dozens of microservices). For a single-node cluster, a simple standalone deployment with `-target=all` is significantly simpler and more resource-efficient.

### Deployment

- **Mode:** Standalone with `-target=all` (all Mimir components in a single process)
- **Replicas:** 1
- **Namespace:** `mimir`
- **Deployment Method:** Kustomize (ConfigMap + Deployment + Service + ExternalSecret)
- **Storage:** EmptyDir (no PVC - data resides in S3)

### Installation

```bash
kubectl create namespace mimir
kubectl apply -k k8/monitoring/mimir
```

### Kustomization Structure

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

### Mimir Configuration (ConfigMap)

The complete Mimir configuration is stored in a ConfigMap:

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

**Important:** Mimir supports environment variable expansion via the `-config.expand-env=true` flag. The placeholders `${MIMIR_S3_ACCESS_KEY}` and `${MIMIR_S3_SECRET_KEY}` are replaced with the actual values at runtime.

### Deployment Configuration

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

The credentials are loaded as environment variables from the Secret via `envFrom`. The Secret is synced from OpenBao by the External Secrets Operator:

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

### Storage Backends

| Component            | Backend     | Path             |
|----------------------|-------------|------------------|
| blocks_storage       | S3 (Garage) | mimir-blocks     |
| ruler_storage        | filesystem  | /data/ruler      |
| alertmanager_storage | filesystem  | /data/alertmanager |
| compactor            | filesystem  | /data/compactor  |
| tsdb                 | filesystem  | /data/tsdb       |

**Ruler and Alertmanager intentionally use local storage**, as these features are not actively used in the current setup and no separate S3 bucket is needed for them.

### Ring Configuration

For single-node operation:
- `instance_addr: 127.0.0.1` (Distributor and Ingester)
- `kvstore.store: memberlist` (no separate KV store required)
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

Mimir is accessible cluster-internally at `mimir.mimir.svc:8080`. Grafana uses `http://mimir.mimir.svc:8080/prometheus` as a Prometheus-compatible datasource.

### Readiness Probe

```yaml
readinessProbe:
  httpGet:
    path: /ready
    port: http
  initialDelaySeconds: 15
  periodSeconds: 10
```

### Resources

```yaml
resources:
  requests:
    memory: 256Mi
    cpu: 250m
  limits:
    memory: 1Gi
    cpu: 500m
```

### Files

- `k8/monitoring/mimir/kustomization.yaml`
- `k8/monitoring/mimir/configmap.yaml`
- `k8/monitoring/mimir/deployment.yaml`
- `k8/monitoring/mimir/service.yaml`
- `k8/monitoring/mimir/templates/external-secret.yaml`

---

## 3.3 Tempo (Distributed Tracing)

### Description

Tempo is the tracing backend and receives traces via OTLP (OpenTelemetry Protocol). It stores trace data in Garage S3 and makes it available through a query API for Grafana.

### Deployment

- **Replicas:** 1
- **Namespace:** `tempo`
- **Helm Chart:** `grafana/tempo` Version 1.24.4

### Installation

```bash
helm dependency update k8/monitoring/tempo
helm install tempo k8/monitoring/tempo -n tempo --create-namespace
```

### S3 Backend Configuration

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

### IMPORTANT: Credentials Handling for Tempo

**Tempo does NOT support environment variable substitution in its configuration file.** This is a key difference from Loki and Mimir:

- The S3 credentials must be placed **directly in the config**
- There is no `-config.expand-env` flag as with Mimir
- The config keys are named `access_key` and `secret_key` (NOT `access_key_id` and `secret_access_key` as with Loki/Mimir)

Since the credentials reside in the values.yaml, this file should be treated with extra care. An ExternalSecret template (`templates/external-secret.yaml`) exists, but the actual injection into the Tempo config requires different mechanisms than those used for Loki/Mimir.

### OTLP Receiver

Tempo accepts traces via the OpenTelemetry Protocol:

| Protocol  | Port | Endpoint         |
|-----------|------|------------------|
| gRPC      | 4317 | `0.0.0.0:4317`  |
| HTTP      | 4318 | `0.0.0.0:4318`  |

Applications can send traces directly to `tempo.tempo.svc:4317` (gRPC) or `tempo.tempo.svc:4318` (HTTP).

### Resources

```yaml
resources:
  requests:
    memory: 256Mi
    cpu: 250m
  limits:
    memory: 512Mi
    cpu: 500m
```

### Files

- `k8/monitoring/tempo/Chart.yaml`
- `k8/monitoring/tempo/values.yaml`
- `k8/monitoring/tempo/templates/external-secret.yaml`

---

## 3.4 Alloy (Collector)

### Description

Alloy is the central data collector (successor to Grafana Agent). It runs as a DaemonSet on every node and collects both logs and metrics. Alloy uses a declarative flow-based configuration.

### Deployment

- **Mode:** DaemonSet (one pod per node)
- **Namespace:** `alloy`
- **Helm Chart:** `grafana/alloy` Version 1.6.2

### Installation

```bash
helm dependency update k8/monitoring/alloy
helm install alloy k8/monitoring/alloy -n alloy --create-namespace
```

### Log Collection Pipeline

The log collection pipeline consists of three stages:

```
discovery.kubernetes "pods" → discovery.relabel "pods" → loki.source.file "pods"
  → loki.process "pods" → loki.write "default"
```

1. **Discovery:** `discovery.kubernetes "pods"` automatically discovers all pods in the cluster
2. **Relabeling:** Extracts relevant labels:
   - `namespace` - Kubernetes namespace
   - `pod` - pod name
   - `container` - container name
   - `node` - node name
   - `app` - app label (from `app` or `app.kubernetes.io/name`)
   - `__path__` - path to the log files (`/var/log/pods/...`)
3. **Log Opt-Out:** Pods with the annotation `alloy.grafana.com/logs.exclude: "true"` are excluded
4. **Processing:** CRI log format parsing and static label `source=kubernetes`
5. **Shipping:** Logs are sent to `http://loki.loki.svc:3100/loki/api/v1/push`

### Metrics Collection Pipeline

Alloy collects metrics from four sources:

#### 1. Kubelet Metrics

```
discovery.kubernetes "nodes" → discovery.relabel "nodes" → prometheus.scrape "kubelet"
```

- Accessed via the API server proxy: `kubernetes.default.svc:443/api/v1/nodes/<node>/proxy/metrics`
- Authentication via ServiceAccount token and CA certificate
- Scrape interval: 60 seconds

#### 2. cAdvisor Container Metrics

```
discovery.kubernetes "nodes" → discovery.relabel "cadvisor" → prometheus.scrape "cadvisor"
```

- Accessed via the API server proxy: `kubernetes.default.svc:443/api/v1/nodes/<node>/proxy/metrics/cadvisor`
- Provides container-level metrics (CPU, memory, filesystem, network per container)
- Scrape interval: 60 seconds

#### 3. kube-state-metrics (Auto-Discovery)

```
discovery.kubernetes "services" → discovery.relabel "kube_state_metrics" → prometheus.scrape "kube_state_metrics"
```

- Auto-discovery via the service label `app.kubernetes.io/name: kube-state-metrics`
- Scrape interval: 60 seconds

#### 4. node-exporter (Auto-Discovery)

```
discovery.kubernetes "endpoints" → discovery.relabel "node_exporter" → prometheus.scrape "node_exporter"
```

- Auto-discovery via the service label `app.kubernetes.io/name` with regex match `(node-exporter|prometheus-node-exporter)`
- Scrape interval: 60 seconds

#### Remote Write

All metrics are sent to Mimir via Prometheus Remote Write:

```
prometheus.remote_write "mimir" {
  endpoint {
    url = "http://mimir.mimir.svc:8080/api/v1/push"
  }
}
```

### IMPORTANT: RBAC Configuration

The default ClusterRole from the Alloy Helm chart does **not** include all required permissions for scraping kubelet and cAdvisor metrics. The following additional rules must be configured:

```yaml
extraClusterPolicies:
  - apiGroups: [""]
    resources: ["nodes", "nodes/proxy", "nodes/metrics"]
    verbs: ["get", "list", "watch"]
```

Without these permissions, the kubelet and cAdvisor scrapers will not return any data, resulting in empty dashboards in Grafana (see Troubleshooting section).

### Volume Mounts

```yaml
mounts:
  varlog: true    # Mounts /var/log from the host for log collection
```

### Resources

```yaml
resources:
  requests:
    memory: 128Mi
    cpu: 100m
  limits:
    memory: 512Mi
    cpu: 500m
```

### Files

- `k8/monitoring/alloy/Chart.yaml`
- `k8/monitoring/alloy/values.yaml`

---

## 3.5 kube-state-metrics

### Description

kube-state-metrics is a service that queries the Kubernetes API and generates metrics about the state of Kubernetes objects. Unlike kubelet/cAdvisor, it does not provide resource usage data but rather information about the desired and current state of objects.

### Provided Metrics (Selection)

| Metric Prefix              | Description                           |
|----------------------------|---------------------------------------|
| `kube_pod_*`               | Pod status, restarts, phase           |
| `kube_deployment_*`        | Deployment replicas, conditions       |
| `kube_daemonset_*`         | DaemonSet status                      |
| `kube_statefulset_*`       | StatefulSet replicas                  |
| `kube_node_*`              | Node status, conditions               |
| `kube_namespace_*`         | Namespace information                 |
| `kube_persistentvolume_*`  | PV/PVC status and capacity            |
| `kube_resourcequota_*`     | Resource quota usage                  |

### Deployment

- **Helm Chart:** `prometheus-community/kube-state-metrics`
- **Replicas:** 1

### Installation

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-state-metrics prometheus-community/kube-state-metrics -n monitoring --create-namespace
```

### Integration with Alloy

kube-state-metrics is automatically discovered by Alloy via the service label `app.kubernetes.io/name: kube-state-metrics`. No manual configuration of scrape targets is required.

---

## 3.6 node-exporter

### Description

The Prometheus Node Exporter runs as a DaemonSet and collects host-level metrics from every node. It provides detailed information about the physical/virtual hardware.

### Provided Metrics (Selection)

| Metric Prefix          | Description                                |
|------------------------|--------------------------------------------|
| `node_cpu_*`           | CPU utilization, frequency, temperatures   |
| `node_memory_*`        | RAM usage (total, free, cached, buffers)   |
| `node_disk_*`          | Disk I/O (reads, writes, bytes)            |
| `node_filesystem_*`    | Filesystem usage (size, avail, free)       |
| `node_network_*`       | Network I/O (bytes, packets, errors)       |
| `node_load*`           | System load (1m, 5m, 15m)                  |
| `node_boot_time_*`     | Boot timestamp                             |
| `node_uname_info`      | Kernel/OS information                      |

### Deployment

- **Helm Chart:** `prometheus-community/prometheus-node-exporter`
- **Mode:** DaemonSet (one pod per node)

### Installation

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install node-exporter prometheus-community/prometheus-node-exporter -n monitoring --create-namespace
```

### Integration with Alloy

node-exporter is automatically discovered by Alloy via the service label `app.kubernetes.io/name` with the regex match `(node-exporter|prometheus-node-exporter)`. Discovery operates through Kubernetes Endpoints, so the actual pod IPs are used as scrape targets.

---

## 3.7 Grafana

### Description

Grafana is the central frontend for the entire observability stack. It visualizes logs (Loki), metrics (Mimir), and traces (Tempo) in a unified interface.

### Deployment

- **Version:** 12.4.1
- **Namespace:** `grafana`
- **Helm Chart:** `grafana/grafana` Version 10.5.15
- **Persistence:** 2 Gi PVC (local-path)

### Installation

```bash
helm dependency update k8/monitoring/grafana
helm install grafana k8/monitoring/grafana -n grafana --create-namespace
```

### Admin Credentials

The admin credentials are automatically synced from OpenBao:

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

In the Grafana configuration:

```yaml
admin:
  existingSecret: grafana-admin-credentials
  userKey: username
  passwordKey: password
```

### Provisioned Datasources

Three datasources are automatically provisioned at startup:

| Datasource | Type       | URL                                        | Default  |
|------------|------------|--------------------------------------------|----------|
| Loki       | loki       | `http://loki.loki.svc:3100`                | No       |
| Mimir      | prometheus | `http://mimir.mimir.svc:8080/prometheus`   | Yes      |
| Tempo      | tempo      | `http://tempo.tempo.svc:3100`              | No       |

**Tempo Integration:**
- Traces-to-logs linking with Loki enabled (`tracesToLogsV2`)
- Node graph visualization enabled

### IngressRoute

Grafana is externally accessible at:

```
https://grafana.development.cfapps.cool
```

Configured as a Traefik IngressRoute:

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

### initChownData Disabled

```yaml
initChownData:
  enabled: false
```

The `initChownData` init container is disabled because it can cause permission issues when using the local-path provisioner. The PVC directories already have the correct permissions.

### Custom Dashboards

Dashboards are provisioned via a ConfigMap:

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

The dashboard JSON files are located in `k8/monitoring/grafana/dashboards/`.

### Resources

```yaml
resources:
  requests:
    memory: 128Mi
    cpu: 100m
  limits:
    memory: 512Mi
    cpu: 500m
```

### Files

- `k8/monitoring/grafana/Chart.yaml`
- `k8/monitoring/grafana/values.yaml`
- `k8/monitoring/grafana/templates/ingressroute.yaml`
- `k8/monitoring/grafana/templates/external-secret.yaml`
- `k8/monitoring/grafana/dashboards/k8s-operations.json`

---

## Dashboard: K8s Operations

The custom "K8s Operations" dashboard provides a comprehensive overview of the cluster state. It is divided into several sections:

### Cluster Health

- **Node Status:** Number of active nodes
- **Running Pods:** Total number of running pods
- **Pod Restarts:** Total number of container restarts (last 24h)
- **CPU Gauge:** Current CPU utilization in percent
- **Memory Gauge:** Current RAM utilization in percent
- **Disk Gauge:** Current disk utilization in percent

### Node Resources

- **CPU Utilization:** Time series (user, system, iowait, idle)
- **Memory Usage:** Time series (used, cached, buffers, free)
- **System Load:** 1min, 5min, 15min averages
- **Network I/O:** Received and transmitted bytes per second
- **Disk I/O:** Read/write operations and bytes per second

### Workloads by Namespace

- **CPU by Namespace:** Stacked chart of CPU usage per namespace
- **Memory by Namespace:** Stacked chart of RAM usage per namespace

### Top Consumers

- **Top 10 CPU Pods:** The 10 pods with the highest CPU consumption
- **Top 10 Memory Pods:** The 10 pods with the highest memory consumption

### Container Restarts & Issues

- Table of pods that have experienced restarts
- Container status overview (Running, Waiting, Terminated)

### Persistent Volumes Usage

- PVC utilization (used vs. available)
- Warnings for high utilization

---

## Troubleshooting

### "no data" in Grafana Dashboards

**Symptom:** Dashboards show no metrics even though all pods are running.

**Cause:** Alloy lacks sufficient RBAC permissions to retrieve kubelet and cAdvisor metrics via the API server proxy.

**Solution:** Ensure that the ClusterRole includes permissions for `nodes/proxy`:

```yaml
extraClusterPolicies:
  - apiGroups: [""]
    resources: ["nodes", "nodes/proxy", "nodes/metrics"]
    verbs: ["get", "list", "watch"]
```

**Diagnosis:**

```bash
# Check Alloy logs
kubectl logs -n alloy -l app.kubernetes.io/name=alloy

# Check ClusterRole
kubectl get clusterrole -l app.kubernetes.io/name=alloy -o yaml

# Manually test whether the API server proxy is working
kubectl get --raw "/api/v1/nodes/<node-name>/proxy/metrics" | head -5
```

### Community Dashboards Show "No data"

**Symptom:** Imported community dashboards (e.g., from grafana.com) show no data even though custom dashboards work correctly.

**Cause:** Many community dashboards use a `cluster` template variable in their PromQL queries (e.g., `{cluster="$cluster"}`). In a single-node setup, this label does not exist because no cluster name is set in the metrics.

**Solution:**
- Edit the dashboard JSON and remove `cluster="$cluster"` from all queries
- Or: Set the `cluster` variable to an empty value in the dashboard (if possible)
- Alternatively: Create custom dashboards that do not use a `cluster` variable (recommended)

### Mimir 502 Bad Gateway

**Symptom:** Grafana shows 502 errors for metric queries.

**Cause:** Incorrect service name in the datasource configuration. The `mimir-distributed` Helm chart would create a service named `mimir-gateway`. Since a Kustomize deployment is used here, the service is simply named `mimir`.

**Solution:** Ensure that the Grafana datasource URL is correct:

```
# Correct (Kustomize deployment):
http://mimir.mimir.svc:8080/prometheus

# Incorrect (would refer to the mimir-distributed Helm chart):
http://mimir-gateway.mimir.svc/prometheus
```

### Loki "no data" Despite Running Alloy

**Diagnosis:**

```bash
# Check whether Alloy is sending logs to Loki
kubectl logs -n alloy -l app.kubernetes.io/name=alloy | grep -i "loki\|error"

# Check whether Loki is reachable
kubectl exec -n alloy <alloy-pod> -- wget -qO- http://loki.loki.svc:3100/ready

# Check whether S3 credentials are correct
kubectl get externalsecret -n loki loki-s3-credentials
kubectl get secret -n loki loki-s3-credentials
```

### Tempo Not Receiving Traces

**Diagnosis:**

```bash
# Check whether the OTLP receiver is running
kubectl logs -n tempo -l app.kubernetes.io/name=tempo | grep -i "otlp\|receiver"

# Send a test trace (gRPC)
# From a pod inside the cluster:
# grpcurl -plaintext tempo.tempo.svc:4317 list

# Check S3 connectivity
kubectl logs -n tempo -l app.kubernetes.io/name=tempo | grep -i "s3\|storage\|error"
```

---

## Resource Overview

Total resource consumption of the monitoring stack:

| Component          | CPU Request | CPU Limit | Memory Request | Memory Limit |
|--------------------|-------------|-----------|----------------|--------------|
| Loki               | 250m        | 500m      | 256 Mi         | 512 Mi       |
| Mimir              | 250m        | 500m      | 256 Mi         | 1 Gi         |
| Tempo              | 250m        | 500m      | 256 Mi         | 512 Mi       |
| Alloy (DaemonSet)  | 100m        | 500m      | 128 Mi         | 512 Mi       |
| Grafana            | 100m        | 500m      | 128 Mi         | 512 Mi       |
| kube-state-metrics | ~100m       | ~250m     | ~128 Mi        | ~256 Mi      |
| node-exporter      | ~100m       | ~250m     | ~64 Mi         | ~128 Mi      |
| **Total (approx.)**| **~1150m**  | **~3000m**| **~1216 Mi**   | **~3432 Mi** |

*Values for kube-state-metrics and node-exporter are estimates (depending on the Helm chart configuration).*

---

## Deployment Order

The components must be deployed in the following order:

1. **kube-state-metrics** and **node-exporter** (no dependencies on each other, can be deployed in parallel)
2. **Loki** (requires S3 credentials from OpenBao)
3. **Mimir** (requires S3 credentials from OpenBao)
4. **Tempo** (requires S3 credentials)
5. **Alloy** (requires Loki and Mimir as endpoints)
6. **Grafana** (requires Loki, Mimir, and Tempo as datasources)

**Note:** Loki, Mimir, and Tempo can also be deployed in parallel since they have no dependencies on each other. However, Alloy and Grafana must wait until their respective backends are available.
