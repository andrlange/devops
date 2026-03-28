# Phase 2: Platform

## Uebersicht

Phase 2 stellt die zentralen Plattformdienste bereit, die als Grundlage fuer den gesamten Stack dienen:

- **ArgoCD** - GitOps Continuous Delivery
- **Portainer** - Kubernetes Management UI
- **Garage** - S3-kompatibler Object Storage (Backend fuer Loki, Mimir, Tempo, Velero)
- **S3 Manager** - Web-UI fuer Bucket- und Dateiverwaltung
- **Technitium DNS** - Interner DNS-Server mit Web-UI
- **Velero** - Backup und Restore

**Voraussetzung:** Phase 1 (Foundation) muss vollstaendig abgeschlossen sein. Das bedeutet: Lima VM laeuft, K3s ist installiert, OpenBao + ESO sind konfiguriert, MetalLB + Traefik + cert-manager sind deployed.

---

## 2.1 ArgoCD

ArgoCD wird als GitOps-Controller eingesetzt und verwaltet alle weiteren Deployments im Cluster.

### Helm Installation

ArgoCD verwendet das offizielle `argo-cd` Helm Chart (Version 9.4.15) mit ArgoCD v3.3.4.

```bash
# Namespace erstellen
kubectl create namespace argocd

# Helm Dependencies laden
cd k8/platform/argocd
helm dependency build

# Installation
helm install argocd . -n argocd -f values.yaml
```

**Chart-Konfiguration** (`Chart.yaml`):
- Chart: `argo-cd` Version `9.4.15`
- Repository: `https://argoproj.github.io/argo-helm`

**Wesentliche values.yaml Einstellungen:**
- `server.insecure: "true"` - TLS-Terminierung erfolgt durch Traefik, nicht durch ArgoCD selbst
- `dex.enabled: false` - Kein SSO/OIDC, nur lokaler Admin-Login
- Images werden aus der lokalen Artifactory Registry gezogen (`artifactory.cfapps.cool/docker-local/...`)
- Service-Typ: `ClusterIP` (Zugriff nur ueber IngressRoute)

### Redis Sub-Image

ArgoCD benoetigt Redis als Cache. Das Redis-Image (`redis:8.2.3-alpine-arm64`) muss separat in die Artifactory Registry importiert werden, da es nicht automatisch mit dem ArgoCD-Image mitgeliefert wird:

```bash
# Redis-Image fuer ARM64 in Artifactory importieren
docker pull redis:8.2.3-alpine
docker tag redis:8.2.3-alpine artifactory.cfapps.cool/docker-local/library/redis:8.2.3-alpine-arm64
docker push artifactory.cfapps.cool/docker-local/library/redis:8.2.3-alpine-arm64
```

### IngressRoute

Die IngressRoute macht ArgoCD unter `argocd.development.cfapps.cool` erreichbar:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`argocd.development.cfapps.cool`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
  tls: {}
```

```bash
kubectl apply -f ingressroute.yaml
```

### Admin-Passwort auslesen

Das initiale Admin-Passwort wird automatisch generiert und in einem Secret gespeichert:

```bash
# Admin-Passwort auslesen
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

# Login via CLI
argocd login argocd.development.cfapps.cool --username admin --password <PASSWORT>

# Passwort aendern (empfohlen)
argocd account update-password
```

### App-of-Apps Pattern

ArgoCD verwendet das App-of-Apps Pattern. Eine Root-Application ueberwacht das Verzeichnis `platform/argocd/applications/` und erstellt automatisch alle darin definierten Application-Manifeste:

```yaml
# platform/argocd/applications/root.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "<GIT_REPO_URL>"
    targetRevision: main
    path: platform/argocd/applications
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

```bash
# Root-Application deployen
kubectl apply -f platform/argocd/applications/root.yaml
```

Die `syncPolicy` mit `prune: true` und `selfHeal: true` sorgt dafuer, dass:
- Nicht mehr im Git vorhandene Ressourcen automatisch geloescht werden
- Manuell geaenderte Ressourcen automatisch auf den Git-Zustand zurueckgesetzt werden

---

## 2.2 Portainer

Portainer CE bietet eine Web-UI zur Verwaltung des Kubernetes-Clusters.

### Helm Installation

Portainer verwendet das offizielle Helm Chart (Version 239.0.2) mit Portainer CE v2.39.0.

```bash
# Namespace erstellen
kubectl create namespace portainer

# Helm Dependencies laden
cd k8/platform/portainer
helm dependency build

# Installation
helm install portainer . -n portainer -f values.yaml
```

**Wesentliche values.yaml Einstellungen:**
- Service-Typ: `ClusterIP`
- TLS-Force deaktiviert (`tls.force: false`) - TLS wird von Traefik terminiert
- Persistenter Speicher: 1Gi auf `local-path` StorageClass
- Image: `portainer-ce:2.39.0-arm64` aus Artifactory

### IngressRoute

Portainer ist unter `portainer.development.cfapps.cool` erreichbar. Die IngressRoute muss manuell erstellt werden:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: portainer
  namespace: portainer
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`portainer.development.cfapps.cool`)
      kind: Rule
      services:
        - name: portainer
          port: 9000
  tls: {}
```

```bash
kubectl apply -f ingressroute.yaml
```

### WICHTIG: Security Timeout

Portainer hat einen eingebauten Sicherheitsmechanismus: Das Admin-Passwort **muss innerhalb von 5 Minuten** nach dem ersten Start gesetzt werden. Danach sperrt sich Portainer aus Sicherheitsgruenden und muss neu gestartet werden.

```bash
# Sofort nach Deployment im Browser oeffnen:
# https://portainer.development.cfapps.cool

# Falls der Timeout abgelaufen ist, Pod neustarten:
kubectl -n portainer rollout restart deployment portainer
# Dann sofort im Browser das Passwort setzen!
```

---

## 2.3 Garage (S3 Object Storage)

Garage ist ein leichtgewichtiger, S3-kompatibler Object Storage. Er dient als Backend fuer Velero, Loki, Mimir, Tempo und artifact-keeper.

### Kustomize Deployment

Garage wird nicht per Helm, sondern via Kustomize als StatefulSet deployed.

```bash
# Namespace erstellen
kubectl create namespace garage

# Alle Manifeste anwenden
kubectl apply -k k8/platform/garage/
```

Das StatefulSet erstellt zwei PersistentVolumeClaims:
- `garage-data` (100Gi) - Eigentliche Objektdaten
- `garage-meta` (1Gi) - Metadaten (LMDB-Datenbank)

### garage.toml Konfiguration

Die Konfiguration wird ueber eine ConfigMap bereitgestellt:

```toml
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "lmdb"

replication_factor = 1
rpc_bind_addr = "[::]:3901"
rpc_secret = "<RPC_SECRET>"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"
root_domain = ".s3.development.cfapps.cool"

[s3_web]
bind_addr = "[::]:3902"
root_domain = ".web.development.cfapps.cool"

[admin]
api_bind_addr = "[::]:3903"
```

**Wichtige Parameter:**
- `replication_factor = 1` - Single-Node Setup, keine Replikation
- `rpc_secret` - Muss ein zufaelliger 32-Byte Hex-String sein
- S3 API auf Port 3900, Admin API auf Port 3903

```bash
# RPC Secret generieren (fuer Neukonfiguration)
openssl rand -hex 32
```

### Node Layout konfigurieren

Nach dem ersten Start muss das Node Layout konfiguriert werden. Dies weist dem Garage-Node eine Kapazitaet und Zone zu:

```bash
# Pod-Name ermitteln
GARAGE_POD=$(kubectl -n garage get pod -l app.kubernetes.io/name=garage -o jsonpath='{.items[0].metadata.name}')

# Node-ID anzeigen
kubectl -n garage exec $GARAGE_POD -- garage status

# Layout zuweisen (Node-ID aus dem vorherigen Befehl verwenden)
kubectl -n garage exec $GARAGE_POD -- garage layout assign <NODE_ID> \
  --zone default \
  --capacity 100GB \
  --tags k3s-node

# Layout anwenden
kubectl -n garage exec $GARAGE_POD -- garage layout apply --version 1
```

**Hinweis:** Das Node Layout bleibt nach einem Neustart erhalten und muss nicht erneut konfiguriert werden.

### Buckets erstellen

Folgende Buckets werden fuer den Stack benoetigt:

```bash
# Buckets erstellen
for BUCKET in velero-backups loki-chunks mimir-blocks tempo-traces artifacts; do
  kubectl -n garage exec $GARAGE_POD -- garage bucket create $BUCKET
  echo "Bucket '$BUCKET' erstellt"
done
```

### API Keys erstellen und in OpenBao speichern

Fuer jeden Service wird ein separater API Key mit Zugriff auf den jeweiligen Bucket erstellt:

```bash
# Beispiel: API Key fuer Velero erstellen
kubectl -n garage exec $GARAGE_POD -- garage key create velero-service-key

# Key-Informationen anzeigen (Access Key ID und Secret Access Key notieren)
kubectl -n garage exec $GARAGE_POD -- garage key info velero-service-key

# Bucket-Berechtigung setzen (read + write)
kubectl -n garage exec $GARAGE_POD -- garage bucket allow velero-backups \
  --read --write --key velero-service-key

# Gleiches Vorgehen fuer alle Services:
for SVC_BUCKET in "loki-svc-key:loki-chunks" "mimir-svc-key:mimir-blocks" "tempo-svc-key:tempo-traces" "artifacts-svc-key:artifacts"; do
  KEY_NAME="${SVC_BUCKET%%:*}"
  BUCKET_NAME="${SVC_BUCKET##*:}"
  kubectl -n garage exec $GARAGE_POD -- garage key create $KEY_NAME
  kubectl -n garage exec $GARAGE_POD -- garage bucket allow $BUCKET_NAME \
    --read --write --key $KEY_NAME
done

# Admin Key fuer S3 Manager erstellen (Zugriff auf alle Buckets)
kubectl -n garage exec $GARAGE_POD -- garage key create admin-key
for BUCKET in velero-backups loki-chunks mimir-blocks tempo-traces artifacts; do
  kubectl -n garage exec $GARAGE_POD -- garage bucket allow $BUCKET \
    --read --write --owner --key admin-key
done
```

**Credentials in OpenBao speichern:**

```bash
# Beispiel: Velero S3 Credentials in OpenBao ablegen
bao kv put secret/velero/s3-credentials \
  ACCESS_KEY_ID="<ACCESS_KEY>" \
  SECRET_ACCESS_KEY="<SECRET_KEY>"

# Admin Key fuer S3 Manager
bao kv put secret/garage/admin-s3-credentials \
  ACCESS_KEY_ID="<ADMIN_ACCESS_KEY>" \
  SECRET_ACCESS_KEY="<ADMIN_SECRET_KEY>"
```

### IngressRoutes

Garage exponiert zwei Endpunkte:

| URL | Port | Zweck |
|-----|------|-------|
| `s3.development.cfapps.cool` | 3900 | S3 API Endpunkt |
| `garage.development.cfapps.cool` | 3902 | Web-Interface |

```bash
kubectl apply -f k8/platform/garage/ingressroute.yaml
```

---

## 2.4 S3 Manager

Der S3 Manager (cloudlena/s3manager) bietet eine Web-UI zur Verwaltung von Buckets und Dateien in Garage.

### Kustomize Deployment

```bash
kubectl apply -k k8/platform/garage/s3-manager/
```

**Konfiguration:**
- Verbindet sich intern zu Garage via `garage.garage.svc:3900`
- Verwendet den Admin API Key aus dem Secret `garage-admin-s3-credentials`
- SSL ist deaktiviert (interne Kommunikation)
- Loeschen von Objekten ist erlaubt (`ALLOW_DELETE: "true"`)
- Region: `garage`

### IngressRoute

Erreichbar unter `s3-manager.development.cfapps.cool`:

```bash
kubectl apply -f k8/platform/garage/s3-manager/ingressroute.yaml
```

---

## 2.5 Technitium DNS

Technitium DNS stellt einen internen DNS-Server mit Web-UI bereit.

### Kustomize Deployment

```bash
# Namespace erstellen
kubectl create namespace technitium

# Deployment anwenden
kubectl apply -k k8/platform/technitium/
```

Technitium wird als Deployment mit `strategy: Recreate` deployed (kein Rolling Update, da DNS-Daten nur von einer Instanz gleichzeitig genutzt werden koennen). Daten werden in einem PVC `technitium-data` unter `/etc/dns` persistiert.

### LoadBalancer Service fuer DNS

DNS-Anfragen (Port 53) werden ueber einen LoadBalancer Service mit fester MetalLB-IP bereitgestellt:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: technitium-dns
  annotations:
    metallb.universe.tf/loadBalancerIPs: "192.168.64.201"
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: technitium
  ports:
    - name: dns-tcp
      port: 53
      targetPort: dns-tcp
      protocol: TCP
    - name: dns-udp
      port: 53
      targetPort: dns-udp
      protocol: UDP
```

Die feste IP `192.168.64.201` wird ueber die MetalLB-Annotation zugewiesen. Damit ist der DNS-Server aus dem Lima-Netzwerk unter dieser IP erreichbar.

```bash
# DNS-Aufloesung testen
dig @192.168.64.201 google.com
```

### Web-UI IngressRoute

Die Technitium Web-UI (Port 5380) ist ueber einen separaten ClusterIP Service und eine IngressRoute unter `dns.development.cfapps.cool` erreichbar:

```bash
kubectl apply -f k8/platform/technitium/ingressroute.yaml
```

---

## 2.6 Velero

Velero sichert Kubernetes-Ressourcen und PersistentVolumes in Garage S3.

### Helm Installation

Velero verwendet das offizielle Helm Chart (Version 12.0.0) mit Velero v1.18.0.

```bash
# Namespace erstellen
kubectl create namespace velero

# Helm Dependencies laden
cd k8/velero
helm dependency build

# Installation
helm install velero . -n velero -f values.yaml
```

**Wesentliche values.yaml Einstellungen:**
- `snapshotsEnabled: false` - Keine CSI Volume Snapshots (local-path-provisioner unterstuetzt dies nicht)
- `defaultVolumesToFsBackup: true` - Alle Volumes werden per Dateisystem-Backup (Kopia/Restic) gesichert
- `deployNodeAgent: true` - Node Agent fuer fsBackup wird als DaemonSet deployed
- AWS S3 Plugin (`velero-plugin-for-aws:v1.14.0-arm64`) als InitContainer

### S3-Credentials via ExternalSecret

Die S3-Zugangsdaten werden ueber einen ExternalSecret aus OpenBao geladen:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: velero-s3-credentials
  namespace: velero
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: velero-s3-credentials
  data:
    - secretKey: cloud
      remoteRef:
        key: secret/velero/s3-credentials
        property: credentials-file
```

Das resultierende Secret wird in der Velero values.yaml als `credentials.existingSecret: velero-s3-credentials` referenziert.

### BackupStorageLocation

Die BackupStorageLocation zeigt auf den `velero-backups` Bucket in Garage:

```yaml
backupStorageLocation:
  - name: garage
    provider: aws
    bucket: velero-backups
    config:
      region: garage
      s3ForcePathStyle: "true"
      s3Url: http://garage.garage.svc:3900
```

- `s3ForcePathStyle: "true"` ist notwendig, da Garage Path-Style-URLs erwartet (nicht Virtual-Hosted-Style)
- Der interne Service-Endpunkt `garage.garage.svc:3900` wird verwendet

### Taeglicher Backup-Schedule

Ein taeglicher Backup-Schedule sichert alle Namespaces um 02:00 UTC:

```bash
# Schedule erstellen
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --ttl 168h \
  --default-volumes-to-fs-backup

# Schedule pruefen
velero schedule get

# Manuellen Backup ausloesen (zum Testen)
velero backup create manual-test-backup \
  --default-volumes-to-fs-backup

# Backup-Status pruefen
velero backup get
velero backup describe manual-test-backup --details
```

**Parameter:**
- `--schedule="0 2 * * *"` - Taeglich um 02:00 UTC
- `--ttl 168h` - Backups werden nach 7 Tagen automatisch geloescht
- `--default-volumes-to-fs-backup` - PVs werden per Dateisystem-Backup gesichert

---

## Wichtige Hinweise

### IngressRoutes und TLS

Alle IngressRoutes verwenden `tls: {}` ohne weitere Konfiguration. Dies nutzt den Default TLSStore, der durch cert-manager mit dem Let's Encrypt Wildcard-Zertifikat fuer `*.development.cfapps.cool` konfiguriert wurde. Beispiel:

```yaml
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`<service>.development.cfapps.cool`)
      kind: Rule
      services:
        - name: <service>
          port: <port>
  tls: {}    # Verwendet Default TLSStore mit Wildcard-Zertifikat
```

### Portainer Security Timeout

Portainer sperrt die Admin-Registrierung nach 5 Minuten. Bei einem Neustart des Pods ohne vorherige Registrierung muss der Pod erneut gestartet werden:

```bash
kubectl -n portainer rollout restart deployment portainer
```

### Garage Node Layout

Das Node Layout wird in den Garage-Metadaten persistiert. Nach einem Neustart des Pods oder des Clusters muss das Layout **nicht** erneut konfiguriert werden. Eine erneute Konfiguration ist nur notwendig, wenn:
- Ein neuer Node zum Cluster hinzugefuegt wird
- Die Kapazitaet eines bestehenden Nodes geaendert werden soll
- Ein Node entfernt wird

### Image Registry

Alle Container-Images werden aus der lokalen Artifactory Registry (`artifactory.cfapps.cool/docker-local/...`) geladen. Das Pull-Secret `artifact-keeper-pull` muss in jedem Namespace vorhanden sein:

```bash
# Pull-Secret in neuen Namespace kopieren (Beispiel)
kubectl get secret artifact-keeper-pull -n default -o yaml \
  | sed 's/namespace: default/namespace: <NEUER_NAMESPACE>/' \
  | kubectl apply -f -
```

### Uebersicht aller URLs (Phase 2)

| Service | URL | Zweck |
|---------|-----|-------|
| ArgoCD | `https://argocd.development.cfapps.cool` | GitOps UI |
| Portainer | `https://portainer.development.cfapps.cool` | Cluster Management UI |
| Garage S3 API | `https://s3.development.cfapps.cool` | S3-kompatibler Endpunkt |
| Garage Web | `https://garage.development.cfapps.cool` | Garage Web-Interface |
| S3 Manager | `https://s3-manager.development.cfapps.cool` | Bucket/File Management UI |
| Technitium DNS | `https://dns.development.cfapps.cool` | DNS Management Web-UI |
| Technitium DNS | `192.168.64.201:53` | DNS-Aufloesung (TCP/UDP) |
