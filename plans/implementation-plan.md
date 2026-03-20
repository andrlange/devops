# K8s DevOps Stack - Implementierungsplan

> Referenz: [Design Specification](../docs/superpowers/specs/2026-03-19-k8s-devops-stack-design.md)

---

## Gesamtübersicht

```
Phase 1 ─ Foundation          Phase 2 ─ Platform           Phase 3 ─ Monitoring
┌──────────────────────┐      ┌──────────────────────┐     ┌──────────────────────┐
│ 1.1 Lima VM          │      │ 2.1 ArgoCD           │     │ 3.1 Grafana          │
│ 1.2 K3s              │      │ 2.2 Portainer        │     │ 3.2 Loki             │
│ 1.3 OpenBao          │─────▶│ 2.3 Garage           │────▶│ 3.3 Mimir            │
│ 1.4 ESO              │      │ 2.4 Technitium DNS   │     │ 3.4 Tempo            │
│ 1.5 MetalLB          │      │ 2.5 Velero           │     │ 3.5 Alerting         │
│ 1.6 Traefik          │      └──────────────────────┘     └──────────────────────┘
│ 1.7 cert-manager     │                                            │
│ 1.8 stack.sh         │      Phase 4 ─ Services          Phase 5 ─ GitLab
└──────────────────────┘      ┌──────────────────────┐     ┌──────────────────────┐
                              │ 4.1 artifact-keeper  │     │ 5.1 GitLab CE        │
                              │ 4.2 PostgreSQL       │────▶│                      │
                              │ 4.3 Meilisearch      │     └──────────────────────┘
                              └──────────────────────┘
```

### Dependency Chain

```
Lima VM → K3s → OpenBao → ESO → cert-manager (ClusterIssuers)
                                      ↓
                               MetalLB → Traefik
                                      ↓
                               ArgoCD → Garage → Velero
                                      ↓
                               Loki/Mimir/Tempo (benötigen Garage S3)
                                      ↓
                               artifact-keeper (benötigt PostgreSQL, Meilisearch, Garage)
                                      ↓
                               GitLab CE
```

---

## Phase 0 - Container Images vorbereiten

Ziel: Alle benötigten Container Images in die eigene Registry spiegeln.

### 0.1 Container Images importieren

**Voraussetzung:** artifact-keeper läuft unter https://artifactory.cfapps.cool

**Schritte:**
1. Images importieren:
   ```bash
   cd k8/
   ./import-all-containers.sh              # Alle Images
   ./import-all-containers.sh --phase 1    # Oder phasenweise
   ```
2. Das Script fragt Benutzername/Passwort für artifactory.cfapps.cool ab
3. Alle Images werden via skopeo als linux/arm64 in das `docker-local` Repository kopiert

### 0.2 Pull-User in artifact-keeper einrichten

**Ziel:** Separater Read-Only-User für K8s Image Pulls (nicht den Admin-Account verwenden).

**Schritte:**
1. In artifact-keeper Web-UI (https://artifactory.cfapps.cool) einloggen
2. Neuen User anlegen:
   - Username: `k8s-pull`
   - Rolle: Read-Only auf `docker-local` Repository
3. API-Key oder Passwort für den Pull-User generieren
4. Credentials in OpenBao speichern (nach Phase 1.3):
   ```bash
   bao kv put secret/k8s/registry \
     server="https://artifactory.cfapps.cool" \
     username="k8s-pull" \
     password="<pull-password>"
   ```

### 0.3 K8s ImagePullSecret konfigurieren

**Wird in Phase 1.4 (ESO) automatisiert.** ESO erstellt in jedem Namespace ein `imagePullSecret` aus OpenBao:

```yaml
# platform/external-secrets/registry-pull-secret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterExternalSecret
metadata:
  name: artifact-keeper-pull
spec:
  namespaceSelectors:
    - matchLabels: {}   # Alle Namespaces
  refreshInterval: 1h
  externalSecretSpec:
    secretStoreRef:
      kind: ClusterSecretStore
      name: openbao
    target:
      name: artifact-keeper-pull
      template:
        type: kubernetes.io/dockerconfigjson
        data:
          .dockerconfigjson: |
            {"auths":{"{{ .server }}":{"username":"{{ .username }}","password":"{{ .password }}"}}}
    data:
      - secretKey: server
        remoteRef:
          key: secret/k8s/registry
          property: server
      - secretKey: username
        remoteRef:
          key: secret/k8s/registry
          property: username
      - secretKey: password
        remoteRef:
          key: secret/k8s/registry
          property: password
```

**Image-Referenzen in Helm Values:** Alle Services verwenden die gespiegelte Registry:
```yaml
# Beispiel: infrastructure/traefik/values.yaml
image:
  repository: artifactory.cfapps.cool/docker-local/traefik
  tag: "v3.6.10"
imagePullSecrets:
  - name: artifact-keeper-pull
```

### Image-Mapping (Source → Target)

| Source | K8s Image Reference |
|--------|-------------------|
| `openbao/openbao:2.5.1` | `artifactory.cfapps.cool/docker-local/openbao/openbao:2.5.1` |
| `ghcr.io/external-secrets/external-secrets:v0.16.1` | `artifactory.cfapps.cool/docker-local/external-secrets/external-secrets:v0.16.1` |
| `quay.io/metallb/controller:v0.15.3` | `artifactory.cfapps.cool/docker-local/metallb/controller:v0.15.3` |
| `quay.io/metallb/speaker:v0.15.3` | `artifactory.cfapps.cool/docker-local/metallb/speaker:v0.15.3` |
| `traefik:v3.6.10` | `artifactory.cfapps.cool/docker-local/traefik:v3.6.10` |
| `quay.io/jetstack/cert-manager-controller:v1.20.0` | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-controller:v1.20.0` |
| `quay.io/jetstack/cert-manager-cainjector:v1.20.0` | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-cainjector:v1.20.0` |
| `quay.io/jetstack/cert-manager-webhook:v1.20.0` | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-webhook:v1.20.0` |
| `quay.io/jetstack/cert-manager-acmesolver:v1.20.0` | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-acmesolver:v1.20.0` |
| `quay.io/argoproj/argocd:v3.3.4` | `artifactory.cfapps.cool/docker-local/argoproj/argocd:v3.3.4` |
| `portainer/portainer-ce:2.39.0` | `artifactory.cfapps.cool/docker-local/portainer/portainer-ce:2.39.0` |
| `dxflrs/garage:v2.2.0` | `artifactory.cfapps.cool/docker-local/dxflrs/garage:v2.2.0` |
| `technitium/dns-server:14.3.0` | `artifactory.cfapps.cool/docker-local/technitium/dns-server:14.3.0` |
| `velero/velero:v1.18.0` | `artifactory.cfapps.cool/docker-local/velero/velero:v1.18.0` |
| `velero/velero-plugin-for-aws:v1.14.0` | `artifactory.cfapps.cool/docker-local/velero/velero-plugin-for-aws:v1.14.0` |
| `grafana/grafana:12.4.1` | `artifactory.cfapps.cool/docker-local/grafana/grafana:12.4.1` |
| `grafana/loki:3.6.7` | `artifactory.cfapps.cool/docker-local/grafana/loki:3.6.7` |
| `grafana/mimir:3.0.4` | `artifactory.cfapps.cool/docker-local/grafana/mimir:3.0.4` |
| `grafana/tempo:2.10.3` | `artifactory.cfapps.cool/docker-local/grafana/tempo:2.10.3` |
| `grafana/alloy:v1.14.1` | `artifactory.cfapps.cool/docker-local/grafana/alloy:v1.14.1` |
| `postgres:17.9` | `artifactory.cfapps.cool/docker-local/postgres:17.9` |
| `getmeili/meilisearch:v1.39.0` | `artifactory.cfapps.cool/docker-local/getmeili/meilisearch:v1.39.0` |
| `gitlab/gitlab-ce:18.10.0-ce.0` | `artifactory.cfapps.cool/docker-local/gitlab/gitlab-ce:18.10.0-ce.0` |

---

## Phase 1 - Foundation

Ziel: Lauffähiger K3s-Cluster mit Netzwerk, TLS und Secret-Management.

---

### 1.1 Lima VM einrichten

**Ziel:** Ubuntu 24.04 ARM64 VM mit shared Networking für MetalLB-Kompatibilität.

**Dateien:**
- `bootstrap/lima.yaml`

**Schritte:**
1. `socket_vmnet` installieren (Homebrew: `brew install socket_vmnet`)
2. `lima.yaml` erstellen mit folgender Konfiguration:
   - `vmType: vz` (Apple Virtualization.framework)
   - `network: vzNAT` mit shared network (`socket_vmnet`)
   - CPUs: 8+
   - Memory: 48GB+
   - Disk: 200GB+
   - Mounts: Host-Verzeichnis `k8/` read-only in VM für initiales Setup
   - Provisioning: Ubuntu 24.04 ARM64 Image
3. VM erstellen und starten: `limactl create --name k3s-server bootstrap/lima.yaml`
4. Netzwerk verifizieren: VM muss eine IP im Host-LAN-Subnetz haben
5. `/data/persistent` Verzeichnis in der VM anlegen für PVs

**Validierung:**
- [ ] `limactl list` zeigt `k3s-server` als Running
- [ ] VM hat routable IP im Host-Netzwerk (z.B. 192.168.x.x)
- [ ] `ping <vm-ip>` vom Host funktioniert
- [ ] `/data/persistent` existiert in der VM

---

### 1.2 K3s installieren

**Ziel:** Single-Node K3s-Cluster ohne eingebauten Traefik und ServiceLB.

**Dateien:**
- `bootstrap/install-k3s.sh`

**Schritte:**
1. K3s Installations-Script erstellen:
   ```bash
   curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="\
     --disable servicelb \
     --disable traefik \
     --write-kubeconfig-mode 644 \
     --tls-san <vm-ip> \
     --tls-san <external-hostname> \
     --data-dir /var/lib/rancher/k3s \
     --default-local-storage-path /data/persistent" sh -
   ```
2. kubeconfig von VM auf Host kopieren:
   ```bash
   limactl shell k3s-server cat /etc/rancher/k3s/k3s.yaml | \
     sed "s/127.0.0.1/<vm-ip>/g" > ~/.kube/config
   ```
3. `kubectl` auf Host installieren (falls nicht vorhanden)
4. Cluster-Zugriff testen

**Validierung:**
- [ ] `kubectl get nodes` zeigt einen Node im Status `Ready`
- [ ] `kubectl get pods -A` zeigt nur `kube-system` Pods (kein Traefik, kein ServiceLB)
- [ ] StorageClass `local-path` ist default: `kubectl get sc`

---

### 1.3 OpenBao deployen

**Ziel:** Secret-Management als Fundament für alle weiteren Services.

**Dateien:**
- `services/openbao/Chart.yaml`
- `services/openbao/values.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace openbao`
2. Helm Chart konfigurieren:
   - OpenBao Helm Chart als Dependency (offizielles Chart)
   - HA-Modus deaktiviert (Single-Node)
   - Storage: PVC mit `local-path` StorageClass
   - UI aktiviert
   - Injector deaktiviert (ESO übernimmt Secret-Sync)
3. Deployen: `helm install openbao ./services/openbao -n openbao`
4. OpenBao initialisieren:
   ```bash
   kubectl exec -n openbao openbao-0 -- bao operator init \
     -key-shares=5 -key-threshold=3
   ```
5. Unseal-Keys und Root-Token **sicher in Passwort-Manager speichern**
6. OpenBao unseal (3 von 5 Keys)
7. KV Secrets Engine aktivieren: `bao secrets enable -path=secret kv-v2`
8. Kubernetes Auth Method aktivieren für ESO-Zugriff:
   ```bash
   bao auth enable kubernetes
   bao write auth/kubernetes/config \
     kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
   ```
9. Bootstrap-Secrets eintragen (interaktiv via `bootstrap.sh`):
   - `secret/dns/google-cloud` → GCP Service Account JSON
   - `secret/dns/route53` → AWS Access Key ID + Secret Access Key
   - `secret/infrastructure/traefik` → Dashboard-Passwort (optional)

**Validierung:**
- [ ] `kubectl get pods -n openbao` zeigt Running Pod
- [ ] OpenBao ist unsealed: `kubectl exec -n openbao openbao-0 -- bao status`
- [ ] KV Engine aktiv: `bao secrets list`
- [ ] Kubernetes Auth konfiguriert: `bao auth list`
- [ ] DNS-Credentials gespeichert: `bao kv get secret/dns/google-cloud`

---

### 1.4 External Secrets Operator (ESO) deployen

**Ziel:** Automatischer Sync von OpenBao-Secrets in K8s-Secrets.

**Dateien:**
- `platform/external-secrets/Chart.yaml`
- `platform/external-secrets/values.yaml`
- `platform/external-secrets/cluster-secret-store.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace external-secrets`
2. ESO via Helm deployen:
   ```yaml
   # Chart.yaml
   dependencies:
     - name: external-secrets
       version: "0.x.x"  # aktuelle Version pinnen
       repository: https://charts.external-secrets.io
   ```
3. ServiceAccount für ESO in OpenBao erstellen:
   - Policy: Leserechte auf `secret/*`
   - Kubernetes Auth Role: bound to ESO ServiceAccount
4. `ClusterSecretStore` erstellen:
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ClusterSecretStore
   metadata:
     name: openbao
   spec:
     provider:
       vault:
         server: "http://openbao.openbao.svc:8200"
         path: "secret"
         version: "v2"
         auth:
           kubernetes:
             mountPath: "kubernetes"
             role: "external-secrets"
             serviceAccountRef:
               name: "external-secrets"
               namespace: "external-secrets"
   ```
5. Test-ExternalSecret erstellen um DNS-Credentials zu syncen:
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   metadata:
     name: google-cloud-dns
     namespace: cert-manager
   spec:
     refreshInterval: 1h
     secretStoreRef:
       kind: ClusterSecretStore
       name: openbao
     target:
       name: google-cloud-dns-credentials
     data:
       - secretKey: credentials.json
         remoteRef:
           key: secret/dns/google-cloud
           property: credentials
   ```

**Validierung:**
- [ ] ESO Pods laufen: `kubectl get pods -n external-secrets`
- [ ] ClusterSecretStore ist `Valid`: `kubectl get clustersecretstore openbao`
- [ ] ExternalSecret synced: `kubectl get externalsecret -n cert-manager`
- [ ] K8s Secret erstellt: `kubectl get secret google-cloud-dns-credentials -n cert-manager`

---

### 1.5 MetalLB deployen

**Ziel:** LoadBalancer-IPs für Services im LAN bereitstellen.

**Dateien:**
- `infrastructure/metallb/Chart.yaml`
- `infrastructure/metallb/values.yaml`
- `infrastructure/metallb/ip-pool.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace metallb-system`
2. MetalLB via Helm deployen (offizielles Chart)
3. IP-Adresspool konfigurieren:
   ```yaml
   apiVersion: metallb.io/v1beta1
   kind: IPAddressPool
   metadata:
     name: default-pool
     namespace: metallb-system
   spec:
     addresses:
       - 192.168.x.200-192.168.x.210  # Anpassen an lokales Netzwerk
   ---
   apiVersion: metallb.io/v1beta1
   kind: L2Advertisement
   metadata:
     name: default
     namespace: metallb-system
   spec:
     ipAddressPools:
       - default-pool
   ```
4. IP-Range muss im selben Subnetz wie die Lima VM liegen
5. Sicherstellen dass kein DHCP-Server diese IPs vergibt

**Validierung:**
- [ ] MetalLB Pods laufen: `kubectl get pods -n metallb-system`
- [ ] IPAddressPool erstellt: `kubectl get ipaddresspool -n metallb-system`
- [ ] L2Advertisement erstellt: `kubectl get l2advertisement -n metallb-system`
- [ ] Test-Service bekommt External IP: `kubectl create svc loadbalancer test --tcp=80:80 && kubectl get svc test`

---

### 1.6 Traefik deployen

**Ziel:** Ingress Controller mit SSL-Termination und IngressRoute CRDs.

**Dateien:**
- `infrastructure/traefik/Chart.yaml`
- `infrastructure/traefik/values.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace traefik`
2. Traefik via Helm deployen:
   ```yaml
   # values.yaml (Auszug)
   service:
     type: LoadBalancer    # MetalLB vergibt IP

   ingressRoute:
     dashboard:
       enabled: true
       matchRule: Host(`traefik.development.cfapps.cool`)
       entryPoints: ["websecure"]

   ports:
     web:
       port: 8000
       exposedPort: 80
       redirectTo:
         port: websecure    # HTTP → HTTPS Redirect
     websecure:
       port: 8443
       exposedPort: 443
       tls:
         enabled: true

   additionalArguments:
     - "--api.dashboard=true"
     - "--entrypoints.websecure.http.tls"

   providers:
     kubernetesCRD:
       enabled: true
       allowCrossNamespace: true
     kubernetesIngress:
       enabled: true
   ```
3. Traefik Service IP notieren (von MetalLB zugewiesen)
4. DNS-Eintrag: `*.development.cfapps.cool` → Traefik LoadBalancer IP

**Validierung:**
- [ ] Traefik Pod läuft: `kubectl get pods -n traefik`
- [ ] Service hat External IP: `kubectl get svc -n traefik`
- [ ] Traefik Dashboard erreichbar (zunächst via Port-Forward): `kubectl port-forward -n traefik svc/traefik 9000:9000`
- [ ] IngressRoute CRD installiert: `kubectl get crd | grep traefik`

---

### 1.7 cert-manager deployen

**Ziel:** Automatische Wildcard-Zertifikate via Let's Encrypt DNS-01 Challenge.

**Dateien:**
- `infrastructure/cert-manager/Chart.yaml`
- `infrastructure/cert-manager/values.yaml`
- `infrastructure/cert-manager/clusterissuer.yaml`
- `infrastructure/cert-manager/wildcard-certificate.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace cert-manager`
2. cert-manager via Helm deployen (mit CRDs):
   ```yaml
   # values.yaml
   installCRDs: true
   ```
3. ExternalSecrets für DNS-Credentials erstellen (ESO synct aus OpenBao):
   - `google-cloud-dns-credentials` → Namespace `cert-manager`
   - `route53-credentials` → Namespace `cert-manager`
4. ClusterIssuer für Let's Encrypt erstellen:
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: letsencrypt-prod
   spec:
     acme:
       server: https://acme-v02.api.letsencrypt.org/directory
       email: <admin-email>
       privateKeySecretRef:
         name: letsencrypt-prod-key
       solvers:
         - dns01:
             cloudDNS:
               project: <gcp-project-id>
               serviceAccountSecretRef:
                 name: google-cloud-dns-credentials
                 key: credentials.json
           selector:
             dnsZones:
               - "cfapps.cool"
         - dns01:
             route53:
               region: eu-central-1
               accessKeyIDSecretRef:
                 name: route53-credentials
                 key: access-key-id
               secretAccessKeySecretRef:
                 name: route53-credentials
                 key: secret-access-key
           selector:
             dnsZones:
               - "andere-domain.com"  # Route53-verwaltete Zonen
   ```
5. Wildcard-Zertifikat anfordern:
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: wildcard-development
     namespace: traefik
   spec:
     secretName: wildcard-development-tls
     issuerRef:
       name: letsencrypt-prod
       kind: ClusterIssuer
     dnsNames:
       - "*.development.cfapps.cool"
       - "development.cfapps.cool"
   ```
6. Traefik konfigurieren um das Wildcard-Zertifikat als Default-TLS zu nutzen:
   ```yaml
   # TLSStore für Traefik
   apiVersion: traefik.io/v1alpha1
   kind: TLSStore
   metadata:
     name: default
     namespace: traefik
   spec:
     defaultCertificate:
       secretName: wildcard-development-tls
   ```

**Validierung:**
- [ ] cert-manager Pods laufen: `kubectl get pods -n cert-manager`
- [ ] ClusterIssuer ist Ready: `kubectl get clusterissuer letsencrypt-prod`
- [ ] Certificate wird ausgestellt: `kubectl get certificate -n traefik`
- [ ] Certificate Status ist `True`: `kubectl describe certificate wildcard-development -n traefik`
- [ ] HTTPS funktioniert: `curl -v https://traefik.development.cfapps.cool`

---

### 1.8 Master Script (`stack.sh`)

**Ziel:** Einfaches Start/Stop/Status-Management des gesamten Stacks.

**Dateien:**
- `stack.sh`

**Schritte:**
1. Script erstellen mit folgenden Subcommands:

   **`stack.sh start`:**
   ```
   1. Prüfe ob Lima installiert ist
   2. limactl start k3s-server (falls nicht running)
   3. Warte auf K3s API-Server (kubectl get nodes --timeout=60s)
   4. Aktualisiere kubeconfig auf Host
   5. Warte auf Core-Pods (kube-system, openbao, traefik)
   6. Prüfe OpenBao Seal-Status → Warnung wenn sealed
   7. Prüfe ArgoCD Sync-Status (falls Phase 2+ deployed)
   8. Zeige Status-Tabelle mit allen Endpoints
   ```

   **`stack.sh stop`:**
   ```
   1. Optionaler Velero-Backup (--backup Flag)
   2. limactl stop k3s-server
   3. Bestätigung ausgeben
   ```

   **`stack.sh status`:**
   ```
   1. Lima VM Status (running/stopped, IP, Resources)
   2. K3s Node Status
   3. Namespace-Übersicht mit Pod-Counts und Health
   4. ArgoCD App-Sync-Status
   5. Zertifikat-Ablaufdaten
   6. Endpoint-Tabelle mit Erreichbarkeits-Check
   ```

   **`stack.sh restart`:**
   ```
   1. stack.sh stop
   2. stack.sh start
   ```

   **`stack.sh backup`:**
   ```
   1. Velero Backup auslösen
   2. Auf Completion warten
   3. Backup-Status ausgeben
   ```

**Validierung:**
- [ ] `stack.sh start` fährt VM hoch und zeigt alle Endpoints
- [ ] `stack.sh stop` fährt VM sauber herunter
- [ ] `stack.sh status` zeigt vollständigen Cluster-Status
- [ ] `stack.sh backup` löst Velero-Backup aus (erst ab Phase 2)

---

## Phase 2 - Platform

Ziel: GitOps-Pipeline, Management-UI, Object Storage, interner DNS und Backup.

**Voraussetzung:** Phase 1 vollständig abgeschlossen und validiert.

---

### 2.1 ArgoCD deployen

**Ziel:** GitOps-Controller der alle weiteren Deployments aus Git synct.

**Dateien:**
- `platform/argocd/Chart.yaml`
- `platform/argocd/values.yaml`
- `platform/argocd/applications/` (App-of-Apps)

**Schritte:**
1. Namespace erstellen: `kubectl create namespace argocd`
2. ArgoCD via Helm deployen:
   ```yaml
   # values.yaml (Auszug)
   server:
     ingress:
       enabled: false  # Wir nutzen IngressRoute

   configs:
     params:
       server.insecure: true  # TLS terminiert am Traefik
   ```
3. Traefik IngressRoute erstellen:
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
   ```
4. Admin-Passwort auslesen und in OpenBao speichern:
   ```bash
   kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
   ```
5. Git-Repository in ArgoCD konfigurieren (das `k8/` Repo)
6. App-of-Apps Pattern einrichten:
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
       repoURL: <git-repo-url>
       targetRevision: main
       path: platform/argocd/applications
     destination:
       server: https://kubernetes.default.svc
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   ```
7. ArgoCD Applications erstellen für jede Gruppe:
   - `infrastructure.yaml` → zeigt auf `infrastructure/`
   - `platform.yaml` → zeigt auf `platform/` (ohne argocd selbst)
   - `monitoring.yaml` → zeigt auf `monitoring/`
   - `services.yaml` → zeigt auf `services/`
   - `backup.yaml` → zeigt auf `velero/`
8. Sync-Waves konfigurieren für korrekte Reihenfolge

**Validierung:**
- [ ] ArgoCD UI erreichbar: `https://argocd.development.cfapps.cool`
- [ ] Login funktioniert
- [ ] Git-Repository connected
- [ ] Root Application synced
- [ ] Alle Sub-Applications sichtbar

---

### 2.2 Portainer deployen

**Ziel:** Web-basierte Cluster-Management-Oberfläche.

**Dateien:**
- `platform/portainer/Chart.yaml`
- `platform/portainer/values.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace portainer`
2. Portainer CE via Helm deployen:
   ```yaml
   # values.yaml
   service:
     type: ClusterIP    # Traefik übernimmt Ingress

   persistence:
     enabled: true
     storageClass: local-path
     size: 1Gi

   tls:
     force: false       # TLS terminiert am Traefik
   ```
3. Traefik IngressRoute erstellen:
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
   ```
4. Initiales Admin-Passwort setzen (beim ersten Login)
5. Admin-Credentials in OpenBao speichern

**Validierung:**
- [ ] Portainer UI erreichbar: `https://portainer.development.cfapps.cool`
- [ ] Kubernetes-Cluster wird erkannt und angezeigt
- [ ] Namespaces, Pods, Services sichtbar

---

### 2.3 Garage deployen

**Ziel:** Lokaler S3-kompatibler Object Storage für Backups und Monitoring-Backends.

**Dateien:**
- `platform/garage/Chart.yaml`
- `platform/garage/values.yaml`
- `platform/garage/buckets.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace garage`
2. Garage via Helm deployen:
   ```yaml
   # values.yaml (Auszug)
   garage:
     replicationMode: "none"    # Single-Node, keine Replikation

   persistence:
     enabled: true
     storageClass: local-path
     dataSize: 100Gi            # Anpassen je nach Bedarf
     metaSize: 1Gi
   ```
3. Traefik IngressRoute für S3-API und Web-Interface
4. Nach dem Start: Buckets anlegen via `garage` CLI oder API:
   - `velero-backups`
   - `loki-chunks`
   - `mimir-blocks`
   - `tempo-traces`
   - `artifacts`
5. Access Keys für jeden Bucket erstellen
6. Access Keys in OpenBao speichern:
   - `secret/garage/velero` → Key für Velero
   - `secret/garage/loki` → Key für Loki
   - `secret/garage/mimir` → Key für Mimir
   - `secret/garage/tempo` → Key für Tempo
   - `secret/garage/artifacts` → Key für artifact-keeper

**Validierung:**
- [ ] Garage Pod läuft: `kubectl get pods -n garage`
- [ ] S3-API erreichbar: `curl https://s3.development.cfapps.cool`
- [ ] Buckets erstellt: `garage bucket list` (via exec in Pod)
- [ ] Schreibtest: S3-kompatibles Tool (aws cli, mc) kann Datei hochladen/runterladen

---

### 2.4 Technitium DNS deployen

**Ziel:** Interner DNS-Server mit Web-UI für Development-Zonen.

**Dateien:**
- `platform/technitium/Chart.yaml`
- `platform/technitium/values.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace technitium`
2. Technitium via Helm oder Kustomize deployen:
   - Container Image: `technitium/dns-server` (ARM64 unterstützt)
   - Ports: 53 (DNS TCP/UDP), 5380 (Web-UI)
   - PVC für DNS-Daten und Konfiguration
3. MetalLB Service für DNS (Port 53):
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: technitium-dns
     namespace: technitium
     annotations:
       metallb.universe.tf/loadBalancerIPs: "192.168.x.201"  # Feste IP
   spec:
     type: LoadBalancer
     ports:
       - name: dns-tcp
         port: 53
         protocol: TCP
       - name: dns-udp
         port: 53
         protocol: UDP
     selector:
       app: technitium
   ```
4. Traefik IngressRoute für Web-UI (Port 5380):
   ```yaml
   apiVersion: traefik.io/v1alpha1
   kind: IngressRoute
   metadata:
     name: technitium-ui
     namespace: technitium
   spec:
     entryPoints:
       - websecure
     routes:
       - match: Host(`dns.development.cfapps.cool`)
         kind: Rule
         services:
           - name: technitium-ui
             port: 5380
   ```
5. DNS-Zonen konfigurieren via Web-UI:
   - Authoritative Zone: `dev.internal` (oder gewünschte interne Zone)
   - Conditional Forwarder: alle anderen Domains → 8.8.8.8, 1.1.1.1
   - Optional: `development.cfapps.cool` → Google Cloud DNS (wenn Split-Horizon gewünscht)
6. Macs/Clients im LAN: Technitium als DNS-Server eintragen (IP: 192.168.x.201)

**Validierung:**
- [ ] DNS Web-UI erreichbar: `https://dns.development.cfapps.cool`
- [ ] DNS-Auflösung funktioniert: `dig @192.168.x.201 test.dev.internal`
- [ ] Forwarding funktioniert: `dig @192.168.x.201 google.com`
- [ ] Interne Zone konfigurierbar über Web-UI

---

### 2.5 Velero deployen

**Ziel:** Automatische Cluster-Backups nach Garage S3.

**Voraussetzung:** Garage (2.3) muss laufen und Bucket `velero-backups` existieren.

**Dateien:**
- `velero/Chart.yaml`
- `velero/values.yaml`
- `velero/schedules/daily-backup.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace velero`
2. ExternalSecret für Garage S3-Credentials (ESO → OpenBao):
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   metadata:
     name: velero-s3-credentials
     namespace: velero
   spec:
     secretStoreRef:
       kind: ClusterSecretStore
       name: openbao
     target:
       name: velero-s3-credentials
       template:
         data:
           cloud: |
             [default]
             aws_access_key_id={{ .access_key }}
             aws_secret_access_key={{ .secret_key }}
     data:
       - secretKey: access_key
         remoteRef:
           key: secret/garage/velero
           property: access_key
       - secretKey: secret_key
         remoteRef:
           key: secret/garage/velero
           property: secret_key
   ```
3. Velero via Helm deployen:
   ```yaml
   # values.yaml
   configuration:
     backupStorageLocation:
       - name: garage
         provider: aws
         bucket: velero-backups
         config:
           region: garage
           s3ForcePathStyle: true
           s3Url: http://garage.garage.svc:3900
     defaultVolumesToFsBackup: true  # Restic/Kopia für PVs

   credentials:
     existingSecret: velero-s3-credentials

   deployNodeAgent: true  # Für file-level PV Backups
   ```
4. Täglichen Backup-Schedule erstellen:
   ```yaml
   apiVersion: velero.io/v1
   kind: Schedule
   metadata:
     name: daily-full-backup
     namespace: velero
   spec:
     schedule: "0 2 * * *"    # Täglich um 02:00
     template:
       ttl: "168h"            # 7 Tage Retention
       includedNamespaces:
         - "*"
       defaultVolumesToFsBackup: true
   ```

**Validierung:**
- [ ] Velero Pod läuft: `kubectl get pods -n velero`
- [ ] BackupStorageLocation ist `Available`: `velero backup-location get`
- [ ] Test-Backup erfolgreich: `velero backup create test-backup --wait`
- [ ] Backup in Garage sichtbar: Bucket `velero-backups` enthält Daten
- [ ] Schedule erstellt: `velero schedule get`

---

## Phase 3 - Monitoring

Ziel: Vollständiger Observability-Stack, migriert von Docker Compose.

**Voraussetzung:** Phase 2 vollständig, Garage S3-Buckets bereit.

---

### 3.1 Grafana deployen

**Dateien:**
- `monitoring/grafana/Chart.yaml`
- `monitoring/grafana/values.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace grafana`
2. Grafana via Helm deployen:
   - Provisioned Datasources: Loki, Mimir, Tempo
   - Admin-Credentials via ESO → OpenBao
   - PVC für Grafana-DB (Dashboards, User-Settings)
   - Dashboards als ConfigMaps provisionieren (Infrastructure, K8s, Application)
3. Traefik IngressRoute: `grafana.development.cfapps.cool`
4. Bestehende Dashboards aus Docker-Compose-Setup migrieren

**Validierung:**
- [ ] Grafana UI erreichbar: `https://grafana.development.cfapps.cool`
- [ ] Datasources konfiguriert und erreichbar (grüne Status-Checks)
- [ ] Dashboards geladen

---

### 3.2 Loki deployen

**Dateien:**
- `monitoring/loki/Chart.yaml`
- `monitoring/loki/values.yaml`

**Schritte:**
1. Loki via Helm deployen (Single-Binary oder Simple-Scalable Mode)
2. S3-Backend konfigurieren:
   ```yaml
   loki:
     storage:
       type: s3
       s3:
         endpoint: http://garage.garage.svc:3900
         bucketnames: loki-chunks
         region: garage
         s3ForcePathStyle: true
         access_key_id: # via ESO
         secret_access_key: # via ESO
   ```
3. ExternalSecret für Garage-Credentials
4. Promtail oder Alloy als Log-Collector deployen (DaemonSet)

**Validierung:**
- [ ] Loki Pod läuft und ist Ready
- [ ] Logs werden geschrieben: `logcli query '{namespace="kube-system"}'`
- [ ] Grafana Loki-Datasource funktioniert

---

### 3.3 Mimir deployen

**Dateien:**
- `monitoring/mimir/Chart.yaml`
- `monitoring/mimir/values.yaml`

**Schritte:**
1. Mimir via Helm deployen (Monolithic Mode für Single-Node)
2. S3-Backend: Bucket `mimir-blocks` auf Garage
3. ExternalSecret für Garage-Credentials
4. Prometheus/Alloy als Metrics-Scraper konfigurieren
5. Remote-Write Endpoint auf Mimir

**Validierung:**
- [ ] Mimir Pod läuft
- [ ] Metriken werden geschrieben
- [ ] Grafana Mimir/Prometheus-Datasource funktioniert

---

### 3.4 Tempo deployen

**Dateien:**
- `monitoring/tempo/Chart.yaml`
- `monitoring/tempo/values.yaml`

**Schritte:**
1. Tempo via Helm deployen (Monolithic Mode)
2. S3-Backend: Bucket `tempo-traces` auf Garage
3. ExternalSecret für Garage-Credentials
4. OTLP-Endpoint konfigurieren für Trace-Ingestion

**Validierung:**
- [ ] Tempo Pod läuft
- [ ] Grafana Tempo-Datasource funktioniert
- [ ] Traces werden gespeichert und sind in Grafana sichtbar

---

### 3.5 Alerting konfigurieren

**Schritte:**
1. Grafana Alerting aktivieren (oder Alertmanager separat)
2. Basis-Alert-Rules:
   - Node nicht erreichbar
   - Pod CrashLoopBackOff
   - PV > 80% voll
   - Zertifikat läuft in < 14 Tagen ab
   - OpenBao sealed
   - ArgoCD App out of sync
3. Notification Channel konfigurieren (E-Mail, Slack, Webhook)

**Validierung:**
- [ ] Alert-Rules sind aktiv in Grafana
- [ ] Test-Alert wird korrekt ausgelöst und benachrichtigt

---

## Phase 4 - Services

Ziel: Bestehende Services von Docker Compose migrieren.

**Voraussetzung:** Phase 3 vollständig, Monitoring aktiv.

---

### 4.1 artifact-keeper deployen

**Dateien:**
- `services/artifact-keeper/Chart.yaml`
- `services/artifact-keeper/values.yaml`
- `services/artifact-keeper/dependencies/`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace artifact-keeper`
2. PostgreSQL deployen:
   - PVC mit `local-path` StorageClass
   - Credentials via ESO → OpenBao
   - Resource Limits: 512MB Request, 1GB Limit
3. Meilisearch deployen:
   - PVC für Index-Daten
   - API-Key via ESO → OpenBao
4. artifact-keeper deployen:
   - Konfiguration: PostgreSQL Connection, Meilisearch URL, S3 (Garage) Backend
   - Alle Credentials via ESO
5. Traefik IngressRoute: `artifacts.development.cfapps.cool`
6. Bestehende Daten aus Docker-Compose-Setup migrieren:
   - PostgreSQL Dump importieren
   - Artifacts nach Garage S3 Bucket `artifacts` migrieren

**Validierung:**
- [ ] Alle Pods laufen: artifact-keeper, PostgreSQL, Meilisearch
- [ ] Web-UI erreichbar: `https://artifacts.development.cfapps.cool`
- [ ] Bestehende Artifacts sichtbar und downloadbar
- [ ] Upload neuer Artifacts funktioniert
- [ ] Suche via Meilisearch funktioniert

---

## Phase 5 - GitLab CE

Ziel: Self-hosted GitLab als Code-Hosting-Plattform.

**Voraussetzung:** Phase 4 vollständig. Genügend RAM verfügbar (~4-8GB zusätzlich).

---

### 5.1 GitLab CE deployen

**Dateien:**
- `services/gitlab-ce/Chart.yaml`
- `services/gitlab-ce/values.yaml`

**Schritte:**
1. Namespace erstellen: `kubectl create namespace gitlab`
2. GitLab CE via offiziellem Helm Chart deployen:
   - Integriertes PostgreSQL deaktivieren → eigene PostgreSQL-Instanz oder shared
   - Integriertes Nginx deaktivieren → Traefik IngressRoute
   - Integriertes cert-manager deaktivieren → unser cert-manager
   - Registry aktivieren (optional, da artifact-keeper existiert)
   - Object Storage → Garage S3 für LFS, Uploads, Artifacts, Packages
   - Resource Limits: 4GB Request, 8GB Limit
   - Credentials via ESO → OpenBao
3. Traefik IngressRoute: `gitlab.development.cfapps.cool`
4. SSH-Zugang konfigurieren (Port 22 oder alternativer Port via MetalLB)
5. Admin-Account einrichten, Credentials in OpenBao

**Validierung:**
- [ ] GitLab UI erreichbar: `https://gitlab.development.cfapps.cool`
- [ ] Login funktioniert
- [ ] Git Clone/Push via HTTPS und SSH funktioniert
- [ ] CI/CD Runners konfigurierbar (optional: K8s Runner)

---

## Phase 6 - Apps

Ziel: Bereit für eigene Applikations-Workloads.

**Schritte:**
1. Namespace `apps` erstellen
2. ArgoCD Application für `apps/` Verzeichnis konfigurieren
3. Template/Beispiel-App erstellen:
   - Helm Chart oder Kustomize
   - IngressRoute Template
   - ExternalSecret Template für App-Secrets
   - Deployment mit Resource Limits
4. Dokumentation: Wie deployt man eine neue App in den Stack

---

## Bootstrap Script (`bootstrap.sh`)

**Ziel:** Einmaliges Setup das den gesamten Stack von Null aufbaut.

**Dateien:**
- `bootstrap/bootstrap.sh`

**Ablauf:**
```
bootstrap.sh
├── 1. Prüfe Voraussetzungen
│   ├── Lima installiert?
│   ├── kubectl installiert?
│   ├── helm installiert?
│   └── socket_vmnet installiert?
│
├── 2. Lima VM erstellen und starten
│   ├── limactl create --name k3s-server bootstrap/lima.yaml
│   └── limactl start k3s-server
│
├── 3. K3s installieren
│   ├── bootstrap/install-k3s.sh (in VM ausführen)
│   └── kubeconfig exportieren
│
├── 4. Phase 1 - Foundation (manuelles Helm install, da ArgoCD noch nicht existiert)
│   ├── helm install openbao
│   ├── [INTERAKTIV] OpenBao init + unseal + Secrets eintragen
│   ├── helm install external-secrets
│   ├── kubectl apply ClusterSecretStore
│   ├── helm install metallb + IP-Pool
│   ├── helm install traefik
│   ├── helm install cert-manager + ClusterIssuer + Certificate
│   └── Warten auf Wildcard-Zertifikat
│
├── 5. Phase 2 - ArgoCD installieren
│   ├── helm install argocd
│   ├── Git-Repo konfigurieren
│   └── App-of-Apps deployen
│
├── 6. ArgoCD übernimmt
│   └── Alle weiteren Services werden von ArgoCD aus Git gesynct
│
└── 7. Status ausgeben
    └── stack.sh status
```

**Wichtig:** Ab Phase 2 übernimmt ArgoCD. Änderungen danach werden nur noch über Git gemacht, nicht mehr via `helm install` direkt.

---

## Disaster Recovery - Wiederherstellung auf Ersatzgerät

### Voraussetzungen auf neuem Mac:
- Homebrew installiert
- Zugriff auf Passwort-Manager (OpenBao Unseal Keys + Root Token)
- Git-Zugriff auf das `k8/` Repository

### Ablauf:
```
1. brew install lima kubectl helm socket_vmnet
2. git clone <repo-url> k8/
3. cd k8/
4. ./bootstrap.sh
   → Lima VM erstellt
   → K3s installiert
   → OpenBao deployed
   → [INTERAKTIV] Unseal Keys eingeben aus Passwort-Manager
   → [INTERAKTIV] Initiale Secrets eintragen (oder aus OpenBao-Backup restore)
   → ESO, MetalLB, Traefik, cert-manager deployed
   → ArgoCD deployed → synct alle Apps aus Git
5. velero restore create --from-backup <latest-backup>
   → PV-Daten werden aus S3 wiederhergestellt
6. ./stack.sh status
   → Verifizierung dass alles läuft
```

**Geschätzter Zeitaufwand:** 30-60 Minuten (abhängig von Datenvolumen beim Velero Restore).

---

## Helm Chart Version Pinning

Alle Helm Charts MÜSSEN versionsgepinnt sein für reproduzierbare Deployments:

| Chart | Repository |
|-------|-----------|
| OpenBao | https://openbao.github.io/openbao-helm |
| External Secrets | https://charts.external-secrets.io |
| MetalLB | https://metallb.github.io/metallb |
| Traefik | https://traefik.github.io/charts |
| cert-manager | https://charts.jetstack.io |
| ArgoCD | https://argoproj.github.io/argo-helm |
| Portainer | https://dl.portainer.io/ce/k8s/charts |
| Grafana | https://grafana.github.io/helm-charts |
| Loki | https://grafana.github.io/helm-charts |
| Mimir | https://grafana.github.io/helm-charts |
| Tempo | https://grafana.github.io/helm-charts |
| Velero | https://vmware-tanzu.github.io/helm-charts |
| GitLab CE | https://charts.gitlab.io |

Versionen werden in den jeweiligen `Chart.yaml` Dateien festgelegt.
