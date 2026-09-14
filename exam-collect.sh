#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUDENTS_FILE="$SCRIPT_DIR/students.txt"
WORKSPACES_DIR="$SCRIPT_DIR/workspaces"
DATUM="$(date +%Y%m%d_%H%M%S)"
ZIP_FILE="$SCRIPT_DIR/submissions_${DATUM}.zip"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

echo "=== Abgaben sammeln ==="

# Studentenliste einlesen
mapfile -t STUDENTS < <(grep -v '^\s*#' "$STUDENTS_FILE" | grep -v '^\s*$')

if [[ ${#STUDENTS[@]} -eq 0 ]]; then
    echo -e "${RED}[FEHLER] Keine Studenten in students.txt gefunden.${NC}"
    exit 1
fi

COLLECTED=0
FAILED=0

for STUDENT_ID in "${STUDENTS[@]}"; do
    STUDENT_ID="$(echo "$STUDENT_ID" | tr -d '[:space:]')"
    CONTAINER_NAME="exam-${STUDENT_ID}"
    DEST="$WORKSPACES_DIR/${STUDENT_ID}"

    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "  ${RED}[FEHLER]${NC} Container $CONTAINER_NAME laeuft nicht – ueberspringe."
        ((FAILED++)) || true
        continue
    fi

    mkdir -p "$DEST"
    echo "[...] Kopiere Workspace von $CONTAINER_NAME..."
    docker cp "${CONTAINER_NAME}:/home/coder/project/." "$DEST/"
    echo -e "  ${GREEN}[OK]${NC} $STUDENT_ID → $DEST"
    ((COLLECTED++)) || true
done

if [[ $COLLECTED -eq 0 ]]; then
    echo -e "${RED}[FEHLER] Keine Workspaces gesammelt.${NC}"
    exit 1
fi

# ZIP erstellen
echo "[...] Erstelle ZIP-Archiv..."
zip -r "$ZIP_FILE" "$WORKSPACES_DIR/" -x "*.DS_Store" >/dev/null
echo -e "${GREEN}[OK] ZIP erstellt: $ZIP_FILE${NC}"
echo ""
echo "Gesammelt: $COLLECTED Studenten"
if [[ $FAILED -gt 0 ]]; then
    echo "Fehlgeschlagen: $FAILED Studenten (Container nicht aktiv)"
fi
echo ""
echo "Inhalt des ZIP:"
zip -sf "$ZIP_FILE" | head -50
