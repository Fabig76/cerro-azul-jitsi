#!/usr/bin/env bash
# =====================================================================
# make-test-env.sh - Genera un .env de prueba en un directorio destino
# Uso: ./make-test-env.sh <directorio> [dominio]
#
# No escribe en el repo: escribe en el directorio que se le pase
# (normalmente un clon limpio en /tmp).
# =====================================================================
set -euo pipefail

DEST="${1:?Uso: make-test-env.sh <directorio> [dominio]}"
DOMAIN="${2:-meet.cleanclone.test}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cp "${REPO}/.env.example" "${DEST}/.env"

python3 - "${DEST}/.env" "$DOMAIN" << 'PYEOF'
import sys
path, domain = sys.argv[1], sys.argv[2]
EQ = chr(61)
subs = {
    "PUBLIC_URL": "meet." + domain,
    "XMPP_DOMAIN": "meet." + domain,
    "XMPP_AUTH_DOMAIN": "auth.meet." + domain,
    "XMPP_MUC_DOMAIN": "muc.meet." + domain,
    "XMPP_INTERNAL_MUC_DOMAIN": "internal-muc.meet." + domain,
    "XMPP_RECORDER_DOMAIN": "recorder.meet." + domain,
    "JVB_WS_DOMAIN": "meet." + domain,
    "TURN_HOST": "meet." + domain,
    "JVB_ADVERTISE_IPS": "84.247.165.81",
}
lines = open(path).read().split("\n")
for i, line in enumerate(lines):
    for k, v in subs.items():
        if line.startswith(k + EQ):
            lines[i] = k + EQ + v
open(path, "w").write("\n".join(lines))
PYEOF

# Generar los 5 secretos y pegarlos.
"${REPO}/gen-passwords.sh" | grep -E '^[A-Z_]+=' | while IFS= read -r l; do
    k="${l%%=*}"; v="${l#*=}"
    python3 - "${DEST}/.env" "$k" "$v" << 'PYEOF'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
EQ = chr(61)
lines = open(path).read().split("\n")
for i, line in enumerate(lines):
    if line.startswith(key + EQ):
        lines[i] = key + EQ + val
open(path, "w").write("\n".join(lines))
PYEOF
done

echo ".env de prueba generado en ${DEST}/.env (dominio: ${DOMAIN})"
