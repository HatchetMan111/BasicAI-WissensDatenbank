#!/usr/bin/env python3
"""Knowledge Mini Status-UI (stdlib only).

Zeigt Status des lokalen basic-memory LXC:
- Container-IP, MCP-SSE URL, Datenverzeichnis
- Anzahl Markdown-Notizen, basic-memory Version
- systemd-Status (best effort)
"""
import argparse
import html
import json
import os
import socket
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def safe_run(cmd, timeout=5):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (out.stdout.strip() + out.stderr.strip()).strip()[:2000]
    except Exception as e:  # noqa: BLE001 - best effort status page
        return f"n/a ({e})"


def container_ip():
    try:
        return safe_run(["hostname", "-I"]).split()[0]
    except Exception:  # noqa: BLE001
        return "n/a"


def count_notes(data_dir):
    try:
        return sum(1 for _ in Path(data_dir).rglob("*.md"))
    except Exception:  # noqa: BLE001
        return -1


class Handler(BaseHTTPRequestHandler):
    server_version = "KnowledgeUI/1.0"

    def _send(self, code, body, ctype):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        if self.path in ("/health", "/status"):
            self._send(200, json.dumps({"status": "ok", "app": "knowledge"}), "application/json")
            return
        if self.path != "/":
            self._send(404, "not found", "text/plain")
            return
        cfg = self.server.cfg
        ip = container_ip()
        notes = count_notes(cfg["data_dir"])
        mcp_status = safe_run(["systemctl", "is-active", "knowledge-mcp"])
        ui_status = safe_run(["systemctl", "is-active", "knowledge-ui"])
        bm_version = safe_run([cfg["bm_bin"], "--version"])
        host = socket.gethostname()
        body = f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Knowledge LXC</title>
<style>body{{font-family:system-ui,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem}}
.card{{border:1px solid #ddd;border-radius:12px;padding:1rem;margin:.75rem 0}}
.ok{{color:#0a7b2d;font-weight:700}}.bad{{color:#b00020;font-weight:700}}
code{{background:#f4f4f4;padding:.1rem .35rem;border-radius:6px}}</style>
</head><body>
<h1>Knowledge LXC</h1>
<p>Lokaler <b>basic-memory</b> Graph f&uuml;r alle Agenten (MCP-SSE).</p>
<div class="card"><b>Container:</b> {html.escape(host)} ({html.escape(ip)})<br>
<b>MCP-SSE:</b> <code>http://{html.escape(ip)}:{cfg['mcp_port']}/sse</code><br>
<b>Health:</b> <code>/health</code></div>
<div class="card"><b>Daten dir:</b> <code>{html.escape(cfg['data_dir'])}</code><br>
<b>Notizen (.md):</b> {notes}<br>
<b>basic-memory:</b> <code>{html.escape(bm_version)}</code></div>
<div class="card"><b>knowledge-mcp:</b> {html.escape(mcp_status)}<br>
<b>knowledge-ui:</b> {html.escape(ui_status)}</div>
<div class="card">Agenten-Config (remote MCP):<br>
<code>http://{html.escape(ip)}:{cfg['mcp_port']}/sse</code></div>
</body></html>"""
        self._send(200, body, "text/html")

    def log_message(self, *args):  # leise
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--mcp-port", type=int, default=8000)
    ap.add_argument("--data-dir", default="/var/lib/knowledge")
    ap.add_argument("--bm-bin", default="/usr/local/bin/basic-memory")
    ap.add_argument("--bind", default="0.0.0.0")
    a = ap.parse_args()
    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    srv.cfg = {"mcp_port": a.mcp_port, "data_dir": a.data_dir, "bm_bin": a.bm_bin or "basic-memory"}
    print(f"knowledge-ui on {a.bind}:{a.port} (mcp={a.mcp_port}, data={a.data_dir})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
