# GCP Service Account fuer Cloud DNS (cert-manager DNS-01)

cert-manager benoetigt einen GCP Service Account mit Zugriff auf Cloud DNS, um DNS-01 Challenges fuer Let's Encrypt Wildcard-Zertifikate zu loesen.

## Voraussetzungen

- `gcloud` CLI installiert und authentifiziert
- GCP Projekt: `cfapps-cool`
- Cloud DNS Zone fuer `cfapps.cool` existiert bereits

## Schritt 1: Service Account erstellen

```bash
gcloud iam service-accounts create cert-manager-dns \
  --display-name="cert-manager DNS-01 solver" \
  --project=cfapps-cool
```

## Schritt 2: Berechtigung vergeben

```bash
gcloud projects add-iam-policy-binding cfapps-cool \
  --member="serviceAccount:cert-manager-dns@cfapps-cool.iam.gserviceaccount.com" \
  --role="roles/dns.admin"
```

> **Hinweis:** `roles/dns.admin` ist die minimale Rolle die cert-manager benoetigt
> (Lesen + Schreiben von DNS Records fuer TXT-Challenge).

## Schritt 3: JSON-Key herunterladen

```bash
gcloud iam service-accounts keys create gcp-dns-credentials.json \
  --iam-account=cert-manager-dns@cfapps-cool.iam.gserviceaccount.com \
  --project=cfapps-cool
```

Die Datei `gcp-dns-credentials.json` wird im aktuellen Verzeichnis erstellt.

## Schritt 4: In OpenBao speichern

```bash
export KUBECONFIG=~/.kube/config-k3s

kubectl exec -n openbao openbao-0 -- bao kv put secret/dns/google-cloud \
  credentials="$(cat gcp-dns-credentials.json)"
```

## Schritt 5: Wildcard-Zertifikat beantragen

```bash
kubectl apply -f k8/infrastructure/cert-manager/wildcard-certificate.yaml
```

## Schritt 6: JSON-Key loeschen

Der Key ist jetzt sicher in OpenBao gespeichert. Die lokale Datei loeschen:

```bash
rm gcp-dns-credentials.json
```

## Verifizierung

```bash
# ExternalSecret synced?
kubectl get externalsecret -n cert-manager

# ClusterIssuer ready?
kubectl get clusterissuer letsencrypt-prod

# Zertifikat ausgestellt?
kubectl get certificate -n traefik
kubectl describe certificate wildcard-development -n traefik
```
