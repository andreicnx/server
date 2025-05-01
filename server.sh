
#!/bin/bash

# BLOQUE 0.0
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}

# BLOQUE — Instalación y configuración de Jellyfin con refresco automático

log "[🎞️ Instalando y configurando Jellyfin como servidor DLNA local...]"

JELLYFIN_LOG="/var/log/fitandsetup/jellyfin.log"
JELLYFIN_API_KEY_FILE="/etc/jellyfin/api_key"
REFRESH_SCRIPT="/usr/local/bin/jellyfin_refresh.sh"
mkdir -p "$(dirname "$JELLYFIN_LOG")"

# Detectar IP real del servidor
IP_LOCAL=$(ip -4 route get 8.8.8.8 | awk '{print $7; exit}')

# Instalar Jellyfin si no está
if ! dpkg -s jellyfin &>/dev/null; then
  curl -fsSL https://repo.jellyfin.org/install-deb | bash -s -- --non-interactive
  apt update && apt install -y jellyfin
  systemctl enable jellyfin
  systemctl start jellyfin
  sleep 15
fi

log "[✅ Jellyfin instalado y activo en http://$IP_LOCAL:8096]"

# Si no existe la API, preguntar al usuario
if [ ! -s "$JELLYFIN_API_KEY_FILE" ]; then
  echo -e "\n🔑 Jellyfin requiere una API Key para refrescar la biblioteca automáticamente."
  echo "   Accede a: http://$IP_LOCAL:8096"
  echo "   Luego ve a: Panel de control → API Keys → Nueva clave"
  read -rp "¿Quieres introducir la API Key ahora? (s/n): " RESPUESTA
  if [[ "$RESPUESTA" =~ ^[sS]$ ]]; then
    read -rp "Introduce la API Key: " API_INPUT
    if [[ -n "$API_INPUT" ]]; then
      mkdir -p "$(dirname "$JELLYFIN_API_KEY_FILE")"
      echo "$API_INPUT" > "$JELLYFIN_API_KEY_FILE"
      log "[🔐 API Key guardada correctamente.]"
    else
      log "[⚠️ No se introdujo ninguna API. Saltando refresco automático por ahora.]"
    fi
  else
    log "[⏩ Saltando configuración del refresco automático por ahora.]"
  fi
fi

# Crear script de refresco si hay clave
if [ -s "$JELLYFIN_API_KEY_FILE" ]; then
  API_KEY=$(cat "$JELLYFIN_API_KEY_FILE")
  cat <<EOF > "$REFRESH_SCRIPT"
#!/bin/bash
LOG="/var/log/fitandsetup/jellyfin_refresh.log"
HOST="http://$IP_LOCAL:8096"
API_KEY="$API_KEY"

if ! systemctl is-active --quiet jellyfin; then
  echo "[\$(date)] Jellyfin no estaba activo. Iniciando..." >> "\$LOG"
  systemctl start jellyfin
  sleep 10
fi

curl -s -X POST "\$HOST/Library/Refresh" -H "X-Emby-Token: \$API_KEY" >> "\$LOG"
EOF

  chmod +x "$REFRESH_SCRIPT"
  
  # Añadir cron si no está
  if ! grep -q jellyfin_refresh /etc/crontab; then
    echo "*/15 * * * * root $REFRESH_SCRIPT" >> /etc/crontab
    log "[⏱️ Refresco automático de biblioteca cada 15 minutos activado.]"
  fi
fi
