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

# Fortschritt + Dauer für visuelle Rückmeldung
STEPS=7; STEP=0; START_TS=$SECONDS
step() { STEP=$((STEP+1)); echo ""; msg_info "[${STEP}/${STEPS}] ${1}"; }
elapsed() { local s=$((SECONDS-START_TS)); printf '%02d:%02d Min.' $((s/60)) $((s%60)); }

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

# Prüft ALLOWED_SIGN_IN: eine E-Mail, eine Domain oder Komma-Mix aus beidem.
valid_allow() {
  local v="${1//[[:space:]]/}" part
  [[ -n "$v" ]] || return 1
  IFS=',' read -ra parts <<< "$v"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then continue; fi
    if [[ "$part" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; then continue; fi
    return 1
  done
  return 0
}

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
echo -ne "${YW}Passwort für ${CIUSER} (versteckt, LEER = Zufallspasswort): ${CL}"
read -rs CIPASS; echo ""
GENPASS=""
if [[ -z "${CIPASS:-}" ]]; then
  CIPASS="crm-$(openssl rand -hex 8)"
  GENPASS=1
fi

echo -e "\n${YW}Netzwerk in der VM (falls dein Netz kein DHCP hat: statisch wählen):${CL}"
read -rp "Statische IP statt DHCP? [j/N]: " STATIC_NOW
IP_STATIC=""; IP_GW=""; IP_DNS="1.1.1.1"
if [[ "${STATIC_NOW:-}" =~ ^[Jj]$ ]]; then
  read -rp "  IP mit Netzmaske (z.B. 192.168.178.50/24): " IP_STATIC
  read -rp "  Gateway (z.B. 192.168.178.1): " IP_GW
  read -rp "  DNS [1.1.1.1]: " _DNS; IP_DNS="${_DNS:-1.1.1.1}"
  [[ "$IP_STATIC" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || die "IP-Format ungültig (erwartet z.B. 192.168.178.50/24)."
  [[ -n "$IP_GW" ]] || die "Gateway fehlt."
fi

echo -e "\n${YW}Login: Nur die E-Mail/Domain ist PFLICHT (die API startet ohne gar nicht).${CL}"
echo -e "  Beispiele: ${GN}du@gmail.com${CL}  oder  ${GN}firma.de${CL}  (ganze Domain = alle Adressen dort)"
echo -e "  Abbruch jederzeit mit ${YW}Strg+C${CL}."
ALLOW=""
while true; do
  read -rp "ALLOWED_SIGN_IN: " ALLOW
  ALLOW="${ALLOW//[[:space:]]/}"
  if valid_allow "$ALLOW"; then break; fi
  echo -e "  ${RD}'${ALLOW:-<leer>}' ist keine gültige E-Mail oder Domain – bitte erneut eingeben.${CL}"
  ALLOW=""
done
echo -e "  ${CM} ${GN}Übernommen: ${ALLOW}${CL}"
GID=""; GIS=""; MID=""; MIS=""; AIKEY=""
read -rp "OAuth/Modell-Keys jetzt eintragen? [j/N]: " OAUTH_NOW
if [[ "${OAUTH_NOW:-}" =~ ^[Jj]$ ]]; then
  read -rp "  GOOGLE_CLIENT_ID (leer = ohne Google): " GID
  if [[ -n "${GID:-}" ]]; then echo -ne "  ${YW}GOOGLE_CLIENT_SECRET (versteckt): ${CL}"; read -rs GIS; echo ""; fi
  read -rp "  MICROSOFT_CLIENT_ID (leer = ohne Microsoft): " MID
  if [[ -n "${MID:-}" ]]; then echo -ne "  ${YW}MICROSOFT_CLIENT_SECRET (versteckt): ${CL}"; read -rs MIS; echo ""; fi
  echo -ne "  ${YW}AI_GATEWAY_API_KEY = Agent-Modell (versteckt, leer = ohne): ${CL}"
  read -rs AIKEY; echo ""
fi

if qm status "$VMID" >/dev/null 2>&1; then
  echo -ne "${YW}VM ${VMID} existiert. Löschen und neu erstellen? (j/n) ${CL}"
  read -r -n 1 REPLY; echo
  [[ $REPLY =~ ^[Jj]$ ]] || die "Abgebrochen."
  msg_info "Stoppe VM ${VMID}"
  qm stop "$VMID" >/dev/null 2>&1 || true; sleep 3
  msg_info "Lösche VM ${VMID}"
  qm destroy "$VMID" --purge >/dev/null 2>&1 || true; sleep 2
  rm -f /var/lib/vz/snippets/compai-crm-"${VMID}"-*.yaml 2>/dev/null || true
  msg_ok "Gelöscht"
fi

# ── Cloud-Init Snippets auf 'local' sicherstellen ────────────────────
step "Cloud-Init-Snippets auf '${var_snippet_store}'"
if ! grep -A5 "^dir: ${var_snippet_store}$" /etc/pve/storage.cfg 2>/dev/null | grep -q snippets; then
  cp -a /etc/pve/storage.cfg "/root/storage.cfg.bak.$(date +%s)"
  CUR=$(awk "/^dir: ${var_snippet_store}\$/{f=1} f&&/content/{print \$2; exit}" /etc/pve/storage.cfg)
  [[ -n "$CUR" ]] || die "Storage-Abschnitt 'dir: ${var_snippet_store}' in /etc/pve/storage.cfg nicht gefunden – Snippets manuell aktivieren: pvesm set ${var_snippet_store} --content <bisher>,snippets"
  pvesm set "$var_snippet_store" --content "${CUR},snippets" >/dev/null \
    || die "Snippets lassen sich nicht aktivieren – manuell: pvesm set ${var_snippet_store} --content <alt>,snippets"
fi
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"
msg_ok "Snippets bereit"

# ── Cloud-Init Vendor-Data mit Seed schreiben ────────────────────────
# WICHTIG: vendor= (nicht user=) – Vendor-Data wird mit der PVE-User-Config
# (ciuser/cipassword/ipconfig) zusammengeführt; user= würde sie ERSETZEN.
qesc() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
SNIPPET="compai-crm-${VMID}-vendor.yaml"
step "Installations-Seed für die VM schreiben"
{
  echo "#cloud-config  # vendor-data: läuft zusätzlich zur PVE-User-Config"
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
# Secrets aus Shell-Variablen löschen (RAM-only ab hier)
CIPASS_KEEP="$CIPASS"; CIPASS=""
GIS=""; MIS=""; AIKEY=""
msg_ok "Cloud-Init-Seed geschrieben"

# ── Image + VM ───────────────────────────────────────────────────────
step "Debian-Cloud-Image"
IMG_PATH="/var/lib/vz/template/iso/${DEBIAN_IMG}"
if [[ ! -f "$IMG_PATH" ]]; then
  mkdir -p "$(dirname "$IMG_PATH")"
  wget -qO "$IMG_PATH" "$DEBIAN_URL" || die "Download fehlgeschlagen: $DEBIAN_URL"
fi
msg_ok "Image bereit"

step "VM ${VMID} erstellen (qm create)"
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
qm set "$VMID" --ide2 "${var_snippet_store}:cloudinit" >/dev/null 2>&1 \
  || qm set "$VMID" --ide2 "${var_storage}:cloudinit" >/dev/null \
  || die "Cloud-Init-Disk lässt sich nicht anlegen (Storage prüfen)."
if [[ -n "${IP_STATIC:-}" ]]; then
  qm set "$VMID" --ipconfig0 "ip=${IP_STATIC},gw=${IP_GW}" --nameserver "${IP_DNS}" --ciuser "$CIUSER" --cipassword "$CIPASS_KEEP" >/dev/null
else
  qm set "$VMID" --ipconfig0 ip=dhcp --ciuser "$CIUSER" --cipassword "$CIPASS_KEEP" >/dev/null
fi
if [[ -n "${GENPASS:-}" ]]; then
  printf 'VM %s | User %s | Passwort %s\n' "$VMID" "$CIUSER" "$CIPASS_KEEP" > "/root/compai-crm-${VMID}.cred"
  chmod 600 "/root/compai-crm-${VMID}.cred"
fi
CIPASS_KEEP=""  # RAM-only, nie auf Platte ausserhalb der VM-Config
qm set "$VMID" --cicustom "vendor=${var_snippet_store}:snippets/${SNIPPET}" >/dev/null
qm set "$VMID" --boot order=scsi0 --serial0 socket --vga serial0 >/dev/null
msg_ok "VM erstellt (Cloud-Init aktiv)"

step "VM starten"
qm start "$VMID" >/dev/null
msg_ok "VM gestartet – Erstinstallation läuft jetzt selbstständig (ca. 10–25 Min)"

# ── Warten: erst IP (Agent ODER ARP), dann Web-UI ───────────────────
# Robust auch ohne Guest-Agent: Fallback über MAC + ARP-Tabelle der Bridge.
get_vm_ip() {
  local ip mac bcast
  # 1) QEMU Guest-Agent (Proxmox-JSON hat Leerzeichen um ':', daher tolerant matchen)
  ip=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null \
    | grep -oE '"ip-address"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
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

# Führt einen Befehl per Guest-Agent synchron aus, gibt stdout zurück (base64-decodiert).
guest_run() {
  local pid st out i
  pid=$(qm guest exec "$VMID" -- "$@" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)
  [[ -n "$pid" ]] || return 1
  for i in $(seq 1 30); do
    sleep 2
    st=$(qm guest exec-status "$VMID" "$pid" 2>/dev/null || true)
    if echo "$st" | grep -q '"exited"[[:space:]]*:[[:space:]]*true'; then
      out=$(echo "$st" | grep -oE '"out-data"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || true)
      if [[ -n "$out" ]]; then printf '%s' "$out" | base64 -d 2>/dev/null || true; fi
      return 0
    fi
  done
  return 1
}

step "VM-IP finden (Agent → ARP → DHCP-Heilung → Auto-Static, max. 10 Min)"
VM_IP=""
for i in $(seq 1 60); do
  if VM_IP=$(get_vm_ip 2>/dev/null); then break; fi
  VM_IP=""
  if (( i % 6 == 0 )); then
    AGENT="nein"
    if qm guest cmd "$VMID" network-get-interfaces >/dev/null 2>&1; then AGENT="läuft, meldet aber noch kein IPv4"; fi
    TAP="down/fehlt"
    if ip link show "tap${VMID}i0" 2>/dev/null | grep -qE 'state (UP|UNKNOWN)'; then TAP="up"; fi
    NBR=$(ip neigh show dev "$var_bridge" 2>/dev/null | wc -l)
    echo -e "  ${YW}noch keine IP (${i}/60): Agent=${AGENT}, tap=${TAP}, ARP-Einträge=${NBR}${CL}"
  fi
  sleep 10
done
# Selbstheilung: Agent lebt, aber kein IPv4 (DHCPv4 hängt) -> DHCP im Gast anstoßen
if [[ -z "$VM_IP" ]] && qm guest cmd "$VMID" network-get-interfaces >/dev/null 2>&1; then
  echo -e "  ${YW}Agent lebt ohne IPv4 – stoße DHCP im Gast an (dhclient eth0)${CL}"
  qm guest exec "$VMID" -- sh -c 'dhclient -4 -v eth0 2>&1 | tail -3 || dhclient eth0' >/dev/null 2>&1 || true
  for i in $(seq 1 12); do
    if VM_IP=$(get_vm_ip 2>/dev/null); then
      echo -e "  ${CM} ${GN}DHCP-Anstoß erfolgreich: ${VM_IP}${CL}"
      break
    fi
    VM_IP=""
    sleep 10
  done
fi
# Auto-Static-Fallback: DHCP liefert partout nichts -> freie IP suchen, setzen, rebooten
if [[ -z "$VM_IP" ]]; then
  echo -e "  ${YW}DHCP liefert keine IPv4 – versuche Auto-Static-IP${CL}"
  BR_CIDR=$(ip -4 addr show dev "$var_bridge" 2>/dev/null | grep -oE 'inet [0-9./]+' | awk '{print $2}' | head -n1 || true)
  GW=$(ip route show default dev "$var_bridge" 2>/dev/null | grep -oE 'via [0-9.]+' | awk '{print $2}' | head -n1 || true)
  if [[ -n "$BR_CIDR" && -n "$GW" ]]; then
    NET_BASE="${BR_CIDR%/*}"; NET_BASE="${NET_BASE%.*}"
    PREFIX="${BR_CIDR#*/}"
    CAND=""
    for last in $(seq 250 -1 230); do
      try="${NET_BASE}.${last}"
      if [[ "$try" == "$GW" ]]; then continue; fi
      if ! ping -c1 -W1 "$try" >/dev/null 2>&1; then
        if ! ip neigh show dev "$var_bridge" 2>/dev/null | grep -qE "^${try}[[:space:]]+.*(REACHABLE|STALE|DELAY|PROBE|PERMANENT)"; then
          CAND="$try"; break
        fi
      fi
    done
    if [[ -n "$CAND" ]]; then
      msg_info "Setze statisch ${CAND}/${PREFIX} via ${GW}, reboote VM"
      qm set "$VMID" --ipconfig0 "ip=${CAND}/${PREFIX},gw=${GW}" --nameserver "1.1.1.1" >/dev/null
      qm reboot "$VMID" >/dev/null 2>&1 || { qm stop "$VMID" >/dev/null 2>&1 || true; sleep 3; qm start "$VMID" >/dev/null; }
      msg_info "Warte auf Reboot + statische IP (max. 10 Min)"
      for i in $(seq 1 60); do
        if VM_IP=$(get_vm_ip 2>/dev/null); then break; fi
        VM_IP=""
        sleep 10
      done
      if [[ -n "$VM_IP" ]]; then msg_ok "VM-IP (statisch): ${VM_IP}"; fi
    else
      echo -e "  ${YW}keine freie IP im Bereich ${NET_BASE}.230-250 gefunden${CL}"
    fi
  else
    echo -e "  ${YW}Auto-Static unmöglich (Bridge ${var_bridge} hat keine eigene IPv4 oder kein Default-Gateway)${CL}"
  fi
fi
if [[ -z "$VM_IP" ]]; then
  echo -e "${YW}--- Netzwerk-Diagnose ---${CL}" >&2
  qm status "$VMID" 2>&1 >&2 || true
  qm config "$VMID" 2>&1 | grep -Ei '^(net0|ipconfig|agent|boot|cicustom|ide2|scsi0|nameserver)' >&2 || true
  echo "tap-Interface:" >&2; ip link show "tap${VMID}i0" 2>&1 >&2 || true
  echo "ARP-Tabelle ${var_bridge}:" >&2; ip neigh show dev "$var_bridge" 2>&1 >&2 || true
  echo "Agent-Antwort:" >&2; qm guest cmd "$VMID" network-get-interfaces 2>&1 | head -c 1500 >&2 || true
  echo "" >&2
  die "Keine VM-IP nach 10 Min (auch nicht per Auto-Static). Ursachen: kein DHCP + kein freier Bereich .230-250, oder VM hängt im Boot (qm terminal ${VMID}). Tipp: neu starten + statische IP manuell wählen. Die VM installiert ggf. weiter – Log in VM: /var/log/compai-crm-install.log"
fi
msg_ok "VM-IP: ${VM_IP}"

step "Auf Web-UI warten http://${VM_IP}:3000 (Erstbuild, max. ${var_wait_min} Min)"
END=$(( $(date +%s) + var_wait_min * 60 ))
N=0; LAST_STEP=""
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
  # Live-Fortschritt: letzte Installer-Zeile aus der VM holen (~alle 2,5 Min)
  if (( N % 10 == 1 )); then
    GSTEP=$(guest_run grep -aE '\[[0-9]+/[0-9]+\]|✓|FEHLER|WARNUNG' /var/log/compai-crm-install.log 2>/dev/null | tail -n1 || true)
    if [[ -n "$GSTEP" && "$GSTEP" != "$LAST_STEP" ]]; then
      LAST_STEP="$GSTEP"
      echo -e "\n  ${BL}VM meldet: ${GSTEP}${CL}"
    fi
  fi
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://${VM_IP}:3000/" 2>/dev/null || echo "000")
  if [[ "$CODE" =~ ^(200|301|302|303|307|308)$ ]]; then
    echo ""
    echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo -e "${GN}  ✓ FERTIG nach $(elapsed) – CompAI CRM ist erreichbar!${CL}"
    echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo -e "  Web-UI .... ${YW}http://${VM_IP}:3000${CL}"
    echo -e "  API ....... ${YW}http://${VM_IP}:3001${CL}"
    if [[ -n "${GENPASS:-}" ]]; then
      echo -e "  SSH ....... ${YW}ssh ${CIUSER}@${VM_IP}${CL}  (Passwort: ${YW}/root/compai-crm-${VMID}.cred${CL} auf dem Host)"
    else
      echo -e "  SSH ....... ${YW}ssh ${CIUSER}@${VM_IP}${CL}"
    fi
    echo -e "  Status .... ${YW}crm-status${CL}  (in der VM: Dienste, Login-Check, URLs)"
    echo -e "  VM-ID ..... ${YW}${VMID}${CL}  (onboot=1, reboot-sicher)"
    if [[ -z "${GID:-}" && -z "${MID:-}" ]]; then
      echo -e "  Login ..... ${YW}OAuth-Keys fehlen noch${CL} – einmalig nachtragen:"
      echo -e "    ${YW}1.${CL} Google/Microsoft-OAuth-Client anlegen (Upstream-README, 2 Min)"
      echo -e "       Redirect-URI: ${YW}http://${VM_IP}:3001/api/auth/callback/google${CL}"
      echo -e "    ${YW}2.${CL} qm terminal ${VMID}  (oder ssh ${CIUSER}@${VM_IP})"
      echo -e "    ${YW}3.${CL} sudo nano /opt/compai-crm/.env   # ALLOWED_SIGN_IN + CLIENT_ID/SECRET setzen"
      echo -e "    ${YW}4.${CL} sudo systemctl restart compai-crm-api compai-crm-app"
    else
      echo -e "  Login ..... ${GN}OAuth-Button – nur '${ALLOW}' kommt rein${CL}"
    fi
    echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
    echo ""
    exit 0
  fi
  echo -n "."
  sleep 15
done

echo ""
msg_error "Timeout nach ${var_wait_min} Min ($(elapsed) vergangen) – hole Diagnose aus der VM..."
DONE_URL=$(guest_run cat /var/log/compai-crm-install.done 2>/dev/null || true)
if [[ -n "$DONE_URL" ]]; then
  echo -e "  ${CM} ${GN}Installation war FERTIG: ${DONE_URL} – bitte im Browser prüfen!${CL}"
else
  echo -e "  ${YW}--- Dienste in der VM ---${CL}"
  guest_run systemctl is-active compai-crm-app compai-crm-api compai-crm-agent 2>/dev/null || echo "  (Agent-Abfrage fehlgeschlagen)"
  echo -e "  ${YW}--- Log-Ende (/var/log/compai-crm-install.log) ---${CL}"
  guest_run tail -n 25 /var/log/compai-crm-install.log 2>/dev/null || echo "  (kein Log abrufbar – Installer lief evtl. nie: Cloud-Init prüfen)"
fi
echo -e "  ${YW}Manuell:${CL}  qm terminal ${VMID}  →  tail -f /var/log/compai-crm-install.log"
echo -e "  ${YW}Fallback:${CL} bash -c \"\$(wget -qLO - ${GUEST_SCRIPT_URL})\""
exit 1
