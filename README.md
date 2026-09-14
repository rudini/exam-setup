# Exam Code-Server Setup

Dieses System startet pro Student eine isolierte VS Code-Umgebung (code-server) im Browser. Alle Studenten teilen sich **eine zentrale URL** (Cloudflare-Tunnel) und melden sich mit einem **persönlichen Username + Passwort** an. Caddy übernimmt die Authentifizierung und leitet jeden Studenten an seinen eigenen Container weiter.

## Voraussetzungen

- **Docker** installiert und laufend
- **Homebrew** unter `/home/linuxbrew/.linuxbrew/bin/brew` vorhanden
- **systemd** mit User-Session (`loginctl enable-linger $USER` falls nötig)
- Internetverbindung (für Cloudflare-Tunnel)

---

## Installation (nach dem Klonen)

Dieses Repository enthält **keine echten Studentendaten** – `students.txt`, `credentials/` und `workspaces/` sind in `.gitignore` und müssen lokal angelegt werden.

```bash
git clone <repo-url> exam-setup
cd exam-setup

# Studentenliste aus Vorlage erstellen und befüllen
cp students.txt.example students.txt
$EDITOR students.txt

# .env aus Vorlage erstellen (SEB Config Key eintragen, falls verwendet)
cp .env.example .env
$EDITOR .env
```

Danach wie gewohnt mit `./setup.sh` fortfahren (siehe unten). `credentials/` und `workspaces/` werden von `setup.sh` bzw. `exam-start.sh` automatisch angelegt.

---

## Verzeichnisstruktur

```
exam-setup/
├── setup.sh                  # Einmalige Initialisierung (Standard: TypeScript)
├── setup_java.sh             # Einmalige Initialisierung, Java-Variante (Wrapper um `setup.sh java`)
├── exam-start.sh             # Pruefung starten
├── exam-collect.sh           # Abgaben einsammeln
├── exam-end.sh               # Pruefung beenden
├── lock-service.py           # Session-Lock (verhindert doppelten Login)
├── students.txt              # Studentenliste
├── Dockerfile                # Docker-Image-Definition (TypeScript)
├── Dockerfile.java           # Docker-Image-Definition (Java)
├── Caddyfile                 # Wird automatisch generiert
├── workspace-template/       # TypeScript-Startprojekt
│   ├── package.json
│   └── src/index.ts
├── workspace-template-java/  # Java-Startprojekt (Maven)
│   ├── pom.xml
│   └── src/main/java/Main.java
├── workspaces/               # Studentenworkspaces (live + Abgaben)
└── credentials/              # Zugangsdaten (Passwörter pro Student)
```

---

## Einmalige Initialisierung

Nur beim ersten Aufsetzen des Systems ausführen:

```bash
./setup.sh
```

Dieses Skript:
1. Installiert **Caddy** (Reverse Proxy) via Homebrew
2. Installiert **cloudflared** (Cloudflare Tunnel) via Homebrew
3. Baut das **Docker-Image** `exam-code-server`
4. Erstellt den **systemd-User-Service** `caddy-exam`
5. Legt die Verzeichnisse `workspaces/` und `credentials/` an

---

## Konfiguration vor der Pruefung

### 1. Studentenliste befüllen

`students.txt` editieren – eine ID pro Zeile im Format `nachname_vorname`:

```
# Kommentarzeilen und Leerzeilen werden ignoriert
mustermann_max
musterfrau_anna
schmidt_lena
```

### 2. Workspace-Template anpassen

Das Template unter `workspace-template/src/index.ts` enthält den Startcode, der jedem Studenten beim ersten Start in seinen Workspace kopiert wird. Die Aufgabenstellung kann hier eingetragen werden.

---

## Pruefung starten

```bash
./exam-start.sh
```

Das Skript führt folgende Schritte aus:

1. Pro Student Container-Port + 6-stelliges Passwort generieren, bcrypt-Hash via `caddy hash-password`
2. **Cloudflare-Tunnel** für die zentrale Caddy-Instanz starten und URL ermitteln (bis zu 30s)
3. Alte Container und Netzwerke entfernen
4. Pro Student: isoliertes **Docker-Netzwerk** + **Container** starten (`code-server --auth none`, nur an `127.0.0.1` gebunden)
5. Template in leere Workspaces kopieren
6. **Session-Lock-Service** starten (verhindert doppelten Login pro Username)
7. **Caddyfile** mit Basic-Auth + User→Port-Mapping generieren und Caddy (neu) starten
8. Zugangsdaten-Tabelle ausgeben

**Hinweis:** Die Browser-Lockdown-Schicht via Safe Exam Browser ist in diesem Setup **nicht** verdrahtet. Wer die zentrale URL und gültige Credentials hat, kommt mit jedem Browser rein. Die Auth-Schicht (Username + Passwort + Session-Lock auf Client-IP + Cloudflare-URL) bleibt aktiv.

Am Ende erscheint eine Tabelle:

```
==================================================================
  PRUEFUNGS-ZUGANGSDATEN (bitte ausdrucken / verteilen)
==================================================================
  Zentrale URL: https://xyz.trycloudflare.com/
------------------------------------------------------------------
Student-ID                Username                  Passwort
------------------------- ------------------------- ---------------
mustermann_max            mustermann_max            483921
==================================================================
```

Alle Studenten öffnen dieselbe URL, melden sich mit ihrem Username + Passwort an und werden von Caddy an ihren persönlichen Container weitergeleitet. Die Daten werden zusätzlich unter `credentials/<student_id>.txt` gespeichert (URL + Username + Passwort).

### Port-Belegung (intern)

| Schicht         | Ports         | Beschreibung                                          |
|-----------------|---------------|-------------------------------------------------------|
| Container       | 8100, 8101, … | code-server (`--auth none`), nur auf localhost        |
| Lock-Service    | 8099          | Session-Lock-Dienst, nur auf localhost                |
| Caddy           | 9000          | Zentraler Reverse Proxy (Basic-Auth + Lock + Routing) |
| Cloudflare      | HTTPS (443)   | Eine öffentliche Tunnel-URL                           |

---

## Während der Pruefung

### Session-Lock: Einmal-Login pro Username

Sobald sich ein Student erfolgreich einloggt, wird sein **Username an die Client-IP gebunden**. Versucht ein anderes Gerät mit denselben Zugangsdaten zuzugreifen, erhält es **HTTP 403** mit der Meldung „Zugriff verweigert".

**Funktionsweise:**
- Erster Request mit Basic-Auth für Username X → Lock wird auf die Client-IP gesetzt
- Weitere Requests von derselben IP → normales Arbeiten möglich
- Request mit denselben Credentials von einer anderen IP → HTTP 403
- Die echte Client-IP wird aus `CF-Connecting-IP` (Cloudflare) ermittelt

**Lock-Status aller Usernamen anzeigen:**
```bash
curl http://localhost:8099/status
```

**Lock eines Studenten zurücksetzen** (z.B. wenn Studierende:r das Gerät wechselt):
```bash
curl http://localhost:8099/unlock/<student_id>
```

**Log des Lock-Services:**
```bash
cat /tmp/exam-lock-service.log
```

---

### Zugangsdaten nachschlagen

```bash
cat credentials/<student_id>.txt
```

### Container-Status prüfen

```bash
docker ps --filter "name=exam-"
```

### Logs eines Containers anzeigen

```bash
docker logs exam-<student_id>
```

### Abgaben manuell einsammeln (ohne Pruefung zu beenden)

```bash
./exam-collect.sh
```

Kopiert den Workspace jedes laufenden Containers nach `workspaces/<student_id>/` und erstellt ein ZIP-Archiv `submissions_<datum>.zip`.

---

## Pruefung beenden

```bash
./exam-end.sh
```

Das Skript fragt interaktiv:
1. **Alle Container und Tunnel beenden?** → `j` bestätigen
2. **Workspaces jetzt sichern?** → `j` führt `exam-collect.sh` aus (empfohlen)

Dann werden gestoppt:
- Alle `exam-*`-Container
- Alle `exam-net-*`-Docker-Netzwerke
- Caddy (`caddy-exam.service`)
- Alle `cloudflared`-Prozesse
- Der Session-Lock-Service (`lock-service.py`)

Abgegebene Dateien bleiben in `workspaces/` und `credentials/` erhalten.

---

## Docker-Image neu bauen

Bei Änderungen am `Dockerfile` oder `workspace-template/`:

```bash
docker build -t exam-code-server .
```

---

## Java-Variante

Für eine Java-Prüfung liegt eine zweite Image-Definition bereit:

- **`Dockerfile.java`** – installiert OpenJDK 21 + Maven statt Node/TypeScript, sowie die Extension `redhat.java` (Language Support for Java, EPL-lizenziert, via open-vsx.org installiert **bevor** der Marketplace deaktiviert wird)
- **`workspace-template-java/`** – Maven-Projekt (`pom.xml` + `src/main/java/Main.java`, Standard-Layout) sowie `.vscode/tasks.json` mit Tasks „Java: Compile" und „Java: Run" (Standard-Build-Task, `Ctrl+Shift+B`, führt `mvn compile exec:java` aus)

Beim Image-Build wird `mvn compile exec:java` einmal gegen das Template ausgeführt, um alle Dependencies **und** Build-Plugins (Compiler, `exec-maven-plugin`) in den `.m2`-Cache des `coder`-Users vorzuladen – Studenten brauchen zur Laufzeit dadurch kein Internet für Maven. Wird `workspace-template-java/pom.xml` um zusätzliche Dependencies ergänzt (siehe „Bestehendes Projekt einbringen" weiter unten), müssen diese vor dem `docker build` einmal online auflösbar sein, damit sie mitgecacht werden.

Statt `./setup.sh` einfach `./setup_java.sh` ausführen (dünner Wrapper um `setup.sh java`) – Caddy/cloudflared/systemd-Setup ist identisch, nur das Docker-Image wird aus `Dockerfile.java` mit dem Template `workspace-template-java/` gebaut. Der Image-Name bleibt `exam-code-server`, daher sind keine weiteren Änderungen an `exam-start.sh` nötig:

```bash
./setup_java.sh
# äquivalent zu: ./setup.sh java
```

**Hinweis:** Ein grafischer Debugger (Breakpoints etc.) ist bewusst nicht eingerichtet – `vscjava.vscode-java-debug` ist eine Microsoft-Extension mit eingeschränkten Redistributions-Bedingungen und daher nicht standardmässig via open-vsx installierbar. Kompilieren/Ausführen funktioniert über die Tasks bzw. direkt im Terminal (`mvn compile exec:java`).

**Wichtig:** Beide Varianten bauen auf denselben Image-Namen `exam-code-server` – es kann pro Host immer nur **eine** Variante aktiv sein, nicht beide gleichzeitig. Zum Wechseln einfach das jeweils andere Setup-Skript ausführen (baut das Image neu und überschreibt den bisherigen Tag); laufende Container einer Prüfung sind davon unberührt, erst der nächste `exam-start.sh`-Lauf verwendet dann das neue Image.

---

## Bestehendes Projekt einbringen

Standardmässig starten Studenten mit dem minimalen Template (`workspace-template/` bzw. `workspace-template-java/`). Um stattdessen ein bestehendes Projekt als Startpunkt zu verwenden:

### Weg A – gemeinsames Startprojekt für alle Studenten

Das Template wird beim allerersten Containerstart automatisch in den Workspace kopiert (nur wenn der Workspace-Ordner noch leer ist – siehe `exam-start.sh`).

**TypeScript/JavaScript:**
1. Bestehendes Projekt nach `workspace-template/` kopieren (`package.json`, `src/`, etc. ersetzen)
2. `./setup.sh` neu ausführen – baut das Image neu, `npm install` läuft dabei automatisch gegen das neue `package.json` und wird mitgebacken (kein Internet zur Laufzeit nötig)
3. Falls `.vscode/launch.json` einen bestimmten Einstiegspunkt referenziert, Pfad anpassen

**Java:**
1. Bestehendes Maven-Projekt nach `workspace-template-java/` kopieren (`pom.xml`, `src/main/java/...`)
2. `./setup_java.sh` neu ausführen – baut das Image neu und lädt dabei automatisch alle in der `pom.xml` deklarierten Dependencies (und Build-Plugins) in den `.m2`-Cache vor
3. Falls die Hauptklasse nicht `Main` heisst, `<exec.mainClass>` in der `pom.xml` anpassen

### Weg B – individuell pro Student

Da das Template nur bei **leerem** Workspace kopiert wird, kann ein Projekt auch direkt in `workspaces/<student_id>/` abgelegt werden, **bevor** `exam-start.sh` läuft – der automatische Kopiermechanismus greift dann gar nicht, und der Container mountet das Projekt direkt. Damit lassen sich auch unterschiedliche Startzustände pro Student verteilen.

---

## Sicherheitsmerkmale

| Feature | Beschreibung |
|--------|-------------|
| Isolierte Netzwerke | Jeder Student hat ein eigenes Docker-Netzwerk – kein Container-zu-Container-Zugriff |
| Zentrale Auth | Caddy `basic_auth` mit bcrypt-Hashes; code-server selbst läuft ohne Auth, ist aber nur via `127.0.0.1` und damit nur über Caddy erreichbar |
| Zufällige Passwörter | 6-stellige Passwörter (`shuf 100000-999999`), gehasht mit `caddy hash-password` |
| Trusted Origins | code-server akzeptiert nur Verbindungen von der zentralen Cloudflare-URL |
| Session-Lock | Nach dem ersten Request wird der Username an die Client-IP gebunden – weitere Login-Versuche von anderen IPs werden mit HTTP 403 abgewiesen |
| Marketplace deaktiviert | Extensions-Marketplace und open-vsx.org sind im Image vollständig gesperrt |
| File-Downloads gesperrt | `--disable-file-downloads` verhindert das Herunterladen von Dateien aus code-server |
| Ressourcenlimits | 1 GB RAM, 1 CPU pro Container |

---

## Typischer Ablauf (Checkliste)

```
[ ] setup.sh einmalig ausführen
[ ] students.txt mit aktuellen Student-IDs befüllen
[ ] Aufgabe in workspace-template/src/index.ts eintragen
[ ] Docker-Image neu bauen falls Template geändert wurde
[ ] exam-start.sh ausführen
[ ] Zugangsdaten ausdrucken und an Studenten verteilen
[ ] Nach der Pruefung: exam-end.sh ausführen (inkl. Sicherung)
[ ] submissions_<datum>.zip zur Bewertung verwenden
```

---

## Fehlerbehebung

**Tunnel-URL nicht ermittelt**
Cloudflare-Log prüfen: `cat /tmp/cloudflared-exam.log`

**Container startet nicht**
Image vorhanden? `docker images | grep exam-code-server` – ggf. neu bauen.

**Caddy-Service schlägt fehl**
Log prüfen: `journalctl --user -u caddy-exam.service -n 50`

**Student kommt nach Geräte-/Netzwerkwechsel nicht mehr rein**
Der Session-Lock ist auf die ursprüngliche IP gebunden. Lock für den Username zurücksetzen:
```bash
curl http://localhost:8099/unlock/<student_id>
```

**Lock-Service startet nicht**
Prüfen ob Port 8099 bereits belegt ist: `ss -tlnp | grep 8099`
Log einsehen: `cat /tmp/exam-lock-service.log`
