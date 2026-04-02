#!/usr/bin/env bash
set -euo pipefail

APP_NAME="kappman"
SERVICE_NAME="kappman-db"
SERVICE_TYPE="postgresql"
SERVICE_PLAN="small"

echo "=== kappman CF Deployment ==="

# Check CF CLI login
if ! cf target &>/dev/null; then
    echo "ERROR: Not logged in to CF. Run 'cf login' first."
    exit 1
fi

echo "Target:"
cf target

# Create database service if not exists
if ! cf service "$SERVICE_NAME" &>/dev/null; then
    echo ""
    echo "Creating service $SERVICE_NAME ($SERVICE_TYPE / $SERVICE_PLAN)..."
    cf create-service "$SERVICE_TYPE" "$SERVICE_PLAN" "$SERVICE_NAME"

    echo "Waiting for service to be ready..."
    while true; do
        STATUS=$(cf service "$SERVICE_NAME" | grep "status:" | awk '{print $NF}')
        if [[ "$STATUS" == "succeeded" ]]; then
            echo "Service $SERVICE_NAME is ready."
            break
        elif [[ "$STATUS" == "failed" ]]; then
            echo "ERROR: Service creation failed!"
            exit 1
        fi
        echo "  status: $STATUS — waiting..."
        sleep 5
    done
else
    echo "Service $SERVICE_NAME already exists."
fi

# Build JAR if needed
JAR_FILE="build/libs/${APP_NAME}-0.0.1-SNAPSHOT.jar"
if [[ ! -f "$JAR_FILE" ]] || [[ -n "$(find src -newer "$JAR_FILE" 2>/dev/null)" ]]; then
    echo ""
    echo "Building JAR..."
    ./gradlew bootJar
else
    echo "JAR is up to date."
fi

# Push
echo ""
echo "Pushing $APP_NAME..."
cf push

# Set CF_PASSWORD
echo ""
echo "=== Post-deployment: Set CF_PASSWORD ==="
if [[ -n "${CF_PASSWORD:-}" ]]; then
    echo "Setting CF_PASSWORD from environment..."
    cf set-env "$APP_NAME" CF_PASSWORD "$CF_PASSWORD"
    echo "Restarting $APP_NAME..."
    cf restart "$APP_NAME"
else
    echo "CF_PASSWORD not set in environment."
    echo "Run manually:"
    echo "  cf set-env $APP_NAME CF_PASSWORD <your-token>"
    echo "  cf restart $APP_NAME"
fi

echo ""
echo "=== Deployment complete ==="
echo "URL: https://${APP_NAME}.app.cfapps.cool"
echo "Default login: admin / change_me"
