#!/bin/bash

# ============================================================
#  Paperclip AI — Proxmox All-in-One Installer v3
#  Läuft auf dem PROXMOX HOST (nicht in der VM!)
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
  Proxmox All-in-One Installer v3
  VM erstellen + Paperclip AI installieren
  by HatchetMan111 | github.com/HatchetMan111
BANNER
echo -e "${NC}"

# ── Proxmox-Host prüfen ──────────────────────────────────────
[[ "$EUID" -ne 0 ]]            && error "Bitte als root auf dem PROXMOX HOST ausführen!"
! command -v qm    &>/dev/null && error "'qm' nicht gefunden – Script muss auf dem Proxmox HOST laufen!"
! command -v pvesh &>/dev/null && error "'pvesh' nicht gefunden – Script muss auf dem Proxmox HOST laufen!"

# ── Abhängigkeiten ────────────────────────────────────────────
step "Voraussetzungen prüfen"
apt-get update -qq 2>/dev/null
for pkg in wget curl openssh-client python3 whois; do
  dpkg -l "$pkg" &>/dev/null || apt-get install -y -qq "$pkg" 2>/dev/null || true
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
UBUNTU_VERSION="22.04"
PAPERCLIP_PORT=3100
SSH_KEY_PATH="/root/.ssh/paperclip_vm_ed25519"
SNIPPETS_DIR="/var/lib/vz/snippets"
IMG_DIR="/var/lib/vz/template/iso"
CLOUD_IMG_NAME="ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_VERSION}/release/${CLOUD_IMG_NAME}"

# Storage ermitteln — local-lvm bevorzugen (robust), sonst local
if pvesm status 2>/dev/null | awk 'NR>1' | grep -q "local-lvm"; then
  VM_STORAGE="local-lvm"
elif pvesm status 2>/dev/null | awk 'NR>1' | grep -q "^local "; then
  VM_STORAGE="local"
else
  VM_STORAGE=$(pvesm status --content images 2>/dev/null \
    | awk 'NR>1 && $3=="active" {print $1; exit}' || true)
  [[ -z "$VM_STORAGE" ]] && error "Kein Storage gefunden. Bitte VM_STORAGE manuell setzen."
fi

# Storage-Typ ermitteln (lvmthin, dir, zfspool ...)
STORAGE_TYPE=$(pvesm status 2>/dev/null \
  | awk -v s="$VM_STORAGE" '$1==s {print $2}' || echo "dir")

echo ""
echo -e "${BOLD}  Geplante Konfiguration:${NC}"
echo -e "  VM-ID:        ${CYAN}${VM_ID}${NC}"
echo -e "  VM-Name:      ${CYAN}${VM_NAME}${NC}"
echo -e "  RAM:          ${CYAN}${VM_RAM} MB${NC}"
echo -e "  CPU:          ${CYAN}${VM_CORES} Kerne${NC}"
echo -e "  Disk:         ${CYAN}${VM_DISK_SIZE} GB${NC}"
echo -e "  Storage:      ${CYAN}${VM_STORAGE} (${STORAGE_TYPE})${NC}"
echo -e "  Bridge:       ${CYAN}${VM_BRIDGE}${NC}"
echo -e "  Ubuntu:       ${CYAN}${UBUNTU_VERSION} LTS${NC}"
echo -e "  Paperclip:    ${CYAN}Port ${PAPERCLIP_PORT}${NC}"
echo ""
read -rp "  Fortfahren? [J/n]: " CONFIRM
CONFIRM="${CONFIRM:-j}"
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || error "Abgebrochen."

# ─────────────────────────────────────────────────────────────
step "Schritt 1/7 — SSH-Key generieren"
# ─────────────────────────────────────────────────────────────
mkdir -p /root/.ssh && chmod 700 /root/.ssh

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  info "Generiere SSH-Key..."
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "paperclip-installer" -q
fi

SSH_PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")
success "SSH-Key bereit."

# ─────────────────────────────────────────────────────────────
step "Schritt 2/7 — Ubuntu Cloud-Image herunterladen"
# ─────────────────────────────────────────────────────────────
mkdir -p "$IMG_DIR"
LOCAL_IMG="$IMG_DIR/$CLOUD_IMG_NAME"

if [[ -f "$LOCAL_IMG" ]]; then
  success "Cloud-Image bereits vorhanden – überspringe Download."
else
  info "Lade Ubuntu ${UBUNTU_VERSION} Cloud-Image..."
  wget --progress=bar:force -O "$LOCAL_IMG" "$CLOUD_IMG_URL" 2>&1 \
    || error "Download fehlgeschlagen. Prüfe Internetverbindung."
  success "Cloud-Image heruntergeladen."
fi

# ─────────────────────────────────────────────────────────────
step "Schritt 3/7 — Cloud-Init Snippet erstellen"
# ─────────────────────────────────────────────────────────────
mkdir -p "$SNIPPETS_DIR"

# Snippets auf local aktivieren
if ! pvesm status 2>/dev/null | awk '/^local /{print $6}' | grep -q "snippets"; then
  info "Aktiviere Snippets auf local storage..."
  pvesm set local --content "snippets,iso,backup,images,rootdir" 2>/dev/null || true
fi

# Root-Passwort hashen (mkpasswd aus whois-Paket)
VM_ROOT_PASS="Paperclip$(openssl rand -hex 6)"
HASHED_PW=$(echo "$VM_ROOT_PASS" | mkpasswd --method=SHA-512 --stdin 2>/dev/null \
  || openssl passwd -6 "$VM_ROOT_PASS")

SNIPPET_FILE="${SNIPPETS_DIR}/paperclip-cloudinit.yaml"

cat > "$SNIPPET_FILE" << CLOUDINIT
#cloud-config
hostname: paperclip-ai
manage_etc_hosts: true
fqdn: paperclip-ai.local

# Root direkt konfigurieren — kein extra User
users:
  - name: root
    lock_passwd: false
    hashed_passwd: "${HASHED_PW}"
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}

# Passwort-Login über SSH erlauben (Fallback)
ssh_pwauth: true

# Nur essentielle Pakete — kein package_upgrade (zu langsam)
packages:
  - qemu-guest-agent
  - openssh-server

package_update: true
package_upgrade: false

# Dienste starten + SSH absichern
runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now ssh
  - mkdir -p /root/.ssh
  - chmod 700 /root/.ssh
  - echo "${SSH_PUB_KEY}" > /root/.ssh/authorized_keys
  - chmod 600 /root/.ssh/authorized_keys
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
  - echo "CLOUDINIT_DONE" > /root/cloudinit-status.txt

final_message: "Paperclip VM bereit! Cloud-Init abgeschlossen nach \$UPTIME Sekunden."
CLOUDINIT

success "Cloud-Init Snippet erstellt."

# ─────────────────────────────────────────────────────────────
step "Schritt 4/7 — VM erstellen & konfigurieren"
# ─────────────────────────────────────────────────────────────

# Bestehende VM bereinigen
if qm status "$VM_ID" &>/dev/null; then
  warn "VM ${VM_ID} existiert bereits – wird gelöscht..."
  qm stop "$VM_ID" --skiplock 2>/dev/null || true
  sleep 5
  qm destroy "$VM_ID" --purge 2>/dev/null || true
  sleep 3
fi

info "Erstelle VM ${VM_ID}..."

# WICHTIG: Kein --serial0 / --vga serial0 für Cloud-Image VMs!
# Das verursacht "starting serial terminal on interface serial0"
# und blockiert die normale Konsole.
# Cloud-Images brauchen: --vga std (oder qxl)
qm create "$VM_ID" \
  --name      "$VM_NAME" \
  --memory    "$VM_RAM" \
  --cores     "$VM_CORES" \
  --cpu       "host" \
  --net0      "virtio,bridge=${VM_BRIDGE}" \
  --ostype    "l26" \
  --machine   "q35" \
  --bios      "seabios" \
  --scsihw    "virtio-scsi-pci" \
  --vga       "std" \
  --onboot    1 \
  --agent     "enabled=1,fstrim_cloned_disks=1" \
  --description "Paperclip AI | github.com/HatchetMan111/-proxmox-paperclip-helper"

success "VM erstellt."

# ── Disk importieren & Referenz ermitteln ─────────────────────
info "Importiere Cloud-Image als Disk (${VM_STORAGE})..."

IMPORT_OUTPUT=$(qm importdisk "$VM_ID" "$LOCAL_IMG" "$VM_STORAGE" --format qcow2 2>&1)
echo "$IMPORT_OUTPUT" | tail -3

# Disk-Referenz aus Output extrahieren
# Mögliche Formate je nach Storage-Typ:
#   dir/file:  "local:200/vm-200-disk-0.qcow2"
#   lvm:       "local-lvm:vm-200-disk-0"
DISK_REF=$(echo "$IMPORT_OUTPUT" \
  | grep -oP "(?<=imported disk ')[^']+" 2>/dev/null || true)

# Fallback: aus qm config lesen
if [[ -z "$DISK_REF" ]]; then
  sleep 2
  DISK_REF=$(qm config "$VM_ID" 2>/dev/null \
    | grep "^unused0:" | awk '{print $2}' || true)
fi

[[ -z "$DISK_REF" ]] && error "Disk-Referenz nicht ermittelbar. Prüfe: qm config ${VM_ID}"
info "Disk-Referenz: ${DISK_REF}"

# ── VM fertig konfigurieren ───────────────────────────────────
info "Konfiguriere Disk, Boot & Cloud-Init..."
qm set "$VM_ID" \
  --scsi0     "${DISK_REF},discard=on" \
  --boot      "order=scsi0" \
  --ide2      "${VM_STORAGE}:cloudinit" \
  --cicustom  "user=local:snippets/paperclip-cloudinit.yaml" \
  --ipconfig0 "ip=dhcp"

info "Setze SSH-Key in Proxmox Cloud-Init..."
# Datei muss für pvesh URL-encoded übergeben werden → direkt als Option
qm set "$VM_ID" --sshkeys "${SSH_KEY_PATH}.pub" 2>/dev/null || true

info "Vergrößere Disk auf ${VM_DISK_SIZE}GB..."
qm resize "$VM_ID" scsi0 "${VM_DISK_SIZE}G"

# Cloud-Init Image neu generieren
qm cloudinit update "$VM_ID" 2>/dev/null || true

success "VM vollständig konfiguriert."
info "Aktuelle VM-Konfiguration:"
qm config "$VM_ID"

# ─────────────────────────────────────────────────────────────
step "Schritt 5/7 — VM starten & IP ermitteln"
# ─────────────────────────────────────────────────────────────
info "Starte VM ${VM_ID}..."
qm start "$VM_ID"

VM_IP=""
info "Warte auf QEMU Guest Agent..."
info "(Cloud-Init installiert qemu-guest-agent — bitte ca. 60-120 Sek. warten)"
echo ""

# Warte bis Guest Agent meldet sich UND eine gültige IP liefert
for i in $(seq 1 360); do
  sleep 1

  VM_IP=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null \
    | python3 -c "
import sys, json
try:
    for iface in json.load(sys.stdin):
        n = iface.get('name','')
        if n == 'lo' or n.startswith(('docker','br-','veth','virbr')):
            continue
        for a in iface.get('ip-addresses',[]):
            if a.get('ip-address-type') == 'ipv4':
                ip = a['ip-address']
                if not ip.startswith(('127.','169.254.')):
                    print(ip); sys.exit(0)
except: pass
" 2>/dev/null || true)

  if [[ -n "$VM_IP" ]]; then
    echo ""
    success "IP via Guest Agent: ${VM_IP}"
    break
  fi

  # Fortschritt alle 10 Sek.
  (( i % 10 == 0 )) && \
    printf "\r  ${CYAN}[%3d/360 Sek.]${NC} Warte auf Guest Agent...   " "$i"
done
echo ""

# Fallback: MAC → ARP
if [[ -z "$VM_IP" ]]; then
  warn "Guest Agent hat keine IP geliefert. Versuche Fallbacks..."

  VM_MAC=$(qm config "$VM_ID" 2>/dev/null \
    | grep "^net0" \
    | grep -oiP '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
    | tr '[:upper:]' '[:lower:]' | head -1 || true)

  if [[ -n "$VM_MAC" ]]; then
    info "VM MAC: $VM_MAC"
    # dnsmasq
    for f in /var/lib/misc/dnsmasq.leases /var/lib/dnsmasq/dnsmasq.leases; do
      [[ -f "$f" ]] && VM_IP=$(grep -i "$VM_MAC" "$f" | awk '{print $3}' | head -1) && break
    done
    # ARP
    [[ -z "$VM_IP" ]] && VM_IP=$(arp -an 2>/dev/null \
      | grep -i "$VM_MAC" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
    # ip neigh
    [[ -z "$VM_IP" ]] && VM_IP=$(ip neigh 2>/dev/null \
      | grep -i "$VM_MAC" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
  fi
fi

# Manuell
if [[ -z "$VM_IP" ]]; then
  echo ""
  warn "Automatische IP-Erkennung fehlgeschlagen."
  echo -e "  ${YELLOW}→ Proxmox Weboberfläche → VM ${VM_ID} → Summary → IPs${NC}"
  echo -e "  ${YELLOW}→ oder in VM-Konsole: ip addr show${NC}"
  echo ""
  read -rp "  VM IP-Adresse manuell eingeben: " VM_IP
  [[ -n "$VM_IP" ]] || error "Keine IP angegeben."
fi

# ── SSH warten ────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ${SSH_KEY_PATH}"
SSH_OK=false

info "Warte auf SSH an ${VM_IP}..."
for i in $(seq 1 40); do
  if ssh $SSH_OPTS root@"$VM_IP" "echo ok" &>/dev/null; then
    SSH_OK=true; break
  fi
  printf "\r  ${CYAN}SSH-Versuch %2d/40...${NC}  " "$i"
  sleep 5
done
echo ""

if [[ "$SSH_OK" == false ]]; then
  warn "SSH noch nicht bereit. Warte weitere 60 Sek. (Cloud-Init läuft noch)..."
  sleep 60
  ssh $SSH_OPTS root@"$VM_IP" "echo ok" &>/dev/null \
    && SSH_OK=true \
    || error "SSH nicht erreichbar.\nManuelle Verbindung: ssh -i ${SSH_KEY_PATH} root@${VM_IP}"
fi

success "SSH-Verbindung zu ${VM_IP} erfolgreich!"

# ─────────────────────────────────────────────────────────────
step "Schritt 6/7 — Paperclip in der VM installieren"
# ─────────────────────────────────────────────────────────────
info "Starte Paperclip-Installation in der VM..."

ssh $SSH_OPTS root@"$VM_IP" 'bash -s' << 'REMOTE_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PAPERCLIP_TELEMETRY_DISABLED=1

echo ""
echo "==> [1/6] System-Pakete installieren..."
apt-get update -qq
apt-get install -y -qq \
  curl git wget gnupg ca-certificates lsb-release \
  software-properties-common build-essential ufw

echo "==> [2/6] Node.js 20 installieren..."
if command -v node &>/dev/null && [[ $(node -v | sed 's/v//' | cut -d. -f1) -ge 20 ]]; then
  echo "    Node.js $(node -v) bereits vorhanden."
else
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
  apt-get install -y -qq nodejs
fi
echo "    Node.js $(node -v) bereit."

echo "==> [3/6] pnpm installieren..."
npm install -g pnpm --quiet 2>/dev/null || npm install -g pnpm
export PNPM_HOME="/root/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"
grep -q "PNPM_HOME" /root/.bashrc 2>/dev/null || cat >> /root/.bashrc << 'BEOF'
export PNPM_HOME="/root/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"
BEOF
grep -q "PNPM_HOME" /root/.profile 2>/dev/null || cat >> /root/.profile << 'PEOF'
export PNPM_HOME="/root/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"
PEOF
echo "    pnpm $(pnpm -v) bereit."

echo "==> [4/6] Paperclip klonen..."
if [[ -d /opt/paperclip/.git ]]; then
  cd /opt/paperclip && git pull --quiet
else
  rm -rf /opt/paperclip
  git clone --depth=1 https://github.com/paperclipai/paperclip.git /opt/paperclip --quiet
fi
echo "    $(cd /opt/paperclip && git log --oneline -1)"

echo "==> [5/6] Dependencies installieren (2-5 Min.)..."
cd /opt/paperclip
pnpm install --frozen-lockfile 2>&1 | tail -5 || pnpm install 2>&1 | tail -5

echo "==> [6/6] Service & Firewall einrichten..."

# .env
if [[ ! -f /opt/paperclip/.env ]]; then
  [[ -f /opt/paperclip/.env.example ]] \
    && cp /opt/paperclip/.env.example /opt/paperclip/.env \
    || touch /opt/paperclip/.env
fi
grep -q "PAPERCLIP_TELEMETRY_DISABLED" /opt/paperclip/.env \
  || echo "PAPERCLIP_TELEMETRY_DISABLED=1" >> /opt/paperclip/.env

PNPM_BIN=$(which pnpm 2>/dev/null || echo "/root/.local/share/pnpm/pnpm")

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

ufw allow 22/tcp    --quiet 2>/dev/null || true
ufw allow 3100/tcp  --quiet 2>/dev/null || true
ufw --force enable          2>/dev/null || true

echo "PAPERCLIP_INSTALL_DONE" > /root/paperclip-install-status.txt
echo "    Fertig!"
REMOTE_SCRIPT

success "Paperclip in VM installiert."

# ─────────────────────────────────────────────────────────────
step "Schritt 7/7 — Dienst prüfen"
# ─────────────────────────────────────────────────────────────
sleep 10
STATUS=$(ssh $SSH_OPTS root@"$VM_IP" \
  "systemctl is-active paperclip 2>/dev/null || echo unknown" 2>/dev/null || echo "ssh-error")

case "$STATUS" in
  active)     success "Paperclip Service: aktiv ✓" ;;
  activating) success "Paperclip Service: startet – normal beim ersten Start ✓" ;;
  *)          warn    "Service-Status: ${STATUS}" ;;
esac

# ─────────────────────────────────────────────────────────────
#  ABSCHLUSS
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   ✅  PAPERCLIP AI VOLLSTÄNDIG INSTALLIERT!              ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
printf  "${BOLD}${GREEN}║  🖥️   VM-ID:     %-42s║${NC}\n" "$VM_ID"
printf  "${BOLD}${GREEN}║  🌐  VM-IP:     %-42s║${NC}\n" "$VM_IP"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${CYAN}║  🚀  Paperclip öffnen:                                   ║${NC}"
printf  "${BOLD}${CYAN}║      http://%-47s║${NC}\n" "${VM_IP}:${PAPERCLIP_PORT}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  🔑  SSH (Key):                                          ║${NC}"
printf  "${BOLD}${GREEN}║      ssh -i %-47s║${NC}\n" "${SSH_KEY_PATH} root@${VM_IP}"
printf  "${BOLD}${GREEN}║  🔑  SSH (Passwort): %-39s║${NC}\n" "$VM_ROOT_PASS"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  📋  Auf der VM:                                         ║${NC}"
echo -e "${BOLD}${GREEN}║      systemctl status paperclip                          ║${NC}"
echo -e "${BOLD}${GREEN}║      journalctl -u paperclip -f                          ║${NC}"
echo -e "${BOLD}${GREEN}║      systemctl restart paperclip                         ║${NC}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  📁  /opt/paperclip  |  ⚙️  /opt/paperclip/.env          ║${NC}"
echo -e "${BOLD}${GREEN}║  📖  https://paperclip.ing/docs                          ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}Passwort notieren:${NC} ${VM_ROOT_PASS}"
echo -e "  ${YELLOW}Danach ändern mit:${NC} passwd root  (in der VM)"
echo ""
echo -e "  ${YELLOW}Hinweis:${NC} Beim ersten Start lädt Paperclip seine Datenbank."
echo -e "  Bitte 30-60 Sek. warten, dann URL im Browser öffnen."
echo ""
