#!/usr/bin/env bash
# =====================================================================
# backup.sh - Respaldo del estado de Jitsi que NO esta en git (Fase 7.2)
#
# Se ejecuta EN EL SERVIDOR DE JITSI. El codigo (compose, plugins,
# panel) esta en git; lo que se perderia con el disco es el estado: el
# .env con los secretos, la base de datos de reuniones, la config que
# generan los contenedores y la del TURN.
#
# QUE RESPALDA (rutas relativas al origen, default /opt/jitsi-meet).
# Se respalda lo que EXISTA; lo que falte se lista al final y en el
# MANIFEST, y el respaldo queda marcado como "incompleto".
#   En claro (no son secretos):
#     docker-compose.yml
#     web/config/                       (custom-config.js, custom-interface_config.js
#                                        y, en un servidor en marcha, la config
#                                        que genera el contenedor web; SIN keys/)
#     admin-panel/instance/             (reuniones.db y demas, SIN admin.env)
#     turn/turnserver.conf              (con static-auth-secret REDACTADO)
#   Cifrado (contienen secretos):
#     .env                              (todos los secretos del stack)
#     admin-panel/instance/admin.env    (contrasena del panel, claves)
#     web/config/keys/                  (cert.key = clave privada TLS, cert.crt)
#     prosody/config/  jicofo/config/  jvb/config/
#       -> NO estan en el repo: los crea cada contenedor al arrancar
#          (bind mount ./<servicio>/config:/config del docker-compose.yml)
#          a partir del .env, y llevan los mismos secretos en claro
#          (contrasenas XMPP de focus/jvb, JWT_APP_SECRET,
#          external_service_secret = TURN_CREDENTIALS). Solo existen en un
#          servidor donde el stack ya ha arrancado. Si faltan, el respaldo
#          sigue siendo restaurable (se regeneran desde el .env).
#
#   El secreto del TURN (static-auth-secret) es el mismo valor que
#   TURN_CREDENTIALS del .env: queda respaldado (cifrado) dentro del .env,
#   y el turnserver.conf se guarda con el placeholder. Al restaurar se
#   vuelve a poner (ver docs/BACKUP-RESTORE.md).
#
# INTEGRIDAD:
#   SHA256SUMS (formato estandar de sha256sum, rutas relativas al
#   paquete) se genera AL FINAL, sobre los ficheros ya escritos: cubre
#   files/**, MANIFEST.txt y el bloque de secretos. Si quedara vacio, el
#   script falla y no deja paquete.
#
# CIFRADO:
#   BACKUP_PASSPHRASE (variable de entorno; nunca como argumento, para que
#   no quede en 'ps' ni en el historial). Se usa
#     openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -salt
#   + un HMAC-SHA256 del fichero cifrado (encrypt-then-MAC).
#   POR QUE NO aes-256-gcm: 'openssl enc' NO admite cifrados AEAD
#   ("enc: AEAD ciphers not supported", verificado con OpenSSL 3.0.13).
#   El HMAC aporta lo que aportaria GCM: detectar una passphrase
#   equivocada o un fichero manipulado/corrupto ANTES de descifrar.
#   Sin BACKUP_PASSPHRASE el script se niega, salvo con --allow-plaintext
#   (y entonces el fichero se llama ...-SECRETOS-EN-CLARO.tar.gz).
#
# Uso:
#   BACKUP_PASSPHRASE='...' scripts/backup.sh [--origen DIR] [--dest DIR]
#                           [--turn-conf FICHERO] [--keep N] [--strict] [--dry-run]
#   --origen DIR directorio del despliegue a respaldar (alias: --src).
#               Default: BACKUP_ORIGEN, si no JITSI_DIR, si no /opt/jitsi-meet.
#               Si no existe, el script falla (exit 1) sin crear nada.
#   --dest DIR  directorio de salida (default BACKUP_DIR o /opt/jitsi-meet/backups)
#   --turn-conf turnserver.conf a respaldar (default <origen>/turn/turnserver.conf)
#   --keep N    borrar los respaldos de este script mas antiguos, dejando N
#               (default 0 = no borrar nada)
#   --strict    si el respaldo sale incompleto, terminar con exit 2 (el
#               paquete se crea igual). Util en cron para que avise.
#
# PERMISOS: en produccion .env, admin.env y web/config/keys/cert.key son
# 600 de root, asi que normalmente hay que ejecutarlo con sudo:
#   sudo BACKUP_PASSPHRASE='...' BACKUP_ORIGEN=/opt/jitsi-meet scripts/backup.sh
# Antes de copiar nada se comprueba que todo es legible; si no, sale con
# exit 1, dice que fichero falla y no crea ningun respaldo.
#
# Codigos de salida: 0 respaldo creado (completo, o incompleto sin
# --strict); 1 error, no se ha creado ningun paquete; 2 respaldo creado
# pero incompleto (solo con --strict).
#
# El respaldo queda con chmod 600. COPIALO FUERA DEL SERVIDOR (un respaldo
# en el mismo disco no sobrevive a la perdida del disco).
# =====================================================================
set -euo pipefail

SRC="${BACKUP_ORIGEN:-${JITSI_DIR:-/opt/jitsi-meet}}"
DEST="${BACKUP_DIR:-/opt/jitsi-meet/backups}"
TURN_CONF=""
KEEP=0
DRY_RUN=0
STRICT=0
ALLOW_PLAINTEXT=0
PBKDF2_ITER=600000

log()  { printf '[backup] %s\n' "$*"; }
warn() { printf '[backup] AVISO: %s\n' "$*" >&2; }
die()  { printf '[backup] ERROR: %s\n' "$*" >&2; exit 1; }

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --origen|--src)    SRC="${2:?falta valor}"; shift ;;
        --dest)            DEST="${2:?falta valor}"; shift ;;
        --turn-conf)       TURN_CONF="${2:?falta valor}"; shift ;;
        --keep)            KEEP="${2:?falta valor}"; shift ;;
        --strict)          STRICT=1 ;;
        --allow-plaintext) ALLOW_PLAINTEXT=1 ;;
        --dry-run)         DRY_RUN=1 ;;
        -h|--help)         sed -n '2,/^# =====.*$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                 die "opcion desconocida: $1" ;;
    esac
    shift
done
case "$KEEP" in ''|*[!0-9]*) die "--keep debe ser un numero" ;; esac

# --- quien ejecuta (primera linea del log) --------------------------------
# Queda registrado en el log del respaldo quien lo genero.
if [ "$(id -u)" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ]; then
        log "ejecutando como root (sudo desde ${SUDO_USER})"
    else
        log "ejecutando como root"
    fi
else
    log "ejecutando como $(id -un) (uid $(id -u), sin root)"
fi

# --- validar el origen ANTES de nada ------------------------------------
[ -e "$SRC" ] || die "no existe el directorio de origen ${SRC} (usa --origen DIR o BACKUP_ORIGEN=DIR). No se ha creado ningun respaldo."
[ -d "$SRC" ] || die "el origen ${SRC} no es un directorio. No se ha creado ningun respaldo."
SRC="$(cd "$SRC" && pwd)"
TURN_CONF="${TURN_CONF:-${SRC}/turn/turnserver.conf}"

# --- comprobar permisos ANTES de copiar nada --------------------------------
# En produccion .env, admin-panel/instance/admin.env y web/config/keys/cert.key
# son 600 de root: sin sudo el respaldo fallaria a medias (o, peor, saldria
# "incompleto" porque un directorio 700 hace que admin.env parezca no existir).
# Se revisa todo lo que se va a leer y, si algo no es legible, se sale sin
# crear nada y diciendo como ejecutarlo.
UNREADABLE=()
check_path() {
    local p="$1" d
    if [ -e "$p" ]; then
        if [ -d "$p" ]; then
            # Directorios sin r/x y ficheros sin r (find no puede entrar en
            # los primeros: se listan ellos y se callan sus errores).
            while IFS= read -r -d '' d; do UNREADABLE+=("$d"); done < <(
                find "$p" \( -type d \( ! -readable -o ! -executable \) -prune -print0 \) \
                     -o \( ! -type d ! -type l ! -readable -print0 \) 2>/dev/null)
        elif [ ! -r "$p" ]; then
            UNREADABLE+=("$p")
        fi
    else
        # No existe... o no se puede ver: subir hasta el primer antecesor
        # que exista y comprobar que se puede entrar en el.
        d="$(dirname "$p")"
        while [ "$d" != "/" ] && [ ! -e "$d" ]; do d="$(dirname "$d")"; done
        if [ ! -x "$d" ] || [ ! -r "$d" ]; then UNREADABLE+=("$d"); fi
    fi
}
check_path "$SRC/docker-compose.yml"
check_path "$SRC/web/config"
check_path "$SRC/admin-panel/instance"
check_path "$TURN_CONF"
for i in .env admin-panel/instance/admin.env prosody/config jicofo/config jvb/config; do
    check_path "${SRC}/${i}"
done
if [ "${#UNREADABLE[@]}" -gt 0 ]; then
    mapfile -t UNREADABLE < <(printf '%s\n' "${UNREADABLE[@]}" | sort -u)
    for f in "${UNREADABLE[@]}"; do
        printf '[backup] ERROR: no se puede leer %s (permisos).\n' "$f" >&2
    done
    {
        echo "          Ejecuta el respaldo con sudo:"
        # sudo no pasa el entorno: las variables van en la propia linea.
        # La passphrase NO se imprime (queda como '...').
        echo "            sudo BACKUP_PASSPHRASE=... BACKUP_ORIGEN=${SRC}${BACKUP_DIR:+ BACKUP_DIR=${BACKUP_DIR}} ${0}${ORIG_ARGS[*]:+ ${ORIG_ARGS[*]}}"
        echo "          No se ha creado ningun respaldo."
    } >&2
    exit 1
fi

# --- que se respalda ----------------------------------------------------
# Cada elemento esperado lleva el motivo que se muestra si falta.
declare -A WHY_MISSING=(
    [docker-compose.yml]="deberia estar en todo clon del repo"
    [web/config]="deberia estar en todo clon del repo (custom-*.js)"
    [web/config/keys]="lo genera el contenedor web al arrancar (certificado TLS); normal si el stack no ha arrancado aqui"
    [admin-panel/instance]="lo crea el panel admin al arrancar"
    [turn/turnserver.conf]="normal si el TURN esta en otro servidor"
    [.env]="SIN .env el respaldo NO sirve para restaurar el stack"
    [admin-panel/instance/admin.env]="lo crea la instalacion del panel admin"
    [prosody/config]="lo genera el contenedor prosody al arrancar; normal si el stack no ha arrancado aqui"
    [jicofo/config]="lo genera el contenedor jicofo al arrancar; normal si el stack no ha arrancado aqui"
    [jvb/config]="lo genera el contenedor jvb al arrancar; normal si el stack no ha arrancado aqui"
)
SECRET_ITEMS=(.env admin-panel/instance/admin.env web/config/keys prosody/config jicofo/config jvb/config)
MISSING=()

command -v openssl >/dev/null || die "falta openssl"
command -v python3 >/dev/null || die "falta python3"

if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
    if [ "$ALLOW_PLAINTEXT" -eq 1 ]; then
        warn "**********************************************************"
        warn "SIN BACKUP_PASSPHRASE: el respaldo CONTENDRA LOS SECRETOS EN"
        warn "CLARO (.env, admin.env, config de prosody/jicofo/jvb)."
        warn "Tratalo como el propio .env: chmod 600 y nunca en sitio publico."
        warn "**********************************************************"
    else
        die "define BACKUP_PASSPHRASE (o usa --allow-plaintext sabiendo que los secretos iran en claro)"
    fi
elif [ "${#BACKUP_PASSPHRASE}" -lt 16 ]; then
    warn "BACKUP_PASSPHRASE tiene menos de 16 caracteres: usa una mas larga"
fi

TS="$(date +%Y%m%d-%H%M%S)"
NAME="cerroazul-backup-${TS}"
[ -n "${BACKUP_PASSPHRASE:-}" ] || NAME="${NAME}-SECRETOS-EN-CLARO"
OUT="${DEST}/${NAME}.tar.gz"

if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] origen:  ${SRC}"
    log "[dry-run] destino: ${OUT}"
    st() { if [ -e "$1" ]; then echo "existe"; else echo "NO EXISTE: se omitiria (${WHY_MISSING[$2]})"; fi; }
    for i in docker-compose.yml web/config admin-panel/instance; do
        log "[dry-run]   en claro: ${i} ($(st "${SRC}/${i}" "$i"))"
    done
    log "[dry-run]   en claro: turn/turnserver.conf <- ${TURN_CONF} (secreto redactado) ($(st "$TURN_CONF" turn/turnserver.conf))"
    if [ -n "${BACKUP_PASSPHRASE:-}" ]; then m="cifrado"; else m="EN CLARO"; fi
    for i in "${SECRET_ITEMS[@]}"; do
        log "[dry-run]   ${m}: ${i} ($(st "${SRC}/${i}" "$i"))"
    done
    log "[dry-run] no se ha escrito nada"
    exit 0
fi

# --- preparar el directorio de trabajo ----------------------------------
# mktemp -d crea el directorio con 700: nadie mas puede entrar. Dentro
# se usa umask 022 a proposito: los directorios del paquete deben tener
# permisos normales, porque al restaurar se aplican sobre los del
# servidor (un web/ o turn/ con 700 seria un efecto colateral raro).
# Los ficheros sensibles conservan los suyos (cp -a) y el .tar.gz final
# queda con 600. Si algo falla, el trap borra todo: no queda paquete.
WORK="$(mktemp -d)"
umask 022
trap 'rm -rf "$WORK"; rm -f "${OUT}.part"' EXIT
STAGE="${WORK}/${NAME}"
mkdir -p "${STAGE}/files" "${WORK}/secrets"

missing() {
    MISSING+=("$1")
    warn "no existe ${1}: se omite (${WHY_MISSING[$1]})"
}

# Copia una ruta relativa del origen a un destino, conservando permisos.
copy_rel() {
    local rel="$1" to="$2"
    if [ ! -e "${SRC}/${rel}" ]; then
        missing "$rel"
        return 0
    fi
    mkdir -p "${to}/$(dirname "$rel")"
    cp -a "${SRC}/${rel}" "${to}/${rel}"
    log "copiado: ${rel}"
}

# 1) Parte en claro
copy_rel docker-compose.yml "${STAGE}/files"
copy_rel web/config "${STAGE}/files"
# web/config/keys/ (cert.key = clave privada TLS) va en el bloque cifrado.
rm -rf "${STAGE}/files/web/config/keys"

if [ -d "${SRC}/admin-panel/instance" ]; then
    mkdir -p "${STAGE}/files/admin-panel/instance"
    # Todo menos admin.env (va cifrado), los logs y la db (copia aparte).
    find "${SRC}/admin-panel/instance" -mindepth 1 -maxdepth 1 \
        ! -name admin.env ! -name '*.log' ! -name 'reuniones.db*' \
        -exec cp -a {} "${STAGE}/files/admin-panel/instance/" \;
    log "copiado: admin-panel/instance (sin admin.env ni logs)"
    if [ -f "${SRC}/admin-panel/instance/reuniones.db" ]; then
        # Copia CONSISTENTE con la API de backup de SQLite: copiar el
        # fichero a pelo mientras el panel escribe puede dar una db rota.
        python3 -I - "${SRC}/admin-panel/instance/reuniones.db" \
            "${STAGE}/files/admin-panel/instance/reuniones.db" <<'PYEOF'
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
n = dst.execute("PRAGMA integrity_check").fetchone()[0]
dst.close(); src.close()
if n != "ok":
    sys.exit("integrity_check de la copia: %s" % n)
PYEOF
        log "reuniones.db copiada (backup API de SQLite, integrity_check ok)"
    else
        log "admin-panel/instance: no hay reuniones.db (aun no se ha creado ninguna reunion)"
    fi
else
    missing admin-panel/instance
fi

if [ -f "$TURN_CONF" ]; then
    mkdir -p "${STAGE}/files/turn"
    # El secreto real NO se guarda aqui: se sustituye por el placeholder
    # del repo. El valor sigue respaldado (cifrado) como TURN_CREDENTIALS.
    sed -E 's/^([[:space:]]*static-auth-secret[[:space:]]*=).*/\1CAMBIAR_CON_EL_TURN_CREDENTIALS_DE_JITSI/' \
        "$TURN_CONF" > "${STAGE}/files/turn/turnserver.conf"
    if grep -qE '^[[:space:]]*static-auth-secret[[:space:]]*=[[:space:]]*CAMBIAR' "${STAGE}/files/turn/turnserver.conf" \
       || ! grep -q 'static-auth-secret' "${STAGE}/files/turn/turnserver.conf"; then
        log "copiado: turn/turnserver.conf (static-auth-secret redactado)"
    else
        die "no se pudo redactar static-auth-secret en turnserver.conf"
    fi
else
    missing turn/turnserver.conf
fi

# 2) Parte con secretos
for i in "${SECRET_ITEMS[@]}"; do copy_rel "$i" "${WORK}/secrets"; done
# Normalizar permisos de los dos ficheros de secretos.
for f in .env admin-panel/instance/admin.env; do
    if [ -f "${WORK}/secrets/${f}" ]; then chmod 600 "${WORK}/secrets/${f}"; fi
done
if [ -d "${WORK}/secrets/web/config/keys" ]; then
    find "${WORK}/secrets/web/config/keys" -type f -name '*.key' -exec chmod 600 {} +
fi

N_PUBLIC="$(find "${STAGE}/files" -type f | wc -l)"
N_SECRET="$(find "${WORK}/secrets" -type f | wc -l)"
if [ "$((N_PUBLIC + N_SECRET))" -eq 0 ]; then
    die "no se ha encontrado NINGUN fichero que respaldar en ${SRC} (faltan: ${MISSING[*]}). ¿Es el directorio del despliegue? No se ha creado ningun respaldo."
fi

# 3) Empaquetar (y cifrar) los secretos
tar -C "${WORK}/secrets" -czf "${WORK}/secrets.tar.gz" .
SECRET_LIST="$(tar -tzf "${WORK}/secrets.tar.gz" | grep -v '/$' | sed 's|^\./||' | sort || true)"

if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
    # -pass env: la passphrase no aparece en la linea de comandos.
    openssl enc -aes-256-cbc -pbkdf2 -iter "$PBKDF2_ITER" -md sha256 -salt \
        -pass env:BACKUP_PASSPHRASE \
        -in "${WORK}/secrets.tar.gz" -out "${STAGE}/secrets.tar.gz.enc"
    # HMAC-SHA256 del cifrado. La clave del MAC sale de la passphrase con
    # PBKDF2 y una sal propia (la sal de openssl + etiqueta), distinta de
    # la del cifrado: asi el MAC no es un atajo para adivinar la passphrase.
    python3 -I - "${STAGE}/secrets.tar.gz.enc" "$PBKDF2_ITER" > "${STAGE}/secrets.tar.gz.enc.mac" <<'PYEOF'
import hashlib, hmac, os, sys
data = open(sys.argv[1], "rb").read()
if data[:8] != b"Salted__":
    sys.exit("formato openssl inesperado")
key = hashlib.pbkdf2_hmac("sha256", os.environ["BACKUP_PASSPHRASE"].encode(),
                          b"cerroazul-backup-mac:" + data[8:16], int(sys.argv[2]))
print(hmac.new(key, data, hashlib.sha256).hexdigest())
PYEOF
    SECRETS_MODE="cifrado (aes-256-cbc + pbkdf2 ${PBKDF2_ITER} + HMAC-SHA256)"
else
    mv "${WORK}/secrets.tar.gz" "${STAGE}/secrets-EN-CLARO.tar.gz"
    SECRETS_MODE="EN CLARO (sin BACKUP_PASSPHRASE)"
fi
rm -f "${WORK}/secrets.tar.gz"
rm -rf "${WORK}/secrets"

if [ "${#MISSING[@]}" -eq 0 ]; then ESTADO="completo"; else ESTADO="incompleto"; fi

# 4) Manifiesto legible (sin secretos: solo nombres)
{
    echo "Respaldo de Cerro Azul Jitsi"
    echo "fecha:   $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "host:    $(hostname)"
    echo "origen:  ${SRC}"
    if git -C "$SRC" rev-parse --short HEAD >/dev/null 2>&1; then
        echo "commit:  $(git -C "$SRC" rev-parse --short HEAD) (restaurar sobre un clon de ese commit)"
    fi
    echo "estado:  ${ESTADO}"
    echo "secretos: ${SECRETS_MODE}"
    echo
    echo "== Faltan (no existian en el origen) =="
    if [ "${#MISSING[@]}" -eq 0 ]; then
        echo "(nada)"
    else
        for m in "${MISSING[@]}"; do echo "${m}  -- ${WHY_MISSING[$m]}"; done
    fi
    echo
    echo "== En claro (files/) =="
    (cd "${STAGE}/files" && find . -type f | sed 's|^\./||' | sort)
    echo
    echo "== Dentro del bloque de secretos =="
    if [ -n "$SECRET_LIST" ]; then printf '%s\n' "$SECRET_LIST"; else echo "(vacio)"; fi
} > "${STAGE}/MANIFEST.txt"

# 5) SHA256SUMS: lo ULTIMO que se escribe, sobre los ficheros ya escritos
#    (files/**, MANIFEST.txt y el bloque de secretos). Rutas relativas al
#    paquete, formato estandar de sha256sum.
( cd "$STAGE" && find . -type f ! -path ./SHA256SUMS -printf '%P\0' | sort -z | xargs -0 -r sha256sum ) \
    > "${STAGE}/SHA256SUMS"
N_SUMS="$(wc -l < "${STAGE}/SHA256SUMS")"
N_FILES="$(find "$STAGE" -type f ! -path "${STAGE}/SHA256SUMS" | wc -l)"
[ "$N_SUMS" -gt 0 ] || die "SHA256SUMS ha salido vacio. No se ha creado ningun respaldo."
[ "$N_SUMS" -eq "$N_FILES" ] || die "SHA256SUMS tiene ${N_SUMS} lineas pero hay ${N_FILES} ficheros. No se ha creado ningun respaldo."
( cd "$STAGE" && sha256sum --quiet --strict -c SHA256SUMS ) \
    || die "SHA256SUMS no se verifica recien generado. No se ha creado ningun respaldo."

# 6) Paquete final
mkdir -p "$DEST"
tar -C "$WORK" -czf "${OUT}.part" "$NAME"
chmod 600 "${OUT}.part"
mv "${OUT}.part" "$OUT"

# 7) Rotacion opcional (solo ficheros con el patron de este script)
if [ "$KEEP" -gt 0 ]; then
    mapfile -t old < <(find "$DEST" -maxdepth 1 -type f -name 'cerroazul-backup-*.tar.gz' -printf '%T@ %p\n' \
                       | sort -rn | tail -n +"$((KEEP + 1))" | cut -d' ' -f2-)
    for f in "${old[@]}"; do rm -f -- "$f"; log "borrado respaldo antiguo: $(basename "$f")"; done
fi

# 8) Listado para verificar
log "respaldo creado: ${OUT} ($(du -h "$OUT" | cut -f1), chmod 600)"
log "origen: ${SRC}"
log "secretos: ${SECRETS_MODE}"
log "SHA256SUMS: ${N_SUMS} ficheros (${N_PUBLIC} en claro + MANIFEST + bloque de secretos)"
echo "----- contenido del paquete -----"
tar -tzvf "$OUT"
echo "----- dentro del bloque de secretos -----"
if [ -n "$SECRET_LIST" ]; then printf '%s\n' "$SECRET_LIST" | sed 's/^/  /'; else echo "  (vacio)"; fi
echo "---------------------------------"
if [ "$ESTADO" = "completo" ]; then
    log "estado: COMPLETO"
else
    warn "estado: INCOMPLETO. Faltan ${#MISSING[@]} elementos (no existian en ${SRC}):"
    for m in "${MISSING[@]}"; do warn "  - ${m}  (${WHY_MISSING[$m]})"; done
fi
log "copialo FUERA del servidor (p. ej. rsync/scp a otro host) y prueba restore.sh una vez al mes"
if [ "$ESTADO" != "completo" ] && [ "$STRICT" -eq 1 ]; then
    exit 2
fi
