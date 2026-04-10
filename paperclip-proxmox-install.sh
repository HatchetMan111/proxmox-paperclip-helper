#!/bin/bash

# ============================================================
#  Paperclip AI — Proxmox All-in-One Installer
#  Läuft auf dem PROXMOX HOST (nicht in der VM!)
#  Erstellt automatisch eine Ubuntu VM + installiert Paperclip
#
#  by HatchetMan111 | github.com/HatchetMan111
# ============================================================

set -euo pipefail

# ── Farben ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Hilfsfunktionen ──────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[FEHLER]${NC} $*"; exit 1; }

step() {
  echo ""
  echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${YELLOW}  $*${NC}"
  echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── Banner ───────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat <<'EOF'
 ____                             _ _       
|  _ \ __ _ _ __   ___ _ __ ___| (_)_ __  
| |_) / _` | '_ \ / _ \ '__/ __| | | '_ \ 
|  __/ (_| | |_) |  __/ | | (__| | | |_) |
|_|   \__,_| .__/ \___|_|  \___|_|_| .__/ 
            |_|                     |_|    
  Proxmox All-in-One Installer
  VM erstellen + Paperclip AI installieren
  by HatchetMan111 | github.com/HatchetMan111
EOF
echo -e "${NC}"

# ── Proxmox-Host prüfen ──────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
  error "Bitte als root auf dem PROXMOX HOST ausführen!"
fi

if ! command -v qm &>/dev/null; then
  error "Kein 'qm' gefunden – dieses Script muss auf dem Proxmox-HOST laufen, nicht in einer VM!"
fi

if ! command -v pvesh &>/dev/null; then
  error "Kein 'pvesh' gefunden – bitte auf dem Proxmox-HOST ausführen."
fi

# ── Voraussetzungen prüfen ───────────────────────────────────
step "Voraussetzungen prüfen"

for cmd in wget ssh-keygen sshpass curl; do
  if ! command -v "$cmd" &>/dev/null; then
    info "$cmd wird installiert..."
    apt-get install -y -qq "$cmd" 2>/dev/null || true
  fi
done

# sshpass ggf. nachinstallieren
if ! command -v sshpass &>/dev/null; then
  apt-get install -y sshpass
fi

success "Alle Voraussetzungen erfüllt."

# ─────────────────────────────────────────────────────────────
#  KONFIGURATION — hier kannst du Werte anpassen
# ─────────────────────────────────────────────────────────────
step "Konfiguration"

# Freie VM-ID ermitteln (ab 200 aufwärts)
VM_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
# Falls nextid zu niedrig, mindestens 200
if [[ "$VM_ID" -lt 200 ]]; then VM_ID=200; fi

VM_NAME="paperclip-ai"
VM_RAM=4096          # MB — min. 4096, empfohlen 8192
VM_CORES=2           # CPU Kerne
VM_DISK_SIZE=20      # GB
VM_BRIDGE="vmbr0"    # Netzwerk-Bridge (Standard Proxmox)
VM_STORAGE=""        # wird automatisch ermittelt
UBUNTU_VERSION="24.04"
UBUNTU_CODENAME="noble"
PAPERCLIP_PORT=3100

# Root-Passwort für die VM (temporär für Installation)
VM_ROOT_PASS="PaperclipSetup$(date +%s | sha256sum | head -c 8)"

# ── Storage ermitteln ────────────────────────────────────────
info "Verfügbaren Storage ermitteln..."

# Ersten lokalen Storage mit Disk-Support finden
VM_STORAGE=$(pvesm status --content images 2>/dev/null \
  | awk 'NR>1 && $3=="active" {print $1; exit}')

if [[ -z "$VM_STORAGE" ]]; then
  # Fallback: 'local-lvm' oder 'local'
  if pvesm status 2>/dev/null | grep -q "local-lvm"; then
    VM_STORAGE="local-lvm"
  elif pvesm status 2>/dev/null | grep -q "^local "; then
    VM_STORAGE="local"
  else
    error "Kein geeigneter Storage gefunden. Bitte manuell in diesem Script angeben (VM_STORAGE=...)."
  fi
fi

# Ubuntu Cloud-Image Pfad (auf Proxmox liegt es im local storage)
ISO_STORAGE="local"
CLOUD_IMG_NAME="ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_VERSION}/release/${CLOUD_IMG_NAME}"
CLOUD_IMG_PATH="/var/lib/vz/snippets"
SNIPPETS_DIR="/var/lib/vz/snippets"

# ── Zusammenfassung anzeigen ─────────────────────────────────
echo ""
echo -e "${BOLD}  Geplante Konfiguration:${NC}"
echo -e "  VM-ID:        ${CYAN}${VM_ID}${NC}"
echo -e "  VM-Name:      ${CYAN}${VM_NAME}${NC}"
echo -e "  RAM:          ${CYAN}${VM_RAM} MB${NC}"
echo -e "  CPU:          ${CYAN}${VM_CORES} Kerne${NC}"
echo -e "  Disk:         ${CYAN}${VM_DISK_SIZE} GB${NC}"
echo -e "  Storage:      ${CYAN}${VM_STORAGE}${NC}"
echo -e "  Bridge:       ${CYAN}${VM_BRIDGE}${NC}"
echo -e "  Ubuntu:       ${CYAN}${UBUNTU_VERSION} LTS (${UBUNTU_CODENAME})${NC}"
echo -e "  Paperclip:    ${CYAN}Port ${PAPERCLIP_PORT}${NC}"
echo ""
read -rp "  Fortfahren? [J/n]: " CONFIRM
CONFIRM="${CONFIRM:-j}"
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || error "Abgebrochen."

# ─────────────────────────────────────────────────────────────
step "Schritt 1/7 — Ubuntu Cloud-Image herunterladen"
# ─────────────────────────────────────────────────────────────

IMG_DIR="/var/lib/vz/template/iso"
mkdir -p "$IMG_DIR"
LOCAL_IMG="$IMG_DIR/$CLOUD_IMG_NAME"

if [[ -f "$LOCAL_IMG" ]]; then
  success "Cloud-Image bereits vorhanden: $LOCAL_IMG"
else
  info "Lade Ubuntu ${UBUNTU_VERSION} Cloud-Image herunter..."
  info "URL: $CLOUD_IMG_URL"
  wget -q --show-progress -O "$LOCAL_IMG" "$CLOUD_IMG_URL"
  success "Cloud-Image heruntergeladen."
fi

# ─────────────────────────────────────────────────────────────
step "Schritt 2/7 — Cloud-Init Snippet erstellen"
# ─────────────────────────────────────────────────────────────

# Snippets auf local storage aktivieren falls nötig
if ! pvesm status | grep -q "^local " ; then
  warn "Local Storage nicht gefunden – Snippets werden direkt erstellt."
fi

# Snippet-Verzeichnis sicherstellen
mkdir -p "$SNIPPETS_DIR"

# Prüfen ob local storage Snippets unterstützt
if ! pvesm status 2>/dev/null | grep "^local " | grep -q "snippets"; then
  info "Snippets-Support auf local storage aktivieren..."
  pvesm set local --content snippets,iso,backup,images,rootdir 2>/dev/null || true
fi

SNIPPET_FILE="${SNIPPETS_DIR}/paperclip-cloudinit.yaml"

info "Cloud-Init User-Data erstellen..."
cat > "$SNIPPET_FILE" <<CLOUDINIT
#cloud-config
hostname: paperclip-ai
manage_etc_hosts: true
fqdn: paperclip-ai.local

users:
  - name: root
    lock_passwd: false
    hashed_passwd: "$(echo "$VM_ROOT_PASS" | openssl passwd -6 -stdin)"

chpasswd:
  expire: false

ssh_pwauth: true

package_update: true
package_upgrade: true
packages:
  - curl
  - git
  - wget
  - ca-certificates
  - gnupg
  - lsb-release
  - build-essential
  - ufw

runcmd:
  - echo "Cloud-Init Setup abgeschlossen" > /root/cloudinit-done.txt
  - systemctl enable ssh
  - systemctl start ssh

final_message: "Ubuntu VM für Paperclip AI ist bereit!"
CLOUDINIT

success "Cloud-Init Snippet erstellt: $SNIPPET_FILE"

# ─────────────────────────────────────────────────────────────
step "Schritt 3/7 — VM erstellen"
# ─────────────────────────────────────────────────────────────

# Alte VM mit gleicher ID entfernen falls vorhanden
if qm status "$VM_ID" &>/dev/null; then
  warn "VM ${VM_ID} existiert bereits. Wird gestoppt und gelöscht..."
  qm stop "$VM_ID" --skiplock 2>/dev/null || true
  sleep 3
  qm destroy "$VM_ID" --purge 2>/dev/null || true
  sleep 2
fi

info "VM ${VM_ID} wird erstellt..."

qm create "$VM_ID" \
  --name "$VM_NAME" \
  --memory "$VM_RAM" \
  --cores "$VM_CORES" \
  --cpu "host" \
  --net0 "virtio,bridge=${VM_BRIDGE}" \
  --ostype "l26" \
  --machine "q35" \
  --bios "seabios" \
  --scsihw "virtio-scsi-pci" \
  --serial0 "socket" \
  --vga "serial0" \
  --onboot 1 \
  --agent "enabled=1" \
  --description "Paperclip AI Server | installiert via HatchetMan111/proxmox-paperclip-helper"

success "VM ${VM_ID} erstellt."

# ── Disk importieren ─────────────────────────────────────────
info "Cloud-Image als Disk importieren..."
qm importdisk "$VM_ID" "$LOCAL_IMG" "$VM_STORAGE" --format qcow2 2>&1 | tail -3

# Disk bestimmen (lvm → kein Format-Suffix, dir → .qcow2)
if [[ "$VM_STORAGE" == *"lvm"* ]] || pvesm status 2>/dev/null | grep "^${VM_STORAGE}" | grep -q "lvmthin\|lvm"; then
  DISK_REF="${VM_STORAGE}:vm-${VM_ID}-disk-0"
else
  DISK_REF="${VM_STORAGE}:${VM_ID}/vm-${VM_ID}-disk-0.qcow2"
fi

# Disk als scsi0 anhängen
qm set "$VM_ID" --scsi0 "${VM_STORAGE}:vm-${VM_ID}-disk-0"

# Disk-Größe anpassen
qm resize "$VM_ID" scsi0 "${VM_DISK_SIZE}G"

# Boot-Reihenfolge
qm set "$VM_ID" --boot "order=scsi0"

# Cloud-Init Drive hinzufügen
qm set "$VM_ID" \
  --ide2 "${VM_STORAGE}:cloudinit" \
  --cicustom "user=local:snippets/paperclip-cloudinit.yaml" \
  --ipconfig0 "ip=dhcp"

success "Disk konfiguriert (${VM_DISK_SIZE}GB)."

# ─────────────────────────────────────────────────────────────
step "Schritt 4/7 — VM starten"
# ─────────────────────────────────────────────────────────────

info "VM ${VM_ID} wird gestartet..."
qm start "$VM_ID"

# Warten bis VM bootet und Cloud-Init fertig ist
info "Warte auf VM-Boot und Cloud-Init (max. 3 Minuten)..."
BOOT_TIMEOUT=180
ELAPSED=0

while [[ $ELAPSED -lt $BOOT_TIMEOUT ]]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))

  # IP via QEMU Guest Agent versuchen
  VM_IP=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for iface in data:
        if iface.get('name','') in ('lo',''):
            continue
        for addr in iface.get('ip-addresses', []):
            if addr.get('ip-address-type') == 'ipv4' and not addr['ip-address'].startswith('127.'):
                print(addr['ip-address'])
                sys.exit(0)
except:
    pass
" 2>/dev/null || true)

  if [[ -n "$VM_IP" ]]; then
    success "VM IP-Adresse gefunden: ${VM_IP}"
    break
  fi

  # Fortschritt anzeigen
  printf "\r  ${CYAN}Warte... ${ELAPSED}/${BOOT_TIMEOUT} Sek.${NC}   "
done
echo ""

# Fallback: IP aus Proxmox DHCP-Leases
if [[ -z "$VM_IP" ]]; then
  warn "Guest Agent hat keine IP gemeldet – versuche Fallback..."
  VM_IP=$(grep -i "paperclip\|${VM_ID}" /var/lib/misc/dnsmasq.leases 2>/dev/null \
    | awk '{print $3}' | head -1 || true)
fi

# Zweiter Fallback: ARP scan
if [[ -z "$VM_IP" ]]; then
  info "ARP-Tabelle wird geprüft..."
  sleep 10
  VM_MAC=$(qm config "$VM_ID" 2>/dev/null | grep "net0" | grep -oP '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' || true)
  if [[ -n "$VM_MAC" ]]; then
    VM_IP=$(arp -an 2>/dev/null | grep -i "$VM_MAC" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
  fi
fi

if [[ -z "$VM_IP" ]]; then
  warn "IP-Adresse konnte nicht automatisch ermittelt werden."
  echo -e "  ${YELLOW}Bitte IP manuell aus der Proxmox-Konsole ablesen und eingeben:${NC}"
  read -rp "  VM IP-Adresse: " VM_IP
  [[ -n "$VM_IP" ]] || error "Keine IP angegeben – Abbruch."
fi

# Zusätzliche Wartezeit für SSH-Dienst
info "Warte auf SSH-Dienst (30 Sek.)..."
sleep 30

# SSH-Verfügbarkeit prüfen
info "Prüfe SSH-Verbindung zu ${VM_IP}..."
SSH_OK=false
for i in $(seq 1 20); do
  if ssh -o StrictHostKeyChecking=no \
         -o ConnectTimeout=5 \
         -o BatchMode=yes \
         -o PasswordAuthentication=no \
         root@"$VM_IP" true 2>/dev/null; then
    SSH_OK=true
    break
  fi
  if sshpass -p "$VM_ROOT_PASS" ssh \
       -o StrictHostKeyChecking=no \
       -o ConnectTimeout=5 \
       root@"$VM_IP" true 2>/dev/null; then
    SSH_OK=true
    break
  fi
  sleep 5
  printf "\r  SSH-Versuch ${i}/20..."
done
echo ""

[[ "$SSH_OK" == true ]] || error "Keine SSH-Verbindung zu ${VM_IP} möglich. Prüfe die VM-Konsole in Proxmox."
success "SSH-Verbindung erfolgreich."

# ─────────────────────────────────────────────────────────────
step "Schritt 5/7 — Paperclip in der VM installieren"
# ─────────────────────────────────────────────────────────────

info "Sende Installations-Script an VM und starte es..."

# Inline-Installationsscript als Heredoc (wird per SSH in die VM geschickt)
INSTALL_SCRIPT=$(cat <<'INNERSCRIPT'
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PAPERCLIP_TELEMETRY_DISABLED=1

echo "▶ System aktualisieren..."
apt-get update -qq
apt-get upgrade -y -qq

echo "▶ Pakete installieren..."
apt-get install -y -qq \
  curl git wget gnupg ca-certificates lsb-release \
  software-properties-common build-essential ufw

echo "▶ Node.js 20 installieren..."
NODE_OK=false
if command -v node &>/dev/null; then
  NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
  [[ "$NODE_VER" -ge 20 ]] && NODE_OK=true
fi
if [[ "$NODE_OK" == false ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
  apt-get install -y -qq nodejs
fi
echo "  Node.js $(node -v) bereit."

echo "▶ pnpm installieren..."
npm install -g pnpm --quiet 2>/dev/null
export PNPM_HOME="/root/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"
echo 'export PNPM_HOME="/root/.local/share/pnpm"' >> /root/.bashrc
echo 'export PATH="$PNPM_HOME:$PATH"' >> /root/.bashrc
echo "  pnpm $(pnpm -v) bereit."

echo "▶ Paperclip klonen..."
INSTALL_DIR="/opt/paperclip"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  cd "$INSTALL_DIR" && git pull --quiet
else
  rm -rf "$INSTALL_DIR"
  git clone --depth=1 https://github.com/paperclipai/paperclip.git "$INSTALL_DIR" --quiet
fi
cd "$INSTALL_DIR"

echo "▶ Dependencies installieren (dauert 2-5 Min.)..."
pnpm install --frozen-lockfile 2>&1 | tail -3 || pnpm install 2>&1 | tail -3

echo "▶ .env erstellen..."
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  [[ -f "$INSTALL_DIR/.env.example" ]] \
    && cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env" \
    || touch "$INSTALL_DIR/.env"
fi
grep -q "PAPERCLIP_TELEMETRY_DISABLED" "$INSTALL_DIR/.env" \
  || echo "PAPERCLIP_TELEMETRY_DISABLED=1" >> "$INSTALL_DIR/.env"

echo "▶ systemd Service einrichten..."
PNPM_BIN=$(which pnpm 2>/dev/null || echo "/root/.local/share/pnpm/pnpm")
cat > /etc/systemd/system/paperclip.service <<SVCEOF
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
RestartSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=paperclip
Environment=NODE_ENV=production
Environment=PAPERCLIP_TELEMETRY_DISABLED=1
Environment=PNPM_HOME=/root/.local/share/pnpm
Environment=PATH=/root/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EnvironmentFile=-${INSTALL_DIR}/.env

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable paperclip --quiet
systemctl start paperclip

echo "▶ Firewall konfigurieren..."
ufw allow 3100/tcp --quiet 2>/dev/null || true
ufw allow 22/tcp --quiet 2>/dev/null || true
ufw --force enable 2>/dev/null || true

echo "PAPERCLIP_INSTALL_DONE" > /root/paperclip-install-status.txt
echo "▶ Installation in VM abgeschlossen!"
INNERSCRIPT
)

# Script per SSH in die VM übertragen und ausführen
sshpass -p "$VM_ROOT_PASS" ssh \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=10 \
  root@"$VM_IP" \
  "bash -s" <<< "$INSTALL_SCRIPT"

success "Paperclip in VM installiert."

# ─────────────────────────────────────────────────────────────
step "Schritt 6/7 — Installation in VM prüfen"
# ─────────────────────────────────────────────────────────────

info "Prüfe ob Paperclip Service läuft..."
sleep 10

STATUS=$(sshpass -p "$VM_ROOT_PASS" ssh \
  -o StrictHostKeyChecking=no \
  root@"$VM_IP" \
  "systemctl is-active paperclip 2>/dev/null || echo 'unknown'" 2>/dev/null || echo "ssh-error")

if [[ "$STATUS" == "active" ]]; then
  success "Paperclip Service ist aktiv!"
elif [[ "$STATUS" == "activating" ]]; then
  success "Paperclip Service startet (activating) — normal beim ersten Boot."
else
  warn "Service-Status: ${STATUS}"
  warn "Paperclip startet möglicherweise noch. Prüfe mit:"
  warn "  ssh root@${VM_IP} 'journalctl -u paperclip -f'"
fi

# Installationsstatus prüfen
DONE=$(sshpass -p "$VM_ROOT_PASS" ssh \
  -o StrictHostKeyChecking=no \
  root@"$VM_IP" \
  "cat /root/paperclip-install-status.txt 2>/dev/null || echo 'NOT_FOUND'" 2>/dev/null || echo "error")

[[ "$DONE" == *"DONE"* ]] && success "Installations-Check bestanden." \
  || warn "Status-Datei nicht gefunden – Installation möglicherweise unvollständig."

# ─────────────────────────────────────────────────────────────
step "Schritt 7/7 — SSH-Key einrichten (optional)"
# ─────────────────────────────────────────────────────────────

info "Richte SSH-Key-Login ein (kein Passwort mehr nötig)..."

# SSH-Key des Proxmox-Hosts kopieren
if [[ -f /root/.ssh/id_rsa.pub ]] || [[ -f /root/.ssh/id_ed25519.pub ]]; then
  PUB_KEY=$(cat /root/.ssh/id_ed25519.pub 2>/dev/null || cat /root/.ssh/id_rsa.pub 2>/dev/null)
  sshpass -p "$VM_ROOT_PASS" ssh \
    -o StrictHostKeyChecking=no \
    root@"$VM_IP" \
    "mkdir -p /root/.ssh && echo '$PUB_KEY' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" 2>/dev/null && \
    success "SSH-Key eingerichtet. Du kannst dich ohne Passwort verbinden." || \
    warn "SSH-Key konnte nicht eingerichtet werden – kein Problem, Passwort-Login funktioniert weiterhin."
else
  info "Kein SSH-Key auf dem Proxmox-Host gefunden – übersprungen."
  info "SSH-Passwort für die VM: ${VM_ROOT_PASS}"
fi

# ─────────────────────────────────────────────────────────────
#  ABSCHLUSS
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   ✅  PAPERCLIP AI VOLLSTÄNDIG INSTALLIERT!          ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║                                                      ║${NC}"
echo -e "${BOLD}${GREEN}║  🖥️   VM-ID:         ${VM_ID}                               ║${NC}"
echo -e "${BOLD}${GREEN}║  📛  VM-Name:       ${VM_NAME}                    ║${NC}"
echo -e "${BOLD}${GREEN}║  🌐  VM-IP:         ${VM_IP}                      ║${NC}"
echo -e "${BOLD}${GREEN}║                                                      ║${NC}"
echo -e "${BOLD}${CYAN}║  🚀  Paperclip URL:                                  ║${NC}"
echo -e "${BOLD}${CYAN}║      http://${VM_IP}:${PAPERCLIP_PORT}                      ║${NC}"
echo -e "${BOLD}${GREEN}║                                                      ║${NC}"
echo -e "${BOLD}${GREEN}║  🔑  SSH-Zugang:                                     ║${NC}"
echo -e "${BOLD}${GREEN}║      ssh root@${VM_IP}                        ║${NC}"
echo -e "${BOLD}${GREEN}║      Passwort: ${VM_ROOT_PASS}             ║${NC}"
echo -e "${BOLD}${GREEN}║                                                      ║${NC}"
echo -e "${BOLD}${GREEN}║  📋  Nützliche Befehle (auf der VM):                 ║${NC}"
echo -e "${BOLD}${GREEN}║  systemctl status paperclip                          ║${NC}"
echo -e "${BOLD}${GREEN}║  journalctl -u paperclip -f   (Live-Log)             ║${NC}"
echo -e "${BOLD}${GREEN}║  systemctl restart paperclip                         ║${NC}"
echo -e "${BOLD}${GREEN}║                                                      ║${NC}"
echo -e "${BOLD}${GREEN}║  📁  Paperclip:     /opt/paperclip                   ║${NC}"
echo -e "${BOLD}${GREEN}║  ⚙️   Config:        /opt/paperclip/.env              ║${NC}"
echo -e "${BOLD}${GREEN}║                                                      ║${NC}"
echo -e "${BOLD}${GREEN}║  📖  Docs: https://paperclip.ing/docs                ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}Hinweis:${NC} Beim ersten Start lädt Paperclip die Datenbank."
echo -e "  Bitte 30-60 Sekunden warten, dann die URL im Browser öffnen."
echo ""
echo -e "  ${YELLOW}Passwort notieren!${NC} Danach kannst du es in der VM ändern:"
echo -e "  ${CYAN}passwd root${NC}"
echo ""
