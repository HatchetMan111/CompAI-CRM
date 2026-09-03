#!/usr/bin/env bash
# CompAI CRM – Proxmox VE VM Installer (Community-Scripts-Stil)
# Host-Script: läuft auf dem Proxmox-Host, erstellt eine Debian-12-VM.
# Danach EINZEILER IN DER VM ausführen (wird am Ende ausgegeben):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CompAI-CRM/main/install/compai-crm.sh)"
#
# Warum VM statt LXC? trycompai/crm braucht Bun + Node>=22 + Turbo-Build +
# Postgres + optional Docker/microsandbox für den Eve-Agent. Docker-in-LXC
# (nesting, privileged) ist fragil; VM ist reboot-sicher und reproduzierbar.

APP="compai-crm"
var_cpu="4"        # Minimum, Turbo-Build + Next.js + NestJS + Agent
var_ram="8192"     # MiB, Minimum 6144 – 8192 empfohlen
var_disk="32"      # GiB, Minimum 24 (Build-Cache + Bun + Postgres)
var_bridge="vmbr0"
var_storage="local-lvm"
var_imgstore="local"
DEBIAN_IMG="debian-12-generic-amd64.qcow2"
DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/${DEBIAN_IMG}"
DEFAULT_VMID="260"

YW='\033[33m'; GN='\033[1;32m'; RD='\033[1;31m'; BL='\033[36m'; CL='\033[m'
CM="${GN}✓${CL}"; CR="${RD}✗${CL}"

set -Eeuo pipefail
shopt -s expand_aliases

header_info() {
  clear
  cat <<"EOF"

  ┌──────────────────────────────────────────────────────┐
  │      C O M P A I   C R M                             │
  │      Agentic-first Open-Source CRM                   │
  │      Proxmox VE · VM Installer                       │
  └──────────────────────────────────────────────────────┘
   https://github.com/trycompai/crm

EOF
}

msg_info() { echo -e "${YW}● ${CL}${BL}${1}...${CL}"; }
msg_ok()   { echo -e "${CM} ${GN}${1}${CL}"; }
msg_error(){ echo -e "${CR} ${RD}${1}${CL}"; }

error_handler() {
  local ec=$? line=${1:-?} cmd=${BASH_COMMAND:-?}
  echo -e "\n${CR} ${RD}FEHLER in Zeile ${line} (Exit ${ec}) beim Befehl: ${cmd}${CL}" >&2
  echo -e "${YW}--- Stacktrace (neueste zuerst) ---${CL}" >&2
  local i=0
  while caller $i >&2; do i=$((i+1)); done
  echo -e "${YW}Tipp: Re-Run mit Debug-Log: bash -x $0${CL}" >&2
  exit "${ec}"
}
trap 'error_handler $LINENO' ERR

die() { msg_error "$1"; exit 1; }

command -v qm >/dev/null 2>&1 || die "Dieses Script muss auf einem Proxmox VE Host laufen (qm fehlt)."
command -v pvesm >/dev/null 2>&1 || die "pvesm fehlt – kein vollständiger PVE-Host?"

header_info
echo -e "\n${YW}Erstellt eine Debian-12-VM für CompAI CRM.${CL}"
echo -e "  ${BL}CPU:  ${GN}${var_cpu}${CL}   ${BL}RAM: ${GN}${var_ram} MiB${CL}   ${BL}Disk: ${GN}${var_disk} GiB${CL}"
echo -e "  ${BL}Ports (in der VM): App ${GN}3000${CL}, API ${GN}3001${CL}, Agent ${GN}2000${CL}\n"

read -rp "VM-ID [${DEFAULT_VMID}]: " VMID
VMID="${VMID:-$DEFAULT_VMID}"
[[ "$VMID" =~ ^[0-9]+$ ]] && [[ "$VMID" -ge 100 ]] || die "Ungültige VM-ID: '$VMID' (>=100)."

if qm status "$VMID" >/dev/null 2>&1; then
  echo -ne "${YW}VM ${VMID} existiert. Löschen und neu erstellen? (j/n) ${CL}"
  read -r -n 1 REPLY; echo
  [[ $REPLY =~ ^[Jj]$ ]] || die "Abgebrochen."
  msg_info "Stoppe VM ${VMID}"
  qm stop "$VMID" >/dev/null 2>&1 || true; sleep 3
  msg_info "Lösche VM ${VMID}"
  qm destroy "$VMID" --purge >/dev/null 2>&1 || true; sleep 2
  msg_ok "Gelöscht"
fi

msg_info "Prüfe Debian-Cloud-Image"
IMG_PATH="/var/lib/vz/template/iso/${DEBIAN_IMG}"
if [[ ! -f "$IMG_PATH" ]]; then
  mkdir -p "$(dirname "$IMG_PATH")"
  wget -qO "$IMG_PATH" "$DEBIAN_URL" || die "Download fehlgeschlagen: $DEBIAN_URL"
fi
msg_ok "Image bereit"

msg_info "Erstelle VM ${VMID} (qm create)"
qm create "$VMID" \
  --name compai-crm \
  --memory "$var_ram" \
  --cores "$var_cpu" \
  --cpu host \
  --balloon 0 \
  --net0 virtio,bridge="$var_bridge",firewall=1 \
  --scsihw virtio-scsi-pci \
  --agent enabled=1 \
  --onboot 1 \
  --startup order=2 \
  --ostype l26 >/dev/null || {
    echo "qm create stderr/stdout siehe oben" >&2; exit 1
  }
qm importdisk "$VMID" "$IMG_PATH" "$var_storage" >/dev/null
qm set "$VMID" --scsi0 "${var_storage}:vm-${VMID}-disk-0" >/dev/null
qm resize "$VMID" scsi0 "${var_disk}G" >/dev/null 2>&1 || true
qm set "$VMID" --boot order=scsi0 --serial0 socket --vga serial0 >/dev/null
msg_ok "VM erstellt"

msg_info "Starte VM"
qm start "$VMID" >/dev/null
msg_ok "VM gestartet"

echo ""
echo -e "  ${CM} ${GN}VM ${VMID} läuft (onboot=1).${CL}"
echo -e "  ${CM} Debian-12-Setup fertigstellen, dann ${YW}IN DER VM${CL} ausführen:"
echo -e "  ${YW}bash -c \"\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CompAI-CRM/main/install/compai-crm.sh)\"${CL}"
echo -e "  ${CM} Web-UI danach: ${YW}http://<VM-IP>:3000${CL}  API: ${YW}http://<VM-IP>:3001${CL}"
echo -e "  ${CM} VM-Shell: ${YW}qm terminal ${VMID}${CL}  oder via SSH"
echo ""
