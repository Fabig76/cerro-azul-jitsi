#!/usr/bin/env bash
# =====================================================================
# backup-proyecto.sh - Respaldo de MIGRACION de Cerro Azul Jitsi
#
# Genera UN UNICO fichero  cerro-azul-jitsi-<AAAAMMDD-HHMM>.tar.gz  con
# todo lo necesario para levantar el proyecto en otro servidor siguiendo
# docs/RESTAURAR-EN-OTRO-SERVIDOR.md, lo verifica y lo sube a Google
# Drive con rclone.
#
# Contenido del .tar.gz:
#   MANIFEST.txt     fecha, host de origen, versiones de los contenedores,
#                    hashes, y QUE FALTA si algo no se pudo leer
#   SHA256SUMS       sumas de todos los ficheros del paquete
#   claro/           SIN secretos
#     repos/cerro-azul-jitsi.bundle       git bundle --all de este repo
#     repos/asambleas-virtuales.bundle    git bundle --all de la otra mitad
#     produccion/opt-jitsi-meet/          el deploy de prod SIN secretos
#                                         (compose, panel, plugins, scripts...)
#     caddy/meet.bytracking.net.caddy     SOLO el bloque de Jitsi del
#                                         Caddyfile del host
#     hermes/check-meet-jitsi.sh          watchdog + definicion del job
#     RESTAURAR-EN-OTRO-SERVIDOR.md       la guia, a mano
#   cifrado/
#     secretos.tar.gz.gpg   gpg simetrico AES256. Dentro (rutas relativas):
#       opt-jitsi-meet/.env
#       opt-jitsi-meet/admin-panel/instance/admin.env
#       opt-jitsi-meet/admin-panel/instance/reuniones.db (copia sqlite consistente)
#       opt-jitsi-meet/web/config/keys/
#       opt-jitsi-meet/prosody/config/certs/  y  prosody/config/data/
#       opt-jitsi-meet/jicofo/config/  y  jvb/config/
#       opt-coturn/{turnserver.conf,.secret,docker-compose.turn.yml,certs/}
#       hermes/secrets/turn.env
#       vps-root/.backup_passphrase   (passphrase de scripts/backup.sh del VPS)
#       LISTA.txt  SHA256SUMS
#
# REGLAS
#   - La passphrase se lee SOLO de la variable BACKUP_PASSPHRASE. Si no
#     esta (o tiene < 16 caracteres) el script ABORTA: nunca se genera un
#     respaldo con secretos en claro. Se pasa a gpg por un descriptor,
#     no por argumentos ni ficheros, y nunca se imprime.
#   - Los secretos en claro solo existen en un directorio 700 que se borra
#     al salir (tambien si hay error).
#   - Solo lee: no reinicia ni modifica nada en los servidores.
#
# DONDE SE EJECUTA
#   Pensado para el host de desarrollo (vmi3186036, como root): alli estan
#   el repo, rclone, el TURN, el watchdog de Hermes y la clave SSH de
#   chatbotph. Tambien funciona como el usuario chatbotph en el VPS (usa
#   sudo para lo que lo requiere): entonces lee /opt/jitsi-meet en local y
#   el TURN/Hermes por SSH (HOST_TURN, HOST_HERMES); necesita rclone
#   configurado o --sin-subir.
#
# USO
#   BACKUP_PASSPHRASE='...' scripts/backup-proyecto.sh [opciones]
#     --sin-subir        genera y verifica en local, no sube a Drive
#     --estricto         si falta algo, aborta antes de empaquetar
#     --salida DIR       donde dejar el .tar.gz (default /root/.cerro-azul-backup/proyecto)
#   Leer la passphrase de un fichero sin que aparezca en el historial:
#     BACKUP_PASSPHRASE="$(cat /root/.backup-proyecto-passphrase)" scripts/backup-proyecto.sh
#
# VARIABLES
#   HOST_JITSI   (chatbotph; "local" si se ejecuta como chatbotph)
#   HOST_TURN    (local en vmi3186036; si no, vmi3186036)
#   HOST_HERMES  (igual que HOST_TURN)
#   DRIVE_DESTINO (gdrive:BACKUP-cerro-azul-jitsi-2026-11-03)
#   REPO_ASAMBLEAS (Fabig76/asambleas-virtuales)
#
# SALIDA: 0 todo bien; 1 error; 2 paquete creado (y subido) pero FALTA algo
#         (ver MANIFEST.txt).
# =====================================================================
set -euo pipefail
umask 077

# ------------------------------------------------------------ opciones
SUBIR=1
ESTRICTO=0
SALIDA="${BACKUP_SALIDA:-/root/.cerro-azul-backup/proyecto}"
while [ $# -gt 0 ]; do
  case "$1" in
    --sin-subir) SUBIR=0 ;;
    --estricto)  ESTRICTO=1 ;;
    --salida)    SALIDA="$2"; shift ;;
    -h|--help)   sed -n '2,70p' "$0"; exit 0 ;;
    *) echo "Opcion desconocida: $1" >&2; exit 1 ;;
  esac
  shift
done

log()   { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fallo() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------ passphrase
if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
  cat >&2 <<'EOF'
ABORTADO: falta BACKUP_PASSPHRASE.
El paquete lleva secretos (.env, admin.env, claves TLS, cuentas XMPP, TURN)
y no se genera sin cifrar. Ejemplo:
  BACKUP_PASSPHRASE="$(cat /root/.backup-proyecto-passphrase)" scripts/backup-proyecto.sh
EOF
  exit 1
fi
[ "${#BACKUP_PASSPHRASE}" -ge 16 ] || fallo "BACKUP_PASSPHRASE tiene menos de 16 caracteres"
command -v gpg >/dev/null || fallo "falta gpg (apt-get install gnupg)"
[ "$SUBIR" = 0 ] || command -v rclone >/dev/null || fallo "falta rclone (o usa --sin-subir)"

# ------------------------------------------------------------ dónde está cada cosa
YO="$(id -un)"
[ "$YO" = root ] && SUDO="" || SUDO="sudo"
if [ "$YO" = chatbotph ]; then HOST_JITSI="${HOST_JITSI:-local}"; else HOST_JITSI="${HOST_JITSI:-chatbotph}"; fi
if [ "$(hostname)" = vmi3186036 ]; then DEF_TURN=local; else DEF_TURN=vmi3186036; fi
HOST_TURN="${HOST_TURN:-$DEF_TURN}"
HOST_HERMES="${HOST_HERMES:-$DEF_TURN}"
DEPLOY=/opt/jitsi-meet
CADDYFILE=/home/chatbotph/chatbotph/Caddyfile
DOMINIO=meet.bytracking.net
TURN_DIR=/opt/coturn
HERMES_DIR=/root/.hermes
WATCHDOG_JOB=62f0e5f5f4bd
DRIVE_DESTINO="${DRIVE_DESTINO:-gdrive:BACKUP-cerro-azul-jitsi-2026-11-03}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ASAMBLEAS="${REPO_ASAMBLEAS:-Fabig76/asambleas-virtuales}"

# en HOST CMD : ejecuta CMD (con sudo si hace falta) en HOST, o en local.
# Ojo: CMD no debe imprimir secretos salvo que la salida vaya a un fichero.
en() {
  local host="$1"; shift
  if [ "$host" = local ]; then
    $SUDO bash -c "$*"
  else
    # en remoto siempre con sudo (el usuario de SSH no es root)
    # shellcheck disable=SC2029
    ssh -o BatchMode=yes -o ConnectTimeout=20 "$host" "sudo bash -c $(printf '%q' "$*")" </dev/null
  fi
}

# ------------------------------------------------------------ directorio de trabajo
FECHA="$(date +%Y%m%d-%H%M)"
NOMBRE="cerro-azul-jitsi-$FECHA.tar.gz"
mkdir -p "$SALIDA"; chmod 700 "$SALIDA"
[ -e "$SALIDA/$NOMBRE" ] && fallo "$SALIDA/$NOMBRE ya existe (espera un minuto)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/backup-proyecto.XXXXXX")"
chmod 700 "$TMP"
limpiar() { rm -rf "$TMP"; }
trap limpiar EXIT
PAQ="$TMP/paquete"            # lo que acaba dentro del .tar.gz
CLARO="$PAQ/claro"
SEC="$TMP/secretos"           # secretos en claro (NUNCA sale de aqui sin cifrar)
mkdir -p "$CLARO" "$PAQ/cifrado" "$SEC"
FALTAN=()                     # "ruta: motivo"
falta() { FALTAN+=("$1"); log "  FALTA: $1"; }

# traer HOST BASE DESTINO RUTA... : copia rutas relativas a BASE conservando
# permisos (tar por SSH con sudo). Si una ruta no existe, la anota en FALTAN.
traer() {
  local host="$1" base="$2" dest="$3"; shift 3
  local r existe=()
  mkdir -p "$dest"
  for r in "$@"; do
    if en "$host" "test -e '$base/$r'"; then existe+=("$r"); else falta "$host:$base/$r (no existe o no se puede leer)"; fi
  done
  [ ${#existe[@]} -gt 0 ] || return 0
  local lista; lista="$(printf "'%s' " "${existe[@]}")"
  en "$host" "tar -C '$base' --exclude=__pycache__ --exclude='*.pyc' --exclude='*.sock' --exclude='*.pid' --numeric-owner -czf - $lista" \
    | tar -xzpf - -C "$dest" --numeric-owner \
    || falta "$host:$base ($* : error al copiar)"
}

log "Respaldo de migracion $NOMBRE"
log "Origen: jitsi=$HOST_JITSI turn=$HOST_TURN hermes=$HOST_HERMES; destino $DRIVE_DESTINO"

# =========================================================== a) repos
log "a) Repos (git bundle --all)..."
mkdir -p "$CLARO/repos"
git -C "$REPO" bundle create "$CLARO/repos/cerro-azul-jitsi.bundle" --all 2>/dev/null \
  || fallo "git bundle de $REPO"
REPO_HEAD="$(git -C "$REPO" rev-parse HEAD)"
REPO_SUCIO="$(git -C "$REPO" status --porcelain | wc -l)"
[ "$REPO_SUCIO" -eq 0 ] || log "  aviso: $REPO tiene $REPO_SUCIO cambio(s) sin commit (no van en el bundle)"

AV_HEAD="-"
if command -v gh >/dev/null && gh repo clone "$REPO_ASAMBLEAS" "$TMP/av.git" -- --mirror -q >/dev/null 2>&1; then
  git -C "$TMP/av.git" bundle create "$CLARO/repos/asambleas-virtuales.bundle" --all 2>/dev/null \
    && AV_HEAD="$(git -C "$TMP/av.git" rev-parse HEAD)" \
    || falta "repos/asambleas-virtuales.bundle (git bundle fallo)"
  rm -rf "$TMP/av.git"
else
  falta "repos/asambleas-virtuales.bundle (no se pudo clonar $REPO_ASAMBLEAS con gh)"
fi

# =========================================================== deploy sin secretos
log "b) Deploy de produccion sin secretos ($HOST_JITSI:$DEPLOY)..."
traer "$HOST_JITSI" "$DEPLOY" "$CLARO/produccion/opt-jitsi-meet" \
  docker-compose.yml .env.example .gitignore README.md \
  admin-panel/Dockerfile admin-panel/app admin-panel/README.md admin-panel/instance/admin.env.example \
  web/config/custom-config.js web/config/custom-interface_config.js \
  prosody/Dockerfile.prosody prosody/prosody-plugins-custom prosody/prosody-plugins \
  scripts infra turn docs integracion loadtest
if [ -f "$CLARO/produccion/opt-jitsi-meet/docker-compose.yml" ]; then
  if cmp -s "$CLARO/produccion/opt-jitsi-meet/docker-compose.yml" "$REPO/docker-compose.yml"; then
    COMPOSE_IGUAL="igual al del repo"
  else
    COMPOSE_IGUAL="DISTINTO al del repo (usar el de produccion/)"
  fi
else
  COMPOSE_IGUAL="no copiado"
fi

# =========================================================== Caddy (solo el bloque)
log "b) Bloque $DOMINIO del Caddyfile del host..."
mkdir -p "$CLARO/caddy"
if en "$HOST_JITSI" "cat '$CADDYFILE'" > "$TMP/Caddyfile.host" 2>/dev/null; then
  if python3 - "$TMP/Caddyfile.host" "$DOMINIO" > "$CLARO/caddy/$DOMINIO.caddy" <<'PY'
import re, sys
lineas = open(sys.argv[1], encoding="utf-8").read().splitlines()
dom = re.escape(sys.argv[2])
ini = next(i for i, l in enumerate(lineas) if re.match(r"^\s*" + dom + r"(\s*,[^{]*)?\s*\{\s*$", l))
# subir por el bloque de comentarios que lo precede
c = ini
while c > 0 and lineas[c - 1].lstrip().startswith("#"):
    c -= 1
prof, fin = 0, None
for j in range(ini, len(lineas)):
    s = lineas[j].split("#", 1)[0]
    prof += s.count("{") - s.count("}")
    if prof == 0:
        fin = j
        break
if fin is None:
    sys.exit("bloque sin cerrar")
print("\n".join(lineas[c:fin + 1]))
PY
  then
    log "  $(wc -l < "$CLARO/caddy/$DOMINIO.caddy") lineas"
  else
    rm -f "$CLARO/caddy/$DOMINIO.caddy"; falta "caddy/$DOMINIO.caddy (no se encontro el bloque en $CADDYFILE)"
  fi
  rm -f "$TMP/Caddyfile.host"
else
  falta "$HOST_JITSI:$CADDYFILE (no se pudo leer)"
fi

# =========================================================== Hermes (watchdog)
log "b) Watchdog de Hermes ($HOST_HERMES)..."
traer "$HOST_HERMES" "$HERMES_DIR" "$CLARO/hermes" scripts/check-meet-jitsi.sh
if en "$HOST_HERMES" "cat '$HERMES_DIR/cron/jobs.json'" 2>/dev/null \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
jobs = d if isinstance(d, list) else d.get("jobs", d)
jobs = jobs if isinstance(jobs, list) else list(jobs.values())
job = next((j for j in jobs if j.get("id") == sys.argv[1]), None)
if job is None: sys.exit(1)
for k in ("repeat","next_run_at","last_run_at","last_status","last_error",
          "last_delivery_error","state","paused_at","paused_reason"):
    job.pop(k, None)
print(json.dumps(job, indent=1, ensure_ascii=False))' "$WATCHDOG_JOB" > "$CLARO/hermes/hermes-job-watchdog.json"; then :
else
  rm -f "$CLARO/hermes/hermes-job-watchdog.json"; falta "hermes/hermes-job-watchdog.json (job $WATCHDOG_JOB no encontrado)"
fi

# la guia de restauracion, para no tener que clonar el bundle para leerla
cp "$REPO/docs/RESTAURAR-EN-OTRO-SERVIDOR.md" "$CLARO/" 2>/dev/null || falta "claro/RESTAURAR-EN-OTRO-SERVIDOR.md"

# =========================================================== SECRETOS
log "b) Secretos del deploy ($HOST_JITSI)..."
traer "$HOST_JITSI" "$DEPLOY" "$SEC/opt-jitsi-meet" \
  .env admin-panel/instance/admin.env web/config/keys \
  prosody/config/certs prosody/config/data jicofo/config jvb/config

# reuniones.db: copia consistente con la API de backup de sqlite (no cp en caliente)
mkdir -p "$SEC/opt-jitsi-meet/admin-panel/instance"
DB_TMP="/tmp/.reuniones-backup-$$.db"
if en "$HOST_JITSI" "umask 077; python3 -c '
import sqlite3
s = sqlite3.connect(\"file:$DEPLOY/admin-panel/instance/reuniones.db?mode=ro\", uri=True)
d = sqlite3.connect(\"$DB_TMP\")
s.backup(d); d.close(); s.close()' && cat '$DB_TMP'; rc=\$?; rm -f '$DB_TMP'; exit \$rc" \
   > "$SEC/opt-jitsi-meet/admin-panel/instance/reuniones.db" \
 && python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); assert c.execute("pragma integrity_check").fetchone()[0]=="ok"' \
      "$SEC/opt-jitsi-meet/admin-panel/instance/reuniones.db"; then
  REUNIONES="$(python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(", ".join("%s=%d" % (t, c.execute("select count(*) from \"%s\"" % t).fetchone()[0]) for (t,) in c.execute("select name from sqlite_master where type=\"table\" and name not like \"sqlite_%\"")))' "$SEC/opt-jitsi-meet/admin-panel/instance/reuniones.db")"
else
  rm -f "$SEC/opt-jitsi-meet/admin-panel/instance/reuniones.db"; REUNIONES="-"
  falta "$DEPLOY/admin-panel/instance/reuniones.db (copia sqlite fallida o no pasa integrity_check)"
fi

traer "$HOST_JITSI" /root "$SEC/vps-root" .backup_passphrase

log "b) TURN ($HOST_TURN:$TURN_DIR)..."
traer "$HOST_TURN" "$TURN_DIR" "$SEC/opt-coturn" turnserver.conf .secret docker-compose.turn.yml certs

log "b) Secreto del watchdog ($HOST_HERMES)..."
traer "$HOST_HERMES" "$HERMES_DIR" "$SEC/hermes" secrets/turn.env

# Comprobación de lo imprescindible (además de lo que traer() ya anotó)
for f in opt-jitsi-meet/.env opt-jitsi-meet/admin-panel/instance/admin.env \
         opt-jitsi-meet/web/config/keys/cert.key opt-jitsi-meet/web/config/keys/cert.crt \
         opt-jitsi-meet/jicofo/config/jicofo.conf opt-jitsi-meet/jvb/config/jvb.conf \
         opt-coturn/turnserver.conf hermes/secrets/turn.env; do
  [ -s "$SEC/$f" ] && continue
  ya=0; for x in "${FALTAN[@]}"; do case "$x" in *"${f#*/}"*|*"$(dirname "${f#*/}")"*) ya=1 ;; esac; done
  [ "$ya" = 1 ] || falta "$f (vacio o ausente)"
done
ls "$SEC"/opt-jitsi-meet/prosody/config/certs/*.key >/dev/null 2>&1 || falta "prosody/config/certs/*.key (no hay claves)"
[ -d "$SEC/opt-jitsi-meet/prosody/config/data/auth%2e${DOMINIO//./%2e}" ] \
  || falta "prosody/config/data/auth%2e${DOMINIO//./%2e} (cuentas focus@/jvb@)"

if [ "$ESTRICTO" = 1 ] && [ ${#FALTAN[@]} -gt 0 ]; then
  fallo "--estricto: faltan ${#FALTAN[@]} elemento(s); no se empaqueta"
fi

# lista + sumas DENTRO del bloque cifrado (nombres y hashes, nunca valores)
( cd "$SEC" && find . \( -type f -o -type l \) ! -name SHA256SUMS ! -name LISTA.txt | sort | sed 's|^\./||' > LISTA.txt
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )

# =========================================================== cifrar
log "Cifrando el bloque de secretos (gpg simetrico AES256)..."
export GNUPGHOME="$TMP/gnupg"; mkdir -m 700 "$GNUPGHOME"
gpg_cifrar() {
  gpg --batch --quiet --no-symkey-cache --pinentry-mode loopback --passphrase-fd 3 \
      --symmetric --cipher-algo AES256 --s2k-mode 3 --s2k-digest-algo SHA512 \
      --s2k-count 65011712 --compress-algo none "$@" 3< <(printf '%s' "$BACKUP_PASSPHRASE")
}
gpg_descifrar() {
  gpg --batch --quiet --no-symkey-cache --pinentry-mode loopback --passphrase-fd 3 \
      --decrypt "$@" 3< <(printf '%s' "$BACKUP_PASSPHRASE")
}
tar -C "$SEC" --numeric-owner -czf - . | gpg_cifrar -o "$PAQ/cifrado/secretos.tar.gz.gpg"
SEC_LISTA="$(cat "$SEC/LISTA.txt")"
SEC_SUMAS="$(cat "$SEC/SHA256SUMS")"
SEC_TAM="$(du -sh "$SEC" | cut -f1)"
rm -rf "$SEC"                                   # fuera los secretos en claro
# comprobar que se descifra antes de seguir
gpg_descifrar "$PAQ/cifrado/secretos.tar.gz.gpg" | tar -tzf - >/dev/null \
  || fallo "el bloque cifrado no se puede descifrar"

# =========================================================== MANIFEST
log "MANIFEST.txt y SHA256SUMS..."
versiones() {
  en "$HOST_JITSI" "docker inspect --format '{{.Name}}  {{.Config.Image}}  {{.Image}}  ({{.State.Status}}, desde {{.State.StartedAt}})' jitsi-web jitsi-prosody jitsi-jicofo jitsi-jvb jitsi-admin 2>/dev/null" \
    | sed 's|^/|  |' || echo "  (no se pudieron leer)"
  en "$HOST_TURN" "docker inspect --format '{{.Name}}  {{.Config.Image}}  {{.Image}}  ({{.State.Status}})' coturn 2>/dev/null" \
    | sed 's|^/|  |' || echo "  coturn: no se pudo leer"
}
{
  echo "CERRO AZUL JITSI - RESPALDO DE MIGRACION"
  echo "Paquete:   $NOMBRE"
  echo "Fecha:     $(date -Iseconds)"
  echo "Generado:  scripts/backup-proyecto.sh por $YO@$(hostname)"
  echo "Origen:    jitsi=$HOST_JITSI:$DEPLOY  turn=$HOST_TURN:$TURN_DIR  hermes=$HOST_HERMES:$HERMES_DIR"
  echo "Dominio:   $DOMINIO"
  echo
  echo "REPOS"
  echo "  cerro-azul-jitsi     HEAD $REPO_HEAD ($(git -C "$REPO" log -1 --format=%s))"
  echo "                       cambios sin commit al respaldar: $REPO_SUCIO"
  echo "  asambleas-virtuales  HEAD $AV_HEAD ($REPO_ASAMBLEAS)"
  echo "  docker-compose.yml de produccion: $COMPOSE_IGUAL"
  echo
  echo "CONTENEDORES (nombre  imagen  id de imagen)"
  versiones
  echo
  echo "REUNIONES (reuniones.db): $REUNIONES"
  echo
  echo "QUE FALTA"
  if [ ${#FALTAN[@]} -eq 0 ]; then echo "  nada: estan todos los elementos esperados"
  else printf '  - %s\n' "${FALTAN[@]}"; fi
  echo
  echo "BLOQUE CIFRADO  cifrado/secretos.tar.gz.gpg  ($SEC_TAM sin comprimir)"
  echo "  gpg simetrico AES256, s2k SHA512. Passphrase: NO esta aqui (gestor de"
  echo "  contrasenas del operador). Descifrar:"
  echo "    gpg --decrypt cifrado/secretos.tar.gz.gpg | tar -xzpf - -C secretos/"
  echo "  Ficheros que contiene (nombres, no valores):"
  printf '%s\n' "$SEC_LISTA" | sed 's|^|    |'
  echo "  sha256 de esos ficheros (antes de cifrar):"
  printf '%s\n' "$SEC_SUMAS" | sed 's|^|    |'
  echo
  echo "NO SE INCLUYE (a proposito): certificados de Let's Encrypt de Caddy (se"
  echo "reemiten solos), web/config generado (config.js...), imagenes Docker (se"
  echo "descargan/construyen), logs, .env.bak.*, /opt/jitsi-meet/backups, repo-sync,"
  echo "secretos y datos de asambleas-virtuales (otro servidor; solo va su codigo)."
  echo
  echo "RESTAURAR: claro/RESTAURAR-EN-OTRO-SERVIDOR.md"
  echo
  echo "FICHEROS EN CLARO"
  ( cd "$PAQ" && find claro cifrado -type f | sort | sed 's|^|  |' )
} > "$PAQ/MANIFEST.txt"

( cd "$PAQ" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum | sed 's|  \./|  |' > SHA256SUMS )

# =========================================================== empaquetar
log "Empaquetando..."
tar -C "$PAQ" -czf "$SALIDA/$NOMBRE.parcial" MANIFEST.txt SHA256SUMS claro cifrado
mv "$SALIDA/$NOMBRE.parcial" "$SALIDA/$NOMBRE"
chmod 600 "$SALIDA/$NOMBRE"
( cd "$SALIDA" && sha256sum "$NOMBRE" > "$NOMBRE.sha256" )
SHA="$(cut -d' ' -f1 "$SALIDA/$NOMBRE.sha256")"
TAM="$(stat -c %s "$SALIDA/$NOMBRE")"
rm -rf "$PAQ"
log "Creado $SALIDA/$NOMBRE ($TAM bytes, $(du -h "$SALIDA/$NOMBRE" | cut -f1)) sha256 $SHA"

# =========================================================== verificar
# verificar FICHERO : extrae, comprueba sumas, descifra, comprueba lo imprescindible
verificar() {
  local f="$1" v
  v="$(mktemp -d "$TMP/verif.XXXXXX")"
  tar -xzf "$f" -C "$v" || return 1
  ( cd "$v" && sha256sum -c --quiet SHA256SUMS ) || { echo "SHA256SUMS exterior no cuadra" >&2; return 1; }
  git clone -q "$v/claro/repos/cerro-azul-jitsi.bundle" "$v/clon" 2>/dev/null || { echo "bundle no clona" >&2; return 1; }
  [ "$(git -C "$v/clon" rev-parse HEAD)" = "$REPO_HEAD" ] || { echo "HEAD del bundle distinto" >&2; return 1; }
  if [ -f "$v/claro/repos/asambleas-virtuales.bundle" ]; then
    git clone -q "$v/claro/repos/asambleas-virtuales.bundle" "$v/clon-av" 2>/dev/null || { echo "bundle asambleas no clona" >&2; return 1; }
  fi
  mkdir -m 700 "$v/s"
  gpg_descifrar "$v/cifrado/secretos.tar.gz.gpg" | tar -xzf - -C "$v/s" || { echo "no se descifra" >&2; return 1; }
  ( cd "$v/s" && sha256sum -c --quiet SHA256SUMS ) || { echo "SHA256SUMS interior no cuadra" >&2; return 1; }
  rm -rf "$v"
}
log "Verificando el paquete local (sumas, bundles, descifrado)..."
verificar "$SALIDA/$NOMBRE" || fallo "la verificacion local ha fallado"
log "OK en local."

if [ "$SUBIR" = 0 ]; then
  log "--sin-subir: queda en $SALIDA/$NOMBRE"
else
  log "Subiendo a $DRIVE_DESTINO ..."
  rclone copy "$SALIDA/$NOMBRE" "$DRIVE_DESTINO/" || fallo "rclone copy $NOMBRE"
  rclone copy "$SALIDA/$NOMBRE.sha256" "$DRIVE_DESTINO/" || fallo "rclone copy $NOMBRE.sha256"
  TAM_DRIVE="$(rclone lsjson "$DRIVE_DESTINO/$NOMBRE" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["Size"])')"
  [ "$TAM_DRIVE" = "$TAM" ] || fallo "tamano en Drive ($TAM_DRIVE) != local ($TAM)"
  log "En Drive: $NOMBRE ($TAM_DRIVE bytes). Descargando para comprobar el viaje de vuelta..."
  mkdir -p "$TMP/bajada"
  rclone copy "$DRIVE_DESTINO/$NOMBRE" "$TMP/bajada/" || fallo "rclone no pudo descargar $NOMBRE"
  [ "$(sha256sum "$TMP/bajada/$NOMBRE" | cut -d' ' -f1)" = "$SHA" ] || fallo "lo descargado de Drive NO coincide (sha256)"
  verificar "$TMP/bajada/$NOMBRE" || fallo "lo descargado de Drive no se puede restaurar"
  rm -rf "$TMP/bajada"
  log "OK: Drive devuelve los mismos bytes (sha256 $SHA) y el paquete se descifra."
fi

if [ ${#FALTAN[@]} -gt 0 ]; then
  log "ATENCION: faltan ${#FALTAN[@]} elemento(s); ver 'QUE FALTA' en MANIFEST.txt"
  exit 2
fi
log "Hecho."
