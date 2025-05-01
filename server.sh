#!/bin/bash

# BLOQUE 0
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}

# BLOQUE 1 — Configuración inteligente de DuckDNS
DUCKDNS_DOMAIN="sumadre"
DUCKDNS_TOKEN="9947bc93-3b12-427f-8eaf-24d8dbd85b04"
UPDATE_SCRIPT="/opt/duckdns/update.sh"

check_duckdns_active() {
  systemctl is-enabled --quiet duckdns.timer && systemctl is-active --quiet duckdns.timer
}

check_duckdns_token_match() {
  grep -q "$DUCKDNS_TOKEN" "$UPDATE_SCRIPT" 2>/dev/null
}

if check_duckdns_active; then
  if check_duckdns_token_match; then
    echo "[⏩ DuckDNS ya está activo y configurado correctamente. Saltando.]"
  else
    echo "[⚠️ DuckDNS activo pero el token no coincide con el configurado en el script.]"
    echo "¿Deseas actualizar la configuración de DuckDNS? [S/n]"
    read -r resp
    resp=${resp,,}
    if [[ "$resp" =~ ^(n|no)$ ]]; then
      echo "⏭️  DuckDNS no modificado."
    else
      systemctl disable --now duckdns.timer
      rm -f "$UPDATE_SCRIPT"
      rm -f /etc/systemd/system/duckdns.{service,timer}
      systemctl daemon-reload
    fi
  fi
fi

# Solo si no está activo o se borró el anterior
if ! check_duckdns_active || ! check_duckdns_token_match; then
  echo "[🌐 Instalando cliente DuckDNS con systemd...]"

  sudo mkdir -p /opt/duckdns
  cat <<EOF | sudo tee "$UPDATE_SCRIPT" > /dev/null
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" | curl -k -o /opt/duckdns/duck.log -K -
EOF
  sudo chmod +x "$UPDATE_SCRIPT"

  # Servicio systemd
  cat <<EOF | sudo tee /etc/systemd/system/duckdns.service > /dev/null
[Unit]
Description=DuckDNS Updater

[Service]
Type=oneshot
ExecStart=$UPDATE_SCRIPT
EOF

  # Timer systemd
  cat <<EOF | sudo tee /etc/systemd/system/duckdns.timer > /dev/null
[Unit]
Description=Actualizar IP de DuckDNS cada 30 minutos

[Timer]
OnBootSec=30sec
OnUnitActiveSec=30min
Unit=duckdns.service

[Install]
WantedBy=timers.target
EOF

  sudo systemctl daemon-reexec
  sudo systemctl daemon-reload
  sudo systemctl enable --now duckdns.timer

  echo "[✅ DuckDNS configurado y activo]"
fi

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

log "[✅ Entorno de virtualización y DLNA preparados]"

# BLOQUE 3 — Montaje de discos SSD /mnt/storage y /mnt/backup con autodetección

is_simulation=false
if [[ "$1" == "--simular" || "$1" == "--dry-run" ]]; then
  is_simulation=true
  log "Modo simulación activado. No se ejecutarán cambios."
fi

log "Buscando discos SSD para montar como /mnt/storage y /mnt/backup..."

ssds=( $(lsblk -dn -o NAME,SIZE | grep '931.5G' | awk '{print $1}') )
if [[ ${#ssds[@]} -ne 2 ]]; then
  log "ERROR: No se detectaron exactamente 2 SSD de 1TB. Abortando."
  exit 1
fi

mnt_storage="/mnt/storage"
mnt_backup="/mnt/backup"
mkdir -p "$mnt_storage" "$mnt_backup"

# Si ya están montados correctamente, omitir el bloque
if mountpoint -q "$mnt_storage" && mountpoint -q "$mnt_backup"; then
  log "[⏩ SSDs ya están montados en $mnt_storage y $mnt_backup. Saltando.]"
else
  get_latest_mount() {
    mountpoint=$1
    dev=$2
    mkdir -p "$mountpoint"
    mount "/dev/$dev" "$mountpoint" 2>/dev/null || true
    latest_file=$(find "$mountpoint" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2)
    umount "$mountpoint" 2>/dev/null || true
    echo "$latest_file"
  }

  latest1=$(get_latest_mount "/mnt/tmp1" "${ssds[0]}")
  latest2=$(get_latest_mount "/mnt/tmp2" "${ssds[1]}")

  if [[ "$latest1" > "$latest2" ]]; then
    dev_storage="${ssds[0]}"
    dev_backup="${ssds[1]}"
  else
    dev_storage="${ssds[1]}"
    dev_backup="${ssds[0]}"
  fi

  log "Asignando /dev/$dev_storage a /mnt/storage"
  log "Asignando /dev/$dev_backup a /mnt/backup"

  if ! $is_simulation; then
    part_storage=$(lsblk -ln /dev/$dev_storage | awk 'NR==2 {print $1}')
    part_backup=$(lsblk -ln /dev/$dev_backup | awk 'NR==2 {print $1}')

    mount "/dev/$part_storage" "$mnt_storage" || log "⚠️ Fallo al montar $part_storage"
    mount "/dev/$part_backup" "$mnt_backup" || log "⚠️ Fallo al montar $part_backup"

    grep -q "$mnt_storage" /etc/fstab || echo "/dev/$part_storage $mnt_storage ext4 defaults 0 2" >> /etc/fstab
    grep -q "$mnt_backup" /etc/fstab || echo "/dev/$part_backup $mnt_backup ext4 defaults 0 2" >> /etc/fstab
  fi

  log "Montaje de discos completado."
fi

# BLOQUE 4 — Sincronización automática de /mnt/storage a /mnt/backup

log "Configurando sincronización automática de /mnt/storage a /mnt/backup..."

BACKUP_LOG="/var/log/fitandsetup/backup_sync.log"
mkdir -p "$(dirname "$BACKUP_LOG")"

# Script de sincronización con exclusiones
cat <<'EOF' > /usr/local/bin/sync_storage_to_backup.sh
#!/bin/bash
SRC="/mnt/storage"
DST="/mnt/backup"
LOG="/var/log/fitandsetup/backup_sync.log"

if mountpoint -q "$SRC" && mountpoint -q "$DST"; then
  echo "[🔄 \$(date)] Iniciando sincronización..." >> "\$LOG"
  rsync -aAXHv --delete --exclude="rsnapshot/" "\$SRC/" "\$DST/" >> "\$LOG" 2>&1
  echo "[✅ \$(date)] Sincronización completada." >> "\$LOG"
  echo "Última sincronización correcta: \$(date)" > "\$DST/.ultima_sync.txt"
else
  echo "[⚠️ \$(date)] Uno de los discos no está montado. Sincronización cancelada." >> "\$LOG"
fi
EOF

chmod +x /usr/local/bin/sync_storage_to_backup.sh

# Crear cron si no existe
cron_file="/etc/cron.d/storage_backup_sync"
if ! grep -q "sync_storage_to_backup.sh" "$cron_file" 2>/dev/null; then
  echo "0 * * * * root /usr/local/bin/sync_storage_to_backup.sh" > "$cron_file"
fi

log "Sincronización activa cada hora y ejecutable manualmente con:"
log "sudo /usr/local/bin/sync_storage_to_backup.sh"

# BLOQUE 4.5 Configuración segura del bridge de red br0.

echo -e "\n==> BLOQUE 4.5 — Configuración segura del bridge de red br0..."
BRIDGE_LOG="/var/log/fitandsetup/bridge.log"
mkdir -p "$(dirname "$BRIDGE_LOG")"

log_bridge() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$BRIDGE_LOG"
}

INTERFAZ=$(ip route | grep default | awk '{print $5}')
NETPLAN_FILE=$(find /etc/netplan -type f -name "*.yaml" | head -n 1)
BACKUP_FILE="${NETPLAN_FILE}.backup-before-bridge"

if grep -q "br0" "$NETPLAN_FILE"; then
    log_bridge "⏩ El bridge br0 ya está configurado en $NETPLAN_FILE. Saltando."
else
    log_bridge "🧩 Creando configuración de red con bridge br0 usando $INTERFAZ..."

    cp "$NETPLAN_FILE" "$BACKUP_FILE"
    log_bridge "💾 Copia de seguridad creada: $BACKUP_FILE"

    cat <<EOF > "$NETPLAN_FILE"
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFAZ:
      dhcp4: no
  bridges:
    br0:
      interfaces: [$INTERFAZ]
      dhcp4: true
      parameters:
        stp: false
        forward-delay: 0
EOF

    if netplan apply 2>/tmp/netplan_error.log; then
        log_bridge "✅ Bridge br0 aplicado correctamente."
    else
        log_bridge "❌ Error al aplicar Netplan. Restaurando configuración anterior..."
        mv "$BACKUP_FILE" "$NETPLAN_FILE"
        netplan apply
        log_bridge "⚠️ Error de Netplan:"
        cat /tmp/netplan_error.log | tee -a "$BRIDGE_LOG"
        log_bridge "✅ Configuración original restaurada."
    fi
fi

# BLOQUE 4.6— Detección automática de br0 como interfaz para la VM de Home Assistant
echo -e "\n==> BLOQUE 4.6 — Selección automática de interfaz de red para la VM..."

VM_NET_IFACE="br0"
if ! ip link show br0 &>/dev/null; then
    echo "[⚠️] El bridge br0 no está disponible. Usando interfaz física predeterminada."
    VM_NET_IFACE=$(ip route | grep default | awk '{print $5}')
    echo "[ℹ️] Usando interfaz $VM_NET_IFACE para la VM."
else
    echo "[✅] Bridge br0 detectado. Será usado como interfaz de red para la VM."
fi

# BLOQUE 5 — Creación limpia de la VM Home Assistant con log aislado
log "[🔁 Reinstalando la máquina virtual de Home Assistant...]"

HA_LOG="/var/log/fitandsetup/ha_vm.log"
HA_DIR="/mnt/storage/haos_vm"
HA_DISK="$HA_DIR/haos.qcow2"
HA_VM="home-assistant"

# Eliminar VM y disco si existen
if virsh list --all | grep -q "$HA_VM"; then
  log "[🧨 Eliminando VM existente y su disco...]"
  virsh destroy "$HA_VM" &>/dev/null || true
  virsh undefine "$HA_VM" --nvram &>/dev/null || true
fi

mkdir -p "$HA_DIR"

log "[⬇️ Buscando la última imagen de HAOS en formato .qcow2.xz...]"
HA_URL=$(curl -s https://api.github.com/repos/home-assistant/operating-system/releases/latest \
  | grep "haos_ova-.*\.qcow2\.xz" \
  | grep "browser_download_url" \
  | cut -d '"' -f 4)

log "[⬇️ Descargando imagen desde: $HA_URL]"
curl -L -o "$HA_DISK.xz" "$HA_URL"

log "[📦 Eliminando archivo anterior descomprimido (si existe)...]"
rm -f "$HA_DISK"

log "[📦 Descomprimiendo imagen...]"
xz -d "$HA_DISK.xz"

log "[⚙️ Creando VM con libvirt...]"
virt-install \
  --name "$HA_VM" \
  --memory 2048 \
  --vcpus 2 \
  --disk path="$HA_DISK",format=qcow2 \
  --import \
  --os-variant generic \
  --network bridge=br0 \
  --noautoconsole \
  --quiet >> "$HA_LOG" 2>&1 &

log "[⏳ VM de Home Assistant en proceso de creación en segundo plano...]"

# BLOQUE 6 — config time machine y samba
echo -e "\n==> BLOQUE 6 — Configuración de Time Machine vía Samba con autodetección..."
TM_LOG="/var/log/fitandsetup/timemachine.log"
mkdir -p "$(dirname "$TM_LOG")"

log_tm() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$TM_LOG"
}

log_tm "Configurando soporte para Time Machine..."

backup_share="[TimeMachine]"
backup_path="/mnt/storage/timemachine"
smb_conf="/etc/samba/smb.conf"
samba_needs_restart=false

# Instalar samba si no está
if ! dpkg -s samba &>/dev/null; then
  log_tm "[📦 Instalando Samba...]"
  apt update && apt install -y samba
  samba_needs_restart=true
fi

# Crear carpeta de respaldo si no existe
if [[ ! -d "$backup_path" ]]; then
  mkdir -p "$backup_path"
  log_tm "📁 Carpeta '$backup_path' creada."
fi

# Añadir bloque a smb.conf si no existe
if ! grep -qF "$backup_share" "$smb_conf"; then
  cat <<EOL >> "$smb_conf"

$backup_share
   path = $backup_path
   browseable = yes
   read only = no
   guest ok = yes
   fruit:aapl = yes
   fruit:time machine = yes
   spotlight = no
EOL
  log_tm "📝 Bloque '$backup_share' añadido a smb.conf."
  samba_needs_restart=true
else
  log_tm "⏩ El bloque '$backup_share' ya existe en smb.conf. Saltando."
fi

# Reiniciar Samba solo si hubo cambios
if $samba_needs_restart; then
  log_tm "[🔄 Reiniciando Samba...]"
  systemctl restart smbd
fi

log_tm "✅ Time Machine compartido como '$(hostname).local' y activo."

# BLOQUE 7 — Snapshots automáticos con rsnapshot (con autodetección)

log "Configurando rsnapshot para backups del sistema..."

SNAPSHOT_ROOT="/mnt/storage/rsnapshot"
SOURCE="/"
RS_CONF="/etc/rsnapshot.conf"
RS_CLEANUP="/usr/local/bin/rsnapshot_cleanup_if_low_space.sh"
RS_LOG="/var/log/fitandsetup/rsnapshot_cleanup.log"

if ! dpkg -s rsnapshot &>/dev/null; then
  log "[📦 Instalando rsnapshot...]"
  apt install -y rsnapshot
fi

# Hacer copia si aún no se ha modificado antes
if ! grep -q "$SNAPSHOT_ROOT" "$RS_CONF"; then
  log "[🛠️ Configurando rsnapshot por primera vez...]"

  cp "$RS_CONF" "${RS_CONF}.bak"

  sed -i "s|^snapshot_root.*|snapshot_root   $SNAPSHOT_ROOT/|" "$RS_CONF"
  sed -i 's/^#cmd_cp/cmd_cp/' "$RS_CONF"
  sed -i 's/^#cmd_rm/cmd_rm/' "$RS_CONF"
  sed -i 's/^#cmd_rsync/cmd_rsync/' "$RS_CONF"

  sed -i '/^interval /d' "$RS_CONF"
  printf "interval\t6h\t7\n" >> "$RS_CONF"
  printf "interval\t12h\t7\n" >> "$RS_CONF"
  printf "interval\tdaily\t7\n" >> "$RS_CONF"
  printf "interval\t72h\t4\n" >> "$RS_CONF"

  if ! grep -q -E "backup\s+/\s+" "$RS_CONF"; then
   printf "backup\t$SOURCE\tlocalhost/\n" >> "$RS_CONF"
  fi

  mkdir -p "$SNAPSHOT_ROOT"

  rsnapshot configtest || {
    echo "❌ Error en configuración de rsnapshot"
    exit 1
  }
else
  log "[⏩ Configuración de rsnapshot ya aplicada. Saltando.]"
fi

# Añadir cronjobs si no existen
if ! crontab -l 2>/dev/null | grep -q "rsnapshot"; then
  log "[⏱️ Añadiendo tareas programadas para snapshots...]"
  (crontab -l 2>/dev/null; echo "0 */6 * * * /usr/bin/rsnapshot 6h"; echo "0 */12 * * * /usr/bin/rsnapshot 12h"; echo "0 3 * * * /usr/bin/rsnapshot daily"; echo "0 */72 * * * /usr/bin/rsnapshot 72h") | crontab -
else
  log "[⏩ Cronjobs para rsnapshot ya existen. Saltando.]"
fi

# Crear script de limpieza si no existe
if [ ! -f "$RS_CLEANUP" ]; then
  log "[🧹 Creando limpieza automática si hay poco espacio...]"

  cat <<CLEAN | tee "$RS_CLEANUP" > /dev/null
#!/bin/bash
LOG="$RS_LOG"
SNAPSHOT_ROOT="$SNAPSHOT_ROOT"
usage=\$(df "\$SNAPSHOT_ROOT" | awk 'NR==2 {print \$5}' | sed 's/%//')

if (( usage > 80 )); then
    echo "[\$(date)] Espacio en \$SNAPSHOT_ROOT es \$usage%. Limpiando snapshots antiguos..." >> "\$LOG"
    for interval in 6h 12h daily 72h; do
        oldest=\$(ls -1dt "\$SNAPSHOT_ROOT"/\$interval.* 2>/dev/null | tail -n 1)
        if [ -d "\$oldest" ]; then
            rm -rf "\$oldest"
            echo "[\$(date)] Eliminado: \$oldest" >> "\$LOG"
        fi
    done
    touch "\$SNAPSHOT_ROOT/rsnapshot_cleanup_alert.txt"
fi
CLEAN

  chmod +x "$RS_CLEANUP"
  echo "0 */4 * * * root $RS_CLEANUP" | tee /etc/cron.d/rsnapshot_cleanup > /dev/null
fi

log "rsnapshot configurado con backups automáticos y limpieza inteligente."

# BLOQUE 8 — VPN local con WireGuard
echo -e "\n==> BLOQUE 8 — VPN local con WireGuard (hasta 10 clientes)..."
WG_LOG="/var/log/fitandsetup/wireguard.log"
mkdir -p "$(dirname "$WG_LOG")"

log_wg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$WG_LOG"
}

log_wg "[🔐 Configurando VPN local con WireGuard (10 clientes)...]"

if ! $is_simulation; then
  if [[ -f /etc/wireguard/wg0.conf ]]; then
    log_wg "[⏩ WireGuard ya está configurado. Saltando.]"
  else
    apt install -y wireguard qrencode

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

# BLOQUE 9 — Backup automático de Home Assistant
echo -e "\n==> BLOQUE 9 — Backup automático de Home Assistant..."
HA_LOG="/var/log/fitandsetup/ha_vm_backup.log"
mkdir -p "$(dirname "$HA_LOG")"

log "[📦 Configurando backups automáticos de Home Assistant...]"

BACKUP_DIR="/mnt/storage/homeassistant_backups"
VM_NAME="home-assistant"
MAX_BACKUPS=5
CRON_JOB="/etc/cron.d/ha_vm_backup"

if [[ -f "$CRON_JOB" && -d "$BACKUP_DIR" ]]; then
  log "[⏩ Backup de Home Assistant ya configurado. Saltando.]"
else
  if ! $is_simulation; then
    mkdir -p "$BACKUP_DIR"

    cat <<'EOSCRIPT' > /usr/local/bin/ha_vm_backup.sh
#!/bin/bash
set -e

VM_NAME="home-assistant"
BACKUP_DIR="/mnt/storage/homeassistant_backups"
TMP_DIR="/tmp/ha_backup"
MAX_BACKUPS=5
VM_DISK="/mnt/storage/haos_vm/haos.qcow2"
LOG="/var/log/fitandsetup/ha_vm_backup.log"

timestamp=$(date +"%Y%m%d-%H%M%S")
backup_name="backup_${timestamp}.tar"

# Apagar la VM si está encendida
if virsh domstate "$VM_NAME" | grep -q running; then
  virsh shutdown "$VM_NAME"
  sleep 10
fi

mkdir -p "$TMP_DIR"
virt-copy-out -a "$VM_DISK" /data/backup "$TMP_DIR"

if [[ -d "$TMP_DIR/backup" ]]; then
  tar -cf "$BACKUP_DIR/$backup_name" -C "$TMP_DIR/backup" .
  echo "[$(date)] Backup creado: $backup_name" >> "$LOG"
fi

cd "$BACKUP_DIR"
ls -1tr backup_*.tar | head -n -$MAX_BACKUPS | xargs -r rm -f

virsh start "$VM_NAME" &>/dev/null || true

rm -rf "$TMP_DIR"

EOSCRIPT

    chmod +x /usr/local/bin/ha_vm_backup.sh
    echo "0 3 * * * root /usr/local/bin/ha_vm_backup.sh" > "$CRON_JOB"

    log "[✅ Backup automático configurado. Se ejecutará cada noche a las 03:00.]"
  else
    log "[🔎 Simulación: no se configuró el backup de Home Assistant.]"
  fi
fi
# BLOQUE 10 — Comprobación visual del sistema tras la instalación
echo -e "\n==> BLOQUE 10 — Comprobación visual del sistema tras la instalación..."
log "[🔍 Comprobación final del sistema...]"

CHECK_SCRIPT="/usr/local/bin/server_check.sh"
CHECK_CRON="/etc/cron.d/server_check"
CHECK_LOG="/var/log/fitandsetup/server_check.log"

if [[ -f "$CHECK_SCRIPT" && -f "$CHECK_CRON" ]]; then
  log "[⏩ Script de verificación ya presente. Saltando.]"
else
  cat <<'EOF' > "$CHECK_SCRIPT"
#!/bin/bash
LOG="/var/log/fitandsetup/server_check.log"
timestamp="[🕒 $(date +'%Y-%m-%d %H:%M:%S')]"

{
  echo "$timestamp INICIO DE COMPROBACIÓN DEL SISTEMA"
  CHECKS_FAILED=0

  check() {
    desc="$1"
    shift
    if "$@" &>/dev/null; then
      echo "[✅] $desc"
    else
      echo "[⚠️ ] $desc — FALLÓ"
      ((CHECKS_FAILED++))
    fi
  }

  check "/mnt/storage montado" mountpoint -q /mnt/storage
  check "/mnt/backup montado" mountpoint -q /mnt/backup
  check "DuckDNS activo" systemctl is-active --quiet duckdns.timer
  check "VM Home Assistant creada" virsh list --all | grep -q home-assistant
  check "Disco HAOS existe" test -f /mnt/storage/haos_vm/haos.qcow2
  check "Carpeta timemachine" test -d /mnt/storage/timemachine
  check "Samba activo" systemctl is-active --quiet smbd
  check "Sync manual existe" test -x /usr/local/bin/sync_storage_to_backup.sh
  check "Última sync registrada" test -f /mnt/backup/.ultima_sync.txt
  check "Config rsnapshot" test -f /etc/rsnapshot.conf
  check "rsnapshot ejecuta" rsnapshot -t 6h
  check "Script limpieza existe" test -x /usr/local/bin/rsnapshot_cleanup_if_low_space.sh
  check "Archivo wg0.conf existe" test -f /etc/wireguard/wg0.conf
  check "Claves del servidor generadas" test -f /etc/wireguard/keys/server_private.key
  check "10 clientes configurados" bash -c 'ls /etc/wireguard/clients/cliente*.conf 2>/dev/null | wc -l | grep -q 10'
  check "Códigos QR generados" bash -c 'ls /mnt/storage/wireguard_backups/qrcodes/cliente*.png 2>/dev/null | wc -l | grep -q 10'
  check "Servicio wg-quick@wg0 activo" systemctl is-active --quiet wg-quick@wg0
  check "Carpeta de backups existe" test -d /mnt/storage/homeassistant_backups
  check "Script de backup existe" test -x /usr/local/bin/ha_vm_backup.sh
  check "Al menos 1 backup creado" bash -c 'ls /mnt/storage/homeassistant_backups/backup_*.tar 2>/dev/null | grep -q .'
  check "Log de backup existe" test -f /var/log/fitandsetup/ha_vm_backup.log

  if [[ $CHECKS_FAILED -eq 0 ]]; then
    echo "[✅ TODO OK] Verificación correcta."
  else
    echo "[⚠️ $CHECKS_FAILED fallos] Revisa manualmente."
  fi

  echo ""
} >> "$LOG"
EOF

  chmod +x "$CHECK_SCRIPT"
  echo "0 */6 * * * root $CHECK_SCRIPT" > "$CHECK_CRON"
  log "[✅ Script de verificación creado y programado cada 6h.]"
fi

# BLOQUE 11 — Servidor DLNA con MiniDLNA (ReadyMedia)

log "[📺 Instalando y configurando MiniDLNA...]"

MINIDLNA_CONF="/etc/minidlna.conf"
MINIDLNA_LOG="/var/log/fitandsetup/minidlna.log"
SHARE_PATH="/mnt/storage/X"

# Instalar minidlna si no está
if ! dpkg -s minidlna &>/dev/null; then
  apt update && apt install -y minidlna
fi

# Configurar minidlna
if ! grep -q "$SHARE_PATH" "$MINIDLNA_CONF"; then
  log "[🛠️ Aplicando configuración en $MINIDLNA_CONF...]"

  sed -i "s|^media_dir=.*||g" "$MINIDLNA_CONF"
  echo "media_dir=V,$SHARE_PATH" >> "$MINIDLNA_CONF"
  sed -i "s|^#\?inotify=.*|inotify=yes|" "$MINIDLNA_CONF"
  sed -i "s|^#\?friendly_name=.*|friendly_name=ServidorDLNA|" "$MINIDLNA_CONF"
  sed -i "s|^#\?log_dir=.*|log_dir=/var/log/minidlna|" "$MINIDLNA_CONF"
fi

# Crear log si no existe
mkdir -p /var/log/fitandsetup
mkdir -p /var/log/minidlna

# Reiniciar el servicio y forzar escaneo
systemctl restart minidlna
minidlnad -R

# Comprobar estado
if systemctl is-active --quiet minidlna; then
  log "[✅ MiniDLNA activo y compartiendo $SHARE_PATH]"
else
  log "[⚠️ MiniDLNA no se inició correctamente. Revisa $MINIDLNA_LOG]"
fi

# BLOQUE 12 — Servidor DLNA local con Jellyfin
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
