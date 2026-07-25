#!/usr/bin/env bash
# ==============================================================================
# FibraOS — Instalador para Proxmox VE (LXC)
# ------------------------------------------------------------------------------
# Detecta automáticamente la versión de Proxmox VE y aplica la configuración
# correcta para Docker en LXC unprivileged:
#
#   PVE 8 (Debian 12, kernel 6.2-6.8):
#     - AppArmor unconfined + reglas cgroup2 en el config del LXC
#     - fuse-overlayfs como storage driver de Docker
#
#   PVE 9 (Debian 13, kernel 6.8+):
#     - AppArmor unconfined en el config del LXC
#     - overlay2 nativo (kernel 6.8+ lo soporta sin fuse)
#     - Plantilla Debian 13 (fallback a Debian 12)
#
# USO (en el HOST Proxmox, como root):
#   FIBRAOS_TOKEN=github_pat_xxx ./install.sh
#
# Variables de entorno (todas opcionales salvo el token):
#   FIBRAOS_TOKEN   token GitHub RO (si no se pasa, se pide por prompt)
#   REPO            repo privado (def: maverick0309/fibra-os)
#   REF             rama/tag (def: main)
#   CTID            id del contenedor (def: siguiente libre)
#   CT_HOSTNAME     nombre del CT (def: FibraOS)
#   DISK_GB RAM_MB CORES   recursos (def: 20 / 4096 / 2)
#   BRIDGE STORAGE TEMPLATE_STORAGE   red/almacenamiento (def: vmbr0 / local-lvm / local)
#   NET_MODE        dhcp | static (si vacío y hay TTY, se pregunta)
#   IP_CIDR         ej: 192.168.18.50/24  (solo modo static)
#   GATEWAY         ej: 192.168.18.1      (solo modo static)
#   ISP_NAME ISP_SLUG ADMIN_EMAIL ADMIN_PASSWORD ADMIN_NAME   datos del ISP
# ==============================================================================
set -Eeuo pipefail

export PATH="$PATH:/usr/sbin:/usr/local/sbin:/sbin"

# ── Config (env con defaults) ─────────────────────────────────────────────────
REPO="${REPO:-maverick0309/fibra-os}"
REF="${REF:-main}"
HOSTNAME_CT="${CT_HOSTNAME:-FibraOS}"
DISK_GB="${DISK_GB:-20}"
RAM_MB="${RAM_MB:-4096}"
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
NET_MODE="${NET_MODE:-}"
IP_CIDR="${IP_CIDR:-}"
GATEWAY="${GATEWAY:-}"
ISP_NAME="${ISP_NAME:-Demo ISP}"
ISP_SLUG="${ISP_SLUG:-demo}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@demo.local}"
ADMIN_NAME="${ADMIN_NAME:-Admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
FIBRAOS_TOKEN="${FIBRAOS_TOKEN:-}"
CTID="${CTID:-}"

# ── Logging ───────────────────────────────────────────────────────────────────
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
SUCCESS=0
cleanup_on_exit() {
  local code=$?
  if [[ "$SUCCESS" -ne 1 && -n "$CREATED_CTID" ]]; then
    msg_info "Limpiando el contenedor $CREATED_CTID que quedó a medias…"
    pct stop "$CREATED_CTID" &>/dev/null || true
    pct destroy "$CREATED_CTID" &>/dev/null || true
    msg_ok "Contenedor $CREATED_CTID eliminado. Corrige el problema y reintenta."
  fi
  exit "$code"
}
trap cleanup_on_exit EXIT

# ── Pre-flight ────────────────────────────────────────────────────────────────
line
echo -e " ${GN}FibraOS — Instalador Proxmox VE (LXC)${CL}"
line
[[ $EUID -eq 0 ]]            || { msg_err "Ejecuta como root en el host Proxmox."; exit 1; }
command -v pct   >/dev/null  || { msg_err "No es un host Proxmox VE (falta 'pct')."; exit 1; }
command -v pvesh >/dev/null  || { msg_err "No es un host Proxmox VE (falta 'pvesh')."; exit 1; }
command -v pveam >/dev/null  || { msg_err "No es un host Proxmox VE (falta 'pveam')."; exit 1; }

# ── Detectar versión de Proxmox VE ───────────────────────────────────────────
PVE_MAJOR="$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+' | head -1 || echo 0)"
msg_info "Proxmox VE detectado: versión mayor ${PVE_MAJOR}"

case "$PVE_MAJOR" in
  8)
    msg_ok "PVE 8 — modo: AppArmor unconfined + cgroup2 + fuse-overlayfs"
    TEMPLATE_SEARCH="debian-12-standard"
    TEMPLATE_FALLBACK=""
    USE_FUSE_OVERLAYFS="yes"
    LXC_EXTRA_CONF="lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.cgroup2.devices.allow: a
lxc.mount.auto: \"proc:rw sys:rw\""
    ;;
  9)
    msg_ok "PVE 9 — modo: AppArmor unconfined + overlay2 nativo"
    TEMPLATE_SEARCH="debian-13-standard"
    TEMPLATE_FALLBACK="debian-12-standard"
    USE_FUSE_OVERLAYFS="no"
    LXC_EXTRA_CONF="lxc.apparmor.profile: unconfined
lxc.cap.drop:"
    ;;
  *)
    msg_err "Versión de Proxmox VE no reconocida (detectado: ${PVE_MAJOR})."
    msg_err "Este script soporta PVE 8 y PVE 9."
    if [[ -t 0 ]]; then
      read -rp " $(echo -e "${YW}▶${CL}") ¿Continuar igualmente con modo PVE 8? [s/N]: " _confirm
      if [[ "$_confirm" =~ ^[sS]$ ]]; then
        msg_info "Continuando en modo PVE 8 (puede que no funcione)…"
        TEMPLATE_SEARCH="debian-12-standard"
        TEMPLATE_FALLBACK=""
        USE_FUSE_OVERLAYFS="yes"
        LXC_EXTRA_CONF="lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.cgroup2.devices.allow: a
lxc.mount.auto: \"proc:rw sys:rw\""
      else
        exit 1
      fi
    else
      exit 1
    fi
    ;;
esac

# ── Token GitHub ──────────────────────────────────────────────────────────────
if [[ -z "$FIBRAOS_TOKEN" ]]; then
  if [[ -t 0 ]]; then
    read -rsp " $(echo -e "${YW}▶${CL}") Pega el token GitHub de SOLO LECTURA (no se mostrará): " FIBRAOS_TOKEN
    echo
  fi
fi
[[ -n "$FIBRAOS_TOKEN" ]] || { msg_err "Falta FIBRAOS_TOKEN (token GitHub RO)."; exit 1; }

msg_info "Validando el token contra $REPO…"
http=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${FIBRAOS_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}") || true
if [[ "$http" != "200" ]]; then
  msg_err "El token no puede leer ${REPO} (HTTP $http). Verifica scope Contents:Read."
  exit 1
fi
msg_ok "Token válido."

[[ -n "$ADMIN_PASSWORD" ]] || ADMIN_PASSWORD="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-14)"
[[ -n "$CTID" ]] || CTID="$(pvesh get /cluster/nextid)"

# ── Red del contenedor ────────────────────────────────────────────────────────
if [[ -z "$NET_MODE" ]]; then
  if [[ -t 0 ]]; then
    BRIDGES="$(ls /sys/class/net 2>/dev/null | grep -E '^vmbr[0-9]+' | tr '\n' ' ')"
    echo -e " ${BL}Bridges disponibles:${CL} ${BRIDGES:-vmbr0}"
    read -rp " $(echo -e "${YW}▶${CL}") Bridge de red [${BRIDGE}]: " _b; BRIDGE="${_b:-$BRIDGE}"
    echo -e " $(echo -e "${YW}▶${CL}") ¿Cómo asigna IP el contenedor?"
    echo "     1) DHCP (automático — necesita un servidor DHCP en ese bridge)"
    echo "     2) IP estática (tú das IP y gateway)"
    read -rp " $(echo -e "${YW}▶${CL}") Opción [1/2] (def 1): " _n
    if [[ "$_n" == "2" ]]; then NET_MODE="static"; else NET_MODE="dhcp"; fi
  else
    NET_MODE="dhcp"
  fi
fi

if [[ "$NET_MODE" == "static" ]]; then
  if [[ -z "$IP_CIDR" && -t 0 ]]; then
    read -rp " $(echo -e "${YW}▶${CL}") IP con máscara (ej 192.168.18.50/24): " IP_CIDR
  fi
  if [[ -z "$GATEWAY" && -t 0 ]]; then
    read -rp " $(echo -e "${YW}▶${CL}") Gateway (ej 192.168.18.1): " GATEWAY
  fi
  [[ "$IP_CIDR" == */* ]] || { msg_err "IP estática inválida: usa formato IP/máscara, ej 192.168.18.50/24"; exit 1; }
  [[ -n "$GATEWAY" ]]     || { msg_err "Falta el gateway para la IP estática."; exit 1; }
  NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}"
else
  NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
fi

# ── Plantilla LXC ────────────────────────────────────────────────────────────
msg_info "Buscando plantilla ${TEMPLATE_SEARCH}…"
TEMPLATE="$(pveam available --section system 2>/dev/null | awk -v s="$TEMPLATE_SEARCH" '$0~s{print $2}' | sort -V | tail -1)"

if [[ -z "$TEMPLATE" && -n "$TEMPLATE_FALLBACK" ]]; then
  msg_info "${TEMPLATE_SEARCH} no disponible, usando ${TEMPLATE_FALLBACK}…"
  TEMPLATE="$(pveam available --section system 2>/dev/null | awk -v s="$TEMPLATE_FALLBACK" '$0~s{print $2}' | sort -V | tail -1)"
fi

[[ -n "$TEMPLATE" ]] || { msg_err "No encontré plantilla Debian en 'pveam available'."; exit 1; }

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Descargando $TEMPLATE a $TEMPLATE_STORAGE…"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null
fi
msg_ok "Plantilla lista: $TEMPLATE"

# ── Crear el LXC ─────────────────────────────────────────────────────────────
msg_info "Creando LXC $CTID ($HOSTNAME_CT) — ${CORES} vCPU / ${RAM_MB} MB / ${DISK_GB} GB…"
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME_CT" \
  --cores "$CORES" --memory "$RAM_MB" --swap "$RAM_MB" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "$NET0" \
  --features "nesting=1,keyctl=1" \
  --unprivileged 1 --onboot 1 >/dev/null
CREATED_CTID="$CTID"

# ── Config extra para Docker en LXC (según versión PVE) ──────────────────────
msg_info "Aplicando config LXC para Docker (PVE ${PVE_MAJOR})…"
printf '%s\n' "$LXC_EXTRA_CONF" >> /etc/pve/lxc/${CTID}.conf
msg_ok "Config LXC aplicada."

pct start "$CTID" >/dev/null
msg_ok "Contenedor $CTID creado y arrancado (red: ${NET_MODE})."

# ── Resolver IP ──────────────────────────────────────────────────────────────
if [[ "$NET_MODE" == "static" ]]; then
  IP="${IP_CIDR%/*}"
  msg_ok "IP del contenedor (estática): $IP"
else
  msg_info "Esperando IP por DHCP…"
  IP=""
  for _ in $(seq 1 30); do
    IP="$(pct exec "$CTID" -- bash -c "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
    [[ -n "$IP" ]] && break
    sleep 2
  done
  if [[ -z "$IP" ]]; then
    msg_err "El contenedor no obtuvo IP por DHCP en el bridge ${BRIDGE}."
    msg_err "Reintenta con: NET_MODE=static IP_CIDR=192.168.X.Y/24 GATEWAY=192.168.X.1"
    exit 1
  fi
  msg_ok "IP del contenedor: $IP"
fi

# ── Script de aprovisionamiento dentro del contenedor ────────────────────────
# El token llega por stdin (nunca aparece en 'ps' ni se escribe a disco).
read -r -d '' PROVISION <<'PROVISION_EOF' || true
set -Eeuo pipefail
read -r FIBRAOS_TOKEN
export DEBIAN_FRONTEND=noninteractive
REPO="__REPO__"; REF="__REF__"
ISP_NAME="__ISP_NAME__"; ISP_SLUG="__ISP_SLUG__"
ADMIN_EMAIL="__ADMIN_EMAIL__"; ADMIN_PASSWORD="__ADMIN_PASSWORD__"; ADMIN_NAME="__ADMIN_NAME__"
USE_FUSE_OVERLAYFS="__USE_FUSE_OVERLAYFS__"

echo "[CT] Instalando dependencias base…"
apt-get update -qq
# Generar locales para evitar warnings de perl/apt
apt-get install -y -qq locales ca-certificates curl gnupg openssl tar >/dev/null
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen >/dev/null 2>&1 || true
export LANG=en_US.UTF-8

if [[ "$USE_FUSE_OVERLAYFS" == "yes" ]]; then
  echo "[CT] Instalando fuse-overlayfs (PVE 8)…"
  apt-get install -y -qq fuse-overlayfs >/dev/null
fi

echo "[CT] Instalando Docker…"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh >/dev/null
fi

if [[ "$USE_FUSE_OVERLAYFS" == "yes" ]]; then
  echo "[CT] Configurando Docker storage driver: fuse-overlayfs (PVE 8)…"
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'DOCKEREOF'
{
  "storage-driver": "fuse-overlayfs"
}
DOCKEREOF
fi

systemctl enable --now docker >/dev/null 2>&1 || true

echo "[CT] Descargando FibraOS…"
mkdir -p /opt/fibraos
curl -fsSL -H "Authorization: Bearer ${FIBRAOS_TOKEN}" \
     -H "Accept: application/vnd.github+json" \
     "https://api.github.com/repos/${REPO}/tarball/${REF}" -o /tmp/fibraos.tgz
tar xzf /tmp/fibraos.tgz -C /opt/fibraos --strip-components=1
rm -f /tmp/fibraos.tgz
unset FIBRAOS_TOKEN
cd /opt/fibraos

echo "[CT] Generando .env…"
PGPASS="$(openssl rand -hex 16)"
SECRET="$(openssl rand -hex 32)"
cp .env.prod.example .env
sed -i "s|CAMBIA_ESTA_PASSWORD|${PGPASS}|g" .env
sed -i "s|SECRET_KEY=.*|SECRET_KEY=${SECRET}|" .env

echo "[CT] Levantando el stack (docker compose build)…"
docker compose -f docker-compose.prod.yml up -d --build

echo "[CT] Esperando a que la API responda…"
for _ in $(seq 1 60); do
  curl -sf http://localhost/api/health >/dev/null 2>&1 && break
  sleep 3
done
curl -sf http://localhost/api/health >/dev/null 2>&1 || {
  echo "[CT] La API no respondió a tiempo"
  docker compose -f docker-compose.prod.yml ps
  exit 1
}

echo "[CT] Creando ISP demo + usuario admin…"
docker compose -f docker-compose.prod.yml exec -T api \
  python scripts/bootstrap_isp.py \
    --isp-name "${ISP_NAME}" --slug "${ISP_SLUG}" \
    --admin-email "${ADMIN_EMAIL}" --admin-password "${ADMIN_PASSWORD}" \
    --admin-name "${ADMIN_NAME}" || echo "[CT] (bootstrap: ISP quizá ya existía, se ignora)"

echo "[CT] OK"
PROVISION_EOF

PROVISION="${PROVISION//__REPO__/$REPO}"
PROVISION="${PROVISION//__REF__/$REF}"
PROVISION="${PROVISION//__ISP_NAME__/$ISP_NAME}"
PROVISION="${PROVISION//__ISP_SLUG__/$ISP_SLUG}"
PROVISION="${PROVISION//__ADMIN_EMAIL__/$ADMIN_EMAIL}"
PROVISION="${PROVISION//__ADMIN_PASSWORD__/$ADMIN_PASSWORD}"
PROVISION="${PROVISION//__ADMIN_NAME__/$ADMIN_NAME}"
PROVISION="${PROVISION//__USE_FUSE_OVERLAYFS__/$USE_FUSE_OVERLAYFS}"

msg_info "Aprovisionando FibraOS dentro del contenedor (PVE ${PVE_MAJOR})…"
printf '%s' "$PROVISION" | pct exec "$CTID" -- bash -c 'cat > /root/fibraos-provision.sh'
printf '%s\n' "$FIBRAOS_TOKEN" | pct exec "$CTID" -- bash /root/fibraos-provision.sh
pct exec "$CTID" -- rm -f /root/fibraos-provision.sh
msg_ok "FibraOS aprovisionado."

# ── Resumen ───────────────────────────────────────────────────────────────────
SUCCESS=1
line
msg_ok "FibraOS instalado en el contenedor ${CTID} (Proxmox VE ${PVE_MAJOR})."
line
echo -e "  ${BL}URL:${CL}          http://${IP}/"
echo -e "  ${BL}Admin:${CL}        ${ADMIN_EMAIL}"
echo -e "  ${BL}Password:${CL}     ${ADMIN_PASSWORD}"
echo -e "  ${BL}ISP:${CL}          ${ISP_NAME} (${ISP_SLUG})"
echo
echo -e "  ${BL}.env:${CL}         /opt/fibraos/.env  (dentro del CT)"
echo -e "  ${BL}Logs:${CL}         pct exec ${CTID} -- docker compose -f /opt/fibraos/docker-compose.prod.yml logs -f api"
echo -e "  ${BL}LXC config:${CL}   /etc/pve/lxc/${CTID}.conf"
echo
echo -e "  ${YW}Nota:${CL} para datos reales el contenedor debe alcanzar las OLTs/MikroTik"
echo -e "        del ISP (LAN directa o WireGuard). Para probar la UI no hace falta."
line
