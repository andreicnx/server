#!/bin/bash

# BLOQUE 0.0
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}
# BLOQUE — Instalación y configuración de Jellyfin como DLNA

log "[🎞️ Instalando y configurando Jellyfin como servidor DLNA local...]"

JELLYFIN_LOG="/var/log/fitandsetup/jellyfin.log"
JELLYFIN_API_FILE="/etc/jellyfin_api.key"
REFRESH_SCRIPT="/usr/local/bin/jellyfin_refresh.sh"

# Instalar Jellyfin si no está
if ! dpkg -s jellyfin &>/dev/null; then
  apt install -y gnupg lsb-release curl apt-transport-https

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg
  echo "deb [signed-by=/etc/apt/keyrings/jellyfin.gpg arch=$( dpkg --print-architecture )] https://repo.jellyfin.org/ubuntu $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/jellyfin.list

  apt update
  apt install -y jellyfin
fi

# Esperar a que arranque y obtener IP local real
systemctl enable jellyfin
systemctl start jellyfin
sleep 15
IP_LOCAL=$(ip route get 1 | awk '{print $7; exit}')
log "[✅ Jellyfin instalado y activo en http://$IP_LOCAL:8096]"

# Añadir carpeta como biblioteca si config.json está listo
CONFIG_FILE="/var/lib/jellyfin/config/system.xml"
if [[ -f "$CONFIG_FILE" ]]; then
  log "[📁 Añadiendo carpeta '/mnt/storage/X' a la biblioteca de Jellyfin...]"
  mkdir -p /mnt/storage/X
  # Aún no hay método fiable de insertar librerías vía línea de comandos.
  # Se espera que el usuario termine configuración inicial desde la web.
else
  log "[📁 Añade manualmente la carpeta '/mnt/storage/X' como biblioteca desde la interfaz web si es la primera vez.]"
fi

# Obtener API Key si no está guardada
if [[ ! -f "$JELLYFIN_API_FILE" ]]; then
  echo ""
  echo "🔑 Para habilitar el refresco automático, necesitas crear una API Key en:"
  echo "→ http://$IP_LOCAL:8096"
  echo "Finaliza la configuración inicial, luego ve a: Panel de control → API Keys → Nueva clave"
  echo ""

  read -r -p "¿Quieres introducir la API Key ahora? (s/n): " RESPUESTA </dev/tty
  if [[ "$RESPUESTA" == "s" ]]; then
    read -r -p "Introduce la API Key de Jellyfin: " JELLYFIN_API_KEY </dev/tty
    echo "$JELLYFIN_API_KEY" > "$JELLYFIN_API_FILE"
    chmod 600 "$JELLYFIN_API_FILE"
    log "[✅ API Key guardada en $JELLYFIN_API_FILE]"
  else
    log "[⏩ Saltando refresco automático de biblioteca por ahora.]"
    return 0 2>/dev/null || exit 0
  fi
fi

# Crear script de refresco si no existe
if [[ ! -f "$REFRESH_SCRIPT" ]]; then
  log "[🛠️ Creando script de refresco automático de la biblioteca Jellyfin...]"
  cat <<EOF > "$REFRESH_SCRIPT"
#!/bin/bash
API_KEY=\$(cat "$JELLYFIN_API_FILE")
HOST="http://127.0.0.1:8096"

if ! systemctl is-active --quiet jellyfin; then
  echo "[\$(date)] Jellyfin no estaba activo. Iniciando..." >> "$JELLYFIN_LOG"
  systemctl start jellyfin
  sleep 10
fi

curl -s -X POST "\$HOST/Library/Refresh" -H "X-Emby-Token: \$API_KEY" >> "$JELLYFIN_LOG"
EOF

  chmod +x "$REFRESH_SCRIPT"
fi

# Añadir cron si no existe
if ! grep -q jellyfin_refresh /etc/crontab; then
  echo "*/15 * * * * root $REFRESH_SCRIPT # jellyfin_refresh" >> /etc/crontab
  log "[⏱️ Tarea programada: refresco automático de biblioteca cada 15 min.]"
fi
