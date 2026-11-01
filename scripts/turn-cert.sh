#!/usr/bin/env bash
# =====================================================================
# turn-cert.sh - Certificado TLS del servidor TURN (cierre de Fase 4)
#
# Se ejecuta EN EL SERVIDOR DEL TURN (no en el de Jitsi), como root.
#
# POR QUE HACE FALTA:
#   coturn ofrece TURN sobre TLS en 443 (turns), la variante que entra en
#   las redes que bloquean UDP. Si el certificado caduca, coturn sigue
#   arrancando pero el handshake TLS falla y esos usuarios vuelven a
#   quedarse sin audio. Este script obtiene y renueva el certificado y
#   lo deja donde lo lee el contenedor.
#
# DOS ESCENARIOS (el script soporta ambos):
#   A) Let's Encrypt para turn.urbcerroazul.com (preferido). Requiere el
#      registro DNS 'turn' apuntando a la IP del TURN.
#        - HTTP-01 con --webroot DIR (un servidor web en el 80 sirve DIR)
#        - HTTP-01 con --standalone (certbot abre el 80 el mismo; en el
#          servidor del TURN el 80 esta libre, es lo mas sencillo)
#        - DNS-01 con --dns-ionos CREDENCIALES (plugin certbot-dns-ionos).
#          OJO: la zona urbcerroazul.com esta HOY en Netim, no en IONOS.
#          DNS-01 con IONOS solo funciona si la zona se mueve a IONOS o si
#          en Netim se crea un CNAME _acme-challenge.turn -> a una zona de
#          IONOS (y certbot se usa con esa delegacion).
#   B) Autofirmado (--selfsigned), el de hoy. Los clientes WebRTC no
#      validan el certificado del TURN (la seguridad la da la credencial
#      HMAC), asi que vale; solo hay que renovarlo antes de que caduque.
#
# DONDE ESCRIBE (lo que monta docker-compose.turn.yml en /etc/coturn/certs):
#   <turn-dir>/certs/turn_server_cert.pem   644  65534:65534
#   <turn-dir>/certs/turn_server_pkey.pem   600  65534:65534
#   El contenedor corre como nobody (65534): si la clave no es suya, no
#   puede leerla y el TLS no arranca.
#
# SUBCOMANDOS:
#   issue          obtiene (o fuerza) el certificado e instala los ficheros
#   renew          solo actua si faltan menos de --days dias (default 30);
#                  si renueva, reinicia coturn
#   deploy         copia la ultima emision de certbot a certs/ y reinicia
#                  coturn (lo usa el deploy-hook; no hace falta a mano)
#   install-hook   imprime el deploy-hook de certbot a instalar
#   status         muestra caducidad y permisos de los ficheros
#
# OPCIONES:
#   --turn-dir DIR       directorio del TURN (default: TURN_DIR; si no, el
#                        padre de scripts/ si contiene turnserver.conf, p. ej.
#                        /opt/coturn; si no, el turn/ del repo)
#   --domain NOMBRE      default turn.urbcerroazul.com
#   --email CORREO       contacto de Let's Encrypt (recomendado)
#   --webroot DIR        HTTP-01 por webroot (default /var/www/certbot)
#   --standalone         HTTP-01 con el servidor propio de certbot
#   --dns-ionos FICHERO  DNS-01 con IONOS (ini con dns_ionos_prefix/secret)
#   --selfsigned         certificado autofirmado (escenario B)
#   --ip IP              anade la IP como SAN al autofirmado
#   --days N             umbral de renovacion (default 30)
#   --staging            usar el entorno de pruebas de Let's Encrypt
#   --container NOMBRE   contenedor de coturn (default COTURN_CONTAINER o coturn)
#   --no-restart         no reiniciar coturn
#   --dry-run            mostrar lo que haria sin cambiar nada
#
# Ejemplos (en el servidor del TURN):
#   scripts/turn-cert.sh issue --selfsigned --turn-dir /opt/coturn --ip 203.0.113.7
#   scripts/turn-cert.sh issue --standalone --email ops@urbcerroazul.com --turn-dir /opt/coturn
#   scripts/turn-cert.sh renew --turn-dir /opt/coturn
#
# Idempotente: si el certificado instalado ya es identico al nuevo, no
# toca los ficheros ni reinicia coturn. No imprime secretos (la clave
# privada nunca sale por pantalla; de las credenciales IONOS solo la ruta).
# =====================================================================
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Directorio del TURN por defecto:
#   - script copiado en /opt/coturn/scripts/ (junto a turnserver.conf) -> /opt/coturn
#   - script dentro del repo (scripts/)                              -> <repo>/turn
if [ -z "${TURN_DIR:-}" ]; then
    if [ -f "${REPO_DIR}/turnserver.conf" ]; then
        TURN_DIR="$REPO_DIR"
    else
        TURN_DIR="${REPO_DIR}/turn"
    fi
fi
DOMAIN="${TURN_DOMAIN:-turn.urbcerroazul.com}"
EMAIL=""
METHOD="webroot"
WEBROOT="/var/www/certbot"
IONOS_CREDS=""
SAN_IP=""
DAYS=30
STAGING=0
CONTAINER="${COTURN_CONTAINER:-coturn}"
RESTART=1
DRY_RUN=0
SELFSIGNED_DAYS=365
# uid/gid del usuario 'nobody' con el que corre el contenedor de coturn.
OWNER="65534:65534"

log()  { printf '[turn-cert] %s\n' "$*"; }
warn() { printf '[turn-cert] AVISO: %s\n' "$*" >&2; }
die()  { printf '[turn-cert] ERROR: %s\n' "$*" >&2; exit 1; }

# Ejecuta un comando, o solo lo muestra en --dry-run.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

usage() {
    sed -n '/^# SUBCOMANDOS:/,/^# Idempotente/p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# --- argumentos -------------------------------------------------------
[ $# -ge 1 ] || usage 1
CMD="$1"; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --turn-dir)    TURN_DIR="${2:?falta valor}"; shift ;;
        --domain)      DOMAIN="${2:?falta valor}"; shift ;;
        --email)       EMAIL="${2:?falta valor}"; shift ;;
        --webroot)     METHOD="webroot"; WEBROOT="${2:?falta valor}"; shift ;;
        --standalone)  METHOD="standalone" ;;
        --dns-ionos)   METHOD="dns-ionos"; IONOS_CREDS="${2:?falta valor}"; shift ;;
        --selfsigned)  METHOD="selfsigned" ;;
        --ip)          SAN_IP="${2:?falta valor}"; shift ;;
        --days)        DAYS="${2:?falta valor}"; shift ;;
        --staging)     STAGING=1 ;;
        --container)   CONTAINER="${2:?falta valor}"; shift ;;
        --no-restart)  RESTART=0 ;;
        --dry-run)     DRY_RUN=1 ;;
        -h|--help)     usage 0 ;;
        *)             die "opcion desconocida: $1 (ver --help)" ;;
    esac
    shift
done

case "$DAYS" in ''|*[!0-9]*) die "--days debe ser un numero" ;; esac

CERT_DIR="${TURN_DIR}/certs"
CERT_FILE="${CERT_DIR}/turn_server_cert.pem"
KEY_FILE="${CERT_DIR}/turn_server_pkey.pem"
LE_LIVE="/etc/letsencrypt/live/${DOMAIN}"

need_root() {
    # chown a 65534 y escribir en /etc/letsencrypt exige root.
    if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
        die "hay que ejecutarlo como root (para chown ${OWNER} de la clave)"
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "falta '$1'. $2"
}

# --- utilidades de certificado ----------------------------------------
cert_expiry() {
    openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2
}

# true si el certificado caduca dentro de N dias (o no existe/no se lee)
expires_within() {
    local file="$1" days="$2"
    [ -f "$file" ] || return 0
    ! openssl x509 -checkend $((days * 86400)) -noout -in "$file" >/dev/null 2>&1
}

# Instala cert+clave en certs/ con los permisos que necesita el
# contenedor. Escritura atomica (fichero temporal + mv) para que coturn
# nunca vea un fichero a medias. Devuelve 0 si cambio algo, 1 si ya era
# identico (idempotencia: entonces no hace falta reiniciar).
install_pair() {
    local src_cert="$1" src_key="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] install -m 644 -o 65534 -g 65534 %s %s\n' "$src_cert" "$CERT_FILE"
        printf '[dry-run] install -m 600 -o 65534 -g 65534 %s %s\n' "$src_key" "$KEY_FILE"
        return 0
    fi
    # La clave y el certificado deben ser pareja: si no, coturn arranca
    # pero rechaza todos los handshakes TLS.
    local pub_c pub_k
    pub_c="$(openssl x509 -in "$src_cert" -noout -pubkey | openssl sha256)"
    pub_k="$(openssl pkey -in "$src_key" -pubout | openssl sha256)"
    [ "$pub_c" = "$pub_k" ] || die "el certificado y la clave no son pareja; no se instala nada"

    mkdir -p "$CERT_DIR"
    if cmp -s "$src_cert" "$CERT_FILE" && cmp -s "$src_key" "$KEY_FILE"; then
        # Igual de contenido; solo se corrigen permisos por si alguien los toco.
        chown "$OWNER" "$CERT_FILE" "$KEY_FILE"
        chmod 644 "$CERT_FILE"; chmod 600 "$KEY_FILE"
        log "el certificado instalado ya es el mismo: no se cambia nada"
        return 1
    fi
    install -m 644 -o 65534 -g 65534 "$src_cert" "${CERT_FILE}.new"
    install -m 600 -o 65534 -g 65534 "$src_key" "${KEY_FILE}.new"
    mv -f "${CERT_FILE}.new" "$CERT_FILE"
    mv -f "${KEY_FILE}.new" "$KEY_FILE"
    log "instalado ${CERT_FILE} (caduca: $(cert_expiry "$CERT_FILE"))"
    return 0
}

restart_coturn() {
    if [ "$RESTART" -eq 0 ]; then
        log "--no-restart: recuerda reiniciar coturn para que cargue el certificado"
        return 0
    fi
    # coturn lee el certificado al arrancar: hay que reiniciarlo.
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] docker restart %s\n' "$CONTAINER"
        return 0
    fi
    docker restart "$CONTAINER" >/dev/null
    log "coturn reiniciado (${CONTAINER})"
}

# Se comprueba ANTES de tocar los certificados: si el contenedor no
# existe, mejor no instalar nada que dejar un certificado nuevo que
# coturn no ha cargado.
check_container() {
    [ "$RESTART" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] || return 0
    command -v docker >/dev/null 2>&1 || die "falta docker (o usa --no-restart)"
    docker inspect "$CONTAINER" >/dev/null 2>&1 \
        || die "no existe el contenedor '${CONTAINER}' (usa --container o --no-restart)"
}

# --- emision -----------------------------------------------------------
issue_selfsigned() {
    need_cmd openssl "Instala openssl (apt install openssl)."
    local tmp san
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # se quiere expandir $tmp ahora
    trap "rm -rf '$tmp'" EXIT
    san="DNS:${DOMAIN}"
    [ -n "$SAN_IP" ] && san="${san},IP:${SAN_IP}"
    log "generando autofirmado para ${DOMAIN} (${SELFSIGNED_DAYS} dias, SAN ${san})"
    local ossl=(openssl req -x509 -newkey rsa:2048 -nodes -sha256
                -days "$SELFSIGNED_DAYS" -subj "/CN=${DOMAIN}"
                -addext "subjectAltName=${san}"
                -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem")
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] %s\n' "${ossl[*]}"
    # openssl escribe puntos de progreso en stderr: se guardan y solo se
    # muestran si falla (para que el log de cron quede limpio).
    elif ! "${ossl[@]}" 2>"${tmp}/openssl.err"; then
        cat "${tmp}/openssl.err" >&2
        die "openssl no pudo generar el certificado"
    fi
    # Un autofirmado nuevo siempre difiere del anterior: siempre "cambia".
    install_pair "${tmp}/cert.pem" "${tmp}/key.pem" || true
}

certbot_common_args() {
    CERTBOT_ARGS=(certonly --non-interactive --agree-tos --keep-until-expiring
                  --cert-name "$DOMAIN" -d "$DOMAIN")
    if [ -n "$EMAIL" ]; then
        CERTBOT_ARGS+=(--email "$EMAIL")
    else
        warn "sin --email: Let's Encrypt no podra avisar de problemas de renovacion"
        CERTBOT_ARGS+=(--register-unsafely-without-email)
    fi
    [ "$STAGING" -eq 1 ] && CERTBOT_ARGS+=(--staging)
    return 0
}

issue_letsencrypt() {
    if [ "$DRY_RUN" -eq 0 ]; then
        need_cmd certbot "Instala certbot (apt install certbot, o snap install --classic certbot)."
    fi
    certbot_common_args
    case "$METHOD" in
        webroot)
            [ "$DRY_RUN" -eq 1 ] || mkdir -p "${WEBROOT}/.well-known/acme-challenge"
            CERTBOT_ARGS+=(--webroot -w "$WEBROOT")
            log "HTTP-01 por webroot: el servidor web del puerto 80 debe servir ${WEBROOT}"
            ;;
        standalone)
            CERTBOT_ARGS+=(--standalone --preferred-challenges http)
            log "HTTP-01 standalone: certbot abrira el puerto 80 (debe estar libre y abierto en el firewall)"
            ;;
        dns-ionos)
            [ -f "$IONOS_CREDS" ] || die "no existe el fichero de credenciales IONOS: ${IONOS_CREDS}"
            # Las credenciales deben ser solo de root (certbot avisa si no).
            if [ "$(stat -c '%a' "$IONOS_CREDS")" != "600" ]; then
                warn "${IONOS_CREDS} deberia tener chmod 600"
            fi
            if [ "$DRY_RUN" -eq 0 ] && ! certbot plugins 2>/dev/null | grep -q 'dns-ionos'; then
                die "falta el plugin certbot-dns-ionos (pip install certbot-dns-ionos, o el snap del plugin)"
            fi
            CERTBOT_ARGS+=(--authenticator dns-ionos
                           --dns-ionos-credentials "$IONOS_CREDS"
                           --dns-ionos-propagation-seconds 90)
            log "DNS-01 con IONOS (credenciales: ${IONOS_CREDS}); recuerda: la zona hoy esta en Netim"
            ;;
    esac
    # El deploy-hook hace que certbot llame a 'deploy' tras CADA emision o
    # renovacion real (tambien las del timer automatico de certbot).
    CERTBOT_ARGS+=(--deploy-hook "$(hook_command)")
    run certbot "${CERTBOT_ARGS[@]}"
    # certbot con --keep-until-expiring no emite si no hace falta, y
    # entonces no llama al hook: se instala igualmente lo que haya en
    # live/ (idempotente: si ya es igual no se reinicia nada).
    deploy_from_lineage "$LE_LIVE"
}

# Copia fullchain/privkey de un "lineage" de certbot y reinicia si cambio.
deploy_from_lineage() {
    local lineage="$1"
    if [ "$DRY_RUN" -eq 0 ]; then
        [ -f "${lineage}/fullchain.pem" ] || die "no existe ${lineage}/fullchain.pem"
    fi
    # fullchain (no cert.pem): coturn debe enviar la cadena intermedia.
    if install_pair "${lineage}/fullchain.pem" "${lineage}/privkey.pem"; then
        restart_coturn
    fi
}

hook_command() {
    printf '%s deploy --turn-dir %s --domain %s --container %s' \
        "$SCRIPT_PATH" "$TURN_DIR" "$DOMAIN" "$CONTAINER"
}

# --- subcomandos ---------------------------------------------------------
cmd_issue() {
    need_root
    check_container
    if [ "$METHOD" = "selfsigned" ]; then
        issue_selfsigned
        restart_coturn
    else
        issue_letsencrypt
    fi
}

cmd_renew() {
    need_root
    if ! expires_within "$CERT_FILE" "$DAYS"; then
        # Silencioso a proposito (lo llama cron): solo una linea de log.
        log "vigente: caduca $(cert_expiry "$CERT_FILE") (umbral ${DAYS} dias); nada que hacer"
        return 0
    fi
    if [ -f "$CERT_FILE" ]; then
        log "caduca $(cert_expiry "$CERT_FILE"): menos de ${DAYS} dias, se renueva"
    else
        log "no hay certificado en ${CERT_FILE}: se emite"
    fi
    check_container
    # Si existe una emision de Let's Encrypt para el dominio, se renueva
    # esa; si no, se trata como escenario B (autofirmado).
    if [ -d "$LE_LIVE" ]; then
        need_cmd certbot "Instala certbot."
        # 1) Puede que el timer de certbot ya renovara y el hook no se
        #    ejecutara (p. ej. instalado despues): basta con desplegar.
        deploy_from_lineage "$LE_LIVE"
        # 2) Si aun asi caduca pronto, se fuerza la renovacion. Se fuerza
        #    porque el umbral lo decide este script (--days), no el de
        #    certbot; y solo se llega aqui si de verdad hace falta, para no
        #    gastar emisiones (Let's Encrypt limita 5 por semana y dominio).
        if [ "$DRY_RUN" -eq 1 ] || expires_within "$CERT_FILE" "$DAYS"; then
            run certbot renew --cert-name "$DOMAIN" --non-interactive \
                --force-renewal --deploy-hook "$(hook_command)"
            deploy_from_lineage "$LE_LIVE"
        fi
    else
        issue_selfsigned
        restart_coturn
    fi
    if [ "$DRY_RUN" -eq 0 ] && expires_within "$CERT_FILE" "$DAYS"; then
        die "tras renovar, el certificado sigue caducando en menos de ${DAYS} dias"
    fi
}

cmd_deploy() {
    need_root
    check_container
    # certbot exporta RENEWED_LINEAGE al ejecutar el deploy-hook.
    deploy_from_lineage "${RENEWED_LINEAGE:-$LE_LIVE}"
}

cmd_install_hook() {
    cat <<EOF
# -------------------------------------------------------------------
# Deploy-hook de certbot para el TURN (${DOMAIN})
#
# certbot ejecuta los scripts de /etc/letsencrypt/renewal-hooks/deploy/
# despues de CADA renovacion correcta (su timer systemd/cron renueva
# solo, ~30 dias antes de caducar). Este hook copia el certificado nuevo
# a ${CERT_DIR} con los permisos de nobody y reinicia coturn.
#
# Instalar (como root, en el servidor del TURN):
#
#   cat > /etc/letsencrypt/renewal-hooks/deploy/coturn.sh <<'HOOK'
#   #!/bin/sh
#   # Solo actua sobre el certificado del TURN.
#   case "\$RENEWED_LINEAGE" in
#     */live/${DOMAIN}) exec $(hook_command) ;;
#   esac
#   HOOK
#   chmod 755 /etc/letsencrypt/renewal-hooks/deploy/coturn.sh
#
# Alternativa equivalente (queda guardado en renewal/${DOMAIN}.conf):
#
#   certbot reconfigure --cert-name ${DOMAIN} \\
#       --deploy-hook "$(hook_command)"
#
# Probar sin emitir de verdad:
#   certbot renew --cert-name ${DOMAIN} --dry-run
#   (en --dry-run certbot NO ejecuta los deploy-hooks; para probar el
#    hook: RENEWED_LINEAGE=${LE_LIVE} $(hook_command))
# -------------------------------------------------------------------
EOF
}

cmd_status() {
    if [ ! -f "$CERT_FILE" ]; then
        log "no hay certificado en ${CERT_FILE}"
        return 1
    fi
    log "certificado: ${CERT_FILE}"
    log "  sujeto:  $(openssl x509 -subject -noout -in "$CERT_FILE" | cut -d= -f2-)"
    log "  emisor:  $(openssl x509 -issuer -noout -in "$CERT_FILE" | cut -d= -f2-)"
    log "  caduca:  $(cert_expiry "$CERT_FILE")"
    log "  permisos: $(stat -c '%a %u:%g' "$CERT_FILE") (cert) / $(stat -c '%a %u:%g' "$KEY_FILE") (clave)"
    if expires_within "$CERT_FILE" "$DAYS"; then
        warn "caduca en menos de ${DAYS} dias"
        return 1
    fi
}

[ "$DRY_RUN" -eq 1 ] && log "modo --dry-run: no se cambia nada"

case "$CMD" in
    issue)        cmd_issue ;;
    renew)        cmd_renew ;;
    deploy)       cmd_deploy ;;
    install-hook) cmd_install_hook ;;
    status)       cmd_status ;;
    -h|--help|help) usage 0 ;;
    *)            die "subcomando desconocido: ${CMD} (issue|renew|deploy|install-hook|status)" ;;
esac
