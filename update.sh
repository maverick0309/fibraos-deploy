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
#   - La base de datos (volumen docker postgres_data).
#
# Variables opcionales:
#   FIBRAOS_TOKEN   token GitHub RO (si no, se pide por prompt)
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
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
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

NEW_DIR=""; OLD_DIR=""; SWAPPED=0; BACKUP_DIR=""
cleanup_on_err() {
  local code=$?
  trap - ERR EXIT        # evita reentrar en el trap desde el propio trap
  msg_err "La actualización falló (exit $code)."
  # Rollback del CÓDIGO si ya se había intercambiado el directorio
  if [[ "$SWAPPED" -eq 1 && -d "$OLD_DIR" ]]; then
    msg_info "Restaurando la versión anterior del código…"
    rm -rf "$APP_DIR" 2>/dev/null || true
    mv "$OLD_DIR" "$APP_DIR"
    ( cd "$APP_DIR" && docker compose -f "$COMPOSE_FILE" up -d --build ) >/dev/null 2>&1 || true
    msg_ok "Código restaurado a la versión anterior y stack levantado."
  fi
  [[ -n "$NEW_DIR" && -d "$NEW_DIR" ]] && rm -rf "$NEW_DIR"
  if [[ -n "$BACKUP_DIR" ]]; then
    echo
    msg_info "Backup disponible en: $BACKUP_DIR"
    msg_info "Restaurar la BASE DE DATOS (solo si hiciera falta):"
    echo "    cd $APP_DIR && gunzip -c $BACKUP_DIR/db.sql.gz | \\"
    echo "      docker compose -f $COMPOSE_FILE exec -T db psql -U \$POSTGRES_USER -d \$POSTGRES_DB"
  fi
  exit "$code"
}
trap cleanup_on_err ERR

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
msg_ok "Instalación encontrada en $APP_DIR"

# Token
if [[ -z "$FIBRAOS_TOKEN" && -t 0 ]]; then
  read -rsp " $(echo -e "${YW}▶${CL}") Pega el token GitHub de SOLO LECTURA (no se mostrará): " FIBRAOS_TOKEN
  echo
fi
[[ -n "$FIBRAOS_TOKEN" ]] || { msg_err "Falta FIBRAOS_TOKEN (token GitHub RO)."; exit 1; }

# ── 2. Qué versión hay y cuál se instalaría ──────────────────────────────────
CUR_VER="$(cat "$APP_DIR/.fibraos-version" 2>/dev/null || echo "desconocida (instalación previa al versionado)")"
msg_info "Consultando ${REPO}@${REF}…"
# Se captura la respuesta ENTERA antes de extraer: si se hace `curl | grep -m1`,
# grep cierra la tubería al primer match y curl muere con "error 23" (SIGPIPE).
API_JSON="$(curl -fsSL -H "Authorization: Bearer ${FIBRAOS_TOKEN}" \
              -H "Accept: application/vnd.github+json" \
              "https://api.github.com/repos/${REPO}/commits/${REF}")" || API_JSON=""
NEW_SHA="$(printf '%s\n' "$API_JSON" \
           | sed -n 's/^[[:space:]]*"sha"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{7,\}\)".*/\1/p' \
           | sed -n '1p')"
[[ -n "$NEW_SHA" ]] || { msg_err "No pude leer ${REPO}@${REF} con ese token (¿permisos Contents:Read?)."; exit 1; }
NEW_SHORT="${NEW_SHA:0:8}"

echo
echo -e "  ${BL}Versión actual:${CL} $CUR_VER"
echo -e "  ${BL}Versión nueva:${CL}  ${NEW_SHORT}  (${REPO}@${REF})"
echo

if [[ "$CUR_VER" == "$NEW_SHORT" ]]; then
  msg_ok "Ya estás en la última versión (${NEW_SHORT}). No hay nada que hacer."
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
  # Credenciales de la BD desde el .env (para el pg_dump)
  PG_USER="$(sed -n 's/^POSTGRES_USER=//p'     "$APP_DIR/.env" | head -1)"; PG_USER="${PG_USER:-fibraos}"
  PG_DB="$(sed   -n 's/^POSTGRES_DB=//p'       "$APP_DIR/.env" | head -1)"; PG_DB="${PG_DB:-fibraos}"
  if ( cd "$APP_DIR" && docker compose -f "$COMPOSE_FILE" exec -T db \
         pg_dump -U "$PG_USER" "$PG_DB" 2>/dev/null ) | gzip > "$BACKUP_DIR/db.sql.gz"; then
    msg_ok "Backup BD: $(du -h "$BACKUP_DIR/db.sql.gz" | cut -f1)  ·  .env copiado"
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
curl -fsSL -H "Authorization: Bearer ${FIBRAOS_TOKEN}" \
     -H "Accept: application/vnd.github+json" \
     "https://api.github.com/repos/${REPO}/tarball/${REF}" -o "/tmp/fibraos-$$.tgz"
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
echo "$NEW_SHORT" > "$NEW_DIR/.fibraos-version"
msg_ok ".env conservado (misma SECRET_KEY → credenciales de OLT intactas)"

# ── 6. Intercambio + arranque ────────────────────────────────────────────────
OLD_DIR="${APP_DIR}.old.$$"
msg_info "Aplicando la nueva versión…"
mv "$APP_DIR" "$OLD_DIR"
mv "$NEW_DIR" "$APP_DIR"
NEW_DIR=""
SWAPPED=1

msg_info "Reconstruyendo y levantando el stack (puede tardar unos minutos)…"
cd "$APP_DIR"
docker compose -f "$COMPOSE_FILE" up -d --build

# ── 7. Health check ──────────────────────────────────────────────────────────
msg_info "Esperando a que la API responda…"
OK=0
for _ in $(seq 1 60); do
  if curl -sf http://localhost/api/health >/dev/null 2>&1; then OK=1; break; fi
  sleep 3
done
if [[ "$OK" -ne 1 ]]; then
  msg_err "La API no respondió tras la actualización."
  docker compose -f "$COMPOSE_FILE" ps || true
  exit 1     # el trap hace rollback del código
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
echo -e "  ${BL}Config:${CL}      $APP_DIR/.env sin cambios (misma SECRET_KEY)"
[[ -n "$BACKUP_DIR" ]] && echo -e "  ${BL}Backup:${CL}      $BACKUP_DIR"
echo -e "  ${BL}Logs:${CL}        docker compose -f $APP_DIR/$COMPOSE_FILE logs -f api"
line
