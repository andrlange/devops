# Phase 5: GitLab CE + Runner

## Overview

**Goal:** Deploy a self-hosted GitLab CE instance as a code hosting platform with an integrated Kubernetes CI/CD Runner. GitLab runs as an Omnibus container (StatefulSet) -- not via the official GitLab Helm Chart, as it is unnecessarily complex for single-node setups.

**Prerequisites:**
- Phase 4 (Services) fully completed
- External Secrets Operator (ESO) with ClusterSecretStore `openbao` configured
- OpenBao unsealed and reachable
- Traefik IngressRoute and cert-manager active for TLS termination
- MetalLB configured for LoadBalancer services
- Container images imported into the registry:
  - `gitlab/gitlab-ce:18.10.0-ce.0` (~1.5GB)
  - `gitlab-org/gitlab-runner:alpine-v18.10.0`
  - `gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v18.10.0`

**Resource requirements:** 4-10 GiB RAM (GitLab Omnibus is very memory-intensive)

**Architecture:**

```
                     ┌──────────────────────────────────────┐
                     │      Traefik IngressRoute            │
                     │  gitlab.development.cfapps.cool      │
                     └──────────────┬───────────────────────┘
                                    │
                                    ▼ (HTTPS → HTTP)
                     ┌──────────────────────────────────────┐
                     │      GitLab CE Omnibus               │
                     │    StatefulSet (1 Replica)           │
                     │     18.10.0-ce.0 (ARM64)             │
                     │                                      │
                     │  ┌────────┐ ┌────────┐ ┌──────┐      │
                     │  │  Puma  │ │Sidekiq │ │nginx │      │
                     │  │(2 Wrkr)│ │(C: 5)  │ │:80   │      │
                     │  └────────┘ └────────┘ └──────┘      │
                     │  ┌─────────────────────────┐         │
                     │  │  PostgreSQL (built-in)  │         │
                     │  └─────────────────────────┘         │
                     └────┬─────────┬─────────┬─────────────┘
                          │         │         │
                    ┌─────┘    ┌────┘    ┌────┘
                    ▼          ▼         ▼
             ┌──────────┐ ┌────────┐ ┌───────┐
             │  data    │ │ config │ │ logs  │
             │  50Gi    │ │  1Gi   │ │  5Gi  │
             └──────────┘ └────────┘ └───────┘

    ┌─────────────────────────┐      ┌──────────────────────┐
    │    LoadBalancer :22     │      │   GitLab Runner      │
    │ (MetalLB 192.168.64.202)│      │  (Helm, NS: gitlab-  │
    │       SSH access        │      │   runner)            │
    └─────────────────────────┘      │  K8s Executor →      │
                                     │  Jobs in NS:         │
                                     │  gitlab-runner-jobs  │
                                     └──────────────────────┘
```

**Components and versions:**

| Component          | Version              | Deployment method               |
|--------------------|----------------------|---------------------------------|
| GitLab CE Omnibus  | 18.10.0-ce.0         | Kustomize (StatefulSet)         |
| GitLab Runner      | alpine-v18.10.0      | Helm Chart (v0.87.0)            |

**All container images are pulled from the internal Artifactory registry (`artifactory.cfapps.cool`) and are ARM64-compatible.**

---

## 5.1 GitLab CE

GitLab CE is deployed as an Omnibus container in a StatefulSet. All internal services (PostgreSQL, Redis, Puma, Sidekiq, nginx) run within the same container.

### Kustomization

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: gitlab
resources:
  - namespace.yaml
  - external-secrets.yaml
  - pvc.yaml
  - statefulset.yaml
  - service.yaml
  - service-ssh.yaml
  - configmap.yaml
  - ingressroute.yaml
commonLabels:
  app.kubernetes.io/part-of: gitlab
  app.kubernetes.io/managed-by: kustomize
```

### Persistent Volume Claims

GitLab requires three separate PVCs for data, configuration, and logs:

| PVC            | Size    | Mount path          | Contents                      |
|----------------|---------|---------------------|-------------------------------|
| gitlab-data    | 50Gi    | /var/opt/gitlab     | Repositories, uploads, DB     |
| gitlab-config  | 1Gi     | /etc/gitlab         | gitlab.rb, certificates       |
| gitlab-logs    | 5Gi     | /var/log/gitlab     | Logs from all services        |

All PVCs use the StorageClass `local-path`.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitlab-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 50Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitlab-config
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitlab-logs
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

### ConfigMap (gitlab.rb)

The entire GitLab configuration is provided via the `GITLAB_OMNIBUS_CONFIG` environment variable, which is loaded from a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitlab-config
data:
  gitlab.rb: |
    external_url 'https://gitlab.development.cfapps.cool'

    # Nginx: HTTP only internally, Traefik terminates TLS
    nginx['listen_port'] = 80
    nginx['listen_https'] = false
    nginx['proxy_set_headers'] = {
      "X-Forwarded-Proto" => "https",
      "X-Forwarded-Ssl" => "on"
    }

    # SSH configuration
    gitlab_rails['gitlab_shell_ssh_port'] = 22

    # Resources reduced for single-node setup
    puma['worker_processes'] = 2
    sidekiq['concurrency'] = 5

    # Built-in monitoring disabled (dedicated stack available)
    prometheus_monitoring['enable'] = false
    node_exporter['enable'] = false

    # Container Registry disabled (artifact-keeper available)
    registry['enable'] = false
```

**Important configuration notes:**

- `external_url` must contain `https://`, even though nginx only listens on port 80 internally. Traefik terminates TLS.
- The `proxy_set_headers` are mandatory for GitLab to generate correct HTTPS redirect URLs.
- Puma workers and Sidekiq concurrency are intentionally kept low to limit memory consumption on a single-node cluster.
- Prometheus monitoring and the container registry are disabled, as the dedicated monitoring stack and artifact-keeper provide these functions.

**IMPORTANT -- GitLab 18.x Breaking Changes:**

The following configuration keys have been removed in GitLab 18.x and MUST NOT be set in `gitlab.rb`. They cause a `FATAL: unsupported configuration value` error on startup:

- `grafana['enable']`
- `alertmanager['enable']`

### ExternalSecret (Root Password)

The GitLab root password is loaded from OpenBao via an ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: gitlab-admin-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: gitlab-admin-credentials
  data:
    - secretKey: GITLAB_ROOT_PASSWORD
      remoteRef:
        key: secret/gitlab/admin
        property: root_password
```

The secret is referenced in the StatefulSet as the environment variable `GITLAB_ROOT_PASSWORD`. GitLab only uses this password during the initial setup -- subsequent changes must be made via the GitLab UI.

### StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: gitlab
spec:
  serviceName: gitlab
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: gitlab
      app.kubernetes.io/component: server
  template:
    spec:
      imagePullSecrets:
        - name: artifact-keeper-pull
      containers:
        - name: gitlab
          image: artifactory.cfapps.cool/docker-local/gitlab/gitlab-ce:18.10.0-ce.0-arm64
          ports:
            - name: http
              containerPort: 80
            - name: ssh
              containerPort: 22
          env:
            - name: GITLAB_OMNIBUS_CONFIG
              valueFrom:
                configMapKeyRef:
                  name: gitlab-config
                  key: gitlab.rb
            - name: GITLAB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: gitlab-admin-credentials
                  key: GITLAB_ROOT_PASSWORD
          resources:
            requests:
              memory: 4Gi
              cpu: 1000m
            limits:
              memory: 10Gi
              cpu: 4000m
```

**Resources:** GitLab Omnibus requires at least 4 GiB RAM. The 10 GiB limit provides sufficient headroom for peak loads during CI/CD activity and large repository operations.

### Health Probes

Health probes must be `exec`-based. HTTP-based probes (`httpGet`) fail because GitLab's internal nginx returns `404` when services are not fully started, instead of the expected error code.

```yaml
startupProbe:
  exec:
    command: ["curl", "-sf", "http://localhost/-/liveness"]
  initialDelaySeconds: 120
  periodSeconds: 15
  timeoutSeconds: 10
  failureThreshold: 80
livenessProbe:
  exec:
    command: ["curl", "-sf", "http://localhost/-/liveness"]
  initialDelaySeconds: 300
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 5
readinessProbe:
  exec:
    command: ["curl", "-sf", "http://localhost/-/readiness"]
  initialDelaySeconds: 30
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 10
```

The `startupProbe` is particularly important: GitLab requires 5-10 minutes for the initial startup (reconfigure + database migration). With `failureThreshold: 80` and `periodSeconds: 15`, this allows a maximum startup time of 20 minutes.

### Services

**HTTP Service (ClusterIP):**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gitlab
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: gitlab
    app.kubernetes.io/component: server
  ports:
    - name: http
      port: 80
      targetPort: http
```

The ClusterIP service is used by the Traefik IngressRoute. There is no external access to HTTP -- all traffic goes through HTTPS via Traefik.

**SSH Service (LoadBalancer):**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gitlab-ssh
  annotations:
    metallb.universe.tf/loadBalancerIPs: "192.168.64.202"
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: gitlab
    app.kubernetes.io/component: server
  ports:
    - name: ssh
      port: 22
      targetPort: 22
```

The SSH service receives a fixed IP address (`192.168.64.202`) via MetalLB. This allows repositories to be cloned over SSH:

```bash
git clone git@192.168.64.202:group/project.git
```

### IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: gitlab
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`gitlab.development.cfapps.cool`)
      kind: Rule
      services:
        - name: gitlab
          port: 80
  tls: {}
```

`tls: {}` uses Traefik's default TLS store, which uses the wildcard certificate from cert-manager.

---

## 5.2 GitLab Runner (Kubernetes Executor)

The GitLab Runner is deployed as a separate Helm Chart and uses the Kubernetes Executor. CI/CD jobs are executed as standalone pods in the `gitlab-runner-jobs` namespace.

### Helm Chart

```yaml
# Chart.yaml
apiVersion: v2
name: gitlab-runner
description: GitLab Runner with Kubernetes executor
version: 0.1.0
appVersion: "18.10.0"
dependencies:
  - name: gitlab-runner
    version: "0.87.0"
    repository: https://charts.gitlab.io
```

### Values

```yaml
gitlab-runner:
  image:
    registry: artifactory.cfapps.cool
    image: docker-local/gitlab-org/gitlab-runner
    tag: alpine-v18.10.0-arm64

  imagePullSecrets:
    - name: artifact-keeper-pull

  gitlabUrl: https://gitlab.development.cfapps.cool/

  rbac:
    create: true
    clusterWideAccess: true

  runners:
    secret: gitlab-runner-secret
    config: |
      [[runners]]
        [runners.kubernetes]
          namespace = "gitlab-runner-jobs"
          image = "alpine:3.21"
          privileged = false
          pull_policy = ["if-not-present"]
          [runners.kubernetes.pod_security_context]
            run_as_non_root = true
            run_as_user = 1000
          [runners.kubernetes.pod_labels]
            "app.kubernetes.io/managed-by" = "gitlab-runner"

  resources:
    requests:
      memory: 128Mi
      cpu: 100m
    limits:
      memory: 256Mi
      cpu: 250m
```

**Runner configuration details:**

- **Namespace for jobs:** `gitlab-runner-jobs` -- jobs are executed in a separate namespace to keep the runner namespace clean.
- **Default image:** `alpine:3.21` -- used when `.gitlab-ci.yml` does not specify an image.
- **Non-privileged:** `privileged = false` -- no Docker-in-Docker for security reasons. Use Kaniko or Buildah for container builds.
- **Pod Security Context:** `run_as_non_root = true`, `run_as_user = 1000` -- jobs never run as root.
- **Pull Policy:** `if-not-present` -- avoids unnecessary image downloads on the single-node cluster.

### ExternalSecret (Runner Token)

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: gitlab-runner-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: gitlab-runner-secret
  data:
    - secretKey: runner-token
      remoteRef:
        key: secret/gitlab/runner
        property: token
    - secretKey: runner-registration-token
      remoteRef:
        key: secret/gitlab/runner
        property: token
```

**IMPORTANT:** The Kubernetes Secret must contain TWO keys (`runner-token` and `runner-registration-token`), even though both reference the same value. The GitLab Runner Helm Chart expects both keys -- if one is missing, a PANIC error occurs on startup.

### Helper Image

The GitLab Runner additionally requires the helper image `gitlab-runner-helper`. This is automatically used by jobs for Git operations, artifact upload, and cache management. It must be imported into the registry as the ARM64 variant:

```
gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v18.10.0
```

---

## Deployment Steps

### Automated (recommended)

The simplest approach is to use `distribution/install.sh`:

```bash
./install.sh phase 5
```

The script automatically performs the following steps:

1. **Create secrets:** Generates a random root password and stores it in OpenBao at `secret/gitlab/admin`.
2. **Deploy GitLab:** Runs `kubectl apply -k services/gitlab-ce/` and waits up to 15 minutes for startup.
3. **Check API availability:** Waits for HTTP 200 from `/-/readiness`.
4. **Create temporary PAT:** Generates a short-lived Personal Access Token (valid for 1 hour) via `gitlab-rails runner` with the scopes `api` and `create_runner`.
5. **Register instance runner:** Calls the GitLab API `/api/v4/user/runners` to register an instance-wide runner (tags: `k8s`, `docker`).
6. **Store runner token:** Writes the obtained runner token to OpenBao at `secret/gitlab/runner`.
7. **Deploy runner:** Runs `helm install gitlab-runner` in the `gitlab-runner` namespace with the token from the ExternalSecret.

The entire process is idempotent and can be retried in case of errors. Already completed steps are skipped.

### Manual

If automated deployment is not possible:

**Step 1: Create secrets in OpenBao**

```bash
# Generate and store root password
GITLAB_ROOT_PASS=$(openssl rand -base64 16)
kubectl exec -n openbao openbao-0 -- bao kv put secret/gitlab/admin \
  root_password="$GITLAB_ROOT_PASS"
echo "Root password: $GITLAB_ROOT_PASS"
```

**Step 2: Deploy GitLab CE**

```bash
kubectl apply -k services/gitlab-ce/
```

**Step 3: Wait for startup (5-10 minutes)**

```bash
# Watch status
kubectl get pods -n gitlab -w

# Follow logs
kubectl logs -n gitlab gitlab-0 -f
```

**Step 4: Create PAT and register runner**

```bash
# Create temporary PAT
PAT=$(kubectl exec -n gitlab gitlab-0 -- gitlab-rails runner "
  token = User.find_by_username('root').personal_access_tokens.create!(
    name: 'runner-setup',
    scopes: ['api', 'create_runner'],
    expires_at: 1.hour.from_now
  )
  puts token.token
" 2>/dev/null | tail -1)

# Register instance runner
RUNNER_TOKEN=$(curl -sk --request POST \
  "https://gitlab.development.cfapps.cool/api/v4/user/runners" \
  --header "PRIVATE-TOKEN: ${PAT}" \
  --form "runner_type=instance_type" \
  --form "description=k8s-runner" \
  --form "tag_list=k8s,docker" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['token'])")
```

**Step 5: Store runner token in OpenBao**

```bash
kubectl exec -n openbao openbao-0 -- bao kv put secret/gitlab/runner \
  token="$RUNNER_TOKEN"
```

**Step 6: Deploy runner**

```bash
kubectl create namespace gitlab-runner
kubectl create namespace gitlab-runner-jobs
helm dependency update services/gitlab-ce/runner/
helm install gitlab-runner services/gitlab-ce/runner/ -n gitlab-runner
```

---

## Validation

### GitLab UI

```bash
# Open browser
open https://gitlab.development.cfapps.cool

# Login: root / password from OpenBao
kubectl exec -n openbao openbao-0 -- bao kv get -field=root_password secret/gitlab/admin
```

### SSH Access

```bash
ssh git@192.168.64.202
# Expected response: "Welcome to GitLab, @root!"
```

### Verify Runner

In the GitLab web UI: **Admin > CI/CD > Runners** -- the `k8s-runner` should be displayed as "online".

### Test Pipeline

Create a new project and add the following `.gitlab-ci.yml`:

```yaml
test:
  script:
    - echo "GitLab Runner is working!"
    - uname -a
    - cat /etc/os-release
  tags:
    - k8s
```

After the commit, the pipeline should start automatically and a pod should be created in the `gitlab-runner-jobs` namespace:

```bash
kubectl get pods -n gitlab-runner-jobs -w
```

---

## Container Images

The following images must be imported into the internal Artifactory registry before deployment:

| Image                                                      | Size     | Purpose             |
|------------------------------------------------------------|----------|---------------------|
| `gitlab/gitlab-ce:18.10.0-ce.0`                            | ~1.5 GB  | GitLab CE server    |
| `gitlab-org/gitlab-runner:alpine-v18.10.0`                 | ~100 MB  | Runner process      |
| `gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v18.10.0` | ~50 MB | Helper for CI jobs  |

All images must be available as ARM64 variants.

---

## Known Limitations

- **High memory consumption:** GitLab Omnibus requires 4-10 GiB RAM. On a single-node cluster with 64 GB, this is acceptable but can become tight when all services are running simultaneously.
- **Long startup time:** The first start takes 5-10 minutes due to the initial reconfigure and database migration. Subsequent starts are somewhat faster (~3-5 minutes).
- **OpenBao dependency:** After a VM restart, OpenBao must be unsealed first before the ExternalSecrets for GitLab and the runner can be resolved.
- **HTTP probes not usable:** GitLab's internal nginx returns `404` when services are not fully started. Therefore, all health probes must be `exec`-based.
- **GitLab 18.x configuration changes:** The configuration keys `grafana['enable']` and `alertmanager['enable']` have been removed and must not be present in `gitlab.rb`.

---

## Troubleshooting

### OOM Kill (Exit Code 137)

GitLab was terminated due to insufficient memory.

```bash
# Check current memory consumption
kubectl top pod -n gitlab

# Increase memory limit in the StatefulSet (e.g., to 12Gi)
# In statefulset.yaml: adjust limits.memory
```

### Startup Probe Timeout

GitLab is killed before it has finished starting.

```bash
# Check logs
kubectl logs -n gitlab gitlab-0 --tail=50

# Increase failureThreshold in the startupProbe
# Current: 80 * 15s = 20 minutes maximum
```

### FATAL: unsupported configuration value

A configuration key in `gitlab.rb` is no longer valid in GitLab 18.x.

```bash
# Find the error message in the logs
kubectl logs -n gitlab gitlab-0 | grep FATAL

# Remove the affected key from the ConfigMap
# Known removed keys: grafana['enable'], alertmanager['enable']
```

### Runner PANIC: registration-token

The runner pod crashes with a registration token error.

**Cause:** The Kubernetes Secret `gitlab-runner-secret` does not contain both expected keys.

```bash
# Check the secret
kubectl get secret gitlab-runner-secret -n gitlab-runner -o jsonpath='{.data}' | python3 -m json.tool

# The secret must contain both keys:
# - runner-token
# - runner-registration-token
# Both must have the same token value
```

### GitLab API Not Reachable After Startup

```bash
# Check pod status
kubectl get pods -n gitlab

# Check readiness (only available after full startup)
curl -sk https://gitlab.development.cfapps.cool/-/readiness

# Check DNS resolution
nslookup gitlab.development.cfapps.cool
```

### Runner Does Not Register

```bash
# Check runner logs
kubectl logs -n gitlab-runner -l app=gitlab-runner --tail=50

# Is the GitLab URL reachable from the runner?
kubectl exec -n gitlab-runner -it $(kubectl get pods -n gitlab-runner -o name | head -1) -- \
  wget -qO- --no-check-certificate https://gitlab.development.cfapps.cool/-/readiness
```

---

## File Structure

```
services/gitlab-ce/
├── namespace.yaml              # Namespace 'gitlab'
├── kustomization.yaml          # Kustomize definition
├── configmap.yaml              # gitlab.rb configuration
├── external-secrets.yaml       # Root password from OpenBao
├── pvc.yaml                    # 3 PVCs (data, config, logs)
├── statefulset.yaml            # GitLab CE Omnibus container
├── service.yaml                # ClusterIP :80 (HTTP)
├── service-ssh.yaml            # LoadBalancer :22 (SSH via MetalLB)
├── ingressroute.yaml           # Traefik IngressRoute (HTTPS)
└── runner/
    ├── Chart.yaml              # Helm Chart with gitlab-runner dependency
    ├── values.yaml             # Runner configuration (K8s Executor)
    └── templates/
        └── external-secret.yaml # Runner token from OpenBao
```
