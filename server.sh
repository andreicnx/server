#!/bin/bash

# BLOQUE 0.0
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}

# BLOQUE 0 — Autodescarga y relanzamiento desde copia local
if [[ "$1" != "--skip-download" ]]; then
  SCRIPT_PATH="/usr/local/bin/fitandsetup.sh"

  echo "[🧩 Descargando copia local del script para futuras ejecuciones...]"
  curl -fsSL https://raw.githubusercontent.com/andreicnx/server/main/server.sh -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"

  echo "[⏩ Ejecutando desde copia local. Este bloque ya no se volverá a ejecutar.]"
  exec sudo bash "$SCRIPT_PATH" --skip-download
  exit 0
fi


# 3. Instalar Jellyfin automáticamente sin confirmación
if ! dpkg -s jellyfin &>/dev/null; then
  curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash /dev/stdin -y
fi

# 4. Detectar IP real del servidor
SERVER_IP=$(ip -4 addr show br0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I | awk '{print $1}')
JELLYFIN_URL="http://$SERVER_IP:8096"

log "[✅ Jellyfin instalado y activo en $JELLYFIN_URL]"

# 5. Esperar a que arranque el servicio
sleep 10

# 6. Detectar si API ya está configurada
API_KEY_FILE="/etc/jellyfin/fitandapi.key"
API_KEY=""
if [[ -f "$API_KEY_FILE" ]]; then
  API_KEY=$(<"$API_KEY_FILE")
fi

# 7. Si no hay API, preguntar
if [[ -z "$API_KEY" ]]; then
  echo
  echo "🔑 Para habilitar el refresco automático, necesitas crear una API Key en:"
  echo "→ $JELLYFIN_URL"
  echo "Finaliza la configuración inicial, luego ve a: Panel de control → API Keys → Nueva clave"
  echo
  read -p "¿Quieres introducir la API Key ahora? (s/n): " want_key
  if [[ "$want_key" == "s" ]]; then
    read -p "Introduce la API Key de Jellyfin: " API_KEY
    echo "$API_KEY" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
    log "[✅ API Key guardada.]"
  else
    log "[⏩ Saltando refresco automático de biblioteca por ahora.]"
    return 0
  fi
fi

# 8. Añadir biblioteca automáticamente si no existe
JELLYFIN_LIBRARIES=$(curl -s -H "X-Emby-Token: $API_KEY" "$JELLYFIN_URL/Library/VirtualFolders")
if ! echo "$JELLYFIN_LIBRARIES" | grep -q "/mnt/storage/X"; then
  curl -s -X POST "$JELLYFIN_URL/Library/VirtualFolders" \
    -H "X-Emby-Token: $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"Name":"Videos","Locations":["/mnt/storage/X"]}' >/dev/null
  log "[✅ Biblioteca '/mnt/storage/X' añadida a Jellyfin.]"
else
  log "[⏩ Biblioteca ya existe. Saltando.]"
fi

# 9. Crear script de refresco automático
REFRESH_SCRIPT="/usr/local/bin/jellyfin_refresh.sh"
cat <<EOF > "$REFRESH_SCRIPT"
#!/bin/bash
API_KEY="$API_KEY"
HOST="$JELLYFIN_URL"
curl -s -X POST "\$HOST/Library/Refresh" -H "X-Emby-Token: \$API_KEY"
EOF

chmod +x "$REFRESH_SCRIPT"

# 10. Añadir a cron si no existe
if ! grep -q jellyfin_refresh /etc/crontab; then
  echo "*/15 * * * * root $REFRESH_SCRIPT" >> /etc/crontab
  log "[✅ Refresco automático programado cada 15 minutos.]"
fi
