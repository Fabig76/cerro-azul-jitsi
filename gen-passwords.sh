#!/usr/bin/env bash
# ============================================================
# gen-passwords.sh - Genera los secretos de Jitsi Cerro Azul
# ============================================================
# Uso:
#   ./gen-passwords.sh              # imprime KEY=valor (copiar al .env)
#   ./gen-passwords.sh >> .env      # agrega al final del .env
#
# Los 5 secretos que genera:
#   JICOFO_AUTH_PASSWORD  32 hex  (Prosody <-> Jicofo)
#   JVB_AUTH_PASSWORD     32 hex  (Prosody <-> JVB)
#   JWT_APP_SECRET        64 hex  (firma los JWT de acceso a las salas)
#   ADMIN_JWT_SECRET      64 hex  (firma los JWT del panel admin)
#   TURN_CREDENTIALS      32 hex  (firma credenciales TURN de corta duracion)
#
# Los 5 deben ser DISTINTOS entre si. Para comprobarlo:
#   ./scripts/validate-env.sh
# ============================================================
set -euo pipefail

emit() {
    # emit <CLAVE> <bytes_hex>
    printf '%s=%s\n' "$1" "$(openssl rand -hex "$2")"
}

echo "# Secretos generados el $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
echo "# Copia estas lineas a tu .env (o ejecuta: ./gen-passwords.sh >> .env)"
echo ""

emit JICOFO_AUTH_PASSWORD 16
emit JVB_AUTH_PASSWORD    16
emit JWT_APP_SECRET       32
emit ADMIN_JWT_SECRET     32
emit TURN_CREDENTIALS     16
