# Instancias

[← Volver al README](../README.md)

## Varias instancias en un servidor

Puedes tener varios entornos completamente aislados en el mismo servidor (por ejemplo, uno por cliente o por persona). Cada instancia tiene su carpeta, sus volúmenes, su imagen, su identidad SSH y su propio nodo en Tailscale: no comparten datos ni contenedores, y `uninstall` o `backup` de una nunca tocan a las demás.

**Crear otra instancia:** ejecuta de nuevo el comando de instalación.

```bash
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash
# o con el alias elegido, sin preguntas:
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash -s -- --alias cliente-a
```

| Situación | Qué hace `install.sh` |
|---|---|
| No existe la principal | Instala la principal. Si una primera instalación falló a medias (queda el clon, sin recursos en Docker), volver a ejecutar la **retoma** |
| Existe la principal, con terminal y sin alias | Muestra un menú: crear una instancia nueva, actualizar una existente (`setup.sh upgrade`) o actualizar todas |
| Al crear una nueva, con terminal | Lista las instancias y pregunta `Alias de la nueva instancia [2]`. Enter acepta el siguiente número libre (`2`, `3`…); escribir un alias que ya existe **actualiza** esa instancia |
| Existe la principal, sin terminal ni alias | Crea sola la siguiente libre y lo informa |
| `--alias NOMBRE` o `AIWS_INSTANCE=NOMBRE` | Usa ese nombre sin preguntar; si ya existe, la actualiza. `--alias default` apunta de forma explícita a la principal |

**Alias válido:** de 1 a 20 caracteres entre `a-z`, `0-9` y `-`, sin empezar ni terminar en `-`. Están reservados `ts`, `mssql`, `postgres`, `redis` y los terminados en `-ts` o `-mssql`. `default` (o vacío) es la instancia principal.

La instancia principal conserva exactamente sus nombres de siempre: los servidores ya instalados siguen funcionando sin migrar nada.

### Cómo se nombra cada instancia

Con el alias `foo`, todo se nombra a partir de `ai-workspace-foo`:

| Recurso | Principal | Alias `foo` |
|---|---|---|
| Carpeta | `~/ai-workspace` | `~/ai-workspace-foo` |
| Proyecto compose y contenedor | `ai-workspace` | `ai-workspace-foo` |
| Sidecar de Tailscale / SQL Server | `ai-workspace-ts` / `ai-workspace-mssql` | `ai-workspace-foo-ts` / `ai-workspace-foo-mssql` |
| Imagen | `ai-workspace:latest` | `ai-workspace-foo:latest` |
| Volúmenes | `ai_home`, `ai_workspace`, `ai_ssh_host_keys`, `ai_ts_state`, `ai_mssql_data` | `ai-workspace-foo_home`, `_workspace`, `_ssh_host_keys`, `_ts_state`, `_mssql_data` |
| Nombre en la tailnet (`TS_HOSTNAME`) | `ai-workspace` | `ai-workspace-foo` |

### Reglas a tener en cuenta

- **Una carpeta, una instancia.** El alias queda guardado en el `.env` (`AIWS_INSTANCE`, más `AIWS_NAME` y `AIWS_VOL_PREFIX`, derivados de él) y no se cambia después de instalar. `setup.sh` se niega a usar contenedores que gestiona otra carpeta.
- **Tailscale:** cada instancia se registra como un equipo distinto, así que pide su propia auth key o link de login.
- **Puertos:** no hay conflictos, porque cada instancia tiene su propia red de Tailscale y no se publica nada en el servidor.
- **Recursos:** `MEM_LIMIT` y `CPUS` son topes por instancia (no reservas) y se suman; ver [Recursos por instancia](configuracion.md#recursos-por-instancia-memoria-y-cpus).
- **Actualizar una existente:** lo normal es `./setup.sh upgrade` desde su carpeta, o `aiws upgrade ALIAS`. Con el comando de una línea hay que indicarla (`--alias NOMBRE` o `--alias default`); sin alias el comando crea una nueva.
- **Instalar a mano:** `git clone https://github.com/heratok/ai-workspace.git ai-workspace-foo && cd ai-workspace-foo && ./setup.sh install --alias foo`.

Cada instancia se maneja desde su propia carpeta con `setup.sh`, o desde cualquier lugar con `aiws`:

```bash
cd ~/ai-workspace-foo && ./setup.sh status     # una instancia, desde su carpeta
aiws status foo                                # la misma, desde cualquier carpeta
ssh ai@ai-workspace-foo                        # el host SSH es el TS_HOSTNAME de la instancia
```

## Gestionar instancias con aiws

`aiws` es un comando del servidor para administrar **todas** las instancias sin entrar a la carpeta de cada una. `setup.sh install` (y `update`) lo deja en el `PATH`: enlace en `/usr/local/bin` si se puede escribir ahí; si no, en `~/.local/bin`, y avisa si esa carpeta no está en el `PATH`. Descubre las instancias solo (contenedores etiquetados, el registro `~/.local/share/ai-workspace/instances` y clones `~/ai-workspace*`) y delega cada acción en el `setup.sh` de la carpeta correspondiente, así que se comporta igual que ejecutarlo a mano.

```bash
aiws ls                                     # tabla: alias, estado, Tailscale, carpeta, MEM/CPUS y total
aiws upgrade santiago maria                 # actualiza dos instancias, una tras otra
aiws upgrade --all                          # actualiza todas
aiws upgrade                                # con terminal: lista numerada para elegir (1 3, 1-3 o todas)
aiws shell santiago                         # abre una shell en esa instancia
aiws resources                              # límites y uso real de memoria y CPU de todas
aiws resources santiago --mem 4g --cpus 2   # cambia los topes de una, sin reconstruir
aiws help                                   # todos los comandos; aiws help upgrade o aiws upgrade --help para uno solo
```

`aiws` sin argumentos equivale a `aiws ls`. `install` no se hace con `aiws`: usa `install.sh`.

### Referencia de comandos

| Tipo | Comandos | Cómo se indican las instancias |
|---|---|---|
| Lista | `ls` | No necesita: muestra todas |
| Varias instancias | `upgrade`, `update`, `backup` | Uno o varios alias, o `--all`. Sin argumentos, con terminal: lista para elegir |
| Varias, solo lectura | `status`, `doctor`, `ts-status` | Uno o varios alias, o `--all`. Sin argumentos actúan sobre todas |
| Ver o cambiar recursos | `resources` | Para ver: varios alias o `--all` (sin argumentos, todas). Para cambiar (`--mem`, `--cpus`, `--shm`, `--pids`, `--mssql-mem`, `--set`, `--no-apply`): una sola |
| Una sola instancia | `shell`, `logs`, `psql`, `components`, `add-key`, `migrate`, `progress`, `down` | `aiws COMANDO ALIAS [opciones]` |
| Destructivos, una sola | `restore`, `rollback`, `clean`, `uninstall`, `purge` | No aceptan `--all` ni varios alias; `setup.sh` sigue pidiendo su confirmación |
| Ayuda | `help` | `aiws help [COMANDO]` |

- **Alias:** los de `aiws ls`. `default` (o `principal`) es la instancia principal. Un alias desconocido se rechaza antes de ejecutar nada.
- **Varias a la vez:** se ejecutan en orden, **si una falla las demás continúan**, y al final hay un resumen `ok`/`fallo`; el código de salida es distinto de cero si alguna falló. El resumen de `upgrade` distingue `ok (actualizada)`, `ok (ya al día)` y `fallo`.
- **`upgrade` y `update` piden UNA confirmación al inicio** (`Se actualizarán y reconstruirán: 2, santiago. ¿Continuar? [s/N]`) y luego corren cada instancia sin más preguntas, así que ninguna puede colgar el lote. `--yes` (o `-y`) la omite (`aiws upgrade --all --yes`); sin terminal es obligatorio y, si falta, `aiws` sale con código 2 sin ejecutar nada.
- **Opciones para `setup.sh`:** en los comandos de varias instancias van después de `--` (`aiws upgrade santiago -- --foreground`); en los demás, tras el alias (`aiws uninstall santiago --all`).
