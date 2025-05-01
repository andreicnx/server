
#!/bin/bash

# BLOQUE 0.0
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}

log "[🎞️ Instalando y configurando Jellyfin como servidor DLNA local...]"

JELLYFIN_LOG="/var/log/fitandsetup/jellyfin.log"
mkdir -p "$(dirname "$JELLYFIN_LOG")"

# Detectar IP real del servidor
IP_LOCAL=$(ip -4 route get 8.8.8.8 | grep -oP 'src \K[\d.]+')

# Instalar Jellyfin si no está
if ! dpkg -s jellyfin &>/dev/null; then
  curl -fsSL https://repo.jellyfin.org/install-deb | bash -s -- --non-interactive
  apt update && apt install -y jellyfin
  systemctl enable jellyfin
  systemctl start jellyfin
  sleep 15
fi

log "[✅ Jellyfin instalado y activo en http://$IP_LOCAL:8096]"

# Preguntar por API key o usar existente
JELLYFIN_API_KEY_FILE="/etc/jellyfin/api_key"
REFRESH_SCRIPT="/usr/local/bin/jellyfin_refresh.sh"

if [[ ! -f "$JELLYFIN_API_KEY_FILE" ]]; then
  echo ""
  echo "🔑 Jellyfin requiere una API Key para refrescar la biblioteca automáticamente."
  echo "   Accede a: http://$IP_LOCAL:8096"
  echo "   Luego ve a: Panel de control → API Keys → Nueva clave"
  read -p "Introduce la API Key ahora (o deja en blanco para saltar): " API_INPUT

  if [[ -n "$API_INPUT" ]]; then
    echo "$API_INPUT" > "$JELLYFIN_API_KEY_FILE"
    log "[🔐 API Key guardada.]"
  else
    log "[⏩ Saltando configuración del refresco automático por ahora.]"
  fi
fi

# Crear script para refrescar biblioteca si hay API
if [[ -s "$JELLYFIN_API_KEY_FILE" ]]; then
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

  # Añadir a crontab si no está
  if ! grep -q jellyfin_refresh /etc/crontab; then
    echo "*/15 * * * * root $REFRESH_SCRIPT" >> /etc/crontab
    log "[⏱️ Refresco automático de biblioteca cada 15 minutos activado.]"
  fi
fi


# BLOQUE FINAL — Autorreparación si no se pudo leer la API
JELLYFIN_API_KEY_FILE="/etc/jellyfin/api_key"
SCRIPT_PATH="/usr/local/bin/fitandsetup.sh"

if [[ ! -s "$JELLYFIN_API_KEY_FILE" && "$0" != "$SCRIPT_PATH" ]]; then
  echo "[🧩 Detected missing API Key and input not captured — preparing local rerun...]"
  curl -s -o "$SCRIPT_PATH" https://raw.githubusercontent.com/andreicnx/server/main/server.sh
  chmod +x "$SCRIPT_PATH"
  echo "[🔁 Reejecutando script correctamente desde: $SCRIPT_PATH]"
  sudo "$SCRIPT_PATH"
  exit 0
fi
