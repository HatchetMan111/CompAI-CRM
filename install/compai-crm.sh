#!/usr/bin/env bash
# CompAI CRM – Guest-Installer für Debian 12 VM (idempotent)
# Einzeiler IN der VM:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CompAI-CRM/main/install/compai-crm.sh)"
# Installiert: Postgres 15 + Bun 1.3.12 + Node 22 + trycompai/crm (Branch release)
# Dienste: compai-crm-api(:3001), compai-crm-app(:3000), compai-crm-agent(:2000)
# Debug: DEBUG=1 bash -x install/compai-crm.sh  (volles xtrace)

APP="compai-crm"
APP_DIR="/opt/compai-crm"
APP_BRANCH="release"
APP_PORT="3000"; API_PORT="3001"; AGENT_PORT="2000"
BUN_VERSION="1.3.12"

YW='\033[33m'; GN='\033[1;32m'; RD='\033[1;31m'; BL='\033[36m'; CL='\033[m'
CM="${GN}✓${CL}"; CR="${RD}✗${CL}"

set -Eeuo pipefail
[[ "${DEBUG:-0}" == "1" ]] && set -x

msg_info() { echo -e "${YW}● ${CL}${BL}${1}...${CL}"; }
msg_ok()   { echo -e "${CM} ${GN}${1}${CL}"; }

error_handler() {
  local ec=$? line=${1:-?} cmd=${BASH_COMMAND:-?}
  echo -e "\n${CR} ${RD}FEHLER Zeile ${line} (Exit ${ec}): ${cmd}${CL}" >&2
  echo -e "${YW}--- Stacktrace ---${CL}" >&2
  local i=0; while caller $i >&2; do i=$((i+1)); done
  echo -e "${YW}--- Service-Logs (falls vorhanden) ---${CL}" >&2
  for s in compai-crm-api compai-crm-app compai-crm-agent postgresql; do
    echo -e "${BL}## ${s} ##${CL}" >&2
    systemctl --no-pager status "$s" 2>&1 | head -n 20 >&2 || true
    journalctl -u "$s" -n 20 --no-pager 2>&1 >&2 || true
  done
  echo -e "${YW}Re-Run mit: DEBUG=1 bash -x $0${CL}" >&2
  exit "$ec"
}
trap 'error_handler $LINENO' ERR

[[ "$(id -u)" == "0" ]] || { echo -e "${CR} Als root ausführen.${CL}" >&2; exit 1; }
command -v apt-get >/dev/null || { echo "Nur Debian/Ubuntu." >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C

msg_info "Installiere Systempakete (postgres, curl, git, openssl)"
apt-get update -qq
apt-get install -y -qq curl git ca-certificates openssl postgresql postgresql-contrib unzip >/dev/null
systemctl enable --now postgresql >/dev/null
msg_ok "Postgres läuft"

if ! command -v bun >/dev/null 2>&1; then
  msg_info "Installiere Bun ${BUN_VERSION}"
  curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash -s -- "bun-v${BUN_VERSION}" >/dev/null
  ln -sf /usr/local/bin/bun /usr/bin/bun
fi
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | cut -d. -f1 | tr -dc 0-9)" -lt 22 ]]; then
  msg_info "Installiere Node.js 22 (nodesource)"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
msg_ok "Bun $(bun --version) / Node $(node --version)"

msg_info "Lege Postgres-DB an (crm/crm)"
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='crm'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE USER crm WITH PASSWORD 'crm' CREATEDB;"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='crm'" | grep -q 1 \
  || sudo -u postgres createdb -O crm crm
msg_ok "DB bereit"

msg_info "Klone/updatete ${APP} (${APP_BRANCH})"
if [[ -d "${APP_DIR}/.git" ]]; then
  git -C "$APP_DIR" fetch --depth 1 origin "$APP_BRANCH"
  git -C "$APP_DIR" reset --hard "origin/${APP_BRANCH}"
else
  rm -rf "$APP_DIR"
  git clone --depth 1 --branch "$APP_BRANCH" https://github.com/trycompai/crm.git "$APP_DIR"
fi
msg_ok "Code bereit"

msg_info "Erstelle / ergänze .env (idempotent, Secrets bleiben)"
ENV_FILE="${APP_DIR}/.env"
[[ -f "$ENV_FILE" ]] || cp "${APP_DIR}/.env.example" "$ENV_FILE"
grep -q '^BETTER_AUTH_SECRET=.*[A-Za-z0-9]' "$ENV_FILE" \
  || sed -i "s|^BETTER_AUTH_SECRET=.*|BETTER_AUTH_SECRET=\"$(openssl rand -base64 32)\"|" "$ENV_FILE"
grep -q '^DATABASE_URL=' "$ENV_FILE" \
  || echo 'DATABASE_URL="postgresql://crm:crm@localhost:5432/crm?schema=public"' >> "$ENV_FILE"
if ! grep -q '^ALLOWED_SIGN_IN=.*[A-Za-z0-9@.]' "$ENV_FILE"; then
  echo ""
  echo -e "${YW}PFLICHT: Ohne ALLOWED_SIGN_IN + Google/Microsoft-OAuth gibt es KEINEN Login.${CL}"
  echo -e "${YW}README: Google Redirect-URI = http://<VM-IP>:3001/api/auth/callback/google${CL}"
  read -rp "ALLOWED_SIGN_IN (z.B. acme.com oder du@gmail.com, leer=später manuell): " ALLOW
  [[ -n "${ALLOW:-}" ]] && sed -i "s|^ALLOWED_SIGN_IN=.*|ALLOWED_SIGN_IN=\"${ALLOW}\"|" "$ENV_FILE" || true
fi
# shellcheck disable=SC1091
set -a; source "$ENV_FILE"; set +a
msg_ok ".env ok"

msg_info "bun install + db:deploy + build (dauert Minuten)"
cd "$APP_DIR"
bun install
bun run db:deploy
bun run build
msg_ok "Build fertig"

write_unit() { cat > "/etc/systemd/system/${1}"; systemctl daemon-reload; systemctl enable "$1" >/dev/null; }

msg_info "Schreibe systemd-Units"
write_unit compai-crm-api.service <<EOF
[Unit]
Description=CompAI CRM API (NestJS :${API_PORT})
After=network-online.target postgresql.service
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=${APP_DIR}/apps/api
EnvironmentFile=${APP_DIR}/.env
Environment=PORT=${API_PORT}
ExecStart=/usr/local/bin/bun dist/main.js
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
write_unit compai-crm-app.service <<EOF
[Unit]
Description=CompAI CRM App (Next.js :${APP_PORT})
After=network-online.target compai-crm-api.service
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=${APP_DIR}/apps/app
EnvironmentFile=${APP_DIR}/.env
Environment=PORT=${APP_PORT}
ExecStart=/usr/local/bin/bun start -p ${APP_PORT}
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
write_unit compai-crm-agent.service <<EOF
[Unit]
Description=CompAI CRM Agent (Eve :${AGENT_PORT})
After=network-online.target compai-crm-api.service
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=${APP_DIR}/apps/agent
EnvironmentFile=${APP_DIR}/.env
Environment=AGENT_PORT=${AGENT_PORT}
ExecStart=/usr/local/bin/bun src/index.ts
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
msg_ok "Units geschrieben + enabled"

msg_info "Starte Dienste"
systemctl restart compai-crm-api compai-crm-app compai-crm-agent
sleep 5

msg_info "Verifiziere (systemctl + HTTP)"
for s in compai-crm-api compai-crm-app compai-crm-agent; do
  systemctl is-active --quiet "$s" || {
    echo "Service $s NICHT aktiv – volle Logs:" >&2
    journalctl -u "$s" -n 50 --no-pager >&2
    exit 1
  }
done
curl -fsS "http://localhost:${API_PORT}/api/health" >/dev/null 2>&1 \
  || curl -fsS "http://localhost:${API_PORT}/" >/dev/null \
  || { echo "API antwortet nicht auf localhost:${API_PORT} (Exit $?)" >&2; journalctl -u compai-crm-api -n 50 --no-pager >&2; exit 1; }
curl -fsS "http://localhost:${APP_PORT}/" >/dev/null \
  || { echo "App antwortet nicht auf localhost:${APP_PORT}" >&2; journalctl -u compai-crm-app -n 50 --no-pager >&2; exit 1; }
msg_ok "Verifikation ok"

VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo -e "  ${CM} ${GN}CompAI CRM installiert + reboot-sicher (systemd, onboot=1 an der VM setzen).${CL}"
echo -e "  ${CM} App:   ${YW}http://${VM_IP:-<VM-IP>}:${APP_PORT}${CL}"
echo -e "  ${CM} API:   ${YW}http://${VM_IP:-<VM-IP>}:${API_PORT}${CL}"
echo -e "  ${CM} Update:  ${YW}cd ${APP_DIR} && git pull && bun install && bun run db:deploy && bun run build && systemctl restart compai-crm-*${CL}"
echo -e "  ${CM} Deinstall: ${YW}systemctl disable --now compai-crm-*; rm -rf ${APP_DIR}${CL}"
echo -e "  ${CM} Logs:  ${YW}journalctl -u compai-crm-api -f / -u compai-crm-app -f / -u compai-crm-agent -f${CL}"
echo ""
