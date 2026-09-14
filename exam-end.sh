#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_PIDS_FILE="/tmp/cloudflared-exam.pids"
LOCK_SERVICE_PID_FILE="/tmp/exam-lock-service.pid"   # legacy
AUTH_SERVICE_PID_FILE="/tmp/exam-auth-service.pid"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "=== Pruefung beenden ==="

read -r -p "Alle Exam-Container stoppen und Caddy/Tunnel beenden? [j/N] " CONFIRM
if [[ "${CONFIRM,,}" != "j" ]]; then
    echo "Abgebrochen."
    exit 0
fi

read -r -p "Workspaces jetzt sichern (exam-collect.sh ausfuehren)? [j/N] " DO_COLLECT
if [[ "${DO_COLLECT,,}" == "j" ]]; then
    "$SCRIPT_DIR/exam-collect.sh"
fi

# Exam-Container stoppen
echo "[...] Stoppe Exam-Container..."
CONTAINERS="$(docker ps -a --filter "name=exam-" --format "{{.Names}}" | grep "^exam-" || true)"
if [[ -z "$CONTAINERS" ]]; then
    echo "  (Keine Exam-Container gefunden)"
else
    while IFS= read -r CONTAINER; do
        docker rm -f "$CONTAINER" >/dev/null
        echo -e "  ${GREEN}[OK]${NC} $CONTAINER entfernt."
    done <<< "$CONTAINERS"
fi

# Per-Student-Netzwerke entfernen
NETWORKS="$(docker network ls --format "{{.Name}}" | grep "^exam-net-" || true)"
if [[ -n "$NETWORKS" ]]; then
    while IFS= read -r NET; do
        docker network rm "$NET" >/dev/null 2>&1 || true
        echo -e "  ${GREEN}[OK]${NC} Netzwerk $NET entfernt."
    done <<< "$NETWORKS"
fi

# Caddy stoppen
if systemctl --user is-active caddy-exam.service &>/dev/null; then
    systemctl --user stop caddy-exam.service
    echo -e "${GREEN}[OK]${NC} Caddy gestoppt."
else
    echo -e "${YELLOW}[INFO]${NC} Caddy lief nicht."
fi

# Alle cloudflared-Prozesse beenden
if [[ -f "$CF_PIDS_FILE" ]]; then
    while IFS= read -r PID; do
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID"
            echo -e "  ${GREEN}[OK]${NC} cloudflared PID $PID beendet."
        fi
    done < "$CF_PIDS_FILE"
    rm -f "$CF_PIDS_FILE"
else
    # Fallback: alle cloudflared-Prozesse killen
    pkill -f "cloudflared tunnel" 2>/dev/null && echo -e "${GREEN}[OK]${NC} cloudflared-Prozesse beendet." || echo -e "${YELLOW}[INFO]${NC} Keine cloudflared-Prozesse gefunden."
fi

# Auth-Service stoppen (aktuelles Setup)
if [[ -f "$AUTH_SERVICE_PID_FILE" ]]; then
    AUTH_PID="$(cat "$AUTH_SERVICE_PID_FILE")"
    if kill -0 "$AUTH_PID" 2>/dev/null; then
        kill "$AUTH_PID"
        echo -e "${GREEN}[OK]${NC} Auth-Service (PID $AUTH_PID) beendet."
    fi
    rm -f "$AUTH_SERVICE_PID_FILE"
fi

# Lock-Service stoppen (legacy, falls noch vom alten Setup aktiv)
if [[ -f "$LOCK_SERVICE_PID_FILE" ]]; then
    LOCK_PID="$(cat "$LOCK_SERVICE_PID_FILE")"
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        kill "$LOCK_PID"
        echo -e "${GREEN}[OK]${NC} Lock-Service (PID $LOCK_PID) beendet."
    fi
    rm -f "$LOCK_SERVICE_PID_FILE"
fi

echo ""
echo "=== Pruefung beendet ==="
echo "Credentials: $SCRIPT_DIR/credentials/"
echo "Workspaces:  $SCRIPT_DIR/workspaces/"
