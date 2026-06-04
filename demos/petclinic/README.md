# Petclinic

A Spring Boot demo application for managing a veterinary clinic. Built with Kotlin, Thymeleaf, and Bootstrap — featuring a dark theme, dual database support (PostgreSQL/H2), three deployment modes, and runtime environment detection.

## Tech Stack

- **Spring Boot 4.0.4** / **Kotlin 2.3.10** / **JDK 25**
- **Thymeleaf** with Bootstrap 5.3.3 (dark theme)
- **PostgreSQL 18** (primary) with **H2** fallback
- **Flyway** for database migrations
- **java-cfenv** for Cloud Foundry service binding

## Features

- Owner, Pet, Vet, and Appointment management (full CRUD)
- Monthly appointment calendar (2024–2034)
- Live client-side filtering for owners and pets
- 110 demo owners, 160+ pets with type images, 500+ appointments
- Navbar shows runtime environment (Local / Docker / Cloud Foundry), database type (H2 / PostgreSQL), and instance ID
- Responsive dark UI with Spring green accents

## Database Configuration Priority

1. **VCAP_SERVICES** — Cloud Foundry service binding (via java-cfenv, highest priority)
2. **Environment variables** — `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD`
3. **application.yml defaults** — PostgreSQL at `localhost:5432/petclinic`
4. **H2 fallback** — Automatic if PostgreSQL is unreachable

## Deployment

### 1. Local Development

#### With PostgreSQL (via Docker Compose)

```bash
# Start PostgreSQL 18
docker compose up -d

# Run the app
./gradlew bootRun
```

Open http://localhost:8080 — navbar will show **Local** and **PostgreSQL**.

#### With H2 (no database needed)

```bash
./gradlew bootRun
```

If PostgreSQL is not reachable, the app automatically falls back to H2 in-memory database. Navbar will show **Local** and **H2**.

#### Explicitly use H2

```bash
SPRING_PROFILES_ACTIVE=h2 ./gradlew bootRun
```

H2 console available at http://localhost:8080/h2-console

### 2. Docker Compose (Full Stack)

Runs both the app and PostgreSQL 18 in containers.

```bash
docker compose -f docker-compose-app.yml up --build
```

Open http://localhost:8080 — navbar will show **Docker** and **PostgreSQL**.

### 3. Cloud Foundry

Deploy to any Cloud Foundry platform (Korifi, cf-for-k8s, TAS, etc.) with a marketplace PostgreSQL service.

#### Automated deployment

```bash
./deploy-cf.sh
```

The script automatically:
- Checks if logged in to CF
- Creates the `petclinic-db` PostgreSQL service if it doesn't exist
- Waits for the service to be ready
- Builds the JAR if missing
- Runs `cf push`

#### Manual deployment

```bash
# Target your org and space
cf target -o myorg -s myspace

# Build the JAR
./gradlew bootJar

# Create a PostgreSQL service instance
cf create-service postgresql small petclinic-db

# Wait for provisioning to complete
cf services

# Deploy
cf push
```

The `manifest.yml` configures:
- **2G memory**, **1 instance**
- **Paketo Java Buildpack** with JDK 25 (`BP_JVM_VERSION`)
- Route: `petclinic.app.cfapps.cool` (adjust for your domain)
- Service binding: `petclinic-db`

#### Scaling

```bash
# Scale to multiple instances
cf scale petclinic -i 3
```

The navbar shows the current instance index (`CF_INSTANCE_INDEX`), so each browser refresh may show a different instance — demonstrating horizontal scaling and load balancing.

#### How CF service binding works

1. `cf push` binds the `petclinic-db` service to the app
2. CF injects credentials into the `VCAP_SERVICES` environment variable
3. **java-cfenv** (`CfDataSourceEnvironmentPostProcessor`) detects the PostgreSQL binding and automatically configures `spring.datasource.*` properties
4. Flyway runs migrations on the bound database
5. The app starts with **Cloud Foundry** and **PostgreSQL** shown in the navbar

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SPRING_DATASOURCE_URL` | `jdbc:postgresql://localhost:5432/petclinic` | Database JDBC URL |
| `SPRING_DATASOURCE_USERNAME` | `petclinic` | Database username |
| `SPRING_DATASOURCE_PASSWORD` | `petclinic` | Database password |
| `PORT` | `8080` | Server port |
| `SPRING_PROFILES_ACTIVE` | _(none)_ | Set to `h2` to force H2 |
| `BP_JVM_VERSION` | `25` | JDK version for Paketo Buildpack (CF only) |
| `BPL_SPRING_CLOUD_BINDINGS_DISABLED` | `true` | Disables Spring Cloud Bindings at runtime (CF only) |

## Runtime Detection

The app automatically detects its runtime environment and displays it in the navbar:

| Environment | Detection | Badge |
|-------------|-----------|-------|
| **Cloud Foundry** | `VCAP_APPLICATION` env var present | Cloud icon |
| **Kubernetes** | `KUBERNETES_SERVICE_HOST` env var present | Diagram icon |
| **Docker** | `/.dockerenv` file exists | Box icon |
| **Local** | None of the above | PC icon |

## Project Structure

```
demos/petclinic/
├── build.gradle.kts          # Gradle build (Spring Boot 4.0.4, Kotlin 2.3.10, JDK 25)
├── Dockerfile                # Multi-stage build (eclipse-temurin:25)
├── docker-compose.yml        # PostgreSQL 18 only (for local dev)
├── docker-compose-app.yml    # Full stack: app + PostgreSQL
├── manifest.yml              # Cloud Foundry deployment manifest
├── deploy-cf.sh              # Automated CF deployment script
└── src/main/kotlin/cool/cfapps/petclinic/
    ├── PetclinicApplication.kt
    ├── config/               # DataSource fallback, DB info, runtime detection
    ├── home/                 # Dashboard controller
    ├── owner/                # Owner entity, repository, controller
    ├── pet/                  # Pet/PetType entities, repositories, controller
    ├── vet/                  # Vet/Specialty entities, repositories, controller
    └── visit/                # Visit entity, repository, controller, calendar
```
