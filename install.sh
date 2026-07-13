#!/usr/bin/env bash
# ==============================================================================
# FibraOS — Instalador para Proxmox VE (LXC)
# ------------------------------------------------------------------------------
# Crea un contenedor LXC (Debian 12) con el stack completo de FibraOS corriendo
# en Docker (web:80 + api + postgres + redis) y lo deja listo para loguear.
#
# USO (en el HOST Proxmox, como root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/maverick0309/fibraos-deploy/main/install.sh)"
#
# o descargando este archivo y ejecutándolo:
#   FIBRAOS_TOKEN=github_pat_xxx ./fibraos-lxc.sh
#
# El código de FibraOS vive en un repo PRIVADO. Se descarga con un token de
# GitHub de SOLO LECTURA (fine-grained PAT, scope: repo fibra-os, Contents:Read).
# El token se pide en runtime y NUNCA se guarda en disco.
#
# Variables de entorno (todas opcionales salvo el token):
#   FIBRAOS_TOKEN   token GitHub RO (si no se pasa, se pide por prompt)
#   REPO            repo privado (def: maverick0309/fibra-os)
#   REF             rama/tag (def: main)
#   CTID            id del contenedor (def: siguiente libre)
#   HOSTNAME        nombre del CT (def: fibraos)
#   DISK_GB RAM_MB CORES   recursos (def: 20 / 4096 / 2)
#   BRIDGE STORAGE TEMPLATE_STORAGE   red/almacenamiento (def: vmbr0 / local-lvm / local)
#   ISP_NAME ISP_SLUG ADMIN_EMAIL ADMIN_PASSWORD ADMIN_NAME   datos del ISP demo
# ==============================================================================
set -Eeuo pipefail

# ── Config (env con defaults) ────────────────────────────────────────────────
REPO="${REPO:-maverick0309/fibra-os}"
REF="${REF:-main}"
HOSTNAME_CT="${HOSTNAME:-fibraos}"
DISK_GB="${DISK_GB:-20}"
RAM_MB="${RAM_MB:-4096}"
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
ISP_NAME="${ISP_NAME:-Demo ISP}"
ISP_SLUG="${ISP_SLUG:-demo}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@demo.local}"
ADMIN_NAME="${ADMIN_NAME:-Admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
FIBRAOS_TOKEN="${FIBRAOS_TOKEN:-}"
CTID="${CTID:-}"

# ── Logging estilo community-scripts ─────────────────────────────────────────
if [[ -t 1 ]]; then
  RD=$'\033[01;31m'; GN=$'\033[1;92m'; YW=$'\033[33m'; BL=$'\033[36m'; CL=$'\033[m'
else
  RD=""; GN=""; YW=""; BL=""; CL=""
fi
msg_info() { echo -e " ${YW}▶${CL} $*"; }
msg_ok()   { echo -e " ${GN}✔${CL} $*"; }
msg_err()  { echo -e " ${RD}✘${CL} $*" >&2; }
line()     { echo -e "${BL}------------------------------------------------------------${CL}"; }

CREATED_CTID=""
cleanup_on_err() {
  local code=$?
  msg_err "Falló la instalación (exit $code)."
  if [[ -n "$CREATED_CTID" ]]; then
    msg_info "Limpiando el contenedor $CREATED_CTID que quedó a medias…"
    pct stop "$CREATED_CTID" &>/dev/null || true
    pct destroy "$CREATED_CTID" &>/dev/null || true
    msg_ok "Contenedor $CREATED_CTID eliminado. Corrige el problema y reintenta."
  fi
  exit "$code"
}
trap cleanup_on_err ERR

# ── Pre-flight ───────────────────────────────────────────────────────────────
line
echo -e " ${GN}FibraOS — Instalador Proxmox LXC${CL}"
line
[[ $EUID -eq 0 ]]            || { msg_err "Ejecuta como root en el host Proxmox."; exit 1; }
command -v pct   >/dev/null || { msg_err "No es un host Proxmox VE (falta 'pct')."; exit 1; }
command -v pvesh >/dev/null || { msg_err "No es un host Proxmox VE (falta 'pvesh')."; exit 1; }
command -v pveam >/dev/null || { msg_err "No es un host Proxmox VE (falta 'pveam')."; exit 1; }

# Token: obligatorio. Prompt si hay TTY y no vino por env.
if [[ -z "$FIBRAOS_TOKEN" ]]; then
  if [[ -t 0 ]]; then
    read -rsp " $(echo -e "${YW}▶${CL}") Pega el token GitHub de SOLO LECTURA (no se mostrará): " FIBRAOS_TOKEN
    echo
  fi
fi
[[ -n "$FIBRAOS_TOKEN" ]] || { msg_err "Falta FIBRAOS_TOKEN (token GitHub RO)."; exit 1; }

# Verifica que el token puede leer el repo ANTES de crear nada.
msg_info "Validando el token contra $REPO…"
http=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${FIBRAOS_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}") || true
if [[ "$http" != "200" ]]; then
  msg_err "El token no puede leer ${REPO} (HTTP $http). Debe ser fine-grained, scope Contents:Read sobre ese repo."
  exit 1
fi
msg_ok "Token válido."

# Password admin: genera una si no vino.
[[ -n "$ADMIN_PASSWORD" ]] || ADMIN_PASSWORD="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-14)"
# CTID: siguiente libre si no vino.
[[ -n "$CTID" ]] || CTID="$(pvesh get /cluster/nextid)"

# ── Plantilla Debian 12 ──────────────────────────────────────────────────────
msg_info "Buscando plantilla Debian 12…"
TEMPLATE="$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/{print $2}' | sort -V | tail -1)"
[[ -n "$TEMPLATE" ]] || { msg_err "No encontré la plantilla debian-12-standard en 'pveam available'."; exit 1; }
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Descargando $TEMPLATE a $TEMPLATE_STORAGE…"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null
fi
msg_ok "Plantilla lista: $TEMPLATE"

# ── Crear el LXC ─────────────────────────────────────────────────────────────
msg_info "Creando LXC $CTID ($HOSTNAME_CT) — ${CORES} vCPU / ${RAM_MB} MB / ${DISK_GB} GB…"
# nesting=1 + keyctl=1 son necesarios para correr Docker dentro de un LXC unprivileged.
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME_CT" \
  --cores "$CORES" --memory "$RAM_MB" --swap "$RAM_MB" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --features "nesting=1,keyctl=1" \
  --unprivileged 1 --onboot 1 >/dev/null
CREATED_CTID="$CTID"
pct start "$CTID" >/dev/null
msg_ok "Contenedor $CTID creado y arrancado."

# Esperar IP por DHCP
msg_info "Esperando IP por DHCP…"
IP=""
for _ in $(seq 1 30); do
  IP="$(pct exec "$CTID" -- bash -c "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
  [[ -n "$IP" ]] && break
  sleep 2
done
[[ -n "$IP" ]] || { msg_err "El contenedor no obtuvo IP (revisa el bridge $BRIDGE)."; exit 1; }
msg_ok "IP del contenedor: $IP"

# ── Script de aprovisionamiento DENTRO del contenedor ────────────────────────
# Se envía por stdin (no toca disco del host). El TOKEN llega por stdin como
# primera línea (nunca aparece en 'ps' del host).
read -r -d '' PROVISION <<'PROVISION_EOF' || true
set -Eeuo pipefail
read -r FIBRAOS_TOKEN   # primera línea del stdin = token (no se escribe a disco)
export DEBIAN_FRONTEND=noninteractive
REPO="__REPO__"; REF="__REF__"
ISP_NAME="__ISP_NAME__"; ISP_SLUG="__ISP_SLUG__"
ADMIN_EMAIL="__ADMIN_EMAIL__"; ADMIN_PASSWORD="__ADMIN_PASSWORD__"; ADMIN_NAME="__ADMIN_NAME__"

echo "[CT] Instalando dependencias base…"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg openssl tar >/dev/null

echo "[CT] Instalando Docker…"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1 || true

echo "[CT] Descargando FibraOS (tarball privado por API)…"
mkdir -p /opt/fibraos
curl -fsSL -H "Authorization: Bearer ${FIBRAOS_TOKEN}" \
     -H "Accept: application/vnd.github+json" \
     "https://api.github.com/repos/${REPO}/tarball/${REF}" -o /tmp/fibraos.tgz
tar xzf /tmp/fibraos.tgz -C /opt/fibraos --strip-components=1
rm -f /tmp/fibraos.tgz
unset FIBRAOS_TOKEN   # el token ya no se necesita
cd /opt/fibraos

echo "[CT] Generando .env (SECRET_KEY + password DB frescos)…"
PGPASS="$(openssl rand -hex 16)"
SECRET="$(openssl rand -hex 32)"
cp .env.prod.example .env
sed -i "s|CAMBIA_ESTA_PASSWORD|${PGPASS}|g" .env
sed -i "s|SECRET_KEY=.*|SECRET_KEY=${SECRET}|" .env

echo "[CT] Levantando el stack (docker compose build, puede tardar unos minutos)…"
docker compose -f docker-compose.prod.yml up -d --build

echo "[CT] Esperando a que la API responda…"
for _ in $(seq 1 60); do
  curl -sf http://localhost/api/health >/dev/null 2>&1 && break
  sleep 3
done
curl -sf http://localhost/api/health >/dev/null 2>&1 || { echo "[CT] La API no respondió a tiempo"; docker compose -f docker-compose.prod.yml ps; exit 1; }

echo "[CT] Creando el ISP demo + usuario admin…"
docker compose -f docker-compose.prod.yml exec -T api \
  python scripts/bootstrap_isp.py \
    --isp-name "${ISP_NAME}" --slug "${ISP_SLUG}" \
    --admin-email "${ADMIN_EMAIL}" --admin-password "${ADMIN_PASSWORD}" \
    --admin-name "${ADMIN_NAME}" || echo "[CT] (bootstrap: el ISP quizá ya existía, se ignora)"

echo "[CT] OK"
PROVISION_EOF

# Sustituir placeholders de forma segura (los valores no llevan '|')
PROVISION="${PROVISION//__REPO__/$REPO}"
PROVISION="${PROVISION//__REF__/$REF}"
PROVISION="${PROVISION//__ISP_NAME__/$ISP_NAME}"
PROVISION="${PROVISION//__ISP_SLUG__/$ISP_SLUG}"
PROVISION="${PROVISION//__ADMIN_EMAIL__/$ADMIN_EMAIL}"
PROVISION="${PROVISION//__ADMIN_PASSWORD__/$ADMIN_PASSWORD}"
PROVISION="${PROVISION//__ADMIN_NAME__/$ADMIN_NAME}"

msg_info "Aprovisionando FibraOS dentro del contenedor (Docker + build + arranque)…"
# 1) El script (SIN token) se escribe como archivo dentro del CT.
printf '%s' "$PROVISION" | pct exec "$CTID" -- bash -c 'cat > /root/fibraos-provision.sh'
# 2) Se ejecuta pasando SOLO el token por stdin (lo lee 'read' dentro del script).
#    Así el token nunca aparece en argumentos ('ps') ni se escribe a disco.
printf '%s\n' "$FIBRAOS_TOKEN" | pct exec "$CTID" -- bash /root/fibraos-provision.sh
# 3) Limpieza del script auxiliar.
pct exec "$CTID" -- rm -f /root/fibraos-provision.sh
msg_ok "FibraOS aprovisionado."

# ── Resumen ──────────────────────────────────────────────────────────────────
trap - ERR
line
msg_ok "FibraOS instalado en el contenedor ${CTID}."
line
echo -e "  ${BL}URL:${CL}         http://${IP}/"
echo -e "  ${BL}Admin:${CL}       ${ADMIN_EMAIL}"
echo -e "  ${BL}Password:${CL}     ${ADMIN_PASSWORD}"
echo -e "  ${BL}ISP:${CL}         ${ISP_NAME} (${ISP_SLUG})"
echo
echo -e "  ${BL}.env:${CL}        /opt/fibraos/.env  (dentro del CT — passwords generadas)"
echo -e "  ${BL}Logs:${CL}        pct exec ${CTID} -- docker compose -f /opt/fibraos/docker-compose.prod.yml logs -f api"
echo
echo -e "  ${YW}Nota:${CL} para ver datos de OLT reales, el contenedor debe ALCANZAR las"
echo -e "        OLTs/MikroTik del ISP (LAN o VPN WireGuard). Para probar la app/UI"
echo -e "        no hace falta: entra con el admin y añade una OLT alcanzable."
line
