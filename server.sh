#!/bin/bash

# BLOQUE 0.0
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}
# BLOQUE — Instalación y configuración de Jellyfin con DLNA y refresco automático opcional
log "[🎞️ Instalando y configurando Jellyfin como servidor DLNA local...]"

# 1. Instalar Jellyfin si no está
if ! dpkg -s jellyfin &>/dev/null; then
  curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash -s -- -y
fi

# 2. Verificar servicio activo
if systemctl is-active --quiet jellyfin; then
  JELLYFIN_IP=$(hostname -I | awk '{print $1}')
  log "[✅ Jellyfin instalado y activo en http://$JELLYFIN_IP:8096]"
else
  log "[❌ Jellyfin no está activo tras la instalación. Revisa el estado con: systemctl status jellyfin]"
  exit 1
fi

# 3. Confirmar configuración inicial y generación de API
echo -e "\n🔑 Para habilitar el refresco automático, necesitas crear una API Key en:
→ http://$JELLYFIN_IP:8096
Finaliza la configuración inicial, luego ve a: Panel de control → API Keys → Nueva clave\n"

CONFIG_FILE="/etc/fitandsetup/jellyfin_api_key.conf"
mkdir -p /etc/fitandsetup

if [[ ! -f "$CONFIG_FILE" || -z $(cat "$CONFIG_FILE") ]]; then
  sudo -u "$SUDO_USER" bash -c '
    read -rp "¿Quieres introducir la API Key ahora? (s/n): " respuesta
    if [[ "$respuesta" == "s" || "$respuesta" == "S" ]]; then
      read -rp "Introduce tu API Key: " clave
      echo "$clave" > "$CONFIG_FILE"
      echo "[✅ API Key guardada en $CONFIG_FILE]"
    else
      echo "[⏩ Saltando refresco automático de biblioteca por ahora.]"
    fi
  '
else
  echo "[⏩ API Key ya guardada previamente. Usando archivo existente.]"
fi

# 4. Crear script de refresco automático si API está disponible
API_KEY=$(cat "$CONFIG_FILE" 2>/dev/null)
REFRESH_SCRIPT="/usr/local/bin/jellyfin_refresh.sh"
JELLYFIN_LOG="/var/log/fitandsetup/jellyfin_refresh.log"

if [[ -n "$API_KEY" ]]; then
  cat <<EOF > "$REFRESH_SCRIPT"
#!/bin/bash
HOST="http://$JELLYFIN_IP:8096"

if ! systemctl is-active --quiet jellyfin; then
  echo "[\$(date)] Jellyfin no estaba activo. Iniciando..." >> "$JELLYFIN_LOG"
  systemctl start jellyfin
  sleep 10
fi

curl -s -X POST "\$HOST/Library/Refresh" -H "X-Emby-Token: \$API_KEY" >> "$JELLYFIN_LOG"
EOF

  chmod +x "$REFRESH_SCRIPT"
  # Añadir cron si no existe
  if ! grep -q jellyfin_refresh /etc/crontab; then
    echo "*/15 * * * * root $REFRESH_SCRIPT" >> /etc/crontab
  fi
  echo "[✅ Refresco automático de biblioteca configurado cada 15 min.]"
fi
