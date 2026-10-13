# Resolver problemas

[← Volver al README](../README.md)

## Solución de problemas

| Síntoma | Causa y solución |
|---|---|
| Se cayó SSH durante `install` o `update` | La instalación continúa en segundo plano. Reconecta y ejecuta `./setup.sh progress` |
| `aiws: command not found` | `setup.sh install` o `update` crea el enlace, y avisa si `~/.local/bin` no está en tu `PATH`. Agrégalo, o enlázalo a mano: `ln -s ~/ai-workspace/aiws ~/.local/bin/aiws` |
| `aiws` dice "Instancia desconocida" | Revisa los alias con `aiws ls`. `default` (o `principal`) es la principal |
| `aiws upgrade` sale con código 2 | Sin terminal, la confirmación es obligatoria: agrega `--yes` |
| `./setup.sh upgrade` falla sin terminal | Usa `./setup.sh upgrade --yes` |
| `install.sh` creó otra instancia en vez de actualizar | Con la principal ya instalada y sin alias, crea una nueva. Para actualizar usa `./setup.sh upgrade`, `aiws upgrade ALIAS` o `--alias NOMBRE` |
| "El contenedor … lo gestiona otra carpeta" | Una carpeta es una instancia. Usa esa carpeta, o elige otro alias |
| Tras `upgrade`, algo dejó de funcionar | `./setup.sh rollback` vuelve a la versión anterior y reconstruye |
| El `build` falla durante `update` o `upgrade` | El contenedor anterior sigue en pie. Revisa el log con `./setup.sh progress` o `logs/latest.log` |
| Alerta "host key changed" al conectar por SSH | Se borró el volumen `ai_ssh_host_keys`. Quita la entrada vieja de `~/.ssh/known_hosts` |
| El nodo pide auth key otra vez | Se borró el volumen `ai_ts_state`: es un nodo nuevo. Pega una auth key o usa el link de login |
| No entro por SSH | Comprueba `./setup.sh ts-status` y `./setup.sh doctor`. Si no autorizaste tu clave: `./setup.sh add-key` |
| Permisos incorrectos en el home tras cambiar `USER_UID` / `USER_GID` | Pon `FIX_OWNERSHIP=true` una sola vez y ejecuta `./setup.sh update` |
| El frontend no abre en `:3000` / `:5173` | El servidor de desarrollo debe escuchar en `0.0.0.0` (p. ej. `vite --host`) |
| `ERR_CONNECTION_REFUSED` en `localhost:PUERTO` al hacer login de una herramienta | El callback apunta al `localhost` de tu PC. Abre un túnel `ssh -L`: ver [Login OAuth con callback en localhost](herramientas.md#login-oauth-con-callback-en-localhost) |
| `agy` falla con `Illegal instruction` | El servidor (o su VM) no expone las instrucciones AES de la CPU. Habilítalas en el hipervisor o desmarca el componente |
| La suma de `MEM_LIMIT` supera la RAM | Es un aviso, no un error: son topes. Ajusta con `aiws resources ALIAS --mem 4g` si varias instancias usan memoria a la vez |
