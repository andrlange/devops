# Upgrade to Stack v1.1.1

## Fresh Installation

Remove any previous installer files and download v1.1.1 in one command:

```bash
rm -f installer.sh stack.tgz && \
  curl -sfL https://artifactory.cfapps.cool/api/v1/repositories/generic/download/installer-v1.1.1.sh -o installer.sh && \
  curl -sfL https://artifactory.cfapps.cool/api/v1/repositories/generic/download/stack-v1.1.1.tgz -o stack.tgz && \
  bash installer.sh
```

This downloads both artifacts, then launches the interactive installer which deploys all 9 phases automatically.

## Extending an Existing Environment

If you already have a running stack (Phase 7+), you can add the new services and update kappman without re-running the full installer.

### Step 1: Update the stack files

```bash
cd ~/devops-stack
rm -f installer.sh stack.tgz
curl -sfL https://artifactory.cfapps.cool/api/v1/repositories/generic/download/stack-v1.1.1.tgz -o stack.tgz
tar xzf stack.tgz
```

### Step 2: Install Marketplace Extension 1

This adds three new services (PostgreSQL AI Enabled, OpenBao Secret Container, AI Model Connector) and their service broker:

```bash
cd ~/devops-stack/k8/distribution
./extend-marketplace-1.sh
```

The script will:
- Configure OpenBao (KV v2 engine + AppRole auth)
- Build and deploy the new marketplace broker
- Register it with Korifi
- Update the existing service broker with documentation metadata
- Rebuild and redeploy kappman with the new marketplace UI (parameters support + service docs)

### Step 3: Verify

```bash
cf marketplace
```

You should see 7 services:

| Service | Description |
|---------|-------------|
| postgresql | PostgreSQL 18 via CloudNativePG |
| valkey | Redis-compatible key-value store |
| rabbitmq | RabbitMQ message broker |
| s3 | S3-compatible object storage (Garage) |
| **postgres-ai** | PostgreSQL 17 with pgvector, pgvectorscale, PostGIS, AI/ML extensions |
| **openbao-secrets** | Managed secret container in OpenBao with AppRole access |
| **ai-connector** | AI Model Connector for Ollama / LM Studio |

### What's New in v1.1.1

- **Kappman V1.1.0** — Marketplace now shows info buttons with tabbed documentation (Overview, Parameters, Credentials, Create Service) for every service. The AI Connector create form includes a JSON parameters field.
- **PostgreSQL AI Enabled** — pgvector, pgvectorscale (DiskANN), PostGIS, full-text search, and 6 more extensions auto-activated
- **OpenBao Secret Container** — Application-managed secrets with AppRole-based access (role_id + secret_id)
- **AI Model Connector** — Connect to Ollama and/or LM Studio instances via OpenAI-compatible API

### Quick Test: Create an AI Connector

```bash
# Single endpoint (Ollama on Lima gateway)
cf create-service ai-connector default my-ollama \
  -c '{"provider":"ollama","host":"192.168.64.1","port":11434}'

# Multiple endpoints (Ollama + LM Studio)
cf create-service ai-connector default my-ai \
  -c '{"endpoints":[{"name":"ollama","provider":"ollama","host":"192.168.64.1","port":11434},{"name":"lmstudio","provider":"lmstudio","host":"192.168.64.1","port":1234}]}'

# Bind to your app
cf bind-service my-app my-ollama
cf restage my-app
```
