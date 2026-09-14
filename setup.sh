#!/usr/bin/env bash
set -euo pipefail

BREW="/home/linuxbrew/.linuxbrew/bin/brew"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Variante wählen: "ts" (Standard, TypeScript) oder "java"
VARIANT="${1:-ts}"
case "$VARIANT" in
    ts)   DOCKERFILE="Dockerfile" ;;
    java) DOCKERFILE="Dockerfile.java" ;;
    *)    echo "Unbekannte Variante '$VARIANT' (erlaubt: ts, java)" >&2; exit 1 ;;
esac

echo "=== Exam Setup: Einmalige Initialisierung (Variante: $VARIANT) ==="

# 1. Caddy installieren
if command -v caddy &>/dev/null; then
    echo "[OK] Caddy ist bereits installiert: $(caddy version)"
else
    echo "[...] Installiere Caddy via Homebrew..."
    "$BREW" install caddy
    echo "[OK] Caddy installiert."
fi

# 2. cloudflared installieren
if command -v cloudflared &>/dev/null; then
    echo "[OK] cloudflared ist bereits installiert: $(cloudflared --version 2>&1 | head -1)"
else
    echo "[...] Installiere cloudflared via Homebrew..."
    "$BREW" install cloudflare/cloudflare/cloudflared
    echo "[OK] cloudflared installiert."
fi

# 3. Docker-Image bauen
echo "[...] Baue Docker-Image 'exam-code-server' aus $DOCKERFILE..."
docker build -f "$SCRIPT_DIR/$DOCKERFILE" -t exam-code-server "$SCRIPT_DIR"
echo "[OK] Docker-Image gebaut."

# 4. Systemd-User-Service für Caddy erstellen
SERVICE_DIR="$HOME/.config/systemd/user"
mkdir -p "$SERVICE_DIR"
cat > "$SERVICE_DIR/caddy-exam.service" <<EOF
[Unit]
Description=Caddy Exam Reverse Proxy
After=network.target

[Service]
Type=simple
ExecStart=$(command -v caddy) run --config $SCRIPT_DIR/Caddyfile --adapter caddyfile
ExecReload=$(command -v caddy) reload --config $SCRIPT_DIR/Caddyfile --adapter caddyfile
Restart=on-failure
WorkingDirectory=$SCRIPT_DIR

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
echo "[OK] Systemd-Service 'caddy-exam' erstellt (~/.config/systemd/user/caddy-exam.service)."

# 5. Verzeichnisse sicherstellen
mkdir -p "$SCRIPT_DIR/workspaces" "$SCRIPT_DIR/credentials"
echo "[OK] Verzeichnisse workspaces/ und credentials/ bereit."

echo ""
echo "=== Setup abgeschlossen ==="
echo ""
echo "Naechste Schritte:"
echo "  1. students.txt befuellen (eine ID pro Zeile)"
echo "  2. Pruefung starten: ./exam-start.sh"
echo "     -> Cloudflare Tunnel URL wird automatisch ausgegeben"
