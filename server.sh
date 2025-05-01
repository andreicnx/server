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

# BLOQUE 5 — Creación limpia de la VM Home Assistant con log

log "[🏠 Instalando Home Assistant en máquina virtual limpia]"

haos_img_url="https://github.com/home-assistant/operating-system/releases/download/10.5/haos_ova-10.5.qcow2.xz"
haos_img_local="/tmp/haos.qcow2.xz"
haos_dir="/mnt/storage/haos_vm"
haos_disk="$haos_dir/haos.qcow2"
ha_log="/var/log/fitandsetup/ha_vm.log"

mkdir -p "$haos_dir" "$(dirname "$ha_log")"

if ! $is_simulation; then
  # Eliminar VM anterior si existe
  if virsh list --all | grep -q "home-assistant"; then
    log "[🧹 Eliminando VM anterior 'home-assistant']"
    virsh destroy home-assistant 2>/dev/null || true
    virsh undefine home-assistant --remove-all-storage 2>/dev/null || true
  fi

  # Eliminar disco previo
  [ -f "$haos_disk" ] && rm -f "$haos_disk"

  # Descargar e instalar nueva imagen
  log "[⬇️ Descargando imagen de Home Assistant OS...]"
  curl -L "$haos_img_url" -o "$haos_img_local"
  unxz "$haos_img_local"
  mv /tmp/haos.qcow2 "$haos_disk"

  log "[🚀 Creando nueva VM Home Assistant]"
  virt-install --name home-assistant \
    --memory 2048 --vcpus 2 \
    --disk path="$haos_disk",format=qcow2 \
    --os-variant generic \
    --import --network bridge=br0 \
    --noautoconsole \
    &> "$ha_log"

  log "[✅ Home Assistant instalado y ejecutándose como VM. Log: $ha_log]"
else
  log "[🔎 Simulación: se saltó la instalación de Home Assistant VM]"
fi

# BLOQUE 6 — Configuración de Time Machine vía Samba con autodetección

log "Configurando soporte para Time Machine..."

backup_share="[TimeMachine]"
backup_path="$mnt_storage/timemachine"
smb_conf="/etc/samba/smb.conf"
samba_needs_restart=false

# Instalar samba si no está
if ! dpkg -s samba &>/dev/null; then
  log "[📦 Instalando Samba...]"
  apt update && apt install -y samba
  samba_needs_restart=true
fi

# Crear carpeta de respaldo si no existe
if [[ ! -d "$backup_path" ]]; then
  mkdir -p "$backup_path"
fi

# Añadir bloque a smb.conf si no existe
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
  samba_needs_restart=true
fi

# Reiniciar Samba solo si hubo cambios
if $samba_needs_restart; then
  log "[🔄 Reiniciando Samba...]"
  systemctl restart smbd
fi

log "Time Machine compartido como '$(hostname).local' y activo."

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


# BLOQUE FINAL — Comprobación visual del sistema tras la instalación

log "[🔍 Comprobación final del sistema...]"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # Sin color

CHECKS_FAILED=0

check() {
  desc="$1"
  shift
  if "$@" &>/dev/null; then
    echo -e "${GREEN}[✅]${NC} $desc"
  else
    echo -e "${YELLOW}[⚠️ ]${NC} $desc — ${RED}Falló${NC}"
    ((CHECKS_FAILED++))
  fi
}

echo -e "\n${YELLOW}--------[ 🧮 SISTEMA MONTADO ]--------${NC}"
check "/mnt/storage montado" mountpoint -q /mnt/storage
check "/mnt/backup montado" mountpoint -q /mnt/backup

echo -e "\n${YELLOW}--------[ 🌐 DUCKDNS ]--------${NC}"
check "Archivo de actualización existe" test -f /opt/duckdns/update.sh
check "Timer duckdns activo" systemctl is-active --quiet duckdns.timer

echo -e "\n${YELLOW}--------[ 🏠 HOME ASSISTANT VM ]--------${NC}"
check "VM creada" virsh list --all | grep -q home-assistant
check "Archivo de disco existe" test -f /mnt/storage/haos_vm/haos.qcow2

echo -e "\n${YELLOW}--------[ 💾 TIME MACHINE ]--------${NC}"
check "Carpeta timemachine existe" test -d /mnt/storage/timemachine
check "Samba activo" systemctl is-active --quiet smbd

echo -e "\n${YELLOW}--------[ 🔁 SYNC STORAGE → BACKUP ]--------${NC}"
check "Script de sync existe" test -x /usr/local/bin/sync_storage_to_backup.sh
check "Archivo .ultima_sync.txt generado" test -f /mnt/backup/.ultima_sync.txt

echo -e "\n${YELLOW}--------[ 📸 SNAPSHOTS (rsnapshot) ]--------${NC}"
check "Archivo de configuración rsnapshot existe" test -f /etc/rsnapshot.conf
check "Snapshot 6h ejecuta correctamente" rsnapshot -t 6h
check "Script limpieza existe" test -x /usr/local/bin/rsnapshot_cleanup_if_low_space.sh

echo -e "\n${YELLOW}--------[ 📂 LOGS DISPONIBLES ]--------${NC}"
echo -e "${GREEN}  - /var/log/fitandsetup/general.log"
echo -e "  - /var/log/fitandsetup/ha_vm.log"
echo -e "  - /var/log/fitandsetup/backup_sync.log"
echo -e "  - /var/log/fitandsetup/rsnapshot_cleanup.log${NC}"

# Resumen
if [[ $CHECKS_FAILED -eq 0 ]]; then
  echo -e "\n${GREEN}[✅ TODO OK] Instalación y verificación completas.${NC}"
else
  echo -e "\n${YELLOW}[⚠️ $CHECKS_FAILED chequeos fallaron] Revisa arriba o en los logs para más detalle.${NC}"
fi
log "[🕒 Instalando verificación automática del sistema cada 6 horas...]"

cat <<'EOF' > /usr/local/bin/server_check.sh
#!/bin/bash
LOG="/var/log/fitandsetup/server_check.log"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

timestamp="[🕒 \$(date +'%Y-%m-%d %H:%M:%S')]"

{
  echo "\$timestamp INICIO DE COMPROBACIÓN DEL SISTEMA"
  CHECKS_FAILED=0

  check() {
    desc="\$1"
    shift
    if "\$@" &>/dev/null; then
      echo "[✅] \$desc"
    else
      echo "[⚠️ ] \$desc — FALLÓ"
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

  if [[ \$CHECKS_FAILED -eq 0 ]]; then
    echo "[✅ TODO OK] Verificación correcta."
  else
    echo "[⚠️ \$CHECKS_FAILED fallos] Revisa manualmente."
  fi

  echo ""
} >> "\$LOG"
EOF

chmod +x /usr/local/bin/server_check.sh

# Cron cada 6h
echo "0 */6 * * * root /usr/local/bin/server_check.sh" > /etc/cron.d/server_check
