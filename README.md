# FibraOS — Instalador para Proxmox VE (LXC)

Crea un contenedor **LXC (Debian 12)** con el stack completo de **FibraOS**
corriendo en Docker (web + api + PostgreSQL + redis), listo para iniciar sesión.
Estilo *community-scripts.org*: **un solo comando**.

> El código de FibraOS vive en un repo **privado**. Este instalador es público;
> descarga el código con un **token de GitHub de solo lectura** que tú generas.
> El token **nunca se guarda en disco**.

---

## Requisitos

- Un host **Proxmox VE** (probado en PVE 8).
- Acceso **root** al host.
- Un **token de GitHub de solo lectura** (paso 1).
- Salida a internet desde el host (para bajar la plantilla, Docker y el código).

---

## Paso 1 — Generar el token de solo lectura

En GitHub → **Settings → Developer settings → Personal access tokens →
Fine-grained tokens → Generate new token**:

1. **Repository access:** *Only select repositories* → `maverick0309/fibra-os`.
2. **Permissions → Repository permissions → Contents:** **Read-only**.
   (`Metadata: Read-only` se añade solo; no hace falta nada más.)
3. Copia el token (`github_pat_...`).

Es de solo lectura y de un solo repo: no puede modificar nada y se puede
**revocar** cuando quieras.

---

## Paso 2 — Ejecutar el instalador (en el host Proxmox, como root)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maverick0309/fibraos-deploy/main/install.sh)"
```

> **¿Entraste con `su`?** Usa `su -` (con guion) para que `pct` esté en el PATH.
> El script igual añade `/usr/sbin` al PATH por si acaso.

---

## Paso 3 — Responder las preguntas

El script pregunta lo mínimo:

| Pregunta | Qué poner |
|---|---|
| **Token** | Pega el token del paso 1 (no se muestra en pantalla). |
| **Bridge de red** | El bridge de Proxmox de tu red (ej `vmbr0`). Muestra los disponibles. |
| **DHCP o IP estática** | `1` DHCP (si el bridge tiene servidor DHCP) · `2` IP estática. |
| **IP / Gateway** (si estática) | Ej: `192.168.1.50/24` y gateway `192.168.1.1`. |

El resto (2 vCPU / 4 GB RAM / 20 GB disco, nombre `FibraOS`) tiene valores por
defecto. El script:

1. Valida el token.
2. Crea el LXC (con Docker habilitado — `nesting=1`).
3. Instala Docker, descarga FibraOS, genera secretos frescos y levanta el stack.
4. Crea un **ISP demo + usuario admin** y **te imprime la URL y la contraseña**.

Si algo falla, **borra el contenedor a medias** para que puedas reintentar limpio.

---

## Paso 4 — Entrar

Abre `http://<IP-del-contenedor>/` con el **email y contraseña** que imprimió el
script. ¡Listo!

> Para ver datos de OLT reales, el contenedor debe **alcanzar las OLTs/MikroTik**
> del ISP (LAN o VPN WireGuard). Para probar la app/UI no hace falta: entra y
> añade una OLT alcanzable desde **OLTs → Nueva OLT**.

---

## Instalación no interactiva (opcional)

Todo por variables de entorno:

```bash
FIBRAOS_TOKEN=github_pat_xxx \
NET_MODE=static  IP_CIDR=192.168.1.50/24  GATEWAY=192.168.1.1 \
CT_HOSTNAME=FibraOS  ISP_NAME="Mi ISP"  ADMIN_EMAIL=admin@example.com \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maverick0309/fibraos-deploy/main/install.sh)"
```

### Variables

| Variable | Def | Qué es |
|---|---|---|
| `FIBRAOS_TOKEN` | *(pide por prompt)* | Token GitHub RO. **Obligatorio.** |
| `REPO` / `REF` | `maverick0309/fibra-os` / `main` | Repo y rama/tag. |
| `CTID` | siguiente libre | ID del contenedor. |
| `CT_HOSTNAME` | `FibraOS` | Nombre del contenedor. |
| `DISK_GB` / `RAM_MB` / `CORES` | `20` / `4096` / `2` | Recursos. |
| `BRIDGE` | `vmbr0` | Bridge de red. |
| `NET_MODE` | *(pregunta)* | `dhcp` o `static`. |
| `IP_CIDR` / `GATEWAY` | — | Para `static`: IP/máscara + gateway. |
| `STORAGE` / `TEMPLATE_STORAGE` | `local-lvm` / `local` | Disco / plantillas. |
| `ISP_NAME` / `ISP_SLUG` | `Demo ISP` / `demo` | ISP que se crea. |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` / `ADMIN_NAME` | `admin@demo.local` / *(aleatoria)* / `Admin` | Usuario admin. |

---

## Después: comandos útiles

```bash
# Ver logs de la API
pct exec <CTID> -- docker compose -f /opt/fibraos/docker-compose.prod.yml logs -f api

# Estado de los contenedores Docker
pct exec <CTID> -- docker compose -f /opt/fibraos/docker-compose.prod.yml ps

# Renombrar el contenedor (si quedó con otro nombre)
pct set <CTID> --hostname FibraOS && pct reboot <CTID>

# Borrar el contenedor para reinstalar
pct stop <CTID>; pct destroy <CTID>
```

---

## Troubleshooting

| Síntoma | Causa / arreglo |
|---|---|
| `No es un host Proxmox VE (falta 'pct')` | Entraste con `su` sin `-`. Usa `su -` (el script ya añade `/usr/sbin` al PATH). |
| `El token no puede leer … (HTTP 404/401)` | Al token le falta `Contents:Read` sobre `fibra-os`, o expiró. Recréalo (paso 1). |
| `El contenedor no obtuvo IP (DHCP)` | Ese bridge no tiene DHCP. Reintenta con **IP estática** (opción 2) o `NET_MODE=static IP_CIDR=... GATEWAY=...`. |
| El contenedor se llama como el host | Versión vieja del script (bug de la variable `HOSTNAME`). Ya está arreglado; re-corre el instalador o `pct set <CTID> --hostname FibraOS`. |
| Docker no arranca en el CT | Necesita `nesting=1` (el script ya lo pone en el LXC que crea). |
| El build se queda sin RAM | Sube `RAM_MB` (el build del frontend consume memoria). 4096 suele bastar. |

---

## Notas

- **Modelo:** un contenedor = un ISP (single-tenant). Cada CT genera sus propios
  secretos (`SECRET_KEY` + password de DB) → no viaja ninguna credencial.
- No es una publicación en el repo **oficial** de community-scripts (ese exige
  código público FOSS). Es un instalador propio, en su estilo, para desplegar
  FibraOS de forma rápida y repetible.
