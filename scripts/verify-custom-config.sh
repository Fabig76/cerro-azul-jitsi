#!/usr/bin/env bash
# =====================================================================
# verify-custom-config.sh - Comprueba que cada clave de los custom-*.js
# del web existe de verdad en la imagen de jitsi/web.
#
# POR QUE: Jitsi ignora EN SILENCIO cualquier clave de config.js que no
# conozca (p.ej. enableLayerSuspension, eliminada en stable-11031). Una
# errata o una clave retirada en una actualizacion no da ningun error:
# simplemente no hace nada.
#
# Criterio (una clave es valida si cumple CUALQUIERA):
#   (a) aparece en las plantillas de la imagen
#       (/defaults/system-config.js, /defaults/settings-config.js,
#        /defaults/interface_config.js), o
#   (b) aparece como identificador en el cliente:
#       /usr/share/jitsi-meet/libs/app.bundle.min.js o lib-jitsi-meet.min.js
#
# Rapido: UNA sola ejecucion de docker vuelca todos los identificadores
# disponibles y la comparacion se hace en local. No levanta el stack.
#
# Uso:
#   ./scripts/verify-custom-config.sh               # sale 1 si alguna falta
#   ./scripts/verify-custom-config.sh --check-only  # informa, sale siempre 0
#   ./scripts/verify-custom-config.sh [--check-only] fichero.js ...
#
# Imagen: jitsi/web:${JITSI_IMAGE_VERSION:-stable-11031}
# =====================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ONLY=0
FILES=()
for a in "$@"; do
    case "$a" in
        --check-only) CHECK_ONLY=1 ;;
        -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) FILES+=("$a") ;;
    esac
done
if [ "${#FILES[@]}" -eq 0 ]; then
    FILES=("$REPO/web/config/custom-config.js" "$REPO/web/config/custom-interface_config.js")
fi

IMAGE="jitsi/web:${JITSI_IMAGE_VERSION:-stable-11031}"

# Codigo de salida final: con --check-only nunca falla (util en CI para
# informar sin bloquear).
finish() {
    if [ "$CHECK_ONLY" -eq 1 ]; then exit 0; fi
    exit "$1"
}

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker no esta disponible" >&2
    finish 2
fi

# Extraer las claves de nivel superior de un fichero propio. Solo cuentan
# las lineas que EMPIEZAN por `config.X` / `interfaceConfig.X`: asi los
# comentarios (que empiezan por // o *) no se cuelan como claves.
extract_keys() {
    sed -nE 's/^[[:space:]]*(config|interfaceConfig)\.([A-Za-z_][A-Za-z0-9_]*).*/\2/p' "$1" | sort -u
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== Volcando identificadores de $IMAGE (una sola ejecucion) ==="
# Todos los identificadores de plantillas y bundles, uno por linea.
# grep -h evita el prefijo de fichero; sort -u deja la lista compacta.
if ! docker run --rm --entrypoint sh "$IMAGE" -c '
    grep -ohE "[A-Za-z_][A-Za-z0-9_]*" \
        /defaults/system-config.js \
        /defaults/settings-config.js \
        /defaults/interface_config.js \
        /usr/share/jitsi-meet/libs/app.bundle.min.js \
        /usr/share/jitsi-meet/libs/lib-jitsi-meet.min.js \
    | sort -u' > "$TMP/available" 2> "$TMP/err"; then
    echo "ERROR: no se pudo leer la imagen $IMAGE:" >&2
    cat "$TMP/err" >&2
    finish 2
fi
echo "    $(wc -l < "$TMP/available") identificadores"
echo

MISSING=0
TOTAL=0
for f in "${FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "AVISO: no existe $f (se omite)"
        continue
    fi
    echo "-- ${f#"$REPO"/} --"
    keys="$(extract_keys "$f")"
    if [ -z "$keys" ]; then
        echo "  (sin claves)"
        continue
    fi
    while IFS= read -r k; do
        TOTAL=$((TOTAL+1))
        if grep -qxF "$k" "$TMP/available"; then
            printf '  OK         %s\n' "$k"
        else
            printf '  NO EXISTE  %s   <- Jitsi la ignora en silencio\n' "$k"
            MISSING=$((MISSING+1))
        fi
    done <<< "$keys"
    echo
done

if [ "$MISSING" -gt 0 ]; then
    echo "RESULTADO: $MISSING de $TOTAL clave(s) NO existen en $IMAGE."
    finish 1
fi
echo "RESULTADO: OK, las $TOTAL claves existen en $IMAGE."
finish 0
