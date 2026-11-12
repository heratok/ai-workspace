# ghcr-image — publicar la imagen en GHCR y que los servidores la descarguen
Objetivo: el CI publica la imagen validada en GHCR (pública) y `setup.sh` la descarga en vez de construirla cuando el servidor usa la configuración por defecto.
Rama: `feat/ghcr-image` · Entrega: `ask-on-risk` · Pruebas: `bash tests/<nombre>.test.sh`

## Specs
- **S1** CI: en `push` a `main` y en la corrida del lunes, después de que pasen escaneos y pruebas de la imagen, publica `ghcr.io/heratok/ai-workspace:ctx-<hash del contexto de build>` y `:latest` como imagen pública. `packages: write` solo donde se publica; los PR nunca publican.
- **S2** Servidor con configuración por defecto (todas las variables de build del `.env` iguales a los valores por defecto de `docker-compose.yml`) y arquitectura amd64: `install`, `update`, `upgrade` y `rollback` descargan `ghcr.io/heratok/ai-workspace:ctx-<hash>` (calculado por `scripts/image-tag.sh` igual que en el CI) en lugar de construir, la etiquetan como `${AIWS_NAME}:latest` y recrean el contenedor. Volúmenes (`/workspace`, `/home/ai`) intactos. Usuario: "asi cada ai-workspace puede bajar la ultima version y mantener su datos y proyecto correctos".
- **S3** Servidor con alguna variable de build distinta (componentes, `USER_UID`/`USER_GID`, versiones fijadas, `NPM_EXTRA_PACKAGES`…), arquitectura distinta de amd64 o `AIWS_IMAGE_SOURCE=build`: construye local como hoy.
- **S4** Acordado con el usuario: "si el CI de ese commit falló o todavía no terminó, la imagen no existe en GHCR. Entonces upgrade avisa y no despliega." `upgrade` lo comprueba antes de tocar archivos; `update`/`rollback` fallan sin tocar el contenedor en marcha y explican la salida (esperar al CI o `AIWS_IMAGE_SOURCE=build`).
- **S5** `clean` borra las etiquetas viejas de GHCR de este servidor (cada una ocupa ~5 GB).
- **S6** Documentación (`docs/operacion.md`, `docs/configuracion.md`, `docs/desarrollo.md`) y `env.example` con `AIWS_IMAGE_SOURCE`.
- **S7** (derivado, necesario para S2) los `ARG` por defecto del `Dockerfile` coinciden con los valores por defecto de `docker-compose.yml`; una prueba lo exige, porque la imagen publicada se construye con los del `Dockerfile`.
- **S8** (derivado de L4) carpeta sin git o con cambios locales sin commit en el contexto de build (`Dockerfile`, `.dockerignore`, `entrypoint.sh`, `config/`): construye local, para no perder esas personalizaciones.

## Tasks
- [ ] T1 S1,S7,S8 · inline · CI publica en GHCR + pruebas de ci.yml y de coherencia ARG/compose · commit: —
- [ ] T2 S2-S5 · inline · `lib/image.sh` (decisión, descarga, limpieza) + integración en build_and_up/upgrade/clean + pruebas · commit: —
- [ ] T3 S6 · inline · documentación y env.example · commit: —
- [ ] T4 · verificador independiente (Risk: ítems 2 y 5) · —

## Log
- L1 (2026-11-12) Usuario: "si dale y si la imagen puede ser publica en ghcr ya el proyecto es publica y asi cada ai-worksapce puede bajar la ultima version y mantener su datos y proyecto correctos?"
- L2 Evidencia: `gh repo view` → heratok/ai-workspace PUBLIC. Mapa del explorador: único `compose build` en `lib/lifecycle.sh:66`; rollback lee `logs/.prev-version` y llama a `update`; `clean` filtra por la etiqueta `org.ai-workspace.instance`, que una imagen descargada no tiene; no hay ayudante que compare `.env` con los valores por defecto.
- L3 Decisiones: solo amd64 (multi-arquitectura con QEMU para 5 GB tardaría más de una hora); `AIWS_IMAGE_SOURCE=auto|build` (por defecto `auto`); la visibilidad pública del paquete se cambia una vez a mano en GitHub (la API no lo permite para paquetes de usuario).
- L4 Rediseño: con el filtro de rutas del #18 (ya en main) el job build no corre en commits solo de docs, así que una etiqueta por SHA de commit dejaría servidores sin imagen. La etiqueta pasa a ser un hash del contexto de build (`ctx-<hash>`), calculado por `scripts/image-tag.sh` en el CI y en el servidor.
