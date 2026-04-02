# GCP Service Account for Cloud DNS (cert-manager DNS-01)

cert-manager requires a GCP Service Account with access to Cloud DNS in order to solve DNS-01 challenges for Let's Encrypt wildcard certificates.

## Prerequisites

- `gcloud` CLI installed and authenticated
- GCP Project: `cfapps-cool`
- Cloud DNS zone for `cfapps.cool` already exists

## Step 1: Create Service Account

```bash
gcloud iam service-accounts create cert-manager-dns \
  --display-name="cert-manager DNS-01 solver" \
  --project=cfapps-cool
```

## Step 2: Assign Permissions

```bash
gcloud projects add-iam-policy-binding cfapps-cool \
  --member="serviceAccount:cert-manager-dns@cfapps-cool.iam.gserviceaccount.com" \
  --role="roles/dns.admin"
```

> **Note:** `roles/dns.admin` is the minimum role required by cert-manager
> (read + write access to DNS records for TXT challenge verification).

## Step 3: Download JSON Key

```bash
gcloud iam service-accounts keys create gcp-dns-credentials.json \
  --iam-account=cert-manager-dns@cfapps-cool.iam.gserviceaccount.com \
  --project=cfapps-cool
```

The file `gcp-dns-credentials.json` will be created in the current directory.

## Step 4: Store in OpenBao

```bash
export KUBECONFIG=~/.kube/config-k3s

kubectl exec -n openbao openbao-0 -- bao kv put secret/dns/google-cloud \
  credentials="$(cat gcp-dns-credentials.json)"
```

## Step 5: Request Wildcard Certificate

```bash
kubectl apply -f k8/infrastructure/cert-manager/wildcard-certificate.yaml
```

## Step 6: Delete JSON Key

The key is now securely stored in OpenBao. Delete the local file:

```bash
rm gcp-dns-credentials.json
```

## Verification

```bash
# ExternalSecret synced?
kubectl get externalsecret -n cert-manager

# ClusterIssuer ready?
kubectl get clusterissuer letsencrypt-prod

# Certificate issued?
kubectl get certificate -n traefik
kubectl describe certificate wildcard-development -n traefik
```
