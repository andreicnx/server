#!/bin/bash

# BLOQUE 0 — Auto-descarga y reejecución desde copia local

LOCAL_SCRIPT="/usr/local/bin/fitandsetup.sh"

if [[ "$(realpath "$0")" != "$LOCAL_SCRIPT" ]]; then
  echo "[🧩 Descargando copia local del script para futuras ejecuciones...]"
  curl -fsSL https://raw.githubusercontent.com/andreicnx/server/main/server.sh -o "$LOCAL_SCRIPT"
  chmod +x "$LOCAL_SCRIPT"
  echo "[⏩ Ejecutando desde copia local. Este bloque ya no se volverá a ejecutar.]"
  exec sudo "$LOCAL_SCRIPT" "$@"
  exit 0
fi

# A partir de aquí empieza el resto del script normal (bloques 1 en adelante)
log "[🎞️ Instalando y configurando Jellyfin como servidor DLNA local...]"

JELLYFIN_LOG="/var/log/fitandsetup/jellyfin.log"
mkdir -p "$(dirname "$JELLYFIN_LOG")"

IP_LOCAL=$(ip -4 route get 8.8.8.8 | grep -oP 'src \K[\d.]+')
JELLYFIN_API_KEY_FILE="/etc/jellyfin/api_key"
REFRESH_SCRIPT="/usr/local/bin/jellyfin_refresh.sh"

# Instalar Jellyfin si no está
if ! dpkg -s jellyfin &>/dev/null; then
  curl -fsSL https://repo.jellyfin.org/install-deb | bash -s -- --non-interactive
  apt update && apt install -y jellyfin
  systemctl enable jellyfin
  systemctl start jellyfin
  sleep 15
fi

log "[✅ Jellyfin instalado y activo en http://$IP_LOCAL:8096]"

# Si no hay clave guardada, solicitarla
if [[ ! -s "$JELLYFIN_API_KEY_FILE" ]]; then
  echo ""
  echo "🔑 Jellyfin requiere una API Key para refrescar la biblioteca automáticamente."
  echo "   Accede a: http://$IP_LOCAL:8096"
  echo "   Luego ve a: Panel de control → API Keys → Nueva clave"
  read -rp "Introduce la API Key ahora (o deja vacío para saltar): " API_INPUT

  if [[ -n "$API_INPUT" ]]; then
    echo "$API_INPUT" > "$JELLYFIN_API_KEY_FILE"
    log "[🔐 API Key guardada.]"
  else
    log "[⏩ Saltando configuración del refresco automático por ahora.]"
    exit 0
  fi
fi

# Crear script de refresco si se dispone de API
if [[ -s "$JELLYFIN_API_KEY_FILE" ]]; then
  API_KEY=$(< "$JELLYFIN_API_KEY_FILE")
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

  if ! grep -q jellyfin_refresh /etc/crontab; then
    echo "*/15 * * * * root $REFRESH_SCRIPT" >> /etc/crontab
    log "[⏱️ Refresco automático de biblioteca cada 15 minutos activado.]"
  fi
fi
