# CompAI-CRM auf Proxmox VE

![Proxmox VE](https://img.shields.io/badge/Proxmox-VE-E57000?logo=proxmox&logoColor=white)
![Debian 12](https://img.shields.io/badge/Debian-12-A81D33?logo=debian&logoColor=white)
![Bun](https://img.shields.io/badge/Bun-1.3-black?logo=bun&logoColor=white)
![License MIT](https://img.shields.io/badge/License-MIT-green)

Installiert das Open-Source-CRM [trycompai/crm](https://github.com/trycompai/crm)
(Agentic-first CRM: Next.js-App `:3000` + NestJS-API `:3001` + Eve-Agent `:2000` + Postgres)
als **Debian-12-VM** auf Proxmox VE – **ein Einzeiler auf dem Host, danach kommt
die Web-UI von selbst. Kein Terminal in der VM mehr nötig.**

> Warum VM statt LXC? Bun + Node ≥ 22 + Turbo-Build + Postgres (+ optional
> Docker/microsandbox für den Agent) sind in einer VM reboot-sicher und
> reproduzierbar. Docker-in-LXC ist fragil (nesting/privileged).

- [Installation](#installation-ein-schritt)
- [So sieht Erfolg aus](#so-sieht-erfolg-aus)
- [Login einrichten (OAuth)](#wichtig-vorab-oauth-pflicht-kommt-von-der-app)
- [Betrieb & Status](#betrieb)
- [FAQ / Probleme](#faq--probleme)
- [Dateien](#struktur)

## Installation (ein Schritt)

**Auf dem Proxmox-Host** ausführen (erstellt die VM, Standard: VMID 260,
4 vCPU, 8 GB RAM, 32 GB Disk, `onboot=1`):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CompAI-CRM/main/install/compai-crm-vm.sh)"
```

Das Script fragt **einmalig**: VM-ID, Linux-User + Passwort (leer = Zufallspasswort),
Netzwerk (DHCP oder statisch), **Pflicht: `ALLOWED_SIGN_IN`** (deine Mail/Domain –
die API startet ohne gar nicht), optional OAuth-Clients und `AI_GATEWAY_API_KEY`.
Danach läuft alles von selbst, mit Schrittzähler `[1/7]…[7/7]` und Zeitanzeige:

1. Cloud-Init-Seed (User, Netzwerk, Keys) wird in die VM gelegt
2. Die VM installiert Postgres, Bun, CRM-Build und 3 systemd-Dienste (~10–25 Min)
3. Der Host findet die IP (Agent → ARP → DHCP-Heilung → Auto-Static-Fallback)
4. Der Host wartet auf die Web-UI und zeigt die Ergebnis-Box ✅

Bei Fehlern mit vollem Log (komplette Kette, Stacktrace, Secrets maskiert):

```bash
bash -x install/compai-crm-vm.sh   # Host-Script mit xtrace
```

## So sieht Erfolg aus

Host-Terminal am Ende:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ FERTIG nach 18:42 Min. – CompAI CRM ist erreichbar!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Web-UI .... http://192.168.178.250:3000
  API ....... http://192.168.178.250:3001
  SSH ....... ssh crmadmin@192.168.178.250  (Passwort: /root/compai-crm-260.cred auf dem Host)
  Status .... crm-status  (in der VM: Dienste, Login-Check, URLs)
  VM-ID ..... 260  (onboot=1, reboot-sicher)
  Login ..... OAuth-Button – nur 'du@gmail.com' kommt rein
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

In der VM gibt `crm-status` jederzeit die Gesundheitsübersicht:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CompAI CRM – Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Web-UI (App) . ● aktiv     [:3000 → HTTP 200]
  API .......... ● aktiv     [:3001 → HTTP 200]
  Agent ........ ● aktiv     [:2000]
  Login ........ OAuth-Login für 'du@gmail.com'
  URL .......... http://192.168.178.250:3000
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Wichtig vorab: OAuth-Pflicht kommt von der App

Das Upstream-CRM kennt **kein Benutzer/Passwort-Login** (also auch kein
admin/admin), nur Google-, Microsoft-OAuth oder eigenes SSO. Ohne Keys zeigt
die Web-UI nur die Login-Seite – deshalb lässt das Script alles leere zu und
druckt am Ende die exakte Nachtrag-Anleitung (3 Befehle in der VM).
Redirect-URI beim Provider eintragen (mit der echten VM-IP):

- Google: `http://<VM-IP>:3001/api/auth/callback/google`
- Microsoft: `http://<VM-IP>:3001/api/auth/callback/microsoft`

Der Agent braucht außerhalb von Vercel zusätzlich `AI_GATEWAY_API_KEY`
(sonst kein Modell), optional `PERPLEXITY_API_KEY`. Details in `.env.example`
des Upstream-Repos.

Keys nachtragen (in der VM):

```bash
sudo nano /opt/compai-crm/.env   # ALLOWED_SIGN_IN + CLIENT_ID/SECRET setzen
sudo systemctl restart compai-crm-api compai-crm-app
```

## Betrieb

```bash
crm-status                                # Gesundheitscheck (in der VM)
qm terminal 260                           # VM-Konsole (nur falls nötig)
tail -f /var/log/compai-crm-install.log   # Erstinstallations-Log (in der VM)
cat /var/log/compai-crm-install.done      # finale URL
journalctl -u compai-crm-api -f           # Dienst-Logs (app/agent analog)
```

**Update** (in der VM):

```bash
cd /opt/compai-crm && git pull && bun install && bun run db:deploy && bun run build && systemctl restart compai-crm-api compai-crm-app compai-crm-agent
```

**Deinstall:** VM löschen (auf dem Host): `qm stop 260 && qm destroy 260 --purge`

## FAQ / Probleme

| Symptom | Lösung |
|---|---|
| `P1000: Authentication failed` bei `db:deploy` | Alter Installer-Stand: Guest-Installer erneut laufen lassen (stellt `DATABASE_URL` automatisch auf den `crm`-User um). |
| `ALLOWED_SIGN_IN is required`, API crash-loopt | E-Mail/Domain in `/opt/compai-crm/.env` setzen + `systemctl restart compai-crm-api compai-crm-app`. Host-Script fragt sie seitdem als Pflicht ab. |
| Aus Versehen auf dem **Host** installiert (`root@Prox`)? | Sofort aufräumen (Hypervisor!): `systemctl disable --now compai-crm-api compai-crm-app compai-crm-agent; rm -f /etc/systemd/system/compai-crm-*.service /usr/local/sbin/crm-status /usr/local/sbin/compai-crm.sh /var/log/compai-crm-install.*; systemctl daemon-reload; rm -rf /opt/compai-crm; sudo -u postgres psql -c "DROP DATABASE IF EXISTS crm;" -c "DROP ROLE IF EXISTS crm;"` – danach nur noch **in der VM** installieren (der Installer verweigert den Host seitdem von selbst). |
| Keine IPv4 / nur IPv6 in der VM | Script stößt `dhclient` selbst an, sonst Auto-Static-IP (`.230`–`.250`). Notfalls neu starten + **statische IP** wählen. |
| `No DHCPOFFERS received` | DHCP-Server antwortet der VM nicht → statische IP nehmen (z. B. `192.168.178.250/24`, GW `.1`). |
| Nur Login-Seite, kein Button funktioniert | OAuth-Keys fehlen → [nachtragen](#wichtig-vorab-oauth-pflicht-kommt-von-der-app). Es gibt kein Passwort-Login. |
| Passwort vergessen | Auf dem Host: `cat /root/compai-crm-<VMID>.cred` (nur bei Zufallspasswort angelegt). Sonst: `qm terminal` → `passwd <user>`. |
| Thin-Pool-Warnung (`thin volume sizes exceeds`) | Harmlos – Thin Provisioning überbucht; erst echtes Vollschreiben wäre ein Problem. |
| Installationsfehler | Volle Kette steht im Terminal (Stacktrace + Service-Logs). In der VM: `tail -f /var/log/compai-crm-install.log`, Re-Run mit `DEBUG=1 bash -x`. |

## Struktur

| Datei | Zweck |
|---|---|
| `install/compai-crm-vm.sh` | PVE-Host-Script: fragt alles ab, erstellt VM + Cloud-Init-Seed, findet IP, wartet auf Web-UI, druckt Ergebnis-Box (`set -Eeuo pipefail`, Stacktrace, Secrets maskiert) |
| `install/compai-crm.sh` | Guest-Installer: Postgres, Bun 1.3.12, Node 24 (eve-CLI braucht ≥24), CRM-Build, systemd-Units, `crm-status`-Tool, HTTP-Verifikation – manuell oder per Cloud-Init (`CRM_NONINTERACTIVE=1`) |

Upstream: https://github.com/trycompai/crm (Branch `release`, MIT).
