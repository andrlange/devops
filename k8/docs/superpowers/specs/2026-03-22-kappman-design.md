# kappman — Korifi App Manager Design Spec

## Overview

kappman is a lightweight Cloud Foundry Apps Manager for Korifi, providing a modern dark-mode web UI for managing organizations, spaces, applications, services, marketplace, buildpacks, and Korifi health status. Inspired by the Pivotal Cloud Foundry Apps Manager, built with the same tech stack as the existing petclinic demo.

## Tech Stack

- **Framework:** Spring Boot 4.0.3, Kotlin 2.3.10
- **Build:** Gradle 9.4.0 (Kotlin DSL), JDK 25
- **Database:** PostgreSQL 18 (via CloudNativePG / OSBAPI Broker)
- **Migrations:** Flyway with `flyway-database-postgresql`
- **Templating:** Thymeleaf + Bootstrap 5.3.3 (dark mode) + HTMX
- **Security:** Spring Security (form login, BCrypt, session-based)
- **CF Integration:** CF API v3 REST client (Spring WebClient)
- **CF Bindings:** java-cfenv 4.0.0

## Deployment

- Deployed as a CF app via `cf push` on Korifi
- Route: `kappman.app.cfapps.cool`
- PostgreSQL service via OSBAPI broker: `cf create-service postgresql small kappman-db`
- Single JAR artifact, Paketo Java buildpack (JDK 25)
- Location: `k8/apps/kappman/`

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
    ↓               ↓
JPA/Flyway      WebClient
    ↓               ↓
PostgreSQL 18   Korifi CF API
```

### CF API Authentication

kappman uses a single configured admin token for all CF API v3 calls. Credentials are provided via environment variables or CF service binding:

```yaml
env:
  CF_API_URL: https://api.app.cfapps.cool
  CF_USERNAME: cf-admin
  CF_PASSWORD: (from service binding or env)
  CF_SKIP_SSL: true
```

The app authenticates at startup, caches the token, and refreshes automatically. The internal user database controls WHO can use the UI and WHAT they can see/do — all CF API calls run under the admin account.

## UI Design

### Layout

Collapsible icon rail sidebar (like VS Code/Slack):
- **Collapsed:** 52px wide icon rail with tooltips on hover
- **Expanded:** 200px sidebar with icon + text labels
- **Toggle:** Button at bottom, state persisted in LocalStorage
- **Transition:** CSS width transition (200ms ease)
- **Theme:** Spring Green (#6db33f) dark mode, matching petclinic/html-demo design language

### Color Scheme (CSS Variables)

```css
--spring-green: #6db33f;
--spring-green-dark: #5a9e2f;
--spring-bg: #191e1e;
--spring-card: #1e2626;
--spring-border: #2a3838;
--spring-text: #e0e0e0;
--spring-muted: #9ab89a;
```

### Navigation Items

| Icon | Label | Route |
|------|-------|-------|
| ⊞ | Dashboard | `/` |
| ◎ | Organizations | `/orgs` |
| ▤ | Spaces | `/spaces` |
| ⬡ | Applications | `/apps` |
| ♦ | Services | `/services` |
| ◈ | Marketplace | `/marketplace` |
| ⧉ | Buildpacks | `/buildpacks` |
| ♡ | Status | `/status` |
| ⚙ | Settings/Users | `/admin/users` (Admin only) |

## RBAC Model

Two roles: **Admin** and **Developer**.

### Admin
- Full access to all orgs, spaces, apps, services
- Create/delete orgs and spaces
- Delete apps
- Manage users (CRUD + role assignment)
- Assign orgs/spaces to developers

### Developer
- View only assigned orgs and spaces
- Start/stop/restart apps
- Scale app instances
- Manage environment variables
- Create/delete service instances
- Create/delete service bindings
- View app logs (recent)

## Data Model (PostgreSQL 18)

kappman stores only user data, assignments, and audit logs. All CF data (orgs, spaces, apps, services) comes live from the Korifi CF API v3.

### Tables

#### `users`
| Column | Type | Constraint |
|--------|------|------------|
| id | BIGINT GENERATED ALWAYS AS IDENTITY | PRIMARY KEY |
| username | VARCHAR(80) | NOT NULL UNIQUE |
| password_hash | VARCHAR(255) | NOT NULL |
| display_name | VARCHAR(120) | NOT NULL |
| email | VARCHAR(255) | |
| role | VARCHAR(20) | NOT NULL (ADMIN, DEVELOPER) |
| enabled | BOOLEAN | NOT NULL DEFAULT true |
| created_at | TIMESTAMP | NOT NULL DEFAULT NOW() |
| updated_at | TIMESTAMP | NOT NULL DEFAULT NOW() |

#### `user_org_assignments`
| Column | Type | Constraint |
|--------|------|------------|
| id | BIGINT GENERATED ALWAYS AS IDENTITY | PRIMARY KEY |
| user_id | BIGINT | NOT NULL FK → users(id) ON DELETE CASCADE |
| org_guid | VARCHAR(255) | NOT NULL |
| UNIQUE(user_id, org_guid) | | |

#### `user_space_assignments`
| Column | Type | Constraint |
|--------|------|------------|
| id | BIGINT GENERATED ALWAYS AS IDENTITY | PRIMARY KEY |
| user_id | BIGINT | NOT NULL FK → users(id) ON DELETE CASCADE |
| space_guid | VARCHAR(255) | NOT NULL |
| UNIQUE(user_id, space_guid) | | |

#### `audit_log`
| Column | Type | Constraint |
|--------|------|------------|
| id | BIGINT GENERATED ALWAYS AS IDENTITY | PRIMARY KEY |
| user_id | BIGINT | FK → users(id) ON DELETE SET NULL |
| action | VARCHAR(50) | NOT NULL |
| resource_type | VARCHAR(50) | NOT NULL |
| resource_guid | VARCHAR(255) | |
| details | TEXT | |
| created_at | TIMESTAMP | NOT NULL DEFAULT NOW() |

### Flyway Migrations

```
db/migration/
├── V1__create_schema.sql          # All tables
└── V2__seed_admin_user.sql        # Default admin user (admin/admin)
```

The `flyway-database-postgresql` dependency is required (same pattern as petclinic).

## Feature Areas

### 1. Dashboard (`/`)
- Counter cards: Orgs, Spaces, Apps, Services
- Korifi Health summary (API, Gateway, kpack status)
- Recent activity feed (from audit_log)
- Quick actions based on role

### 2. Organizations (`/orgs`)
- List all orgs with space count
- Show K8s namespace mapping (org GUID → namespace)
- Admin: Create/delete org (CF API call + audit)
- Click → drill-down to org's spaces

### 3. Spaces (`/orgs/{orgGuid}/spaces`)
- Spaces in org with app/service counts
- K8s namespace mapping display
- Admin: Create/delete space
- Click → drill-down to apps & services in space

### 4. Applications (`/apps`, `/spaces/{spaceGuid}/apps/{appGuid}`)
- App list with status badges (STARTED, STOPPED, STAGING)
- App detail page:
  - Instance info (count, memory, disk)
  - Routes
  - Start / Stop / Restart / Restage (HTMX buttons)
  - Scale instances (HTMX form)
  - Environment variables (view/set/delete)
  - Recent logs (HTMX polling, 30s interval)
  - Bound services list
- Admin: Delete app

### 5. Services (`/spaces/{spaceGuid}/services`)
- Service instances in space
- Plan, status, bindings display
- Create service instance (from marketplace)
- Create/delete service bindings
- Delete service instance

### 6. Marketplace (`/marketplace`)
- Service offerings catalog (from CF API)
- Plans with details (description, resources)
- Broker info
- Quick create → service instance creation form

### 7. Buildpacks (`/buildpacks`)
- Available buildpacks list (from CF API `/v3/buildpacks`)
- Version and status
- ClusterBuilder status (via CF API or direct status endpoint)
- Stack images (build/run)

### 8. Korifi Status (`/status`)
- CF API v3 info & health (`/v3/info`)
- Gateway status (Contour — via CF API reachability)
- kpack ClusterBuilder readiness
- Service Broker availability
- Auto-refresh via HTMX polling (every 30s)

### 9. User Management — Admin Only (`/admin/users`)
- User list with roles
- Create/delete users
- Assign role (Admin/Developer)
- Assign orgs/spaces to developers
- Reset password

## Package Structure

```
cool.cfapps.kappman/
├── KappmanApplication.kt
├── config/
│   ├── SecurityConfig.kt          # Spring Security, form login, BCrypt
│   ├── WebClientConfig.kt         # CF API WebClient bean
│   ├── DataSourceConfig.kt        # PostgreSQL with H2 fallback (from petclinic)
│   ├── GlobalModelAttributes.kt   # Runtime detection, sidebar state
│   └── KappmanProperties.kt       # @ConfigurationProperties
├── auth/
│   ├── User.kt                    # JPA Entity
│   ├── UserRole.kt                # Enum: ADMIN, DEVELOPER
│   ├── UserRepository.kt          # Spring Data JPA
│   ├── UserOrgAssignment.kt       # JPA Entity
│   ├── UserSpaceAssignment.kt     # JPA Entity
│   ├── AuthController.kt          # Login page
│   └── KappmanUserDetailsService.kt  # Spring Security UserDetailsService
├── dashboard/
│   └── DashboardController.kt
├── org/
│   └── OrgController.kt
├── space/
│   └── SpaceController.kt
├── app/
│   └── AppController.kt           # Start/Stop/Scale/Logs via HTMX
├── service/
│   ├── ServiceController.kt
│   └── MarketplaceController.kt
├── buildpack/
│   └── BuildpackController.kt
├── status/
│   └── StatusController.kt        # Health checks with HTMX auto-refresh
├── admin/
│   └── AdminController.kt         # User CRUD (Admin only)
├── audit/
│   ├── AuditLog.kt                # JPA Entity
│   ├── AuditLogRepository.kt
│   └── AuditService.kt            # Log actions
└── cfapi/
    ├── CfApiClient.kt             # Low-level REST client (WebClient)
    ├── CfApiService.kt            # Business logic (orgs, spaces, apps, services)
    └── model/                     # CF API v3 response DTOs
        ├── CfOrg.kt
        ├── CfSpace.kt
        ├── CfApp.kt
        ├── CfServiceInstance.kt
        ├── CfServiceOffering.kt
        ├── CfBuildpack.kt
        └── CfInfo.kt
```

## Template Structure

```
templates/
├── fragments/
│   ├── layout.html                # Main layout with sidebar
│   ├── navbar.html                # Top bar (user info, org/space selector)
│   └── sidebar.html               # Collapsible icon rail
├── auth/
│   └── login.html
├── dashboard/
│   └── index.html
├── org/
│   ├── list.html
│   └── detail.html
├── space/
│   ├── list.html
│   └── detail.html
├── app/
│   ├── list.html
│   ├── detail.html
│   └── fragments/                 # HTMX partial responses
│       ├── status-badge.html
│       ├── logs.html
│       └── env-vars.html
├── service/
│   ├── list.html
│   ├── detail.html
│   └── create.html
├── marketplace/
│   ├── catalog.html
│   └── create-instance.html
├── buildpack/
│   └── list.html
├── status/
│   └── index.html                 # Auto-refresh via HTMX
├── admin/
│   ├── users.html
│   ├── user-form.html
│   └── user-assignments.html
└── error/
    ├── 403.html
    └── 404.html
```

## Static Assets

```
static/
├── css/
│   └── kappman.css                # Spring Green dark theme (from petclinic pattern)
├── js/
│   └── sidebar.js                 # Collapse/expand toggle, LocalStorage
└── img/
    └── logo.svg                   # kappman logo (shamrock/leaf icon)
```

## Configuration

### application.yml

```yaml
spring:
  application:
    name: kappman
  datasource:
    url: ${SPRING_DATASOURCE_URL:jdbc:postgresql://localhost:5432/kappman}
    username: ${SPRING_DATASOURCE_USERNAME:kappman}
    password: ${SPRING_DATASOURCE_PASSWORD:kappman}
    driver-class-name: org.postgresql.Driver
  flyway:
    enabled: true
    locations: classpath:db/migration
  jpa:
    open-in-view: false
    hibernate:
      ddl-auto: validate

server:
  port: ${PORT:8080}

management:
  endpoints:
    web:
      exposure:
        include: health,info

kappman:
  cf-api:
    url: ${CF_API_URL:https://api.app.cfapps.cool}
    username: ${CF_USERNAME:cf-admin}
    password: ${CF_PASSWORD:}
    skip-ssl: ${CF_SKIP_SSL:true}
  instance-id: ${CF_INSTANCE_INDEX:${HOSTNAME:local}}
```

### manifest.yml

```yaml
applications:
- name: kappman
  memory: 1G
  instances: 1
  path: build/libs/kappman-0.0.1-SNAPSHOT.jar
  routes:
  - route: kappman.app.cfapps.cool
  buildpacks:
  - paketo-buildpacks/java
  env:
    BP_JVM_VERSION: "25"
    BPL_SPRING_CLOUD_BINDINGS_DISABLED: "true"
    CF_API_URL: https://api.app.cfapps.cool
    CF_USERNAME: cf-admin
    CF_SKIP_SSL: "true"
  services:
  - kappman-db
```

### deploy-cf.sh

Deployment script following petclinic pattern:
1. Check CF login
2. Create PostgreSQL service if missing (`cf create-service postgresql small kappman-db`)
3. Wait for service provisioning
4. Build JAR if needed (`./gradlew bootJar`)
5. `cf push`

## CF API v3 Endpoints Used

| Feature | Method | Endpoint |
|---------|--------|----------|
| API Info | GET | `/v3/info` |
| List Orgs | GET | `/v3/organizations` |
| Create Org | POST | `/v3/organizations` |
| Delete Org | DELETE | `/v3/organizations/{guid}` |
| List Spaces | GET | `/v3/spaces?organization_guids={guid}` |
| Create Space | POST | `/v3/spaces` |
| Delete Space | DELETE | `/v3/spaces/{guid}` |
| List Apps | GET | `/v3/apps?space_guids={guid}` |
| Get App | GET | `/v3/apps/{guid}` |
| Update App (start/stop) | PATCH | `/v3/apps/{guid}` |
| Scale App | POST | `/v3/apps/{guid}/actions/scale` |
| Restage App | POST | `/v3/builds` |
| Get App Env | GET | `/v3/apps/{guid}/env` |
| Set App Env | PATCH | `/v3/apps/{guid}/environment_variables` |
| App Routes | GET | `/v3/apps/{guid}/routes` |
| Recent Logs | GET | `/v3/apps/{guid}/audit_events` (or logcache) |
| List Service Instances | GET | `/v3/service_instances?space_guids={guid}` |
| Create Service Instance | POST | `/v3/service_instances` |
| Delete Service Instance | DELETE | `/v3/service_instances/{guid}` |
| List Bindings | GET | `/v3/service_credential_bindings` |
| Create Binding | POST | `/v3/service_credential_bindings` |
| Delete Binding | DELETE | `/v3/service_credential_bindings/{guid}` |
| Service Offerings | GET | `/v3/service_offerings` |
| Service Plans | GET | `/v3/service_plans` |
| List Buildpacks | GET | `/v3/buildpacks` |

## HTMX Integration

HTMX is used for interactive elements without full page reloads:

- **App Start/Stop/Restart:** `hx-post="/apps/{guid}/start"` with `hx-swap="outerHTML"` on status badge
- **Scale Instances:** `hx-post="/apps/{guid}/scale"` inline form
- **App Logs:** `hx-get="/apps/{guid}/logs"` with `hx-trigger="every 30s"` for polling
- **Status Page:** `hx-get="/status/health"` with `hx-trigger="every 30s"` auto-refresh
- **Delete Confirmations:** `hx-confirm="Are you sure?"` on destructive actions
- **Env Vars:** `hx-post="/apps/{guid}/env"` for add, `hx-delete` for remove

## Security

- Spring Security form-based login (`/login`)
- BCrypt password hashing
- Session-based authentication (Spring Session)
- Role-based access via `@PreAuthorize` or `SecurityConfig` URL patterns
- Admin-only routes: `/admin/**`
- CSRF protection enabled
- Developer visibility filtered by org/space assignments in service layer

## File Location

```
k8/apps/kappman/
├── build.gradle.kts
├── settings.gradle.kts
├── gradlew, gradlew.bat, gradle/
├── manifest.yml
├── deploy-cf.sh
├── Dockerfile
├── README.md
└── src/
    ├── main/
    │   ├── kotlin/cool/cfapps/kappman/
    │   └── resources/
    │       ├── application.yml
    │       ├── application-h2.yml
    │       ├── db/migration/
    │       ├── templates/
    │       └── static/
    └── test/
        └── kotlin/cool/cfapps/kappman/
```
