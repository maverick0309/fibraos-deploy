#!/usr/bin/env bash
# ==============================================================================
# FibraOS — ACTUALIZADOR (solo actualiza; NO instala ni crea contenedores)
# ------------------------------------------------------------------------------
# Trae el código nuevo de GitHub a una instalación de FibraOS que YA existe
# (/opt/fibraos), conservando datos y configuración.
#
# USO (DENTRO del contenedor / host Docker donde corre FibraOS, como root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/maverick0309/fibraos-deploy/main/update.sh)"
#
# Desde el host Proxmox, sin entrar al contenedor:
#   pct exec <CTID> -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/maverick0309/fibraos-deploy/main/update.sh)"
#
# QUÉ CONSERVA (no se toca nunca):
#   - .env  → incluida SECRET_KEY. ⚠️ SECRET_KEY cifra las credenciales de las
#             OLTs: si cambiara, se perderían TODAS. El script nunca la regenera.
#   - .env.traps → TRAPS_KEY (cifra las credenciales de AVISOS de las OLTs) y la
#             contraseña del rol del receptor. Si falta, se crea; si le falta una de sus
#             variables, se añade SOLO esa. Una que ya existe no se toca nunca. Se
#             asegura en cada pasada (también si ya estás al día), salvo con --dry-run.
#   - La base de datos (volumen docker postgres_data).
#
# REQUISITOS: Docker Compose v2, 2.0.1 o más nuevo. Se comprueba ANTES de tocar nada, y el
# docker-compose.prod.yml de la versión nueva se valida con TU Compose antes del cambio.
#
# Variables opcionales:
#   FIBRAOS_TOKEN   token GitHub RO. Si no está en el entorno se lee de
#                   /root/.fibraos-token (si existe) y, si tampoco, se pide por teclado.
#                   Este script NUNCA escribe ese fichero: el token es tuyo y guardarlo
#                   en el disco de tu servidor lo decides tú, no el actualizador.
#   TOKEN_FILE      dónde buscar ese fichero (def: /root/.fibraos-token)
#   REPO            repo privado (def: maverick0309/fibra-os)
#   REF             rama/tag/commit a instalar (def: main)
#   APP_DIR         instalación a actualizar (def: /opt/fibraos)
#   KEEP_BACKUPS    backups a conservar (def: 5)
#
# Flags:
#   --dry-run     solo muestra qué versión se instalaría; no cambia nada
#   --no-backup   omite el backup (DESACONSEJADO)
# ==============================================================================
set -Eeuo pipefail

REPO="${REPO:-maverick0309/fibra-os}"
REF="${REF:-main}"
APP_DIR="${APP_DIR:-/opt/fibraos}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/fibraos-backups}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
COMPOSE_FILE="docker-compose.prod.yml"
FIBRAOS_TOKEN="${FIBRAOS_TOKEN:-}"
DRY_RUN=0
DO_BACKUP=1

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --no-backup) DO_BACKUP=0 ;;
    -h|--help)   sed -n '3,/^# =====/p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $arg (usa --help)"; exit 1 ;;
  esac
done

# ── Logging ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RD=$'\033[01;31m'; GN=$'\033[1;92m'; YW=$'\033[33m'; BL=$'\033[36m'; CL=$'\033[m'
else
  RD=""; GN=""; YW=""; BL=""; CL=""
fi
msg_info() { echo -e " ${YW}▶${CL} $*"; }
msg_ok()   { echo -e " ${GN}✔${CL} $*"; }
msg_err()  { echo -e " ${RD}✘${CL} $*" >&2; }
line()     { echo -e "${BL}------------------------------------------------------------${CL}"; }

NEW_DIR=""; OLD_DIR=""; SWAPPED=0; BACKUP_DIR=""; REV_ANTES=""; NOVEDADES_TMP=""
PG_USER="fibraos"; PG_DB="fibraos"

# Espera a /api/health. $1 = intentos de 3 s (def 60 = 3 min). 0 si respondió.
_esperar_api() {
  local _i
  for _i in $(seq 1 "${1:-60}"); do
    curl -sf http://localhost/api/health >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

# La revisión de Alembic de la base, o nada si no se puede leer. Hay que llamarla desde el
# directorio de la instalación (el nombre del proyecto de compose sale de ahí).
_revision_bd() {
  local r=""
  r="$(docker compose -f "$COMPOSE_FILE" exec -T db \
         psql -U "$PG_USER" -d "$PG_DB" -tAc 'SELECT version_num FROM alembic_version' \
         2>/dev/null)" || r=""
  printf '%s' "${r//[$' \t\r\n']/}"
}

# ¿La base avanzó de revisión durante esta actualización? (la API nueva migró al arrancar)
_base_migrada() {
  local r
  r="$(_revision_bd)"
  [[ -n "$REV_ANTES" && -n "$r" && "$r" != "$REV_ANTES" ]]
}

# 🔴 Por qué NO se restaura la base sola cuando ya se migró (ADR, update.sh):
#   · Las migraciones corren en UNA transacción (alembic/env.py): o la revisión avanzó
#     entera o no avanzó. Si no avanzó, volver al código anterior es seguro y se hace.
#   · Si avanzó, el código anterior NO arranca (su Alembic no conoce esa revisión): volver
#     solo al código deja la API caída, que es lo que pasaba. Volver también la base exige
#     BORRARLA y cargar el volcado: se pierde todo lo escrito desde el backup, no hay
#     volcado con --no-backup, y una carga a medias deja algo peor que cualquiera de las
#     dos versiones. Eso no lo decide un script sin nadie delante.
#   · Así que se queda el código NUEVO, que es el que corresponde a esa base (las
#     migraciones son reentrantes), se mira si la API responde, y se dan los comandos
#     exactos para volver atrás a mano si la persona lo decide.
_se_queda_la_nueva() {   # $1 = revisión actual de la base
  local guardado="$OLD_DIR"
  msg_err "La base de datos ya está migrada a la versión nueva (${REV_ANTES} → $1)."
  msg_err "El código anterior NO arranca contra una base migrada, así que NO se vuelve"
  msg_err "atrás: se queda la versión nueva, que es la que corresponde a esa base."
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] && mv "$OLD_DIR" "$BACKUP_DIR/codigo-anterior"; then
    guardado="$BACKUP_DIR/codigo-anterior"
  fi
  docker compose -f "$COMPOSE_FILE" up -d >/dev/null 2>&1
  if _esperar_api 20; then
    msg_ok "La API responde con la versión nueva."
  else
    msg_err "La API NO responde. Qué hacer:"
    echo "    1. Mira por qué:  cd $APP_DIR && docker compose -f $COMPOSE_FILE logs --tail 100 api"
    echo "    2. Mándanos esa salida: con la base ya migrada, lo normal es arreglarlo hacia"
    echo "       delante (una versión corregida), no volver atrás."
  fi
  echo
  msg_info "El código anterior está guardado en: $guardado"
  if [[ -n "$BACKUP_DIR" && -f "$BACKUP_DIR/db.sql.gz" ]]; then
    msg_info "Volver atrás A MANO (BORRA todo lo que se escribió en la base después del backup):"
    echo "    cd $APP_DIR && docker compose -f $COMPOSE_FILE down"
    echo "    cd / && mv $APP_DIR ${APP_DIR}.fallida && mv $guardado $APP_DIR"
    echo "    cd $APP_DIR && docker compose -f $COMPOSE_FILE up -d db && sleep 10"
    echo "    docker compose -f $COMPOSE_FILE exec -T db dropdb -U $PG_USER $PG_DB"
    echo "    docker compose -f $COMPOSE_FILE exec -T db createdb -U $PG_USER $PG_DB"
    echo "    gunzip -c $BACKUP_DIR/db.sql.gz | docker compose -f $COMPOSE_FILE exec -T db psql -q -U $PG_USER -d $PG_DB"
    echo "    docker compose -f $COMPOSE_FILE up -d --build"
  else
    msg_err "No hay volcado de la base de esta actualización (--no-backup): no se puede volver"
    msg_err "atrás. Hay que seguir hacia delante."
  fi
}

_volver_al_codigo_anterior() {
  msg_info "La base sigue en la revisión de antes (${REV_ANTES:-no se pudo leer}): se vuelve al código anterior…"
  cd / || true
  rm -rf "$APP_DIR"
  if ! mv "$OLD_DIR" "$APP_DIR"; then
    msg_err "No pude devolver el código anterior a su sitio. Está en: $OLD_DIR"
    return
  fi
  cd "$APP_DIR" || return
  docker compose -f "$COMPOSE_FILE" up -d --build >/dev/null 2>&1
  # Se COMPRUEBA, no se da por hecho: antes decía «stack levantado» sin haberlo mirado.
  if _esperar_api; then
    msg_ok "Código anterior restaurado y la API responde: FibraOS sigue como estaba."
  else
    msg_err "Código anterior restaurado, pero la API NO responde. Mira por qué con:"
    echo "    cd $APP_DIR && docker compose -f $COMPOSE_FILE logs --tail 100 api"
    docker compose -f "$COMPOSE_FILE" ps 2>/dev/null
  fi
}

# Se llama por la trampa ERR (un comando falló) y A MANO desde los fallos que salen con
# `exit`: un `exit 1` NO dispara la trampa ERR, y por eso la espera de /api/health fallida
# no volvía nunca atrás aunque el comentario dijera lo contrario.
cleanup_on_err() {
  local code=$?
  [[ -n "${1:-}" ]] && code="$1"
  trap - ERR EXIT        # evita reentrar en el trap desde el propio trap
  set +e                 # un fallo dentro de la vuelta atrás no puede cortarla a medias
  msg_err "La actualización falló (exit $code)."
  if [[ "$SWAPPED" -eq 1 && -d "$OLD_DIR" ]]; then
    local rev_ahora=""
    cd "$APP_DIR" 2>/dev/null && rev_ahora="$(_revision_bd)"
    if [[ -n "$REV_ANTES" && -n "$rev_ahora" && "$rev_ahora" != "$REV_ANTES" ]]; then
      _se_queda_la_nueva "$rev_ahora"
    else
      _volver_al_codigo_anterior
    fi
  fi
  [[ -n "$NEW_DIR" && -d "$NEW_DIR" ]] && rm -rf "$NEW_DIR"
  [[ -n "$NOVEDADES_TMP" ]] && rm -f "$NOVEDADES_TMP"
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    echo
    msg_info "Backup de esta actualización: $BACKUP_DIR  (base, .env y .env.traps)"
  fi
  exit "$code"
}
trap cleanup_on_err ERR

# ── Docker Compose: versión mínima ───────────────────────────────────────────
# Medido el 2026-10-15 con `docker compose config` sobre docker-compose.prod.yml y los
# binarios oficiales 2.0.1, 2.2.3, 2.4.1, 2.10.2, 2.17.3, 2.20.3, 2.23.3, 2.24.0 y 5.1.2:
# carga en todos. Dos cosas lo subirían sin que se note y por eso NO se usan: `env_file`
# en forma larga (`path:` + `required:`, exige 2.24) y `cpus:` entre comillas (lo
# rechazan 2.10 y anteriores). Además, el fichero de la versión nueva se valida con TU
# Compose antes de cambiar nada (paso 5b): esa es la comprobación que vale siempre.
COMPOSE_MIN="2.0.1"

_version_compose() {   # «2.24.6», sin la «v» ni sufijos de distribución; nada si no se sabe
  local v=""
  v="$(docker compose version --short 2>/dev/null)" || v=""
  if [[ -z "$v" ]]; then
    v="$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || v=""
  fi
  v="${v#v}"; v="${v%%[^0-9.]*}"
  printf '%s' "$v"
}

_version_ge() {   # $1 >= $2
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

# ── Funciones de .env.traps y del perfil «avisos» ────────────────────────────
# (tests/test_receptor_avisos_seguridad.py ejecuta este bloque con un `docker` falso)

_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

_valor_de() {   # $1 = fichero, $2 = variable → su valor (la última aparición, como Compose)
  [[ -f "$1" ]] || return 0
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?${2}[[:space:]]*=//p" "$1" \
    | tail -1 | tr -d '"'"'"' \r\t'
}

_env_traps_faltan() {   # $1 = directorio → variables que faltan o están vacías
  local var falta=""
  for var in TRAPS_KEY TRAPS_DB_PASSWORD; do
    [[ -n "$(_valor_de "$1/.env.traps" "$var")" ]] || falta+="$var "
  done
  printf '%s' "${falta% }"
}

# `.env.traps` tiene que EXISTIR antes de cualquier `up`: docker-compose.prod.yml lo
# declara en forma corta (la única que entiende cualquier Compose v2), y sin el fichero el
# `up` falla. Se crea si falta y se le añaden SOLO las variables que falten.
# 🔴 Una TRAPS_KEY que ya existe no se toca jamás: cifra las credenciales de avisos, y
# cambiarla las deja ilegibles. Una vacía no ha cifrado nada (la API exige 32 caracteres),
# así que se completa: la línea nueva va al final y Compose usa la última (medido).
ENV_TRAPS_ANADIDAS=""
_asegurar_env_traps() {   # $1 = directorio de la instalación
  local f="$1/.env.traps" faltan var
  if [[ ! -e "$f" ]]; then
    ( umask 077
      { echo "# Creado por update.sh el $(date '+%Y-%m-%d %H:%M'). No lo borres ni lo cambies:"
        echo "# TRAPS_KEY cifra las credenciales de avisos de tus OLTs."
      } > "$f" )
  fi
  if [[ ! -f "$f" ]]; then
    msg_err "$f existe pero no es un fichero normal: no lo toco. Arréglalo y vuelve a lanzar esto."
    exit 1
  fi
  faltan="$(_env_traps_faltan "$1")"
  [[ -n "$faltan" ]] || return 0
  # Si el fichero no acaba en salto de línea, lo que se añada se pegaría a la última
  # variable y la CAMBIARÍA (p. ej. la TRAPS_KEY). Primero el salto.
  if [[ -s "$f" && -n "$(tail -c1 "$f")" ]]; then printf '\n' >> "$f"; fi
  for var in $faltan; do
    case "$var" in
      TRAPS_KEY)         printf 'TRAPS_KEY=%s\n' "$(_hex 32)" >> "$f" ;;
      TRAPS_DB_PASSWORD) printf 'TRAPS_DB_PASSWORD=%s\n' "$(_hex 24)" >> "$f" ;;
    esac
  done
  chmod 600 "$f"
  ENV_TRAPS_ANADIDAS="$faltan"
  msg_ok ".env.traps: añadido ${faltan} (lo que ya había no se ha tocado)"
}

_valor_env() {   # $1 = variable; primero el entorno, luego el .env del directorio actual
  local v="${!1:-}"
  [[ -n "$v" ]] || v="$(_valor_de .env "$1")"
  printf '%s' "$v"
}

# ¿Hay algo escuchando en ese puerto UDP? 0 = sí · 1 = no · 2 = no se puede saber.
# Sin `ss` (contenedores mínimos) se mira /proc/net/udp{,6}: el puerto va en hexadecimal
# detrás de los dos puntos de la columna local_address.
_puerto_udp_ocupado() {
  local p="$1" hex f
  local -a ficheros=()
  if command -v ss >/dev/null 2>&1; then
    [[ -n "$(ss -Hlun "sport = :${p}" 2>/dev/null)" ]] && return 0
    return 1
  fi
  for f in /proc/net/udp /proc/net/udp6; do [[ -r "$f" ]] && ficheros+=("$f"); done
  [[ ${#ficheros[@]} -gt 0 ]] || return 2
  hex="$(printf '%04X' "$p")"
  if awk -v h="$hex" 'FNR > 1 { n = split($2, a, ":"); if (toupper(a[n]) == h) f = 1 }
                      END { exit !f }' "${ficheros[@]}"; then
    return 0
  fi
  return 1
}

_quitar_avisos_de_esta_pasada() {
  COMPOSE_PROFILES="$(printf '%s' "$PERFILES" | tr ',' '\n' | grep -vx 'avisos' \
                      | paste -sd, - || true)"
  export COMPOSE_PROFILES
}

# 1) Con el perfil apagado no hay nada que publicar; pero si el contenedor quedó de cuando
#    estaba encendido, `up -d` ya no lo toca (ni para pararlo): se retira.
# 2) Con el perfil encendido, si el puerto UDP lo tiene OTRO programa del servidor (un
#    snmptrapd, otro NMS), `up -d` fallaría y la vuelta atrás desharía la actualización
#    ENTERA por un servicio opcional. En ese caso —y si no se puede saber, o el puerto no
#    es un número— se actualiza sin el receptor y se dice.
#    Exportar COMPOSE_PROFILES aquí vale también para la vuelta atrás.
PERFILES=""
_preparar_perfil_avisos() {
  local trap_port nuestro estado
  PERFILES="$(_valor_env COMPOSE_PROFILES)"
  if [[ ",${PERFILES}," != *",avisos,"* ]]; then
    if [[ -n "$(docker ps -aq --filter 'name=^fibraos-traps$' 2>/dev/null || true)" ]]; then
      msg_info "El perfil «avisos» está apagado: se retira el receptor de avisos que quedaba."
      docker compose -f "$COMPOSE_FILE" rm -sf traps >/dev/null 2>&1 || true
    fi
    return 0
  fi
  trap_port="$(_valor_env FIBRAOS_TRAP_PORT)"; trap_port="${trap_port:-162}"
  if [[ ! "$trap_port" =~ ^[0-9]{1,5}$ ]] || (( 10#$trap_port < 1 || 10#$trap_port > 65535 )); then
    msg_err "AVISO: FIBRAOS_TRAP_PORT=«${trap_port}» no es un puerto válido."
    msg_err "       Se actualiza SIN el receptor de avisos. Corrígelo en $APP_DIR/.env."
    _quitar_avisos_de_esta_pasada; return 0
  fi
  nuestro="$(docker ps -q --filter 'name=^fibraos-traps$' 2>/dev/null || true)"
  [[ -z "$nuestro" ]] || return 0
  estado=0; _puerto_udp_ocupado "$trap_port" || estado=$?
  if [[ "$estado" -eq 0 ]]; then
    msg_err "AVISO: el puerto UDP ${trap_port} ya lo usa otro programa de este servidor."
    msg_err "       Se actualiza SIN el receptor de avisos (perfil «avisos»). Para usarlo,"
    msg_err "       cambia FIBRAOS_TRAP_PORT en $APP_DIR/.env y apunta tus OLTs a ese puerto."
    _quitar_avisos_de_esta_pasada
  elif [[ "$estado" -eq 2 ]]; then
    msg_err "AVISO: no puedo comprobar si el puerto UDP ${trap_port} está libre (ni «ss» ni"
    msg_err "       /proc/net/udp). Se actualiza SIN el receptor de avisos para no arriesgar"
    msg_err "       la actualización. Instala iproute2 y vuelve a lanzar esto para activarlo."
    _quitar_avisos_de_esta_pasada
  fi
  return 0
}

# La primera actualización con el receptor mete la base en su red (`traps_net`), y Docker
# tiene que recrear ese contenedor. Se dice antes, para que nadie se asuste.
_avisar_reinicio_bd() {
  local redes=""
  grep -q 'traps_net' "$COMPOSE_FILE" 2>/dev/null || return 0
  redes="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
             fibraos-db 2>/dev/null)" || return 0
  [[ -z "$redes" || "$redes" == *traps_net* ]] && return 0
  msg_info "Esta vez se reinicia UNA vez la base de datos (entra en la red del receptor de"
  msg_info "avisos): unos segundos sin servicio. Los datos no se tocan."
}
# ── fin de las funciones de avisos ───────────────────────────────────────────

line
echo -e " ${GN}FibraOS — Actualizador${CL}  (no instala: solo actualiza)"
line

# ── 1. Pre-flight ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { msg_err "Ejecuta como root."; exit 1; }
if [[ ! -d "$APP_DIR" || ! -f "$APP_DIR/$COMPOSE_FILE" ]]; then
  msg_err "No encuentro una instalación de FibraOS en $APP_DIR."
  msg_err "Este script SOLO actualiza. Para instalar de cero usa install.sh."
  exit 1
fi
[[ -f "$APP_DIR/.env" ]] || { msg_err "Falta $APP_DIR/.env — instalación incompleta, no continúo."; exit 1; }
command -v docker >/dev/null || { msg_err "Falta docker."; exit 1; }
docker compose version >/dev/null 2>&1 || { msg_err "Falta el plugin 'docker compose'."; exit 1; }
command -v curl >/dev/null || { msg_err "Falta curl."; exit 1; }
COMPOSE_VER="$(_version_compose)"
if [[ -z "$COMPOSE_VER" ]]; then
  msg_err "AVISO: no sé leer la versión de 'docker compose'. Sigo: antes de cambiar nada se"
  msg_err "       comprueba que tu Compose carga el fichero de la versión nueva."
elif ! _version_ge "$COMPOSE_VER" "$COMPOSE_MIN"; then
  msg_err "Tu Docker Compose es la versión ${COMPOSE_VER}; FibraOS necesita la ${COMPOSE_MIN} o más nueva."
  msg_err "Actualízalo (paquete docker-compose-plugin) y vuelve a lanzar esto."
  msg_err "Tu instalación NO se ha tocado."
  exit 1
fi
# Credenciales de la base desde el .env (para el pg_dump y para leer la revisión de Alembic)
PG_USER="$(_valor_de "$APP_DIR/.env" POSTGRES_USER)"; PG_USER="${PG_USER:-fibraos}"
PG_DB="$(_valor_de "$APP_DIR/.env" POSTGRES_DB)";     PG_DB="${PG_DB:-fibraos}"
msg_ok "Instalación encontrada en $APP_DIR  ·  Docker Compose ${COMPOSE_VER:-?}"

# ── Token de GitHub ──────────────────────────────────────────────────────────
#
# Orden: variable de entorno → fichero → teclado.
#
# El fichero NO lo escribe este script. Teclear el token en cada actualización es lo
# que produce el pegado a medias, y un pegado a medias da un 401 que parece una avería
# del producto; pero guardar solo una credencial en el disco de otra persona no es una
# decisión que le toque tomar a un actualizador. Si quieres dejar de teclearlo:
#
#     install -m 600 /dev/null /root/.fibraos-token
#     printf '%s' 'TU_TOKEN' > /root/.fibraos-token
TOKEN_FILE="${TOKEN_FILE:-/root/.fibraos-token}"
TOKEN_ORIGEN="la variable FIBRAOS_TOKEN"
if [[ -z "$FIBRAOS_TOKEN" && -r "$TOKEN_FILE" ]]; then
  FIBRAOS_TOKEN="$(head -1 "$TOKEN_FILE")"
  TOKEN_ORIGEN="$TOKEN_FILE"
  TOKEN_PERM="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || echo '?')"
  if [[ "$TOKEN_PERM" != "600" && "$TOKEN_PERM" != "400" ]]; then
    msg_err "AVISO: $TOKEN_FILE tiene permisos $TOKEN_PERM — cualquier usuario del servidor"
    msg_err "       puede leer tu token. Arréglalo con:  chmod 600 $TOKEN_FILE"
  fi
fi
if [[ -z "$FIBRAOS_TOKEN" && -t 0 ]]; then
  msg_info "Pégalo ENTERO y de una sola vez: un token a medias da un error 401 que parece"
  msg_info "una avería del producto. Para no teclearlo cada vez, ver $TOKEN_FILE en --help."
  read -rsp " $(echo -e "${YW}▶${CL}") Pega el token GitHub de SOLO LECTURA (no se mostrará): " FIBRAOS_TOKEN
  echo
  TOKEN_ORIGEN="lo que se tecleó ahora"
fi
# Un pegado desde un correo o desde el móvil arrastra espacios y saltos de línea. GitHub
# responde 401 sin decir por qué, así que se limpian antes de preguntarle nada.
FIBRAOS_TOKEN="${FIBRAOS_TOKEN//[$' \t\r\n']/}"
[[ -n "$FIBRAOS_TOKEN" ]] || { msg_err "Falta FIBRAOS_TOKEN (token GitHub RO)."; exit 1; }

# ── Hablar con GitHub diciendo qué pasa cuando no se puede ────────────────────
#
# `curl -fsSL` con un token caducado escupe «curl: (22) ... error: 401» y el script
# terminaba con «La actualización falló (exit 22)»: ni una palabra sobre el token. El
# ISP se queda mirando su servidor buscando una avería que no existe. Por eso aquí se
# pide SIN -f, se mira el código HTTP y se explica en palabras.

# Deja el cuerpo en $2 y devuelve el código HTTP por stdout (000 = no hubo respuesta).
_gh_get() {   # $1 = URL, $2 = fichero de salida
  local code=""
  # Ojo: cuando curl falla del todo YA imprime «000» por el -w, así que un
  # `|| echo 000` de más devolvía «000000» y el mensaje salía como código raro.
  code="$(curl -sSL -o "$2" -w '%{http_code}' \
               -H "Authorization: Bearer ${FIBRAOS_TOKEN}" \
               -H "Accept: application/vnd.github+json" \
               "$1" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

_fallo_github() {   # $1 = código HTTP, $2 = qué se estaba haciendo
  local code="$1" que="$2"
  case "$code" in
    401)
      msg_err "GitHub rechazó el token (HTTP 401) al $que."
      msg_err "El token NO es válido. Casi siempre es una de estas tres:"
      msg_err "   1. caducó — los tokens de GitHub llevan fecha de caducidad;"
      msg_err "   2. se pegó a medias — tiene que ir entero, sin espacios ni saltos;"
      msg_err "   3. se revocó."
      msg_err "Pide uno nuevo a quien te da soporte y vuelve a lanzar esto mismo."
      ;;
    403)
      msg_err "GitHub aceptó el token pero no deja $que (HTTP 403)."
      msg_err "El token existe pero le falta permiso, o se agotó el límite de llamadas."
      msg_err "Necesita permiso de lectura de contenido (Contents: Read) sobre ${REPO}."
      ;;
    404)
      msg_err "GitHub no encuentra ${REPO}@${REF} con ese token (HTTP 404) al $que."
      msg_err "En un repositorio privado, un token sin acceso da 404, no 403: es el mismo"
      msg_err "síntoma que si no existiera. Comprueba que el token es de ESTE producto."
      ;;
    000)
      msg_err "No hubo respuesta de GitHub al $que."
      msg_err "Es tu salida a internet: DNS, cortafuegos o proxy. Compruébalo con:"
      msg_err "   curl -sI https://api.github.com"
      ;;
    *)
      msg_err "GitHub respondió HTTP $code al $que — no esperado."
      ;;
  esac
  case "$code" in
    401|403|404)
      msg_err "Token usado: ${#FIBRAOS_TOKEN} caracteres, de ${TOKEN_ORIGEN}."
      msg_err "(los de GitHub tienen 40 o más; si salen menos, se pegó incompleto)"
      ;;
  esac
  msg_err "Tu instalación NO se ha tocado: sigue funcionando la versión que tenías."
}

# ── 2. Qué versión hay y cuál se instalaría ──────────────────────────────────
CUR_VER="$(cat "$APP_DIR/.fibraos-version" 2>/dev/null || echo "desconocida (instalación previa al versionado)")"
msg_info "Consultando ${REPO}@${REF}…"
# Se captura la respuesta ENTERA antes de extraer: si se hace `curl | grep -m1`,
# grep cierra la tubería al primer match y curl muere con "error 23" (SIGPIPE).
API_TMP="/tmp/fibraos-api-$$.json"
HTTP_CODE="$(_gh_get "https://api.github.com/repos/${REPO}/commits/${REF}" "$API_TMP")"
if [[ "$HTTP_CODE" != "200" ]]; then
  _fallo_github "$HTTP_CODE" "consultar qué versión hay disponible"
  rm -f "$API_TMP"
  trap - ERR; exit 1
fi
API_JSON="$(cat "$API_TMP")"; rm -f "$API_TMP"
NEW_SHA="$(printf '%s\n' "$API_JSON" \
           | sed -n 's/^[[:space:]]*"sha"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{7,\}\)".*/\1/p' \
           | sed -n '1p')"
# 200 pero sin sha: la respuesta no es la que se espera (¿un proxy que devuelve HTML?).
[[ -n "$NEW_SHA" ]] || { msg_err "GitHub contestó correctamente pero sin decir la versión de ${REPO}@${REF}."; msg_err "Tu instalación NO se ha tocado."; trap - ERR; exit 1; }
NEW_SHORT="${NEW_SHA:0:8}"

echo
echo -e "  ${BL}Versión actual:${CL} $CUR_VER"
echo -e "  ${BL}Versión nueva:${CL}  ${NEW_SHORT}  (${REPO}@${REF})"
echo

# ── 2b. .env.traps: en TODOS los caminos, también si ya estás al día ─────────
# Antes solo se creaba al instalar una versión nueva, y los mensajes de la API mandan a
# lanzar update.sh para crearlo: a quien ya estaba al día, update.sh le decía «nada que
# hacer» y se iba sin crearlo. Va DESPUÉS de hablar con GitHub para que un token caducado
# siga queriendo decir «no se ha tocado nada»; con --dry-run solo se dice.
if [[ "$DRY_RUN" -eq 1 ]]; then
  _faltan="$(_env_traps_faltan "$APP_DIR")"
  [[ -z "$_faltan" ]] || \
    msg_info "--dry-run: a $APP_DIR/.env.traps le falta ${_faltan}; una pasada normal lo añadiría."
else
  _asegurar_env_traps "$APP_DIR"
fi

if [[ "$CUR_VER" == "$NEW_SHORT" ]]; then
  msg_ok "Ya estás en la última versión (${NEW_SHORT}). No hay código que actualizar."
  # Si se acaba de añadir algo a .env.traps, la API tiene que recrearse para leerlo: fija
  # la contraseña del rol del receptor al arrancar, y sin TRAPS_KEY no genera credenciales
  # de avisos. `up -d` sin --build recrea SOLO lo que cambió (api, y traps si está en su
  # perfil); la base y los datos no se tocan.
  if [[ -n "$ENV_TRAPS_ANADIDAS" && "$DRY_RUN" -ne 1 ]]; then
    cd "$APP_DIR"
    msg_info "Se recrea la API para que lea lo añadido a .env.traps (sin reconstruir nada)…"
    _preparar_perfil_avisos
    _avisar_reinicio_bd
    if docker compose -f "$COMPOSE_FILE" up -d && _esperar_api; then
      msg_ok "API respondiendo con la configuración de avisos cargada."
    else
      msg_err "La API no responde tras recrearla. El código no ha cambiado; mira por qué con:"
      msg_err "   cd $APP_DIR && docker compose -f $COMPOSE_FILE logs --tail 100 api"
      trap - ERR; exit 1
    fi
  fi
  # Y aun así se dice dónde leer los cambios. `NOVEDADES.md` lo escribe una
  # actualización, así que quien ya está al día no lo tiene todavía y se queda sin
  # saber a dónde mirar — que es exactamente el callejón sin salida que se llevó un
  # ISP al buscar un fichero que su instalación no había creado nunca.
  if [[ -f "$APP_DIR/NOVEDADES.md" ]]; then
    echo -e "  ${BL}Novedades:${CL}   $APP_DIR/NOVEDADES.md   (de la última actualización)"
  fi
  [[ -f "$APP_DIR/CHANGELOG.md" ]] && \
    echo -e "  ${BL}Historial:${CL}   $APP_DIR/CHANGELOG.md   (qué cambió en cada versión)"
  trap - ERR; exit 0
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  msg_ok "--dry-run: no se ha cambiado nada."
  trap - ERR; exit 0
fi

# ── 3. Backup (antes de tocar nada) ──────────────────────────────────────────
if [[ "$DO_BACKUP" -eq 1 ]]; then
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y-%m-%d_%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  msg_info "Backup en $BACKUP_DIR …"
  cp "$APP_DIR/.env" "$BACKUP_DIR/.env"
  cp -p "$APP_DIR/.env.traps" "$BACKUP_DIR/.env.traps"
  if ( cd "$APP_DIR" && docker compose -f "$COMPOSE_FILE" exec -T db \
         pg_dump -U "$PG_USER" "$PG_DB" 2>/dev/null ) | gzip > "$BACKUP_DIR/db.sql.gz"; then
    msg_ok "Backup BD: $(du -h "$BACKUP_DIR/db.sql.gz" | cut -f1)  ·  .env y .env.traps copiados"
  else
    rm -f "$BACKUP_DIR/db.sql.gz"
    msg_err "No pude hacer el dump de la BD (¿el contenedor db está arriba?)."
    msg_err "Aborto por seguridad. Usa --no-backup solo si sabes lo que haces."
    exit 1
  fi
  # Rotación: conservar los últimos N
  mapfile -t OLD_BK < <(ls -1dt "${BACKUP_ROOT}"/*/ 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)))
  for d in "${OLD_BK[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done
else
  msg_info "Backup OMITIDO (--no-backup)."
fi

# ── 4. Descargar el código nuevo ─────────────────────────────────────────────
NEW_DIR="${APP_DIR}.new.$$"
mkdir -p "$NEW_DIR"
msg_info "Descargando código ${NEW_SHORT}…"
# Sin `-f` y mirando el código: si el token caducó ENTRE la consulta de arriba y esta
# descarga —o si tiene permiso para ver el repositorio pero no para bajarlo—, lo que
# veía el ISP era «exit 22» y ninguna pista de que el problema fuese su token.
HTTP_CODE="$(_gh_get "https://api.github.com/repos/${REPO}/tarball/${REF}" "/tmp/fibraos-$$.tgz")"
if [[ "$HTTP_CODE" != "200" ]]; then
  _fallo_github "$HTTP_CODE" "descargar el código"
  rm -f "/tmp/fibraos-$$.tgz"; rm -rf "$NEW_DIR"; NEW_DIR=""
  trap - ERR; exit 1
fi
tar xzf "/tmp/fibraos-$$.tgz" -C "$NEW_DIR" --strip-components=1
rm -f "/tmp/fibraos-$$.tgz"
unset FIBRAOS_TOKEN
[[ -f "$NEW_DIR/$COMPOSE_FILE" ]] || { msg_err "El tarball no trae $COMPOSE_FILE — abortando."; exit 1; }

# ── 4b. ¿Qué trae esta actualización? ────────────────────────────────────────
#
# El registro de cambios viajaba en el tarball desde siempre, pero **nadie apuntaba a
# él**: el actualizador decía "14551cd0 → ea325f04" y ya está. Un ISP no tiene forma de
# saber qué se arregló ni qué debería probar, y el repositorio es privado, así que
# tampoco puede mirarlo en la web.
#
# Se extraen solo las secciones NUEVAS: las que están en el CHANGELOG que se acaba de
# descargar y no en el que ya tenía instalado. Así lo que se lee es exactamente lo que
# cambia para él, no el historial entero.
#
# Se calcula AQUÍ porque es el único momento en que existen las dos versiones del
# fichero a la vez: después del intercambio, la vieja ya no está en su sitio.
NOVEDADES_TMP="/tmp/fibraos-novedades-$$.md"

_extraer_novedades() {   # $1 = CHANGELOG instalado, $2 = CHANGELOG nuevo
  [[ -f "$2" ]] || return 1
  if [[ ! -f "$1" ]]; then
    # Instalación anterior al registro de cambios: se enseña solo la última entrada,
    # que es lo útil. Volcar el historial completo sería ruido.
    awk '/^## /{n++} n==1' "$2"
    return 0
  fi
  # Se recorre el nuevo desde arriba y se corta en la primera sección que ya conocía.
  awk -v instalado="$1" '
    BEGIN { while ((getline l < instalado) > 0) if (l ~ /^## /) conocida[l] = 1 }
    /^## / && ($0 in conocida) { exit }
    /^## / { dentro = 1 }
    dentro { print }
  ' "$2"
}

_extraer_novedades "$APP_DIR/CHANGELOG.md" "$NEW_DIR/CHANGELOG.md" > "$NOVEDADES_TMP" 2>/dev/null || true

# ── 5. Conservar configuración y datos locales ───────────────────────────────
# .env es lo único imprescindible (SECRET_KEY + password BD). Nunca se regenera.
cp "$APP_DIR/.env" "$NEW_DIR/.env"
# 🔴 .env.traps viaja igual que el .env: su TRAPS_KEY cifra las credenciales de avisos, y
# perderla las dejaría ilegibles (habría que regenerarlas y reconfigurar cada OLT). Ya
# existe seguro (paso 2b); si no se pudiera copiar, se para aquí, antes del intercambio.
cp -p "$APP_DIR/.env.traps" "$NEW_DIR/.env.traps"
echo "$NEW_SHORT" > "$NEW_DIR/.fibraos-version"
msg_ok ".env y .env.traps conservados (misma SECRET_KEY y TRAPS_KEY → credenciales intactas)"

# ── 5b. ¿Tu Docker Compose entiende la versión nueva? ────────────────────────
# ANTES del intercambio: si no, el `up` fallaría con la versión nueva ya puesta. Esto es
# lo que de verdad protege de un fichero que pida un Compose más nuevo que el tuyo (la
# versión mínima de arriba es solo un aviso rápido).
if ! _cfg_err="$(cd "$NEW_DIR" && docker compose -f "$COMPOSE_FILE" config -q 2>&1)"; then
  msg_err "Tu Docker Compose (${COMPOSE_VER:-versión desconocida}) no puede cargar el $COMPOSE_FILE"
  msg_err "de la versión nueva:"
  printf '%s\n' "$_cfg_err" | head -5 | sed 's/^/     /' >&2
  msg_err "Actualiza Docker Compose (paquete docker-compose-plugin) y vuelve a lanzar esto."
  msg_err "Tu instalación NO se ha tocado: sigue funcionando la versión que tenías."
  cleanup_on_err 1
fi

# La revisión de Alembic justo antes del cambio: si la vuelta atrás la encuentra distinta,
# es que la API nueva ya migró la base y el código anterior no arrancaría contra ella.
REV_ANTES="$(cd "$APP_DIR" && _revision_bd)"

# ── 6. Intercambio + arranque ────────────────────────────────────────────────
OLD_DIR="${APP_DIR}.old.$$"
msg_info "Aplicando la nueva versión…"
mv "$APP_DIR" "$OLD_DIR"
mv "$NEW_DIR" "$APP_DIR"
NEW_DIR=""
SWAPPED=1

msg_info "Reconstruyendo y levantando el stack (puede tardar unos minutos)…"
cd "$APP_DIR"

# ── Receptor de avisos (perfil opcional «avisos») ────────────────────────────
# .env.traps ya existe (paso 2b) y viajó con el .env. Aquí solo se decide si el receptor
# arranca en esta pasada, y se avisa si la base va a reiniciarse.
_preparar_perfil_avisos
_avisar_reinicio_bd

docker compose -f "$COMPOSE_FILE" up -d --build

# ── 7. Health check ──────────────────────────────────────────────────────────
msg_info "Esperando a que la API responda…"
OK=0
if _esperar_api; then
  OK=1
elif _base_migrada; then
  # La base ya cambió de revisión: el código anterior no arrancaría contra ella, así que
  # rendirse ahora no arregla nada. Puede que solo esté tardando: se le da más tiempo.
  msg_info "La base ya se migró y la API aún no responde: le doy 3 minutos más…"
  _esperar_api && OK=1
fi
if [[ "$OK" -ne 1 ]]; then
  msg_err "La API no respondió tras la actualización."
  docker compose -f "$COMPOSE_FILE" ps || true
  # `exit 1` NO dispara la trampa ERR: hay que llamar a la vuelta atrás a mano.
  cleanup_on_err 1
fi

# Éxito → limpiar la copia anterior
rm -rf "$OLD_DIR"
SWAPPED=0
trap - ERR

line
msg_ok "FibraOS actualizado: ${CUR_VER}  →  ${NEW_SHORT}"
line

# ── 8. Qué ha cambiado ───────────────────────────────────────────────────────
# Se guarda SIEMPRE en un sitio fijo, y en la terminal se enseña un resumen: las
# entradas largas no caben en pantalla y lo que importa es que sepa dónde está el texto
# completo para leerlo con calma y probar lo que le afecte.
NOVEDADES_FILE="$APP_DIR/NOVEDADES.md"
if [[ -s "$NOVEDADES_TMP" ]]; then
  {
    echo "# Novedades de esta actualización"
    echo
    echo "Instalado el $(date '+%Y-%m-%d %H:%M') · versión ${CUR_VER} → ${NEW_SHORT}"
    echo
    cat "$NOVEDADES_TMP"
  } > "$NOVEDADES_FILE"

  TOTAL=$(wc -l < "$NOVEDADES_TMP")
  echo -e "  ${BL}Qué ha cambiado:${CL}"
  echo
  sed -n '1,40p' "$NOVEDADES_TMP" | sed 's/^/  /'
  if [[ "$TOTAL" -gt 40 ]]; then
    echo
    echo -e "  ${YW}… $((TOTAL - 40)) líneas más.${CL}"
  fi
  echo
  line
  echo -e "  ${BL}Novedades:${CL}   $NOVEDADES_FILE   ${GN}← qué se corrigió y qué probar${CL}"
else
  echo -e "  ${BL}Novedades:${CL}   (esta versión no trae entrada en el registro de cambios)"
fi
echo -e "  ${BL}Historial:${CL}   $APP_DIR/CHANGELOG.md   (todas las versiones)"
rm -f "$NOVEDADES_TMP"

echo -e "  ${BL}Datos:${CL}       intactos (volumen postgres_data)"
echo -e "  ${BL}Config:${CL}      $APP_DIR/.env y .env.traps conservados (mismas SECRET_KEY y TRAPS_KEY)"
[[ -n "$BACKUP_DIR" ]] && echo -e "  ${BL}Backup:${CL}      $BACKUP_DIR"
echo -e "  ${BL}Logs:${CL}        docker compose -f $APP_DIR/$COMPOSE_FILE logs -f api"
line
