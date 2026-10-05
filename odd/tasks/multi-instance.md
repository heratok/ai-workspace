# Feature: multi-instance (several isolated ai-workspace environments on one VPS)

## Objective
Allow several isolated ai-workspace installations on the same VPS. Re-running the installer when an
instance already exists creates a new one named `ai-workspace-{alias}` automatically.

## Problem
All names are hardcoded (compose project `ai-workspace`, container names, volumes `ai_home`,
`ai_workspace`, `ai_ts_state`, `ai_ssh_host_keys`, `ai_mssql_data`, image `ai-workspace:latest`,
TS_HOSTNAME). A second install in another dir silently hijacks the first one's containers and shares
its data, SSH keys and Tailscale identity; `uninstall` from either dir wipes both.

## Design (decided)
- New `.env` var `AIWS_INSTANCE` (alias, `[a-z0-9-]`, 1-20 chars). Empty = default instance.
- Derived base name: default -> `ai-workspace`; alias `foo` -> `ai-workspace-foo`.
- Default instance keeps EXACT current names (backward compatible, no migration).
- Alias instance: project/container `ai-workspace-foo`, `ai-workspace-foo-ts`, `ai-workspace-foo-mssql`;
  volumes `ai-workspace-foo_home`, `_workspace`, `_ssh_host_keys`, `_ts_state`, `_mssql_data`;
  image `ai-workspace-foo:latest`; TS_HOSTNAME `ai-workspace-foo`; dir `~/ai-workspace-foo`.
- Compose reads names from `.env` (`AIWS_NAME`, `AIWS_VOL_PREFIX`) with defaults equal to today's names.
- install.sh automatic flow:
  - `--alias X` / `AIWS_INSTANCE=X` explicit: install or update that instance.
  - no alias + no existing default instance: install default (as today).
  - no alias + default exists: interactive -> list instances, prompt alias (suggest next free `2`,`3`...;
    typing an existing alias updates it); non-interactive -> next free numeric alias automatically.
  - Refuse an alias whose names collide with something not owned by that clone.
- Ports: no conflict (each instance has its own Tailscale netns). Warn about MEM_LIMIT/CPUS sum.

## Scope
install.sh, setup.sh, docker-compose.yml, env.example, README.md, .github/workflows/ci.yml, tests/.
Out of scope: landing page.

## TDD
Mode: strict (session config). Runner: none existed -> `bash tests/instances.test.sh` (new, plain bash
with stubbed `docker`), added to CI.

## Tasks
- [x] T1 Tests (RED): name derivation, alias validation, next-free-alias, collision detection
- [x] T2 setup.sh: derive all names from AIWS_INSTANCE; sourceable for tests
- [x] T3 docker-compose.yml + env.example: interpolated names with back-compat defaults
- [x] T4 install.sh: automatic alias detection/prompt, `--alias` flag, per-instance dir
- [x] T5 CI runs tests; README documents multi-instance
- [ ] T6 Verification: bash -n, shellcheck -S error, compose config (default + alias), tests GREEN
- [x] T7 `aiws` host command: instance discovery (labels/owner folder + ~/ai-workspace* clones), `aiws ls`
- [x] T8 `aiws upgrade <alias...>` / `--all` / no args = interactive multi-select; sequential, continue on failure, final summary
- [x] T9 `aiws <cmd> <alias>` passthrough to that instance's setup.sh (status, doctor, shell, backup, uninstall...)
- [x] T10 install.sh re-run menu: "crear nueva" or "actualizar <existente>"; setup.sh install puts `aiws` on PATH
- [x] T11 Tests, CI (bash -n/shellcheck on aiws), README
- [x] T12 Recursos por instancia sin reconstruir: SHM_SIZE/PIDS_LIMIT en compose; `setup.sh resources` (ver límites + uso real, cambiar con --mem/--cpus/--shm/--pids/--mssql-mem, --no-apply, --set interactivo); `aiws resources`
- [x] T13 Dimensionado al instalar: `--mem`/`--cpus` (install.sh y setup.sh install); sugerencia por RAM/CPUs/instancias existentes con prompt (tty) o aplicada (sin tty); nunca toca el .env de una instancia existente
- [x] T14 `aiws ls` con "Suma de límites" (máximos, no reservas) y host; ayuda, README, env.example; pruebas (matemática de sugerencia, validación, .env, apply sin build, tabla aiws, prompts)

## Acceptance criteria
- Default install produces identical names to before.
- Second run of install.sh yields `ai-workspace-2` (or chosen alias) with zero shared resources.
- `uninstall`/`backup` of one instance never touches another.

## Progress
Created 2026-10-05.
- T1 RED observado: `bash tests/instances.test.sh` con el código sin cambios -> 30 aserciones OK (triviales), 52 fallidas (`instance_names: command not found`, `write_instance_env`/`bind_alias` inexistentes; install.sh ejecutaba main al hacer source -> "Falta el plugin docker compose").
- T2-T4 GREEN: `bash tests/instances.test.sh` -> 116 aserciones correctas, 0 fallidas. install.sh probado de extremo a extremo con git/docker simulados via `cat install.sh | bash` (sin default -> principal; con default y sin tty -> `--alias 2`; `AIWS_INSTANCE=cli-a`; alias inválido rechazado).
- T3: `docker compose config -q` OK con env.example (external true y false); nombres default idénticos a los previos; alias foo -> ai-workspace-foo_home, ai-workspace-foo-ts, ai-workspace-foo:latest, etc.
- T5: README documenta multi-instancia; ci.yml agrega pruebas y checks de compose (default + alias), simulados localmente OK. Ejecución real en GitHub Actions: NO observada.
- T6 parcial: `bash -n` OK; tests GREEN; compose OK. **shellcheck no está instalado localmente: no ejecutado** (pendiente verlo en CI).
- Desviaciones: aliases reservados (ts, mssql, postgres, redis, *-ts, *-mssql) por colisión de nombres y porque la migración 001 hace `docker rm -f ai-workspace-postgres ai-workspace-redis`; etiqueta `org.ai-workspace.instance` en contenedores e imagen (recrea los contenedores de la principal en el próximo up); compose() inyecta AIWS_NAME/AIWS_VOL_PREFIX derivados.
Next: T6 pendiente de shellcheck (CI), revisión humana y commit.

### Ronda de correcciones (verificación independiente)
- RED observado (`bash tests/instances.test.sh`, 121 OK / 16 fallidas antes de implementar): bind_alias rechazaba un clon nuevo con la principal en otra carpeta (también en el e2e `cat install.sh | bash` simulado); default existente solo por clon; alias_taken sin ssh_host_keys/mssql_data; prompt sin re-pregunta; check_instance_owner no rechazaba dueño existente; devdb tunnel con host fijo (RED aparte contra el devdb original).
- Corregido (GREEN: 139 aserciones, 0 fallidas): 1) bind_alias solo rechaza si el .env tiene otra instancia o esta carpeta es dueña del contenedor; 2) la principal "existe" solo con recursos Docker (`--alias default` explícito, README documenta `./setup.sh upgrade`); 3) check_instance_owner muere si la carpeta dueña existe y difiere, avisa si ya no existe; 4) env_get quita \r; 5) prompt re-pregunta hasta 3 veces; 6) alias_taken cubre _ssh_host_keys y _mssql_data; 7) AIWS_HOSTNAME en compose + runtime.env + devdb tunnel.
- Nota: el test de CRLF (item 4) pasa también sin el fix en Git Bash de Windows (la sustitución de comandos descarta \r); sigue siendo regresión válida en Linux.
- Pendiente: shellcheck y ejecución real de CI.

### Alcance agregado (2026-10-05, autorizado por el usuario)
Comando de servidor `aiws` para gestionar todas las instancias: listar, actualizar una/varias/todas
(selección múltiple interactiva), y delegar cualquier comando al setup.sh de cada instancia.
Razón: actualizar desde la carpeta de cada instancia no era intuitivo. Next: T7.

### T7-T11 `aiws` (ver también el requisito de ayuda por comando)
- RED observado (`bash tests/aiws.test.sh` sin el script `aiws`): 11 aserciones OK (triviales) / 159 fallidas (`aiws: No such file`, `main: command not found`). RED de T10 en `tests/instances.test.sh` (`aiws_menu`/`aiws_update_instances`/`install_aiws_link` inexistentes, resumen sin "aiws help"): ~20 fallidas.
- GREEN: `bash tests/aiws.test.sh` -> 290 aserciones OK, 0 fallidas; `bash tests/instances.test.sh` -> 161 OK, 0 fallidas. `bash -n` OK en install.sh, setup.sh, aiws, config/devdb, entrypoint.sh y los dos tests; compose config -q OK (default y alias).
- Diseño: `aiws` (raíz, ejecutable, sourceable) con UNA tabla `AIWS_CMDS` (nombre|tipo|descripción|ejemplo) de la que salen despachador y ayuda (general, `help <cmd>`, `<cmd> --help|-h`); comando desconocido -> error + ayuda, exit 2; `install` se rechaza (exit 2) remitiendo a install.sh. Descubrimiento: contenedores etiquetados + dueño (label compose working_dir), sidecar heredado de la principal, y clones ~/ai-workspace* con setup.sh; dedupe por carpeta canónica; alias desde el .env (sin CR). Delegación: `(cd carpeta && bash ./setup.sh cmd ...)`.
- T10: install.sh con tty y la principal instalada muestra menú (1 crear, N actualizar <alias>, última "todas"); actualizar = `git pull --ff-only` + `setup.sh upgrade` en cada clon, secuencial, sigue si falla, resumen y rc != 0. Sin tty: igual que antes. setup.sh agrega `install_aiws_link` (install y update) y menciona `aiws help` en el resumen.
- Desviaciones/limitaciones: (a) las pruebas del enlace simbólico (`t_setup_aiws_link`) se OMITEN en Git Bash de Windows (no crea symlinks): la lógica de `install_aiws_link` no se pudo observar aquí, solo en Linux/CI; (b) el menú de install.sh actualiza con `setup.sh upgrade` (camino documentado de actualización) y solo encuentra instancias en `~/ai-workspace*` (las de otra carpeta: `aiws upgrade <alias>`); (c) los tests de aiws tardan ~110 s en Git Bash por el costo de procesos, rápido en Linux; (d) shellcheck sigue sin ejecutarse localmente.

### Ronda 4 (verificación independiente de aiws)
- RED observado: `tests/aiws.test.sh` 293 OK / 19 fallidas; `tests/instances.test.sh` 163 OK / 11 fallidas (report_status devolvía 0, git pull previo al upgrade, sin dedupe, copias `~/ai-workspace-bak` como "default", alias ambiguo elegido en silencio, sin registro, "08" octal, entorno sin limpiar, `--all` con alias, avisos de root/enlaces).
- Corregido: 1) `report_status` hace `exit rc` si el proceso falló (follow/upgrade/update/progress y el caso "ya en curso" propagan el estado real); 2) `aiws_update_instances` ya no hace `git pull` (lo hace `setup.sh upgrade`); 3) dedupe por instancia conservando el orden; 4) un clon de `~/ai-workspace*` solo cuenta si su carpeta coincide con el alias de su `.env` o tiene contenedores/registro (si no: aviso "se ignora"); alias repetido -> `inst_resolve` falla nombrando las carpetas; 5) registro `${XDG_DATA_HOME:-~/.local/share}/ai-workspace/instances` (install/upgrade lo escriben, uninstall/purge lo quitan, aiws lo lee); 6) `install_aiws_link` cae a ~/.local/bin si el enlace roto no es escribible, no pisa archivos normales, avisa de clon en /root; 7) `10#` en la selección; 8) `env -u ...` al delegar y error si se mezcla `--all` con alias.
- Las pruebas de enlaces simbólicos siguen omitiéndose en Git Bash (se ejecutan en Linux).

### Ronda 5 (e2e real en Linux: UX de upgrade)
- RED observado: `tests/aiws.test.sh` 294 OK / 37 fallidas; `tests/instances.test.sh` 176 OK / 18 fallidas (`g` sin `--no-pager`; `setup.sh upgrade` sin `--yes`, sin falla sin terminal, sin "ya al día"/`--rebuild`/`--foreground`; aiws sin confirmación única, sin `--yes`, sin resumen diferenciado).
- Corregido: `g` usa `git --no-pager`; `setup.sh upgrade [--yes|-y] [--rebuild] [--foreground]` (sin preguntas: stash automático, actualiza, reconstruye; al día -> "ya al día" y 0 sin reconstruir salvo `--rebuild`; sin `--yes` y sin tty falla con mensaje; con tty conserva las preguntas); `AIWS_UPGRADE_RESULT_FILE` (que aiws pasa a cada hija) recibe `updated`/`uptodate`; aiws: tipo `multi-build` (upgrade/update) con UNA confirmación ("Se actualizarán y reconstruirán: ...") y `-y/--yes`; sin tty ni `--yes` -> exit 2 sin ejecutar; hijas de comandos "varias" con stdin cerrado, las interactivas/destructivas heredan teclado; hijas de upgrade reciben `--yes`; resumen `ok (actualizada)` / `ok (ya al día)` / `fallo`; install.sh menú llama `setup.sh upgrade --yes`; README y ayuda documentan `--yes`.

### T12-T14 recursos por instancia y dimensionado
- RED observado: `tests/aiws.test.sh` 346 OK / 35 fallidas; `tests/instances.test.sh` 232 OK / 82 fallidas (sin `resources`, `res_check`, `suggest_mem`, `size_resources`, `--mem/--cpus`, `aiws resources`, "Suma de límites").
- GREEN: `tests/aiws.test.sh` 387 OK / 0 fallidas; `tests/instances.test.sh` 313 OK / 1 fallida (`assert_lacks` no definido en ese archivo; corregido y la prueba aislada pasa: 3/0; la coordinación la reproduce igual en Linux). `bash -n` OK; `docker compose config -q` OK (default, alias y SHM_SIZE=1g/PIDS_LIMIT=4096/MEM_LIMIT=3g/CPUS=2 reflejados: shm_size 1073741824, pids_limit 4096, mem_limit 3221225472, cpus 2); el paso de compose de ci.yml se ejecutó localmente OK.
- T12: compose `SHM_SIZE`/`PIDS_LIMIT` (defaults 2gb/2048 idénticos); `setup.sh resources` (ver límites + `docker stats`; `--mem/--cpus/--shm/--pids/--mssql-mem`, `--no-apply`, `--set` interactivo; validación todo-o-nada; aplica con `compose up -d --no-build` + wait_healthy, solo esa instancia); `aiws resources` (tabla de varias/--all con uso real y totales; cambiar exige una sola instancia y delega).
- T13: `--mem/--cpus` en install.sh (pasan a setup.sh install, también `--mem=VALOR`) y setup.sh install; sugerencia `(RAM-2g)/(existentes+1)` acotada 2g-8g y CPUs `min(4,nproc)` con prompt (tty) o aplicada (sin tty); aviso de poca memoria; nunca toca el .env de una instancia existente salvo flags explícitos; lectores de host sustituibles (`AIWS_HOST_MEM_KB`, `AIWS_HOST_CPUS`).
- T14: `aiws ls` con "Suma de límites ... Son máximos, no son reservas" y RAM/CPUs del servidor, con aviso si la suma supera la RAM; ayuda general y `aiws help resources`; README (sección "Recursos por instancia"), env.example (SHM_SIZE, PIDS_LIMIT, MSSQL_MEM_LIMIT y comentarios).
- Desviación: en `resources --set` el valor por defecto de cada prompt es el ACTUAL (Enter conserva; la sugerencia se muestra en el texto) para que un Enter no cambie límites por accidente; en la instalación nueva el default sí es la sugerencia.
