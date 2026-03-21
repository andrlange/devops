# HTML Demo — Statische Seite auf Korifi

Deployt eine statische HTML-Seite via Apache (httpd) auf Korifi unter `html-demo.app.cfapps.cool`.

## Voraussetzungen

- `cf` CLI installiert (`brew install cloudfoundry/tap/cf-cli@8`)
- `export KUBECONFIG=~/.kube/config-k3s`
- Korifi (Phase 6) deployed und CF API erreichbar

## Schritte

### 1. Anmelden

```bash
cf api https://api.app.cfapps.cool --skip-ssl-validation
kubectl config use-context cf-admin
cf login
# Waehle "cf-admin" wenn aufgefordert
```

### 2. Org erstellen und targeten

```bash
cf create-org dev
cf target -o dev
```

### 3. Space erstellen und targeten

```bash
cf create-space test
cf target -s test
```

### 4. App deployen

```bash
cd demos/html/
cf push
```

`cf push` liest `manifest.yml` automatisch und:
- Erkennt das `paketo-buildpacks/httpd` Buildpack
- Baut ein Container Image mit Apache httpd
- Erstellt die Route `html-demo.app.cfapps.cool`

### 5. Testen

```bash
curl -sk https://html-demo.app.cfapps.cool
```

## Aufraumen

```bash
cf delete html-demo -r -f
```
