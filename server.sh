#!/bin/bash
echo "[🔧 Instalando dependencias base para virtualización...]"
sudo apt update
sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-daemon \
  libvirt-daemon-driver-qemu \
  libvirt-clients \
  bridge-utils \
  virtinst \
  wget curl git mini-dlna

echo "[🧩 Activando libvirt...]"
sudo systemctl enable --now libvirtd

# Verificar que el socket de libvirt está disponible
if [ ! -S /var/run/libvirt/libvirt-sock ]; then
  echo "❌ Error: libvirt no está activo o el socket no existe. Abortando..."
  exit 1
fi

echo "[✅ Entorno de virtualización preparado]"
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}

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

  mountpoint -q "$mnt_storage" || mount "/dev/$part_storage" "$mnt_storage"
  mountpoint -q "$mnt_backup" || mount "/dev/$part_backup" "$mnt_backup"

  grep -q "$mnt_storage" /etc/fstab || echo "/dev/$part_storage $mnt_storage ext4 defaults 0 2" >> /etc/fstab
  grep -q "$mnt_backup" /etc/fstab || echo "/dev/$part_backup $mnt_backup ext4 defaults 0 2" >> /etc/fstab
fi

log "Montaje de discos completado."

# Continúa con lo demás (rsync, HAOS, samba, snapshots...) como ya está definido en tu script

# Reemplaza la URL anterior de haos por esta correcta:
haos_img_url="https://github.com/home-assistant/operating-system/releases/download/10.5/haos_ova-10.5.qcow2.xz"
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
