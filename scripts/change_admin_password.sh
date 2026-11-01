#!/usr/bin/env bash
# =====================================================================
# change_admin_password.sh - Cambia la contrasena del panel admin
#
# El panel guarda el SHA-256 de la contrasena en admin.env
# (JITSI_ADMIN_PASSWORD_HASH). La contrasena en texto plano NO se puede
# recuperar: solo comprobar o cambiar.
#
# Uso:
#   ./scripts/change_admin_password.sh <nueva-contrasena> [ruta-admin.env]
#   ./scripts/change_admin_password.sh --verificar 'mi-contrasena'
#
# Si no se da la ruta, usa la del VPS:
#   /opt/jitsi-meet/admin-panel/instance/admin.env
# =====================================================================
set -uo pipefail

# Uso:
#   $0 <nueva-contrasena> [ruta-admin.env]
#   $0 --verificar <contrasena> [ruta-admin.env]
DEFAULT_ENV="/opt/jitsi-meet/admin-panel/instance/admin.env"
KEY="JITSI_ADMIN_PASSWORD_HASH"

# Verificar: compara la contrasena dada con el hash guardado.
if [ "${1:-}" = "--verificar" ]; then
    CONTRASENA="${2:-}"
    ADMIN_ENV="${3:-$DEFAULT_ENV}"
    if [ -z "$CONTRASENA" ]; then
        echo "Uso: $0 --verificar 'mi-contrasena' [ruta-admin.env]" >&2
        exit 2
    fi
    if [ ! -f "$ADMIN_ENV" ]; then
        echo "ERROR: no existe $ADMIN_ENV" >&2
        exit 2
    fi
    STORED=$(grep -E "^$KEY=" "$ADMIN_ENV" | head -1 | cut -d= -f2- | tr -d '[:space:]')
    CAND=$(printf '%s' "$CONTRASENA" | sha256sum | cut -d' ' -f1)
    if [ "$STORED" = "$CAND" ]; then
        echo "CONTRASENA CORRECTA"
        exit 0
    fi
    echo "CONTRASENA INCORRECTA"
    exit 1
fi

ADMIN_ENV="${2:-$DEFAULT_ENV}"
NUEVA="${1:-}"

if [ -z "$NUEVA" ]; then
    echo "Uso: $0 <nueva-contrasena> [ruta-admin.env]" >&2
    echo "     $0 --verificar 'mi-contrasena' [ruta-admin.env]" >&2
    exit 2
fi

if [ ! -f "$ADMIN_ENV" ]; then
    echo "ERROR: no existe $ADMIN_ENV" >&2
    exit 2
fi

NUEVA="$1"
LONG=$(printf '%s' "$NUEVA" | wc -c)
if [ "$LONG" -lt 8 ]; then
    echo "ERROR: la contrasena debe tener al menos 8 caracteres (tiene $LONG)" >&2
    exit 2
fi

HASH=$(printf '%s' "$NUEVA" | sha256sum | cut -d' ' -f1)
BAK="${ADMIN_ENV}.bak.$(date +%Y%m%d_%H%M%S)"

cp -p "$ADMIN_ENV" "$BAK" || { echo "ERROR: no se pudo respaldar" >&2; exit 1; }

# Sustituir el valor conservando el resto del archivo y sus permisos.
python3 - "$ADMIN_ENV" "$HASH" << 'PYEOF'
import os, re, sys
path, nuevo = sys.argv[1], sys.argv[2]
KEY = "JITSI_ADMIN_PASSWORD_HASH"
with open(path) as f:
    lineas = f.readlines()
salida, cambiado = [], False
for l in lineas:
    if l.strip().startswith(KEY + "="):
        salida.append(KEY + "=" + nuevo + "\n")
        cambiado = True
    else:
        salida.append(l)
if not cambiado:
    salida.append(KEY + "=" + nuevo + "\n")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.writelines(salida)
os.chmod(tmp, os.stat(path).st_mode & 0o777)
os.replace(tmp, path)
print("  hash actualizado")
PYEOF

echo "Contrasena cambiada en $ADMIN_ENV"
echo "  respaldo: $BAK"
echo "  usuario:  $(grep -h '^ADMIN_USER=' "$ADMIN_ENV" | cut -d= -f2- || echo 'Hguaza76 (default)')"
echo
echo "Para aplicar el cambio hay que recrear el contenedor admin:"
echo "  cd /opt/jitsi-meet && docker compose up -d --force-recreate admin"
