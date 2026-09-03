# CompAI-CRM auf Proxmox VE (VM, Community-Scripts-Stil)

Installiert das Open-Source-CRM [trycompai/crm](https://github.com/trycompai/crm)
(Agentic-first CRM: Next.js-App `:3000` + NestJS-API `:3001` + Eve-Agent `:2000` + Postgres)
als **Debian-12-VM** auf Proxmox VE – mit Einzeiler, systemd-Diensten und Selbst-Verifikation.

> Warum VM statt LXC? Bun + Node ≥ 22 + Turbo-Build + Postgres (+ optional
> Docker/microsandbox für den Agent) sind in einer VM reboot-sicher und
> reproduzierbar. Docker-in-LXC ist fragil (nesting/privileged).

## Installation

**1. Auf dem Proxmox-Host** (erstellt die VM, Standard: VMID 260, 4 vCPU, 8 GB RAM, 32 GB Disk, `onboot=1`):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CompAI-CRM/main/install/compai-crm-vm.sh)"
```

**2. In der neuen VM** (installiert Postgres, Bun, CRM-Build, 3 systemd-Dienste):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CompAI-CRM/main/install/compai-crm.sh)"
```

Danach: `http://<VM-IP>:3000` (App) · `http://<VM-IP>:3001` (API).

Bei Fehlern mit vollem Log:

```bash
DEBUG=1 bash -x install/compai-crm.sh
```

## Wichtig vorab: OAuth-Pflicht

Ohne `ALLOWED_SIGN_IN` + **Google- oder Microsoft-OAuth-Client** (oder eigenes
IdP unter Settings → SSO) gibt es **keinen Login**. Der Installer fragt
`ALLOWED_SIGN_IN` ab. Redirect-URI beim Provider eintragen:

- Google: `http://<VM-IP>:3001/api/auth/callback/google`
- Microsoft: `http://<VM-IP>:3001/api/auth/callback/microsoft`

Der Agent braucht außerhalb von Vercel zusätzlich `AI_GATEWAY_API_KEY`
(sonst kein Modell), optional `PERPLEXITY_API_KEY`. Details in `.env.example`
des Upstream-Repos.

## Betrieb

```bash
systemctl status compai-crm-api compai-crm-app compai-crm-agent
journalctl -u compai-crm-api -f
journalctl -u compai-crm-app -f
journalctl -u compai-crm-agent -f
```

**Update** (in der VM):

```bash
cd /opt/compai-crm && git pull && bun install && bun run db:deploy && bun run build && systemctl restart compai-crm-api compai-crm-app compai-crm-agent
```

**Deinstall** (in der VM):

```bash
systemctl disable --now compai-crm-api compai-crm-app compai-crm-agent
rm -rf /opt/compai-crm
```

VM löschen (auf dem Host): `qm stop 260 && qm destroy 260 --purge`

## Struktur

| Datei | Zweck |
|---|---|
| `install/compai-crm-vm.sh` | PVE-Host-Script: erstellt die Debian-12-VM (`qm`, idempotent, `set -Eeuo pipefail`, Stacktrace bei Fehlern) |
| `install/compai-crm.sh` | Guest-Installer in der VM: Postgres, Bun 1.3.12, Node 22, CRM-Build, systemd-Units, HTTP-Verifikation |

Upstream: https://github.com/trycompai/crm (Branch `release`, MIT).
