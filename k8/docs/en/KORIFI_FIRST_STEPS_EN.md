# Korifi — Getting Started

A guide to deploying a Spring Boot 4 application with PostgreSQL 18 on Korifi. The app will be accessible at `demo.app.cfapps.cool` and will consume the PostgreSQL service via the classic CF environment variable `VCAP_SERVICES`.

**Prerequisites:**

- Phase 1-5 deployed, Phase 6 (Korifi) installed and functional
- `cf` CLI installed (`brew install cloudfoundry/tap/cf-cli@8`)
- `cf-admin` context present in Kubeconfig (`kubectl config use-context cf-admin`)
- Java 21+ and Maven/Gradle installed on the host
- CF API reachable: `curl -sk https://api.app.cfapps.cool/v3/info`

---

## 1. Set Up the CF CLI

```bash
# Set API endpoint
cf api https://api.app.cfapps.cool --skip-ssl-validation

# Log in as cf-admin
kubectl config use-context cf-admin
cf login
# Select "1. cf-admin" when prompted

# Set org and space (create if not already present)
cf create-org dev 2>/dev/null || true
cf target -o dev
cf create-space test 2>/dev/null || true
cf target -s test
```

**Validation:**

```bash
cf target
# API endpoint:   https://api.app.cfapps.cool
# user:           cf-admin
# org:            dev
# space:          test
```

---

## 2. Provision PostgreSQL 18

Korifi does not have a built-in service broker for databases. PostgreSQL is deployed directly as a K8s Deployment and registered in CF via a **User-Provided Service (UPS)**. The app then receives the credentials as usual through `VCAP_SERVICES`.

### 2.1 Deploy PostgreSQL 18 in Kubernetes

```bash
# Create namespace for CF services
kubectl create namespace cf-services 2>/dev/null || true

# Deploy PostgreSQL 18
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: demo-pg-credentials
  namespace: cf-services
type: Opaque
stringData:
  POSTGRES_DB: demodb
  POSTGRES_USER: demouser
  POSTGRES_PASSWORD: demopass-change-me
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-postgres
  namespace: cf-services
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-postgres
  template:
    metadata:
      labels:
        app: demo-postgres
    spec:
      containers:
      - name: postgres
        image: postgres:18
        ports:
        - containerPort: 5432
        envFrom:
        - secretRef:
            name: demo-pg-credentials
        volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: 256Mi
            cpu: 100m
          limits:
            memory: 512Mi
      volumes:
      - name: pgdata
        persistentVolumeClaim:
          claimName: demo-pg-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-pg-data
  namespace: cf-services
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: demo-postgres
  namespace: cf-services
spec:
  selector:
    app: demo-postgres
  ports:
  - port: 5432
    targetPort: 5432
EOF
```

**Wait until PostgreSQL is ready:**

```bash
kubectl wait --for=condition=Available deploy/demo-postgres -n cf-services --timeout=120s

# Test the connection
kubectl run pg-test --rm -it --restart=Never \
  --image=postgres:18 \
  --env="PGPASSWORD=demopass-change-me" \
  -- psql -h demo-postgres.cf-services.svc.cluster.local -U demouser -d demodb -c "SELECT version();"
# Expected output: PostgreSQL 18.x
```

### 2.2 Create a User-Provided Service in CF

The UPS registers the PostgreSQL credentials in CF. Spring Boot automatically picks them up via `VCAP_SERVICES`.

```bash
# Determine the ClusterIP of the PostgreSQL service
PG_HOST=$(kubectl get svc demo-postgres -n cf-services -o jsonpath='{.spec.clusterIP}')

# Create the User-Provided Service
# The format follows the CF convention for relational databases
cf create-user-provided-service demo-pg \
  -p "{\"uri\":\"postgresql://demouser:demopass-change-me@${PG_HOST}:5432/demodb\",\"username\":\"demouser\",\"password\":\"demopass-change-me\",\"hostname\":\"${PG_HOST}\",\"port\":\"5432\",\"dbname\":\"demodb\"}"
```

**Validation:**

```bash
cf services
# name      offering             plan   bound apps   last operation   broker
# demo-pg   user-provided                            create
```

> **Note:** `hostname` uses the ClusterIP, which can change if the service is recreated. Alternatively, the DNS name `demo-postgres.cf-services.svc.cluster.local` can be used — it is stable but longer. For a dev setup, the ClusterIP is sufficient.

---

## 3. Prepare the Spring Boot 4 App

### 3.1 Project Structure

```
demo-app/
├── pom.xml
├── manifest.yml
├── src/main/java/com/example/demo/
│   ├── DemoApplication.java
│   └── InfoController.java
└── src/main/resources/
    └── application.yml
```

### 3.2 pom.xml

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
         https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>4.0.0</version>
    <relativeTo/>
  </parent>

  <groupId>com.example</groupId>
  <artifactId>demo</artifactId>
  <version>0.0.1-SNAPSHOT</version>

  <properties>
    <java.version>21</java.version>
  </properties>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
    <!-- CF VCAP_SERVICES Parsing -->
    <dependency>
      <groupId>io.pivotal.cfenv</groupId>
      <artifactId>java-cfenv-boot</artifactId>
      <version>3.2.0</version>
    </dependency>
    <dependency>
      <groupId>org.postgresql</groupId>
      <artifactId>postgresql</artifactId>
      <scope>runtime</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

**Dependencies explained:**

| Dependency | Purpose |
|------------|---------|
| `spring-boot-starter-web` | REST API, embedded Tomcat |
| `spring-boot-starter-data-jpa` | JPA/Hibernate for PostgreSQL access |
| `spring-boot-starter-actuator` | Health endpoints for CF (`/actuator/health`) |
| `java-cfenv-boot` | Automatically parses `VCAP_SERVICES` into Spring Boot properties |
| `postgresql` | JDBC driver for PostgreSQL |

### 3.3 application.yml

```yaml
spring:
  application:
    name: demo
  jpa:
    hibernate:
      ddl-auto: update
    show-sql: false

# java-cfenv-boot automatically overrides these properties when
# VCAP_SERVICES is present. For local development:
---
spring:
  config:
    activate:
      on-profile: default
  datasource:
    url: jdbc:postgresql://localhost:5432/demodb
    username: demouser
    password: demopass-change-me
```

> **How does service detection work?**
>
> The `java-cfenv-boot` library automatically detects the CF environment via the `VCAP_SERVICES` environment variable. It extracts the PostgreSQL credentials from the User-Provided Service and sets the Spring Boot properties `spring.datasource.url`, `spring.datasource.username`, and `spring.datasource.password`. No manual configuration is required.

### 3.4 DemoApplication.java

```java
package com.example.demo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class DemoApplication {
    public static void main(String[] args) {
        SpringApplication.run(DemoApplication.class, args);
    }
}
```

### 3.5 InfoController.java

A simple controller that displays the DB status:

```java
package com.example.demo;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import javax.sql.DataSource;
import java.sql.Connection;
import java.util.Map;

@RestController
public class InfoController {

    private final DataSource dataSource;

    public InfoController(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @GetMapping("/")
    public Map<String, String> info() {
        String dbStatus;
        String dbVersion;
        try (Connection conn = dataSource.getConnection()) {
            dbStatus = "connected";
            dbVersion = conn.getMetaData().getDatabaseProductVersion();
        } catch (Exception e) {
            dbStatus = "error: " + e.getMessage();
            dbVersion = "unknown";
        }
        return Map.of(
            "app", "demo",
            "framework", "Spring Boot 4.0",
            "database.status", dbStatus,
            "database.version", dbVersion,
            "platform", "Korifi v0.18.0"
        );
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "UP");
    }
}
```

### 3.6 manifest.yml

The CF manifest defines the app name, route, memory, and service binding:

```yaml
applications:
- name: demo
  memory: 1G
  instances: 1
  routes:
  - route: demo.app.cfapps.cool
  services:
  - demo-pg
  buildpacks:
  - paketo-buildpacks/java
  env:
    JBP_CONFIG_OPEN_JDK_JRE: '{ jre: { version: 21.+ } }'
    JAVA_TOOL_OPTIONS: "-Djava.security.egd=file:/dev/./urandom"
```

**Manifest explained:**

| Field | Description |
|-------|-------------|
| `name: demo` | App name in CF (also used for K8s resources) |
| `memory: 1G` | RAM limit (Spring Boot + JVM requires ~512M-1G) |
| `routes` | Explicit route `demo.app.cfapps.cool` instead of an auto-generated route |
| `services` | Binds the `demo-pg` UPS to the app — credentials are injected into `VCAP_SERVICES` |
| `buildpacks` | Paketo Java Buildpack (automatically detects Maven/Gradle) |

---

## 4. Build and Deploy the App

### 4.1 Build the App Locally

```bash
cd demo-app

# Maven build (creates JAR in target/)
./mvnw clean package -DskipTests
```

> **Note:** Building locally is optional. The kpack builder on the cluster can also build directly from source code. However, building locally is recommended to ensure the app compiles before starting the slower cloud build.

### 4.2 cf push

```bash
# Make sure the CF login is active
cf target
# org: dev, space: test

# Deploy the app
cf push
```

`cf push` automatically performs the following steps:

1. **Upload:** Source code is sent to the Korifi API
2. **Build:** kpack creates an OCI container image via the Paketo Java Buildpack
3. **Stage:** The image is pushed to the registry (`artifactory.cfapps.cool/docker-local/korifi/`)
4. **Deploy:** Korifi creates a StatefulSet with the app
5. **Route:** HTTPRoute `demo.app.cfapps.cool` is created via Contour Gateway
6. **Bind:** `VCAP_SERVICES` with PostgreSQL credentials is injected into the container

**Expected output:**

```
Pushing app demo to org dev / space test as cf-admin...

Staging app and tracing logs...
   Build created: ...
   ...
   Successfully built image: artifactory.cfapps.cool/docker-local/korifi/...

Waiting for app demo to start...

Instances starting...

name:              demo
requested state:   started
routes:            demo.app.cfapps.cool
stack:
buildpacks:

type:           web
sidecars:
instances:      1/1
memory usage:   1024M
     state     since                  cpu    memory   disk
#0   running   2026-03-21T...         0.0%   0 of 1G  0 of 1G
```

> **Warning — First build is slow:** On ARM64 (Apple Silicon), kpack runs under QEMU emulation. The first Java build can take **10-15 minutes** as buildpack layers are downloaded and AMD64 binaries are emulated. Subsequent builds are faster (3-5 minutes) thanks to layer caching.

### 4.3 Verify the DNS Entry

The route `demo.app.cfapps.cool` must resolve to the Contour IP `192.168.64.203`. For local development, an `/etc/hosts` entry is sufficient:

```bash
# Check if entry exists
grep demo.app.cfapps.cool /etc/hosts

# If not, add it (one-time):
echo "192.168.64.203 demo.app.cfapps.cool" | sudo tee -a /etc/hosts
```

> **Note:** If a wildcard entry `*.app.cfapps.cool` already exists in `/etc/hosts` or Technitium DNS, no additional entry is needed.

---

## 5. Test the App

```bash
# Access the app
curl -sk https://demo.app.cfapps.cool
# Expected output:
# {"app":"demo","framework":"Spring Boot 4.0","database.status":"connected",
#  "database.version":"18.x","platform":"Korifi v0.18.0"}

# App status
cf apps
# name   requested state   processes   routes
# demo   started           web:1/1     demo.app.cfapps.cool

# Verify service binding
cf env demo
# Under VCAP_SERVICES the demo-pg service with all credentials should be visible

# View logs
cf logs demo --recent

# Health check
curl -sk https://demo.app.cfapps.cool/actuator/health
```

---

## 6. Common Operations

### Scale the App

```bash
# Horizontal (more instances)
cf scale demo -i 2

# Vertical (more memory)
cf scale demo -m 2G
```

### Redeploy the App

```bash
# After code changes
cd demo-app
./mvnw clean package -DskipTests
cf push
```

### Stream Logs

```bash
# Live logs (like tail -f)
cf logs demo

# Recent logs
cf logs demo --recent
```

### Change Service Binding

```bash
# Remove service
cf unbind-service demo demo-pg

# Bind new service
cf bind-service demo demo-pg-v2

# Restage the app so the new bindings take effect
cf restage demo
```

### Stop/Start the App

```bash
cf stop demo
cf start demo

# Or: delete the app entirely
cf delete demo -r -f
# -r = also delete the route
# -f = no confirmation prompt
```

### Set Environment Variables

```bash
# Additional env vars (besides VCAP_SERVICES)
cf set-env demo SPRING_PROFILES_ACTIVE production
cf restage demo
```

---

## 7. Troubleshooting

### Build Fails

```bash
# Check kpack build status
kubectl get builds -n $(kubectl get cfspace -A -o jsonpath='{.items[0].status.namespace}') -o wide

# View build logs (Korifi namespace for the space)
kubectl logs -n $(kubectl get cfspace -A -o jsonpath='{.items[0].status.namespace}') \
  -l app.kubernetes.io/component=build --tail=50
```

**Common causes:**

| Problem | Solution |
|---------|----------|
| `Failed to pull image` | Check registry credentials (`kubectl get secret image-registry-credentials -n cf`) |
| Build hangs at "Detecting" | QEMU emulation is slow — wait (up to 15 min for Java) |
| `Insufficient memory` | Lima VM does not have enough RAM — at least 4Gi free required |

### App Does Not Start

```bash
# Check pod status in K8s
cf target -o dev -s test
kubectl get pods -n $(kubectl get cfspace -A -o jsonpath='{.items[0].status.namespace}')

# Read pod logs directly
kubectl logs -n $(kubectl get cfspace -A -o jsonpath='{.items[0].status.namespace}') \
  -l korifi.cloudfoundry.org/app-guid --tail=50
```

**Common causes:**

| Problem | Solution |
|---------|----------|
| `Connection refused` (DB) | Check PostgreSQL service ClusterIP, update UPS if needed |
| `OOMKilled` | Increase memory: `cf scale demo -m 2G` |
| Port binding failed | Spring Boot must listen on `$PORT` (default with Paketo) |

### Route Not Reachable

```bash
# Check HTTPRoute
kubectl get httproute -A | grep demo

# Check gateway status
kubectl get gateway korifi -n korifi-gateway
# PROGRAMMED must be True

# Check DNS
dig +short demo.app.cfapps.cool
# Must return 192.168.64.203 (or check /etc/hosts)

# Check Envoy logs
kubectl logs -n projectcontour daemonset/envoy -c envoy --tail=20
```

### VCAP_SERVICES Not Present

```bash
# Check service binding
cf services
# demo-pg must list the app "demo" under "bound apps"

# If not bound:
cf bind-service demo demo-pg
cf restage demo
```

---

## 8. Cleanup

```bash
# Delete the app
cf delete demo -r -f

# Delete the service
cf delete-service demo-pg -f

# Remove PostgreSQL from K8s
kubectl delete deploy,svc,pvc,secret -n cf-services \
  -l app=demo-postgres --ignore-not-found
kubectl delete secret demo-pg-credentials -n cf-services --ignore-not-found

# Delete space/org (optional)
cf delete-space test -f
cf delete-org dev -f
```
