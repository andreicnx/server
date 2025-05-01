#!/bin/bash

# BLOQUE 0
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}


# BLOQUE X — Instalación y configuración de Jellyfin como servidor DLNA local

log "[🎮 Instalando Jellyfin como servidor DLNA local...]"

JELLYFIN_LOG="/var/log/fitandsetup/jellyfin.log"
mkdir -p "$(dirname "$JELLYFIN_LOG")"

if ! dpkg -s jellyfin &>/dev/null; then
  curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash -s
fi

# Esperar inicio del servicio
sleep 15

# Obtener IP local real (no del bridge)
REAL_IP=$(hostname -I | awk '{for(i=1;i<=NF;i++) if ($i ~ /^192\./ || $i ~ /^10\./ || $i ~ /^172\./) { print $i; exit } }')

log "[✅ Jellyfin instalado y activo en http://$REAL_IP:8096]"

API_KEY_FILE="/etc/jellyfin/.api_key"
MEDIA_DIR="/mnt/storage/X"
REFRESH_SCRIPT="/usr/local/bin/jellyfin_refresh.sh"

# Configuración de biblioteca vía API si se ha creado ya
if [[ ! -f "$API_KEY_FILE" ]]; then
  echo "🔑 Para habilitar el refresco automático, necesitas crear una API Key en:"
  echo "→ http://$REAL_IP:8096"
  echo "Finaliza la configuración inicial, luego ve a: Panel de control → API Keys → Nueva clave"
  read -p "¿Quieres introducir la API Key ahora? (s/n): " introducir_api

  if [[ "$introducir_api" == "s" ]]; then
    read -p "Introduce tu API Key de Jellyfin: " api_key
    echo "$api_key" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
  else
    log "[⏩ Saltando refresco automático de biblioteca por ahora.]"
    exit 0
  fi
fi

API_KEY=$(cat "$API_KEY_FILE")
HOST="http://$REAL_IP:8096"

# Crear biblioteca si no existe ya
if ! curl -s -H "X-Emby-Token: $API_KEY" "$HOST/Library/VirtualFolders" | grep -q "$MEDIA_DIR"; then
  log "[➕ Añadiendo biblioteca de vídeos desde $MEDIA_DIR...]"
  curl -s -X POST "$HOST/Library/VirtualFolders" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Token: $API_KEY" \
    -d '{
      "Name": "Videos",
      "CollectionType": "movies",
      "Locations": ["'"$MEDIA_DIR"'"]
    }'
fi

# Crear script de refresco si no existe
if [[ ! -f "$REFRESH_SCRIPT" ]]; then
  cat <<EOF > "$REFRESH_SCRIPT"
#!/bin/bash
HOST="$HOST"
API_KEY="$API_KEY"
curl -s -X POST "\$HOST/Library/Refresh" -H "X-Emby-Token: \$API_KEY" >> "$JELLYFIN_LOG"
EOF
  chmod +x "$REFRESH_SCRIPT"
fi

# Añadir cron si no existe ya
if ! grep -q jellyfin_refresh /etc/crontab; then
  echo "*/15 * * * * root $REFRESH_SCRIPT" >> /etc/crontab
fi

log "[✅ Biblioteca configurada y refresco automático activo cada 15 minutos.]"
