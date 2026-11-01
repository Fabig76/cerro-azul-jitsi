#!/usr/bin/env bash
# =====================================================================
# restore.sh - Restaura un respaldo de backup.sh (Fase 7.2)
#
# Deja los ficheros listos en el destino y NO ARRANCA NADA: el arranque
# (docker compose up) lo decide el operador despues de revisar. Asi una
# restauracion equivocada no tumba un stack que estaba funcionando.
#
# Uso:
#   BACKUP_PASSPHRASE='...' scripts/restore.sh RESPALDO.tar.gz [--dest DIR] [--owner U[:G]]
#                            [--yes] [--dry-run]
#
#   --dest DIR  donde restaurar (default /opt/jitsi-meet). Debe ser un clon
#               del repo (el respaldo NO lleva el codigo: compose, plugins,
#               panel... vienen de git).
#   --yes       no preguntar antes de sobrescribir (para automatizar)
#   --dry-run   verificar el respaldo y mostrar que se restauraria, sin
#               escribir nada en el destino
#   --owner U[:G] propietario que deben tener los ficheros restaurados
#               (default: RESTORE_OWNER, si no el propietario de --dest).
#               Solo se usa para el aviso de chown; el script no cambia
#               propietarios por su cuenta.
#
# Permisos que deja:
#   600: .env, admin-panel/instance/admin.env, web/config/keys/*.key,
#        turn/turnserver.conf
#   644: .js .yml .yaml .json .css .html .crt de la parte en claro
#   resto: los que traia el respaldo (cp -a en el origen)
# Si un fichero restaurado no queda con el propietario esperado, se
# imprime el 'chown' exacto de cada uno. Si el destino no es escribible
# (p. ej. .env 600 de root y ejecutas sin root), se avisa ANTES de tocar
# nada y se pide repetir con sudo.
#
# La passphrase se toma de BACKUP_PASSPHRASE; si no esta y hay terminal,
# se pide sin eco. Nunca se acepta como argumento (quedaria en 'ps' y en
# el historial).
#
# Seguridad:
#   - verifica SHA256SUMS (todo el paquete) y el HMAC de la parte
#     cifrada ANTES de tocar el destino (passphrase mala, SHA256SUMS
#     vacio/mal formado o fichero manipulado => no se restaura nada)
#   - --dry-run hace toda la verificacion (en un directorio temporal)
#     y lista que se crearia/sobrescribiria, sin escribir en el destino
#   - cada fichero que se sobrescribe se copia antes a
#     <dest>/.pre-restore-<fecha>/ (vuelta atras manual)
#
# Codigos de salida: 0 todo restaurado; 1 error (no se toco el destino,
# o se interrumpio); 3 restauracion PARCIAL (sin passphrase: se restauro
# la parte en claro pero NO los secretos).
# =====================================================================
set -euo pipefail

DEST="/opt/jitsi-meet"
YES=0
DRY_RUN=0
ARCHIVE=""
OWNER="${RESTORE_OWNER:-}"

log()  { printf '[restore] %s\n' "$*"; }
warn() { printf '[restore] AVISO: %s\n' "$*" >&2; }
die()  { printf '[restore] ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dest)    DEST="${2:?falta valor}"; shift ;;
        --yes|-y)  YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --owner)   OWNER="${2:?falta valor}"; shift ;;
        -h|--help) sed -n '2,/^# =====.*$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        die "opcion desconocida: $1" ;;
        *)         [ -z "$ARCHIVE" ] || die "solo se admite un respaldo"; ARCHIVE="$1" ;;
    esac
    shift
done

[ -n "$ARCHIVE" ] || die "uso: restore.sh RESPALDO.tar.gz [--dest DIR] [--owner U[:G]] [--yes] [--dry-run]"
[ -f "$ARCHIVE" ] || die "no existe ${ARCHIVE}"
command -v openssl >/dev/null || die "falta openssl"
command -v python3 >/dev/null || die "falta python3"

[ "$DRY_RUN" -eq 0 ] || log "[dry-run] se verifica el respaldo en un directorio temporal; no se escribe nada en ${DEST}"

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. Extraer y validar la estructura -----------------------------------
# Antes de extraer: ningun miembro absoluto ni con '..' (un tar manipulado
# podria escribir fuera del directorio de trabajo).
if tar -tzf "$ARCHIVE" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
    die "el respaldo contiene rutas absolutas o '..': no se procesa"
fi
tar -C "$WORK" --no-same-owner -xzf "$ARCHIVE"
mapfile -t tops < <(find "$WORK" -mindepth 1 -maxdepth 1 -type d)
[ "${#tops[@]}" -eq 1 ] || die "estructura inesperada (se esperaba un unico directorio cerroazul-backup-*)"
B="${tops[0]}"
if ! { [ -f "${B}/MANIFEST.txt" ] && [ -f "${B}/SHA256SUMS" ] && [ -d "${B}/files" ]; }; then
    die "no parece un respaldo de backup.sh (faltan MANIFEST.txt/SHA256SUMS/files)"
fi
log "respaldo: $(basename "$B")"
sed -n '2,/^$/p' "${B}/MANIFEST.txt" | sed '/^$/d; s/^/          /'

# --- 2. Verificar SHA256SUMS ----------------------------------------------
# Mensaje de error de varias lineas con el prefijo de die().
die_sums() {
    printf '[restore] ERROR: el respaldo no contiene SHA256SUMS valido (%s).\n' "$1" >&2
    printf '          El respaldo esta incompleto o se genero con un fallo.\n' >&2
    printf '          Genera uno nuevo con scripts/backup.sh.\n' >&2
    exit 1
}
SUMS="${B}/SHA256SUMS"
[ -s "$SUMS" ] || die_sums "esta vacio"
if grep -qvE '^[0-9a-f]{64} [ *][^/].*$' "$SUMS"; then
    die_sums "tiene lineas mal formadas, p. ej. linea $(grep -nvE '^[0-9a-f]{64} [ *][^/].*$' "$SUMS" | head -1 | cut -d: -f1)"
fi
# Formato actual: rutas relativas al paquete (files/..., MANIFEST.txt,
# secrets...). Formato antiguo: rutas './...' relativas a files/.
if grep -qE '^[0-9a-f]{64} [ *]\./' "$SUMS"; then
    SUMS_DIR="${B}/files"
    warn "SHA256SUMS en formato antiguo: solo cubre la parte en claro"
else
    SUMS_DIR="$B"
    # Todo fichero del paquete debe estar en SHA256SUMS (nada colado).
    extra="$(comm -13 <(sed -E 's/^[0-9a-f]{64} [ *]//' "$SUMS" | sort) \
                      <(cd "$B" && find . -type f ! -path ./SHA256SUMS -printf '%P\n' | sort))"
    [ -z "$extra" ] || die "el paquete contiene ficheros que no estan en SHA256SUMS: ${extra//$'\n'/, }. Corrupto o manipulado"
fi
if ! (cd "$SUMS_DIR" && sha256sum --quiet --strict -c "$SUMS"); then
    die "SHA256SUMS no cuadra con los ficheros: el respaldo esta corrupto o manipulado"
fi
log "SHA256SUMS: $(wc -l < "$SUMS") ficheros, sumas correctas"
if grep -q '^estado: *incompleto' "${B}/MANIFEST.txt"; then
    warn "el respaldo esta marcado como INCOMPLETO; faltaba en el origen:"
    sed -n '/^== Faltan/,/^$/p' "${B}/MANIFEST.txt" | sed '1d;/^$/d;s/^/            /' >&2
fi

# --- 3. Secretos: verificar HMAC y descifrar --------------------------------
SECRETS_OK=0
mkdir -p "${WORK}/secrets"
if [ -f "${B}/secrets.tar.gz.enc" ]; then
    if [ -z "${BACKUP_PASSPHRASE:-}" ] && [ -t 0 ]; then
        read -r -s -p "Passphrase del respaldo (vacio = no restaurar secretos): " BACKUP_PASSPHRASE
        echo
        export BACKUP_PASSPHRASE
    fi
    if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
        [ -f "${B}/secrets.tar.gz.enc.mac" ] || die "falta secrets.tar.gz.enc.mac"
        # Mismo calculo que backup.sh; comparacion en tiempo constante.
        if ! python3 -I - "${B}/secrets.tar.gz.enc" "${B}/secrets.tar.gz.enc.mac" <<'PYEOF'
import hashlib, hmac, os, sys
data = open(sys.argv[1], "rb").read()
expected = open(sys.argv[2]).read().strip()
if data[:8] != b"Salted__":
    sys.exit(1)
key = hashlib.pbkdf2_hmac("sha256", os.environ["BACKUP_PASSPHRASE"].encode(),
                          b"cerroazul-backup-mac:" + data[8:16], 600000)
sys.exit(0 if hmac.compare_digest(hmac.new(key, data, hashlib.sha256).hexdigest(), expected) else 1)
PYEOF
        then
            die "HMAC incorrecto: passphrase equivocada o bloque de secretos manipulado. No se restaura nada"
        fi
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
            -pass env:BACKUP_PASSPHRASE \
            -in "${B}/secrets.tar.gz.enc" -out "${WORK}/secrets.tar.gz"
        SECRETS_OK=1
        log "secretos: HMAC correcto, descifrados"
    else
        warn "sin passphrase: NO se restauraran los secretos (.env, admin.env, config de prosody/jicofo/jvb)"
    fi
elif [ -f "${B}/secrets-EN-CLARO.tar.gz" ]; then
    warn "este respaldo lleva los secretos EN CLARO"
    cp "${B}/secrets-EN-CLARO.tar.gz" "${WORK}/secrets.tar.gz"
    SECRETS_OK=1
else
    warn "el respaldo no trae bloque de secretos"
fi
if [ "$SECRETS_OK" -eq 1 ]; then
    if tar -tzf "${WORK}/secrets.tar.gz" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
        die "el bloque de secretos contiene rutas absolutas o '..'"
    fi
    tar -C "${WORK}/secrets" --no-same-owner -xzf "${WORK}/secrets.tar.gz"
fi

# --- 4. Plan: que se escribe y que se sobrescribe ---------------------------
mapfile -t plan < <( { (cd "${B}/files" && find . -type f);
                       (cd "${WORK}/secrets" && find . -type f); } | sed 's|^\./||' | sort -u )
[ "${#plan[@]}" -gt 0 ] || die "el respaldo no contiene ficheros"

n_new=0; n_over=0
echo "----- ficheros a restaurar en ${DEST} -----"
for rel in "${plan[@]}"; do
    if [ -e "${DEST}/${rel}" ]; then
        printf '  SOBRESCRIBE  %s\n' "$rel"; n_over=$((n_over + 1))
    else
        printf '  nuevo        %s\n' "$rel"; n_new=$((n_new + 1))
    fi
done
echo "-------------------------------------------"
log "${#plan[@]} ficheros: ${n_new} nuevos, ${n_over} se sobrescriben"

if [ ! -f "${DEST}/prosody/Dockerfile.prosody" ]; then
    warn "${DEST} no parece un clon del repo (falta prosody/Dockerfile.prosody)."
    warn "Primero: git clone <repo> ${DEST} ; despues restaura encima."
fi

# --- 4b. Se puede escribir en el destino? (antes de tocar nada) ------------
NOWRITE=()
# El propio destino (ahi se crea .pre-restore-<fecha>/).
if [ -e "$DEST" ] && { [ ! -w "$DEST" ] || [ ! -x "$DEST" ]; }; then NOWRITE+=("$DEST"); fi
for rel in "${plan[@]}"; do
    t="${DEST}/${rel}"
    if [ -e "$t" ]; then
        { [ -w "$t" ] && [ -r "$t" ]; } || NOWRITE+=("$t")
    else
        d="$(dirname "$t")"
        while [ "$d" != "/" ] && [ ! -e "$d" ]; do d="$(dirname "$d")"; done
        { [ -w "$d" ] && [ -x "$d" ]; } || NOWRITE+=("$d")
    fi
done
if [ "${#NOWRITE[@]}" -gt 0 ]; then
    mapfile -t NOWRITE < <(printf '%s\n' "${NOWRITE[@]}" | sort -u)
    for t in "${NOWRITE[@]}"; do
        printf '[restore] ERROR: no se puede escribir/leer %s (permisos).\n' "$t" >&2
    done
    {
        echo "          Ejecuta la restauracion con sudo:"
        echo "            sudo BACKUP_PASSPHRASE=... ${0} ${ARCHIVE} --dest ${DEST}"
        echo "          No se ha tocado nada en ${DEST}."
    } >&2
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] respaldo verificado; no se ha escrito nada en ${DEST}"
    [ "$SECRETS_OK" -eq 1 ] || exit 3
    exit 0
fi

# --- 5. Confirmacion -----------------------------------------------------
if [ "$YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
        die "sin terminal para confirmar: usa --yes para restaurar sin preguntar"
    fi
    read -r -p "Restaurar en ${DEST} (${n_over} ficheros se sobrescriben)? escribe 'si': " answer
    [ "$answer" = "si" ] || die "cancelado por el operador; no se ha tocado nada"
fi

# --- 6. Copia de seguridad de lo que se va a pisar, y restaurar --------------
TS="$(date +%Y%m%d-%H%M%S)"
PRE="${DEST}/.pre-restore-${TS}"
mkdir -p "$DEST"
if [ "$n_over" -gt 0 ]; then
    for rel in "${plan[@]}"; do
        if [ -e "${DEST}/${rel}" ]; then
            mkdir -p "${PRE}/$(dirname "$rel")"
            cp -a "${DEST}/${rel}" "${PRE}/${rel}"
        fi
    done
    chmod 700 "$PRE"
    log "copia previa de los ${n_over} ficheros sobrescritos en ${PRE}"
fi

# tar | tar conserva permisos y fechas de los ficheros.
#   --no-same-owner: los uid del servidor viejo no tienen por que existir
#                    en el nuevo (el operador ajusta propietarios).
#   --no-overwrite-dir: no cambia permisos/propietario de directorios que
#                    ya existen en el destino.
umask 022
tar -C "${B}/files" -cf - . | tar -C "$DEST" --no-same-owner --no-overwrite-dir -xf -
if [ "$SECRETS_OK" -eq 1 ]; then
    tar -C "${WORK}/secrets" -cf - . | tar -C "$DEST" --no-same-owner --no-overwrite-dir -xf -
fi

# Permisos segun el tipo de fichero (solo sobre lo que se ha restaurado).
for rel in "${plan[@]}"; do
    t="${DEST}/${rel}"
    [ -f "$t" ] || continue
    case "$rel" in
        .env|admin-panel/instance/admin.env|web/config/keys/*.key|turn/turnserver.conf)
            chmod 600 "$t" ;;
        prosody/config/*|jicofo/config/*|jvb/config/*)
            : ;;   # llevan secretos: se quedan como venian
        *.js|*.yml|*.yaml|*.json|*.css|*.html|*.crt)
            chmod 644 "$t" ;;
    esac
done
log "permisos: 600 para .env, admin.env, *.key y turnserver.conf; 644 para .js/.yml/.json/.crt"

# Propietarios: el script no hace chown; dice exactamente cual hace falta.
[ -n "$OWNER" ] || OWNER="$(stat -c '%U:%G' "$DEST")"
O_USER="${OWNER%%:*}"
O_GROUP=""; [ "$OWNER" = "$O_USER" ] || O_GROUP="${OWNER#*:}"
CHOWN_CMDS=()
for rel in "${plan[@]}"; do
    t="${DEST}/${rel}"
    [ -e "$t" ] || continue
    cur_u="$(stat -c '%U' "$t")"; cur_g="$(stat -c '%G' "$t")"
    if [ "$cur_u" != "$O_USER" ] || { [ -n "$O_GROUP" ] && [ "$cur_g" != "$O_GROUP" ]; }; then
        CHOWN_CMDS+=("sudo chown ${OWNER} ${t}")
    fi
done

log "restaurado en ${DEST}. NO se ha arrancado nada."
if [ "${#CHOWN_CMDS[@]}" -gt 0 ]; then
    warn "${#CHOWN_CMDS[@]} ficheros restaurados no son de ${OWNER} (propietario esperado;"
    warn "cambialo con --owner U[:G] o RESTORE_OWNER). Ejecuta, uno por fichero:"
    for c in "${CHOWN_CMDS[@]}"; do printf '            %s\n' "$c" >&2; done
    warn "(los permisos 600 se conservan tras el chown)"
else
    log "propietarios: todos los ficheros restaurados son de ${OWNER}; no hace falta chown"
fi
cat <<EOF
Siguientes pasos (docs/BACKUP-RESTORE.md):
  1. Propietarios: ver arriba (comandos chown concretos, si hacen falta)
  2. scripts/validate-env.sh ${DEST}/.env
  3. Si cambia la IP publica: JVB_ADVERTISE_IPS / JVB_PUBLIC_ADDRESS en el .env
  4. TURN: el static-auth-secret de coturn debe ser el TURN_CREDENTIALS del .env
  5. Arrancar cuando se decida: cd ${DEST} && docker compose up -d
EOF
if [ "$SECRETS_OK" -ne 1 ]; then
    warn "RESTAURACION PARCIAL: faltan los secretos. Repite con BACKUP_PASSPHRASE definido."
    exit 3
fi
