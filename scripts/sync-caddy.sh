#!/usr/bin/env bash
# =====================================================================
# sync-caddy.sh - Sincroniza el bloque de Caddy de Jitsi con el host
#
# El repo es la fuente de verdad. Este script:
#   1. Verifica que el bloque del repo y el del host son identicos
#   2. Si difieren, muestra el diff y opcionalmente actualiza el host
#   3. Valida la config resultante ANTES de recargar Caddy
#
# Uso:
#   ./scripts/sync-caddy.sh                 # solo verifica (default)
#   ./scripts/sync-caddy.sh --apply         # actualiza el host si difiere
#   ./scripts/sync-caddy.sh --host <user@host>   # otro destino (default: chatbotph)
#
# Variable de entorno:
#   CADDY_HOST_PATH   ruta del Caddyfile en el host
#                     (default: /home/chatbotph/chatbotph/Caddyfile)
#   CADDY_CONTAINER   nombre del contenedor Caddy (default: hermes-caddy)
# =====================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BLOCK_FILE="${REPO_ROOT}/infra/caddy/meet.bytracking.net.caddy"

APPLY=0
CADDY_SSH="${CADDY_SSH:-chatbotph}"
CADDY_HOST_PATH="${CADDY_HOST_PATH:-/home/chatbotph/chatbotph/Caddyfile}"
CADDY_CONTAINER="${CADDY_CONTAINER:-hermes-caddy}"

for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --host) shift; CADDY_SSH="$1" ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "Opción desconocida: $arg" >&2; exit 1 ;;
    esac
done

[ -f "$BLOCK_FILE" ] || { echo "ERROR: no existe $BLOCK_FILE" >&2; exit 1; }

echo "=== Repo:   $BLOCK_FILE"
echo "=== Host:   ${CADDY_SSH}:${CADDY_HOST_PATH}"
echo "=== Contenedor Caddy: ${CADDY_CONTAINER}"
echo

# ── 1. Extraer el bloque meet del Caddyfile del host ──────────────────
# Se toma desde la linea del bloque hasta la llave de cierre al inicio de linea.
extract_meet_block() {
    # Captura el bloque de configuracion Y el bloque de comentarios que lo
    # precede (lineas contiguas con '#' justo antes de la llave de apertura).
    awk '
        /^meet\.bytracking\.net \{/ {
            # Retroceder: tomar los comentarios inmediatamente anteriores.
            # awk no puede retroceder, asi que se acumula en "pending".
            for (i = 1; i <= npending; i++) print pending[i]
            inblock = 1
        }
        inblock { print; next }
        /^[[:space:]]*#/ { pending[++npending] = $0; next }
        { npending = 0 }
    ' -
}

REMOTE_BLOCK="$(ssh "$CADDY_SSH" "cat '${CADDY_HOST_PATH}'" | extract_meet_block)"

if [ -z "$REMOTE_BLOCK" ]; then
    echo "El host NO tiene el bloque meet.bytracking.net."
    if [ "$APPLY" -eq 1 ]; then
        echo "->Agregando al final del Caddyfile del host..."
        ssh "$CADDY_SSH" "cat >> '${CADDY_HOST_PATH}'" < "$BLOCK_FILE"
        echo "->Bloque agregado."
    else
        echo "->Ejecuta con --apply para agregarlo."
    fi
    exit 0
fi

# ── 2. Comparar ignorando lineas en blanco ───────────────────────────
norm() { grep -v '^[[:space:]]*$'; }

if diff -q <(printf '%s\n' "$REMOTE_BLOCK" | norm) <(norm < "$BLOCK_FILE") >/dev/null; then
    echo "OK: el bloque del host coincide con el del repo."
    exit 0
fi

echo "DIFERENCIA entre el repo y el host:"
diff -u <(printf '%s\n' "$REMOTE_BLOCK") "$BLOCK_FILE" || true
echo

if [ "$APPLY" -eq 0 ]; then
    echo "->Ejecuta con --apply para actualizar el host."
    exit 1
fi

# ── 3. Reconstruir el Caddyfile del host con el bloque del repo ──────
echo "->Reconstruyendo el Caddyfile del host..."
ssh "$CADDY_SSH" "
    set -e
    TS=\$(date +%Y%m%d_%H%M%S)
    BAK='${CADDY_HOST_PATH}.bak.sync.'\$TS
    cp -p '${CADDY_HOST_PATH}' \"\$BAK\"
    echo \"   respaldo: \$BAK\"

    # Quitar el bloque meet anterior (si existe) y anexar el del repo.
    awk '
        /^meet\.bytracking\.net \{/ { skip=1 }
        !skip { print }
        skip && /^\}/ { skip=0 }
    ' '${CADDY_HOST_PATH}' > /tmp/Caddyfile.new
    printf '\n' >> /tmp/Caddyfile.new
    cat '${BLOCK_FILE}' >> /tmp/Caddyfile.new
    mv /tmp/Caddyfile.new '${CADDY_HOST_PATH}'
    echo '   Caddyfile actualizado.'
"

# ── 4. Validar ANTES de recargar (puerta de calidad) ──────────────────
echo "->Validando la config..."
if ! ssh "$CADDY_SSH" "docker exec -i ${CADDY_CONTAINER} caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile" < /dev/null 2>&1 | grep -q "Valid configuration"; then
    echo "ERROR: la config no valida. NO se recarga. Restaura el respaldo." >&2
    exit 1
fi

# ── 5. Recargar (sin downtime) ────────────────────────────────────────
echo "->Recargando Caddy..."
ssh "$CADDY_SSH" "docker exec ${CADDY_CONTAINER} caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile" >/dev/null 2>&1
echo "->Recarga hecha."

# ── 6. Verificar ───────────────────────────────────────────────────────
echo "->Verificando..."
sleep 2
for url in "https://meet.bytracking.net/" \
           "https://meet.bytracking.net/healthz" \
           "https://monitorlegal.org/" \
           "https://minutasegura.com/"; do
    code="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "$url")"
    printf '   %-45s HTTP %s\n' "$url" "$code"
    [ "$code" = "200" ] || { echo "ERROR: $url devolvio $code" >&2; exit 1; }
done

echo
echo "Sincronizacion completa y verificada."
