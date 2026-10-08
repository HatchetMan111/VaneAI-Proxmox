#!/usr/bin/env bash
#
# Vane Proxmox LXC Installer v1.1 – im Stil der Proxmox VE Community Scripts
#
# App:      Vane – privacy-fokussierte AI-Antwortmaschine (Next.js + SearxNG)
# Upstream: https://github.com/ItzCrazyKns/Vane
# Stack:    Node 20 (Next.js, npm run start, 0.0.0.0:3000) + SearxNG
#           (pip + gunicorn, nur 127.0.0.1:8080), ohne Docker, ohne Cloud-Zwang.
#           LLM-Keys (OpenAI/Claude/Gemini/Groq) trägt man nach dem ersten Start
#           im Vane-Setup (http://<LXC-IP>:3000) ein.
# Läuft:    vollständig lokal im LXC – SearxNG + Web UI lokal, LLM konfigurierbar
# Host:     DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VaneAI-Proxmox/main/install/vane.sh)"
#   CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VaneAI-Proxmox/main/install/vane.sh)"
#   bash vane.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="vane"                                      # Container-Hostname + Service-Name
APP_PORT="3000"                                 # Vane Web UI (Next.js, bind 0.0.0.0)
SEARXNG_PORT="8080"                             # SearxNG intern (nur 127.0.0.1)
UPSTREAM_REPO="https://github.com/ItzCrazyKns/Vane"
INSTALLER_REPO="https://github.com/HatchetMan111/VaneAI-Proxmox"
VANE_UNIT_URL="https://raw.githubusercontent.com/HatchetMan111/VaneAI-Proxmox/main/systemd/vane.service"
SEARXNG_UNIT_URL="https://raw.githubusercontent.com/HatchetMan111/VaneAI-Proxmox/main/systemd/searxng.service"

DEFAULT_CORES="2"                               # vCPU (npm run build braucht kurz mehr)
DEFAULT_RAM="2048"                              # RAM in MB (Next.js Build ~1.5 GB Spitze)
DEFAULT_SWAP="1024"                             # Swap (MB) – puffert den Build
DEFAULT_DISK="8"                                # Disk in GB (Image ~2-3 GB + node_modules)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                  # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"                 # Template-Familie
UNPRIVILEGED="1"                                # 1 = unprivilegiert (reicht hier)
FEATURES="nesting=1"                            # Robustheit für npm/pip

APP_USER="vane"
APP_DIR="/opt/vane"
SEARXNG_USER="searx"
SEARXNG_VENV="/opt/searxng-venv"
SEARXNG_CONF="/etc/searxng/settings.yml"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=2048 DISK=8 ./vane.sh
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

# Vollständige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollständiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash vane.sh [OPTIONEN]
  CT_ID=150 bash vane.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO/raw.githubusercontent.com\/HatchetMan111\/VaneAI-Proxmox\/main\/install\/vane.sh})"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
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
# 1. Host-Prüfung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

# Immer nächste freie ID, außer --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Nächste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfügbares
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
msg_info "Prüfe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Hinweis: Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfügbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell prüfen (Netz/DNS auf dem Host)."
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
  msg_warn "CT $CT_ID existiert – überspringe Erstellung (Update-Modus)."
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
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge prüfen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

msg_info "Preflight im Container (Platte/RAM) ..."
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export LC_ALL=C LANG=C
  df -h / | tail -1
  free -m | head -2
  FREE_KB=$(df --output=avail / | tail -1)
  [ "$FREE_KB" -gt 4194304 ] || { echo "Zu wenig Plattenplatz (<4GB frei). Abbruch."; exit 1; }
'

# ---------------------------------------------------------------------------
# 4. SearxNG + Vane im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere SearxNG im Container (echtes SearXNG von GitHub + gunicorn, 127.0.0.1:${SEARXNG_PORT}) ..."
# ACHTUNG: In diesem Block sind KEINE einfachen Anführungszeichen erlaubt –
# sie würden den äußeren bash -c Block der Host-Shell sprengen.
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export LC_ALL=C LANG=C
  echo "--- Phase S1: Systempakete ---"
  apt-get update
  apt-get install -y git curl ca-certificates build-essential python3 python3-venv python3-pip openssl libxml2-dev libxslt1-dev zlib1g-dev
  id searx >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /opt/searxng searx
  echo "--- Phase S2: SearXNG-Quellcode (github.com/searxng/searxng) ---"
  if [ ! -d /opt/searxng-src/.git ]; then
    rm -rf /opt/searxng-src
    git clone --depth 1 https://github.com/searxng/searxng /opt/searxng-src
  else
    git -C /opt/searxng-src pull --ff-only
  fi
  test -f /opt/searxng-src/searx/webapp.py
  echo "--- Phase S2b: settings.yml (Secret nur beim ersten Lauf) ---"
  # settings.yml MUSS vor dem Import-Check existieren: searx.webapp
  # verweigert mit sys.exit(1) jedes Default-Secret (ultrasecretkey).
  if [ ! -f /etc/searxng/settings.yml ]; then
    mkdir -p /etc/searxng
    SECRET_KEY=$(openssl rand -hex 24)
    cat > /etc/searxng/settings.yml <<YAML
use_default_settings: true
server:
  secret_key: "${SECRET_KEY}"
  bind_address: "127.0.0.1"
  port: 8080
search:
  formats:
    - html
    - json
engines:
  - name: wolframalpha
    disabled: false
YAML
  fi
  chmod 640 /etc/searxng/settings.yml
  chown -R searx:searx /etc/searxng
  echo "--- Phase S3: venv + SearXNG-Install ---"
  export SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml
  if ! /opt/searxng-venv/bin/python -c "import searx.webapp" >/dev/null 2>&1; then
    rm -rf /opt/searxng-venv
    python3 -m venv /opt/searxng-venv
    /opt/searxng-venv/bin/pip install --upgrade pip setuptools wheel
    /opt/searxng-venv/bin/pip install -r /opt/searxng-src/requirements.txt
    /opt/searxng-venv/bin/pip install --no-build-isolation --no-deps /opt/searxng-src gunicorn
  fi
  /opt/searxng-venv/bin/python -c "import searx.webapp; print(\"searx-modul ok\")"
  chown -R searx:searx /opt/searxng-venv
'
pct exec "$CT_ID" -- test -f /etc/searxng/settings.yml \
  || { msg_error "SearxNG-Config fehlt: /etc/searxng/settings.yml."; exit 1; }
msg_ok "SearxNG installiert (JSON-Format + Wolfram Alpha aktiviert)."

msg_info "Installiere Node 20 + Vane im Container (nativ, ohne Docker) ..."
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export LC_ALL=C LANG=C
  echo "--- Phase V1: Node 20 ---"
  if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh
    bash /tmp/nodesource_setup.sh
    rm -f /tmp/nodesource_setup.sh
    apt-get install -y nodejs
  fi
  node --version
  npm --version
  echo "--- Phase V2: Vane-Checkout ---"
  id vane >/dev/null 2>&1 || useradd -m -s /bin/bash vane
  if [ ! -d /opt/vane/.git ]; then
    rm -rf /opt/vane
    mkdir -p /opt/vane
    chown vane:vane /opt/vane
    su -s /bin/bash vane -c "git clone https://github.com/ItzCrazyKns/Vane /opt/vane"
  else
    su -s /bin/bash vane -c "git -C /opt/vane pull --ff-only"
  fi
  test -f /opt/vane/package.json
  echo "--- Phase V3: Build (yarn, wie Upstream-Dockerfile) ---"
  export NODE_OPTIONS=--max-old-space-size=1536
  if ! command -v yarn >/dev/null 2>&1; then
    npm install -g yarn
  fi
  yarn --version
  if [ -f /opt/vane/yarn.lock ]; then
    su -s /bin/bash vane -c "cd /opt/vane && yarn install --frozen-lockfile --network-timeout 600000 && yarn build"
  elif [ -f /opt/vane/package-lock.json ]; then
    su -s /bin/bash vane -c "cd /opt/vane && npm ci --no-audit --no-fund && npm run build"
  else
    su -s /bin/bash vane -c "cd /opt/vane && npm install --no-audit --no-fund --legacy-peer-deps && npm run build"
  fi
  echo "--- Phasen V1-V3 ok ---"
'
# Host-seitiger Guard: bricht laut ab, falls der Checkout/Build fehlt.
pct exec "$CT_ID" -- test -f /opt/vane/package.json \
  || { msg_error "Checkout unvollstaendig: /opt/vane/package.json fehlt im Container."; exit 1; }
pct exec "$CT_ID" -- test -d /opt/vane/.next \
  || { msg_error "Build unvollstaendig: /opt/vane/.next fehlt (npm run build)."; exit 1; }
msg_ok "Vane gebaut (Node $(pct exec "$CT_ID" -- node --version 2>/dev/null || echo "?"))."

# systemd-Units aus diesem Repo übernehmen (fällt auf Inline-Unit zurück)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/searxng.service "$SEARXNG_UNIT_URL" 2>/dev/null; then
  msg_ok "searxng.service aus Repo übernommen."
else
  msg_warn "SearxNG-Unit-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/searxng.service <<UNIT
[Unit]
Description=SearxNG – lokale Metasuchmaschine (fuer Vane)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=searx
Group=searx
Environment=SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/searxng-venv/bin/gunicorn --bind 127.0.0.1:${SEARXNG_PORT} -k gthread --workers 2 --threads 4 --timeout 120 searx.webapp:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi

if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/vane.service "$VANE_UNIT_URL" 2>/dev/null; then
  msg_ok "vane.service aus Repo übernommen."
else
  msg_warn "Vane-Unit-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/vane.service <<UNIT
[Unit]
Description=Vane – AI answering engine (Next.js, nativ)
After=network-online.target searxng.service
Wants=network-online.target

[Service]
Type=simple
User=vane
Group=vane
WorkingDirectory=/opt/vane
Environment=NODE_ENV=production
Environment=PORT=${APP_PORT}
Environment=HOSTNAME=0.0.0.0
Environment=SEARXNG_API_URL=http://127.0.0.1:${SEARXNG_PORT}
ExecStart=/usr/bin/npm run start
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi

pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  chown -R vane:vane /opt/vane
  mkdir -p /opt/vane/data
  chown -R vane:vane /opt/vane/data
  systemctl daemon-reload
  systemctl enable --now searxng
  systemctl enable --now vane
'

# ---------------------------------------------------------------------------
# 5. Verifikation: Services + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active searxng || { msg_error "systemd-Service searxng ist nicht active."; pct exec "$CT_ID" -- systemctl status searxng --no-pager || true; pct exec "$CT_ID" -- journalctl -u searxng --no-pager -n 100 || true; exit 1; }
msg_ok "SearxNG läuft (systemctl is-active searxng = active)."

pct exec "$CT_ID" -- systemctl is-active vane || { msg_error "systemd-Service vane ist nicht active."; pct exec "$CT_ID" -- systemctl status vane --no-pager || true; pct exec "$CT_ID" -- journalctl -u vane --no-pager -n 100 || true; exit 1; }
msg_ok "Vane-Service läuft (systemctl is-active vane = active)."

msg_info "Warte auf SearxNG (max. 2 Min) ..."
SEARX_OK=0
for _ in $(seq 1 12); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${SEARXNG_PORT}/" >/dev/null 2>&1; then SEARX_OK=1; break; fi
  sleep 10
done
[[ "$SEARX_OK" == "1" ]] \
  || { msg_error "SearxNG antwortet nicht auf localhost:${SEARXNG_PORT}/."; pct exec "$CT_ID" -- journalctl -u searxng --no-pager -n 100 || true; exit 1; }
msg_ok "SearxNG antwortet (HTTP 200 auf localhost:${SEARXNG_PORT}/)."

msg_info "Warte auf Web UI (max. 4 Min – Next.js-Start braucht beim ersten Mal länger) ..."
WEB_OK=0
for _ in $(seq 1 24); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${APP_PORT}/" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/."; pct exec "$CT_ID" -- systemctl status vane --no-pager || true; pct exec "$CT_ID" -- journalctl -u vane --no-pager -n 100 || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/)."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Vane – privacy-fokussierte AI-Antwortmaschine"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  Setup        : LLM-API-Keys im Setup-Screen eintragen;"
echo "                 SearxNG-URL dort: http://127.0.0.1:${SEARXNG_PORT} (lokal im CT)"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unverändert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status vane searxng  (im Container via: pct enter $CT_ID)"
echo "  Update       : Skript erneut laufen lassen (idempotent, git pull + rebuild)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
