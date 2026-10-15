#!/usr/bin/env bash
#
# Knowledge LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Knowledge – zentraler lokaler basic-memory Graph (MCP-SSE) + Mini Status-UI
# Upstream: https://github.com/basicmachines-co/basic-memory
# Stack:    Python 3.12 + uv + basic-memory (nativ, ohne Docker) + Mini-UI (stdlib) + systemd
# Laeuft:   vollstaendig lokal im LXC, keine Cloud noetig
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BasicAI-WissensDatenbank/main/install/knowledge.sh)"
#   CT_ID=150 CORES=2 RAM=4096 DISK=10 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BasicAI-WissensDatenbank/main/install/knowledge.sh)"
#   bash knowledge.sh --ctid 150 --cores 2 --memory 4096 --disk 10 --bridge vmbr0 --debug
#
# Repo: https://github.com/HatchetMan111/BasicAI-WissensDatenbank
# basic-memory braucht fuer Embeddings RAM: Default 4096 MB, Minimum 2048 MB.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="knowledge"                               # Container-Hostname + Service-Prefix
MCP_PORT="8000"                               # basic-memory MCP SSE
UI_PORT="8080"                                # Mini Status-UI
UPSTREAM_REPO="https://github.com/basicmachines-co/basic-memory"
INSTALLER_REPO="https://github.com/HatchetMan111/BasicAI-WissensDatenbank"
MCP_SERVICE_URL="${INSTALLER_REPO%/}/raw/main/systemd/knowledge-mcp.service"
UI_SERVICE_URL="${INSTALLER_REPO%/}/raw/main/systemd/knowledge-ui.service"
UI_PY_URL="${INSTALLER_REPO%/}/raw/main/src/knowledge-ui.py"

DEFAULT_CORES="2"                             # vCPU
DEFAULT_RAM="4096"                            # RAM in MB (Minimum 2048, Embeddings!)
DEFAULT_SWAP="1024"                           # Swap (MB)
DEFAULT_DISK="10"                             # Disk in GB (Minimum 8)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage fuer CT-Templates
DEFAULT_OS="debian-12-standard"               # Template-Familie
UNPRIVILEGED="1"                              # 1 = unprivilegiert (reicht, kein Docker)
FEATURES="nesting=1"

APP_USER="knowledge"
APP_DIR="/opt/knowledge"
DATA_DIR="/var/lib/knowledge"
BM_BIN="/usr/local/bin/basic-memory"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=4096 DISK=10 ./knowledge.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash knowledge.sh [OPTIONEN]
  CT_ID=150 bash knowledge.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO%/}/raw/main/install/knowledge.sh)"

Optionen:
  --ctid ID            Container-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM}, Minimum 2048)
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK}, Minimum 8)
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufaellig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container uebernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

[[ "$RAM" -ge 2048 ]] || { msg_error "RAM muss >= 2048 sein (Embeddings). Gewaehlt: $RAM"; exit 1; }
[[ "$DISK" -ge 8 ]] || { msg_error "Disk muss >= 8 GB sein. Gewaehlt: $DISK"; exit 1; }

# Immer naechste freie ID, ausser --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Naechste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfuegbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Pruefe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden."
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – ueberspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge pruefen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. basic-memory + Mini-UI im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere basic-memory nativ via uv (idempotent) ..."
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl ca-certificates python3 sqlite3 iproute2
  id knowledge >/dev/null 2>&1 || useradd -m -s /bin/bash knowledge
  mkdir -p /opt/knowledge /var/lib/knowledge
  chown -R knowledge:knowledge /opt/knowledge /var/lib/knowledge
  if [ ! -x /home/knowledge/.local/bin/uv ]; then
    su -s /bin/bash knowledge -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
  fi
  su -s /bin/bash knowledge -c "export PATH=/home/knowledge/.local/bin:$PATH; uv tool install basic-memory --prerelease=allow"
  ln -sf /home/knowledge/.local/bin/basic-memory /usr/local/bin/basic-memory
  /usr/local/bin/basic-memory --version
  chown -R knowledge:knowledge /var/lib/knowledge
'

msg_info "Lege Mini-UI nach /opt/knowledge ..."
if pct exec "$CT_ID" -- curl -fsSL -o /opt/knowledge/knowledge-ui.py "$UI_PY_URL" 2>/dev/null; then
  msg_ok "knowledge-ui.py aus Repo uebernommen."
else
  msg_warn "UI-URL nicht erreichbar – schreibe eingebettete UI (Fallback)."
  pct push "$CT_ID" /dev/stdin /opt/knowledge/knowledge-ui.py <<UIEOF
#!/usr/bin/env python3
import argparse, json, socket, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
def safe_run(cmd, timeout=5):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (out.stdout.strip() + out.stderr.strip()).strip()[:2000]
    except Exception as e:
        return "n/a (%s)" % e
class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        d = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(d)))
        self.end_headers()
        self.wfile.write(d)
    def do_GET(self):
        if self.path in ("/health", "/status"):
            self._send(200, json.dumps({"status": "ok", "app": "knowledge"}), "application/json")
            return
        notes = sum(1 for _ in Path("/var/lib/knowledge").rglob("*.md")) if True)
        ip = safe_run(["hostname", "-I"]).split()[0] if safe_run(["hostname", "-I"]) else "n/a"
        self._send(200, "<h1>Knowledge LXC</h1><p>MCP: http://%s:8000/sse</p><p>Notes: %s</p>" % (ip, notes), "text/html")
    def log_message(self, *a):
        pass
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    args, _ = ap.parse_known_args()
    ThreadingHTTPServer(("0.0.0.0", args.port), H).serve_forever()
if __name__ == "__main__":
    main()
UIEOF
fi
pct exec "$CT_ID" -- chmod 644 /opt/knowledge/knowledge-ui.py

msg_info "Richte systemd-Units ein ..."
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/knowledge-mcp.service "$MCP_SERVICE_URL" 2>/dev/null; then
  msg_ok "knowledge-mcp.service aus Repo uebernommen."
else
  msg_warn "MCP-Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/knowledge-mcp.service <<UNIT
[Unit]
Description=Knowledge LXC - basic-memory MCP SSE (:8000)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=knowledge
Group=knowledge
Environment=HOME=/home/knowledge
Environment=PYTHONUNBUFFERED=1
Environment=BASIC_MEMORY_DEFAULT_PROJECT=main
Environment=BASIC_MEMORY_SYNC_CHANGES=true
ExecStart=/usr/local/bin/basic-memory mcp --transport sse --host 0.0.0.0 --port 8000
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
fi
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/knowledge-ui.service "$UI_SERVICE_URL" 2>/dev/null; then
  msg_ok "knowledge-ui.service aus Repo uebernommen."
else
  msg_warn "UI-Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/knowledge-ui.service <<UNIT
[Unit]
Description=Knowledge LXC - Mini Status-UI (:8080)
After=network-online.target knowledge-mcp.service
Wants=network-online.target
[Service]
Type=simple
User=knowledge
Group=knowledge
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 /opt/knowledge/knowledge-ui.py --port 8080 --mcp-port 8000 --data-dir /var/lib/knowledge --bm-bin /usr/local/bin/basic-memory --bind 0.0.0.0
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now knowledge-mcp
pct exec "$CT_ID" -- systemctl enable --now knowledge-ui

msg_info "Initialisiere main-Projekt ..."
pct exec "$CT_ID" -- su -s /bin/bash knowledge -c "/usr/local/bin/basic-memory project list | grep -q main || /usr/local/bin/basic-memory project add main /var/lib/knowledge" || msg_warn "Projekt-Init uebersprungen (wird beim ersten Start angelegt)."

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI + MCP-Port
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active knowledge-mcp || { msg_error "systemd-Service knowledge-mcp ist nicht active."; pct exec "$CT_ID" -- systemctl status knowledge-mcp --no-pager || true; pct exec "$CT_ID" -- journalctl -u knowledge-mcp --no-pager -n 100 || true; exit 1; }
msg_ok "Service knowledge-mcp laeuft."
pct exec "$CT_ID" -- systemctl is-active knowledge-ui || { msg_error "systemd-Service knowledge-ui ist nicht active."; pct exec "$CT_ID" -- systemctl status knowledge-ui --no-pager || true; exit 1; }
msg_ok "Service knowledge-ui laeuft."

msg_info "Warte auf Web UI (max. 3 Min) ..."
UI_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${UI_PORT}/health" >/dev/null 2>&1; then UI_OK=1; break; fi
  sleep 10
done
[[ "$UI_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${UI_PORT}/health."; pct exec "$CT_ID" -- systemctl status knowledge-ui --no-pager || true; pct exec "$CT_ID" -- journalctl -u knowledge-ui --no-pager -n 100 || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${UI_PORT}/health)."

msg_info "Pruefe MCP-Port ${MCP_PORT} ..."
MCP_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- bash -c "command -v ss >/dev/null && ss -tln | grep -q :${MCP_PORT}" >/dev/null 2>&1; then MCP_OK=1; break; fi
  if pct exec "$CT_ID" -- curl -fs -m 5 "http://localhost:${MCP_PORT}/" >/dev/null 2>&1; then MCP_OK=1; break; fi
  sleep 10
done
[[ "$MCP_OK" == "1" ]] \
  || { msg_error "MCP antwortet nicht auf Port ${MCP_PORT}."; pct exec "$CT_ID" -- journalctl -u knowledge-mcp --no-pager -n 100 || true; exit 1; }
msg_ok "MCP-Port ${MCP_PORT} offen."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Knowledge – lokaler basic-memory Graph"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${UI_PORT}  (/health)"
echo "  MCP-SSE      : http://${CT_IP}:${MCP_PORT}/sse  (fuer alle Agenten als remote MCP)"
echo "  Daten        : /var/lib/knowledge (*.md, Obsidian-kompatibel)"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unveraendert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status knowledge-mcp knowledge-ui  (im Container via: pct enter $CT_ID)"
echo "  Update       : Skript erneut laufen lassen (idempotent, uv tool upgrade)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${UI_PORT}/health"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
