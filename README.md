# FitAndSetup — Servidor Ubuntu Automatizado para Home Assistant

Este repositorio contiene un script de instalación y configuración completamente automatizado para convertir un servidor Ubuntu en un entorno optimizado para Home Assistant y servicios asociados.

---

## 🧩 Funcionalidades del Script

1. **Red segura y bridge (br0)** para máquinas virtuales.
2. **Descarga y despliegue de Home Assistant OS en VM** (libvirt + KVM).
3. **Montaje automático de discos SSD** (/mnt/storage y /mnt/backup).
4. **Sincronización de respaldo automática** con log y control de estado.
5. **Servidor Samba (Time Machine)** accesible desde macOS.
6. **Sistema de snapshots con rsnapshot**, limpieza si hay poco espacio.
7. **VPN local con WireGuard**, QR para 10 clientes y backup completo.
8. **Backups automáticos de Home Assistant** (con apagado y arranque controlado).
9. **Comprobación final del sistema + script programado cada 6h**.
10. **Servidor DLNA con MiniDLNA y Jellyfin**, accesibles desde Chromecast, TV o móvil.

---

## 🚀 Ejecución del Script

```bash
curl -s https://raw.githubusercontent.com/andreicnx/server/main/server.sh | sudo bash
```

---

## 📂 Estructura del Script

- `/mnt/storage`: disco principal (datos, backups, VM)
- `/mnt/backup`: copia espejo automatizada de `/mnt/storage`
- `/mnt/home`: disco exclusivo para Home Assistant
- `/var/log/fitandsetup/`: logs detallados de cada componente
- `/usr/local/bin/`: scripts auxiliares para tareas programadas

---

## 📋 Requisitos Previos

- Ubuntu Server 22.04 LTS mínimo
- 3 discos SSD (1 para almacenamiento, 1 para backup, 1 exclusivo para Home Assistant)
- Acceso root o `sudo`
- Internet activo
- CPU compatible con virtualización

---

## 🛡️ Seguridad y Resiliencia

- Todos los bloques del script se pueden ejecutar múltiples veces sin efectos negativos.
- Cada paso genera logs específicos para seguimiento y depuración.
- Rollback automático de configuración de red si falla el bridge.
- Revisión del sistema cada 6h, con log dedicado.

---

## 🧠 Automatización Inteligente (pendiente)

- Análisis automático de logs con la API de ChatGPT (en preparación).

---

## 📆 Última actualización

2025-05-01
