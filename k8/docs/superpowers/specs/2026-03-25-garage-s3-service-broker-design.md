# Garage S3 Service Broker — Design Spec

## Overview

Extend the existing OSBAPI Universal Broker with a 4th service: S3-compatible object storage powered by Garage. Developers can provision dedicated S3 buckets with credentials via `cf create-service s3 default my-bucket` and bind them to apps. The service appears automatically in Kappman's marketplace via the CF API.

## Architecture

```
cf create-service s3 default my-bucket
    |
Korifi -> OSBAPI Provision -> broker
    |
S3Provisioner.Provision()
    |
Garage Admin API (port 3903)
    |-- POST /v1/key       -> creates API key "s3-<instanceID>"
    |-- PUT  /v1/bucket     -> creates bucket "s3-<instanceID>"
    |-- PUT  /v1/bucket/allow -> grants read+write to key
    |
Credentials stored in K8s Secret "s3-<instanceID>-credentials"
    |
cf bind-service my-app my-bucket
    |
S3Provisioner.GetCredentials() -> reads secret -> returns S3 creds
```

The S3 provisioner follows the identical pattern as the existing PostgreSQL/Valkey/RabbitMQ provisioners, implementing the `Provisioner` interface.

## Service Catalog Entry

- **Service name:** `s3`
- **Service ID:** `a4d8f2b1-6e3c-4f7a-8b9d-5c1e3a7f2d4b`
- **Description:** S3-compatible object storage powered by Garage
- **Tags:** `s3`, `object-storage`, `garage`
- **Bindable:** true
- **Plan:** single `default` plan
  - **Plan ID:** `b5e9a3c2-7f4d-5a8b-9c0e-6d2f4b8a1c5e`
  - **Description:** Dedicated S3 bucket with read/write access
  - **Free:** true

Single plan because Garage has no per-bucket quota mechanism. Additional plans can be added if Garage adds quota support.

## Provisioner Implementation

New file: `provisioners/s3.go`

### Provision(name, namespace string, params map) error

1. Call Garage Admin API `POST /v1/key` with name `s3-<name>` — returns `accessKeyId`, `secretAccessKey`
2. Call Garage Admin API `PUT /v1/bucket` with global alias `s3-<name>` — returns bucket ID
3. Call Garage Admin API `PUT /v1/bucket/allow` granting `read: true, write: true` for the key on the bucket
4. Create K8s Secret `s3-<name>-credentials` in `cf-services` namespace with fields: `access_key_id`, `secret_access_key`, `bucket`, `endpoint`, `region`

### Deprovision(name, namespace string) error

1. Read the secret to get the key ID
2. Call Garage Admin API `DELETE /v1/bucket` (alias `s3-<name>`) — deletes bucket and contents
3. Call Garage Admin API `DELETE /v1/key?id=<accessKeyId>` — deletes the API key
4. Delete K8s Secret `s3-<name>-credentials`
5. Lenient on errors (log and continue, matching existing broker pattern)

### GetCredentials(name, namespace string) (map, error)

1. Read K8s Secret `s3-<name>-credentials`
2. Return credential map:

```json
{
  "type": "s3",
  "access_key_id": "GK...",
  "secret_access_key": "...",
  "endpoint": "http://garage.garage.svc.cluster.local:3900",
  "bucket": "s3-a1b2c3d4",
  "region": "garage",
  "path_style": true,
  "uri": "s3://GK...@garage.garage.svc.cluster.local:3900/s3-a1b2c3d4"
}
```

### IsReady(name, namespace string) (bool, error)

Check that the K8s Secret `s3-<name>-credentials` exists. Garage bucket creation is synchronous (unlike CRD-based operators), so the secret's presence confirms readiness.

## Garage Admin API Interaction

The broker calls the Garage Admin HTTP API (port 3903) directly, using a bearer token for authentication. This is preferred over kubectl exec for reliability and proper API contract.

### Endpoints used

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/v1/key` | Create API key |
| GET | `/v1/key?id=<id>` | Get key info |
| DELETE | `/v1/key?id=<id>` | Delete API key |
| PUT | `/v1/bucket` | Create bucket |
| DELETE | `/v1/bucket?id=<id>` | Delete bucket |
| PUT | `/v1/bucket/allow` | Grant key access to bucket |

### Authentication

Bearer token in `Authorization` header. Token sourced from Garage config (`[admin]` section) and stored in OpenBao at `secret/garage/admin-token`.

## Configuration

New environment variables on broker deployment:

| Env Var | Value | Source |
|---------|-------|--------|
| `GARAGE_ADMIN_TOKEN` | Garage admin API bearer token | OpenBao via ESO |
| `GARAGE_ADMIN_URL` | `http://garage.garage.svc.cluster.local:3903` | Hardcoded default |
| `GARAGE_S3_ENDPOINT` | `http://garage.garage.svc.cluster.local:3900` | Hardcoded default |

## Deployment Changes

### deployment.yaml

- Image tag bump: `1.2.0-arm64` -> `1.3.0-arm64`
- Add env vars: `GARAGE_ADMIN_TOKEN` (from ESO secret), `GARAGE_ADMIN_URL`, `GARAGE_S3_ENDPOINT`
- No RBAC changes — existing ClusterRole already grants Secret create/read/delete in `cf-services`

### OpenBao + ESO

- OpenBao path: `secret/garage/admin-token` containing the Garage admin bearer token
- ExternalSecret in `cf-services` namespace syncs to K8s Secret `garage-admin-token`

### install.sh (Phase 7)

1. Extract or configure Garage admin token, store in OpenBao at `secret/garage/admin-token`
2. Add `cf enable-service-access s3` after broker registration

## Naming Convention

- Bucket name: `s3-<first 8 chars of instanceID>` (e.g., `s3-a1b2c3d4`)
- API key name: `s3-<first 8 chars of instanceID>`
- K8s Secret: `s3-<first 8 chars of instanceID>-credentials`
- Matches existing broker pattern (`pg-`, `valkey-`, `rmq-` prefixes)

## Kappman Integration

No changes needed. Kappman reads service offerings from the CF API (`/v3/service_offerings`, `/v3/service_plans`). Adding the S3 service to the broker catalog makes it automatically visible in the marketplace page. Service instances appear in the services view.

## Developer Experience

```bash
# See S3 in marketplace
cf marketplace
# s3   default   S3-compatible object storage powered by Garage

# Create a bucket
cf create-service s3 default my-bucket

# Bind to app (injects S3 credentials into VCAP_SERVICES)
cf bind-service my-app my-bucket

# View credentials
cf service-key my-bucket my-key
```

## Files Modified

| File | Change |
|------|--------|
| `src/broker/catalog.go` | Add S3 service + default plan |
| `src/broker/broker.go` | Register S3 provisioner in provisioners map |
| `src/provisioners/s3.go` | **New** — S3Provisioner implementation |
| `src/main.go` | Add Garage config env var parsing |
| `deployment.yaml` | Image tag bump, new env vars, ESO secret reference |
| `distribution/install.sh` | Garage admin token setup, `cf enable-service-access s3` |

## Bucket Lifecycle

- **Create:** Synchronous — bucket + key created immediately via Admin API
- **Bind:** Reads pre-created credentials from K8s Secret
- **Unbind:** No-op (matching existing broker pattern)
- **Delete:** Removes bucket (including contents), key, and secret
