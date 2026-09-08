#!/usr/bin/env bash
# ============================================================
# gen-passwords.sh - Genera passwords aleatorios para Jitsi Cerro Azul
# ============================================================
# Uso: ./gen-passwords.sh > /dev/null  # solo genera
#      ./gen-passwords.sh >> .env     # agrega a .env
# ============================================================

set -e

echo "# Passwords generados el $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
echo "# Copia estas lineas a tu .env"
echo ""
echo "JICOFO_AUTH_PASSWORD=$(openssl rand -hex 16)"
echo "JVB_AUTH_PASSWORD=$(openssl rand -hex 16)"
echo "JWT_APP_SECRET=$(openssl rand -hex 32)"
echo "ADMIN_JWT_SECRET=$(openssl rand -hex 32)"
echo "TURNCREDENTIALS_secret=$(openssl rand -hex 32)"
