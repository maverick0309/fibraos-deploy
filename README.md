# FibraOS — Despliegue en Proxmox (LXC)

Instalador tipo *community-scripts.org*: crea un contenedor LXC (Debian 12) con
el stack completo de FibraOS en Docker (web + api + postgres + redis), listo para
loguear.

- **Script:** [`install.sh`](./install.sh)
- **Modelo:** un contenedor = un ISP (single-tenant), igual que [`../INSTALL.md`](../INSTALL.md).

---

## Instalación en un solo comando

En el **host Proxmox VE**, como **root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maverick0309/fibraos-deploy/main/install.sh)"
```

El script pide el **token de GitHub** (ver abajo), crea el contenedor, instala
Docker, descarga FibraOS, levanta el stack y crea un ISP demo con un usuario
admin. Al final imprime la **URL**, el **email** y la **contraseña**.

> El repo del código es **privado**, por eso hace falta un token de solo lectura.
> El instalador (`install.sh`) es público; el código se baja por la API de GitHub
> con ese token. El token **no se guarda en disco** en ningún momento.

---

## Antes de empezar: crea el token de SOLO LECTURA

En GitHub → **Settings → Developer settings → Personal access tokens →
Fine-grained tokens → Generate new token**:

1. **Repository access:** *Only select repositories* → `maverick0309/fibra-os`.
2. **Permissions → Repository permissions → Contents:** **Read-only**.
3. Copia el token (`github_pat_...`). Es lo único que le das al partner.

> Es de solo lectura y solo a ese repo: no puede modificar nada ni ver otros
> repos. **No reutilices** un token de push. Puedes revocarlo cuando quieras.

---

## Opciones (variables de entorno)

Todas opcionales salvo el token. Ejemplo no interactivo:

```bash
FIBRAOS_TOKEN=github_pat_xxx \
ISP_NAME="Astrovision" ISP_SLUG=astrovision \
ADMIN_EMAIL=admin@astrovision.sv ADMIN_PASSWORD='UnaClaveFuerte' \
RAM_MB=4096 DISK_GB=20 CORES=2 BRIDGE=vmbr0 STORAGE=local-lvm \
./install.sh
```

| Variable | Def | Qué es |
|---|---|---|
| `FIBRAOS_TOKEN` | *(pide por prompt)* | Token GitHub RO. **Obligatorio.** |
| `REPO` / `REF` | `maverick0309/fibra-os` / `main` | Repo y rama/tag a desplegar. |
| `CTID` | siguiente libre | ID del contenedor LXC. |
| `HOSTNAME` | `fibraos` | Nombre del contenedor. |
| `DISK_GB` / `RAM_MB` / `CORES` | `20` / `4096` / `2` | Recursos. |
| `BRIDGE` / `STORAGE` / `TEMPLATE_STORAGE` | `vmbr0` / `local-lvm` / `local` | Red / disco / plantillas. |
| `ISP_NAME` / `ISP_SLUG` | `Demo ISP` / `demo` | ISP que se crea. |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` / `ADMIN_NAME` | `admin@demo.local` / *(aleatoria)* / `Admin` | Usuario admin. |

---

## Qué hace el script

1. Comprueba que corre en Proxmox como root y **valida el token** contra el repo
   antes de crear nada.
2. Descarga la plantilla Debian 12 (si falta) y crea un **LXC unprivileged** con
   `features: nesting=1,keyctl=1` (necesario para Docker dentro de LXC).
3. Dentro del contenedor: instala Docker, baja el código por la API con el token,
   genera un `.env` con **`SECRET_KEY` y contraseña de base de datos nuevas**
   (`openssl rand`), y levanta `docker-compose.prod.yml`.
4. Espera a que la API responda (`/api/health`) y crea el ISP + admin
   (`scripts/bootstrap_isp.py`).
5. Si algo falla, **elimina el contenedor a medias** para no dejar basura.

Cada contenedor genera sus propios secretos → no viaja ninguna credencial.

---

## Después de instalar

- Entra en `http://<IP-del-contenedor>/` con el email/clave que imprime el script.
- Para ver datos reales, el contenedor debe **alcanzar las OLTs/MikroTik** del ISP
  (LAN directa o **VPN WireGuard**). Para probar la app/UI no hace falta: entra y
  añade una OLT alcanzable desde **OLTs → Nueva OLT**.
- Logs: `pct exec <CTID> -- docker compose -f /opt/fibraos/docker-compose.prod.yml logs -f api`
- Actualizar a la última versión: volver a correr el instalador en un CTID nuevo,
  o dentro del CT `cd /opt/fibraos && git pull` no aplica (se bajó por tarball) —
  para actualizar, re-desplegar.

---

## Troubleshooting

| Síntoma | Causa / arreglo |
|---|---|
| `El token no puede leer … (HTTP 404/401)` | El token no tiene `Contents:Read` sobre `fibra-os`, o expiró. Recréalo. |
| Docker no arranca dentro del CT | Falta `nesting=1`. El script ya lo pone; si usas un CT propio, añade `features: nesting=1,keyctl=1`. |
| El CT no obtiene IP | El `BRIDGE` no es el correcto para tu red. Pása `BRIDGE=vmbrX`. |
| El build tarda mucho / se queda sin RAM | Sube `RAM_MB` (el build del frontend consume memoria). 4096 suele bastar. |
| No hay datos de ONTs | Normal sin OLT alcanzable. Añade una OLT (con VPN/LAN a su red de gestión). |

---

## Nota

No es una publicación en el repo **oficial** de community-scripts (ese exige
código público FOSS). Es un instalador propio, en su estilo, para desplegar
FibraOS (privado) de forma rápida y repetible.
