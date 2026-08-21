# 🤖 Proxmox Helper Script — Paperclip AI (All-in-One)

Dieses Repository steht unter der [MIT License](LICENSE).
Basierend auf [Paperclip AI](https://github.com/paperclipai/paperclip).

💡 Entwickelt mit ❤️ für Proxmox-Homelab-Enthusiasten.

> 🤖 „One command. One VM. One AI company."

---

## 🧩 Was dieses Script macht

✅ Läuft direkt auf dem **Proxmox HOST** (keine manuelle VM nötig!)
✅ Lädt automatisch das **Ubuntu 24.04 Cloud-Image** herunter
✅ Erstellt eine neue **Ubuntu VM** (ID, RAM, CPU, Disk, Bridge – alles automatisch)
✅ Konfiguriert **Cloud-Init** (Hostname, Root-Passwort, SSH)
✅ Startet die VM und wartet auf Boot + IP-Adresse
✅ Installiert **Node.js 20**, **pnpm 9.15+** und alle Abhängigkeiten
✅ Klont **Paperclip AI** und richtet **systemd Autostart** ein
✅ Richtet die **Firewall** ein (Port 3100 + SSH)
✅ Gibt am Ende **IP-Adresse + fertige Web-URL** aus

---

## ⚙️ Systemanforderungen

| Komponente | Anforderung |
|---|---|
| Proxmox VE | 7.x oder 8.x |
| Ausführungsort | Proxmox **HOST** Shell (nicht in einer VM!) |
| RAM für VM | ≥ 4 GB (8 GB empfohlen) |
| Storage | ≥ 20 GB freier Platz |
| CPU | ≥ 2 Cores für die VM |
| Netzwerk | DHCP auf vmbr0 (Standard) |

[![Proxmox](https://img.shields.io/badge/Proxmox-VE%207%2F8-orange?logo=proxmox)](https://www.proxmox.com)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-blue?logo=ubuntu)](https://ubuntu.com)
[![Node.js](https://img.shields.io/badge/Node.js-20+-green?logo=node.js)](https://nodejs.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 🚀 Ein-Klick-Installation

**Auf dem Proxmox HOST** in der Shell oder per SSH als root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/proxmox-paperclip-helper/main/paperclip-proxmox-install.sh)
```

Das Script fragt einmal nach Bestätigung der geplanten Konfiguration – danach läuft alles vollautomatisch.

**Am Ende erscheint:**

```
✅  PAPERCLIP AI VOLLSTÄNDIG INSTALLIERT!

🚀  Paperclip URL:
    http://<VM-IP>:3100

🔑  SSH-Zugang:
    ssh -i /root/.ssh/paperclip_vm_ed25519 root@<VM-IP>
```

Einfach die URL im Browser öffnen und loslegen. 🎉

---

## ♻️ Neustart-sicher — keine Zusatzschritte nötig!

Alles läuft nach einem Neustart **vollautomatisch** weiter:

| Ebene | Mechanismus |
|---|---|
| VM startet mit dem Host | `onboot=1` (bereits konfiguriert) |
| Paperclip startet in der VM | systemd Service (`systemctl enable paperclip`) |

Falls sich durch DHCP die IP geändert hat, einfach auf dem **Proxmox Host** ausführen:

```bash
paperclip-info
```

Das zeigt dir jederzeit die aktuelle VM-ID, IP-Adresse, Web-URL und den SSH-Befehl an.
Alle Zugangsdaten findest du außerdem in `/root/paperclip-vm-info.txt`.

---

## 🔧 Was passiert im Detail?

```
[Proxmox HOST]
    │
    ├─ 1. Ubuntu 24.04 Cloud-Image herunterladen
    ├─ 2. Cloud-Init Snippet erstellen (Hostname, Passwort, SSH)
    ├─ 3. VM erstellen (qm create + importdisk + cloudinit)
    ├─ 4. VM starten + auf IP warten (via QEMU Guest Agent)
    │
    └─ 5. Per SSH in die VM → Paperclip installieren:
              ├─ System updaten
              ├─ Node.js 20 installieren
              ├─ pnpm installieren
              ├─ Paperclip klonen (/opt/paperclip)
              ├─ pnpm install
              ├─ .env erstellen
              ├─ systemd Service einrichten (autostart)
              ├─ Firewall (Port 3100 + 22)
              └─ SSH härten (nur Key-Login)
```

---

## 📋 Nützliche Befehle nach der Installation

```bash
# Auf dem PROXMOX HOST:

# Aktuelle IP + URL anzeigen (z.B. nach Neustart)
paperclip-info

# Alle Zugangsdaten
cat /root/paperclip-vm-info.txt

# In die VM einloggen
ssh -i /root/.ssh/paperclip_vm_ed25519 root@<VM-IP>
```

```bash
# In der VM:

# Paperclip Status
systemctl status paperclip

# Live-Log
journalctl -u paperclip -f

# Neu starten
systemctl restart paperclip

# Konfiguration bearbeiten
nano /opt/paperclip/.env
```

---

## 📁 Installationspfade

| Ort | Pfad | Inhalt |
|---|---|---|
| HOST | `/root/paperclip-vm-info.txt` | Alle Zugangsdaten & Infos |
| HOST | `/usr/local/bin/paperclip-info` | IP/URL-Anzeige (auch nach Reboot) |
| HOST | `/root/.ssh/paperclip_vm_ed25519` | SSH-Key für die VM |
| VM | `/opt/paperclip` | Paperclip Installationsverzeichnis |
| VM | `/opt/paperclip/.env` | Konfigurationsdatei (API Keys etc.) |
| VM | `/etc/systemd/system/paperclip.service` | systemd Autostart |

---

## 🔐 Sicherheitshinweis

- Das Script generiert ein **zufälliges Root-Passwort** für die VM. Es funktioniert **ausschließlich in der Proxmox-Konsole (noVNC)** – SSH-Login ist nach der Installation **nur noch per SSH-Key** möglich.
- Das Cloud-Init-Snippet (mit Passwort-Hash) und die Info-Datei sind nur für `root` lesbar (`chmod 600`).
- Die Firewall in der VM erlaubt nur SSH (22) und Paperclip (3100).

Root-Passwort ändern (optional, in der Proxmox-Konsole):
```bash
passwd root
```

---

## 🤝 Community & Links

- 📖 [Paperclip Dokumentation](https://paperclip.ing/docs)
- 💬 [Paperclip Discord](https://discord.gg/m4HZY7xNG3)
- 🐙 [Paperclip GitHub](https://github.com/paperclipai/paperclip)

---

*© HatchetMan111 — MIT License*
