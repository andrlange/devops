# Phase 1 — Foundation

## Uebersicht

### Ziel der Phase

Phase 1 legt das Fundament fuer den gesamten K8s DevOps Stack. Am Ende dieser Phase laeuft ein voll funktionsfaehiger K3s-Cluster in einer Lima VM auf Apple Silicon, mit Secret Management (OpenBao + ESO), Load Balancing (MetalLB), Ingress (Traefik) und automatischer TLS-Zertifikatsverwaltung (cert-manager). Alle nachfolgenden Phasen (Platform, Monitoring, Services) bauen auf dieser Infrastruktur auf.

### Komponenten-Uebersicht mit Versionen

| Komponente | Version | Helm Chart Version | Namespace | Beschreibung |
|---|---|---|---|---|
| Lima VM | vzNAT | - | - | Virtualisierung via Apple Virtualization.framework |
| K3s | latest | - | kube-system | Leichtgewichtige Kubernetes-Distribution |
| OpenBao | 2.5.1 | 0.8.0 | openbao | Secret Management (Vault-kompatibler Fork) |
| External Secrets Operator | v0.16.1 | 0.16.1 | external-secrets | Synchronisiert Secrets aus OpenBao nach Kubernetes |
| MetalLB | v0.15.3 | 0.15.3 | metallb-system | L2 Load Balancer fuer Bare-Metal / VMs |
| Traefik | v3.6.10 | 39.0.5 | traefik | Ingress Controller mit Dashboard |
| cert-manager | v1.20.0 | 1.20.0 | cert-manager | Automatische TLS-Zertifikate via Let's Encrypt |

### Dependency Chain

```
Lima VM
  └── K3s
        ├── OpenBao (Secret Management)
        │     └── External Secrets Operator (liest aus OpenBao)
        │           └── cert-manager (DNS-Credentials via ESO)
        ├── MetalLB (LoadBalancer IPs)
        │     └── Traefik (bekommt IP von MetalLB)
        │           └── cert-manager (Wildcard-Zertifikat im Traefik-Namespace)
        └── stack.sh (Management auf dem Host)
```

Die Installationsreihenfolge ist: Lima VM -> K3s -> Pull Secrets -> OpenBao -> ESO -> MetalLB -> Traefik -> cert-manager -> TLS Store.

---

## 1.1 Lima VM

### Was wird installiert und warum

Lima stellt eine Linux-VM auf macOS bereit, die ueber Apples native `Virtualization.framework` (vmType: `vz`) laeuft. Das ist die performanteste Variante auf Apple Silicon und bietet:

- Nahezu native Geschwindigkeit auf ARM64
- vzNAT-Netzwerk, das MetalLB L2 Advertisements im Host-Netzwerk ermoeglicht
- Rosetta-Uebersetzung fuer x86_64-Binaerdateien (als Fallback)

Die VM wird im `plain`-Modus betrieben — das bedeutet, Lima installiert keinen eigenen Guest Agent. Mounts werden ueber die VM-Konfiguration definiert.

### Konfigurationsdetails

| Parameter | Wert | Beschreibung |
|---|---|---|
| vmType | `vz` | Apple Virtualization.framework |
| plain | `true` | Kein Lima Guest Agent |
| CPUs | 8 | Konfigurierbar in `config.env` (LIMA_CPUS) |
| RAM | 48 GiB | Konfigurierbar in `config.env` (LIMA_MEMORY_GB) |
| Disk | 200 GiB | Konfigurierbar in `config.env` (LIMA_DISK_GB) |
| OS | Ubuntu 24.04 ARM64 | Cloud Image |
| Netzwerk | vzNAT | Shared Networking, Subnetz 192.168.64.0/24 |
| Rosetta | aktiviert | x86_64-Emulation ueber binfmt |
| SSH | forwardAgent: true | SSH-Agent wird durchgereicht |
| Mount | `/Users/andreas/development/devops/k8` -> `/mnt/k8` | Nur lesend |

**Konfigurationsdatei:** `k8/bootstrap/lima.yaml`

### Provisionierung

Beim ersten Start der VM werden automatisch folgende Pakete installiert und Kernel-Module geladen:

- **Pakete:** curl, jq, open-iscsi, nfs-common, bash-completion, ca-certificates, gnupg
- **Kernel-Module:** br_netfilter, ip_vs, ip_vs_rr, ip_vs_wrr, ip_vs_sh, nf_conntrack
- **sysctl-Einstellungen:** IP-Forwarding, Bridge-Netfilter, erhoehte inotify-Limits
- **Verzeichnis:** `/data/persistent` wird als Basis fuer Persistent Volumes erstellt

### Befehle zum Erstellen und Starten

```bash
# VM erstellen
limactl create --name=k3s-server k8/bootstrap/lima.yaml

# VM starten
limactl start k3s-server

# Shell in die VM oeffnen
limactl shell k3s-server
```

### Validierung

```bash
# VM-Status pruefen
limactl list

# Erwartete Ausgabe: k3s-server mit Status "Running"

# VM-IP ermitteln
limactl shell k3s-server hostname -I

# Kernel-Module pruefen
limactl shell k3s-server lsmod | grep -E "br_netfilter|ip_vs"

# Persistent-Volume-Verzeichnis pruefen
limactl shell k3s-server ls -la /data/persistent
```

---

## 1.2 K3s

### Installation mit deaktivierten Komponenten

K3s wird mit explizit deaktivierten Komponenten installiert, da diese separat via Helm deployed werden:

- `--disable servicelb` — MetalLB wird stattdessen verwendet
- `--disable traefik` — Traefik wird als eigenes Helm Chart installiert (volle Kontrolle ueber Version und Konfiguration)

**Installationsskript:** `k8/bootstrap/install-k3s.sh`

```bash
# Innerhalb der Lima VM ausfuehren:
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
  --disable servicelb \
  --disable traefik \
  --write-kubeconfig-mode 644 \
  --tls-san "<VM_IP>" \
  --data-dir /var/lib/rancher/k3s \
  --default-local-storage-path /data/persistent
```

Der `--tls-san` Parameter fuegt die VM-IP als Subject Alternative Name zum K3s-API-Server-Zertifikat hinzu. Dadurch kann kubectl vom macOS-Host aus darauf zugreifen.

### registries.yaml Konfiguration

K3s containerd wird konfiguriert, um Images von der privaten Registry `artifactory.cfapps.cool` zu pullen. Die Datei wird bei der Installation angelegt und spaeter durch `bootstrap.sh` mit den tatsaechlichen Credentials befuellt:

**Pfad in der VM:** `/etc/rancher/k3s/registries.yaml`

```yaml
configs:
  "artifactory.cfapps.cool":
    auth:
      username: "<wird durch bootstrap.sh gesetzt>"
      password: "<wird durch bootstrap.sh gesetzt>"
    tls:
      insecure_skip_verify: false
```

Nach dem Setzen der Credentials wird K3s neu gestartet:

```bash
limactl shell k3s-server sudo systemctl restart k3s
```

### kubeconfig Export

Das bootstrap.sh Skript exportiert die kubeconfig automatisch auf den macOS-Host:

```bash
# Manuell ausfuehren, falls noetig:
VM_IP=$(limactl shell k3s-server hostname -I | awk '{print $1}')

limactl shell k3s-server sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127\.0\.0\.1/${VM_IP}/g" \
  | sed "s/default/k3s-devops/g" \
  > ~/.kube/config-k3s

chmod 600 ~/.kube/config-k3s
export KUBECONFIG=~/.kube/config-k3s
```

Fuer dauerhafte Nutzung in der Shell:

```bash
echo 'export KUBECONFIG=~/.kube/config-k3s' >> ~/.zshrc
```

### Validierung

```bash
export KUBECONFIG=~/.kube/config-k3s

# Node-Status pruefen
kubectl get nodes -o wide
# Erwartung: 1 Node mit Status "Ready"

# Deaktivierte Komponenten verifizieren — keine Traefik/ServiceLB Pods
kubectl get pods -n kube-system | grep -E "traefik|svclb"
# Erwartung: keine Ergebnisse

# K3s-Version
kubectl version --short
```

---

## 1.3 OpenBao

### Helm Chart Installation

OpenBao wird als Standalone-Server (kein HA) mit File Storage deployed. Alle Container-Images kommen von der privaten Registry.

**Verzeichnis:** `k8/services/openbao/`

| Parameter | Wert |
|---|---|
| Helm Chart | openbao/openbao v0.8.0 |
| Image | `artifactory.cfapps.cool/docker-local/openbao/openbao:2.5.1-arm64` |
| Modus | Standalone (kein HA) |
| Storage | File-basiert, 10Gi PV (local-path) |
| Audit Storage | 2Gi PV (local-path) |
| UI | Aktiviert (ClusterIP Service) |
| Injector | Deaktiviert (ESO wird stattdessen verwendet) |

```bash
# Namespace erstellen
kubectl create namespace openbao

# Pull Secret erstellen (wird interaktiv durch bootstrap.sh abgefragt)
kubectl create secret docker-registry artifact-keeper-pull \
  --docker-server=artifactory.cfapps.cool \
  --docker-username="<username>" \
  --docker-password="<password>" \
  -n openbao

# Helm Dependencies laden und installieren
cd k8/services/openbao
helm dependency build
helm install openbao . -n openbao

# Warten bis der Pod laeuft (wird NICHT Ready sein, da noch sealed)
kubectl get pods -n openbao -w
```

### Initialisierung und Unseal

OpenBao muss einmalig initialisiert werden. Dabei werden 5 Unseal Keys und ein Root Token erzeugt. Zum Unsealen werden 3 der 5 Keys benoetigt (Shamir's Secret Sharing, Threshold 3/5).

```bash
# Initialisierung
kubectl exec -n openbao openbao-0 -- bao operator init

# WICHTIG: Unseal Keys und Root Token SOFORT in einem Passwort-Manager speichern!
# Diese werden NICHT erneut angezeigt.

# Unseal (3 verschiedene Keys verwenden)
kubectl exec -n openbao openbao-0 -- bao operator unseal <UNSEAL_KEY_1>
kubectl exec -n openbao openbao-0 -- bao operator unseal <UNSEAL_KEY_2>
kubectl exec -n openbao openbao-0 -- bao operator unseal <UNSEAL_KEY_3>
```

### KV v2 Engine aktivieren

```bash
# Mit Root Token einloggen
kubectl exec -it -n openbao openbao-0 -- bao login
# Root Token eingeben

# KV v2 Secret Engine unter dem Pfad "secret" aktivieren
kubectl exec -it -n openbao openbao-0 -- bao secrets enable -path=secret kv-v2
```

### Kubernetes Auth Method konfigurieren

Die Kubernetes Auth Method erlaubt es Pods (speziell ESO), sich ueber ihren ServiceAccount bei OpenBao zu authentifizieren.

```bash
# Kubernetes Auth aktivieren
kubectl exec -it -n openbao openbao-0 -- bao auth enable kubernetes

# Kubernetes Auth konfigurieren (nutzt den in-cluster API-Server)
kubectl exec -it -n openbao openbao-0 -- bao write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
```

### ESO Policy und Role erstellen

ESO benoetigt eine Policy mit Leserechten auf die Secrets und eine Kubernetes Auth Role, die an den ESO ServiceAccount gebunden ist.

```bash
# Policy erstellen
kubectl exec -it -n openbao openbao-0 -- bao policy write external-secrets - <<'POLICY'
path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }
POLICY

# Kubernetes Auth Role fuer ESO erstellen
kubectl exec -it -n openbao openbao-0 -- bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h
```

### Bootstrap Secrets eintragen

Folgende Secrets werden in OpenBao gespeichert und spaeter durch ESO in Kubernetes-Secrets synchronisiert:

**DNS-Credentials (fuer cert-manager DNS-01 Challenge):**

```bash
# GCP Service Account JSON fuer Cloud DNS
kubectl exec -it -n openbao openbao-0 -- bao kv put secret/dns/google-cloud \
  credentials=@/path/to/gcp-service-account.json
```

Hinweis: Die Datei muss zuerst in den Pod kopiert werden, oder der Inhalt wird direkt als String uebergeben:

```bash
# Alternative: JSON-Inhalt direkt uebergeben
kubectl exec -it -n openbao openbao-0 -- bao kv put secret/dns/google-cloud \
  credentials='{"type":"service_account","project_id":"cfapps-cool",...}'
```

**Registry Pull Credentials (fuer ESO-verwaltete Pull Secrets):**

```bash
kubectl exec -it -n openbao openbao-0 -- bao kv put secret/k8s/registry \
  server="https://artifactory.cfapps.cool" \
  username="<pull-user>" \
  password="<pull-token>"
```

### Validierung

```bash
# Pod-Status pruefen
kubectl get pods -n openbao
# Erwartung: openbao-0 Running 1/1

# Seal-Status pruefen
kubectl exec -n openbao openbao-0 -- bao status
# Erwartung: Sealed = false

# Secret Engine pruefen
kubectl exec -n openbao openbao-0 -- bao secrets list
# Erwartung: secret/ vom Typ kv (Version 2)

# Auth Methods pruefen
kubectl exec -n openbao openbao-0 -- bao auth list
# Erwartung: kubernetes/ vom Typ kubernetes

# Gespeicherte Secrets pruefen
kubectl exec -n openbao openbao-0 -- bao kv list secret/
# Erwartung: dns/ und k8s/ als Unterordner
```

---

## 1.4 External Secrets Operator (ESO)

### Installation und ClusterSecretStore

ESO wird installiert, um Secrets automatisch aus OpenBao in Kubernetes-Secrets zu synchronisieren. Dadurch muessen keine Secrets in Git gespeichert werden.

**Verzeichnis:** `k8/platform/external-secrets/`

| Parameter | Wert |
|---|---|
| Helm Chart | external-secrets v0.16.1 |
| Image | `artifactory.cfapps.cool/docker-local/external-secrets/external-secrets:v0.16.1-arm64` |
| CRDs | Werden mit installiert (installCRDs: true) |
| Komponenten | Controller, Webhook, CertController |

```bash
# Namespace erstellen
kubectl create namespace external-secrets

# Pull Secret erstellen
kubectl create secret docker-registry artifact-keeper-pull \
  --docker-server=artifactory.cfapps.cool \
  --docker-username="<username>" \
  --docker-password="<password>" \
  -n external-secrets

# Helm Dependencies laden und installieren
cd k8/platform/external-secrets
helm dependency build
helm install external-secrets . -n external-secrets

# Warten bis alle Pods bereit sind
kubectl wait --for=condition=Ready pods --all -n external-secrets --timeout=120s
```

**ClusterSecretStore** verbindet ESO mit OpenBao ueber die Kubernetes Auth Method:

**Datei:** `k8/platform/external-secrets/cluster-secret-store.yaml`

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

```bash
# ClusterSecretStore anwenden
kubectl apply -f k8/platform/external-secrets/cluster-secret-store.yaml
```

### ClusterExternalSecret fuer Registry Pull Secrets

Ein `ClusterExternalSecret` sorgt dafuer, dass in jedem Namespace automatisch ein Pull Secret fuer die private Registry erstellt wird. Damit muss kein manuelles Secret-Management pro Namespace betrieben werden.

**Datei:** `k8/platform/external-secrets/registry-pull-secret.yaml`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterExternalSecret
metadata:
  name: artifact-keeper-pull
spec:
  namespaceSelectors:
    - matchLabels: {}
  externalSecretSpec:
    refreshInterval: 1h
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

```bash
# ClusterExternalSecret anwenden
kubectl apply -f k8/platform/external-secrets/registry-pull-secret.yaml
```

### Validierung

```bash
# ESO Pods pruefen
kubectl get pods -n external-secrets
# Erwartung: 3 Pods (controller, webhook, cert-controller) alle Running

# ClusterSecretStore-Status pruefen
kubectl get clustersecretstore
# Erwartung: openbao mit Status "Valid" / Condition "True"

# ClusterExternalSecret pruefen
kubectl get clusterexternalsecret
# Erwartung: artifact-keeper-pull vorhanden

# Pruefen ob Pull Secrets in Namespaces erstellt wurden
kubectl get secret artifact-keeper-pull --all-namespaces
# Erwartung: Secret in allen Namespaces vorhanden
```

---

## 1.5 MetalLB

### L2 Mode mit vzNAT Subnetz

MetalLB stellt LoadBalancer-IPs bereit, die im vzNAT-Subnetz der Lima VM liegen. Im L2-Modus antwortet MetalLB auf ARP-Anfragen fuer die zugewiesenen IPs, sodass der macOS-Host diese direkt erreichen kann.

**Verzeichnis:** `k8/infrastructure/metallb/`

| Parameter | Wert |
|---|---|
| Helm Chart | metallb v0.15.3 |
| Controller Image | `artifactory.cfapps.cool/docker-local/metallb/controller:v0.15.3-arm64` |
| Speaker Image | `artifactory.cfapps.cool/docker-local/metallb/speaker:v0.15.3-arm64` |
| FRR | Deaktiviert (nur L2 Modus benoetigt) |

```bash
# Namespace erstellen
kubectl create namespace metallb-system

# Pull Secret erstellen
kubectl create secret docker-registry artifact-keeper-pull \
  --docker-server=artifactory.cfapps.cool \
  --docker-username="<username>" \
  --docker-password="<password>" \
  -n metallb-system

# Helm Dependencies laden und installieren
cd k8/infrastructure/metallb
helm dependency build
helm install metallb . -n metallb-system

# Warten bis alle Pods bereit sind
kubectl wait --for=condition=Ready pods --all -n metallb-system --timeout=120s
```

### IP Address Pool Konfiguration

**Datei:** `k8/infrastructure/metallb/ip-pool.yaml`

Der IP-Pool definiert den Bereich `192.168.64.200-192.168.64.210` (11 IPs) im oberen Bereich des vzNAT-Subnetzes, um Kollisionen mit DHCP-Adressen der VM zu vermeiden. Die `L2Advertisement` sorgt dafuer, dass MetalLB fuer diese IPs auf ARP-Anfragen antwortet.

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.64.200-192.168.64.210
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

```bash
# IP Pool und L2 Advertisement anwenden
kubectl apply -f k8/infrastructure/metallb/ip-pool.yaml
```

### Validierung

```bash
# MetalLB Pods pruefen
kubectl get pods -n metallb-system
# Erwartung: controller und speaker Pods Running

# IP Address Pool pruefen
kubectl get ipaddresspool -n metallb-system
# Erwartung: default-pool mit Adressbereich 192.168.64.200-192.168.64.210

# L2 Advertisement pruefen
kubectl get l2advertisement -n metallb-system
# Erwartung: default vorhanden

# Test: Einen LoadBalancer Service erstellen und pruefen ob eine IP zugewiesen wird
kubectl create deployment nginx-test --image=nginx --port=80 -n default
kubectl expose deployment nginx-test --type=LoadBalancer --port=80 -n default
kubectl get svc nginx-test -n default
# Erwartung: EXTERNAL-IP aus dem Bereich 192.168.64.200-210

# Aufraeumen
kubectl delete deployment nginx-test -n default
kubectl delete svc nginx-test -n default
```

---

## 1.6 Traefik

### LoadBalancer Service via MetalLB

Traefik wird als Ingress Controller deployed und bekommt ueber MetalLB eine feste LoadBalancer-IP zugewiesen. Alle HTTP(S)-Anfragen an `*.development.cfapps.cool` werden ueber diese IP geroutet.

**Verzeichnis:** `k8/infrastructure/traefik/`

| Parameter | Wert |
|---|---|
| Helm Chart | traefik v39.0.5 |
| Image | `artifactory.cfapps.cool/docker-local/traefik:v3.6.10-arm64` |
| Service Type | LoadBalancer |
| Kubernetes CRD Provider | Aktiviert (Cross-Namespace erlaubt) |
| Kubernetes Ingress Provider | Aktiviert |

```bash
# Namespace erstellen
kubectl create namespace traefik

# Pull Secret erstellen
kubectl create secret docker-registry artifact-keeper-pull \
  --docker-server=artifactory.cfapps.cool \
  --docker-username="<username>" \
  --docker-password="<password>" \
  -n traefik

# Helm Dependencies laden und installieren
cd k8/infrastructure/traefik
helm dependency build
helm install traefik . -n traefik

# Warten auf LoadBalancer-IP
kubectl get svc -n traefik traefik -w
# Erwartung: EXTERNAL-IP wird zugewiesen (z.B. 192.168.64.200)
```

### HTTP->HTTPS Redirect

Traefik ist so konfiguriert, dass alle HTTP-Anfragen (Port 80) automatisch auf HTTPS (Port 443) umgeleitet werden:

```yaml
additionalArguments:
  - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
  - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
  - "--entrypoints.websecure.http.tls"
```

### Dashboard IngressRoute

Das Traefik Dashboard ist unter `https://traefik.development.cfapps.cool` erreichbar:

```yaml
ingressRoute:
  dashboard:
    enabled: true
    matchRule: Host(`traefik.development.cfapps.cool`)
    entryPoints:
      - websecure
```

### TLSStore fuer Wildcard-Zertifikat

Nach der Installation von cert-manager und dem Ausstellen des Wildcard-Zertifikats wird ein TLSStore konfiguriert, der das Wildcard-Zertifikat als Standard-Zertifikat fuer alle HTTPS-Verbindungen setzt.

**Datei:** `k8/infrastructure/traefik/tls-store.yaml`

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: traefik
spec:
  defaultCertificate:
    secretName: wildcard-development-tls
```

```bash
# TLSStore anwenden (NACH cert-manager Installation)
kubectl apply -f k8/infrastructure/traefik/tls-store.yaml
```

### Validierung

```bash
# Traefik Pods pruefen
kubectl get pods -n traefik
# Erwartung: traefik Pod Running

# LoadBalancer-IP pruefen
kubectl get svc -n traefik traefik
# Erwartung: EXTERNAL-IP zugewiesen (z.B. 192.168.64.200)

# HTTP-Redirect testen (von macOS Host)
LB_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -v http://${LB_IP} 2>&1 | grep "Location:"
# Erwartung: Location: https://... (301 Redirect)

# Dashboard erreichbar (nach DNS-Konfiguration)
curl -k https://traefik.development.cfapps.cool
# Oder ueber /etc/hosts: <LB_IP> traefik.development.cfapps.cool
```

---

## 1.7 cert-manager

### DNS-01 Challenge mit Cloud DNS

cert-manager nutzt die DNS-01 Challenge, um Wildcard-Zertifikate von Let's Encrypt zu erhalten. Die Validierung erfolgt ueber Google Cloud DNS: cert-manager erstellt einen TXT-Record in der Zone `cfapps.cool`, Let's Encrypt prueft diesen, und das Zertifikat wird ausgestellt.

**Verzeichnis:** `k8/infrastructure/cert-manager/`

| Parameter | Wert |
|---|---|
| Helm Chart | cert-manager v1.20.0 |
| Controller Image | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-controller:v1.20.0-arm64` |
| CAInjector Image | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-cainjector:v1.20.0-arm64` |
| Webhook Image | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-webhook:v1.20.0-arm64` |
| ACME Solver Image | `artifactory.cfapps.cool/docker-local/jetstack/cert-manager-acmesolver:v1.20.0-arm64` |
| CRDs | Werden mit installiert |
| Startup API Check | Deaktiviert |

```bash
# Namespace erstellen
kubectl create namespace cert-manager

# Pull Secret erstellen
kubectl create secret docker-registry artifact-keeper-pull \
  --docker-server=artifactory.cfapps.cool \
  --docker-username="<username>" \
  --docker-password="<password>" \
  -n cert-manager

# Helm Dependencies laden und installieren
cd k8/infrastructure/cert-manager
helm dependency build
helm install cert-manager . -n cert-manager

# Warten bis alle Pods bereit sind
kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=120s
```

Die DNS-Credentials werden ueber ESO aus OpenBao synchronisiert:

**Datei:** `k8/infrastructure/cert-manager/dns-external-secret.yaml`

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

```bash
# DNS ExternalSecret anwenden
kubectl apply -f k8/infrastructure/cert-manager/dns-external-secret.yaml

# Warten bis das Secret synchronisiert wurde
kubectl get secret google-cloud-dns-credentials -n cert-manager
```

### ClusterIssuer Konfiguration

**Datei:** `k8/infrastructure/cert-manager/clusterissuer.yaml`

Der ClusterIssuer nutzt den ACME-Produktionsserver von Let's Encrypt und Google Cloud DNS fuer die DNS-01 Challenge. Die Variable `${GCP_PROJECT_ID}` wird durch `envsubst` aus `config.env` ersetzt (Wert: `cfapps-cool`).

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@cfapps.cool
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - dns01:
          cloudDNS:
            project: "${GCP_PROJECT_ID}"
            serviceAccountSecretRef:
              name: google-cloud-dns-credentials
              key: credentials.json
        selector:
          dnsZones:
            - "cfapps.cool"
```

```bash
# ClusterIssuer anwenden (mit envsubst fuer GCP_PROJECT_ID)
source k8/config.env
envsubst < k8/infrastructure/cert-manager/clusterissuer.yaml | kubectl apply -f -
```

### Wildcard-Zertifikat

**Datei:** `k8/infrastructure/cert-manager/wildcard-certificate.yaml`

Das Zertifikat wird im `traefik`-Namespace erstellt, da Traefik es als Standard-Zertifikat verwendet.

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

```bash
# Wildcard-Zertifikat anfordern
kubectl apply -f k8/infrastructure/cert-manager/wildcard-certificate.yaml

# TLSStore konfigurieren (Traefik nutzt das Wildcard-Zertifikat als Default)
kubectl apply -f k8/infrastructure/traefik/tls-store.yaml
```

### Validierung

```bash
# cert-manager Pods pruefen
kubectl get pods -n cert-manager
# Erwartung: 3 Pods (controller, cainjector, webhook) alle Running

# ClusterIssuer pruefen
kubectl get clusterissuer
# Erwartung: letsencrypt-prod mit Status "True" / "Ready"

# DNS-Credentials Secret pruefen
kubectl get secret google-cloud-dns-credentials -n cert-manager
# Erwartung: Secret vorhanden

# Zertifikat-Status pruefen
kubectl get certificate -n traefik
# Erwartung: wildcard-development mit READY=True

# Zertifikat-Details anzeigen
kubectl describe certificate wildcard-development -n traefik

# CertificateRequest pruefen (bei Problemen)
kubectl get certificaterequest -n traefik

# Secret mit dem Zertifikat pruefen
kubectl get secret wildcard-development-tls -n traefik
# Erwartung: Secret vom Typ kubernetes.io/tls vorhanden

# TLS-Verbindung testen (nach DNS-Konfiguration)
LB_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -v --resolve "traefik.development.cfapps.cool:443:${LB_IP}" \
  https://traefik.development.cfapps.cool 2>&1 | grep "subject:"
# Erwartung: subject: CN=*.development.cfapps.cool
```

---

## 1.8 stack.sh

### Beschreibung

`stack.sh` ist das zentrale Management-Skript fuer den gesamten K8s DevOps Stack. Es laeuft auf dem macOS-Host und steuert den Lebenszyklus der Lima VM und des K3s-Clusters.

**Pfad:** `k8/stack.sh`

Das Skript liest seine Konfiguration aus `k8/config.env` und verwaltet die kubeconfig unter `~/.kube/config-k3s`.

### Start/Stop/Status/Restart/Backup Befehle

```bash
# Stack starten
# - Startet Lima VM falls gestoppt
# - Wartet auf K3s API-Server
# - Aktualisiert kubeconfig auf dem Host (VM-IP kann sich aendern)
# - Wartet auf Core Pods (kube-system, openbao, traefik)
# - Prueft OpenBao Seal-Status (Hinweis zum manuellen Unseal)
# - Zeigt Endpoints an
./k8/stack.sh start

# Stack stoppen
# - Stoppt die Lima VM (alle Pods werden dabei beendet)
./k8/stack.sh stop

# Stack stoppen mit vorherigem Backup
# - Erstellt ein Velero-Backup bevor die VM gestoppt wird
./k8/stack.sh stop --backup

# Status anzeigen
# - Lima VM Status (IP, CPU, RAM, Disk)
# - K3s Node-Status
# - Namespace-Uebersicht mit Pod-Counts (Ready/Not-Ready)
# - ArgoCD Application Sync-Status
# - TLS-Zertifikate mit Ablaufdaten
# - Endpoint-Erreichbarkeit (HTTP-Status-Codes)
./k8/stack.sh status

# Stack neustarten
# - Stoppt und startet den Stack
./k8/stack.sh restart

# Velero Backup erstellen
# - Nutzt velero CLI falls installiert, sonst kubectl
# - Erstellt ein manuelles Backup aller Namespaces
./k8/stack.sh backup
```

### Status-Ausgabe

Der `status`-Befehl zeigt eine umfassende Uebersicht:

- **Lima VM:** Status, IP-Adresse, Ressourcen (CPU/RAM/Disk)
- **K3s Nodes:** Node-Status mit Details
- **Namespaces:** Tabellarische Uebersicht mit Total/Ready/Not-Ready Pod-Counts
- **OpenBao:** Seal-Status (Sealed/Unsealed) mit Warnung falls sealed
- **ArgoCD:** Sync- und Health-Status aller Applications
- **TLS Certificates:** Name, Namespace, Ready-Status, Ablaufdatum
- **Endpoints:** URL und Erreichbarkeit (UP/DOWN mit HTTP-Status-Code) fuer alle Services

---

## Automatisierter Bootstrap

Alle Phasen koennen mit einem einzigen Befehl ausgefuehrt werden:

```bash
# Kompletter Bootstrap (alle Phasen)
./k8/bootstrap/bootstrap.sh

# Einzelne Phase ausfuehren
./k8/bootstrap/bootstrap.sh phase_k3s
./k8/bootstrap/bootstrap.sh phase_pull_secrets
./k8/bootstrap/bootstrap.sh phase_openbao
./k8/bootstrap/bootstrap.sh phase_eso
./k8/bootstrap/bootstrap.sh phase_metallb
./k8/bootstrap/bootstrap.sh phase_traefik
./k8/bootstrap/bootstrap.sh phase_certmanager
./k8/bootstrap/bootstrap.sh phase_tls_store

# Mehrere Phasen kombinieren
./k8/bootstrap/bootstrap.sh phase_traefik phase_certmanager
```

**Voraussetzungen auf dem macOS-Host:**

```bash
# Benoetigte Tools installieren
brew install lima kubectl helm
```

---

## Bekannte Einschraenkungen

### Lima plain mode: Mounts eingeschraenkt

Im `plain`-Modus installiert Lima keinen Guest Agent in der VM. Der Mount von `k8/` nach `/mnt/k8` ist nur lesend (`writable: false`). Dateien, die in der VM geaendert werden muessen (z.B. `registries.yaml`), werden direkt ueber `limactl shell` und `tee` geschrieben, nicht ueber den Mount.

### OpenBao muss nach jedem VM-Neustart manuell unsealed werden

OpenBao verwendet Shamir's Secret Sharing und speichert die Unseal Keys nicht persistent. Nach jedem Neustart der Lima VM (oder des OpenBao Pods) muss OpenBao manuell mit 3 der 5 Unseal Keys entsperrt werden:

```bash
kubectl exec -n openbao openbao-0 -- bao operator unseal <KEY_1>
kubectl exec -n openbao openbao-0 -- bao operator unseal <KEY_2>
kubectl exec -n openbao openbao-0 -- bao operator unseal <KEY_3>
```

Der `stack.sh start` Befehl erkennt einen sealed OpenBao und gibt eine Warnung aus.

### vzNAT Subnetz wird von macOS bestimmt

Das vzNAT-Subnetz (`192.168.64.0/24`) wird von macOS Virtualization.framework zugewiesen und kann nicht frei gewaehlt werden. Der typische Bereich ist `192.168.64.0/24`, kann sich aber aendern. Falls sich das Subnetz aendert, muessen folgende Werte in `config.env` angepasst werden:

```bash
NETWORK_SUBNET="192.168.64.0/24"
NETWORK_GATEWAY="192.168.64.1"
NETWORK_DNS="192.168.64.1"
METALLB_IP_RANGE="192.168.64.200-192.168.64.210"
```

Zusaetzlich muss die `ip-pool.yaml` fuer MetalLB aktualisiert werden.

### VM-IP kann sich bei Neustarts aendern

Die VM erhaelt ihre IP per DHCP vom vzNAT-Interface. Bei VM-Neustarts kann sich die IP aendern. `stack.sh start` aktualisiert die kubeconfig automatisch mit der neuen IP. Falls kubectl nach einem Neustart nicht funktioniert:

```bash
# Kubeconfig manuell aktualisieren
VM_IP=$(limactl shell k3s-server hostname -I | awk '{print $1}')
limactl shell k3s-server sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127\.0\.0\.1/${VM_IP}/g" \
  | sed "s/default/k3s-devops/g" \
  > ~/.kube/config-k3s
```

### Container Images aus privater Registry

Alle Container Images werden ueber die private Registry `artifactory.cfapps.cool` bezogen. Vor der Installation jeder Komponente muss ein Pull Secret (`artifact-keeper-pull`) im jeweiligen Namespace erstellt werden. Nach der ESO-Installation uebernimmt der `ClusterExternalSecret` diese Aufgabe automatisch fuer alle Namespaces.

### DNS-Konfiguration erforderlich

Damit die Services ueber `*.development.cfapps.cool` erreichbar sind, muss ein DNS-Eintrag (oder `/etc/hosts`) die Wildcard-Domain auf die Traefik LoadBalancer-IP zeigen:

```bash
# LoadBalancer-IP ermitteln
LB_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# /etc/hosts ergaenzen (fuer lokalen Zugriff)
sudo bash -c "echo '${LB_IP} traefik.development.cfapps.cool argocd.development.cfapps.cool grafana.development.cfapps.cool' >> /etc/hosts"
```
