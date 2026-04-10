#!/bin/bash

# ============================================================
#  Paperclip AI — Proxmox VM Installer
#  by HatchetMan111 | github.com/HatchetMan111
# ============================================================
# Dieses Script installiert Paperclip AI vollautomatisch
# auf einer frischen Ubuntu 22.04 / 24.04 VM auf Proxmox VE.
# Einfach auf der VM ausführen – kein manueller Eingriff nötig.
# ============================================================

set -euo pipefail

# ── Farben ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Hilfsfunktionen ─────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

step() {
  echo ""
  echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${YELLOW}  $*${NC}"
  echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── Banner ──────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat <<'EOF'
 ____                             _ _       
|  _ \ __ _ _ __   ___ _ __ ___| (_)_ __  
| |_) / _` | '_ \ / _ \ '__/ __| | | '_ \ 
|  __/ (_| | |_) |  __/ | | (__| | | |_) |
|_|   \__,_| .__/ \___|_|  \___|_|_| .__/ 
            |_|                     |_|    
  AI Orchestration — Proxmox VM Installer
  by HatchetMan111 | github.com/HatchetMan111
EOF
echo -e "${NC}"
echo -e "  Installiert Paperclip AI vollautomatisch auf dieser VM."
echo -e "  Quelle: ${CYAN}https://github.com/paperclipai/paperclip${NC}"
echo ""

# ── Root-Check ──────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  error "Bitte als root ausführen: sudo bash paperclip-install.sh"
fi

# ── Betriebssystem prüfen ───────────────────────────────────
step "Schritt 1/8 — Betriebssystem prüfen"
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  info "Erkannt: $PRETTY_NAME"
  if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    warn "Dieses Script wurde für Ubuntu/Debian entwickelt."
    warn "Andere Systeme könnten abweichen – fortfahren auf eigene Gefahr."
    read -rp "Trotzdem fortfahren? [j/N]: " confirm
    [[ "$confirm" =~ ^[jJyY]$ ]] || error "Abgebrochen."
  fi
else
  error "Betriebssystem konnte nicht erkannt werden."
fi

# ── System aktualisieren ────────────────────────────────────
step "Schritt 2/8 — System aktualisieren & Abhängigkeiten installieren"
info "apt update läuft..."
apt-get update -qq
info "apt upgrade läuft (kann etwas dauern)..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

info "Grundpakete installieren..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl \
  git \
  wget \
  gnupg \
  ca-certificates \
  lsb-release \
  software-properties-common \
  build-essential \
  ufw \
  systemd
success "System aktualisiert und Grundpakete installiert."

# ── Node.js installieren ────────────────────────────────────
step "Schritt 3/8 — Node.js 20 installieren"

# Prüfen ob Node.js bereits installiert und aktuell genug ist
NODE_OK=false
if command -v node &>/dev/null; then
  NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
  if [[ "$NODE_VERSION" -ge 20 ]]; then
    success "Node.js $(node -v) bereits installiert – überspringe."
    NODE_OK=true
  else
    warn "Node.js $(node -v) gefunden, aber Version 20+ benötigt. Wird aktualisiert..."
  fi
fi

if [[ "$NODE_OK" == false ]]; then
  info "NodeSource Repository hinzufügen..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
  info "Node.js 20 installieren..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  success "Node.js $(node -v) installiert."
fi

# npm aktuell halten
info "npm aktualisieren..."
npm install -g npm@latest --quiet 2>/dev/null || true

# ── pnpm installieren ───────────────────────────────────────
step "Schritt 4/8 — pnpm 9.15+ installieren"

# Prüfen ob pnpm bereits vorhanden und aktuell genug
PNPM_OK=false
if command -v pnpm &>/dev/null; then
  PNPM_MAJOR=$(pnpm -v | cut -d. -f1)
  PNPM_MINOR=$(pnpm -v | cut -d. -f2)
  if [[ "$PNPM_MAJOR" -ge 10 ]] || [[ "$PNPM_MAJOR" -eq 9 && "$PNPM_MINOR" -ge 15 ]]; then
    success "pnpm $(pnpm -v) bereits installiert – überspringe."
    PNPM_OK=true
  else
    warn "pnpm $(pnpm -v) gefunden, aber 9.15+ benötigt. Wird aktualisiert..."
  fi
fi

if [[ "$PNPM_OK" == false ]]; then
  info "pnpm via npm installieren..."
  npm install -g pnpm --quiet
  success "pnpm $(pnpm -v) installiert."
fi

# PATH für pnpm sicherstellen
export PNPM_HOME="/root/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"

# ── Paperclip klonen ────────────────────────────────────────
step "Schritt 5/8 — Paperclip herunterladen"

INSTALL_DIR="/opt/paperclip"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Paperclip bereits unter $INSTALL_DIR vorhanden – führe git pull aus..."
  cd "$INSTALL_DIR"
  git pull --quiet
  success "Repository aktualisiert."
else
  if [[ -d "$INSTALL_DIR" ]]; then
    warn "Verzeichnis $INSTALL_DIR existiert ohne Git – wird gelöscht und neu geklont..."
    rm -rf "$INSTALL_DIR"
  fi
  info "Klone paperclipai/paperclip nach $INSTALL_DIR ..."
  git clone --depth=1 https://github.com/paperclipai/paperclip.git "$INSTALL_DIR" --quiet
  success "Repository geklont."
fi

cd "$INSTALL_DIR"

# ── Dependencies installieren ───────────────────────────────
step "Schritt 6/8 — Node-Dependencies installieren (pnpm install)"
info "Dies kann 2–5 Minuten dauern..."
pnpm install --frozen-lockfile 2>&1 | tail -5 || pnpm install 2>&1 | tail -5
success "Alle Abhängigkeiten installiert."

# ── .env erstellen ──────────────────────────────────────────
step "Schritt 7/8 — Konfiguration (.env) erstellen"

if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  if [[ -f "$INSTALL_DIR/.env.example" ]]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    info ".env aus .env.example erstellt."
  else
    # Minimalconfig anlegen
    cat > "$INSTALL_DIR/.env" <<'ENVEOF'
# Paperclip .env — automatisch erstellt durch Installer
NODE_ENV=production
PAPERCLIP_TELEMETRY_DISABLED=1
ENVEOF
    info "Minimal-.env erstellt."
  fi
  # Telemetrie standardmäßig deaktivieren
  if ! grep -q "PAPERCLIP_TELEMETRY_DISABLED" "$INSTALL_DIR/.env"; then
    echo "PAPERCLIP_TELEMETRY_DISABLED=1" >> "$INSTALL_DIR/.env"
  fi
  success ".env Datei bereit."
else
  info ".env bereits vorhanden – wird nicht überschrieben."
  # Telemetrie trotzdem deaktivieren wenn nicht gesetzt
  if ! grep -q "PAPERCLIP_TELEMETRY_DISABLED" "$INSTALL_DIR/.env"; then
    echo "PAPERCLIP_TELEMETRY_DISABLED=1" >> "$INSTALL_DIR/.env"
    info "Telemetrie in bestehender .env deaktiviert."
  fi
fi

# ── systemd Service einrichten ──────────────────────────────
step "Schritt 8/8 — Autostart via systemd einrichten"

# Pfade für pnpm ermitteln
PNPM_BIN=$(which pnpm 2>/dev/null || echo "/root/.local/share/pnpm/pnpm")
NODE_BIN=$(which node)

info "systemd Service wird erstellt..."
cat > /etc/systemd/system/paperclip.service <<SERVICEEOF
[Unit]
Description=Paperclip AI Orchestration Server
Documentation=https://github.com/paperclipai/paperclip
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${PNPM_BIN} dev
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=paperclip
Environment=NODE_ENV=production
Environment=PAPERCLIP_TELEMETRY_DISABLED=1
Environment=PATH=/root/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EnvironmentFile=-${INSTALL_DIR}/.env

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable paperclip --quiet
info "Paperclip Service wird gestartet..."
systemctl start paperclip

# Warten bis Service läuft
info "Warte auf Paperclip Start (max. 30 Sek.)..."
for i in $(seq 1 30); do
  if systemctl is-active --quiet paperclip; then
    success "Paperclip Service läuft!"
    break
  fi
  if [[ $i -eq 30 ]]; then
    warn "Service hat sich noch nicht gemeldet – prüfe Status manuell:"
    warn "  systemctl status paperclip"
    warn "  journalctl -u paperclip -f"
  fi
  sleep 1
done

# ── Firewall ─────────────────────────────────────────────────
info "Firewall: Port 3100 freigeben..."
if command -v ufw &>/dev/null; then
  ufw allow 3100/tcp --quiet 2>/dev/null || true
  ufw --force enable 2>/dev/null || true
fi

# ── IP ermitteln ─────────────────────────────────────────────
IP=""
# Mehrere Methoden probieren
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$IP" ]]; then
  IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+')
fi
if [[ -z "$IP" ]]; then
  IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
fi
if [[ -z "$IP" ]]; then
  IP="<IP-der-VM>"
fi

# ── Abschluss ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   ✅  PAPERCLIP ERFOLGREICH INSTALLIERT!          ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║                                                  ║${NC}"
echo -e "${BOLD}${GREEN}║  🌐  Weboberfläche:                              ║${NC}"
echo -e "${BOLD}${GREEN}║                                                  ║${NC}"
echo -e "${BOLD}${CYAN}║      http://${IP}:3100                  ║${NC}"
echo -e "${BOLD}${GREEN}║                                                  ║${NC}"
echo -e "${BOLD}${GREEN}║  📋  Nützliche Befehle:                          ║${NC}"
echo -e "${BOLD}${GREEN}║  systemctl status paperclip                      ║${NC}"
echo -e "${BOLD}${GREEN}║  journalctl -u paperclip -f   (Live-Log)         ║${NC}"
echo -e "${BOLD}${GREEN}║  systemctl restart paperclip                     ║${NC}"
echo -e "${BOLD}${GREEN}║                                                  ║${NC}"
echo -e "${BOLD}${GREEN}║  📁  Installationspfad:  /opt/paperclip          ║${NC}"
echo -e "${BOLD}${GREEN}║  ⚙️   Konfiguration:      /opt/paperclip/.env     ║${NC}"
echo -e "${BOLD}${GREEN}║                                                  ║${NC}"
echo -e "${BOLD}${GREEN}║  📖  Docs: https://paperclip.ing/docs            ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}Hinweis:${NC} Beim ersten Start lädt Paperclip die eingebettete"
echo -e "  Datenbank – das kann 30-60 Sekunden dauern."
echo -e "  Einfach kurz warten, dann die URL im Browser öffnen."
echo ""
