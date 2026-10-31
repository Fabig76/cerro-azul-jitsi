#!/usr/bin/env bash
# =====================================================================
# install-prosody-plugins.sh - Instala los plugins de Prosody de Jitsi
#
# POR QUE ESTE SCRIPT EXISTE:
# La imagen oficial jitsi/prosody NO incluye los modulos Lua propios de
# Jitsi (mod_auth_token, mod_room_metadata, mod_av_moderation,
# mod_muc_lobby_rooms, mod_conference_duration, etc.). Verificado el
# 31-Oct-2026 con jitsi/prosody:stable-11031:
#
#   $ docker run --rm --entrypoint sh jitsi/prosody:stable-11031 \
#       -c "ls /usr/share/jitsi-meet/prosody-plugins/ | wc -l"
#   0
#
# Sin ellos, Prosody no arranca bien y Jitsi no puede autenticar:
#   modulemanager error  Unable to load module 'auth_token': No such file
#
# La fuente canonica es el paquete Debian `jitsi-meet-prosody`, que vive
# en el repo UNSTABLE (el repo stable solo trae documentacion, un .deb
# de 5 KB).
#
# Uso:
#   ./scripts/install-prosody-plugins.sh              # instala (idempotente)
#   ./scripts/install-prosody-plugins.sh --check      # solo verifica
#   ./scripts/install-prosody-plugins.sh --version 1.0.9237-1
#
# Variable de entorno:
#   PROSODY_PLUGINS_VERSION   version del .deb a usar
#   PROSODY_PLUGINS_DIR       destino (default: ./prosody/prosody-plugins)
# =====================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS_DIR="${PROSODY_PLUGINS_DIR:-${REPO_ROOT}/prosody/prosody-plugins}"
BASE_URL="https://download.jitsi.org/unstable"
VERSION="${PROSODY_PLUGINS_VERSION:-}"

MODE=install
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        --version) shift; VERSION="$1" ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Opcion desconocida: $arg" >&2; exit 1 ;;
    esac
done

# ── Descubrir la ultima version si no se indico una ──────────────────
if [ -z "$VERSION" ]; then
    echo "=== Buscando la ultima version en ${BASE_URL}/ ==="
    VERSION=$(curl -fsSL --max-time 60 "${BASE_URL}/" 2>/dev/null \
        | grep -oE 'jitsi-meet-prosody_[0-9.]+-[0-9]+_all\.deb' \
        | sort -V -u | tail -1 | sed -E 's/^jitsi-meet-prosody_(.*)_all\.deb$/\1/')
    if [ -z "$VERSION" ]; then
        echo "ERROR: no se pudo descubrir la version. Usa --version <X.Y.Z-N>." >&2
        exit 1
    fi
    echo "    ultima version: ${VERSION}"
fi

DEB_NAME="jitsi-meet-prosody_${VERSION}_all.deb"

echo "=== Plugins de Prosody para Jitsi ==="
echo "    version: ${VERSION}"
echo "    destino: ${PLUGINS_DIR}"
echo

# ── Verificacion ──────────────────────────────────────────────────────
current_count=0
if [ -d "$PLUGINS_DIR" ]; then
    current_count=$(find "$PLUGINS_DIR" -name '*.lua' 2>/dev/null | wc -l)
fi

if [ "$MODE" = "check" ]; then
    echo "plugins .lua instalados: ${current_count}"
    if [ "$current_count" -ge 80 ]; then
        echo "OK: la cantidad esperada (80+) esta presente."
        exit 0
    fi
    echo "FALTA: se esperan 80+ modulos, hay ${current_count}."
    exit 1
fi

if [ "$current_count" -ge 80 ]; then
    echo "Ya hay ${current_count} modulos .lua instalados. No hace falta nada."
    exit 0
fi

# ── Descarga y extraccion ─────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== 1. Descargar ${DEB_NAME} ==="
curl -fsSL --max-time 120 -o "${TMP}/${DEB_NAME}" \
     "${BASE_URL}/${DEB_NAME}" \
  || { echo "ERROR: no se pudo descargar. Verifica la version en ${BASE_URL}/" >&2; exit 1; }

size=$(wc -c < "${TMP}/${DEB_NAME}")
echo "    descargado: ${size} bytes"
if [ "$size" -lt 100000 ]; then
    echo "ERROR: el .deb es demasiado pequeno (${size} bytes)." >&2
    echo "       El repo 'stable' trae un .deb vacio con solo documentacion." >&2
    echo "       Usa el repo 'unstable' (esta variable BASE_URL)." >&2
    exit 1
fi

echo "=== 2. Extraer ==="
dpkg-deb -x "${TMP}/${DEB_NAME}" "${TMP}/pkg"
SRC="${TMP}/pkg/usr/share/jitsi-meet/prosody-plugins"
if [ ! -d "$SRC" ]; then
    echo "ERROR: el .deb no contiene usr/share/jitsi-meet/prosody-plugins" >&2
    exit 1
fi

echo "=== 3. Instalar en ${PLUGINS_DIR} ==="
mkdir -p "$PLUGINS_DIR"
cp -r "${SRC}/." "${PLUGINS_DIR}/"

count=$(find "$PLUGINS_DIR" -name '*.lua' | wc -l)
echo "    modulos .lua instalados: ${count}"
if [ "$count" -lt 80 ]; then
    echo "ERROR: se esperaban 80+ modulos, hay ${count}" >&2
    exit 1
fi

echo
echo "=== 4. Verificar modulos criticos ==="
missing=0
for m in mod_auth_token.lua mod_room_metadata.lua mod_turncredentials.lua; do
    if [ -f "${PLUGINS_DIR}/${m}" ]; then
        echo "    OK  ${m}"
    else
        echo "    FALTA ${m}"
        missing=1
    fi
done
[ "$missing" -eq 0 ] || { echo "ERROR: faltan modulos criticos" >&2; exit 1; }

echo
echo "Listo. Reinicia prosody para que los cargue:"
echo "    docker compose up -d --force-recreate prosody"
