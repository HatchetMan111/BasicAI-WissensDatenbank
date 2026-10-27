# Knowledge LXC für Proxmox

Zentraler lokaler **basic-memory** Knowledge-Graph für alle Agenten.
Läuft vollständig lokal im LXC, keine Cloud nötig.

- **MCP-SSE:** `http://[LXC-IP]:8000/sse` → in OpenCode/Claude/Cursor als **remote MCP** eintragen
- **Web UI:** `http://[LXC-IP]:8080` (Status, Projekte, Notizen-Count, `/health`)
- **Daten:** `/var/lib/knowledge/*.md` (Obsidian-kompatibel)
- Upstream: https://github.com/basicmachines-co/basic-memory

## Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BasicAI-WissensDatenbank/main/install/knowledge.sh)"
```

Mit Parametern:

```bash
CT_ID=150 CORES=2 RAM=4096 DISK=10 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BasicAI-WissensDatenbank/main/install/knowledge.sh)"
# oder:
bash knowledge.sh --ctid 150 --cores 2 --memory 4096 --disk 10 --bridge vmbr0 --debug
```

Defaults: nächste freie ID via `pvesh get /cluster/nextid`, Hostname `knowledge`,
2 vCPU / 4096 MB / 10 GB, `vmbr0`, Debian-12 unprivileged, `onboot=1`.

Das Script ist idempotent (`set -euo pipefail`, volle Fehlerkette ins Log,
`--debug` für `bash -x`): existiert die CT-ID, läuft es im Update-Modus
(`uv tool upgrade`, Units neu, Services restart).

## Native Wheels, alte CPUs und SIGILL

basic-memory nutzt native Wheels (`pydantic-core`, `numpy`, `sqlite-vec`, …) und
für Embeddings `fastembed`/`onnxruntime`. Auf älteren CPUs (kein AVX oder
neuere SIMD-Baseline) kann eines dieser Module den Prozess hart mit `SIGILL`
beenden — Symptom: `systemd: status=4/ILL` oder `Illegal instruction` bei
`basic-memory project list`.

Der Installer rät nicht, sondern misst:

1. **AVX-Check** (`/proc/cpuinfo`). Ohne AVX werden `fastembed`/`onnxruntime`
   entfernt → Keyword-/FTS-Suche (`/etc/knowledge-semantic.conf`, `SEMANTIC=off`).
2. **Self-Test** `basic-memory project list` direkt nach der Installation.
3. **Bei Crash**: Modul-Sweep (jedes Modul in eigenem Prozess) + `dmesg`, dann
   automatische Pins, nach jedem Schritt erneut getestet:
   `numpy==1.26.4` → `sqlite-vec==0.1.9` → `basic-memory==0.23.2`.
   Der erfolgreiche Fix landet in `/etc/knowledge-runtime.conf` (`RUNTIME=…`)
   und in der Abschluss-Zusammenfassung.
4. **Hilft nichts**: Abbruch mit vollem Sweep, Journal und Kernel-Trap
   (nennt die crashende `.so`) — kein stiller Fehlschlag.

Anschließend startet der Installer `knowledge-mcp` und prüft 30 s auf
Stabilität (`NRestarts == 0`); schlägt das fehl, wird `fastembed` entfernt,
neu gestartet und die Ursache ausgegeben.

Semantische Suche **ohne** AVX nachrüsten (OpenAI-kompatibler
Embedding-Server, z. B. Ollama auf einem anderen Host):

```bash
pct enter <CTID>
basic-memory config set semantic_embedding_provider litellm
basic-memory config set semantic_embedding_api_base http://<ollama-host>:11434/v1
basic-memory config set semantic_embedding_model openai/nomic-embed-text
basic-memory config set semantic_embedding_dimensions 768
basic-memory reindex --embeddings
systemctl restart knowledge-mcp
```

Wichtig: `uv tool upgrade basic-memory` setzt die Pins/`fastembed`-Entfernung
zurück. Danach Installer erneut ausführen (idempotent) oder die
Provider-Konfiguration oben nutzen.

## Agenten anbinden (MCP)

Die Installation liefert **einen** MCP-Server für alle Agenten. Beide Endpoints
zeigen auf denselben Graphen (Projekt `main` → `/var/lib/knowledge`):

| Transport | URL | Status |
| --- | --- | --- |
| SSE | `http://<LXC-IP>:8000/sse` | Default dieser Installation |
| Streamable HTTP | `http://<LXC-IP>:8000/mcp` | nach Umstellung (siehe unten) |

Umstellung auf Streamable HTTP (upstream-Empfehlung, manche Clients wollen das):

```bash
pct exec <CTID> -- sed -i 's/--transport sse/--transport streamable-http/' /etc/systemd/system/knowledge-mcp.service
pct exec <CTID> -- systemctl daemon-reload
pct exec <CTID> -- systemctl restart knowledge-mcp
# danach: http://<LXC-IP>:8000/mcp
```

Nur ein Transport gleichzeitig (ein Prozess = ein Watcher auf der DB).

### OpenCode

`~/.config/opencode/opencode.json` (global) oder `opencode.json` im Projekt,
Eintrag in das bestehende `mcp`-Objekt mergen:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "knowledge": {
      "type": "remote",
      "url": "http://10.120.1.194:8000/sse",
      "enabled": true
    }
  }
}
```

Prüfen: `opencode mcp list`, debuggen: `opencode mcp debug knowledge`.
Die Tools heißen mit Server-Prefix `knowledge_*` (z. B. `knowledge_write_note`).

### Claude Code

```bash
# alle Projekte (user scope)
claude mcp add --transport sse --scope user knowledge http://10.120.1.194:8000/sse

# alternativ Streamable HTTP
claude mcp add --transport http --scope user knowledge http://10.120.1.194:8000/mcp
```

Prüfen: `claude mcp list` → `knowledge: ... - ✓ Connected`.

### Claude Desktop

Desktop spricht lokale HTTP-Endpoints nicht direkt, dafür den Brücken-Prozess
`mcp-remote` nutzen — `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "knowledge": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://10.120.1.194:8000/sse"]
    }
  }
}
```

Datei liegt auf macOS unter
`~/Library/Application Support/Claude/claude_desktop_config.json`, unter Windows
unter `%APPDATA%\Claude\claude_desktop_config.json`. Danach Claude Desktop
komplett beenden (Tray) und neu starten.

Alternativ (nur mit HTTPS): Settings → Connectors → „Add custom connector“ mit
`https://…/sse` (z. B. über Tailscale Funnel, siehe ChatGPT).

### ChatGPT

ChatGPT verbindet **nur remote** und braucht einen **öffentlichen HTTPS**-Endpoint
(oder „Secure MCP Tunnel“). Pro/Plus/Business/Enterprise/Edu, Web-UI.

```bash
# Beispiel Tailscale (LXC-Host im Tailnet): HTTPS-Endpoint auf 443 -> 8000
tailscale funnel --bg 8000
# URL: https://<host>.<tailnet>.ts.net/sse
```

Dann auf <https://chatgpt.com/plugins> → „+“ → „Add custom MCP server“ →
URL eintragen → Authentifizierung „No authentication“ → „Scan tools“.
ChatGPT nutzt zusätzlich die OpenAI-spezifischen `search`/`fetch`-Tools, die
basic-memory mitbringt.

> **Achtung:** Der Endpoint hat **keine Authentifizierung**. Wer die URL kennt,
> kann Notizen lesen *und* schreiben. Nur im LAN/VPN oder hinter einem
> tokenprüfenden Reverse Proxy (Caddy/nginx) veröffentlichen.

### Was der Agent kann (Tools)

`write_note`, `read_note`, `edit_note`, `move_note`, `delete_note`,
`search_notes`, `recent_activity`, `build_context`, `list_directory`,
`view_note`, `bm_find` sowie `search`/`fetch` für ChatGPT.

Suchtypen: `text` (Keyword/FTS) und `hybrid`/`semantic` — bei `SEMANTIC=off`
(siehe oben) liefert alles Keyword-Treffer.

### Beispiel-Prompts

```text
Schreib in knowledge eine Notiz "Proxmox-Backup" mit den Schritten, die wir gerade gemacht haben.
Suche in knowledge nach "ZFS snapshot" und fasse zusammen, was dort steht.
Hole mit build_context alles zu "Homelab Netzwerk" und beantworte meine Frage daraus.
Was war die letzte Aktivität in knowledge?
```

Ohne expliziten Hinweis nutzen Agenten die Tools oft nicht — „nutze knowledge“
oder eine `AGENTS.md`/`CLAUDE.md`-Regel hilft:

```md
Wenn es um Notizen, Wissen oder frühere Entscheidungen geht: nutze die knowledge-MCP-Tools.
```

### Notizen direkt schreiben/lesen

```bash
pct enter <CTID>
basic-memory project list          # Projekt main -> /var/lib/knowledge
basic-memory search "backup"       # Keyword-Suche
basic-memory sync                  # Dateien aus /var/lib/knowledge indexieren
```

Alles unter `/var/lib/knowledge/*.md` (Markdown + Frontmatter, Obsidian-kompatibel)
wird bei laufendem Dienst automatisch indexiert (`BASIC_MEMORY_SYNC_CHANGES=true`).
Die Web-UI auf `:8080` ist reine Statusanzeige.

## Update / Deinstall / Reboot-Test

```bash
# Update: Script erneut laufen lassen (idempotent)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BasicAI-WissensDatenbank/main/install/knowledge.sh)"

# im Container: basic-memory Version
pct enter <CTID>
basic-memory --version && basic-memory status

# Deinstall:
pct stop <CTID> && pct destroy <CTID>

# Reboot-Test:
pct reboot <CTID> && sleep 60 && curl -fs http://<LXC-IP>:8080/health
```

## Layout

```
install/knowledge.sh          Proxmox-Installer (Host läuft, CT wird erstellt)
src/knowledge-ui.py           Mini Status-UI (stdlib-only, :8080)
systemd/knowledge-mcp.service basic-memory MCP SSE (:8000)
systemd/knowledge-ui.service  UI-Service (:8080)
```

## Troubleshooting

```bash
# vollen Fehlerbaum eines Dienstes sehen
pct exec <CTID> -- systemctl status knowledge-mcp --no-pager
pct exec <CTID> -- journalctl -u knowledge-mcp --no-pager -n 200

# Modus der semantischen Suche + aktiver Runtime-Fix
pct exec <CTID> -- cat /etc/knowledge-semantic.conf /etc/knowledge-runtime.conf

# Self-Test / Diagnose der nativen Module
pct exec <CTID> -- su - knowledge -c 'cd /home/knowledge && basic-memory project list' 

# CPU-Flags im Container
pct exec <CTID> -- grep -m1 '^flags' /proc/cpuinfo
```

`Permission denied: '.env'` / `pyproject.toml` in den Logs kam daher, dass
`basic-memory` als `knowledge`-User mit `cwd=/root` lief. Alle Aufrufe im
Installer nutzen deshalb `su - knowledge` (Login-Shell: `HOME=/home/knowledge`)
plus `cd /home/knowledge`; die Unit setzt zusätzlich `WorkingDirectory=`.

## Hinweis

SSE-Endpoints sind ohne Auth – nur im LAN / hinter Tailscale/VPN betreiben,
nicht öffentlich exposen. Bei >5 parallelen Schreibern auf Postgres-Variante
(`docker-compose-postgres.yml` upstream) wechseln.
