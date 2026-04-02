# kappman — Korifi App Manager

A lightweight Cloud Foundry Apps Manager for Korifi, providing a modern dark-mode web UI for managing organizations, spaces, applications, services, marketplace, buildpacks, and Korifi health status.

## Tech Stack

- Spring Boot 4.0.3 / Kotlin 2.3.10 / Gradle 9.4.0
- JDK 25, PostgreSQL 18, Flyway
- Thymeleaf + Bootstrap 5.3.3 (dark mode) + HTMX
- Spring Security (form login, BCrypt, RBAC)
- CF API v3 REST client

## Prerequisites

- JDK 25
- Gradle 9.4.0 (wrapper included)
- CF CLI (for deployment)
- Access to a Korifi cluster

## Local Development

```bash
# Start with H2 fallback (no PostgreSQL needed)
./gradlew bootRun
```

The app starts at http://localhost:8080 with H2 in-memory database.

Default credentials: `admin` / `change_me`

### With local PostgreSQL

```bash
# Create database
createdb kappman

# Start with PostgreSQL
SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/kappman \
SPRING_DATASOURCE_USERNAME=kappman \
SPRING_DATASOURCE_PASSWORD=kappman \
./gradlew bootRun
```

## Deployment to Korifi

### Automated (recommended)

```bash
# From the distribution directory — installs everything automatically
./install.sh phase 8
```

This creates the ServiceAccount, org/space, database, builds, pushes, and configures the Korifi API token.

### Manual

```bash
cf api https://api.app.cfapps.cool
cf login
./deploy-cf.sh
cf set-env kappman CF_PASSWORD <your-cf-admin-token>
cf restart kappman
```

The app will be available at https://kappman.app.cfapps.cool

## Features

- **Dashboard** — Stats, Korifi health summary, recent activity
- **Organizations** — List, create, delete, K8s namespace mapping
- **Spaces** — List, create, delete, drill-down to apps/services
- **Applications** — Start/stop/restart, scale, env vars, logs (HTMX)
- **Services** — Service instances, create/delete, bindings
- **Marketplace** — Service catalog, create instances from plans
- **Buildpacks** — Available buildpacks and kpack status
- **Status** — Korifi health checks with auto-refresh (30s)
- **User Management** — Admin-only CRUD, role assignment, org/space assignments

## RBAC

| Role | Capabilities |
|------|-------------|
| **Admin** | Full access, user management, create/delete orgs/spaces/apps |
| **Developer** | View assigned orgs/spaces, start/stop apps, manage env vars, services |

## Architecture

```
Browser (Thymeleaf + HTMX)
    ↓
Spring MVC Controllers
    ↓
Service Layer
    ↙          ↘
UserService     CfApiService
(PostgreSQL)    (CF API v3 REST)
```

The app stores only user data and audit logs in its own database. All CF resources (orgs, spaces, apps, services) are fetched live from the Korifi CF API v3.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CF_API_URL` | `https://api.app.cfapps.cool` | Korifi CF API endpoint |
| `CF_USERNAME` | `cf-admin` | CF API username |
| `CF_PASSWORD` | (empty) | CF API password/token |
| `CF_SKIP_SSL` | `true` | Skip SSL verification |
| `PORT` | `8080` | Server port |
