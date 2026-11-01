#!/usr/bin/env bash
# =====================================================================
# check-turn.sh - Watchdog del servidor TURN (Fase 7.1)
#
# Comprueba desde fuera que el TURN responde: STUN Binding (UDP),
# TURN Allocate con credencial REST (UDP y TLS) y STUN sobre TLS en 443.
# La logica esta en check_turn.py (solo stdlib de Python 3): aqui solo se
# localiza el script y se le pasan los argumentos.
#
# Uso:
#   scripts/check-turn.sh [ENV_FILE] [--host H] [--port 3478] [--turns-port 443]
#                         [--no-allocate] [--no-tls] [--cert-min-days 14] [-v]
#
#   ENV_FILE: .env de Jitsi (o un fichero con SOLO las lineas TURN_*), del
#   que se lee TURN_CREDENTIALS para firmar la credencial de prueba. El
#   secreto no se imprime nunca. Tambien se acepta la variable de entorno
#   TURN_CREDENTIALS si no se pasa fichero.
#
# Contrato de watchdog (igual que check-meet-jitsi.sh de Hermes):
#   todo bien -> no imprime nada, sale 0; algo falla -> imprime, sale 1;
#   error de uso/configuracion -> sale 2.
#
# --dry-run: muestra que se comprobaria, sin enviar ningun paquete.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "🔴 ALERTA: check-turn.sh necesita python3 y no esta instalado"
    exit 2
fi

args=()
dry_run=0
for a in "$@"; do
    if [ "$a" = "--dry-run" ]; then dry_run=1; else args+=("$a"); fi
done

if [ "$dry_run" -eq 1 ]; then
    echo "[dry-run] se ejecutaria: python3 -I ${SCRIPT_DIR}/check_turn.py ${args[*]:-} -v"
    echo "[dry-run] comprobaciones: STUN UDP, Allocate UDP, STUN TLS (+caducidad cert), Allocate TLS"
    exit 0
fi

# -I: modo aislado (no carga modulos del directorio actual ni PYTHON*).
exec python3 -I "${SCRIPT_DIR}/check_turn.py" "${args[@]}"
