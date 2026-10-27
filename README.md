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

## Semantische Suche und CPU-Anforderung (AVX)

basic-memory sucht standardmäßig semantisch: `fastembed` + `onnxruntime` laden
lokal das Embedding-Modell `bge-small-en-v1.5` (384 Dimensionen). Die
`onnxruntime`-Wheels setzen **AVX** voraus.

Der Installer prüft `/proc/cpuinfo`:

| CPU | Ergebnis |
| --- | --- |
| AVX vorhanden | semantische Suche aktiv (lokale Embeddings) |
| kein AVX (Atom/Celeron u.a.) | `fastembed`/`onnxruntime` werden entfernt → **Keyword-/FTS-Suche** |

Ohne AVX würde `import onnxruntime` den MCP-Prozess mit `SIGILL` beenden
(systemd: `status=4/ILL`, ~20 s nach Start). Der Installer startet den Dienst
und prüft 30 s lang auf Stabilität (`NRestarts == 0`); schlägt das fehl, wird
`fastembed` automatisch entfernt, neu gestartet und die Ursache im Journal
ausgegeben. Der aktive Modus steht in `/etc/knowledge-semantic.conf`
(`SEMANTIC=on|off`) und wird in der Web-UI angezeigt.

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

Wichtig: `uv tool upgrade basic-memory` installiert `fastembed` auf einem
Nicht-AVX-Host wieder mit. Danach den Installer erneut ausführen (entfernt es
wieder) oder die Provider-Konfiguration oben nutzen.

## Agenten anbinden

OpenCode (`~/.config/opencode/opencode.json`, Bereich `mcp`):

```json
"knowledge": {
  "type": "remote",
  "url": "http://192.168.1.xx:8000/sse"
}
```

Danach: `"Lege eine Notiz zu X an."`, `"Suche in meinen Notes nach Y."`

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

# Modus der semantischen Suche
pct exec <CTID> -- cat /etc/knowledge-semantic.conf

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
