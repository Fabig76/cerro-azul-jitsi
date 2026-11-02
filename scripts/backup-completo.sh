#!/usr/bin/env bash
# =====================================================================
# backup-completo.sh - Copia de seguridad COMPLETA de Cerro Azul Jitsi
#                      en Google Drive (Fase 10)
#
# Se ejecuta EN EL HOST DE DESARROLLO (donde estan el repo, el watchdog
# de Hermes y las claves SSH de los dos servidores). Recoge todo lo
# necesario para reconstruir el proyecto en un servidor nuevo siguiendo
# docs/RESTAURAR.md, y lo sube a Drive en dos paquetes:
#
#   A) cerro-azul-jitsi-proyecto-<fecha>.tar.gz      (SIN cifrar, sin secretos)
#        repo/cerro-azul-jitsi.bundle   historial git completo (git bundle --all)
#        repo/arbol/                    arbol de trabajo (ficheros versionados
#                                       + no versionados no ignorados)
#        produccion/opt-jitsi-meet/     el deploy de chatbotph SIN secretos
#        produccion/Caddyfile           el Caddyfile del host (hermes-caddy)
#        watchdog/                      check-meet-jitsi.sh + definicion del job
#        MANIFIESTO.txt  SHA256SUMS
#
#   B) cerro-azul-jitsi-secretos-<fecha>.tar.gz.enc  (CIFRADO, AES-256-CBC)
#        opt-jitsi-meet/.env, admin-panel/instance/{admin.env,reuniones.db},
#        web/config/keys/, prosody/config/certs/
#        vps-root/.backup_passphrase
#        hermes/turn.env
#        turn-vps/{turnserver.conf,.secret,docker-compose.turn.yml,certs/}
#        CLAVE.txt  MANIFIESTO.txt  SHA256SUMS
#
# REGLAS:
#   - Si hay participantes en alguna sala, ABORTA sin tocar nada (la BD
#     de reuniones no se copia en caliente).
#   - El paquete de secretos SOLO sale de aqui cifrado. Los ficheros en
#     claro se montan en un directorio 700 y se borran al terminar.
#   - La clave NUNCA se imprime. Se lee de BACKUP_CLAVE (variable de
#     entorno) o de /root/.cerro-azul-backup/CLAVE.txt.
#   - No reinicia ni modifica nada en los servidores: solo lee.
#
# Uso:
#   scripts/backup-completo.sh [--sin-subir] [--sin-verificar] [--trabajo DIR]
#     --sin-subir      genera y verifica los paquetes en local, no sube a Drive
#     --sin-verificar  no descarga de Drive para comprobar el viaje de vuelta
#     --trabajo DIR    donde crear backup-<fecha>/ (default
#                      /root/.cerro-azul-backup/trabajo)
#
# Variables: BACKUP_CLAVE, DRIVE_CARPETA (default 1Ov4zUYBtyp01QLlDT8arobe29q6n8VuB),
#            HOST_JITSI (chatbotph), HOST_TURN (vmi3186036), REPO (este repo).
#
# Codigos de salida: 0 ok; 1 error; 3 abortado porque hay gente en las salas.
# =====================================================================
set -euo pipefail
umask 077

HOST_JITSI="${HOST_JITSI:-chatbotph}"
HOST_TURN="${HOST_TURN:-vmi3186036}"
DEPLOY=/opt/jitsi-meet
CADDYFILE=/home/chatbotph/chatbotph/Caddyfile
TURN_DIR=/opt/coturn
WATCHDOG=/root/.hermes/scripts/check-meet-jitsi.sh
WATCHDOG_JOB=62f0e5f5f4bd
HERMES_JOBS=/root/.hermes/cron/jobs.json
TURN_ENV=/root/.hermes/secrets/turn.env
CLAVE_FICHERO=/root/.cerro-azul-backup/CLAVE.txt
DRIVE_CARPETA="${DRIVE_CARPETA:-1Ov4zUYBtyp01QLlDT8arobe29q6n8VuB}"
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
TRABAJO="${BACKUP_TRABAJO:-/root/.cerro-azul-backup/trabajo}"
GAPI=(python "${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-workspace/scripts/google_api.py")

SUBIR=1
VERIFICAR=1
while [ $# -gt 0 ]; do
  case "$1" in
    --sin-subir) SUBIR=0 ;;
    --sin-verificar) VERIFICAR=0 ;;
    --trabajo) TRABAJO="$2"; shift ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "Opcion desconocida: $1" >&2; exit 1 ;;
  esac
  shift
done

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fallo() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- clave
CLAVE_TMP=""
limpiar() {
  [ -n "$CLAVE_TMP" ] && rm -f "$CLAVE_TMP"
  [ -n "${STAGE_B:-}" ] && [ -d "$STAGE_B" ] && rm -rf "$STAGE_B"
  [ -n "${VERIF:-}" ] && [ -d "$VERIF" ] && rm -rf "$VERIF"
  return 0
}
trap limpiar EXIT

if [ -n "${BACKUP_CLAVE:-}" ]; then
  CLAVE_TMP="$(mktemp)"; chmod 600 "$CLAVE_TMP"
  printf '%s' "$BACKUP_CLAVE" > "$CLAVE_TMP"
  CLAVE="$CLAVE_TMP"
elif [ -r "$CLAVE_FICHERO" ]; then
  CLAVE="$CLAVE_FICHERO"
else
  fallo "no hay clave: define BACKUP_CLAVE o crea $CLAVE_FICHERO (600)"
fi
[ "$(tr -d '\n' < "$CLAVE" | wc -c)" -ge 16 ] || fallo "la clave tiene menos de 16 caracteres"

cifrar()    { openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -md sha256 -pass "file:$CLAVE" "$@"; }
descifrar() { openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -pass "file:$CLAVE" "$@"; }

# ------------------------------------------- 0. nadie en las salas
log "Comprobando que no hay nadie en las salas ($HOST_JITSI)..."
STATS="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST_JITSI" \
  'docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats')" \
  || fallo "no se pudo leer /stats de jicofo; no se respalda a ciegas"
read -r PARTICIPANTES CONFERENCIAS < <(printf '%s' "$STATS" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(int(d["participants"]), int(d["conferences"]))') \
  || fallo "respuesta de /stats ilegible"
if [ "$PARTICIPANTES" -gt 0 ] || [ "$CONFERENCIAS" -gt 0 ]; then
  echo "ABORTADO: hay $PARTICIPANTES participante(s) en $CONFERENCIAS sala(s)." >&2
  echo "No se respalda la BD en caliente. Repite cuando las salas esten vacias." >&2
  exit 3
fi
log "Salas vacias (participants=0, conferences=0)."

# ------------------------------------------- directorio de trabajo
FECHA="$(date +%Y%m%d-%H%M)"
DIR="$TRABAJO/backup-$FECHA"
[ -e "$DIR" ] && fallo "$DIR ya existe (espera un minuto o borralo)"
mkdir -p "$DIR"; chmod 700 "$TRABAJO" "$DIR"
NOMBRE_A="cerro-azul-jitsi-proyecto-$FECHA.tar.gz"
NOMBRE_B="cerro-azul-jitsi-secretos-$FECHA.tar.gz.enc"
STAGE_A="$DIR/proyecto"
STAGE_B="$DIR/secretos"
mkdir -p "$STAGE_A" "$STAGE_B"
log "Trabajo en $DIR"

# remoto_tar HOST DIR_BASE DESTINO RUTA... : copia rutas relativas a DIR_BASE
# (con sudo, conservando permisos), sin __pycache__/*.pyc.
remoto_tar() {
  local host="$1" base="$2" dest="$3"; shift 3
  mkdir -p "$dest"
  # shellcheck disable=SC2029
  ssh -o BatchMode=yes "$host" "sudo tar -C '$base' --exclude=__pycache__ --exclude='*.pyc' -czf - $*" \
    | tar -xzpf - -C "$dest"
}

# =================================================== PAQUETE A
log "Paquete A: repo (bundle + arbol de trabajo)..."
mkdir -p "$STAGE_A/repo/arbol"
git -C "$REPO" bundle create "$STAGE_A/repo/cerro-azul-jitsi.bundle" --all 2>/dev/null
git -C "$REPO" bundle verify "$STAGE_A/repo/cerro-azul-jitsi.bundle" >/dev/null 2>&1 \
  || fallo "git bundle verify ha fallado"
# Solo lo que git ve (versionado + no versionado no ignorado): asi quedan
# fuera __pycache__, .venv, node_modules y cualquier secreto local ignorado.
( cd "$REPO" && git ls-files -z --cached --others --exclude-standard \
    | grep -zvE '(^|/)(__pycache__|\.venv|node_modules)/|\.pyc$' \
    | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf - ) | tar -xpf - -C "$STAGE_A/repo/arbol"
REPO_HEAD="$(git -C "$REPO" rev-parse HEAD)"
REPO_SUCIO="$(git -C "$REPO" status --porcelain | wc -l)"

log "Paquete A: deploy de produccion sin secretos..."
remoto_tar "$HOST_JITSI" "$DEPLOY" "$STAGE_A/produccion/opt-jitsi-meet" \
  docker-compose.yml .env.example .gitignore README.md \
  admin-panel/Dockerfile admin-panel/app admin-panel/README.md admin-panel/instance/admin.env.example \
  web/config/custom-config.js web/config/custom-interface_config.js \
  prosody/Dockerfile.prosody prosody/prosody-plugins-custom prosody/prosody-plugins \
  scripts infra turn docs
log "Paquete A: Caddyfile del host..."
ssh -o BatchMode=yes "$HOST_JITSI" "cat '$CADDYFILE'" > "$STAGE_A/produccion/Caddyfile"
[ -s "$STAGE_A/produccion/Caddyfile" ] || fallo "Caddyfile vacio"

log "Paquete A: watchdog de Hermes..."
mkdir -p "$STAGE_A/watchdog"
cp -p "$WATCHDOG" "$STAGE_A/watchdog/"
python3 - "$HERMES_JOBS" "$WATCHDOG_JOB" > "$STAGE_A/watchdog/hermes-job-watchdog.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
jobs = d if isinstance(d, list) else d.get("jobs", d)
jobs = jobs if isinstance(jobs, list) else list(jobs.values())
job = next((j for j in jobs if j.get("id") == sys.argv[2]), None)
for k in ("repeat", "next_run_at", "last_run_at", "last_status", "last_error",
          "last_delivery_error", "state", "paused_at", "paused_reason"):
    (job or {}).pop(k, None)
print(json.dumps(job, indent=1, ensure_ascii=False))
PY

# =================================================== PAQUETE B
log "Paquete B: secretos del deploy..."
# reuniones.db: copia consistente con la API de backup de sqlite (no cp).
ssh -o BatchMode=yes "$HOST_JITSI" "sudo python3 -c '
import sqlite3, sys
s = sqlite3.connect(\"file:$DEPLOY/admin-panel/instance/reuniones.db?mode=ro\", uri=True)
d = sqlite3.connect(\"/tmp/.reuniones-backup.db\")
s.backup(d); d.close(); s.close()
' && sudo chmod 600 /tmp/.reuniones-backup.db"
remoto_tar "$HOST_JITSI" "$DEPLOY" "$STAGE_B/opt-jitsi-meet" \
  .env admin-panel/instance/admin.env web/config/keys prosody/config/certs
ssh -o BatchMode=yes "$HOST_JITSI" "sudo cat /tmp/.reuniones-backup.db && sudo rm -f /tmp/.reuniones-backup.db" \
  > "$STAGE_B/opt-jitsi-meet/admin-panel/instance/reuniones.db"
chmod 600 "$STAGE_B/opt-jitsi-meet/admin-panel/instance/reuniones.db"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); assert c.execute("pragma integrity_check").fetchone()[0]=="ok"' \
  "$STAGE_B/opt-jitsi-meet/admin-panel/instance/reuniones.db" || fallo "reuniones.db copiada no pasa integrity_check"

remoto_tar "$HOST_JITSI" /root "$STAGE_B/vps-root" .backup_passphrase
log "Paquete B: secretos del TURN ($HOST_TURN)..."
remoto_tar "$HOST_TURN" "$TURN_DIR" "$STAGE_B/turn-vps" \
  turnserver.conf .secret docker-compose.turn.yml certs
mkdir -p "$STAGE_B/hermes"
cp -p "$TURN_ENV" "$STAGE_B/hermes/turn.env"
cp "$CLAVE" "$STAGE_B/CLAVE.txt"; chmod 600 "$STAGE_B/CLAVE.txt"

# Comprobar que esta todo lo que tiene que estar
FALTAN=()
for f in opt-jitsi-meet/.env opt-jitsi-meet/admin-panel/instance/admin.env \
         opt-jitsi-meet/admin-panel/instance/reuniones.db \
         opt-jitsi-meet/web/config/keys/cert.key opt-jitsi-meet/web/config/keys/cert.crt \
         vps-root/.backup_passphrase hermes/turn.env \
         turn-vps/turnserver.conf turn-vps/.secret turn-vps/docker-compose.turn.yml CLAVE.txt; do
  [ -s "$STAGE_B/$f" ] || FALTAN+=("$f")
done
ls "$STAGE_B/opt-jitsi-meet/prosody/config/certs/"*.key >/dev/null 2>&1 || FALTAN+=("prosody/config/certs/*.key")
[ ${#FALTAN[@]} -eq 0 ] || fallo "faltan secretos: ${FALTAN[*]}"

# =================================================== manifiestos
tamano() { du -sh "$1" | cut -f1; }
{
  echo "CERRO AZUL JITSI - PAQUETE A: PROYECTO (sin secretos)"
  echo "Fecha: $(date -Iseconds)   Generado por: scripts/backup-completo.sh en $(hostname)"
  echo "Repo: HEAD $REPO_HEAD ($(git -C "$REPO" log -1 --format=%s)); cambios sin commit: $REPO_SUCIO"
  echo
  echo "CONTENIDO"
  echo "  repo/cerro-azul-jitsi.bundle   $(tamano "$STAGE_A/repo/cerro-azul-jitsi.bundle")  historial git completo (todas las ramas)"
  echo "  repo/arbol/                    $(tamano "$STAGE_A/repo/arbol")  arbol de trabajo tal cual estaba"
  echo "  produccion/opt-jitsi-meet/     $(tamano "$STAGE_A/produccion/opt-jitsi-meet")  $HOST_JITSI:$DEPLOY sin secretos"
  echo "  produccion/Caddyfile           $(tamano "$STAGE_A/produccion/Caddyfile")  $HOST_JITSI:$CADDYFILE"
  echo "  watchdog/                      $(tamano "$STAGE_A/watchdog")  $WATCHDOG + job Hermes $WATCHDOG_JOB"
  echo
  echo "NO INCLUYE (a proposito): .env, admin.env, reuniones.db, certificados y"
  echo "claves -> van en el paquete B cifrado. Tampoco: __pycache__, *.pyc, .venv,"
  echo "node_modules, la config generada por los contenedores (se regenera), las"
  echo "bases de datos de Prometheus ni la imagen del TURN (se descarga)."
  echo
  echo "RESTAURAR (resumen; guia completa en repo/arbol/docs/RESTAURAR.md)"
  echo "  git clone cerro-azul-jitsi.bundle cerro-azul-jitsi"
  echo "  -> descifrar el paquete B, colocar secretos, docker compose up -d --build"
  echo
  echo "FICHEROS"
  ( cd "$STAGE_A" && find . -type f | sort | sed 's|^\./|  |' )
} > "$STAGE_A/MANIFIESTO.txt"

{
  echo "CERRO AZUL JITSI - PAQUETE B: SECRETOS Y DATOS (cifrado)"
  echo "Fecha: $(date -Iseconds)   Generado por: scripts/backup-completo.sh en $(hostname)"
  echo
  echo "CONTENIDO -> DESTINO AL RESTAURAR (permisos)"
  echo "  opt-jitsi-meet/.env                               -> /opt/jitsi-meet/.env (600)"
  echo "  opt-jitsi-meet/admin-panel/instance/admin.env     -> /opt/jitsi-meet/admin-panel/instance/admin.env (600)"
  echo "  opt-jitsi-meet/admin-panel/instance/reuniones.db  -> /opt/jitsi-meet/admin-panel/instance/reuniones.db (644)"
  echo "  opt-jitsi-meet/web/config/keys/                   -> /opt/jitsi-meet/web/config/keys/ (cert.key 600)"
  echo "  opt-jitsi-meet/prosody/config/certs/              -> /opt/jitsi-meet/prosody/config/certs/ (*.key 400)"
  echo "  vps-root/.backup_passphrase                       -> /root/.backup_passphrase en el VPS de Jitsi (600)"
  echo "  hermes/turn.env                                   -> /root/.hermes/secrets/turn.env en el host del watchdog (600)"
  echo "  turn-vps/turnserver.conf, .secret,                -> /opt/coturn/ en el VPS del TURN"
  echo "    docker-compose.turn.yml, certs/"
  echo "  CLAVE.txt                                         la clave de este paquete (copia; guardala FUERA)"
  echo
  echo "Tamanos: opt-jitsi-meet $(tamano "$STAGE_B/opt-jitsi-meet"), turn-vps $(tamano "$STAGE_B/turn-vps")"
  echo
  echo "DESCIFRAR"
  echo "  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \\"
  echo "    -pass file:CLAVE.txt -in $NOMBRE_B -out secretos.tar.gz"
  echo "  tar xzpf secretos.tar.gz"
  echo "Guia completa: docs/RESTAURAR.md (en el paquete A)."
  echo
  echo "FICHEROS"
  ( cd "$STAGE_B" && find . -type f | sort | sed 's|^\./|  |' )
} > "$STAGE_B/MANIFIESTO.txt"

for s in "$STAGE_A" "$STAGE_B"; do
  ( cd "$s" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
done

# =================================================== empaquetar
log "Empaquetando..."
tar -C "$STAGE_A" -czf "$DIR/$NOMBRE_A" .
tar -C "$STAGE_B" -czf - . | cifrar -out "$DIR/$NOMBRE_B"
rm -rf "$STAGE_A" "$STAGE_B"
chmod 600 "$DIR/$NOMBRE_A" "$DIR/$NOMBRE_B"
( cd "$DIR" && sha256sum "$NOMBRE_A" "$NOMBRE_B" > SHA256SUMS.paquetes )

# =================================================== verificar en local
verificar_paquetes() {  # verificar_paquetes DIR_CON_LOS_DOS_PAQUETES
  local d="$1" v
  v="$(mktemp -d)"; VERIF="$v"
  mkdir -p "$v/a" "$v/b"
  tar -xzf "$d/$NOMBRE_A" -C "$v/a" || return 1
  ( cd "$v/a" && sha256sum -c --quiet SHA256SUMS ) || return 1
  # "git bundle verify" exige estar dentro de un repo: se usa uno vacio
  git init -q "$v/vacio" && git -C "$v/vacio" bundle verify "$v/a/repo/cerro-azul-jitsi.bundle" >/dev/null 2>&1 || return 1
  git clone -q "$v/a/repo/cerro-azul-jitsi.bundle" "$v/clon" 2>/dev/null || return 1
  [ "$(git -C "$v/clon" rev-parse HEAD)" = "$REPO_HEAD" ] || return 1
  descifrar -in "$d/$NOMBRE_B" | tar -xzf - -C "$v/b" || return 1
  ( cd "$v/b" && sha256sum -c --quiet SHA256SUMS ) || return 1
  rm -rf "$v"; VERIF=""
}
log "Verificando los paquetes en local (extraer, sha256, bundle, descifrar)..."
verificar_paquetes "$DIR" || fallo "la verificacion local de los paquetes ha fallado"
log "OK: $NOMBRE_A ($(tamano "$DIR/$NOMBRE_A")), $NOMBRE_B ($(tamano "$DIR/$NOMBRE_B"))"

if [ "$SUBIR" = 0 ]; then
  log "--sin-subir: paquetes en $DIR"
  exit 0
fi

# =================================================== subir a Drive
subir() {  # subir FICHERO -> imprime el id
  "${GAPI[@]}" drive upload "$DIR/$1" --name "$1" --parent "$DRIVE_CARPETA" \
       --mime-type application/octet-stream 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
}
log "Subiendo a Drive (carpeta $DRIVE_CARPETA)..."
ID_A="$(subir "$NOMBRE_A")" || fallo "fallo al subir $NOMBRE_A"
ID_B="$(subir "$NOMBRE_B")" || fallo "fallo al subir $NOMBRE_B"
log "Subido: $NOMBRE_A -> https://drive.google.com/file/d/$ID_A/view"
log "Subido: $NOMBRE_B -> https://drive.google.com/file/d/$ID_B/view"
printf '%s %s\n%s %s\n' "$ID_A" "$NOMBRE_A" "$ID_B" "$NOMBRE_B" > "$DIR/DRIVE_IDS.txt"

# =================================================== viaje de vuelta
if [ "$VERIFICAR" = 1 ]; then
  log "Descargando de Drive para verificar el viaje de vuelta..."
  BAJADA="$DIR/descarga-drive"; mkdir -p "$BAJADA"
  "${GAPI[@]}" drive download "$ID_A" --output "$BAJADA/$NOMBRE_A" >/dev/null 2>&1
  "${GAPI[@]}" drive download "$ID_B" --output "$BAJADA/$NOMBRE_B" >/dev/null 2>&1
  ( cd "$BAJADA" && sha256sum -c --quiet ../SHA256SUMS.paquetes ) \
    || fallo "lo descargado de Drive NO coincide con lo subido"
  verificar_paquetes "$BAJADA" || fallo "lo descargado de Drive no se puede restaurar"
  for id in "$ID_A" "$ID_B"; do
    "${GAPI[@]}" drive get "$id" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); c = sys.argv[1]
assert c in d.get("parents", []), "no esta en la carpeta"
print("  en Drive:", d["name"], "(carpeta ok)")' "$DRIVE_CARPETA" || fallo "drive get $id"
  done
  rm -rf "$BAJADA"
  log "OK: Drive devuelve los mismos bytes y los paquetes se restauran."
fi

log "Hecho. Paquetes locales en $DIR (600). IDs en $DIR/DRIVE_IDS.txt"
