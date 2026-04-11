#!/bin/bash
# ============================================================
#  Paperclip AI — Schnell-Fix für bestehende VM
#  Direkt auf der VM ausführen (nicht auf dem Proxmox Host!)
#  Behebt: pnpm not found / status=1/FAILURE
# ============================================================

set -euo pipefail

echo "==> pnpm via corepack neu installieren..."
corepack enable 2>/dev/null || true
corepack prepare pnpm@latest --activate 2>/dev/null || true

if ! command -v pnpm &>/dev/null; then
  echo "    Fallback: npm global..."
  npm install -g pnpm@latest
fi

PNPM_BIN=$(which pnpm)
echo "    pnpm Pfad: ${PNPM_BIN}"
echo "    pnpm Version: $(pnpm -v)"

echo "==> pnpm install in /opt/paperclip..."
cd /opt/paperclip
export PNPM_HOME="/root/.local/share/pnpm"
"${PNPM_BIN}" install --frozen-lockfile 2>&1 | tail -5 \
  || "${PNPM_BIN}" install 2>&1 | tail -5

echo "==> systemd Service aktualisieren..."
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
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EnvironmentFile=-/opt/paperclip/.env

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl restart paperclip

echo ""
echo "==> Status prüfen..."
sleep 5
systemctl status paperclip --no-pager | head -10

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "================================================"
echo "  Paperclip URL: http://${IP}:3100"
echo "================================================"
