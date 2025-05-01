#!/bin/bash

# BLOQUE 0 — Lanzador de ejecución persistente
# Este bloque solo se ejecuta si se lanza mediante curl | bash
# y asegura que el resto del script continúe en entorno normal (no bajo 'sudo bash')

LOCAL_SCRIPT="/usr/local/bin/fitandsetup.sh"

if [[ "$0" == *bash ]]; then
  echo "[🧩 Descargando copia local del script para futuras ejecuciones...]"
  curl -s -o "$LOCAL_SCRIPT" https://raw.githubusercontent.com/andreicnx/server/main/server.sh
  chmod +x "$LOCAL_SCRIPT"

  echo "[⏩ Ejecutando desde copia local. Este bloque ya no se volverá a ejecutar.]"
  exec sudo "$LOCAL_SCRIPT"
  exit 0
fi

# A partir de aquí empieza el resto del script normal (bloques 1 en adelante)
#!/bin/bash

# BLOQUE 0 — Lanzador de ejecución persistente
# Este bloque solo se ejecuta si se lanza mediante curl | bash
# y asegura que el resto del script continúe en entorno normal (no bajo 'sudo bash')

LOCAL_SCRIPT="/usr/local/bin/fitandsetup.sh"

if [[ "$0" == *bash ]]; then
  echo "[🧩 Descargando copia local del script para futuras ejecuciones...]"
  curl -s -o "$LOCAL_SCRIPT" https://raw.githubusercontent.com/andreicnx/server/main/server.sh
  chmod +x "$LOCAL_SCRIPT"

  echo "[⏩ Ejecutando desde copia local. Este bloque ya no se volverá a ejecutar.]"
  exec sudo "$LOCAL_SCRIPT"
  exit 0
fi

# A partir de aquí empieza el resto del script normal (bloques 1 en adelante)

# ... (el contenido completo del server.sh va a partir de aquí, sin incluir de nuevo BLOQUE 0)
