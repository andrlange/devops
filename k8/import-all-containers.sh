#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# K8s DevOps Stack — Alle Container Images in artifact-keeper importieren
# =============================================================================
# Importiert alle Images aus container-images.txt via skopeo in artifact-keeper.
#
# Zwei Modi:
#   --local    Direkt auf dem Server gegen localhost (schnell, kein TLS)
#   (default)  Remote gegen artifactory.cfapps.cool (via HTTPS)
#
# Verwendung:
#   ./import-all-containers.sh                          # Remote, Multi-Arch
#   ./import-all-containers.sh --local                  # Lokal auf Server
#   ./import-all-containers.sh --local --phase 1        # Lokal, nur Phase 1
#   ./import-all-containers.sh --arch-only arm64        # Nur ARM64
#   ./import-all-containers.sh --dry-run                # Nur anzeigen
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_LIST="${SCRIPT_DIR}/container-images.txt"

# --- Defaults ----------------------------------------------------------------

REGISTRY="artifactory.cfapps.cool"
TARGET_REPO="docker-local"
PHASE_FILTER=""
DRY_RUN=false
ARCH_ONLY=""
LOCAL_MODE=false
LOCAL_PORT="8100"
TLS_VERIFY=true

# --- Argumente parsen --------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)
            LOCAL_MODE=true
            REGISTRY="localhost:${LOCAL_PORT}"
            TLS_VERIFY=false
            shift
            ;;
        --local-port)
            LOCAL_PORT="$2"
            if [ "$LOCAL_MODE" = true ]; then
                REGISTRY="localhost:${LOCAL_PORT}"
            fi
            shift 2
            ;;
        --phase)
            PHASE_FILTER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --arch-only)
            ARCH_ONLY="$2"
            shift 2
            ;;
        -h|--help)
            echo "Verwendung: $0 [OPTIONEN]"
            echo ""
            echo "Optionen:"
            echo "  --local          Lokal auf dem Server ausfuehren (localhost:8100, kein TLS)"
            echo "  --local-port P   Lokaler Backend-Port (Default: 8100)"
            echo "  --phase N        Nur Images einer bestimmten Phase importieren (1-5)"
            echo "  --dry-run        Nur anzeigen, nicht importieren"
            echo "  --registry HOST  Ziel-Registry (Default: artifactory.cfapps.cool)"
            echo "  --arch-only ARCH Nur eine Architektur importieren (arm64, amd64)"
            echo "                   Default: Multi-Arch (arm64 + amd64)"
            echo ""
            echo "Beispiele:"
            echo "  $0 --local                   # Lokal auf dem Server, alle Images"
            echo "  $0 --local --phase 1         # Lokal, nur Phase 1"
            echo "  $0                           # Remote nach artifactory.cfapps.cool"
            echo "  $0 --arch-only arm64         # Nur ARM64"
            exit 0
            ;;
        *)
            echo "Unbekannte Option: $1" >&2
            exit 1
            ;;
    esac
done

# --- Voraussetzungen pruefen ------------------------------------------------

if ! command -v skopeo >/dev/null 2>&1; then
    echo "FEHLER: skopeo ist nicht installiert." >&2
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "Installation: brew install skopeo" >&2
    else
        echo "Installation: sudo apt install skopeo" >&2
    fi
    exit 1
fi

if [ ! -f "$IMAGE_LIST" ]; then
    echo "FEHLER: Image-Liste nicht gefunden: $IMAGE_LIST" >&2
    exit 1
fi

# --- Images parsen -----------------------------------------------------------

CURRENT_PHASE=""
IMAGES=()
PHASES=()

while IFS= read -r line; do
    if [[ "$line" =~ ^#\ ---\ Phase\ ([0-9]+) ]]; then
        CURRENT_PHASE="${BASH_REMATCH[1]}"
        continue
    fi
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "${line// /}" ]] && continue
    if [ -n "$PHASE_FILTER" ] && [ "$CURRENT_PHASE" != "$PHASE_FILTER" ]; then
        continue
    fi
    IMAGES+=("$line")
    PHASES+=("$CURRENT_PHASE")
done < "$IMAGE_LIST"

TOTAL=${#IMAGES[@]}

# --- Modus bestimmen ---------------------------------------------------------

if [ -n "$ARCH_ONLY" ]; then
    ARCH_MODE="single-arch (linux/${ARCH_ONLY})"
else
    ARCH_MODE="multi-arch (arm64 + amd64)"
fi

if [ "$LOCAL_MODE" = true ]; then
    CONN_MODE="lokal (localhost:${LOCAL_PORT}, kein TLS)"
    PROTO="http"
else
    CONN_MODE="remote (${REGISTRY}, HTTPS)"
    PROTO="https"
fi

# --- Zusammenfassung ---------------------------------------------------------

echo "=============================================="
echo "  K8s Stack — Container Import"
echo "=============================================="
echo ""
echo "  Ziel-Registry: ${PROTO}://${REGISTRY}"
echo "  Repository:    ${TARGET_REPO}"
echo "  Verbindung:    ${CONN_MODE}"
echo "  Architektur:   ${ARCH_MODE}"
echo "  Images gesamt: $TOTAL"
if [ -n "$PHASE_FILTER" ]; then
    echo "  Phase-Filter:  $PHASE_FILTER"
fi
echo ""

if [ "$TOTAL" -eq 0 ]; then
    echo "Keine Images zum Importieren gefunden."
    exit 0
fi

echo "  Images:"
LAST_PHASE=""
for i in "${!IMAGES[@]}"; do
    if [ "${PHASES[$i]}" != "$LAST_PHASE" ]; then
        echo ""
        echo "  Phase ${PHASES[$i]}:"
        LAST_PHASE="${PHASES[$i]}"
    fi
    echo "    ${IMAGES[$i]}"
done
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] Keine Images importiert."
    exit 0
fi

# --- Credentials abfragen ---------------------------------------------------

echo "  Anmeldung an ${REGISTRY}:"
echo ""
printf "  Benutzername: "
read -r AK_USERNAME
printf "  Passwort: "
read -rs AK_PASSWORD
echo ""
echo ""

if [ -z "$AK_USERNAME" ] || [ -z "$AK_PASSWORD" ]; then
    echo "FEHLER: Benutzername und Passwort erforderlich." >&2
    exit 1
fi

# --- Verbindungstest ---------------------------------------------------------

echo "  Teste Verbindung zu ${REGISTRY} ..."

LOGIN_FLAGS=(--username "${AK_USERNAME}" --password "${AK_PASSWORD}")
if [ "$TLS_VERIFY" = false ]; then
    LOGIN_FLAGS+=(--tls-verify=false)
fi

if ! skopeo login "${REGISTRY}" "${LOGIN_FLAGS[@]}" 2>/dev/null; then
    echo "FEHLER: Login fehlgeschlagen. Bitte Credentials pruefen." >&2
    if [ "$LOCAL_MODE" = true ]; then
        echo "Ist artifact-keeper auf Port ${LOCAL_PORT} erreichbar?" >&2
    fi
    exit 1
fi
echo "  Login erfolgreich."
echo ""

printf "Import starten? [J/n]: "
read -r CONFIRM
case "${CONFIRM:-j}" in
    j|J|ja|Ja|JA|"") ;;
    *) echo "Abgebrochen."; exit 0 ;;
esac

# --- Hilfsfunktionen --------------------------------------------------------

# Source-Referenz fuer skopeo normalisieren
normalize_source_ref() {
    local ref="$1"
    if echo "$ref" | grep -qE '^[a-z0-9.-]+\.[a-z]{2,}/'; then
        echo "$ref"; return
    fi
    if echo "$ref" | grep -qE '^[a-z0-9.-]+:[0-9]+/'; then
        echo "$ref"; return
    fi
    if ! echo "$ref" | grep -q '/'; then
        echo "docker.io/library/$ref"
    else
        echo "docker.io/$ref"
    fi
}

# Target-Name normalisieren (Registry-Prefix entfernen)
normalize_target_name() {
    local name="$1"
    name="${name#docker.io/library/}"
    name="${name#docker.io/}"
    name="${name#library/}"
    name="${name#ghcr.io/}"
    name="${name#quay.io/}"
    echo "$name"
}

# --- Retry-Konfiguration (lokal schneller, remote gedrosselt) ----------------

if [ "$LOCAL_MODE" = true ]; then
    MAX_RETRIES=3
    RETRY_DELAY=3
    INTER_ARCH_DELAY=1
    INTER_IMAGE_DELAY=1
else
    MAX_RETRIES=3
    RETRY_DELAY=10
    INTER_ARCH_DELAY=5
    INTER_IMAGE_DELAY=3
fi

# --- Import mit Retry --------------------------------------------------------

SUCCESS=0
FAILED=0
FAILED_IMAGES=()
IMPORTED_TARGETS=()

# skopeo copy mit TLS-Flag und Retry
skopeo_copy_with_retry() {
    local attempt=1
    local extra_flags=()
    if [ "$TLS_VERIFY" = false ]; then
        extra_flags+=(--dest-tls-verify=false)
    fi

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        if skopeo copy "${extra_flags[@]}" "$@" 2>&1; then
            return 0
        fi
        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            echo ""
            echo "  Versuch $attempt/$MAX_RETRIES fehlgeschlagen. Warte ${RETRY_DELAY}s ..."
            sleep "$RETRY_DELAY"
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# Import einer einzelnen Architektur
import_single_arch() {
    local source_ref="$1"
    local dest_ref="$2"
    local arch="$3"

    echo "  Kopiere linux/${arch} (max ${MAX_RETRIES} Versuche) ..."
    skopeo_copy_with_retry \
        --override-os linux --override-arch "$arch" \
        --dest-creds "${AK_USERNAME}:${AK_PASSWORD}" \
        "docker://${source_ref}" \
        "docker://${dest_ref}"
}

for i in "${!IMAGES[@]}"; do
    IMAGE="${IMAGES[$i]}"
    PHASE="${PHASES[$i]}"
    NUM=$((i + 1))

    SOURCE_REF=$(normalize_source_ref "$IMAGE")
    TARGET_NAME=$(normalize_target_name "$IMAGE")
    DEST_REF="${REGISTRY}/${TARGET_REPO}/${TARGET_NAME}"

    echo ""
    echo "=============================================="
    echo "  [$NUM/$TOTAL] Phase $PHASE"
    echo "  Source: ${SOURCE_REF}"
    echo "  Target: ${DEST_REF}"
    echo "  Modus:  ${CONN_MODE} / ${ARCH_MODE}"
    echo "=============================================="

    IMAGE_OK=false

    if [ -n "$ARCH_ONLY" ]; then
        # --- Single-Arch Modus ---
        if import_single_arch "$SOURCE_REF" "$DEST_REF" "$ARCH_ONLY"; then
            IMAGE_OK=true
        fi
    else
        # --- Multi-Arch Modus: arm64 + amd64 einzeln ---
        ARCH_SUCCESS=0
        for arch in arm64 amd64; do
            echo ""
            echo "  --- linux/${arch} ---"
            if import_single_arch "$SOURCE_REF" "${DEST_REF}-${arch}" "$arch"; then
                echo "  OK: linux/${arch}"
                ARCH_SUCCESS=$((ARCH_SUCCESS + 1))
            else
                echo "  WARNUNG: linux/${arch} fehlgeschlagen oder nicht verfuegbar."
            fi

            # Pause zwischen Architekturen
            if [ "$arch" = "arm64" ]; then
                sleep "$INTER_ARCH_DELAY"
            fi
        done

        if [ "$ARCH_SUCCESS" -gt 0 ]; then
            IMAGE_OK=true
            echo ""
            echo "  ${ARCH_SUCCESS}/2 Architekturen importiert."
        fi
    fi

    if [ "$IMAGE_OK" = true ]; then
        SUCCESS=$((SUCCESS + 1))
        IMPORTED_TARGETS+=("$TARGET_NAME")
        echo ""
        echo "  OK: ${TARGET_NAME}"
    else
        FAILED=$((FAILED + 1))
        FAILED_IMAGES+=("$IMAGE")
        echo ""
        echo "  FEHLER: Import komplett fehlgeschlagen fuer $IMAGE"
        echo ""
        printf "  Weiter mit naechstem Image? [J/n]: "
        read -r CONTINUE
        case "${CONTINUE:-j}" in
            j|J|ja|Ja|JA|"") ;;
            *) echo "Abgebrochen."; break ;;
        esac
    fi

    # Pause zwischen Images
    if [ "$i" -lt $((TOTAL - 1)) ]; then
        sleep "$INTER_IMAGE_DELAY"
    fi
done

# --- Ergebnis ----------------------------------------------------------------

echo ""
echo "=============================================="
echo "  Import abgeschlossen"
echo "=============================================="
echo ""
echo "  Registry:     ${PROTO}://${REGISTRY}"
echo "  Repository:   ${TARGET_REPO}"
echo "  Modus:        ${CONN_MODE} / ${ARCH_MODE}"
echo "  Erfolgreich:  $SUCCESS / $TOTAL"
if [ "$FAILED" -gt 0 ]; then
    echo "  Fehlgeschlagen: $FAILED"
    echo ""
    echo "  Fehlgeschlagene Images:"
    for img in "${FAILED_IMAGES[@]}"; do
        echo "    - $img"
    done
fi
echo ""

if [ ${#IMPORTED_TARGETS[@]} -gt 0 ]; then
    echo "=============================================="
    echo "  K8s Pull-Referenzen"
    echo "=============================================="
    echo ""
    echo "  K8s Pull-Registry: artifactory.cfapps.cool"
    echo "  (unabhaengig davon ob lokal oder remote importiert wurde)"
    echo ""
    echo "  Fuer Helm values.yaml / Manifeste:"
    echo ""
    for t in "${IMPORTED_TARGETS[@]}"; do
        IMAGE_BASE="${t%%:*}"
        IMAGE_TAG="${t#*:}"
        echo "    image:"
        echo "      repository: artifactory.cfapps.cool/${TARGET_REPO}/${IMAGE_BASE}"
        echo "      tag: \"${IMAGE_TAG}\""
        echo ""
    done
fi

echo "=============================================="
echo "  Naechste Schritte"
echo "=============================================="
echo ""
echo "  1. Pull-User in artifact-keeper anlegen (Read-Only auf ${TARGET_REPO})"
echo ""
echo "  2. K8s Pull-Secret erstellen:"
echo ""
echo "     kubectl create secret docker-registry artifact-keeper-pull \\"
echo "       --docker-server=https://artifactory.cfapps.cool \\"
echo "       --docker-username=<pull-user> \\"
echo "       --docker-password=<pull-password> \\"
echo "       -n <namespace>"
echo ""
echo "  3. Oder via OpenBao + ESO (empfohlen, siehe Implementierungsplan):"
echo ""
echo "     bao kv put secret/k8s/registry \\"
echo "       server=https://artifactory.cfapps.cool \\"
echo "       username=<pull-user> \\"
echo "       password=<pull-password>"
echo ""
