# CompAI-CRM auf Proxmox VE (VM, Community-Scripts-Stil, vollautomatisch)

Installiert das Open-Source-CRM [trycompai/crm](https://github.com/trycompai/crm)
(Agentic-first CRM: Next.js-App `:3000` + NestJS-API `:3001` + Eve-Agent `:2000` + Postgres)
als **Debian-12-VM** auf Proxmox VE – **ein Einzeiler auf dem Host, danach kommt
die Web-UI von selbst. Kein Terminal in der VM mehr nötig.**

> Warum VM statt LXC? Bun + Node ≥ 22 + Turbo-Build + Postgres (+ optional
> Docker/microsandbox für den Agent) sind in einer VM reboot-sicher und
> reproduzierbar. Docker-in-LXC ist fragil (nesting/privileged).

## Installation (ein Schritt)

**Auf dem Proxmox-Host** ausführen (erstellt die VM, Standard: VMID 260,
4 vCPU, 8 GB RAM, 32 GB Disk, `onboot=1`):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CompAI-CRM/main/install/compai-crm-vm.sh)"
```

Das Script fragt **einmalig** ab: VM-ID, Linux-User + Passwort für die VM,
`ALLOWED_SIGN_IN`, optional Google-/Microsoft-OAuth-Clients und
`AI_GATEWAY_API_KEY`. Danach läuft alles von selbst:

1. VM wird per Cloud-Init mit User, DHCP und Seed-Werten versorgt
2. Die VM installiert Postgres, Bun, CRM-Build und 3 systemd-Dienste (~10–25 Min)
3. Der Host wartet und meldet am Ende: `http://<VM-IP>:3000` ✅

Bei Fehlern mit vollem Log:

```bash
bash -x install/compai-crm-vm.sh   # Host-Script mit xtrace
```

## Wichtig vorab: OAuth-Pflicht

Ohne `ALLOWED_SIGN_IN` + **Google- oder Microsoft-OAuth-Client** (oder eigenes
IdP unter Settings → SSO) gibt es **keinen Login**. Redirect-URI beim Provider
eintragen (mit der echten VM-IP):

- Google: `http://<VM-IP>:3001/api/auth/callback/google`
- Microsoft: `http://<VM-IP>:3001/api/auth/callback/microsoft`

Der Agent braucht außerhalb von Vercel zusätzlich `AI_GATEWAY_API_KEY`
(sonst kein Modell), optional `PERPLEXITY_API_KEY`. Details in `.env.example`
des Upstream-Repos.

## Betrieb

```bash
qm terminal 260                       # nur falls doch mal nötig
tail -f /var/log/compai-crm-install.log   # Erstinstallations-Log (in der VM)
cat /var/log/compai-crm-install.done      # finale URL
systemctl status compai-crm-api compai-crm-app compai-crm-agent
journalctl -u compai-crm-api -f
```

**Update** (in der VM):

```bash
cd /opt/compai-crm && git pull && bun install && bun run db:deploy && bun run build && systemctl restart compai-crm-api compai-crm-app compai-crm-agent
```

**Deinstall:** VM löschen (auf dem Host): `qm stop 260 && qm destroy 260 --purge`

## Struktur

| Datei | Zweck |
|---|---|
| `install/compai-crm-vm.sh` | PVE-Host-Script: fragt alles ab, erstellt VM + Cloud-Init-Seed, wartet auf Web-UI (`set -Eeuo pipefail`, Stacktrace, Secrets maskiert) |
| `install/compai-crm.sh` | Guest-Installer: Postgres, Bun 1.3.12, Node 22, CRM-Build, systemd-Units, HTTP-Verifikation – manuell oder per Cloud-Init (`CRM_NONINTERACTIVE=1`) |

Upstream: https://github.com/trycompai/crm (Branch `release`, MIT).
