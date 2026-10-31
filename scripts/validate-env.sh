#!/usr/bin/env bash
# =====================================================================
# validate-env.sh - Valida el .env de Jitsi antes de desplegar
#
# Comprueba lo que realmente rompe el stack, con los mensajes de error
# exactos que se ven en los logs. Uso:
#   ./scripts/validate-env.sh
#   ./scripts/validate-env.sh /opt/jitsi-meet/.env
# =====================================================================
set -uo pipefail

ENV_FILE="${1:-.env}"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: no existe $ENV_FILE" >&2
    echo "       Ejecuta: cp .env.example $ENV_FILE" >&2
    exit 1
fi

ERRORS=0
WARNINGS=0

ok()    { printf '  OK       %s\n' "$1"; }
fail()  { printf '  FALLO    %s\n' "$1"; ERRORS=$((ERRORS+1)); }
warn()  { printf '  AVISO    %s\n' "$1"; WARNINGS=$((WARNINGS+1)); }

# Leer un valor del .env
getval() {
    sed -n "s/^$1=//p" "$ENV_FILE" | head -1
}

has() {
    grep -qE "^$1=" "$ENV_FILE"
}

echo "=== Validando $ENV_FILE ==="
echo

# --- 1. Secretos obligatorios con la longitud correcta -----------------
echo "-- Secretos --"
check_secret() {
    local key="$1" bytes="$2"
    if ! has "$key"; then
        fail "$key no esta definido"
        return
    fi
    local val
    val="$(getval "$key")"
    if [ -z "$val" ]; then
        fail "$key esta vacio"
    elif [ "${#val}" -ne "$bytes" ]; then
        fail "$key debe tener $bytes caracteres hex, tiene ${#val}"
    elif ! printf '%s' "$val" | grep -qE '^[0-9a-f]+$'; then
        fail "$key no es hex valido"
    else
        ok "$key ($bytes hex)"
    fi
}
check_secret JICOFO_AUTH_PASSWORD 32
check_secret JVB_AUTH_PASSWORD    32
check_secret JWT_APP_SECRET       64
check_secret ADMIN_JWT_SECRET     64
check_secret TURN_CREDENTIALS     32

# --- 2. Los 5 secretos deben ser distintos ----------------------------
echo
echo "-- Los secretos deben ser distintos entre si --"
dups=""
KEYS="JICOFO_AUTH_PASSWORD JVB_AUTH_PASSWORD JWT_APP_SECRET ADMIN_JWT_SECRET TURN_CREDENTIALS"
for k in $KEYS; do
    v="$(getval "$k")"
    [ -n "$v" ] || continue
    for j in $KEYS; do
        [ "$k" = "$j" ] && continue
        w="$(getval "$j")"
        [ "$v" = "$w" ] && dups="$dups $k==$j"
    done
done
if [ -n "$dups" ]; then
    fail "secretos duplicados:$dups"
else
    ok "los 5 secretos son distintos"
fi

# --- 3. Valores con trampa conocida ------------------------------------
echo
echo "-- Valores que rompen el stack --"

v="$(getval JVB_BREWERY_MUC)"
if [ -z "$v" ]; then
    fail "JVB_BREWERY_MUC no esta definido"
elif [ "$v" != "jvbbrewery" ]; then
    fail "JVB_BREWERY_MUC debe ser 'jvbbrewery', no '$v'"
    echo "              Con el dominio completo el JVB entra al MUC equivocado"
    echo "              y Jicofo reporta 'no operational bridges'."
else
    ok "JVB_BREWERY_MUC=jvbbrewery"
fi

if has LOCAL_ADDRESS; then
    warn "LOCAL_ADDRESS esta definido en el .env"
    echo "              El entrypoint de la imagen lo autodetecta y lo pisa."
    echo "              Definirlo a mano solo produce drift."
else
    ok "LOCAL_ADDRESS no esta definido (correcto: la imagen lo autodetecta)"
fi

if has JVB_PUBLIC_ADDRESS; then
    warn "JVB_PUBLIC_ADDRESS esta definido (obsoleto)"
    echo "              Usa JVB_ADVERTISE_IPS."
else
    ok "JVB_PUBLIC_ADDRESS no esta definido (correcto)"
fi

v="$(getval COLIBRI_REST_ENABLED)"
if [ "$v" != "true" ]; then
    fail "COLIBRI_REST_ENABLED debe ser 'true' (tiene '$v')"
    echo "              Sin esto /about/health devuelve 404 y Jicofo marca"
    echo "              el bridge como no operacional, aunque todo demas"
    echo "              parezca bien."
else
    ok "COLIBRI_REST_ENABLED=true"
fi

v="$(getval DISABLE_AWS_HARVESTER)"
if [ "$v" != "true" ]; then
    warn "DISABLE_AWS_HARVESTER no es 'true' (tiene '$v')"
    echo "              El JVB puede colgarse (issue upstream #2008)."
else
    ok "DISABLE_AWS_HARVESTER=true"
fi

# --- 4. Coherencia de dominios ----------------------------------------
echo
echo "-- Dominios --"
pub="$(getval PUBLIC_URL)"
if [ -z "$pub" ]; then
    fail "PUBLIC_URL no esta definido"
elif [ "$pub" = "meet.tu-dominio.com" ]; then
    fail "PUBLIC_URL es el valor de ejemplo ('$pub')"
else
    ok "PUBLIC_URL=$pub"
    for k in XMPP_DOMAIN XMPP_MUC_DOMAIN XMPP_INTERNAL_MUC_DOMAIN JVB_WS_DOMAIN; do
        v="$(getval "$k")"
        if [ -z "$v" ]; then
            fail "$k no esta definido"
        elif ! printf '%s' "$v" | grep -q "$(printf '%s' "$pub" | sed 's/[^.]*$//')"; then
            warn "$k='$v' no parece derivar de PUBLIC_URL=$pub"
        else
            ok "$k=$v"
        fi
    done
fi

v="$(getval XMPP_SERVER)"
if [ "$v" != "prosody" ]; then
    fail "XMPP_SERVER debe ser 'prosody' (nombre del contenedor), no '$v'"
else
    ok "XMPP_SERVER=prosody"
fi

# --- 5. Version de imagenes -------------------------------------------
echo
echo "-- Imagenes --"
v="$(getval JITSI_IMAGE_VERSION)"
if [ -z "$v" ]; then
    fail "JITSI_IMAGE_VERSION no esta definido"
elif [ "$v" = "stable" ] || [ "$v" = "latest" ]; then
    fail "JITSI_IMAGE_VERSION='$v' no es una version fija"
else
    ok "JITSI_IMAGE_VERSION=$v"
fi

v="$(getval JVB_ADVERTISE_IPS)"
if [ -z "$v" ]; then
    fail "JVB_ADVERTISE_IPS no esta definido"
elif [ "$v" = "IP-PUBLICA-DEL-VPS" ]; then
    fail "JVB_ADVERTISE_IPS es el valor de ejemplo"
else
    ok "JVB_ADVERTISE_IPS=$v"
fi

# --- 6. Valores de ejemplo sin cambiar ---------------------------------
echo
echo "-- Valores de ejemplo sin reemplazar --"
placeholders=$(grep -E '^[A-Z_]+=' "$ENV_FILE" | grep -iE 'CAMBIAR|TU-DOMINIO|IP-PUBLICA|tu-dominio' | cut -d= -f1 | tr '\n' ' ')
if [ -n "$placeholders" ]; then
    fail "quedan placeholders sin reemplazar: $placeholders"
else
    ok "no quedan placeholders"
fi

# --- Resumen ------------------------------------------------------------
echo
if [ "$ERRORS" -gt 0 ]; then
    echo "RESULTADO: $ERRORS error(es), $WARNINGS aviso(s). No desplegar."
    exit 1
fi
echo "RESULTADO: OK ($WARNINGS aviso(s))."
[ "$WARNINGS" -gt 0 ] && exit 0 || exit 0
