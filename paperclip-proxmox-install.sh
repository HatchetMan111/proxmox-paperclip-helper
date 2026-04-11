#!/bin/bash
# ============================================================
#  Paperclip AI — Proxmox All-in-One Installer
#  Ausführen auf dem PROXMOX HOST als root
#  by HatchetMan111 | github.com/HatchetMan111
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[FEHLER]${NC} $*"; exit 1; }
step()    { echo ""; echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}${YELLOW}  $*${NC}"; echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

clear
echo -e "${BOLD}${CYAN}"
cat <<'BANNER'
 ____                             _ _       
|  _ \ __ _ _ __   ___ _ __ ___| (_)_ __  
| |_) / _` | '_ \ / _ \ '__/ __| | | '_ \ 
|  __/ (_| | |_) |  __/ | | (__| | | |_) |
|_|   \__,_| .__/ \___|_|  \___|_|_| .__/ 
            |_|                     |_|    
  Proxmox All-in-One Installer
  by HatchetMan111 | github.com/HatchetMan111
BANNER
echo -e "${NC}"

# ── Proxmox Host prüfen ──────────────────────────────────────
[[ "$EUID" -ne 0 ]]            && error "Bitte als root auf dem PROXMOX HOST ausführen!"
! command -v qm    &>/dev/null && error "'qm' nicht gefunden — Script muss auf dem Proxmox HOST laufen!"
! command -v pvesh &>/dev/null && error "'pvesh' nicht gefunden — Script muss auf dem Proxmox HOST laufen!"

step "Schritt 1/7 — Voraussetzungen"
apt-get update -qq 2>/dev/null
for pkg in wget curl openssh-client python3 whois; do
  dpkg -l "$pkg" &>/dev/null || apt-get install -y -qq "$pkg" 2>/dev/null || true
done
success "Voraussetzungen OK"

# ── Konfiguration ────────────────────────────────────────────
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

# Storage ermitteln
if pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^local-lvm$"; then
  VM_STORAGE="local-lvm"
elif pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -q "^local$"; then
  VM_STORAGE="local"
else
  VM_STORAGE=$(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}' || true)
  [[ -z "$VM_STORAGE" ]] && error "Kein Storage gefunden."
fi

STORAGE_TYPE=$(pvesm status 2>/dev/null | awk -v s="$VM_STORAGE" '$1==s {print $2}')

echo -e "  VM-ID:     ${CYAN}${VM_ID}${NC}"
echo -e "  Storage:   ${CYAN}${VM_STORAGE} (${STORAGE_TYPE})${NC}"
echo -e "  Bridge:    ${CYAN}${VM_BRIDGE}${NC}"
echo -e "  RAM:       ${CYAN}${VM_RAM} MB${NC}  CPU: ${CYAN}${VM_CORES}${NC}  Disk: ${CYAN}${VM_DISK_SIZE}GB${NC}"
echo -e "  Ubuntu:    ${CYAN}${UBUNTU_VERSION} LTS${NC}  Port: ${CYAN}${PAPERCLIP_PORT}${NC}"
echo ""
read -rp "  Fortfahren? [J/n]: " CONFIRM
CONFIRM="${CONFIRM:-j}"
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || error "Abgebrochen."

# ── Schritt 2: SSH-Key ───────────────────────────────────────
step "Schritt 2/7 — SSH-Key generieren"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "paperclip-installer" -q
fi
SSH_PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")
success "SSH-Key bereit: ${SSH_KEY_PATH}"

# ── Schritt 3: Cloud-Image ───────────────────────────────────
step "Schritt 3/7 — Ubuntu Cloud-Image herunterladen"
mkdir -p "$IMG_DIR"
LOCAL_IMG="$IMG_DIR/$CLOUD_IMG_NAME"
if [[ -f "$LOCAL_IMG" ]]; then
  success "Cloud-Image bereits vorhanden."
else
  info "Lade Ubuntu ${UBUNTU_VERSION}..."
  wget --progress=bar:force -O "$LOCAL_IMG" "$CLOUD_IMG_URL" 2>&1 || error "Download fehlgeschlagen."
  success "Cloud-Image heruntergeladen."
fi

# ── Schritt 4: Cloud-Init Snippet ───────────────────────────
step "Schritt 4/7 — Cloud-Init konfigurieren"
mkdir -p "$SNIPPETS_DIR"

# Snippets auf local aktivieren
if ! pvesm status 2>/dev/null | awk '/^local /{print $6}' | grep -q "snippets"; then
  pvesm set local --content "snippets,iso,backup,images,rootdir" 2>/dev/null || true
fi

VM_ROOT_PASS="Paperclip$(openssl rand -hex 6)"
HASHED_PW=$(echo "$VM_ROOT_PASS" | mkpasswd --method=SHA-512 --stdin 2>/dev/null \
  || openssl passwd -6 "$VM_ROOT_PASS")

cat > "${SNIPPETS_DIR}/paperclip-cloudinit.yaml" << CLOUDINIT
#cloud-config
hostname: paperclip-ai
manage_etc_hosts: true
fqdn: paperclip-ai.local

users:
  - name: root
    lock_passwd: false
    hashed_passwd: "${HASHED_PW}"
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}

ssh_pwauth: true

packages:
  - qemu-guest-agent
  - openssh-server

package_update: true
package_upgrade: false

runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now ssh
  - mkdir -p /root/.ssh
  - chmod 700 /root/.ssh
  - echo "${SSH_PUB_KEY}" > /root/.ssh/authorized_keys
  - chmod 600 /root/.ssh/authorized_keys
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
  - echo "CLOUDINIT_DONE" > /root/cloudinit-status.txt
CLOUDINIT

success "Cloud-Init Snippet erstellt."

# ── Schritt 5: VM erstellen ──────────────────────────────────
step "Schritt 5/7 — VM erstellen"

if qm status "$VM_ID" &>/dev/null; then
  warn "VM ${VM_ID} existiert — wird gelöscht..."
  qm stop "$VM_ID" --skiplock 2>/dev/null || true
  sleep 5
  qm destroy "$VM_ID" --purge 2>/dev/null || true
  sleep 3
fi

info "Erstelle VM ${VM_ID}..."
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

info "Importiere Disk..."
IMPORT_OUTPUT=$(qm importdisk "$VM_ID" "$LOCAL_IMG" "$VM_STORAGE" --format qcow2 2>&1)
echo "$IMPORT_OUTPUT" | tail -2

# Disk-Referenz aus Output oder qm config lesen
DISK_REF=$(echo "$IMPORT_OUTPUT" | grep -oP "(?<=imported disk ')[^']+" 2>/dev/null || true)
if [[ -z "$DISK_REF" ]]; then
  sleep 2
  DISK_REF=$(qm config "$VM_ID" 2>/dev/null | grep "^unused0:" | awk '{print $2}' || true)
fi
[[ -z "$DISK_REF" ]] && error "Disk-Referenz nicht gefunden. Prüfe: qm config ${VM_ID}"
info "Disk: ${DISK_REF}"

info "Konfiguriere VM..."
qm set "$VM_ID" \
  --scsi0     "${DISK_REF},discard=on" \
  --boot      "order=scsi0" \
  --ide2      "${VM_STORAGE}:cloudinit" \
  --cicustom  "user=local:snippets/paperclip-cloudinit.yaml" \
  --ipconfig0 "ip=dhcp" \
  --sshkeys   "${SSH_KEY_PATH}.pub"

info "Disk auf ${VM_DISK_SIZE}GB vergrößern..."
qm resize "$VM_ID" scsi0 "${VM_DISK_SIZE}G"
qm cloudinit update "$VM_ID" 2>/dev/null || true
success "VM ${VM_ID} fertig konfiguriert."

# ── Schritt 6: VM starten + IP ──────────────────────────────
step "Schritt 6/7 — VM starten & IP ermitteln"
info "Starte VM..."
qm start "$VM_ID"

VM_IP=""
info "Warte auf QEMU Guest Agent (max. 5 Min.)..."
info "Cloud-Init installiert qemu-guest-agent — bitte ~90 Sek. warten..."
echo ""

for i in $(seq 1 300); do
  sleep 1
  VM_IP=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null \
    | python3 -c "
import sys,json
try:
  for iface in json.load(sys.stdin):
    n=iface.get('name','')
    if n in ('lo',) or n.startswith(('docker','br-','veth','virbr')): continue
    for a in iface.get('ip-addresses',[]):
      if a.get('ip-address-type')=='ipv4':
        ip=a['ip-address']
        if not ip.startswith(('127.','169.254.')): print(ip); sys.exit(0)
except: pass
" 2>/dev/null || true)

  if [[ -n "$VM_IP" ]]; then
    echo ""
    success "IP gefunden: ${VM_IP}"
    break
  fi
  (( i % 15 == 0 )) && printf "\r  ${CYAN}[%3d/300 Sek.]${NC} Warte...   " "$i"
done
echo ""

# Fallback: MAC → ARP
if [[ -z "$VM_IP" ]]; then
  warn "Guest Agent hat keine IP — versuche ARP..."
  VM_MAC=$(qm config "$VM_ID" 2>/dev/null \
    | grep "^net0" | grep -oiP '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
    | tr '[:upper:]' '[:lower:]' | head -1 || true)
  if [[ -n "$VM_MAC" ]]; then
    sleep 5
    VM_IP=$(arp -an 2>/dev/null | grep -i "$VM_MAC" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
    [[ -z "$VM_IP" ]] && VM_IP=$(ip neigh 2>/dev/null | grep -i "$VM_MAC" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
  fi
fi

# Manuell
if [[ -z "$VM_IP" ]]; then
  echo -e "  ${YELLOW}→ Proxmox GUI → VM ${VM_ID} → Summary → IP, oder Konsole: ip addr show${NC}"
  read -rp "  VM IP-Adresse eingeben: " VM_IP
  [[ -n "$VM_IP" ]] || error "Keine IP angegeben."
fi

# SSH warten
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -i ${SSH_KEY_PATH}"
SSH_OK=false
info "Warte auf SSH an ${VM_IP}..."
for i in $(seq 1 40); do
  ssh $SSH_OPTS root@"$VM_IP" "echo ok" &>/dev/null && SSH_OK=true && break
  printf "\r  SSH-Versuch %2d/40..." "$i"
  sleep 5
done
echo ""

if [[ "$SSH_OK" == false ]]; then
  warn "SSH noch nicht bereit — warte 60 Sek. mehr..."
  sleep 60
  ssh $SSH_OPTS root@"$VM_IP" "echo ok" &>/dev/null \
    && SSH_OK=true \
    || error "SSH nicht erreichbar.\nManuell: ssh -i ${SSH_KEY_PATH} root@${VM_IP}"
fi
success "SSH-Verbindung zu ${VM_IP} OK!"

# ── Schritt 7: Paperclip installieren ───────────────────────
step "Schritt 7/7 — Paperclip in der VM installieren"
info "Installation läuft — bitte nicht abbrechen..."

ssh $SSH_OPTS root@"$VM_IP" 'bash -s' << 'REMOTE_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PAPERCLIP_TELEMETRY_DISABLED=1

echo ""
echo "==> [1/6] System-Pakete..."
apt-get update -qq
apt-get install -y -qq curl git wget gnupg ca-certificates lsb-release build-essential ufw

echo "==> [2/6] Node.js 20..."
if command -v node &>/dev/null && [[ $(node -v | sed 's/v//' | cut -d. -f1) -ge 20 ]]; then
  echo "    Node.js $(node -v) vorhanden."
else
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null
  apt-get install -y -qq nodejs
  echo "    Node.js $(node -v) installiert."
fi

echo "==> [3/6] pnpm via corepack..."
# corepack ist in Node.js 20 eingebaut und legt pnpm nach /usr/local/bin
# Das ist der einzige Pfad den systemd ohne PATH-Konfiguration findet
corepack enable
corepack prepare pnpm@latest --activate

# Sicherstellen dass pnpm wirklich unter /usr/local/bin liegt
if ! /usr/local/bin/pnpm --version &>/dev/null; then
  # Fallback: symlink manuell setzen
  PNPM_REAL=$(find /root/.local /usr/lib/node_modules -name "pnpm" -type f 2>/dev/null | head -1 || true)
  [[ -n "$PNPM_REAL" ]] && ln -sf "$PNPM_REAL" /usr/local/bin/pnpm || npm install -g pnpm
fi

echo "    pnpm $(/usr/local/bin/pnpm -v) unter /usr/local/bin/pnpm"

echo "==> [4/6] Paperclip klonen..."
rm -rf /opt/paperclip
git clone --depth=1 https://github.com/paperclipai/paperclip.git /opt/paperclip --quiet
echo "    $(cd /opt/paperclip && git log --oneline -1)"

echo "==> [5/6] Dependencies (2-5 Min.)..."
cd /opt/paperclip
/usr/local/bin/pnpm install --frozen-lockfile 2>&1 | tail -5 \
  || /usr/local/bin/pnpm install 2>&1 | tail -5
echo "    Dependencies installiert."

echo "==> [6/6] systemd Service & Firewall..."

[[ -f /opt/paperclip/.env.example ]] \
  && cp /opt/paperclip/.env.example /opt/paperclip/.env \
  || touch /opt/paperclip/.env
grep -q "PAPERCLIP_TELEMETRY_DISABLED" /opt/paperclip/.env \
  || echo "PAPERCLIP_TELEMETRY_DISABLED=1" >> /opt/paperclip/.env

# Absoluten Pfad verwenden — kein Rätselraten für systemd
cat > /etc/systemd/system/paperclip.service << 'SVCEOF'
[Unit]
Description=Paperclip AI Orchestration Server
Documentation=https://github.com/paperclipai/paperclip
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/paperclip
ExecStart=/usr/local/bin/pnpm dev
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=paperclip
Environment=NODE_ENV=production
Environment=PAPERCLIP_TELEMETRY_DISABLED=1
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable paperclip --quiet
systemctl start paperclip

ufw allow 22/tcp   --quiet 2>/dev/null || true
ufw allow 3100/tcp --quiet 2>/dev/null || true
ufw --force enable         2>/dev/null || true

echo "PAPERCLIP_INSTALL_DONE" > /root/paperclip-install-status.txt
echo "    Fertig!"
REMOTE_SCRIPT

success "Paperclip installiert."

sleep 12
STATUS=$(ssh $SSH_OPTS root@"$VM_IP" "systemctl is-active paperclip 2>/dev/null || echo unknown" 2>/dev/null || echo "error")
case "$STATUS" in
  active)     success "Service: aktiv ✓" ;;
  activating) success "Service: startet... ✓" ;;
  *)          warn    "Service-Status: ${STATUS} — prüfe: journalctl -u paperclip -n 30 --no-pager" ;;
esac

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   ✅  PAPERCLIP AI VOLLSTÄNDIG INSTALLIERT!              ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
printf  "${BOLD}${CYAN}║  🚀  http://%-47s║${NC}\n" "${VM_IP}:${PAPERCLIP_PORT}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
printf  "${BOLD}${GREEN}║  🔑  ssh -i %-47s║${NC}\n" "${SSH_KEY_PATH} root@${VM_IP}"
printf  "${BOLD}${GREEN}║  🔑  Passwort: %-44s║${NC}\n" "${VM_ROOT_PASS}"
echo -e "${BOLD}${GREEN}║                                                          ║${NC}"
echo -e "${BOLD}${GREEN}║  📋  journalctl -u paperclip -f          (Live-Log)      ║${NC}"
echo -e "${BOLD}${GREEN}║  📋  systemctl restart paperclip                         ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Passwort notieren: ${YELLOW}${VM_ROOT_PASS}${NC}"
echo -e "  Dann ändern mit: ${CYAN}passwd root${NC}  (in der VM)"
echo ""
