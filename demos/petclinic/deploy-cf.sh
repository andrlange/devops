#!/usr/bin/env bash
set -euo pipefail

APP_NAME="petclinic"
SERVICE_NAME="petclinic-db"
SERVICE_TYPE="postgresql"
SERVICE_PLAN="small"
JAR_PATH="build/libs/petclinic-0.0.1-SNAPSHOT.jar"

get_service_status() {
    cf services 2>/dev/null | grep "^${SERVICE_NAME} " | awk '{print $5, $6}' || echo ""
}

echo "=== Petclinic CF Deployment ==="
echo ""

# Check CF CLI is logged in and targeting an org/space
if ! cf target &>/dev/null; then
    echo "ERROR: Not logged in to CF. Run 'cf login' first."
    exit 1
fi

CURRENT_ORG=$(cf target | grep "org:" | awk '{print $2}')
CURRENT_SPACE=$(cf target | grep "space:" | awk '{print $2}')

if [ -z "$CURRENT_ORG" ] || [ -z "$CURRENT_SPACE" ]; then
    echo "ERROR: No org/space targeted. Run 'cf target -o <org> -s <space>' first."
    exit 1
fi

echo "Deploying to: org=$CURRENT_ORG space=$CURRENT_SPACE"
echo ""

# Build JAR if missing
if [ ! -f "$JAR_PATH" ]; then
    echo "Building JAR..."
    ./gradlew bootJar --no-daemon
    echo ""
fi

# Check if PostgreSQL service exists
echo "Checking for PostgreSQL service '$SERVICE_NAME'..."
STATUS=$(get_service_status)

if [ -z "$STATUS" ]; then
    echo "Service '$SERVICE_NAME' not found. Creating..."
    cf create-service "$SERVICE_TYPE" "$SERVICE_PLAN" "$SERVICE_NAME"
    sleep 5
    STATUS=$(get_service_status)
fi

echo "Service status: $STATUS"

# Wait for service to be ready
while ! echo "$STATUS" | grep -q "succeeded"; do
    if echo "$STATUS" | grep -q "failed"; then
        echo "ERROR: Service provisioning failed!"
        exit 1
    fi
    echo "  Waiting... ($STATUS)"
    sleep 10
    STATUS=$(get_service_status)
done
echo "Service '$SERVICE_NAME' is ready."

echo ""
echo "Deploying $APP_NAME..."
cf push
echo ""
echo "=== Deployment complete ==="
cf apps
