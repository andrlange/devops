# Phase 5: GitLab CE + Runner

## Uebersicht

**Ziel:** Deployment einer self-hosted GitLab CE Instanz als Code-Hosting-Plattform mit integriertem Kubernetes CI/CD Runner. GitLab wird als Omnibus-Container (StatefulSet) betrieben -- nicht ueber das offizielle GitLab Helm Chart, da dieses fuer Single-Node-Setups unnoetig komplex ist.

**Voraussetzungen:**
- Phase 4 (Services) vollstaendig abgeschlossen
- External Secrets Operator (ESO) mit ClusterSecretStore `openbao` konfiguriert
- OpenBao unsealed und erreichbar
- Traefik IngressRoute und cert-manager fuer TLS-Terminierung aktiv
- MetalLB fuer LoadBalancer-Services konfiguriert
- Container Images in die Registry importiert:
  - `gitlab/gitlab-ce:18.10.0-ce.0` (~1.5GB)
  - `gitlab-org/gitlab-runner:alpine-v18.10.0`
  - `gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v18.10.0`

**Ressourcenbedarf:** 4-10 GiB RAM (GitLab Omnibus ist sehr speicherintensiv)

**Architektur:**

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
                     │  │  PostgreSQL (eingebaut) │         │
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
    │       SSH-Zugang        │      │   runner)            │
    └─────────────────────────┘      │  K8s-Executor →      │
                                     │  Jobs in NS:         │
                                     │  gitlab-runner-jobs  │
                                     └──────────────────────┘
```

**Komponenten und Versionen:**

| Komponente         | Version              | Deployment-Art              |
|--------------------|----------------------|-----------------------------|
| GitLab CE Omnibus  | 18.10.0-ce.0         | Kustomize (StatefulSet)     |
| GitLab Runner      | alpine-v18.10.0      | Helm Chart (v0.87.0)        |

**Alle Container-Images werden ueber die interne Artifactory-Registry (`artifactory.cfapps.cool`) bezogen und sind ARM64-kompatibel.**

---

## 5.1 GitLab CE

GitLab CE wird als Omnibus-Container in einem StatefulSet deployt. Alle internen Dienste (PostgreSQL, Redis, Puma, Sidekiq, nginx) laufen im selben Container.

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

GitLab benoetigt drei getrennte PVCs fuer Daten, Konfiguration und Logs:

| PVC            | Groesse | Mount-Pfad         | Inhalt                        |
|----------------|---------|---------------------|-------------------------------|
| gitlab-data    | 50Gi    | /var/opt/gitlab     | Repositories, Uploads, DB     |
| gitlab-config  | 1Gi     | /etc/gitlab         | gitlab.rb, Zertifikate        |
| gitlab-logs    | 5Gi     | /var/log/gitlab     | Logs aller Dienste            |

Alle PVCs nutzen die StorageClass `local-path`.

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

Die gesamte GitLab-Konfiguration erfolgt ueber die Umgebungsvariable `GITLAB_OMNIBUS_CONFIG`, die aus einer ConfigMap geladen wird:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitlab-config
data:
  gitlab.rb: |
    external_url 'https://gitlab.development.cfapps.cool'

    # Nginx: nur HTTP intern, Traefik terminiert TLS
    nginx['listen_port'] = 80
    nginx['listen_https'] = false
    nginx['proxy_set_headers'] = {
      "X-Forwarded-Proto" => "https",
      "X-Forwarded-Ssl" => "on"
    }

    # SSH-Konfiguration
    gitlab_rails['gitlab_shell_ssh_port'] = 22

    # Ressourcen reduziert fuer Single-Node
    puma['worker_processes'] = 2
    sidekiq['concurrency'] = 5

    # Eingebautes Monitoring deaktiviert (eigener Stack vorhanden)
    prometheus_monitoring['enable'] = false
    node_exporter['enable'] = false

    # Container Registry deaktiviert (artifact-keeper vorhanden)
    registry['enable'] = false
```

**Wichtige Konfigurationshinweise:**

- `external_url` muss `https://` enthalten, obwohl nginx intern nur auf Port 80 hoert. Traefik terminiert TLS.
- Die `proxy_set_headers` sind zwingend notwendig, damit GitLab korrekte HTTPS-Redirect-URLs generiert.
- Puma Worker und Sidekiq Concurrency sind bewusst niedrig gehalten, um den Speicherverbrauch auf einem Single-Node-Cluster zu begrenzen.
- Prometheus Monitoring und Container Registry sind deaktiviert, da der eigene Monitoring-Stack und artifact-keeper diese Funktionen uebernehmen.

**WICHTIG -- GitLab 18.x Breaking Changes:**

Die folgenden Konfigurationsschluessel wurden in GitLab 18.x entfernt und duerfen NICHT in `gitlab.rb` gesetzt werden. Sie verursachen einen `FATAL: unsupported configuration value`-Fehler beim Start:

- `grafana['enable']`
- `alertmanager['enable']`

### ExternalSecret (Root-Passwort)

Das GitLab Root-Passwort wird ueber einen ExternalSecret aus OpenBao geladen:

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

Das Secret wird im StatefulSet als Umgebungsvariable `GITLAB_ROOT_PASSWORD` referenziert. GitLab nutzt dieses Passwort nur beim erstmaligen Setup -- spaetere Aenderungen muessen ueber die GitLab-UI erfolgen.

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

**Ressourcen:** GitLab Omnibus benoetigt mindestens 4 GiB RAM. Das Limit von 10 GiB gibt genuegend Spielraum fuer Spitzenlasten bei CI/CD-Aktivitaeten und grossen Repository-Operationen.

### Health Probes

Die Health Probes muessen `exec`-basiert sein. HTTP-basierte Probes (`httpGet`) schlagen fehl, weil GitLabs interner nginx bei nicht vollstaendig gestarteten Diensten `404` zurueckgibt, anstatt den erwarteten Fehlercode.

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

Die `startupProbe` ist besonders wichtig: GitLab benoetigt 5-10 Minuten fuer den initialen Start (Reconfigure + Datenbank-Migration). Mit `failureThreshold: 80` und `periodSeconds: 15` ergibt sich eine maximale Startup-Zeit von 20 Minuten.

### Services

**HTTP-Service (ClusterIP):**

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

Der ClusterIP-Service wird von der Traefik IngressRoute angesprochen. Kein externer Zugriff auf HTTP -- alles laeuft ueber HTTPS via Traefik.

**SSH-Service (LoadBalancer):**

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

Der SSH-Service bekommt ueber MetalLB eine feste IP-Adresse (`192.168.64.202`). Damit koennen Repositories per SSH geklont werden:

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

`tls: {}` nutzt den Default-TLS-Store von Traefik, der das Wildcard-Zertifikat von cert-manager verwendet.

---

## 5.2 GitLab Runner (Kubernetes Executor)

Der GitLab Runner wird als separates Helm Chart deployed und nutzt den Kubernetes Executor. CI/CD-Jobs werden als eigenstaendige Pods im Namespace `gitlab-runner-jobs` ausgefuehrt.

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

**Runner-Konfiguration im Detail:**

- **Namespace fuer Jobs:** `gitlab-runner-jobs` -- Jobs werden in einem separaten Namespace ausgefuehrt, damit der Runner-Namespace sauber bleibt.
- **Default Image:** `alpine:3.21` -- wird verwendet, wenn `.gitlab-ci.yml` kein Image spezifiziert.
- **Nicht-privilegiert:** `privileged = false` -- aus Sicherheitsgruenden kein Docker-in-Docker. Fuer Container-Builds Kaniko oder Buildah verwenden.
- **Pod Security Context:** `run_as_non_root = true`, `run_as_user = 1000` -- Jobs laufen nie als Root.
- **Pull Policy:** `if-not-present` -- vermeidet ueberfluessige Image-Downloads auf dem Single-Node-Cluster.

### ExternalSecret (Runner-Token)

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

**WICHTIG:** Das Kubernetes Secret muss ZWEI Keys enthalten (`runner-token` und `runner-registration-token`), obwohl beide denselben Wert referenzieren. Das Helm Chart des GitLab Runners erwartet beide Keys -- fehlt einer, kommt es zu einem PANIC-Fehler beim Start.

### Helper Image

Der GitLab Runner benoetigt zusaetzlich das Helper-Image `gitlab-runner-helper`. Dieses wird automatisch von Jobs genutzt fuer Git-Operationen, Artifact-Upload und Cache-Management. Es muss als ARM64-Variante in die Registry importiert werden:

```
gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v18.10.0
```

---

## Deployment-Schritte

### Automatisch (empfohlen)

Der einfachste Weg ist die Nutzung von `distribution/install.sh`:

```bash
./install.sh phase 5
```

Das Skript fuehrt automatisch folgende Schritte aus:

1. **Secrets erstellen:** Generiert ein zufaelliges Root-Passwort und speichert es in OpenBao unter `secret/gitlab/admin`.
2. **GitLab deployen:** `kubectl apply -k services/gitlab-ce/` und wartet bis zu 15 Minuten auf den Startup.
3. **API-Verfuegbarkeit pruefen:** Wartet auf HTTP 200 von `/-/readiness`.
4. **Temporaeren PAT erstellen:** Erzeugt via `gitlab-rails runner` einen kurzlebigen Personal Access Token (1 Stunde gueltig) mit den Scopes `api` und `create_runner`.
5. **Instance Runner registrieren:** Ruft die GitLab API `/api/v4/user/runners` auf, um einen Instance-weiten Runner zu registrieren (Tags: `k8s`, `docker`).
6. **Runner-Token speichern:** Schreibt den erhaltenen Runner-Token nach OpenBao unter `secret/gitlab/runner`.
7. **Runner deployen:** `helm install gitlab-runner` im Namespace `gitlab-runner` mit dem Token aus dem ExternalSecret.

Der gesamte Prozess ist idempotent und kann bei Fehlern wiederholt werden. Bereits abgeschlossene Schritte werden uebersprungen.

### Manuell

Falls das automatische Deployment nicht moeglich ist:

**Schritt 1: Secrets in OpenBao erstellen**

```bash
# Root-Passwort generieren und speichern
GITLAB_ROOT_PASS=$(openssl rand -base64 16)
kubectl exec -n openbao openbao-0 -- bao kv put secret/gitlab/admin \
  root_password="$GITLAB_ROOT_PASS"
echo "Root-Passwort: $GITLAB_ROOT_PASS"
```

**Schritt 2: GitLab CE deployen**

```bash
kubectl apply -k services/gitlab-ce/
```

**Schritt 3: Auf Startup warten (5-10 Minuten)**

```bash
# Status beobachten
kubectl get pods -n gitlab -w

# Logs verfolgen
kubectl logs -n gitlab gitlab-0 -f
```

**Schritt 4: PAT erstellen und Runner registrieren**

```bash
# Temporaeren PAT erstellen
PAT=$(kubectl exec -n gitlab gitlab-0 -- gitlab-rails runner "
  token = User.find_by_username('root').personal_access_tokens.create!(
    name: 'runner-setup',
    scopes: ['api', 'create_runner'],
    expires_at: 1.hour.from_now
  )
  puts token.token
" 2>/dev/null | tail -1)

# Instance Runner registrieren
RUNNER_TOKEN=$(curl -sk --request POST \
  "https://gitlab.development.cfapps.cool/api/v4/user/runners" \
  --header "PRIVATE-TOKEN: ${PAT}" \
  --form "runner_type=instance_type" \
  --form "description=k8s-runner" \
  --form "tag_list=k8s,docker" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['token'])")
```

**Schritt 5: Runner-Token in OpenBao speichern**

```bash
kubectl exec -n openbao openbao-0 -- bao kv put secret/gitlab/runner \
  token="$RUNNER_TOKEN"
```

**Schritt 6: Runner deployen**

```bash
kubectl create namespace gitlab-runner
kubectl create namespace gitlab-runner-jobs
helm dependency update services/gitlab-ce/runner/
helm install gitlab-runner services/gitlab-ce/runner/ -n gitlab-runner
```

---

## Validierung

### GitLab UI

```bash
# Browser oeffnen
open https://gitlab.development.cfapps.cool

# Login: root / Passwort aus OpenBao
kubectl exec -n openbao openbao-0 -- bao kv get -field=root_password secret/gitlab/admin
```

### SSH-Zugang

```bash
ssh git@192.168.64.202
# Erwartete Antwort: "Welcome to GitLab, @root!"
```

### Runner pruefen

Im GitLab Web-UI: **Admin > CI/CD > Runners** -- der `k8s-runner` sollte als "online" angezeigt werden.

### Test-Pipeline

Neues Projekt erstellen und folgende `.gitlab-ci.yml` hinzufuegen:

```yaml
test:
  script:
    - echo "GitLab Runner funktioniert!"
    - uname -a
    - cat /etc/os-release
  tags:
    - k8s
```

Nach dem Commit sollte die Pipeline automatisch starten und ein Pod im Namespace `gitlab-runner-jobs` erstellt werden:

```bash
kubectl get pods -n gitlab-runner-jobs -w
```

---

## Container Images

Folgende Images muessen vor dem Deployment in die interne Artifactory-Registry importiert werden:

| Image                                                      | Groesse  | Zweck              |
|------------------------------------------------------------|----------|---------------------|
| `gitlab/gitlab-ce:18.10.0-ce.0`                            | ~1.5 GB  | GitLab CE Server    |
| `gitlab-org/gitlab-runner:alpine-v18.10.0`                 | ~100 MB  | Runner-Prozess      |
| `gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v18.10.0` | ~50 MB | Helper fuer CI-Jobs |

Alle Images muessen als ARM64-Variante vorliegen.

---

## Bekannte Einschraenkungen

- **Hoher Speicherbedarf:** GitLab Omnibus benoetigt 4-10 GiB RAM. Auf einem Single-Node-Cluster mit 64 GB ist das vertretbar, kann aber bei gleichzeitiger Nutzung aller Dienste eng werden.
- **Langer Startup:** Der erste Start dauert 5-10 Minuten wegen initialer Reconfigure und Datenbank-Migration. Nachfolgende Starts sind etwas schneller (~3-5 Minuten).
- **OpenBao-Abhaengigkeit:** Nach einem VM-Neustart muss OpenBao zuerst unsealed werden, bevor die ExternalSecrets fuer GitLab und den Runner aufgeloest werden koennen.
- **HTTP-Probes nicht nutzbar:** GitLabs interner nginx gibt bei nicht vollstaendig gestarteten Diensten `404` zurueck. Daher muessen alle Health Probes `exec`-basiert sein.
- **GitLab 18.x Config-Aenderungen:** Die Konfigurationsschluessel `grafana['enable']` und `alertmanager['enable']` wurden entfernt und duerfen nicht in `gitlab.rb` stehen.

---

## Fehlerbehebung

### OOM Kill (Exit Code 137)

GitLab wurde wegen Speichermangel beendet.

```bash
# Aktuellen Speicherverbrauch pruefen
kubectl top pod -n gitlab

# Memory Limit im StatefulSet erhoehen (z.B. auf 12Gi)
# In statefulset.yaml: limits.memory anpassen
```

### Startup Probe Timeout

GitLab wird gekillt, bevor es fertig gestartet ist.

```bash
# Logs pruefen
kubectl logs -n gitlab gitlab-0 --tail=50

# failureThreshold in der startupProbe erhoehen
# Aktuell: 80 * 15s = 20 Minuten Maximum
```

### FATAL: unsupported configuration value

Ein Konfigurationsschluessel in `gitlab.rb` ist in GitLab 18.x nicht mehr gueltig.

```bash
# Fehlermeldung in den Logs finden
kubectl logs -n gitlab gitlab-0 | grep FATAL

# Den betroffenen Key aus der ConfigMap entfernen
# Bekannte entfernte Keys: grafana['enable'], alertmanager['enable']
```

### Runner PANIC: registration-token

Der Runner-Pod crashed mit einem Fehler zum Registration-Token.

**Ursache:** Das Kubernetes Secret `gitlab-runner-secret` enthaelt nicht beide erwarteten Keys.

```bash
# Secret pruefen
kubectl get secret gitlab-runner-secret -n gitlab-runner -o jsonpath='{.data}' | python3 -m json.tool

# Das Secret muss beide Keys enthalten:
# - runner-token
# - runner-registration-token
# Beide muessen denselben Token-Wert haben
```

### GitLab API nicht erreichbar nach Start

```bash
# Pod-Status pruefen
kubectl get pods -n gitlab

# Readiness pruefen (erst nach vollstaendigem Start verfuegbar)
curl -sk https://gitlab.development.cfapps.cool/-/readiness

# DNS-Aufloesung pruefen
nslookup gitlab.development.cfapps.cool
```

### Runner registriert sich nicht

```bash
# Runner-Logs pruefen
kubectl logs -n gitlab-runner -l app=gitlab-runner --tail=50

# GitLab-URL aus dem Runner erreichbar?
kubectl exec -n gitlab-runner -it $(kubectl get pods -n gitlab-runner -o name | head -1) -- \
  wget -qO- --no-check-certificate https://gitlab.development.cfapps.cool/-/readiness
```

---

## Dateistruktur

```
services/gitlab-ce/
├── namespace.yaml              # Namespace 'gitlab'
├── kustomization.yaml          # Kustomize-Definition
├── configmap.yaml              # gitlab.rb Konfiguration
├── external-secrets.yaml       # Root-Passwort aus OpenBao
├── pvc.yaml                    # 3 PVCs (data, config, logs)
├── statefulset.yaml            # GitLab CE Omnibus Container
├── service.yaml                # ClusterIP :80 (HTTP)
├── service-ssh.yaml            # LoadBalancer :22 (SSH via MetalLB)
├── ingressroute.yaml           # Traefik IngressRoute (HTTPS)
└── runner/
    ├── Chart.yaml              # Helm Chart mit gitlab-runner Dependency
    ├── values.yaml             # Runner-Konfiguration (K8s Executor)
    └── templates/
        └── external-secret.yaml # Runner-Token aus OpenBao
```
