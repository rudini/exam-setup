#!/usr/bin/env python3
"""
Exam Lock Service – verhindert, dass mehr als eine Person pro Username eingeloggt ist.

Caddy ruft pro Request /check/<username> via forward_auth auf. Der Service
merkt sich die Client-IP, die als erstes mit gueltiger Basic-Auth fuer einen
Username durchgekommen ist, und blockiert weitere Requests von anderen IPs.

Logik:
  - Erster Request fuer Username X (von IP A) → Lock setzen, durchlassen
  - Weiterer Request fuer X von IP A → durchlassen
  - Request fuer X von einer anderen IP → 403

Admin-Endpunkte (nur localhost):
  GET /unlock/<username>   → Sperre fuer einen Username zuruecksetzen
  GET /status              → Zeigt alle aktiven Sperren
"""

import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

LOCK_SERVICE_PORT = 8099
locks: dict[str, str] = {}   # username -> client_ip
lock_mutex = threading.Lock()


class LockHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        pass  # Standard-Logging unterdrücken

    def do_GET(self):
        path = self.path.split("?", 1)[0].strip("/")
        parts = path.split("/")

        if len(parts) == 2 and parts[0] == "check":
            self._handle_check(parts[1])
        elif len(parts) == 2 and parts[0] == "unlock":
            self._handle_unlock(parts[1])
        elif path == "status":
            self._handle_status()
        else:
            self.send_response(404)
            self.end_headers()

    def _client_ip(self) -> str:
        # Cloudflare setzt die echte Client-IP hier
        cf_ip = self.headers.get("CF-Connecting-IP", "").strip()
        if cf_ip:
            return cf_ip
        # Fallback: erster Wert aus X-Forwarded-For
        xff = self.headers.get("X-Forwarded-For", "").strip()
        if xff:
            return xff.split(",")[0].strip()
        xri = self.headers.get("X-Real-IP", "").strip()
        if xri:
            return xri
        return self.client_address[0]

    def _handle_check(self, username: str):
        if not username:
            self._ok()
            return

        ip = self._client_ip()

        with lock_mutex:
            if username not in locks:
                locks[username] = ip
                print(f"[LOCK] {username} gesperrt fuer IP {ip}", flush=True)
                self._ok()
            elif locks[username] == ip:
                self._ok()
            else:
                print(f"[BLOCK] {username}: Lock={locks[username]}, Versuch={ip}", flush=True)
                self.send_response(403)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    b"<!doctype html><html><body style='font-family:sans-serif;padding:2rem'>"
                    b"<h2>Zugriff verweigert</h2>"
                    b"<p>Dieser Pr\xc3\xbcfungs-Account wird bereits von einem anderen Ger\xc3\xa4t verwendet.</p>"
                    b"<p>Falls du der/die richtige Studierende bist, wende dich an die Aufsicht.</p>"
                    b"</body></html>"
                )

    def _handle_unlock(self, username: str):
        with lock_mutex:
            was_locked = username in locks
            locks.pop(username, None)
        status = (
            f"{username} entsperrt." if was_locked
            else f"{username} war nicht gesperrt."
        )
        print(f"[UNLOCK] {status}", flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write((status + "\n").encode())

    def _handle_status(self):
        with lock_mutex:
            lines = [f"{u}: {ip}" for u, ip in sorted(locks.items())]
        body = "\n".join(lines) if lines else "Keine aktiven Sperren."
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write((body + "\n").encode())

    def _ok(self):
        self.send_response(200)
        self.end_headers()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else LOCK_SERVICE_PORT
    server = HTTPServer(("127.0.0.1", port), LockHandler)
    print(f"[Lock Service] Lauscht auf 127.0.0.1:{port}", flush=True)
    server.serve_forever()
