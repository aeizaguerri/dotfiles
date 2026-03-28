# gdrive-sync

Sincronización bidireccional robusta de Google Drive en Linux usando `rclone bisync` + `inotifywait`.

## Arquitectura

```
┌─────────────────────────────────────────┐
│          ARRANQUE DEL PC                │
│  gdrive-sync-boot.service (oneshot)     │
│  → rclone bisync (trae cambios remotos) │
└─────────────┬───────────────────────────┘
              │ After=
              ▼
┌─────────────────────────────────────────┐
│       WATCHER PERMANENTE                │
│  gdrive-sync-watcher.service (simple)   │
│  → inotifywait en ~/GoogleDrive-local   │
│  → debounce 30s                         │
│  → rclone bisync                        │
└─────────────────────────────────────────┘
```

### Flujo

1. **Al hacer login**: `gdrive-sync-boot.service` ejecuta un bisync completo para traer cualquier cambio remoto (ediciones desde el celu, la web, otro PC).
2. **Mientras usás el PC**: `gdrive-sync-watcher.service` monitorea `~/GoogleDrive-local` con `inotifywait`. Cuando detecta cambios, espera 30 segundos de inactividad (debounce) y lanza un bisync.
3. **Al apagar**: No hay sync explícito. El watcher ya sincronizó cada cambio a los ~30s de producirse, así que al apagar ya está todo al día.

## Requisitos

- **rclone** — `sudo dnf install rclone`
- **inotify-tools** — `sudo dnf install inotify-tools`
- **rclone remote configurado** — `rclone config` (debe existir `gdrive:`)

## Instalación

```bash
cd ~/dotfiles/gdrive-sync
./install.sh
```

El instalador:
1. Verifica dependencias (rclone, inotifywait, remote configurado)
2. Limpia el setup viejo (cron, locks zombies, script anterior)
3. Copia los scripts a `~/.local/bin/`
4. Crea el marker `RCLONE_TEST` para `--check-access`
5. Si es la primera vez, ejecuta `--resync` para sincronizar las listings
6. Instala y habilita los servicios de systemd
7. Activa `loginctl enable-linger` para que los servicios arranquen al boot

## Desinstalación

```bash
cd ~/dotfiles/gdrive-sync
./install.sh --uninstall
```

Detiene servicios, los deshabilita, y borra scripts y units. **No borra** la carpeta `~/GoogleDrive-local` ni los logs.

## Archivos instalados

| Archivo | Ubicación | Función |
|---------|-----------|---------|
| `gdrive-sync.sh` | `~/.local/bin/` | Script principal de bisync |
| `gdrive-watcher.sh` | `~/.local/bin/` | Watcher con inotifywait + debounce |
| `gdrive-sync-boot.service` | `~/.config/systemd/user/` | Sync al login |
| `gdrive-sync-watcher.service` | `~/.config/systemd/user/` | Watcher permanente |

## Uso manual

```bash
# Sync manual
gdrive-sync.sh

# Forzar resync completo (si algo se rompe)
gdrive-sync.sh --resync
```

## Comandos útiles

```bash
# Ver estado del watcher
systemctl --user status gdrive-sync-watcher

# Ver logs en vivo del watcher
journalctl --user -u gdrive-sync-watcher -f

# Ver logs de sincronización
cat ~/.local/share/gdrive-sync/logs/gdrive-sync.log
cat ~/.local/share/gdrive-sync/logs/gdrive-watcher.log

# Reiniciar watcher
systemctl --user restart gdrive-sync-watcher

# Sync manual inmediato
gdrive-sync.sh
```

## Configuración

Variables de entorno (se pueden setear en los archivos `.service`):

| Variable | Default | Descripción |
|----------|---------|-------------|
| `GDRIVE_REMOTE` | `gdrive:` | Nombre del remote de rclone |
| `GDRIVE_LOCAL` | `~/GoogleDrive-local` | Carpeta local de sincronización |
| `GDRIVE_LOG_DIR` | `~/.local/share/gdrive-sync/logs` | Directorio de logs |
| `GDRIVE_DEBOUNCE_SEC` | `30` | Segundos de espera antes de sincronizar |
| `GDRIVE_MAX_LOG_LINES` | `2000` | Líneas máximas en el log (rotación automática) |

Para cambiar, editá el service:
```bash
systemctl --user edit gdrive-sync-watcher.service
```

Y agregá:
```ini
[Service]
Environment=GDRIVE_DEBOUNCE_SEC=15
```

## Solución de problemas

### "Sync already running, skipping"
El script anterior tenía un bug de lock. El nuevo usa PID-based locking con cleanup automático. Si aún así pasa:
```bash
# Ver qué PID tiene el lock
cat ~/.local/share/gdrive-sync/logs/gdrive-sync.lock
# Verificar si ese proceso existe
ps -p <PID>
# Si no existe, borrarlo
rm ~/.local/share/gdrive-sync/logs/gdrive-sync.lock
```

### "prior lock file found" (error de rclone)
Rclone bisync tiene su propio sistema de locks. El script los limpia automáticamente al arrancar. Si persiste:
```bash
rm -f ~/.cache/rclone/bisync/*.lck
```

### Resync completo (nuclear option)
Si bisync se corrompe y no recupera:
```bash
gdrive-sync.sh --resync
```
Esto reconstruye las listings desde cero. Es seguro — no borra archivos.

### inotify watch limit
Si tenés muchos archivos y `inotifywait` falla:
```bash
# Ver límite actual
cat /proc/sys/fs/inotify/max_user_watches
# Aumentar (temporal)
sudo sysctl fs.inotify.max_user_watches=524288
# Aumentar (permanente)
echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/90-inotify.conf
sudo sysctl --system
```
