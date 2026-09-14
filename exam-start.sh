#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUDENTS_FILE="$SCRIPT_DIR/students.txt"
CADDYFILE="$SCRIPT_DIR/Caddyfile"
CREDENTIALS_DIR="$SCRIPT_DIR/credentials"
CF_PIDS_FILE="/tmp/cloudflared-exam.pids"

CONTAINER_BASE_PORT=8100
CADDY_PUBLIC_PORT=9000
AUTH_SERVICE_PORT=8098
AUTH_SERVICE_PID_FILE="/tmp/exam-auth-service.pid"
PORT_MAP_FILE="/tmp/exam-port-map.txt"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

echo "=== Pruefung starten ==="

mapfile -t STUDENTS < <(grep -v '^\s*#' "$STUDENTS_FILE" | grep -v '^\s*$')

if [[ ${#STUDENTS[@]} -eq 0 ]]; then
    echo -e "${RED}[FEHLER] students.txt ist leer.${NC}"
    exit 1
fi

echo "Gefundene Studenten: ${#STUDENTS[@]}"

# Alte cloudflared-Prozesse beenden
if [[ -f "$CF_PIDS_FILE" ]]; then
    while IFS= read -r OLD_PID; do
        kill "$OLD_PID" 2>/dev/null || true
    done < "$CF_PIDS_FILE"
    rm -f "$CF_PIDS_FILE"
fi

declare -A PASSWORDS
declare -A CONTAINER_PORTS

# ── Phase 1: Ports zuweisen + Passwörter laden/generieren ────────────────────
# Wenn credentials/<student_id>.txt bereits ein Passwort enthält, wird es
# wiederverwendet (stabile Credentials ueber Restarts). Sonst neu generieren.
mkdir -p "$CREDENTIALS_DIR"
echo "[...] Lade/Generiere Passwoerter..."
NEW_COUNT=0
REUSED_COUNT=0
IDX=0
for STUDENT_ID in "${STUDENTS[@]}"; do
    STUDENT_ID="$(echo "$STUDENT_ID" | tr -d '[:space:]')"
    CONTAINER_PORTS["$STUDENT_ID"]=$((CONTAINER_BASE_PORT + IDX))

    CRED_FILE="$CREDENTIALS_DIR/${STUDENT_ID}.txt"
    PW=""
    if [[ -f "$CRED_FILE" ]]; then
        PW="$(awk '/^Passwort:/ {print $2; exit}' "$CRED_FILE")"
    fi
    if [[ -z "$PW" ]]; then
        PW="$(shuf -i 100000-999999 -n 1)"
        NEW_COUNT=$((NEW_COUNT + 1))
    else
        REUSED_COUNT=$((REUSED_COUNT + 1))
    fi

    PASSWORDS["$STUDENT_ID"]="$PW"
    IDX=$((IDX + 1))
done
echo "  ${REUSED_COUNT} wiederverwendet, ${NEW_COUNT} neu generiert."

# ── Phase 2: ein Cloudflared-Tunnel für die zentrale Caddy-Instanz ───────────
echo "[...] Starte Cloudflare Tunnel (warte auf URL)..."
CF_LOG="/tmp/cloudflared-exam.log"
rm -f "$CF_LOG"
cloudflared tunnel --url "http://localhost:${CADDY_PUBLIC_PORT}" --no-autoupdate 2>"$CF_LOG" &
echo "$!" >> "$CF_PIDS_FILE"

CF_URL=""
for i in $(seq 1 30); do
    CF_URL="$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1 || true)"
    [[ -n "$CF_URL" ]] && break
    sleep 1
done

if [[ -z "$CF_URL" ]]; then
    echo -e "${RED}[FEHLER] Tunnel-URL nicht ermittelt. Log: $CF_LOG${NC}"
    exit 1
fi
echo -e "  ${GREEN}[OK]${NC} Tunnel: $CF_URL"

# ── Phase 3: Alte Container + Netzwerke entfernen ────────────────────────────
for STUDENT_ID in "${STUDENTS[@]}"; do
    STUDENT_ID="$(echo "$STUDENT_ID" | tr -d '[:space:]')"
    CONTAINER_NAME="exam-${STUDENT_ID}"
    NET_NAME="exam-net-${STUDENT_ID}"

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker rm -f "$CONTAINER_NAME" >/dev/null
    fi
    if docker network ls --format '{{.Name}}' | grep -q "^${NET_NAME}$"; then
        docker network rm "$NET_NAME" >/dev/null
    fi
done

# ── Phase 4: Pro-Student-Netzwerk + Container starten ────────────────────────
echo "[...] Starte Container..."
NET_IDX=0
for STUDENT_ID in "${STUDENTS[@]}"; do
    STUDENT_ID="$(echo "$STUDENT_ID" | tr -d '[:space:]')"
    CONTAINER_NAME="exam-${STUDENT_ID}"
    NET_NAME="exam-net-${STUDENT_ID}"
    WORKSPACE="$SCRIPT_DIR/workspaces/${STUDENT_ID}"
    C_PORT="${CONTAINER_PORTS[$STUDENT_ID]}"

    mkdir -p "$WORKSPACE"

    # Eigenes Netzwerk pro Student: kein Container-zu-Container-Zugriff möglich.
    # Festes /28-Subnetz statt Docker-Auto-Zuteilung: sonst verbraucht jedes
    # Netzwerk einen der nur 31 "predefined address pool"-Slots des Hosts,
    # die sich Rakazo-Bot-Screens und Exam-Container sonst streitig machen.
    SUBNET="10.90.$((NET_IDX / 16)).$(((NET_IDX % 16) * 16))/28"
    docker network create --subnet "$SUBNET" "$NET_NAME" >/dev/null
    NET_IDX=$((NET_IDX + 1))

    # Auth wird komplett von Caddy uebernommen → code-server laeuft mit
    # --auth none. Container ist nur ueber 127.0.0.1 erreichbar, daher sicher.
    # Trusted-Origin: alle Container teilen die zentrale Cloudflare-URL.
    docker run -d \
        --name "$CONTAINER_NAME" \
        --network "$NET_NAME" \
        --memory 1g \
        --cpus 1.0 \
        -p "127.0.0.1:${C_PORT}:8080" \
        -v "${WORKSPACE}:/home/coder/project" \
        -e CS_DISABLE_GETTING_STARTED_OVERRIDE=1 \
        -e SERVICE_URL="http://localhost:1/disabled" \
        -e ITEM_URL="http://localhost:1/disabled" \
        exam-code-server \
        --bind-addr 0.0.0.0:8080 \
        --auth none \
        --disable-telemetry \
        --disable-file-downloads \
        --disable-workspace-trust \
        --trusted-origins "${CF_URL}" \
        /home/coder/project \
        >/dev/null

    echo -e "  ${GREEN}[OK]${NC} $CONTAINER_NAME (Netzwerk: $NET_NAME, Port: $C_PORT)"

    # Template in leeren Workspace kopieren (nur wenn noch kein package.json vorhanden)
    if [[ ! -f "${WORKSPACE}/package.json" ]]; then
        docker exec "$CONTAINER_NAME" cp -r /opt/workspace-template/. /home/coder/project/
        echo -e "  ${GREEN}[OK]${NC} Template kopiert → $STUDENT_ID"
    fi
done

# Zugangsdaten-Dateien schreiben (mit URL + Username + Passwort)
for STUDENT_ID in "${STUDENTS[@]}"; do
    STUDENT_ID="$(echo "$STUDENT_ID" | tr -d '[:space:]')"
    CRED_FILE="$CREDENTIALS_DIR/${STUDENT_ID}.txt"
    {
        echo "URL:      ${CF_URL}/"
        echo "Username: ${STUDENT_ID}"
        echo "Passwort: ${PASSWORDS[$STUDENT_ID]}"
    } > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
done

# ── Phase 5: Port-Map schreiben + Auth-Service starten ───────────────────────
# Port-Map für auth-service.py
{
    for STUDENT_ID in "${STUDENTS[@]}"; do
        STUDENT_ID="$(echo "$STUDENT_ID" | tr -d '[:space:]')"
        echo "${STUDENT_ID} ${CONTAINER_PORTS[$STUDENT_ID]}"
    done
} > "$PORT_MAP_FILE"

if [[ -f "$AUTH_SERVICE_PID_FILE" ]]; then
    OLD_PID="$(cat "$AUTH_SERVICE_PID_FILE")"
    kill "$OLD_PID" 2>/dev/null || true
    rm -f "$AUTH_SERVICE_PID_FILE"
fi
python3 "$SCRIPT_DIR/auth-service.py" "$AUTH_SERVICE_PORT" "$CREDENTIALS_DIR" "$PORT_MAP_FILE" \
    >> "/tmp/exam-auth-service.log" 2>&1 &
echo "$!" > "$AUTH_SERVICE_PID_FILE"
echo "[OK] Auth-Service gestartet (PID $(cat "$AUTH_SERVICE_PID_FILE"), Port $AUTH_SERVICE_PORT)."
echo "     → Status:    curl http://localhost:${AUTH_SERVICE_PORT}/status"
echo "     → Entsperren: curl http://localhost:${AUTH_SERVICE_PORT}/unlock/<student_id>"

# ── Phase 6: Caddyfile generieren + Caddy starten ────────────────────────────
{
    echo ":${CADDY_PUBLIC_PORT} {"
    echo "  # Cross-Origin-Isolation: ermöglicht navigator.clipboard in SEB"
    echo "  header {"
    echo "    Cross-Origin-Opener-Policy \"same-origin\""
    echo "    Cross-Origin-Embedder-Policy \"require-corp\""
    echo "  }"
    echo "  # Login-Seite erfordert keine Session (kein auth-check)"
    echo "  handle /login* {"
    echo "    reverse_proxy localhost:${AUTH_SERVICE_PORT}"
    echo "  }"
    echo "  handle {"
    echo "    forward_auth localhost:${AUTH_SERVICE_PORT} {"
    echo "      uri /auth"
    echo "      copy_headers X-Backend-Port"
    echo "    }"
    echo "    reverse_proxy 127.0.0.1:{http.request.header.X-Backend-Port}"
    echo "  }"
    echo "}"
} > "$CADDYFILE.tmp"
mv "$CADDYFILE.tmp" "$CADDYFILE"
echo "[OK] Caddyfile generiert."

if systemctl --user is-active caddy-exam.service &>/dev/null; then
    systemctl --user reload caddy-exam.service 2>/dev/null || systemctl --user restart caddy-exam.service
    echo "[OK] Caddy neu geladen."
else
    systemctl --user start caddy-exam.service
    echo "[OK] Caddy gestartet."
fi

# ── Zugangsdaten ausgeben ─────────────────────────────────────────────────────
echo ""
echo "=================================================================="
echo "  PRUEFUNGS-ZUGANGSDATEN (bitte ausdrucken / verteilen)"
echo "=================================================================="
echo "  Zentrale URL: ${CF_URL}/"
echo "------------------------------------------------------------------"
printf "%-25s %-25s %-15s\n" "Student-ID" "Username" "Passwort"
printf "%-25s %-25s %-15s\n" "-------------------------" "-------------------------" "---------------"
for STUDENT_ID in "${STUDENTS[@]}"; do
    STUDENT_ID="$(echo "$STUDENT_ID" | tr -d '[:space:]')"
    printf "%-25s %-25s %-15s\n" \
        "$STUDENT_ID" \
        "$STUDENT_ID" \
        "${PASSWORDS[$STUDENT_ID]}"
done
echo "=================================================================="
echo ""
