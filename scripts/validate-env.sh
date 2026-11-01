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

# --- 6. Autenticacion JWT y moderacion (Fase 2) ------------------------
echo
echo "-- Autenticacion JWT (Fase 2) --"
is_true() { case "$1" in 1|true|TRUE|True|yes|on) return 0;; *) return 1;; esac; }

enable_auth="$(getval ENABLE_AUTH)"
# Prosody usa PROSODY_AUTH_TYPE y, si no esta, cae en AUTH_TYPE.
pat="$(getval PROSODY_AUTH_TYPE)"
[ -n "$pat" ] || pat="$(getval AUTH_TYPE)"

if ! is_true "$enable_auth"; then
    warn "ENABLE_AUTH='$enable_auth': Jitsi NO exige token (salas abiertas, modo rollback)"
else
    ok "ENABLE_AUTH=$enable_auth"
    if [ "$pat" != "jwt" ]; then
        fail "con ENABLE_AUTH=1, PROSODY_AUTH_TYPE (o AUTH_TYPE) debe ser 'jwt', es '$pat'"
        echo "              La plantilla de Prosody decide con PROSODY_AUTH_TYPE;"
        echo "              AUTH_TYPE solo es su fallback."
    else
        ok "PROSODY_AUTH_TYPE efectivo = jwt"
    fi
    a="$(getval AUTH_TYPE)"
    if [ -n "$a" ] && [ "$a" != "$pat" ]; then
        warn "AUTH_TYPE='$a' distinto de PROSODY_AUTH_TYPE='$pat' (web/jicofo leen AUTH_TYPE)"
    fi

    v="$(getval JWT_APP_ID)"
    if [ -z "$v" ]; then
        fail "JWT_APP_ID esta vacio o no definido"
    else
        ok "JWT_APP_ID=$v"
    fi

    for k in JWT_ACCEPTED_ISSUERS JWT_ACCEPTED_AUDIENCES; do
        v="$(getval "$k")"
        if [ -z "$v" ]; then
            fail "$k no esta definido (el panel firma iss/aud con su primer valor)"
        else
            ok "$k=$v"
        fi
    done

    v="$(getval JWT_ALLOW_EMPTY)"
    if [ "$v" != "0" ]; then
        fail "JWT_ALLOW_EMPTY debe ser 0 (tiene '$v'): con 1 se entra sin token"
    else
        ok "JWT_ALLOW_EMPTY=0"
    fi

    v="$(getval JWT_ENABLE_DOMAIN_VERIFICATION)"
    if is_true "$v"; then
        fail "JWT_ENABLE_DOMAIN_VERIFICATION='$v': el panel pone un id de participante en 'sub', no el dominio"
    else
        ok "JWT_ENABLE_DOMAIN_VERIFICATION desactivado"
    fi

    if is_true "$(getval ENABLE_GUESTS)"; then
        fail "ENABLE_GUESTS=1: habilita un dominio anonimo que entra sin token"
    else
        ok "ENABLE_GUESTS=0"
    fi

    # token_affiliation solo funciona en el componente MUC.
    muc_mods=",$(getval XMPP_MUC_MODULES | tr -d ' '),"
    vh_mods=",$(getval XMPP_MODULES | tr -d ' '),"
    case "$muc_mods" in
        *,token_affiliation,*) ok "XMPP_MUC_MODULES contiene token_affiliation" ;;
        *)
            fail "XMPP_MUC_MODULES debe contener token_affiliation (rol moderador desde el JWT)"
            case "$vh_mods" in
                *,token_affiliation,*)
                    echo "              Esta en XMPP_MODULES (VirtualHost): ahi se carga pero"
                    echo "              no recibe 'muc-occupant-pre-join' y no hace nada." ;;
            esac ;;
    esac

    if is_true "$(getval JICOFO_ENABLE_AUTH)"; then
        fail "JICOFO_ENABLE_AUTH debe ser 0: con auth JWT en Jicofo TODOS serian moderadores"
    else
        ok "JICOFO_ENABLE_AUTH=0"
    fi

    v="$(getval ENABLE_AUTO_OWNER)"
    if [ "$v" != "false" ] && [ "$v" != "0" ]; then
        fail "ENABLE_AUTO_OWNER debe ser false (tiene '$v'): si no, el primero en entrar es moderador"
    else
        ok "ENABLE_AUTO_OWNER=$v"
    fi
fi

v="$(getval ENABLE_AV_MODERATION)"
if [ -n "$v" ] && ! is_true "$v"; then
    fail "ENABLE_AV_MODERATION='$v': sin moderacion A/V cualquiera puede hablar"
else
    ok "ENABLE_AV_MODERATION=${v:-default(true)}"
fi

for k in START_WITH_AUDIO_MUTED START_WITH_VIDEO_MUTED; do
    v="$(getval "$k")"
    if ! is_true "$v"; then
        warn "$k='$v': los participantes no entran silenciados"
    else
        ok "$k=$v"
    fi
done

# --- 7. Sala grande (Fase 3) -------------------------------------------
echo
echo "-- Sala grande (Fase 3) --"
# OJO: sin definir, el compose pasa 0 al web (${VAR:-0}); por eso aqui un
# valor vacio se trata como 0 y solo se falla si alguien lo pone a 1.
for k in ENABLE_PREJOIN_PAGE ENABLE_P2P; do
    v="$(getval "$k")"
    if is_true "$enable_auth" && is_true "$v"; then
        fail "$k='$v' con ENABLE_AUTH=1: debe ser 0"
        case "$k" in
            ENABLE_PREJOIN_PAGE)
                echo "              En la prejoin el asistente puede encender micro/camara"
                echo "              antes de que la moderacion A/V este activa." ;;
            ENABLE_P2P)
                echo "              En P2P el medio va directo entre navegadores, fuera del"
                echo "              JVB donde se aplica la moderacion A/V." ;;
        esac
    elif is_true "$v"; then
        warn "$k='$v': en una sala grande deberia ser 0"
    else
        ok "$k=${v:-sin definir (compose pasa 0)}"
    fi
done

v="$(getval ENABLE_BREAKOUT_ROOMS)"
if [ -n "$v" ] && [ "$v" != "0" ] && [ "$v" != "false" ]; then
    warn "ENABLE_BREAKOUT_ROOMS='$v': a 500 personas cada sala de breakout es"
    echo "              otra conferencia que Jicofo/JVB sostienen (multiplica la carga)."
else
    ok "ENABLE_BREAKOUT_ROOMS=${v:-sin definir (compose pasa 0)}"
fi

# Limites: solo se avisa, no se falla. Sin definir = sin limite.
for k in MAX_PARTICIPANTS MAX_BRIDGE_PARTICIPANTS VISITORS_MAX_PARTICIPANTS; do
    if has "$k"; then
        v="$(getval "$k")"
        case "$k" in
            MAX_PARTICIPANTS)        donde="Prosody (muc_max_occupants)" ;;
            MAX_BRIDGE_PARTICIPANTS) donde="Jicofo (max-bridge-participants)" ;;
            *)                       donde="Jicofo (visitors, solo con ENABLE_VISITORS=1)" ;;
        esac
        if printf '%s' "$v" | grep -qE '^[0-9]+$' && [ "$v" -ge 500 ]; then
            ok "$k=$v ($donde)"
        else
            warn "$k=$v limita en $donde: para 500 personas subirlo o quitarlo (Fase 5)"
        fi
    else
        ok "$k sin definir (sin limite artificial)"
    fi
done

# Rate limits de Prosody (Fase 3.4). El modulo viene DESACTIVADO por
# defecto. Si alguien lo activa con los valores por defecto, el
# login_rate (logins por segundo Y POR IP) bloquea a los asistentes entre
# si: en un conjunto todos salen por la misma IP publica (NAT).
v="$(getval PROSODY_ENABLE_RATE_LIMITS)"
if is_true "$v"; then
    lr="$(getval PROSODY_RATE_LIMIT_LOGIN_RATE)"
    sr="$(getval PROSODY_RATE_LIMIT_SESSION_RATE)"
    ar="$(getval PROSODY_RATE_LIMIT_ALLOW_RANGES)"
    if [ -z "$lr" ] || [ "$lr" -lt 20 ] 2>/dev/null; then
        fail "PROSODY_ENABLE_RATE_LIMITS=1 con LOGIN_RATE='${lr:-3}': los asistentes"
        echo "              comparten IP publica (NAT) y se bloquearian entre si."
        echo "              Subir PROSODY_RATE_LIMIT_LOGIN_RATE a 50 o mas."
    else
        ok "rate limits activos (LOGIN_RATE=$lr, SESSION_RATE=${sr:-200})"
    fi
    if [ -z "$ar" ] || [ "$ar" = "10.0.0.0/8" ]; then
        warn "PROSODY_RATE_LIMIT_ALLOW_RANGES=${ar:-10.0.0.0/8}: conviene anadir"
        echo "              la IP publica del conjunto para eximir a los asistentes."
    else
        ok "PROSODY_RATE_LIMIT_ALLOW_RANGES=$ar"
    fi
else
    ok "rate limits de Prosody desactivados (sin limite artificial de entrada)"
fi

# --- 8. Valores de ejemplo sin cambiar ---------------------------------
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
