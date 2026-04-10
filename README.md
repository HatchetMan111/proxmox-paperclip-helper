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
    ssh root@<VM-IP>
```

Einfach die URL im Browser öffnen und loslegen. 🎉

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
              ├─ systemd Service einrichten
              └─ Firewall (Port 3100 + 22)
```

---

## 📋 Nützliche Befehle nach der Installation

```bash
# In die VM einloggen
ssh root@<VM-IP>

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

## 📁 Installationspfade (in der VM)

| Pfad | Inhalt |
|---|---|
| `/opt/paperclip` | Paperclip Installationsverzeichnis |
| `/opt/paperclip/.env` | Konfigurationsdatei (API Keys etc.) |
| `/etc/systemd/system/paperclip.service` | systemd Autostart |

---

## 🔐 Sicherheitshinweis

Das Script generiert ein zufälliges Root-Passwort für die VM und zeigt es am Ende an.  
**Bitte notieren und danach ändern:**
```bash
ssh root@<VM-IP>
passwd root
```

---

## 🤝 Community & Links

- 📖 [Paperclip Dokumentation](https://paperclip.ing/docs)
- 💬 [Paperclip Discord](https://discord.gg/m4HZY7xNG3)
- 🐙 [Paperclip GitHub](https://github.com/paperclipai/paperclip)

---

*© HatchetMan111 — MIT License*
