# Korifi — Erste Schritte

Eine Anleitung zum Deployen einer Spring Boot 4 Applikation mit PostgreSQL 18 auf Korifi. Die App wird unter `demo.app.cfapps.cool` erreichbar sein und den PostgreSQL-Service ueber die klassische CF-Umgebungsvariable `VCAP_SERVICES` konsumieren.

**Voraussetzungen:**

- Phase 1-5 deployed, Phase 6 (Korifi) installiert und funktional
- `cf` CLI installiert (`brew install cloudfoundry/tap/cf-cli@8`)
- `cf-admin` Kubeconfig vorhanden (`~/.kube/cf-admin-kubeconfig`)
- Java 21+ und Maven/Gradle auf dem Host installiert
- CF API erreichbar: `curl -sk https://api.app.cfapps.cool/v3/info`

---

## 1. CF CLI einrichten

```bash
# API Endpunkt setzen
cf api https://api.app.cfapps.cool --skip-ssl-validation

# Login als cf-admin
KUBECONFIG=~/.kube/cf-admin-kubeconfig cf login
# Waehle "1. cf-admin" wenn aufgefordert

# Org und Space setzen (falls noch nicht vorhanden)
cf create-org dev 2>/dev/null || true
cf target -o dev
cf create-space test 2>/dev/null || true
cf target -s test
```

**Validierung:**

```bash
cf target
# API endpoint:   https://api.app.cfapps.cool
# user:           cf-admin
# org:            dev
# space:          test
```

---

## 2. PostgreSQL 18 bereitstellen

Korifi hat keinen eingebauten Service Broker fuer Datenbanken. PostgreSQL wird direkt als K8s-Deployment bereitgestellt und ueber einen **User-Provided Service (UPS)** in CF registriert. Die App erhaelt die Credentials dann wie gewohnt ueber `VCAP_SERVICES`.

### 2.1 PostgreSQL 18 in Kubernetes deployen

```bash
# Namespace fuer CF-Services erstellen
kubectl create namespace cf-services 2>/dev/null || true

# PostgreSQL 18 deployen
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

**Warten bis PostgreSQL bereit ist:**

```bash
kubectl wait --for=condition=Available deploy/demo-postgres -n cf-services --timeout=120s

# Verbindung testen
kubectl run pg-test --rm -it --restart=Never \
  --image=postgres:18 \
  --env="PGPASSWORD=demopass-change-me" \
  -- psql -h demo-postgres.cf-services.svc.cluster.local -U demouser -d demodb -c "SELECT version();"
# Erwartete Ausgabe: PostgreSQL 18.x
```

### 2.2 User-Provided Service in CF erstellen

Der UPS registriert die PostgreSQL-Credentials in CF. Spring Boot erkennt diese automatisch ueber `VCAP_SERVICES`.

```bash
# ClusterIP des PostgreSQL-Services ermitteln
PG_HOST=$(kubectl get svc demo-postgres -n cf-services -o jsonpath='{.spec.clusterIP}')

# User-Provided Service erstellen
# Das Format folgt der CF-Konvention fuer relationale Datenbanken
cf create-user-provided-service demo-pg \
  -p "{\"uri\":\"postgresql://demouser:demopass-change-me@${PG_HOST}:5432/demodb\",\"username\":\"demouser\",\"password\":\"demopass-change-me\",\"hostname\":\"${PG_HOST}\",\"port\":\"5432\",\"dbname\":\"demodb\"}"
```

**Validierung:**

```bash
cf services
# name      offering             plan   bound apps   last operation   broker
# demo-pg   user-provided                            create
```

> **Hinweis:** `hostname` nutzt die ClusterIP, die sich aendern kann wenn der Service neu erstellt wird. Alternativ kann der DNS-Name `demo-postgres.cf-services.svc.cluster.local` verwendet werden — dieser ist stabil, aber laenger. Fuer ein Dev-Setup ist die ClusterIP ausreichend.

---

## 3. Spring Boot 4 App vorbereiten

### 3.1 Projektstruktur

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

**Abhaengigkeiten erklaert:**

| Dependency | Zweck |
|------------|-------|
| `spring-boot-starter-web` | REST API, eingebetteter Tomcat |
| `spring-boot-starter-data-jpa` | JPA/Hibernate fuer PostgreSQL-Zugriff |
| `spring-boot-starter-actuator` | Health-Endpoints fuer CF (`/actuator/health`) |
| `java-cfenv-boot` | Parsed `VCAP_SERVICES` automatisch in Spring Boot Properties |
| `postgresql` | JDBC-Treiber fuer PostgreSQL |

### 3.3 application.yml

```yaml
spring:
  application:
    name: demo
  jpa:
    hibernate:
      ddl-auto: update
    show-sql: false

# java-cfenv-boot ueberschreibt diese Properties automatisch wenn
# VCAP_SERVICES vorhanden ist. Fuer lokale Entwicklung:
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

> **Wie funktioniert die Service-Erkennung?**
>
> Die Bibliothek `java-cfenv-boot` erkennt automatisch die CF-Umgebung anhand der Umgebungsvariable `VCAP_SERVICES`. Sie extrahiert die PostgreSQL-Credentials aus dem User-Provided Service und setzt die Spring Boot Properties `spring.datasource.url`, `spring.datasource.username` und `spring.datasource.password`. Es ist keine manuelle Konfiguration noetig.

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

Ein einfacher Controller der den DB-Status anzeigt:

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

Das CF Manifest definiert App-Name, Route, Speicher und Service-Binding:

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

**Manifest erklaert:**

| Feld | Beschreibung |
|------|-------------|
| `name: demo` | App-Name in CF (wird auch fuer K8s-Ressourcen verwendet) |
| `memory: 1G` | RAM-Limit (Spring Boot + JVM benoetigt ~512M-1G) |
| `routes` | Explizite Route `demo.app.cfapps.cool` statt auto-generierter Route |
| `services` | Bindet den `demo-pg` UPS an die App — Credentials landen in `VCAP_SERVICES` |
| `buildpacks` | Paketo Java Buildpack (erkennt Maven/Gradle automatisch) |

---

## 4. App bauen und deployen

### 4.1 App lokal bauen

```bash
cd demo-app

# Maven Build (erstellt JAR in target/)
./mvnw clean package -DskipTests
```

> **Hinweis:** Das lokale Bauen ist optional. Der kpack Builder auf dem Cluster kann auch direkt aus dem Source Code bauen. Das lokale Bauen ist aber empfehlenswert um sicherzustellen, dass die App kompiliert bevor der langsamere Cloud-Build gestartet wird.

### 4.2 cf push

```bash
# Sicherstellen, dass CF-Login aktiv ist
KUBECONFIG=~/.kube/cf-admin-kubeconfig cf target
# org: dev, space: test

# App deployen
KUBECONFIG=~/.kube/cf-admin-kubeconfig cf push
```

`cf push` fuehrt folgende Schritte automatisch aus:

1. **Upload:** Source Code wird an Korifi API gesendet
2. **Build:** kpack erstellt via Paketo Java Buildpack ein OCI Container Image
3. **Stage:** Image wird in die Registry (`artifactory.cfapps.cool/docker-local/korifi/`) gepusht
4. **Deploy:** Korifi erstellt ein StatefulSet mit der App
5. **Route:** HTTPRoute `demo.app.cfapps.cool` wird via Contour Gateway erstellt
6. **Bind:** `VCAP_SERVICES` mit PostgreSQL-Credentials wird in den Container injiziert

**Erwartete Ausgabe:**

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

> **Achtung — Erster Build ist langsam:** Auf ARM64 (Apple Silicon) laeuft kpack unter QEMU-Emulation. Der erste Java-Build kann **10-15 Minuten** dauern, da Buildpack-Layer heruntergeladen und AMD64-Binaries emuliert werden. Folge-Builds sind dank Layer-Caching schneller (3-5 Minuten).

### 4.3 DNS-Eintrag pruefen

Die Route `demo.app.cfapps.cool` muss auf die Contour-IP `192.168.64.203` aufloesen. Fuer lokale Entwicklung genuegt ein `/etc/hosts`-Eintrag:

```bash
# Pruefen ob Eintrag vorhanden
grep demo.app.cfapps.cool /etc/hosts

# Falls nicht, hinzufuegen (einmalig):
echo "192.168.64.203 demo.app.cfapps.cool" | sudo tee -a /etc/hosts
```

> **Hinweis:** Falls bereits ein Wildcard-Eintrag `*.app.cfapps.cool` in `/etc/hosts` oder Technitium DNS existiert, ist kein zusaetzlicher Eintrag noetig.

---

## 5. App testen

```bash
# App aufrufen
curl -sk https://demo.app.cfapps.cool
# Erwartete Ausgabe:
# {"app":"demo","framework":"Spring Boot 4.0","database.status":"connected",
#  "database.version":"18.x","platform":"Korifi v0.18.0"}

# App Status
cf apps
# name   requested state   processes   routes
# demo   started           web:1/1     demo.app.cfapps.cool

# Service Binding pruefen
cf env demo
# Unter VCAP_SERVICES sollte der demo-pg Service mit allen Credentials sichtbar sein

# Logs anzeigen
cf logs demo --recent

# Health Check
curl -sk https://demo.app.cfapps.cool/actuator/health
```

---

## 6. Haeufige Operationen

### App skalieren

```bash
# Horizontal (mehr Instanzen)
cf scale demo -i 2

# Vertikal (mehr Speicher)
cf scale demo -m 2G
```

### App neu deployen

```bash
# Nach Code-Aenderungen
cd demo-app
./mvnw clean package -DskipTests
cf push
```

### Logs streamen

```bash
# Live-Logs (wie tail -f)
cf logs demo

# Letzte Logs
cf logs demo --recent
```

### Service-Binding aendern

```bash
# Service entfernen
cf unbind-service demo demo-pg

# Neuen Service binden
cf bind-service demo demo-pg-v2

# App restagen damit neue Bindings wirksam werden
cf restage demo
```

### App stoppen/starten

```bash
cf stop demo
cf start demo

# Oder: App komplett loeschen
cf delete demo -r -f
# -r = auch Route loeschen
# -f = keine Bestaetigungsabfrage
```

### Umgebungsvariablen setzen

```bash
# Zusaetzliche Env-Vars (neben VCAP_SERVICES)
cf set-env demo SPRING_PROFILES_ACTIVE production
cf restage demo
```

---

## 7. Troubleshooting

### Build schlaegt fehl

```bash
# kpack Build-Status pruefen
kubectl get builds -n $(kubectl get cfspace -A -o jsonpath='{.items[0].status.namespace}') -o wide

# Build-Logs anzeigen (Korifi-Namespace fuer den Space)
kubectl logs -n $(kubectl get cfspace -A -o jsonpath='{.items[0].status.namespace}') \
  -l app.kubernetes.io/component=build --tail=50
```

**Haeufige Ursachen:**

| Problem | Loesung |
|---------|---------|
| `Failed to pull image` | Registry-Credentials pruefen (`kubectl get secret image-registry-credentials -n cf`) |
| Build haengt bei "Detecting" | QEMU-Emulation ist langsam — abwarten (bis 15 Min fuer Java) |
| `Insufficient memory` | Lima VM hat zu wenig RAM — mindestens 4Gi frei benoetigt |

### App startet nicht

```bash
# Pod-Status im K8s pruefen
cf target -o dev -s test
kubectl get pods -n $(kubectl get cfspace -A -o jsonpath='{.items[0].status.namespace}')

# Pod-Logs direkt lesen
kubectl logs -n $(kubectl get cfspace -A -o jsonpath='{.items[0].status.namespace}') \
  -l korifi.cloudfoundry.org/app-guid --tail=50
```

**Haeufige Ursachen:**

| Problem | Loesung |
|---------|---------|
| `Connection refused` (DB) | PostgreSQL-Service ClusterIP pruefen, ggf. UPS aktualisieren |
| `OOMKilled` | Memory erhoehen: `cf scale demo -m 2G` |
| Port-Binding fehlgeschlagen | Spring Boot muss auf `$PORT` hoeren (Standard bei Paketo) |

### Route nicht erreichbar

```bash
# HTTPRoute pruefen
kubectl get httproute -A | grep demo

# Gateway-Status pruefen
kubectl get gateway korifi -n korifi-gateway
# PROGRAMMED muss True sein

# DNS pruefen
dig +short demo.app.cfapps.cool
# Muss 192.168.64.203 zurueckgeben (oder /etc/hosts pruefen)

# Envoy-Logs pruefen
kubectl logs -n projectcontour daemonset/envoy -c envoy --tail=20
```

### VCAP_SERVICES nicht vorhanden

```bash
# Service-Binding pruefen
cf services
# demo-pg muss unter "bound apps" die App "demo" listen

# Falls nicht gebunden:
cf bind-service demo demo-pg
cf restage demo
```

---

## 8. Aufraumen

```bash
# App loeschen
cf delete demo -r -f

# Service loeschen
cf delete-service demo-pg -f

# PostgreSQL aus K8s entfernen
kubectl delete deploy,svc,pvc,secret -n cf-services \
  -l app=demo-postgres --ignore-not-found
kubectl delete secret demo-pg-credentials -n cf-services --ignore-not-found

# Space/Org loeschen (optional)
cf delete-space test -f
cf delete-org dev -f
```
