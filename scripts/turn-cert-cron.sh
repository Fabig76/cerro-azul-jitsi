#!/usr/bin/env bash
# =====================================================================
# turn-cert-cron.sh - Renovacion desatendida del certificado del TURN
#
# Para cron, EN EL SERVIDOR DEL TURN. Llama a 'turn-cert.sh renew' (que
# solo actua si faltan menos de 30 dias) y, si falla, avisa.
#
# POR QUE AVISA:
#   Un certificado caducado no tumba coturn: el TURN por UDP sigue
#   funcionando y nadie lo nota... salvo quien esta en una red que solo
#   deja salir 443/TLS, que se queda sin audio. Sin aviso, el fallo se
#   descubre en plena asamblea.
#
# Avisos (en este orden; si no hay ninguno configurado, solo log):
#   TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID  -> mensaje de Telegram
#   TURN_ALERT_WEBHOOK                     -> POST JSON {"text": "..."}
#                                             (Slack/Discord/n8n/etc.)
#   Ademas imprime el error por stdout: si cron tiene MAILTO, llega por
#   correo; y encaja con el patron "solo imprime si falla" de Hermes.
#   Las URL/tokens de aviso NO se imprimen nunca (llevan credenciales).
#
# Variables:
#   TURN_DIR          directorio del TURN (default /opt/coturn)
#   TURN_CERT_LOG     fichero de log (default /var/log/turn-cert.log)
#   TURN_CERT_ARGS    argumentos extra para turn-cert.sh (p. ej. --days 20)
#
# Instalacion (root, servidor del TURN), una vez al dia a las 04:17:
#   cat > /etc/cron.d/turn-cert <<'EOF'
#   TURN_DIR=/opt/coturn
#   # TURN_ALERT_WEBHOOK=https://...   (o TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID)
#   17 4 * * * root /opt/coturn/scripts/turn-cert-cron.sh
#   EOF
#
# --dry-run: ejecuta renew en --dry-run y NO envia avisos reales.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TURN_DIR="${TURN_DIR:-/opt/coturn}"
LOG_FILE="${TURN_CERT_LOG:-/var/log/turn-cert.log}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Log con fecha. Si no se puede escribir el fichero, a stderr.
log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    if { [ -e "$LOG_FILE" ] && [ -w "$LOG_FILE" ]; } || \
       { [ ! -e "$LOG_FILE" ] && [ -w "$(dirname "$LOG_FILE")" ]; }; then
        printf '%s\n' "$line" >> "$LOG_FILE"
    else
        printf '%s\n' "$line" >&2
    fi
}

# Envia el aviso. Con python3 (stdlib) en vez de curl para no exponer la
# URL del webhook en la lista de procesos (ps) y no depender de curl.
send_alert() {
    local text="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] se enviaria un aviso: ${text%%$'\n'*}"
        return 0
    fi
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && [ -z "${TURN_ALERT_WEBHOOK:-}" ]; then
        log "sin TURN_ALERT_WEBHOOK ni TELEGRAM_*: el aviso solo queda en el log"
        return 0
    fi
    ALERT_TEXT="$text" python3 -I - <<'PYEOF' || log "no se pudo enviar el aviso (ver conectividad)"
import json, os, sys, urllib.request
text = os.environ["ALERT_TEXT"]
def post(url, payload):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=15).read()
ok = False
tok, chat = os.environ.get("TELEGRAM_BOT_TOKEN"), os.environ.get("TELEGRAM_CHAT_ID")
if tok and chat:
    try:
        post("https://api.telegram.org/bot%s/sendMessage" % tok, {"chat_id": chat, "text": text})
        ok = True
    except Exception as e:  # sin imprimir la URL: lleva el token
        print("aviso Telegram fallo: %s" % type(e).__name__, file=sys.stderr)
hook = os.environ.get("TURN_ALERT_WEBHOOK")
if hook:
    try:
        post(hook, {"text": text})
        ok = True
    except Exception as e:
        print("aviso webhook fallo: %s" % type(e).__name__, file=sys.stderr)
sys.exit(0 if ok else 1)
PYEOF
}

# Evitar dos ejecuciones a la vez (cron + manual), que podrian reiniciar
# coturn dos veces o pisarse al escribir los ficheros.
LOCK="/tmp/turn-cert-cron.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
    log "otra renovacion en curso; se omite esta"
    exit 0
fi

args=(renew --turn-dir "$TURN_DIR")
[ "$DRY_RUN" -eq 1 ] && args+=(--dry-run)
# shellcheck disable=SC2206  # se quiere separar por espacios
[ -n "${TURN_CERT_ARGS:-}" ] && args+=(${TURN_CERT_ARGS})

set +e
output="$("${SCRIPT_DIR}/turn-cert.sh" "${args[@]}" 2>&1)"
rc=$?
set -e

while IFS= read -r l; do log "$l"; done <<< "$output"

if [ "$rc" -ne 0 ]; then
    msg="🔴 ALERTA: fallo la renovacion del certificado del TURN ($(hostname), rc=${rc})
$(printf '%s\n' "$output" | tail -n 8)
Revisar: ${SCRIPT_DIR}/turn-cert.sh status --turn-dir ${TURN_DIR}"
    send_alert "$msg"
    # stdout: llega por MAILTO de cron / al usuario en el patron Hermes.
    printf '%s\n' "$msg"
    exit "$rc"
fi
exit 0
