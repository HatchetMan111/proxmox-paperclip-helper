# 🤖 Proxmox Helper Script — Paperclip AI

Dieses Repository steht unter der [MIT License](LICENSE).  
Basierend auf [Paperclip AI](https://github.com/paperclipai/paperclip).

💡 Entwickelt mit ❤️ für Proxmox-Homelab-Enthusiasten.

> 🤖 „Run your AI company — not your tabs."

---

## 🧩 Was dieses Script macht

✅ Prüft das Betriebssystem (Ubuntu / Debian)  
✅ Aktualisiert das System vollständig  
✅ Installiert Node.js 20+ (via NodeSource)  
✅ Installiert pnpm 9.15+ (Paketmanager)  
✅ Klont Paperclip AI nach `/opt/paperclip`  
✅ Installiert alle Node-Abhängigkeiten  
✅ Erstellt `.env` Konfigurationsdatei  
✅ Richtet systemd-Service ein (Autostart nach Neustart)  
✅ Gibt am Ende die fertige Web-URL mit IP aus

---

## ⚙️ Systemanforderungen

| Komponente | Empfehlung |
|---|---|
| Proxmox VE | 7.x oder 8.x |
| Betriebssystem der VM | Ubuntu 22.04 / 24.04 LTS |
| RAM | ≥ 4 GB (8 GB empfohlen) |
| Storage | ≥ 20 GB |
| CPU | ≥ 2 Cores |

[![Proxmox](https://img.shields.io/badge/Proxmox-VE%208.x-orange?logo=proxmox)](https://www.proxmox.com)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%2F%2024.04%20LTS-blue?logo=ubuntu)](https://ubuntu.com)
[![Node.js](https://img.shields.io/badge/Node.js-20+-green?logo=node.js)](https://nodejs.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 🚀 Ein-Klick-Installation

**Schritt 1:** Ubuntu VM in Proxmox erstellen (22.04 oder 24.04), starten und SSH öffnen.

**Schritt 2:** Auf der VM als root ausführen:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/proxmox-paperclip-helper/main/paperclip-install.sh)
```

**Schritt 3:** Am Ende des Scripts wird die URL ausgegeben:

```
✅  PAPERCLIP ERFOLGREICH INSTALLIERT!
🌐  Weboberfläche:  http://<VM-IP>:3100
```

Einfach die URL im Browser öffnen und Paperclip konfigurieren. 🎉

---

## 📋 Nützliche Befehle nach der Installation

```bash
# Status prüfen
systemctl status paperclip

# Live-Log ansehen
journalctl -u paperclip -f

# Neu starten
systemctl restart paperclip

# Stoppen
systemctl stop paperclip
```

---

## 📁 Installationspfade

| Pfad | Inhalt |
|---|---|
| `/opt/paperclip` | Paperclip Installationsverzeichnis |
| `/opt/paperclip/.env` | Konfigurationsdatei (API Keys etc.) |
| `/etc/systemd/system/paperclip.service` | Autostart-Service |

---

## 🔧 Was ist Paperclip AI?

[Paperclip](https://paperclip.ing) ist eine Open-Source-Plattform, um KI-Agenten  
(Claude Code, OpenClaw, Codex, Cursor ...) als vollständiges Unternehmen zu orchestrieren:  
mit Organigramm, Budgets, Zielen und Governance — alles in einem Dashboard.

---

## 🤝 Community & Links

- 📖 [Paperclip Dokumentation](https://paperclip.ing/docs)
- 💬 [Paperclip Discord](https://discord.gg/m4HZY7xNG3)
- 🐙 [Paperclip GitHub](https://github.com/paperclipai/paperclip)

---

*© HatchetMan111 — MIT License*
