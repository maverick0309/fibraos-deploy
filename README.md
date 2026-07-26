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

---

## Actualizar una instalación existente

`update.sh` **solo actualiza** — no instala ni crea contenedores. Úsalo para
llevar los cambios del código a un FibraOS que ya está funcionando.

Dentro del contenedor, como root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maverick0309/fibraos-deploy/main/update.sh)"
```

Desde el host Proxmox, sin entrar al contenedor:

```bash
pct exec <CTID> -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/maverick0309/fibraos-deploy/main/update.sh)"
```

**Qué hace, en orden:**
1. Comprueba que exista la instalación (si no, te dice que uses `install.sh`).
2. **Backup**: `pg_dump` de la base + copia de `.env` en `/opt/fibraos-backups/`
   (conserva los últimos 5).
3. Descarga el código nuevo con el mismo token de solo lectura.
4. **Conserva `.env` intacto** y la base de datos.
5. `docker compose up -d --build` y espera a que la API responda.
6. **Si el arranque falla, restaura solo la versión anterior.**

Si ya estás en la última versión, lo dice y no hace nada.

### Qué trae cada versión

Tras actualizar, dentro del contenedor tienes **`/opt/fibraos/CHANGELOG.md`**: qué se
arregló, qué cambia de comportamiento y **qué te conviene ajustar en tus OLTs** (ACLs de
gestión, communities, límite de sesiones del usuario). Está escrito para el ISP, no para
el que programa.

```bash
pct exec <CTID> -- cat /opt/fibraos/CHANGELOG.md | head -60
```

Y si vas a mirar el código, `/opt/fibraos/docs/COMUNICACION-CON-LAS-OLT.md` explica cómo
FibraOS habla con los equipos: qué pide por SNMP, qué por CLI, y por qué.

> ⚠️ **Nunca regenera `.env`.** `SECRET_KEY` cifra las credenciales de las OLTs
> guardadas: si cambiara, se perderían todas y habría que volver a introducirlas.

| Flag / Variable | Para qué |
|---|---|
| `--dry-run` | Solo dice qué versión instalaría; no cambia nada. |
| `--no-backup` | Omite el backup (desaconsejado). |
| `REF=<rama\|tag>` | Instala una versión concreta (def: `main`). |
| `FIBRAOS_TOKEN` | El mismo token RO; si no se pasa, lo pide por teclado. |
| `APP_DIR` | Instalación a actualizar (def: `/opt/fibraos`). |

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

---

## OLTs que no reconoces en tu panel

Si ves OLTs que no configuraste (las versiones antiguas de FibraOS traían scripts
de ejemplo que podían insertar datos de demostración):

1. **Actualiza** con `update.sh` — las versiones nuevas ya no traen esos scripts.
2. Entra en la OLT → pestaña **Acciones** → **Eliminar OLT** (hay que escribir su
   nombre exacto). **Tú decides qué se va con ella:**

   | | Se borra |
   |---|---|
   | Siempre | la OLT, sus ONTs y su histórico de señal, eventos y tráfico |
   | ☐ opcional | sus **clientes** |
   | ☐ opcional | sus **tickets / averías** |
   | ☐ opcional | su **facturación** (facturas y pagos) |

   Sin marcar nada, los clientes se conservan sin ONT vinculada. **La facturación
   nunca se borra por defecto.** Y si pides borrar los clientes pero no la
   facturación, los que tengan facturas **se conservan** (una factura no puede
   quedarse sin dueño) y la app te dice cuántos fueron. El equipo del **inventario
   nunca se borra**: solo se desvincula, porque sigue instalado físicamente.

3. Si alguna no aparece en la lista pero sigue en la base (fila sin ISP asignado),
   ya no se consulta, pero para quitarla del todo:
   ```sql
   SELECT id, name, host FROM olts WHERE tenant_id IS NULL;
   DELETE FROM onts WHERE olt_id IN (SELECT id FROM olts WHERE tenant_id IS NULL);
   DELETE FROM olts WHERE tenant_id IS NULL;
   ```

Una instalación nueva de FibraOS **arranca vacía**: 0 OLTs, 0 ONTs, 0 clientes.
Solo se crean el ISP y el usuario admin que indica el instalador.

### Comprobar si te quedaron restos de una OLT borrada

Una consulta y sales de dudas (no modifica nada):

```bash
docker exec -it fibraos-db psql -U fibraos -d fibraos
```
```sql
SELECT (SELECT count(*) FROM olts)                                  AS olts,
       (SELECT count(*) FROM olts WHERE tenant_id IS NULL)          AS olts_sin_isp,
       (SELECT count(*) FROM onts)                                  AS onts,
       (SELECT count(*) FROM clients)                               AS clientes,
       (SELECT count(*) FROM clients WHERE ont_id IS NULL)          AS clientes_sin_ont,
       (SELECT count(*) FROM tickets WHERE ont_id IS NULL
                                       AND client_id IS NULL)       AS tickets_huerfanos;
```

- `clientes_sin_ont` alto = clientes de una OLT que ya borraste. Para quitarlos:
  ```sql
  SELECT id, name, zone FROM clients WHERE ont_id IS NULL ORDER BY name;   -- míralos
  DELETE FROM clients WHERE ont_id IS NULL
                        AND id NOT IN (SELECT client_id FROM invoices);    -- sin facturación
  ```
- `tickets_huerfanos` alto = averías de equipos que ya no existen:
  `DELETE FROM tickets WHERE ont_id IS NULL AND client_id IS NULL;`

> Haz antes un backup: `update.sh` ya crea uno en `/opt/fibraos-backups/`.

---

## Mi OLT solo funciona por Telnet (o SSH no conecta)

Normal, sobre todo en **ZTE**: los dos protocolos son **excluyentes**.

| Comando en la OLT | Efecto |
|---|---|
| `ssh server only` | deja **solo SSH** (Telnet desactivado) |
| `no ssh server only` | deja **solo Telnet** (SSH desactivado) |

De fábrica muchas ZTE vienen en modo Telnet. FibraOS **usa el protocolo que elijas** y
nunca lo cambia solo: entra en la OLT → **Configuración** → *Protocolo principal* →
`Telnet`, y guarda.

- Pulsa **Probar conexión**: te dice qué puertos están abiertos (`SSH :22 · Telnet :23`)
  y qué protocolo deberías usar. No hace falta que entres a la OLT a mirarlo.
- ⚠️ **Telnet no cifra**: usuario y contraseña viajan en claro. Úsalo solo dentro de tu
  LAN de gestión o de una VPN, nunca expuesto a internet.
- En una ZTE C320 real, Telnet resultó **~3× más rápido** que SSH leyendo las mismas
  ONUs (21 s frente a 63 s): la negociación SSH con cifrado legacy es cara para la
  tarjeta de control de la OLT.

---

### Si borras una OLT y sigue apareciendo en el listado
Ya no pasa (se corrigió el refresco de la lista). Con una versión anterior, recarga
la página: **la OLT ya estaba borrada**, era la lista lo que no se refrescaba.

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
