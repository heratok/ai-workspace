# ai-workspace

Entorno de desarrollo aislado en Docker para trabajar con agentes de IA, accesible **solo por Tailscale** y por SSH. Puedes tener varias instancias independientes en el mismo servidor y administrarlas con el comando `aiws`.

- Lo del sistema se instala en la imagen. Lo del usuario se instala sin root en el home.
- En el servidor no se instala nada aparte de Docker: Tailscale corre como contenedor.
- El servidor no publica ningún puerto.
- El contenedor del workspace corre con `cap_drop: ALL` y solo 6 capacidades (las que usan el entrypoint y sshd); el usuario `ai` no tiene ninguna. Si una función que corre como root falla con `Operation not permitted`, ver el comentario en `docker-compose.yml`.

```
 Tu PC (tailnet) ──Tailscale──► [ai-workspace-ts]  ◄─ red compartida ─►  [ai-workspace]
                                 sidecar, NET_ADMIN                       sshd :22, mosh, :3000, :5173
                                 volumen ai_ts_state                      usuario ai, sin root
```

## Contenido

1. [Inicio rápido](#inicio-rápido) y [Requisitos y Tailscale](#requisitos-y-tailscale)
2. Documentación detallada (`docs/`):
   - [Instancias](docs/instancias.md): varias instancias por servidor y el comando `aiws`
   - [Referencia de configuración](docs/configuracion.md): variables del `.env`, recursos y componentes
   - [Guía de operación](docs/operacion.md): comandos de `setup.sh`, actualizar, respaldos, limpieza y volúmenes
   - [Imagen y herramientas](docs/herramientas.md): qué trae la imagen, bases de datos, agentes, Herdr, Doppler, Playwright
   - [Resolver problemas](docs/solucion-de-problemas.md)
   - [Desarrollo y migración](docs/desarrollo.md): CI y migración desde v1

## Inicio rápido

Necesitas un servidor Linux con Docker y una cuenta de Tailscale (detalles en [Requisitos](#requisitos-y-tailscale)).

### Opción A: un solo comando (recomendada)

```bash
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash
```

Clona el repositorio en `~/ai-workspace` (o lo actualiza si ya existe) y ejecuta `setup.sh install`. Te pide la auth key de Tailscale (o te da un link de inicio de sesión) y tu clave SSH pública, y después sigue solo.

```bash
# Sin preguntas
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh \
  | bash -s -- --authkey tskey-auth-XXXX --pubkey 'ssh-ed25519 AAAA...'

# En otra carpeta (por defecto: ~/ai-workspace)
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh \
  | AIWS_DIR=/opt/ai-workspace bash
```

Requiere `git` y Docker con `docker compose`. Para revisar el script antes de ejecutarlo: `curl -fsSLO …/install.sh && less install.sh && bash install.sh`.

Variables de `install.sh`: `AIWS_INSTANCE` (alias, equivale a `--alias`), `AIWS_DIR` (carpeta), `AIWS_REPO_URL` (repositorio) y `AIWS_REPO_BRANCH` (rama o tag, por defecto `main`). Los demás argumentos pasan tal cual a `setup.sh install` (`--authkey`, `--pubkey`, `--mem`, `--cpus`, `--foreground`).

> Si ya hay una instancia en el servidor, volver a ejecutar el comando **crea otra** en lugar de reinstalar. Ver [Varias instancias](docs/instancias.md#varias-instancias-en-un-servidor).

### Opción B: clonar a mano

```bash
git clone https://github.com/heratok/ai-workspace.git
cd ai-workspace
chmod +x setup.sh
./setup.sh                     # menú → 1) Instalar

# o, sin menú:
./setup.sh install             # opcional: --authkey tskey-auth-XXXX --pubkey 'ssh-ed25519 AAAA...'
```

Clonar desde GitHub permite actualizar luego con `./setup.sh upgrade`.

### Qué hace `setup.sh install`

1. Valida los requisitos.
2. Corrige los saltos de línea de Windows (CRLF).
3. Crea `.env` a partir de `env.example`.
4. Pide la auth key, o muestra un link de inicio de sesión si no la pegas.
5. Aplica las migraciones pendientes y crea los volúmenes.
6. Construye la imagen y levanta los contenedores.
7. **Borra la auth key del `.env`** una vez registrado el nodo.
8. Autoriza tu clave SSH.
9. Deja el comando [`aiws`](docs/instancias.md#gestionar-instancias-con-aiws) en el `PATH`.
10. Ejecuta `ws-doctor`.

Puedes ejecutarlo de nuevo cuando quieras: los datos se conservan.

Las preguntas se hacen al principio y el resto sigue en **segundo plano**: si se cae la conexión SSH, la instalación continúa (ver [Si se cae SSH durante la instalación](docs/operacion.md#si-se-cae-ssh-durante-la-instalación)).

### Conexión

```bash
ssh ai@ai-workspace                       # con MagicDNS (si no, usa la IP 100.x)
mosh -p 60000:60010 ai@ai-workspace
# Frontends: http://ai-workspace:3000 y :5173 (el servidor de desarrollo debe escuchar en 0.0.0.0, p. ej. vite --host)
```

El host es el `TS_HOSTNAME` de la instancia (`ai-workspace-ALIAS` si tiene alias). SSH usa el puerto **22** de la IP de Tailscale.

## Requisitos y Tailscale

| Dónde | Qué |
|---|---|
| Servidor Linux | Docker con el plugin `docker compose` (v2), `git` (para `install.sh`) y que exista `/dev/net/tun` |
| Cuenta de Tailscale | Nada que preparar: el script te pide la auth key (solo pegar) o te da un link para iniciar sesión |
| Tu PC | Tailscale conectado a la misma tailnet y una clave SSH. En Windows (PowerShell): `ssh-keygen -t ed25519` (si no tienes) y `type $env:USERPROFILE\.ssh\id_ed25519.pub` para copiarla. Se pega cuando `setup.sh` la pide |

### Conexión a Tailscale: dos formas

En la primera instalación, `setup.sh` muestra `Auth key (oculta):`.

| Qué haces | Qué pasa | Recomendado para |
|---|---|---|
| **Pegas la auth key** y presionas Enter | Se conecta solo | Servidores (con tag, el nodo no vence) |
| **Presionas Enter** sin pegar nada | El script muestra un link `https://login.tailscale.com/a/...`; lo abres, apruebas y continúa solo (espera hasta 10 min) | Probar rápido. El nodo vence a los 180 días, salvo que en el panel uses *Disable key expiry* |

### Cómo crear la auth key

1. Entra a https://login.tailscale.com/admin/settings/keys y pulsa **Generate auth key**.
2. Configúrala así:
   - **Reusable:** sí, para poder reinstalar.
   - **Ephemeral:** **no**. Si es ephemeral, el nodo desaparece al reiniciarse.
   - **Tags:** `tag:ai-workspace` (recomendado). Antes hay que declarar el tag en las ACL:
     ```json
     "tagOwners": { "tag:ai-workspace": ["autogroup:admin"] }
     ```
     Los nodos con tag **no vencen** (no tienen key expiry), así que no se desconectan cada 180 días.
3. Copia la clave, que empieza con `tskey-auth-`, y pégala cuando el script la pida. Solo se pide una vez.
