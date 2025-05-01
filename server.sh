#!/bin/bash

# BLOQUE 0
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}


# BLOQUE X — Instalación y configuración de Jellyfin + DLNA local + Refresco automático

log "[🎞️ Instalando y configurando Jellyfin como servidor DLNA local...]"

JELLYFIN_API_FILE="/etc/jellyfin_api.key"
JELLYFIN_LOG="/var/log/fitandsetup/jellyfin.log"
REFRESH_SCRIPT="/usr/local/bin/jellyfin_refresh.sh"
VIDEO_PATH="/mnt/storage/X"

# Instalar Jellyfin si no está presente
if ! dpkg -s jellyfin &>/dev/null; then
  curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash -s -- -y
fi

# Esperar arranque
sleep 15
systemctl enable jellyfin
systemctl start jellyfin

# Detectar IP local real
SERVER_IP=$(hostname -I | awk '{print $1}')
log "[✅ Jellyfin instalado y activo en http://$SERVER_IP:8096]"

# Añadir carpeta de vídeos si no se ha hecho ya
JELLYFIN_DATA="/var/lib/jellyfin/data/library/"

if [[ ! -d "$JELLYFIN_DATA" || ! $(grep "$VIDEO_PATH" "$JELLYFIN_DATA"/* 2>/dev/null) ]]; then
  log "[📁 Añade manualmente la carpeta '$VIDEO_PATH' como biblioteca desde la interfaz web si es la primera vez.]"
fi

# Preguntar por la API si no está guardada
if [[ ! -f "$JELLYFIN_API_FILE" ]]; then
  echo -e "\n🔑 Para habilitar el refresco automático, necesitas crear una API Key en:"
  echo "→ http://$SERVER_IP:8096"
  echo "Panel de control → API Keys → Nueva clave (nombre sugerido: refresco_script)"
  echo -n "¿Quieres introducir la API Key ahora? (s/n): "
  read -r CONFIRM_API

  if [[ "$CONFIRM_API" == "s" || "$CONFIRM_API" == "S" ]]; then
    echo -n "Introduce la API Key: "
    read -r API_KEY
    echo "$API_KEY" > "$JELLYFIN_API_FILE"
    chmod 600 "$JELLYFIN_API_FILE"
    log "[✅ API Key guardada en $JELLYFIN_API_FILE]"
  else
    log "[⏩ Saltando refresco automático de biblioteca por ahora.]"
    exit 0
  fi
fi

# Crear script de refresco automático
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

# Añadir cron si no está
if ! grep -q jellyfin_refresh /etc/crontab; then
  echo "*/15 * * * * root $REFRESH_SCRIPT" >> /etc/crontab
  log "[✅ Refresco automático de biblioteca activado cada 15 min.]"
fi
