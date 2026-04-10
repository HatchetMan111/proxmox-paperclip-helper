#!/bin/bash

# ============================================================
#  Paperclip AI — Proxmox All-in-One Installer v2
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
cat <<'BANNER'
 ____                             _ _       
|  _ \ __ _ _ __   ___ _ __ ___| (_)_ __  
| |_) / _` | '_ \ / _ \ '__/ __| | | '_ \ 
|  __/ (_| | |_) |  __/ | | (__| | | |_) |
|_|   \__,_| .__/ \___|_|  \___|_|_| .__/ 
            |_|                     |_|    
  Proxmox All-in-One Installer v2
  VM erstellen + Paperclip AI installieren
  by HatchetMan111 | github.com/HatchetMan111
BANNER
echo -e "${NC}"

# ── Proxmox-Host prüfen ──────────────────────────────────────
[[ "$EUID" -ne 0 ]]           && error "Bitte als root auf dem PROXMOX HOST ausführen!"
! command -v qm &>/dev/null   && error "'qm' nicht gefunden – Script muss auf dem Proxmox HOST laufen!"
! command -v pvesh &>/dev/null && error "'pvesh' nicht gefunden – Script muss auf dem Proxmox HOST laufen!"

# ── Abhängigkeiten installieren ──────────────────────────────
step "Voraussetzungen prüfen & installieren"

apt-get update -qq 2>/dev/null
for pkg in wget curl openssh-client python3; do
  if ! dpkg -l "$pkg" &>/dev/null; then
    info "$pkg wird installiert..."
    apt-get install -y -qq "$pkg" 2>/dev/null || true
  fi
done
success "Voraussetzungen erfüllt."

# ─────────────────────────────────────────────────────────────
#  KONFIGURATION
# ─────────────────────────────────────────────────────────────
step "Konfiguration"

VM_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
[[ "$VM_ID" -lt 200 ]] && VM_ID=200

VM_NAME="paperclip-ai"
VM_RAM=4096
VM_CORES=2
VM_DISK_SIZE=20
VM_BRIDGE="vmbr0"
# Ubuntu 22.04: stabilster Stand für Cloud-Init + qemu-guest-agent
UBUNTU_VERSION="22.04"
PAPERCLIP_PORT=3100
SSH_KEY_PATH="/root/.ssh/paperclip_vm_ed25519"
SNIPPETS_DIR="/var/lib/vz/snippets"
IMG_DIR="/var/lib/vz/template/iso"
CLOUD_IMG_NAME="ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_VERSION}/release/${CLOUD_IMG_NAME}"

# Storage automatisch ermitteln
VM_STORAGE=$(pvesm status --content images 2>/dev/null \
  | awk 'NR>1 && $3=="active" {print $1; exit}' || true)

if [[ -z "$VM_STORAGE" ]]; then
  if pvesm status 2>/dev/null | grep -q "local-lvm"; then
    VM_STORAGE="local-lvm"
  elif pvesm status 2>/dev/null | grep -q "^local "; then
    VM_STORAGE="local"
  else
    error "Kein Storage gefunden. Bitte VM_STORAGE manuell im Script setzen."
  fi
fi

echo ""
echo -e "${BOLD}  Geplante Konfiguration:${NC}"
echo -e "  VM-ID:     ${CYAN}${VM_ID}${NC}"
echo -e "  VM-Name:   ${CYAN}${VM_NAME}${NC}"
echo -e "  RAM:       ${CYAN}${VM_RAM} MB${NC}"
echo -e "  CPU:       ${CYAN}${VM_CORES} Kerne${NC}"
echo -e "  Disk:      ${CYAN}${VM_DISK_SIZE} GB${NC}"
echo -e "  Storage:   ${CYAN}${VM_STORAGE}${NC}"
echo -e "  Bridge:    ${CYAN}${VM_BRIDGE}${NC}"
echo -e "  Ubuntu:    ${CYAN}${UBUNTU_VERSION} LTS${NC}"
echo -e "  Port:      ${CYAN}${PAPERCLIP_PORT}${NC}"
echo ""
read -rp "  Fortfahren? [J/n]: " CONFIRM
CONFIRM="${CONFIRM:-j}"
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || error "Abgebrochen."

# ─────────────────────────────────────────────────────────────
step "Schritt 1/7 — SSH-Key generieren"
# ─────────────────────────────────────────────────────────────
# SSH-Key wird VOR der VM-Erstellung generiert und direkt in
# Cloud-Init eingebettet. Kein Passwort, kein sshpass nötig.

mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [[ -f "$SSH_KEY_PATH" ]]; then
  info "SSH-Key bereits vorhanden – wird wiederverwendet."
else
  info "Generiere SSH-Key für VM-Zugang..."
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "paperclip-installer" -q
  success "SSH-Key generiert: $SSH_KEY_PATH"
fi

SSH_PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")
success "Public Key: ${SSH_PUB_KEY:0:40}..."

# ─────────────────────────────────────────────────────────────
step "Schritt 2/7 — Ubuntu Cloud-Image herunterladen"
# ─────────────────────────────────────────────────────────────

mkdir -p "$IMG_DIR"
LOCAL_IMG="$IMG_DIR/$CLOUD_IMG_NAME"

if [[ -f "$LOCAL_IMG" ]]; then
  success "Cloud-Image bereits vorhanden – überspringe Download."
else
  info "Lade Ubuntu ${UBUNTU_VERSION} Cloud-Image herunter..."
  wget --progress=bar:force -O "$LOCAL_IMG" "$CLOUD_IMG_URL" 2>&1 || \
    error "Download fehlgeschlagen. Prüfe Internetverbindung."
  success "Cloud-Image heruntergeladen: $LOCAL_IMG"
fi

# ─────────────────────────────────────────────────────────────
step "Schritt 3/7 — Cloud-Init Snippet erstellen"
# ─────────────────────────────────────────────────────────────

mkdir -p "$SNIPPETS_DIR"

# Snippets-Support auf local storage aktivieren
CURRENT_CONTENT=$(pvesm status 2>/dev/null | awk '/^local / {print $6}' || true)
if [[ "$CURRENT_CONTENT" != *"snippets"* ]]; then
  info "Aktiviere Snippets-Support auf local storage..."
  pvesm set local --content "snippets,iso,backup,images,rootdir" 2>/dev/null || true
fi

SNIPPET_FILE="${SNIPPETS_DIR}/paperclip-cloudinit.yaml"
info "Erstelle Cloud-Init User-Data mit SSH-Key..."

# WICHTIG:
# - qemu-guest-agent: PFLICHT für automatische IP-Erkennung durch Proxmox
# - ssh_authorized_keys: Key direkt eingebettet → kein Passwort-Login nötig
# - package_upgrade: false → spart Boot-Zeit, Updates kommen später
cat > "$SNIPPET_FILE" <<CLOUDINIT
#cloud-config
hostname: paperclip-ai
manage_etc_hosts: true
fqdn: paperclip-ai.local

users:
  - name: root
    lock_passwd: true
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}

ssh_pwauth: false

packages:
  - qemu-guest-agent
  - openssh-server
  - curl
  - git
  - wget
  - ca-certificates
  - gnupg
  - lsb-release
  - build-essential
  - ufw

package_update: true
package_upgrade: false

runcmd:
  - mkdir -p /root/.ssh
  - chmod 700 /root/.ssh
  - echo "${SSH_PUB_KEY}" > /root/.ssh/authorized_keys
  - chmod 600 /root/.ssh/authorized_keys
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - systemctl enable ssh
  - systemctl start ssh
  - echo "CLOUDINIT_DONE" > /root/cloudinit-status.txt

final_message: "Paperclip VM bereit!"
CLOUDINIT

success "Cloud-Init Snippet erstellt: $SNIPPET_FILE"

# ─────────────────────────────────────────────────────────────
step "Schritt 4/7 — VM erstellen & konfigurieren"
# ─────────────────────────────────────────────────────────────

# Bestehende VM mit gleicher ID bereinigen
if qm status "$VM_ID" &>/dev/null; then
  warn "VM ${VM_ID} existiert bereits – wird gestoppt und gelöscht..."
  qm stop "$VM_ID" --skiplock 2>/dev/null || true
  sleep 5
  qm destroy "$VM_ID" --purge 2>/dev/null || true
  sleep 3
fi

info "Erstelle VM ${VM_ID} (${VM_NAME})..."
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
  --agent "enabled=1,fstrim_cloned_disks=1" \
  --description "Paperclip AI | github.com/HatchetMan111/-proxmox-paperclip-helper"

success "VM Basis erstellt."

info "Importiere Cloud-Image als Disk in ${VM_STORAGE}..."
IMPORT_OUT=$(qm importdisk "$VM_ID" "$LOCAL_IMG" "$VM_STORAGE" --format qcow2 2>&1)
echo "$IMPORT_OUT" | tail -5

# Disk-Referenz direkt aus importdisk-Output lesen.
# "unused0: successfully imported disk 'local:200/vm-200-disk-0.qcow2'"
# → wir extrahieren alles zwischen den einfachen Anführungszeichen
DISK_REF=$(echo "$IMPORT_OUT" \
  | grep -oP "(?<=')[^']+(?=')" \
  | grep -v "^$" | tail -1 || true)

# Fallback: aus qm config lesen (unused0-Zeile)
if [[ -z "$DISK_REF" ]]; then
  sleep 2
  DISK_REF=$(qm config "$VM_ID" 2>/dev/null \
    | grep "^unused0:" \
    | awk '{print $2}' || true)
fi

[[ -z "$DISK_REF" ]] && error "Disk-Referenz konnte nicht ermittelt werden.\nPrüfe: qm config ${VM_ID}"

info "Disk-Referenz: ${DISK_REF}"

info "Konfiguriere Boot, Cloud-Init & Disk..."
qm set "$VM_ID" \
  --scsi0 "${DISK_REF},discard=on" \
  --boot "order=scsi0" \
  --ide2 "${VM_STORAGE}:cloudinit" \
  --cicustom "user=local:snippets/paperclip-cloudinit.yaml" \
  --ipconfig0 "ip=dhcp" \
  --sshkeys "${SSH_KEY_PATH}.pub"

info "Vergrößere Disk auf ${VM_DISK_SIZE}GB..."
qm resize "$VM_ID" scsi0 "${VM_DISK_SIZE}G"

success "VM vollständig konfiguriert (ID: ${VM_ID})."

# ─────────────────────────────────────────────────────────────
step "Schritt 5/7 — VM starten & IP ermitteln"
# ─────────────────────────────────────────────────────────────

info "Starte VM ${VM_ID}..."
qm start "$VM_ID"

VM_IP=""
MAX_WAIT=300  # 5 Minuten: Cloud-Init mit package_update braucht Zeit

info "Warte auf QEMU Guest Agent + IP-Adresse..."
info "(Cloud-Init installiert Pakete inkl. qemu-guest-agent — bitte ~90 Sek. warten)"
echo ""

for i in $(seq 1 $MAX_WAIT); do
  sleep 1

  # Methode 1: QEMU Guest Agent — direkte IP-Abfrage
  VM_IP=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for iface in data:
        name = iface.get('name','')
        # Loopback, Docker, Bridge-Interfaces überspringen
        skip = ['lo','docker','br-','virbr','veth']
        if any(name.startswith(s) for s in skip):
            continue
        for addr in iface.get('ip-addresses', []):
            if addr.get('ip-address-type') == 'ipv4':
                ip = addr['ip-address']
                # Loopback und Link-Local ignorieren
                if not ip.startswith('127.') and not ip.startswith('169.254.'):
                    print(ip)
                    sys.exit(0)
except Exception:
    pass
" 2>/dev/null || true)

  if [[ -n "$VM_IP" ]]; then
    echo ""
    success "IP via QEMU Guest Agent gefunden: ${VM_IP}"
    break
  fi

  # Fortschrittsbalken
  if (( i % 15 == 0 )); then
    printf "\r  ${CYAN}[%3d/%d Sek.]${NC} Warte auf Guest Agent + IP...    " "$i" "$MAX_WAIT"
  fi
done
echo ""

# Methode 2: MAC → DHCP Lease / ARP
if [[ -z "$VM_IP" ]]; then
  info "Fallback: Suche IP über MAC-Adresse..."

  VM_MAC=$(qm config "$VM_ID" 2>/dev/null \
    | grep -i "^net0" \
    | grep -oiP '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
    | head -1 | tr '[:upper:]' '[:lower:]' || true)

  if [[ -n "$VM_MAC" ]]; then
    info "VM MAC: $VM_MAC"

    # dnsmasq Leases
    for f in /var/lib/misc/dnsmasq.leases /var/lib/dnsmasq/dnsmasq.leases; do
      [[ -f "$f" ]] && VM_IP=$(grep -i "$VM_MAC" "$f" | awk '{print $3}' | head -1 || true)
      [[ -n "$VM_IP" ]] && break
    done

    # ARP-Tabelle
    if [[ -z "$VM_IP" ]]; then
      sleep 5
      VM_IP=$(arp -an 2>/dev/null \
        | grep -i "$VM_MAC" \
        | grep -oP '\d+\.\d+\.\d+\.\d+' \
        | head -1 || true)
    fi

    # ip neigh
    if [[ -z "$VM_IP" ]]; then
      VM_IP=$(ip neigh 2>/dev/null \
        | grep -i "$VM_MAC" \
        | grep -oP '\d+\.\d+\.\d+\.\d+' \
        | head -1 || true)
    fi
  fi
fi

# Manuell fragen als letzter Ausweg
if [[ -z "$VM_IP" ]]; then
  echo ""
  warn "Automatische IP-Erkennung fehlgeschlagen."
  echo -e "  ${YELLOW}→ Öffne Proxmox Weboberfläche → VM ${VM_ID} → Konsole${NC}"
  echo -e "  ${YELLOW}→ Warte bis Login erscheint, dann: ip addr show${NC}"
  echo ""
  read -rp "  VM IP-Adresse eingeben: " VM_IP
  [[ -n "$VM_IP" ]] || error "Keine IP angegeben – Abbruch."
fi

# ── SSH-Verbindung warten ─────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ${SSH_KEY_PATH}"
SSH_OK=false

info "Warte auf SSH an ${VM_IP} (max. 3 Min.)..."
for i in $(seq 1 36); do
  if ssh $SSH_OPTS root@"$VM_IP" "echo ok" &>/dev/null 2>&1; then
    SSH_OK=true
    break
  fi
  printf "\r  ${CYAN}SSH-Versuch %d/36...${NC}  " "$i"
  sleep 5
done
echo ""

if [[ "$SSH_OK" == false ]]; then
  warn "SSH noch nicht bereit – warte weitere 90 Sek. (Cloud-Init läuft noch)..."
  sleep 90
  ssh $SSH_OPTS root@"$VM_IP" "echo ok" &>/dev/null 2>&1 \
    && SSH_OK=true \
    || error "SSH nicht erreichbar.\nManuelle Verbindung: ssh -i ${SSH_KEY_PATH} root@${VM_IP}"
fi

success "SSH-Verbindung zu ${VM_IP} erfolgreich!"

# ─────────────────────────────────────────────────────────────
step "Schritt 6/7 — Paperclip in der VM installieren"
# ─────────────────────────────────────────────────────────────

info "Starte Paperclip-Installation auf ${VM_IP}..."

# Heredoc mit einfachen Anführungszeichen → keine lokale Variable-Expansion
ssh $SSH_OPTS root@"$VM_IP" 'bash -s' << 'REMOTE_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PAPERCLIP_TELEMETRY_DISABLED=1

echo ""
echo "==> [1/6] System-Pakete aktualisieren..."
apt-get update -qq
apt-get install -y -qq \
  curl git wget gnupg ca-certificates lsb-release \
  software-properties-common build-essential ufw

echo "==> [2/6] Node.js 20 installieren..."
if command -v node &>/dev/null; then
  NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
  if [[ "$NODE_VER" -ge 20 ]]; then
    echo "    Node.js $(node -v) bereits vorhanden – überspringe."
  else
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
    apt-get install -y -qq nodejs
  fi
else
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
  apt-get install -y -qq nodejs
fi
echo "    Node.js $(node -v) bereit."

echo "==> [3/6] pnpm installieren..."
npm install -g pnpm --quiet 2>/dev/null || npm install -g pnpm
export PNPM_HOME="/root/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"

# Dauerhaft in Shell-Profile eintragen
grep -q "PNPM_HOME" /root/.bashrc 2>/dev/null || cat >> /root/.bashrc << 'BASHEOF'
export PNPM_HOME="/root/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"
BASHEOF
grep -q "PNPM_HOME" /root/.profile 2>/dev/null || cat >> /root/.profile << 'PROFEOF'
export PNPM_HOME="/root/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"
PROFEOF

echo "    pnpm $(pnpm -v) bereit."

echo "==> [4/6] Paperclip klonen..."
if [[ -d /opt/paperclip/.git ]]; then
  cd /opt/paperclip && git pull --quiet
  echo "    Aktualisiert: $(git log --oneline -1)"
else
  rm -rf /opt/paperclip
  git clone --depth=1 https://github.com/paperclipai/paperclip.git /opt/paperclip --quiet
  echo "    Geklont: $(cd /opt/paperclip && git log --oneline -1)"
fi

echo "==> [5/6] Dependencies installieren (2-5 Min.)..."
cd /opt/paperclip
pnpm install --frozen-lockfile 2>&1 | tail -5 || pnpm install 2>&1 | tail -5

echo "==> [6/6] Dienst & Firewall konfigurieren..."

# .env erstellen
if [[ ! -f /opt/paperclip/.env ]]; then
  [[ -f /opt/paperclip/.env.example ]] \
    && cp /opt/paperclip/.env.example /opt/paperclip/.env \
    || touch /opt/paperclip/.env
fi
grep -q "PAPERCLIP_TELEMETRY_DISABLED" /opt/paperclip/.env \
  || echo "PAPERCLIP_TELEMETRY_DISABLED=1" >> /opt/paperclip/.env

# pnpm-Pfad ermitteln
PNPM_BIN=$(which pnpm 2>/dev/null || echo "/root/.local/share/pnpm/pnpm")

# systemd Service
cat > /etc/systemd/system/paperclip.service << SVCEOF
[Unit]
Description=Paperclip AI Orchestration Server
Documentation=https://github.com/paperclipai/paperclip
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/paperclip
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
EnvironmentFile=-/opt/paperclip/.env

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable paperclip --quiet
systemctl start paperclip

# Firewall
ufw allow 22/tcp   --quiet 2>/dev/null || true
ufw allow 3100/tcp --quiet 2>/dev/null || true
ufw --force enable         2>/dev/null || true

echo "PAPERCLIP_INSTALL_DONE" > /root/paperclip-install-status.txt
echo ""
echo "    Installation in VM erfolgreich abgeschlossen!"
REMOTE_SCRIPT

success "Paperclip erfolgreich in VM installiert."

# ─────────────────────────────────────────────────────────────
step "Schritt 7/7 — Dienst prüfen"
# ─────────────────────────────────────────────────────────────

sleep 10
STATUS=$(ssh $SSH_OPTS root@"$VM_IP" \
  "systemctl is-active paperclip 2>/dev/null || echo unknown" 2>/dev/null || echo "ssh-error")

case "$STATUS" in
  active)     success "Paperclip Service: aktiv ✓" ;;
  activating) success "Paperclip Service: startet – normal beim ersten Start ✓" ;;
  *)          warn    "Service-Status: ${STATUS} — prüfe: journalctl -u paperclip -f" ;;
esac

DONE=$(ssh $SSH_OPTS root@"$VM_IP" \
  "cat /root/paperclip-install-status.txt 2>/dev/null || echo NOT_FOUND" 2>/dev/null || echo "error")
[[ "$DONE" == *"DONE"* ]] \
  && success "Installations-Check: bestanden ✓" \
  || warn "Status-Datei nicht gefunden – Installation evtl. unvollständig."

# ─────────────────────────────────────────────────────────────
#  ABSCHLUSS
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   ✅  PAPERCLIP AI VOLLSTÄNDIG INSTALLIERT!              ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
printf  "${BOLD}${GREEN}║  🖥️   VM-ID:     %-42s║${NC}\n" "$VM_ID"
printf  "${BOLD}${GREEN}║  📛  VM-Name:   %-42s║${NC}\n" "$VM_NAME"
printf  "${BOLD}${GREEN}║  🌐  VM-IP:     %-42s║${NC}\n" "$VM_IP"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${CYAN}║  🚀  Paperclip öffnen im Browser:                        ║${NC}"
printf  "${BOLD}${CYAN}║      http://%-47s║${NC}\n" "${VM_IP}:${PAPERCLIP_PORT}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  🔑  SSH-Zugang (ohne Passwort):                         ║${NC}"
printf  "${BOLD}${GREEN}║      ssh -i %-47s║${NC}\n" "${SSH_KEY_PATH} root@${VM_IP}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  📋  Nützliche Befehle auf der VM:                       ║${NC}"
echo -e "${BOLD}${GREEN}║      systemctl status paperclip                          ║${NC}"
echo -e "${BOLD}${GREEN}║      journalctl -u paperclip -f    (Live-Log)            ║${NC}"
echo -e "${BOLD}${GREEN}║      systemctl restart paperclip                         ║${NC}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  📁  Paperclip:  /opt/paperclip                          ║${NC}"
echo -e "${BOLD}${GREEN}║  ⚙️   Config:     /opt/paperclip/.env                     ║${NC}"
echo -e "${BOLD}${GREEN}║  📖  Docs:       https://paperclip.ing/docs              ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}Hinweis:${NC} Beim ersten Start lädt Paperclip seine Datenbank."
echo -e "  Bitte 30-60 Sek. warten, dann URL im Browser öffnen."
echo ""
echo -e "  ${YELLOW}SSH-Key liegt auf deinem Proxmox-Host:${NC}"
echo -e "  ${CYAN}${SSH_KEY_PATH}${NC}"
echo ""
