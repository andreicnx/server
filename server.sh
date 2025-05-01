#!/bin/bash

# BLOQUE 0
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}


# BLOQUE 2 — Instalación de dependencias base con verificación

log "[🔧 Comprobando e instalando dependencias base para virtualización y servicios...]"

base_packages=(
  qemu-kvm libvirt-daemon-system libvirt-daemon libvirt-daemon-driver-qemu
  libvirt-clients bridge-utils virtinst wget curl git minidlna
)

missing=()
for pkg in "${base_packages[@]}"; do
  dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
done

if [ "${#missing[@]}" -eq 0 ]; then
  log "[⏩ Todos los paquetes base ya están instalados. Saltando.]"
else
  log "[📦 Instalando paquetes faltantes: ${missing[*]}]"
  apt update && apt install -y "${missing[@]}"
fi

log "[🧩 Activando libvirt...]"
systemctl enable --now libvirtd

if [ ! -S /var/run/libvirt/libvirt-sock ]; then
  echo "❌ Error: libvirt no está activo o el socket no existe. Abortando..."
  exit 1
fi





    mkdir -p /etc/wireguard/keys /etc/wireguard/clients
    chmod 700 /etc/wireguard
    chmod 600 /etc/wireguard/keys/* 2>/dev/null || true

    wg genkey | tee /etc/wireguard/keys/server_private.key | wg pubkey > /etc/wireguard/keys/server_public.key

    server_priv=$(< /etc/wireguard/keys/server_private.key)
    server_pub=$(< /etc/wireguard/keys/server_public.key)

    cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = $server_priv
SaveConfig = true
EOF

    mkdir -p /mnt/storage/wireguard_backups/qrcodes

    for i in {1..10}; do
      client="cliente$i"
      priv_key=$(wg genkey)
      pub_key=$(echo "$priv_key" | wg pubkey)
      ip="10.8.0.$((i+1))"

      echo "$priv_key" > /etc/wireguard/keys/${client}_private.key
      echo "$pub_key"  > /etc/wireguard/keys/${client}_public.key

      cat <<EOL >> /etc/wireguard/wg0.conf

[Peer]
PublicKey = $pub_key
AllowedIPs = $ip/32
EOL

      cat <<EOC > /etc/wireguard/clients/${client}.conf
[Interface]
PrivateKey = $priv_key
Address = $ip/24
DNS = 1.1.1.1

[Peer]
PublicKey = $server_pub
Endpoint = $(curl -s ifconfig.me):51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOC

      qrencode -o "/mnt/storage/wireguard_backups/qrcodes/${client}.png" < /etc/wireguard/clients/${client}.conf
    done

    sed -i 's/^#\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sysctl -p

    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0

    cp -r /etc/wireguard/* /mnt/storage/wireguard_backups/

    if command -v ufw &>/dev/null; then
      ufw allow 51820/udp
    fi

    log_wg "[✅ WireGuard configurado correctamente. Archivos y QR en /mnt/storage/wireguard_backups]"
  fi
else
  log_wg "[🔎 Simulación: configuración de WireGuard omitida.]"
fi



# BLOQUE 12 — nstalación y configuración de Jellyfin + DLNA local + Refresco automático

log "[🎞️ Instalando y configurando Jellyfin como servidor DLNA local...]"

JELLYFIN_API_FILE="/etc/jellyfin_api.key"
JELLYFIN_LOG="/var/log/fitandsetup/jellyfin.log"
REFRESH_SCRIPT="/usr/local/bin/jellyfin_refresh.sh"
VIDEO_PATH="/mnt/storage/X"

# Instalar Jellyfin si no está presente
if ! dpkg -s jellyfin &>/dev/null; then
  curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash -s -- -y <<< $'\n'
fi

# Esperar arranque y asegurar servicio
sleep 15
systemctl enable jellyfin
systemctl start jellyfin

# Detectar IP local real conectada al router principal
SERVER_IP=$(ip route get 1 | awk '{print $7; exit}')
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
  echo "Finaliza la configuración inicial, luego ve a: Panel de control → API Keys → Nueva clave"
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

# BLOQUE 13 — Actualización automática del sistema (semanal)
log "[🛠️ Programando actualizaciones automáticas del sistema cada semana...]"

AUTO_UPGRADE_SCRIPT="/usr/local/bin/system_weekly_upgrade.sh"
CRON_FILE="/etc/cron.d/system_weekly_upgrade"

cat <<'EOF' > "$AUTO_UPGRADE_SCRIPT"
#!/bin/bash
LOG="/var/log/fitandsetup/system_upgrade.log"
echo "[🔧 $(date)] Iniciando actualización semanal del sistema..." >> "$LOG"
apt update >> "$LOG" 2>&1
apt upgrade -y >> "$LOG" 2>&1
echo "[✅ $(date)] Actualización completada." >> "$LOG"
EOF

chmod +x "$AUTO_UPGRADE_SCRIPT"
echo "0 4 * * 1 root $AUTO_UPGRADE_SCRIPT" > "$CRON_FILE"
