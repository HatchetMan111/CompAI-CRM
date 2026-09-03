#!/usr/bin/env bash
# CompAI CRM – Proxmox VE VM Installer (Community-Scripts-Stil, VOLLAUTOMATISCH)
# Läuft auf dem Proxmox-Host. Fragt alles EINMAL ab, erstellt eine Debian-12-VM,
# übergibt Zugang + OAuth-Werte per Cloud-Init und wartet, bis die Web-UI antwortet.
# Danach ist KEIN Terminal in der VM mehr nötig: http://<VM-IP>:3000
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
var_snippet_store="local"
var_wait_min="40"  # max. Wartezeit auf die Web-UI (Erstbuild dauert!)
DEBIAN_IMG="debian-12-generic-amd64.qcow2"
DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/${DEBIAN_IMG}"
DEFAULT_VMID="260"
DEFAULT_CIUSER="crmadmin"
GUEST_SCRIPT_URL="https://raw.githubusercontent.com/HatchetMan111/CompAI-CRM/main/install/compai-crm.sh"

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
  │      Proxmox VE · VM Installer (automatisch)         │
  └──────────────────────────────────────────────────────┘
   https://github.com/trycompai/crm

EOF
}

msg_info() { echo -e "${YW}● ${CL}${BL}${1}...${CL}"; }
msg_ok()   { echo -e "${CM} ${GN}${1}${CL}"; }
msg_error(){ echo -e "${CR} ${RD}${1}${CL}"; }

error_handler() {
  local ec=$? line=${1:-?} cmd=${BASH_COMMAND:-?}
  # Secrets nie ins Log: Passwörter/Secrets maskieren
  cmd=$(printf '%s' "$cmd" | sed -E 's/(--cipassword )[^ ]+/\1***/g; s/((SECRET|AIKEY|_SECRET)=)[^ ;]+/\1***/g')
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
echo -e "\n${YW}Erstellt eine Debian-12-VM für CompAI CRM – vollautomatisch bis zur Web-UI.${CL}"
echo -e "  ${BL}CPU:  ${GN}${var_cpu}${CL}   ${BL}RAM: ${GN}${var_ram} MiB${CL}   ${BL}Disk: ${GN}${var_disk} GiB${CL}"
echo -e "  ${BL}Web-UI: ${GN}http://<VM-IP>:3000${CL}  (API :3001, Agent :2000)\n"

# ── Eingaben (einmalig, alles andere läuft von selbst) ───────────────
read -rp "VM-ID [${DEFAULT_VMID}]: " VMID
VMID="${VMID:-$DEFAULT_VMID}"
[[ "$VMID" =~ ^[0-9]+$ ]] && [[ "$VMID" -ge 100 ]] || die "Ungültige VM-ID: '$VMID' (>=100)."

read -rp "Linux-User in der VM [${DEFAULT_CIUSER}]: " CIUSER
CIUSER="${CIUSER:-$DEFAULT_CIUSER}"
echo -ne "${YW}Passwort für ${CIUSER} (Eingabe versteckt, PFLICHT): ${CL}"
read -rs CIPASS; echo ""
[[ -n "$CIPASS" ]] || die "Leeres Passwort – abgebrochen."

echo -e "\n${YW}Login braucht ALLOWED_SIGN_IN + Google- ODER Microsoft-OAuth.${CL}"
echo -e "${YW}Google Redirect-URI (später beim Provider eintragen): http://<VM-IP>:3001/api/auth/callback/google${CL}"
read -rp "ALLOWED_SIGN_IN (z.B. acme.com oder du@gmail.com): " ALLOW
if [[ -z "${ALLOW:-}" ]]; then
  echo -e "${RD}WARNUNG: leer = NIEMAND kann sich einloggen, bis du manuell ein IdP unter Settings → SSO einrichtest.${CL}"
fi
read -rp "GOOGLE_CLIENT_ID (leer = ohne Google): " GID
GIS=""; if [[ -n "${GID:-}" ]]; then echo -ne "${YW}GOOGLE_CLIENT_SECRET (versteckt): ${CL}"; read -rs GIS; echo ""; fi
read -rp "MICROSOFT_CLIENT_ID (leer = ohne Microsoft): " MID
MIS=""; if [[ -n "${MID:-}" ]]; then echo -ne "${YW}MICROSOFT_CLIENT_SECRET (versteckt): ${CL}"; read -rs MIS; echo ""; fi
echo -ne "${YW}AI_GATEWAY_API_KEY für den Agent (leer = Agent ohne Modell, versteckt): ${CL}"
read -rs AIKEY; echo ""

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

# ── Cloud-Init Snippets auf 'local' sicherstellen ────────────────────
msg_info "Prüfe Snippets-Support auf Storage '${var_snippet_store}'"
if ! grep -A5 "^dir: ${var_snippet_store}$" /etc/pve/storage.cfg 2>/dev/null | grep -q snippets; then
  cp -a /etc/pve/storage.cfg "/root/storage.cfg.bak.$(date +%s)"
  CUR=$(awk "/^dir: ${var_snippet_store}\$/{f=1} f&&/content/{print \$2; exit}" /etc/pve/storage.cfg)
  pvesm set "$var_snippet_store" --content "${CUR},snippets" >/dev/null \
    || die "Snippets lassen sich nicht aktivieren – manuell: pvesm set ${var_snippet_store} --content <alt>,snippets"
fi
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"
msg_ok "Snippets bereit"

# ── Cloud-Init User-Data mit Seed schreiben ──────────────────────────
# Single-Quote-Escaping für bash UND YAML-literal-Block: ' -> '\''
qesc() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
SNIPPET="compai-crm-${VMID}-user.yaml"
{
  echo "#cloud-config"
  echo "manage_etc_hosts: true"
  echo "package_update: true"
  echo "packages:"
  echo "  - qemu-guest-agent"
  echo "  - curl"
  echo "  - ca-certificates"
  echo "write_files:"
  echo "  - path: /root/crm-seed/install.env"
  echo "    owner: root:root"
  echo "    permissions: '0600'"
  echo "    content: |"
  echo "      CRM_ALLOWED_SIGN_IN='$(qesc "${ALLOW:-}")'"
  echo "      CRM_GOOGLE_CLIENT_ID='$(qesc "${GID:-}")'"
  echo "      CRM_GOOGLE_CLIENT_SECRET='$(qesc "${GIS:-}")'"
  echo "      CRM_MICROSOFT_CLIENT_ID='$(qesc "${MID:-}")'"
  echo "      CRM_MICROSOFT_CLIENT_SECRET='$(qesc "${MIS:-}")'"
  echo "      CRM_AI_GATEWAY_API_KEY='$(qesc "${AIKEY:-}")'"
  echo "runcmd:"
  echo "  - [systemctl, enable, --now, qemu-guest-agent]"
  echo "  - [bash, -c, \"wget -qO /usr/local/sbin/compai-crm.sh ${GUEST_SCRIPT_URL} && chmod +x /usr/local/sbin/compai-crm.sh && CRM_NONINTERACTIVE=1 bash /usr/local/sbin/compai-crm.sh\"]"
} > "${SNIPPET_DIR}/${SNIPPET}"
chmod 600 "${SNIPPET_DIR}/${SNIPPET}"
# Secrets aus Shell-Variablen löschen
GIS=""; MIS=""; AIKEY=""; CIPASS_KEEP="$CIPASS"
msg_ok "Cloud-Init-Seed geschrieben"

# ── Image + VM ───────────────────────────────────────────────────────
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
qm set "$VMID" --ide2 "${var_storage}:cloudinit" >/dev/null
qm set "$VMID" --ipconfig0 ip=dhcp --ciuser "$CIUSER" --cipassword "$CIPASS_KEEP" >/dev/null
CIPASS_KEEP=""  # RAM-only, nie auf Platte ausserhalb der VM-Config
qm set "$VMID" --cicustom "user=${var_snippet_store}:snippets/${SNIPPET}" >/dev/null
qm set "$VMID" --boot order=scsi0 --serial0 socket --vga serial0 >/dev/null
msg_ok "VM erstellt (Cloud-Init aktiv)"

msg_info "Starte VM"
qm start "$VMID" >/dev/null
msg_ok "VM gestartet – Erstinstallation läuft jetzt selbstständig (ca. 10–25 Min)"

# ── Warten: erst IP (Agent ODER ARP), dann Web-UI ───────────────────
# Robust auch ohne Guest-Agent: Fallback über MAC + ARP-Tabelle der Bridge.
get_vm_ip() {
  local ip mac bcast
  # 1) QEMU Guest-Agent
  ip=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null \
    | grep -oE '"ip-address":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | cut -d'"' -f4 \
    | grep -vE '^(127\.|169\.254\.)' | head -n1 || true)
  if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
  # 2) ARP-Tabelle: MAC aus der VM-Config, Broadcast-Ping füllt die Tabelle
  mac=$(qm config "$VMID" 2>/dev/null | grep -oiE '(virtio|e1000|vmxnet3)=[A-Fa-f0-9:]{17}' | cut -d= -f2 | head -n1 || true)
  if [[ -n "$mac" ]]; then
    bcast=$(ip -4 addr show dev "$var_bridge" 2>/dev/null | grep -oE 'brd [0-9.]+' | awk '{print $2}' | head -n1 || true)
    [[ -n "$bcast" ]] && ping -b -c2 -W2 "$bcast" >/dev/null 2>&1 || true
    ip=$(ip neigh show dev "$var_bridge" 2>/dev/null | grep -i "$mac" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
  fi
  return 1
}

msg_info "Warte auf VM-IP via Agent oder ARP (max. 10 Min)"
VM_IP=""
for i in $(seq 1 60); do
  if VM_IP=$(get_vm_ip 2>/dev/null); then break; fi
  VM_IP=""
  (( i % 6 == 0 )) && echo -e "  ${YW}noch keine IP (Versuch ${i}/60) – VM bootet / DHCP läuft${CL}"
  sleep 10
done
[[ -n "$VM_IP" ]] || die "Keine VM-IP gefunden (weder Agent noch ARP nach 10 Min) – prüfe DHCP/Bridge. Fortsetzen manuell: qm terminal ${VMID}, Log in VM: /var/log/compai-crm-install.log"
msg_ok "VM-IP: ${VM_IP}"

msg_info "Warte auf Web-UI http://${VM_IP}:3000 (max. ${var_wait_min} Min)"
END=$(( $(date +%s) + var_wait_min * 60 ))
N=0
while [[ $(date +%s) -lt $END ]]; do
  N=$((N+1))
  # DHCP-IP kann sich ändern -> alle ~2 Min neu auflösen
  if (( N % 8 == 0 )); then
    NEW_IP=$(get_vm_ip 2>/dev/null || true)
    if [[ -n "$NEW_IP" && "$NEW_IP" != "$VM_IP" ]]; then
      VM_IP="$NEW_IP"
      echo -e "\n  ${YW}neue VM-IP: ${VM_IP}${CL}"
    fi
  fi
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${VM_IP}:3000/" 2>/dev/null || echo "000")
  if [[ "$CODE" =~ ^(200|301|302|303|307|308)$ ]]; then
    echo ""
    echo -e "  ${CM} ${GN}FERTIG – Web-UI ist erreichbar, kein Terminal mehr nötig!${CL}"
    echo -e "  ${CM} CRM:  ${YW}http://${VM_IP}:3000${CL}"
    echo -e "  ${CM} API:  ${YW}http://${VM_IP}:3001${CL}"
    echo -e "  ${CM} Login: ${YW}OAuth-Button (Google/Microsoft) – nur Adressen aus '${ALLOW:-<ALLOWED_SIGN_IN fehlt!>}' kommen rein${CL}"
    echo -e "  ${CM} SSH (falls doch nötig): ${YW}ssh ${CIUSER}@${VM_IP}${CL}"
    echo ""
    exit 0
  fi
  echo -n "."
  sleep 15
done

echo ""
msg_error "Timeout nach ${var_wait_min} Min – Installation läuft in der VM ggf. weiter."
echo -e "  ${YW}Status prüfen:${CL} qm terminal ${VMID}  →  tail -f /var/log/compai-crm-install.log"
echo -e "  ${YW}Fertig-Datei:${CL}     cat /var/log/compai-crm-install.done"
echo -e "  ${YW}Fallback manuell:${CL} bash -c \"\$(wget -qLO - ${GUEST_SCRIPT_URL})\""
exit 1
