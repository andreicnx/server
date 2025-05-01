#!/bin/bash

# BLOQUE 0
set -e
LOG_DIR="/var/log/fitandsetup"
mkdir -p "$LOG_DIR"

log() {
  echo -e "[$(date +'%F %T')] $1" | tee -a "$LOG_DIR/general.log"
}


# BLOQUE 5 — Instalación limpia de Home Assistant en disco dedicado
log "[🔁 Reinstalando Home Assistant desde cero en disco exclusivo...]"

HA_DISK="/mnt/home/haos.qcow2"
HA_VM="home-assistant"
HA_LOG="/var/log/fitandsetup/ha_vm.log"

# Eliminar VM y disco previos si existen
if virsh list --all | grep -q "$HA_VM"; then
  log "[🧨 Eliminando VM existente...]"
  virsh destroy "$HA_VM" &>/dev/null || true
  virsh undefine "$HA_VM" --nvram &>/dev/null || true
fi

if [[ -f "$HA_DISK" ]]; then
  log "[🧹 Eliminando disco anterior: $HA_DISK]"
  rm -f "$HA_DISK"
fi

# Eliminar backups y snapshots anteriores
log "[🧹 Eliminando backups y snapshots anteriores de Home Assistant...]"
rm -rf /mnt/storage/homeassistant_backups
rm -rf /mnt/storage/rsnapshot

mkdir -p "$(dirname "$HA_DISK")"

# Descargar imagen oficial más reciente
log "[⬇️ Buscando la última imagen de HAOS en formato .qcow2.xz...]"
HA_URL=$(curl -s https://api.github.com/repos/home-assistant/operating-system/releases/latest \
  | grep "browser_download_url" | grep "haos_ova-.*\.qcow2\.xz" | cut -d '"' -f 4)

log "[⬇️ Descargando imagen desde: $HA_URL]"
curl -L -o "${HA_DISK}.xz" "$HA_URL"

log "[📦 Descomprimiendo imagen...]"
xz -d "${HA_DISK}.xz"

# Crear VM con consola activa
log "[⚙️ Creando VM con libvirt...]"
virt-install \
  --name "$HA_VM" \
  --memory 2048 \
  --vcpus 2 \
  --disk path="$HA_DISK",format=qcow2 \
  --import \
  --os-variant generic \
  --network bridge=br0 \
  --quiet >> "$HA_LOG" 2>&1

log "[⏳ VM de Home Assistant lanzada. Conéctate con 'virsh console home-assistant']"
