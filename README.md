# Knowledge LXC für Proxmox

Zentraler lokaler **basic-memory** Knowledge-Graph für alle Agenten.
Läuft vollständig lokal im LXC, keine Cloud nötig.

- **MCP-SSE:** `http://[LXC-IP]:8000/sse` → in OpenCode/Claude/Cursor als **remote MCP** eintragen
- **Web UI:** `http://[LXC-IP]:8080` (Status, Projekte, Notizen-Count, `/health`)
- **Daten:** `/var/lib/knowledge/*.md` (Obsidian-kompatibel)
- Upstream: https://github.com/basicmachines-co/basic-memory

## Installation (Einzeiler, auf dem Proxmox-Host als root)

> `USER` ersetzen!

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/knowledge-proxmox/main/install/knowledge.sh)"
```

Mit Parametern:

```bash
CT_ID=150 CORES=2 RAM=4096 DISK=10 bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/knowledge-proxmox/main/install/knowledge.sh)"
# oder:
bash knowledge.sh --ctid 150 --cores 2 --memory 4096 --disk 10 --bridge vmbr0 --debug
```

Defaults: nächste freie ID via `pvesh get /cluster/nextid`, Hostname `knowledge`,
2 vCPU / 4096 MB / 10 GB, `vmbr0`, Debian-12 unprivileged, `onboot=1`.

Das Script ist idempotent (`set -euo pipefail`, volle Fehlerkette ins Log,
`--debug` für `bash -x`): existiert die CT-ID, läuft es im Update-Modus
(`uv tool upgrade`, Units neu, Services restart).

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
bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/knowledge-proxmox/main/install/knowledge.sh)"

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

## Hinweis

SSE-Endpoints sind ohne Auth – nur im LAN / hinter Tailscale/VPN betreiben,
nicht öffentlich exposen. Bei >5 parallelen Schreibern auf Postgres-Variante
(`docker-compose-postgres.yml` upstream) wechseln.
