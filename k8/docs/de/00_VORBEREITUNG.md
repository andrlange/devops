# Vorbereitung: K8s DevOps Stack

Dieses Dokument beschreibt **alle Voraussetzungen**, die erfuellt sein muessen, bevor der K8s DevOps Stack (Phasen 1-4) auf einem neuen System ausgerollt werden kann.

> **Wichtig:** Alle Schritte muessen in der angegebenen Reihenfolge abgearbeitet werden. Fehlende Voraussetzungen fuehren zu Fehlern waehrend des Bootstrappings.

---

## Hardware-Voraussetzungen

| Komponente | Minimum | Empfohlen |
|---|---|---|
| Prozessor | Apple Silicon M4 | M4 Pro / M4 Max |
| RAM | 64 GB | 64 GB+ (GitLab CE allein benoetigt 4-10 GB RAM) |
| Freier Speicherplatz | 200 GB | 300 GB+ |
| Internetverbindung | Stabil | Stabil, idealerweise >100 Mbit/s |

Die Lima VM wird standardmaessig mit folgenden Ressourcen konfiguriert (anpassbar in `config.env`):

- **CPUs:** 8 Kerne
- **RAM:** 48 GB (der Rest bleibt fuer macOS) — GitLab CE benoetigt 4-10 GB RAM, daher sollten mindestens 48 GB fuer die VM eingeplant werden
- **Disk:** 200 GB

Eine stabile Internetverbindung wird benoetigt fuer:

- Download des Ubuntu 24.04 ARM64 Cloud-Images (~700 MB)
- K3s-Installation (~200 MB)
- Helm-Chart-Downloads
- Let's Encrypt ACME-Kommunikation (DNS-01 Challenge)
- GitLab CE Container Image (~1.5 GB — Import dauert entsprechend laenger)
- GitLab Runner + Helper Container Images

---

## Software-Voraussetzungen

### macOS und Homebrew

Homebrew muss installiert sein. Falls noch nicht vorhanden:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Erforderliche Tools

Alle Tools lassen sich ueber Homebrew installieren:

```bash
# Lima — Lightweight VM Manager fuer macOS
brew install lima

# Kubernetes CLI
brew install kubectl

# Helm — Kubernetes Package Manager
brew install helm

# Skopeo — Container Image Tool (fuer Import in artifact-keeper)
brew install skopeo

# jq — JSON-Prozessor (fuer Skripte)
brew install jq

# envsubst — Umgebungsvariablen in Templates ersetzen
brew install gettext
```

### Versionen pruefen

```bash
limactl --version        # >= 1.0.0
kubectl version --client # >= 1.30
helm version             # >= 3.15
skopeo --version         # >= 1.15
jq --version             # >= 1.7
envsubst --version       # GNU gettext
```

### socket_vmnet (Netzwerk-Voraussetzung)

`socket_vmnet` wird benoetigt, damit die Lima VM ein vzNAT-Netzwerk mit einer erreichbaren IP-Adresse im Subnetz `192.168.64.0/24` erhaelt. Ohne dieses Paket funktioniert MetalLB L2 nicht.

```bash
# Installation
brew install socket_vmnet

# Einmalige Einrichtung (erfordert sudo)
sudo brew services start socket_vmnet
```

Verifizierung:

```bash
# Service-Status pruefen
sudo brew services list | grep socket_vmnet
# Erwartete Ausgabe: socket_vmnet started
```

> **Hinweis:** `socket_vmnet` benoetigt Root-Rechte, da es ein virtuelles Netzwerk-Interface erstellt. Der Service muss nach jedem macOS-Neustart automatisch gestartet werden (wird durch `brew services` sichergestellt).

### Optionale Tools

```bash
# Google Cloud CLI (fuer GCP Cloud DNS Setup)
brew install google-cloud-sdk

# AWS CLI (falls Route53 statt Cloud DNS verwendet wird)
brew install awscli

# k9s — Terminal-basierte Kubernetes-UI
brew install k9s
```

---

## Netzwerk-Voraussetzungen

### vzNAT-Netzwerk

Die Lima VM verwendet das Apple Virtualization.framework mit vzNAT (shared networking):

- **Subnetz:** `192.168.64.0/24` (von macOS vergeben)
- **Gateway:** `192.168.64.1` (macOS Host)
- **DNS:** `192.168.64.1`
- Die VM erhaelt eine IP-Adresse in diesem Subnetz (z.B. `192.168.64.2`)

**Vorteile von vzNAT:**

- **Portabel:** Funktioniert auf jedem Netzwerk, unabhaengig von DHCP-Konfiguration, Firmen-Firewalls oder Netzwerkwechseln
- **Isoliert:** Das virtuelle Subnetz ist vom physischen Netzwerk getrennt
- **Stabil:** Keine IP-Aenderungen bei Netzwerkwechsel (z.B. Home-Office → Buero)

### MetalLB IP-Pool

MetalLB arbeitet im L2-Modus und annonciert IP-Adressen im vzNAT-Subnetz:

- **IP-Range:** `192.168.64.200 - 192.168.64.210` (konfigurierbar in `config.env`)
- Diese IPs werden fuer `LoadBalancer`-Services vergeben (Traefik, etc.)
- **Port 22 (SSH):** GitLab SSH-Zugang laeuft ueber eine separate MetalLB LoadBalancer IP (`192.168.64.202`), um Konflikte mit dem Standard-SSH-Port auf der Traefik-IP zu vermeiden
- Der Bereich liegt im oberen Teil des Subnetzes, um Konflikte mit der VM-IP zu vermeiden

**Keine Konflikte mit dem physischen Netzwerk:** Da vzNAT ein eigenes virtuelles Subnetz verwendet, gibt es keine Ueberschneidungen mit dem physischen LAN, WLAN oder VPN.

### Firewall

Falls eine lokale Firewall aktiv ist (z.B. Little Snitch, Lulu), muessen folgende Verbindungen erlaubt sein:

- `socket_vmnet` → Netzwerkzugriff
- `lima` / `qemu` → Netzwerkzugriff
- Ausgehend: HTTPS (Port 443) fuer ACME, Helm-Repos, Image-Downloads

---

## DNS-Vorbereitung

### Zwei Wildcard-Domains

Der Stack verwendet zwei getrennte Wildcard-Domains:

| Domain | Zweck | Beispiele |
|---|---|---|
| `*.development.cfapps.cool` | Platform & Management Services | ArgoCD, Grafana, Portainer, OpenBao |
| `*.app.cfapps.cool` | Application Workloads | Eigene Anwendungen (Phase 6) |

#### Platform-Services (development.cfapps.cool)

| Service | URL |
|---|---|
| ArgoCD | `argocd.development.cfapps.cool` |
| Grafana | `grafana.development.cfapps.cool` |
| Portainer | `portainer.development.cfapps.cool` |
| OpenBao | `openbao.development.cfapps.cool` |
| artifact-keeper | `artifacts.development.cfapps.cool` |

#### Application Workloads (app.cfapps.cool)

Fuer eigene Anwendungen, die in Phase 6 deployt werden (z.B. `myapp.app.cfapps.cool`).

### DNS-Eintraege konfigurieren

Beim DNS-Provider (z.B. Google Cloud DNS, Cloudflare, Route53) muessen **zwei** Wildcard-A-Records angelegt werden, die beide auf die gleiche Traefik LoadBalancer IP zeigen:

```
*.development.cfapps.cool  →  192.168.64.200
*.app.cfapps.cool          →  192.168.64.200
```

Die IP `192.168.64.200` ist die erste Adresse im MetalLB-Pool und wird Traefik zugewiesen. Beide Domains zeigen auf denselben Traefik-Ingress — das Routing erfolgt ueber Host-basierte IngressRoutes.

> **Hinweis:** Wenn eigene Domains verwendet werden, muessen `PLATFORM_DOMAIN` und `APPS_DOMAIN` in `config.env` entsprechend angepasst werden.

### TLS-Zertifikate

cert-manager stellt **separate** Wildcard-Zertifikate fuer jede Domain aus:

| Zertifikat | Domain | Secret Name | Verwendung |
|---|---|---|---|
| Platform Wildcard | `*.development.cfapps.cool` | Default TLSStore | `tls: {}` in IngressRoutes |
| Apps Wildcard | `*.app.cfapps.cool` | `wildcard-apps-tls` | `tls: { secretName: wildcard-apps-tls }` in IngressRoutes |

Beide Zertifikate werden ueber DNS-01 Challenge validiert. Da beide Domains zur gleichen DNS-Zone `cfapps.cool` gehoeren, wird derselbe GCP Cloud DNS Service Account verwendet.

### DNS-01 Challenge Provider

Fuer Let's Encrypt Wildcard-Zertifikate wird DNS-01 Validation benoetigt. Der Stack unterstuetzt zwei Provider:

1. **Google Cloud DNS** (Standard) — siehe Abschnitt "GCP Service Account"
2. **AWS Route53** (Alternative) — siehe Abschnitt "AWS Route53"

Mindestens ein Provider muss konfiguriert sein, damit cert-manager Wildcard-Zertifikate ausstellen kann.

---

## GCP Service Account (fuer Cloud DNS)

cert-manager benoetigt einen GCP Service Account mit Zugriff auf Cloud DNS, um DNS-01 Challenges fuer Let's Encrypt Wildcard-Zertifikate zu loesen.

### Voraussetzungen

- `gcloud` CLI installiert und authentifiziert (`gcloud auth login`)
- GCP-Projekt existiert (Standard: `cfapps-cool`)
- Cloud DNS Zone fuer die Domain ist eingerichtet

### Kurzanleitung

```bash
# 1. Service Account erstellen
gcloud iam service-accounts create cert-manager-dns \
  --display-name="cert-manager DNS-01 solver" \
  --project=cfapps-cool

# 2. Rolle zuweisen (roles/dns.admin = Minimum fuer DNS-01)
gcloud projects add-iam-policy-binding cfapps-cool \
  --member="serviceAccount:cert-manager-dns@cfapps-cool.iam.gserviceaccount.com" \
  --role="roles/dns.admin"

# 3. JSON-Key herunterladen
gcloud iam service-accounts keys create gcp-dns-credentials.json \
  --iam-account=cert-manager-dns@cfapps-cool.iam.gserviceaccount.com \
  --project=cfapps-cool
```

Die JSON-Datei wird spaeter waehrend des Bootstrappings in OpenBao gespeichert und anschliessend lokal geloescht.

> **Detaillierte Anleitung:** Siehe [`docs/gcp-dns-service-account.md`](gcp-dns-service-account.md)

---

## AWS Route53 (alternativ)

Falls AWS Route53 statt Google Cloud DNS verwendet wird:

### IAM User erstellen

```bash
aws iam create-user --user-name cert-manager-dns
```

### IAM Policy zuweisen

Minimale Policy fuer cert-manager:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:GetChange",
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/*"
    }
  ]
}
```

### Access Keys erstellen

```bash
aws iam create-access-key --user-name cert-manager-dns
```

Folgende Werte werden benoetigt:

- **Access Key ID** (z.B. `AKIA...`)
- **Secret Access Key** (z.B. `wJal...`)

Diese Credentials werden waehrend des Bootstrappings in OpenBao gespeichert.

### config.env anpassen

```bash
ACME_DNS_ZONES_ROUTE53="meine-domain.de"
ACME_DNS_ZONES_CLOUDDNS=""   # Cloud DNS deaktivieren falls nur Route53
```

---

## Container Registry (artifact-keeper)

Der Stack bezieht **alle** Container Images aus der eigenen artifact-keeper Registry. Dies stellt sicher, dass:

- Keine externen Abhaengigkeiten zur Laufzeit bestehen
- Rate-Limits von Docker Hub / GHCR / Quay nicht greifen
- Nur gepruefte Images im Cluster laufen
- Architektur-spezifische Tags verwendet werden koennen

### Voraussetzungen

artifact-keeper muss unter der konfigurierten URL erreichbar sein:

```
https://artifactory.cfapps.cool
```

Falls eine andere URL verwendet wird, muss `REGISTRY` in `config.env` angepasst werden.

### Images importieren

Alle benoetigten Container Images sind in `container-images.txt` aufgelistet. Das Import-Skript verwendet `skopeo`, um Images architektur-spezifisch zu importieren:

```bash
# Alle Images importieren (Multi-Arch)
./import-all-containers.sh

# Nur ARM64 Images importieren
./import-all-containers.sh --arch-only arm64

# Nur Images fuer Phase 1 importieren
./import-all-containers.sh --phase 1

# Trockenlauf — zeigt an, was importiert wuerde
./import-all-containers.sh --dry-run

# Lokal auf dem Server (schnell, kein TLS)
./import-all-containers.sh --local
```

### Image-Tag-Schema

Images werden mit architektur-spezifischem Suffix gespeichert:

```
artifactory.cfapps.cool/docker-local/<image>:<tag>-arm64
artifactory.cfapps.cool/docker-local/<image>:<tag>-amd64
```

Beispiel:

```
artifactory.cfapps.cool/docker-local/openbao/openbao:2.5.1-arm64
```

### Credentials

Zwei Satz Credentials werden benoetigt:

| Zweck | Beschreibung |
|---|---|
| **Admin-Credentials** | Fuer `import-all-containers.sh` — Schreibzugriff auf die Registry |
| **Read-Only Credentials** | Fuer K8s Pull-Secrets — nur Lesezugriff zum Pullen von Images |

Die Read-Only Credentials werden als Kubernetes Secret (`artifact-keeper-pull`) im Cluster hinterlegt, damit K3s Images aus der Registry pullen kann.

Zusaetzlich wird die Datei `/etc/rancher/k3s/registries.yaml` in der VM konfiguriert, damit K3s containerd direkt gegen die Registry authentifiziert (siehe `bootstrap/install-k3s.sh`).

---

## Passwort-Manager

Folgende Geheimnisse entstehen waehrend des Bootstrappings und **muessen sicher ausserhalb von Git gespeichert werden** (z.B. 1Password, Bitwarden, KeePass):

### OpenBao Unseal Keys

Bei der Initialisierung von OpenBao werden generiert:

| Geheimnis | Anzahl | Hinweis |
|---|---|---|
| **Unseal Keys** | 5 Stueck | Threshold: 3 von 5 werden zum Entsiegeln benoetigt |
| **Root Token** | 1 | Fuer initiale Konfiguration, danach einschraenken |

> **NIEMALS in Git speichern!** OpenBao Unseal Keys und Root Token gehoeren ausschliesslich in einen Passwort-Manager.

### Weitere Geheimnisse

| Geheimnis | Verwendung |
|---|---|
| artifact-keeper Admin-Password | Image-Import in die Registry |
| artifact-keeper Read-Only Password | K8s Pull-Secret |
| GCP JSON-Key (`gcp-dns-credentials.json`) | Wird in OpenBao gespeichert, lokal loeschen |
| AWS Access Key / Secret Key | Falls Route53 verwendet wird |
| ArgoCD Admin-Password | Wird bei Installation generiert |

---

## Konfiguration (config.env)

Die Datei `config.env` im Projektroot enthaelt alle konfigurierbaren Parameter. Sie wird von `bootstrap.sh` und `stack.sh` gelesen.

### Vollstaendige Parameterbeschreibung

#### Architektur

| Parameter | Default | Beschreibung |
|---|---|---|
| `ARCH` | `arm64` | Ziel-Architektur fuer Container Images. Bestimmt den Tag-Suffix: `image:tag-${ARCH}` |

#### Lima VM

| Parameter | Default | Beschreibung |
|---|---|---|
| `LIMA_VM_NAME` | `k3s-server` | Name der Lima VM |
| `LIMA_CPUS` | `8` | Anzahl CPU-Kerne fuer die VM |
| `LIMA_MEMORY_GB` | `48` | RAM in GB fuer die VM |
| `LIMA_DISK_GB` | `200` | Festplattenspeicher in GB fuer die VM |

#### Netzwerk

| Parameter | Default | Beschreibung |
|---|---|---|
| `NETWORK_SUBNET` | `192.168.64.0/24` | vzNAT-Subnetz (von macOS vergeben) |
| `NETWORK_GATEWAY` | `192.168.64.1` | Gateway-IP (macOS Host) |
| `NETWORK_DNS` | `192.168.64.1` | DNS-Server fuer die VM |
| `METALLB_IP_RANGE` | `192.168.64.200-192.168.64.210` | IP-Pool fuer MetalLB LoadBalancer-Services |

#### Domain und TLS

| Parameter | Default | Beschreibung |
|---|---|---|
| `PLATFORM_DOMAIN` | `development.cfapps.cool` | Domain fuer Platform & Management Services (`<service>.PLATFORM_DOMAIN`) |
| `APPS_DOMAIN` | `app.cfapps.cool` | Domain fuer Application Workloads (`<service>.APPS_DOMAIN`) |
| `ACME_EMAIL` | `admin@cfapps.cool` | E-Mail-Adresse fuer Let's Encrypt Registrierung |
| `GCP_PROJECT_ID` | `cfapps-cool` | GCP Projekt-ID fuer Cloud DNS |
| `ACME_DNS_ZONES_CLOUDDNS` | `cfapps.cool` | DNS-Zonen, die via Google Cloud DNS validiert werden |
| `ACME_DNS_ZONES_ROUTE53` | *(leer)* | DNS-Zonen, die via AWS Route53 validiert werden |

#### Container Registry

| Parameter | Default | Beschreibung |
|---|---|---|
| `REGISTRY` | `artifactory.cfapps.cool` | URL der Container Registry |
| `REGISTRY_REPO` | `docker-local` | Repository-Name in der Registry |
| `REGISTRY_PULL_SECRET_NAME` | `artifact-keeper-pull` | Name des K8s Pull-Secrets |

#### Persistent Storage

| Parameter | Default | Beschreibung |
|---|---|---|
| `PV_BASE_PATH` | `/data/persistent` | Basis-Pfad fuer Persistent Volumes in der VM |

---

## Checkliste vor dem Start

Alle Punkte abarbeiten, bevor `bootstrap.sh` ausgefuehrt wird:

### Hardware

- [ ] Apple Silicon Mac (M4 oder neuer)
- [ ] Mindestens 64 GB RAM
- [ ] Mindestens 200 GB freier Speicherplatz

### Software

- [ ] Homebrew installiert
- [ ] `limactl` installiert (>= 1.0.0)
- [ ] `kubectl` installiert (>= 1.30)
- [ ] `helm` installiert (>= 3.15)
- [ ] `skopeo` installiert (>= 1.15)
- [ ] `jq` installiert (>= 1.7)
- [ ] `envsubst` installiert (GNU gettext)
- [ ] `socket_vmnet` installiert und gestartet (`sudo brew services start socket_vmnet`)

### Netzwerk und DNS

- [ ] `socket_vmnet` Service laeuft (`sudo brew services list | grep socket_vmnet`)
- [ ] Wildcard DNS-Eintrag konfiguriert (`*.development.cfapps.cool → 192.168.64.200`)
- [ ] Wildcard DNS-Eintrag konfiguriert (`*.app.cfapps.cool → 192.168.64.200`)
- [ ] DNS-Eintraege getestet (`dig +short test.development.cfapps.cool` und `dig +short test.app.cfapps.cool`)

### Credentials

- [ ] GCP Service Account erstellt und JSON-Key heruntergeladen **oder** AWS IAM User mit Route53-Berechtigung erstellt
- [ ] artifact-keeper laeuft und ist erreichbar (`curl -s https://artifactory.cfapps.cool/health`)
- [ ] Alle Container Images importiert (`./import-all-containers.sh` erfolgreich durchgelaufen)
- [ ] artifact-keeper Admin-Credentials bereitgelegt
- [ ] artifact-keeper Read-Only Credentials bereitgelegt
- [ ] Passwort-Manager bereit fuer OpenBao Unseal Keys

### Konfiguration

- [ ] `config.env` geprueft und bei Bedarf angepasst (Domain, IP-Range, Registry-URL, GCP-Projekt)
- [ ] Bei eigener Domain: `PLATFORM_DOMAIN`, `APPS_DOMAIN` und `ACME_DNS_ZONES_*` Parameter aktualisiert
- [ ] Bei eigener Registry: `REGISTRY` und `REGISTRY_REPO` Parameter aktualisiert

---

> **Naechster Schritt:** Wenn alle Punkte der Checkliste abgehakt sind, kann mit Phase 1 (Foundation) begonnen werden — siehe Bootstrapping-Dokumentation.
