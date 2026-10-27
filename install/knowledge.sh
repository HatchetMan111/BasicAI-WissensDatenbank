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
# push: Datei via stdin in den Container (mktemp-Umweg, /dev/stdin ist unzuverlaessig)
push_file() {
  local dest="$1" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  pct push "$CT_ID" "$tmp" "$dest"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Self-Test + SIGILL-Mitigation (native Wheels vs. alte CPUs)
# ---------------------------------------------------------------------------
BM_VENV_PY="/home/knowledge/.local/share/uv/tools/basic-memory/bin/python"

bm_uv() {  # bm_uv install <spec> ...  (in das uv-tool-venv)
  pct exec "$CT_ID" -- su - knowledge -c "cd /home/knowledge && export PATH=/home/knowledge/.local/bin:$PATH && uv pip $* --python $BM_VENV_PY"
}

strip_fastembed() {
  pct exec "$CT_ID" -- su - knowledge -c "cd /home/knowledge && export PATH=/home/knowledge/.local/bin:$PATH && uv pip uninstall --python $BM_VENV_PY fastembed onnxruntime onnxruntime-extensions" || true
  pct exec "$CT_ID" -- rm -rf /var/lib/knowledge/fastembed_cache /home/knowledge/.cache/fastembed || true
}

bm_selftest() {  # 0 = basic-memory laeuft, sonst Exit-Code (132 = SIGILL)
  local rc=0
  pct exec "$CT_ID" -- su - knowledge -c "cd /home/knowledge && /usr/local/bin/basic-memory project list" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

diag_native_modules() {  # pro Modul ein eigener Prozess, damit ein Crash den Sweep nicht stoppt
  local mod rc
  push_file /tmp/knowledge-import.py <<'PYEOF'
import sys

__import__(sys.argv[1])
PYEOF
  push_file /tmp/knowledge-vecload.py <<'PYEOF'
import sqlite3

import sqlite_vec

conn = sqlite3.connect(":memory:")
conn.enable_load_extension(True)
conn.load_extension(sqlite_vec.loadable_path())
conn.execute("select vec_version()").fetchone()
PYEOF
  for mod in pydantic_core sqlalchemy numpy sqlite_vec tiktoken tokenizers mmh3 jsonschema fastmcp mcp basic_memory basic_memory.db basic_memory.repository.search_repository; do
    rc=0
    pct exec "$CT_ID" -- su - knowledge -c "cd /home/knowledge && $BM_VENV_PY /tmp/knowledge-import.py $mod" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" == "0" ]]; then echo "OK     $mod"; else echo "CRASH  $mod (rc=$rc)"; fi
  done
  rc=0
  pct exec "$CT_ID" -- su - knowledge -c "cd /home/knowledge && $BM_VENV_PY /tmp/knowledge-vecload.py" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "0" ]]; then echo "OK     sqlite-vec load_extension"; else echo "CRASH  sqlite-vec load_extension (rc=$rc)"; fi
}

diag_dump() {
  msg_error "Native Modul-Sweep (CRASH = Prozess wurde abgebrochen):"
  diag_native_modules 2>&1 | sed 's/^/    /' || true
  msg_error "Kernel-Trap (nennt die crashende Shared Library):"
  dmesg 2>/dev/null | tail -n 15 || true
}

mitigate_runtime() {  # versucht bekannte Pins und prueft nach jedem Schritt neu
  local out crashers rc strat
  local -a strats

  rc="$(bm_selftest)"
  if [[ "$rc" == "0" ]]; then msg_ok "Self-Test 'basic-memory project list' OK."; return 0; fi
  msg_warn "Self-Test fehlgeschlagen (rc=$rc) – basic-memory crasht auf dieser CPU."

  out="$(diag_native_modules 2>&1 || true)"
  printf '%s\n' "$out" | sed 's/^/    /'
  crashers="$(printf '%s\n' "$out" | awk '/^CRASH/ {print $2}' | tr '\n' ' ')"
  msg_warn "Crash-Module: ${crashers:-unbekannt}"

  case " $crashers " in
    *" sqlite_vec "* | *" sqlite-vec "*) strats=("sqlitevec" "numpy" "older") ;;
    *" numpy "*)      strats=("numpy" "sqlitevec" "older") ;;
    *)                strats=("numpy" "sqlitevec" "older") ;;
  esac

  for strat in "${strats[@]}"; do
    case "$strat" in
      numpy)
        msg_info "Strategie 1: numpy==1.26.4 (2.x-Wheels nutzen neuere SIMD-Pfade) ..."
        bm_uv install numpy==1.26.4 || true
        ;;
      sqlitevec)
        msg_info "Strategie 2: sqlite-vec==0.1.9 (Extension statt Alpha-Wheel) ..."
        bm_uv install sqlite-vec==0.1.9 || true
        ;;
      older)
        msg_info "Strategie 3: basic-memory==0.23.2 (aelterer Wheel-Stack) ..."
        pct exec "$CT_ID" -- su - knowledge -c "cd /home/knowledge && export PATH=/home/knowledge/.local/bin:$PATH && uv tool install basic-memory==0.23.2 --force" || true
        pct exec "$CT_ID" -- ln -sf /home/knowledge/.local/bin/basic-memory /usr/local/bin/basic-memory || true
        if [[ "$SEMANTIC_MODE" == "off" ]]; then strip_fastembed; fi
        ;;
    esac
    rc="$(bm_selftest)"
    if [[ "$rc" == "0" ]]; then
      msg_ok "Self-Test OK nach Strategie '$strat'."
      pct exec "$CT_ID" -- bash -c "printf 'RUNTIME=%s\n' '$strat' > /etc/knowledge-runtime.conf" || true
      return 0
    fi
    msg_warn "Strategie '$strat' half nicht (rc=$rc)."
  done
  return 1
}

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
    su - knowledge -c "cd /home/knowledge && curl -LsSf https://astral.sh/uv/install.sh | sh"
  fi
  su - knowledge -c "cd /home/knowledge && export PATH=/home/knowledge/.local/bin:$PATH && uv tool install basic-memory"
  ln -sf /home/knowledge/.local/bin/basic-memory /usr/local/bin/basic-memory
  /usr/local/bin/basic-memory --version
  # onnxruntime-Wheels setzen AVX voraus. Fehlt AVX, killt "import fastembed" den
  # MCP-Prozess hart mit SIGILL (systemd: status=4/ILL). Dann fastembed entfernen:
  # basic-memory faellt dokumentiert auf Keyword-/FTS-Suche zurueck und bootet stabil.
  if grep -qiE "^flags[[:space:]]*:.*[[:space:]]avx([[:space:]]|$)" /proc/cpuinfo; then
    SEMANTIC=on
  else
    SEMANTIC=off
    su - knowledge -c "cd /home/knowledge && export PATH=/home/knowledge/.local/bin:$PATH && uv pip uninstall --python /home/knowledge/.local/share/uv/tools/basic-memory/bin/python fastembed onnxruntime onnxruntime-extensions" || true
    rm -rf /var/lib/knowledge/fastembed_cache /home/knowledge/.cache/fastembed
  fi
  printf "SEMANTIC=%s\n" "$SEMANTIC" > /etc/knowledge-semantic.conf
  chown -R knowledge:knowledge /var/lib/knowledge
'

SEMANTIC_MODE="$(pct exec "$CT_ID" -- sed -n 's/^SEMANTIC=//p' /etc/knowledge-semantic.conf 2>/dev/null | tr -d '\r' || true)"
SEMANTIC_MODE="${SEMANTIC_MODE:-on}"
if [[ "$SEMANTIC_MODE" == "off" ]]; then
  msg_warn "CPU ohne AVX: onnxruntime (fastembed) wuerde den MCP-Server mit SIGILL beenden."
  msg_warn "Semantische Suche ist deshalb AUS -> basic-memory nutzt Keyword-/FTS-Suche."
  msg_warn "Upgrade-Pfad: Ollama/llama.cpp als OpenAI-kompatiblen Embedding-Server nutzen"
  msg_warn "  und semantic_embedding_provider=litellm + semantic_embedding_api_base setzen."
else
  msg_ok "AVX vorhanden: semantische Suche (fastembed, lokale Embeddings) aktiv."
fi

msg_info "Self-Test basic-memory (project list) ..."
if ! mitigate_runtime; then
  msg_error "basic-memory laeuft auf dieser CPU nicht stabil – vollstaendige Diagnose:"
  diag_dump
  exit 1
fi

msg_info "Lege Mini-UI nach /opt/knowledge ..."
if pct exec "$CT_ID" -- curl -fsSL -o /opt/knowledge/knowledge-ui.py "$UI_PY_URL" 2>/dev/null; then
  msg_ok "knowledge-ui.py aus Repo uebernommen."
else
  msg_warn "UI-URL nicht erreichbar – schreibe eingebettete UI (Fallback)."
  push_file /opt/knowledge/knowledge-ui.py <<'UIEOF'
#!/usr/bin/env python3
import argparse
import json
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def safe_run(cmd, timeout=5):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (out.stdout + out.stderr).strip()
    except Exception as exc:  # noqa: BLE001
        return "n/a (%s)" % exc


def semantic_mode():
    try:
        for line in Path("/etc/knowledge-semantic.conf").read_text().splitlines():
            if line.startswith("SEMANTIC="):
                return line.split("=", 1)[1].strip()
    except Exception:  # noqa: BLE001
        pass
    return "unknown"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        if self.path == "/health":
            self._send(200, json.dumps({"status": "ok", "app": "knowledge"}), "application/json")
            return
        if self.path != "/":
            self._send(404, "not found", "text/plain")
            return
        notes = sum(1 for _ in Path("/var/lib/knowledge").rglob("*.md"))
        ip = (safe_run(["hostname", "-I"]).split() or ["n/a"])[0]
        body = (
            "<h1>Knowledge LXC</h1>"
            "<p>MCP: http://%s:8000/sse</p>"
            "<p>Notizen: %d</p>"
            "<p>Semantische Suche: %s</p>"
        ) % (ip, notes, semantic_mode())
        self._send(200, body, "text/html")

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    args, _ = parser.parse_known_args()
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


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
  push_file /etc/systemd/system/knowledge-mcp.service <<'UNIT'
[Unit]
Description=Knowledge LXC - basic-memory MCP SSE (:8000)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=knowledge
Group=knowledge
WorkingDirectory=/home/knowledge
Environment=HOME=/home/knowledge
Environment=PATH=/home/knowledge/.local/bin:/usr/local/bin:/usr/bin:/bin
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
  push_file /etc/systemd/system/knowledge-ui.service <<'UNIT'
[Unit]
Description=Knowledge LXC - Mini Status-UI (:8080)
After=network-online.target knowledge-mcp.service
Wants=network-online.target
[Service]
Type=simple
User=knowledge
Group=knowledge
WorkingDirectory=/home/knowledge
Environment=HOME=/home/knowledge
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 /opt/knowledge/knowledge-ui.py --port 8080 --mcp-port 8000 --data-dir /var/lib/knowledge --bm-bin /usr/local/bin/basic-memory --bind 0.0.0.0
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable knowledge-mcp knowledge-ui

msg_info "Initialisiere main-Projekt (Login-Shell: HOME=/home/knowledge, sonst EACCES auf .env/pyproject.toml) ..."
if ! pct exec "$CT_ID" -- bash -c '
  set -e
  LIST="$(su - knowledge -c "cd /home/knowledge && /usr/local/bin/basic-memory project list 2>&1")"
  printf "%s\n" "$LIST"
  if printf "%s" "$LIST" | grep -q "/var/lib/knowledge"; then
    echo "Projekt mit Pfad /var/lib/knowledge existiert bereits."
  elif printf "%s" "$LIST" | grep -qw main; then
    echo "WARN: Projekt main existiert bereits mit anderem Pfad – bitte manuell pruefen."
  else
    su - knowledge -c "cd /home/knowledge && /usr/local/bin/basic-memory project add main /var/lib/knowledge"
  fi
'; then
  msg_error "Projekt-Init fehlgeschlagen (vollstaendige Ausgabe oben)."
  diag_dump
  exit 1
fi
msg_ok "Projekt main -> /var/lib/knowledge bereit."

# ---------------------------------------------------------------------------
# 5. Verifikation: Service stabil + Web UI + MCP-Port
# ---------------------------------------------------------------------------
mcp_active() { pct exec "$CT_ID" -- systemctl is-active --quiet knowledge-mcp 2>/dev/null; }

wait_mcp_stable() {
  local i restarts
  for i in $(seq 1 15); do
    mcp_active || return 1
    sleep 2
  done
  restarts="$(pct exec "$CT_ID" -- systemctl show -p NRestarts --value knowledge-mcp 2>/dev/null | tr -d '\r' || true)"
  (( ${restarts:-0} <= ${MCP_RESTARTS_BASE:-0} ))
}

msg_info "Starte knowledge-mcp (Stabilitaetsfenster 30s – SIGILL tritt ~20s nach Start auf) ..."
pct exec "$CT_ID" -- systemctl reset-failed knowledge-mcp 2>/dev/null || true
MCP_RESTARTS_BASE="$(pct exec "$CT_ID" -- systemctl show -p NRestarts --value knowledge-mcp 2>/dev/null | tr -d '\r' || true)"
MCP_RESTARTS_BASE="${MCP_RESTARTS_BASE:-0}"
pct exec "$CT_ID" -- systemctl restart knowledge-mcp

if ! wait_mcp_stable; then
  msg_error "knowledge-mcp ist nicht stabil aktiv. Status + letzte 120 Journal-Zeilen:"
  pct exec "$CT_ID" -- systemctl status knowledge-mcp --no-pager || true
  pct exec "$CT_ID" -- journalctl -u knowledge-mcp --no-pager -n 120 || true
  if [[ "$SEMANTIC_MODE" == "on" ]]; then
    msg_warn "Fallback: entferne fastembed/onnxruntime (semantische Suche aus) und starte neu ..."
    strip_fastembed
    pct exec "$CT_ID" -- bash -c "printf 'SEMANTIC=off\n' > /etc/knowledge-semantic.conf" || true
    SEMANTIC_MODE=off
    pct exec "$CT_ID" -- systemctl reset-failed knowledge-mcp 2>/dev/null || true
    pct exec "$CT_ID" -- systemctl restart knowledge-mcp 2>/dev/null || pct exec "$CT_ID" -- systemctl start knowledge-mcp
    if wait_mcp_stable; then
      msg_warn "MCP laeuft jetzt im Keyword-/FTS-Modus (semantische Suche aus)."
      msg_warn "Ursache oben im Journal pruefen (typisch: onnxruntime/SIGILL ohne AVX)."
    else
      msg_error "MCP startet auch ohne fastembed nicht. Vollstaendiges Journal:"
      pct exec "$CT_ID" -- journalctl -u knowledge-mcp --no-pager -n 200 || true
      pct exec "$CT_ID" -- systemctl status knowledge-mcp --no-pager || true
      diag_dump
      exit 1
    fi
  else
    diag_dump
    exit 1
  fi
fi
msg_ok "knowledge-mcp laeuft stabil (30s ohne Neustart)."

pct exec "$CT_ID" -- systemctl start knowledge-ui
pct exec "$CT_ID" -- systemctl is-active knowledge-ui || { msg_error "systemd-Service knowledge-ui ist nicht active."; pct exec "$CT_ID" -- systemctl status knowledge-ui --no-pager || true; pct exec "$CT_ID" -- journalctl -u knowledge-ui --no-pager -n 80 || true; exit 1; }
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
  sleep 5
done
[[ "$MCP_OK" == "1" ]] \
  || { msg_error "MCP lauscht nicht auf Port ${MCP_PORT}."; pct exec "$CT_ID" -- journalctl -u knowledge-mcp --no-pager -n 120 || true; exit 1; }
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
SEM_SUMMARY="$(pct exec "$CT_ID" -- sed -n 's/^SEMANTIC=//p' /etc/knowledge-semantic.conf 2>/dev/null | tr -d '\r' || true)"
RT_SUMMARY="$(pct exec "$CT_ID" -- sed -n 's/^RUNTIME=//p' /etc/knowledge-runtime.conf 2>/dev/null | tr -d '\r' || true)"
case "${SEM_SUMMARY:-on}" in
  off) echo "  Semantik     : AUS – Keyword-/FTS-Suche (CPU ohne AVX, fastembed entfernt)" ;;
  *)   echo "  Semantik     : AN – lokale Embeddings (fastembed)${RT_SUMMARY:+ | Runtime-Fix: $RT_SUMMARY}" ;;
esac
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unveraendert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status knowledge-mcp knowledge-ui  (im Container via: pct enter $CT_ID)"
echo "  Update       : Skript erneut laufen lassen (idempotent, uv tool upgrade)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${UI_PORT}/health"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
