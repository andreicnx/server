#!/bin/bash

set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

# FUNCIONES COMUNES
log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}

is_simulation=false
if [[ "$1" == "--simular" || "$1" == "--dry-run" ]]; then
  is_simulation=true
  log "Modo simulación activado. No se ejecutarán cambios."
fi

# BLOQUE 1: DETECCION Y MONTAJE DE /mnt/storage y /mnt/backup
log "Buscando discos SSD para montar como /mnt/storage y /mnt/backup..."

# Detectar los dos discos SSD de 1TB
ssds=( $(lsblk -dn -o NAME,SIZE | grep '931.5G' | awk '{print $1}') )
if [[ ${#ssds[@]} -ne 2 ]]; then
  log "ERROR: No se detectaron exactamente 2 SSD de 1TB. Abortando."
  exit 1
fi

mnt_storage="/mnt/storage"
mnt_backup="/mnt/backup"

mkdir -p "$mnt_storage" "$mnt_backup"

# Asignar el disco con última modificación más reciente como storage
get_latest_mount() {
  mountpoint=$1
  dev=$2
  mkdir -p "$mountpoint"
  mount "/dev/$dev" "$mountpoint"
  latest_file=$(find "$mountpoint" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2)
  umount "$mountpoint"
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
  # Detectar particiones en los discos
  part_storage=$(lsblk -ln /dev/$dev_storage | awk 'NR==2 {print $1}')
  part_backup=$(lsblk -ln /dev/$dev_backup | awk 'NR==2 {print $1}')

  mount "/dev/$part_storage" "$mnt_storage"
  mount "/dev/$part_backup" "$mnt_backup"

  echo "/dev/$part_storage $mnt_storage ext4 defaults 0 2" >> /etc/fstab
  echo "/dev/$part_backup $mnt_backup ext4 defaults 0 2" >> /etc/fstab
fi

log "Montaje de discos completado."

# BLOQUE 2: Sincronización automática con rsync y control de espacio
log "Configurando sincronización automática de /mnt/storage a /mnt/backup cada 3 horas..."

rsync_script="/usr/local/bin/sync_storage_backup.sh"
cat <<EOF > "$rsync_script"
#!/bin/bash

LOG_SYNC="/var/log/fitandsetup/rsync.log"

free_percent=\$(df -h /mnt/backup | awk 'NR==2 {print \$5}' | sed 's/%//')

if (( free_percent > 70 )); then
  echo "[\$(date +'%F %T')] Espacio bajo en /mnt/backup (\$free_percent%). Ejecutando rsync." | tee -a "\$LOG_SYNC"
  rsync -a --delete /mnt/storage/ /mnt/backup/ | tee -a "\$LOG_SYNC"
else
  echo "[\$(date +'%F %T')] Espacio suficiente en /mnt/backup (\$free_percent%). Saltando rsync." | tee -a "\$LOG_SYNC"
fi
EOF

chmod +x "$rsync_script"

if ! $is_simulation; then
  echo "0 */3 * * * root $rsync_script" > /etc/cron.d/sync_storage_backup
fi

log "Sincronización programada con éxito."

# BLOQUE 3: Preparación del disco Samsung e instalación de Home Assistant OS
log "Preparando disco dedicado para Home Assistant..."

samsung_disk=$(lsblk -dn -o NAME,SIZE,MODEL | grep -i samsung | awk '{print $1}')
if [[ -z "$samsung_disk" ]]; then
  log "ERROR: No se encontró el disco Samsung. Abortando."
  exit 1
fi

haos_dir="/mnt/homeassistant"
mkdir -p "$haos_dir"

if ! $is_simulation; then
  log "Formateando /dev/$samsung_disk como ext4..."
  umount "/dev/$samsung_disk" || true
  mkfs.ext4 -F "/dev/$samsung_disk"
  mount "/dev/$samsung_disk" "$haos_dir"
fi

log "Descargando imagen de Home Assistant OS (KVM)..."

haos_img_url="https://github.com/home-assistant/operating-system/releases/latest/download/haos_ova-10.5.qcow2.xz"
haos_img_local="/tmp/haos.qcow2.xz"

if ! $is_simulation; then
  curl -L "$haos_img_url" -o "$haos_img_local"
  unxz "$haos_img_local"
  mv /tmp/haos.qcow2 "$haos_dir/haos.qcow2"

  log "Creando VM para Home Assistant..."
  virt-install --name home-assistant \
    --memory 2048 --vcpus 2 \
    --disk path="$haos_dir/haos.qcow2",format=qcow2 \
    --os-variant generic \
    --import --network network=default \
    --noautoconsole
fi

log "Home Assistant instalado y ejecutándose como VM."

# BLOQUE 4: Configuración de Time Machine vía Samba
log "Instalando Samba y configurando soporte para Time Machine..."

if ! $is_simulation; then
  apt update && apt install -y samba
fi

smb_conf="/etc/samba/smb.conf"
backup_share="[TimeMachine]"
backup_path="$mnt_storage/timemachine"

# NO crear carpeta si ya existe
if [[ ! -d "$backup_path" ]]; then
  mkdir -p "$backup_path"
fi

if ! grep -q "$backup_share" "$smb_conf"; then
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
fi

if ! $is_simulation; then
  systemctl restart smbd
fi

log "Time Machine compartido como 'andrei-ubuntu.local' y activo."

# BLOQUE 5: Snapshots automáticos y limpieza inteligente
log "Configurando Snapper para snapshots automáticos del sistema..."

if ! $is_simulation; then
  apt install -y snapper
  snapper -c root create-config /
  sed -i 's/^ALLOW_USERS=.*/ALLOW_USERS="root"/' /etc/snapper/configs/root

  cron_job="/etc/cron.d/snapshots_auto"
  echo "0 */6 * * * root snapper create -c root -d 'Snapshot cada 6h'" > "$cron_job"
  echo "30 */12 * * * root snapper create -c root -d 'Snapshot cada 12h'" >> "$cron_job"
  echo "15 3 * * * root snapper create -c root -d 'Snapshot diario'" >> "$cron_job"
  echo "45 4 */3 * * root snapper create -c root -d 'Snapshot cada 72h'" >> "$cron_job"

  # Limpieza si espacio crítico
  cat <<CLEAN > /usr/local/bin/snapper_cleanup_if_low_space.sh
#!/bin/bash
usage=\$(df / | awk 'NR==2 {print \$5}' | sed 's/%//')
if (( usage > 70 )); then
  echo "[\$(date)] Espacio bajo en /. Limpiando snapshots antiguos." >> /var/log/fitandsetup/snapper_cleanup.log
  snapper -c root cleanup number
  touch /mnt/storage/snapshot_cleanup_alert.txt
fi
CLEAN

  chmod +x /usr/local/bin/snapper_cleanup_if_low_space.sh
  echo "0 */4 * * * root /usr/local/bin/snapper_cleanup_if_low_space.sh" >> "$cron_job"
fi

log "Snapper configurado con snapshots automáticos y limpieza inteligente."
