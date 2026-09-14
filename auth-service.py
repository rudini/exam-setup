#!/usr/bin/env python3
"""
Exam Auth Service — Form-basierter Login + Session-Management + IP-Lock.

Ersetzt Caddy basic_auth und lock-service.py.

Caddy-Konfiguration:
  handle /login* { reverse_proxy localhost:8098 }
  handle {
    forward_auth localhost:8098 { uri /auth; copy_headers X-Backend-Port }
    reverse_proxy 127.0.0.1:{http.request.header.X-Backend-Port}
  }

Endpunkte:
  GET  /login              → Login-Formular
  POST /login              → Credentials prüfen, Session-Cookie setzen, → /
  GET  /auth               → Forward-auth-Check (200+X-Backend-Port | 302 /login | 403)
  GET  /unlock/<username>  → IP-Lock zurücksetzen
  GET  /status             → Aktive Locks/Sessions
"""

import os
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

AUTH_SERVICE_PORT = 8098
COOKIE_NAME = "exam_session"

credentials: dict[str, str] = {}    # username → password
port_map: dict[str, int] = {}        # username → backend port
sessions: dict[str, tuple[str, str]] = {}  # token → (username, client_ip)
locks: dict[str, str] = {}           # username → client_ip
mutex = threading.Lock()

LOGIN_HTML = """\
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Prüfungs-Login</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:sans-serif;background:#f0f2f5;display:flex;
         align-items:center;justify-content:center;min-height:100vh}
    .card{background:#fff;border-radius:8px;padding:2rem;
          box-shadow:0 2px 16px rgba(0,0,0,.12);width:100%;max-width:360px}
    h1{font-size:1.4rem;margin-bottom:1.5rem;color:#111}
    label{display:block;margin-bottom:.3rem;font-size:.85rem;color:#555}
    input{width:100%;padding:.6rem .75rem;border:1px solid #ccc;border-radius:4px;
          font-size:1rem;margin-bottom:1rem}
    input:focus{outline:2px solid #2563eb;border-color:#2563eb}
    button{width:100%;padding:.7rem;background:#2563eb;color:#fff;border:none;
           border-radius:4px;font-size:1rem;cursor:pointer;font-weight:600}
    button:hover{background:#1d4ed8}
    .error{color:#dc2626;font-size:.9rem;margin-bottom:1rem;
           background:#fef2f2;border:1px solid #fecaca;border-radius:4px;padding:.5rem .75rem}
  </style>
</head>
<body>
  <div class="card">
    <h1>Prüfungs-Login</h1>
    {error}
    <form method="post" action="/login">
      <label for="u">Benutzername</label>
      <input id="u" name="username" type="text" autocomplete="username" autofocus required>
      <label for="p">Passwort</label>
      <input id="p" name="password" type="password" autocomplete="current-password" required>
      <button type="submit">Anmelden</button>
    </form>
  </div>
</body>
</html>
"""

ACCESS_DENIED_HTML = """\
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <title>Zugriff verweigert</title>
  <style>body{font-family:sans-serif;padding:2rem}</style>
</head>
<body>
  <h2>Zugriff verweigert</h2>
  <p>Dieser Prüfungs-Account wird bereits von einem anderen Gerät verwendet.</p>
  <p>Falls du der/die richtige Studierende bist, wende dich an die Aufsicht.</p>
</body>
</html>
"""


def load_credentials(creds_dir: str) -> None:
    global credentials
    creds = {}
    try:
        for fname in os.listdir(creds_dir):
            if not fname.endswith(".txt"):
                continue
            username = fname[:-4]
            with open(os.path.join(creds_dir, fname)) as f:
                for line in f:
                    if line.startswith("Passwort:"):
                        creds[username] = line.split(":", 1)[1].strip()
                        break
        credentials = creds
        print(f"[Auth] {len(credentials)} Credentials geladen.", flush=True)
    except Exception as exc:
        print(f"[Auth] Fehler beim Laden der Credentials: {exc}", flush=True)


def load_port_map(map_file: str) -> None:
    global port_map
    pm = {}
    try:
        with open(map_file) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) == 2:
                    pm[parts[0]] = int(parts[1])
        port_map = pm
        print(f"[Auth] {len(port_map)} Port-Mappings geladen.", flush=True)
    except Exception as exc:
        print(f"[Auth] Fehler beim Laden der Port-Map: {exc}", flush=True)


def client_ip(handler) -> str:
    for hdr in ("CF-Connecting-IP", "X-Forwarded-For", "X-Real-IP"):
        val = handler.headers.get(hdr, "").strip()
        if val:
            return val.split(",")[0].strip()
    return handler.client_address[0]


def get_cookie(handler, name: str) -> str:
    for part in handler.headers.get("Cookie", "").split(";"):
        part = part.strip()
        if part.startswith(name + "="):
            return part[len(name) + 1:]
    return ""


class AuthHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        parts = path.lstrip("/").split("/")

        if path in ("/login", "/login/"):
            self._serve_login()
        elif path == "/auth":
            self._handle_auth()
        elif len(parts) == 2 and parts[0] == "unlock":
            self._handle_unlock(parts[1])
        elif path == "/status":
            self._handle_status()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if path == "/login":
            self._handle_login_post()
        else:
            self.send_response(404)
            self.end_headers()

    # ── Login form ────────────────────────────────────────────────────────────

    def _serve_login(self, error: str = "") -> None:
        err_html = f'<p class="error">{error}</p>' if error else ""
        body = LOGIN_HTML.replace("{error}", err_html).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle_login_post(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        params = parse_qs(raw)
        username = params.get("username", [""])[0].strip()
        password = params.get("password", [""])[0]

        if not username or not password:
            self._serve_login("Bitte Benutzername und Passwort eingeben.")
            return

        if credentials.get(username) != password:
            print(f"[AUTH] Fehlgeschlagener Login: {username}", flush=True)
            self._serve_login("Ungültiger Benutzername oder Passwort.")
            return

        ip = client_ip(self)
        token = secrets.token_hex(32)

        with mutex:
            if username in locks and locks[username] != ip:
                print(f"[BLOCK] {username}: Lock={locks[username]}, Versuch={ip}", flush=True)
                self._send_html(403, ACCESS_DENIED_HTML)
                return
            sessions[token] = (username, ip)
            if username not in locks:
                locks[username] = ip
                print(f"[LOCK] {username} gesperrt fuer IP {ip}", flush=True)

        self.send_response(302)
        self.send_header("Location", "/")
        self.send_header(
            "Set-Cookie",
            f"{COOKIE_NAME}={token}; Path=/; HttpOnly; SameSite=Lax; Secure",
        )
        self.end_headers()

    # ── Forward-auth check (called by Caddy for every request except /login) ──

    def _handle_auth(self) -> None:
        token = get_cookie(self, COOKIE_NAME)
        ip = client_ip(self)

        with mutex:
            if token not in sessions:
                self.send_response(302)
                self.send_header("Location", "/login")
                self.end_headers()
                return

            username, _ = sessions[token]

            if username in locks and locks[username] != ip:
                print(f"[BLOCK] {username}: Lock={locks[username]}, Versuch={ip}", flush=True)
                self._send_html(403, ACCESS_DENIED_HTML)
                return

            backend_port = port_map.get(username, "")

        if not backend_port:
            print(f"[AUTH] Kein Port fuer {username}", flush=True)
            self._send_text(503, "Kein Backend-Port konfiguriert.")
            return

        self.send_response(200)
        self.send_header("X-Backend-Port", str(backend_port))
        self.end_headers()

    # ── Admin endpoints ───────────────────────────────────────────────────────

    def _handle_unlock(self, username: str) -> None:
        with mutex:
            was_locked = username in locks
            locks.pop(username, None)
            to_remove = [t for t, (u, _) in sessions.items() if u == username]
            for t in to_remove:
                del sessions[t]
        msg = f"{username} entsperrt." if was_locked else f"{username} war nicht gesperrt."
        print(f"[UNLOCK] {msg}", flush=True)
        self._send_text(200, msg)

    def _handle_status(self) -> None:
        with mutex:
            sess_count = {u: 0 for u in locks}
            for u, _ in sessions.values():
                sess_count[u] = sess_count.get(u, 0) + 1
            lines = [
                f"{u}: {ip}  ({sess_count.get(u, 0)} session(s))"
                for u, ip in sorted(locks.items())
            ]
        self._send_text(200, "\n".join(lines) if lines else "Keine aktiven Locks.")

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _send_html(self, status: int, html: str) -> None:
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, status: int, text: str) -> None:
        body = (text + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else AUTH_SERVICE_PORT
    creds_dir = sys.argv[2] if len(sys.argv) > 2 else "credentials"
    map_file = sys.argv[3] if len(sys.argv) > 3 else "/tmp/exam-port-map.txt"
    load_credentials(creds_dir)
    load_port_map(map_file)
    server = HTTPServer(("127.0.0.1", port), AuthHandler)
    print(f"[Auth Service] Lauscht auf 127.0.0.1:{port}", flush=True)
    server.serve_forever()
