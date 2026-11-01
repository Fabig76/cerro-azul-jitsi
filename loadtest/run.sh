#!/usr/bin/env bash
# =====================================================================
# loadtest/run.sh - Envoltorio de Malleus para la prueba de 600 (Fase 7.3)
#
# Se ejecuta en la VM de CONTROL de la prueba (la que tiene el clon de
# jitsi-meet-torture y ve el Selenium Grid), NO en el servidor de Jitsi.
#
# POR DEFECTO NO LANZA NADA (--dry-run): hace las comprobaciones previas y
# muestra el comando de Malleus. Para lanzar de verdad: --run.
#
# Que hace:
#   1. Comprobaciones previas (todas de solo lectura):
#        - la web de Jitsi responde 200
#        - el JWT es para ESA sala, no ha caducado y dura toda la prueba
#        - el bridge esta operativo (operational_bridge_count >= 1) y el
#          JVB sano (/about/health)
#        - MAX_PARTICIPANTS del prosody en marcha >= participantes + 10
#          (si no, Prosody rechaza EN SILENCIO a partir del limite)
#        - el Selenium Grid responde y malleus.sh existe
#   2. Con --run: lanza Malleus y, en paralelo, cada --sample-every
#      segundos toma muestras del JVB (participantes, stress, perdida,
#      bitrate) y de CPU de jvb/prosody (docker stats).
#   3. Al terminar: guarda el log de prosody del periodo y genera la tabla
#      de resultados (loadtest/summarize.py) en results/<fecha>/summary.md
#
# Acceso al servidor de Jitsi (para el bridge y las metricas):
#   --server local           este script corre en el propio servidor
#   --server ssh:USER@HOST   via ssh (clave sin contrasena, BatchMode)
#   --server none            sin acceso: se omiten esas comprobaciones
#                            (solo vale para --dry-run)
#
# Uso tipico (ver loadtest/malleus-sala-prueba.md):
#   loadtest/run.sh --server ssh:root@meet.bytracking.net \
#       --hub http://grid.interno:4444/wd/hub --torture ~/jitsi-meet-torture \
#       --jwt-file ~/cargatest0.jwt                     # dry-run
#   loadtest/run.sh ... --participants 10 --duration 300 --run   # humo
#   loadtest/run.sh ... --run                                     # 600
#
# Opciones (default entre parentesis):
#   --instance URL (https://meet.bytracking.net)  --room-prefix P (cargatest)
#   --participants N (600) --conferences N (1) --senders N (1)
#   --audio-senders N (3)  --duration S (2700 = 45 min)
#   --join-delay MS (300: 600 clientes en 3 min; el cliente i entra en i*MS)
#   --hub URL (http://localhost:4444/wd/hub)  --torture DIR (~/jitsi-meet-torture)
#   --jwt-file F  --port-mbps N (1000)  --sample-every S (15)
#   --extra-sender-params S  --extra-receiver-params S
#   --no-lite-mode (por defecto se usa --use-lite-mode en los receptores)
#   --switch-speakers (los audio-senders hablan por turnos, como oradores rotando)
#   --results DIR (loadtest/results)  --summarize DIR (solo rehacer la tabla)
#
# El JWT no se imprime nunca: en el comando mostrado sale como <JWT>.
# =====================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTANCE="https://meet.bytracking.net"
ROOM_PREFIX="cargatest"
PARTICIPANTS=600
CONFERENCES=1
SENDERS=1
AUDIO_SENDERS=3
DURATION=2700
JOIN_DELAY=300
HUB="http://localhost:4444/wd/hub"
TORTURE="${HOME}/jitsi-meet-torture"
JWT_FILE=""
SERVER="none"
PORT_MBPS=1000
SAMPLE_EVERY=15
EXTRA_SENDER=""
EXTRA_RECEIVER=""
LITE=1
SWITCH=0
RESULTS_ROOT="${HERE}/results"
RUN=0
SUMMARIZE_ONLY=""

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --instance)              INSTANCE="${2:?}"; shift ;;
        --room-prefix)           ROOM_PREFIX="${2:?}"; shift ;;
        --participants)          PARTICIPANTS="${2:?}"; shift ;;
        --conferences)           CONFERENCES="${2:?}"; shift ;;
        --senders)               SENDERS="${2:?}"; shift ;;
        --audio-senders)         AUDIO_SENDERS="${2:?}"; shift ;;
        --duration)              DURATION="${2:?}"; shift ;;
        --join-delay)            JOIN_DELAY="${2:?}"; shift ;;
        --hub)                   HUB="${2:?}"; shift ;;
        --torture)               TORTURE="${2:?}"; shift ;;
        --jwt-file)              JWT_FILE="${2:?}"; shift ;;
        --server)                SERVER="${2:?}"; shift ;;
        --port-mbps)             PORT_MBPS="${2:?}"; shift ;;
        --sample-every)          SAMPLE_EVERY="${2:?}"; shift ;;
        --extra-sender-params)   EXTRA_SENDER="${2:?}"; shift ;;
        --extra-receiver-params) EXTRA_RECEIVER="${2:?}"; shift ;;
        --no-lite-mode)          LITE=0 ;;
        --switch-speakers)       SWITCH=1 ;;
        --results)               RESULTS_ROOT="${2:?}"; shift ;;
        --summarize)             SUMMARIZE_ONLY="${2:?}"; shift ;;
        --run)                   RUN=1 ;;
        --dry-run)               RUN=0 ;;
        -h|--help)               sed -n '2,/^# =====.*$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                       die "opcion desconocida: $1 (ver --help)" ;;
    esac
    shift
done

for v in PARTICIPANTS CONFERENCES SENDERS AUDIO_SENDERS DURATION JOIN_DELAY PORT_MBPS SAMPLE_EVERY; do
    case "${!v}" in ''|*[!0-9]*) die "--${v,,} debe ser un numero entero" ;; esac
done

if [ -n "$SUMMARIZE_ONLY" ]; then
    exec python3 -I "${HERE}/summarize.py" "$SUMMARIZE_ONLY"
fi

INSTANCE="${INSTANCE%/}"
# Malleus llama a la sala <prefijo><indice>: con 1 conferencia, '<prefijo>0'.
ROOM="${ROOM_PREFIX}0"

# --- acceso al servidor de Jitsi --------------------------------------------
case "$SERVER" in
    local|none) ;;
    ssh:*) SSH_TARGET="${SERVER#ssh:}" ;;
    *) die "--server debe ser local, none o ssh:USER@HOST" ;;
esac

# Ejecuta un comando en el servidor de Jitsi (local o por ssh).
srv() {
    if [ "$SERVER" = "local" ]; then
        "$@"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" "$(printf '%q ' "$@")"
    fi
}

# --- comprobaciones previas ---------------------------------------------------
CHECKS=()   # "ESTADO|comprobacion|detalle"
check() { CHECKS+=("$1|$2|$3"); }

# 1. La web responde
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${INSTANCE}/" || true)"
if [ "$code" = "200" ]; then check OK "web de Jitsi" "${INSTANCE}/ -> 200"
else check FALLA "web de Jitsi" "${INSTANCE}/ -> HTTP ${code:-sin respuesta}"; fi

# 2. El JWT: sala correcta y vigente durante toda la prueba
TOKEN=""
if [ -z "$JWT_FILE" ]; then
    check FALLA "JWT de la sala" "falta --jwt-file (generalo con loadtest/make-token.py)"
elif [ ! -r "$JWT_FILE" ]; then
    check FALLA "JWT de la sala" "no se puede leer ${JWT_FILE}"
else
    TOKEN="$(tr -d '[:space:]' < "$JWT_FILE")"
    [ "$(stat -c '%a' "$JWT_FILE")" = "600" ] || check AVISO "permisos del JWT" "${JWT_FILE} deberia tener chmod 600"
    # Margen: tiempo de entrada de todos + duracion + 15 min.
    need=$(( PARTICIPANTS * JOIN_DELAY / 1000 + DURATION + 900 ))
    jwt_check="$(TOKEN="$TOKEN" python3 -I - "$ROOM" "$need" <<'PYEOF'
import base64, json, os, sys, time
room, need = sys.argv[1], int(sys.argv[2])
try:
    seg = os.environ["TOKEN"].split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4)))
except Exception:
    print("FALLA|el fichero no contiene un JWT valido"); sys.exit()
now = time.time()
if claims.get("room") != room:
    print("FALLA|el JWT es para la sala %r y Malleus usara %r" % (claims.get("room"), room)); sys.exit()
left = claims.get("exp", 0) - now
if left < need:
    print("FALLA|el JWT caduca en %d min y la prueba necesita %d min" % (left // 60, need // 60)); sys.exit()
if claims.get("context", {}).get("user", {}).get("moderator"):
    print("AVISO|el JWT es de moderador; los clientes de carga deberian ser asistentes"); sys.exit()
print("OK|sala %s, caduca en %d min (necesarios %d)" % (room, left // 60, need // 60))
PYEOF
)"
    check "${jwt_check%%|*}" "JWT de la sala (la sala existe y se puede entrar)" "${jwt_check#*|}"
fi

# 3-5. Servidor: bridge, JVB, limite de participantes, rate limits
if [ "$SERVER" = "none" ]; then
    check AVISO "servidor de Jitsi" "--server none: sin comprobar bridge ni MAX_PARTICIPANTS (y sin metricas)"
else
    bc="$(srv docker exec jitsi-jicofo curl -s --max-time 10 http://127.0.0.1:8888/stats 2>/dev/null \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["bridge_selector"]["operational_bridge_count"])' 2>/dev/null || true)"
    if [ "${bc:-0}" -ge 1 ] 2>/dev/null; then check OK "bridge operativo" "operational_bridge_count=${bc}"
    else check FALLA "bridge operativo" "operational_bridge_count=${bc:-sin respuesta}"; fi

    jh="$(srv docker exec jitsi-jvb curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8080/about/health 2>/dev/null || true)"
    if [ "$jh" = "200" ]; then check OK "salud del JVB" "/about/health -> 200"
    else check FALLA "salud del JVB" "/about/health -> ${jh:-sin respuesta}"; fi

    mp="$(srv docker exec jitsi-prosody printenv MAX_PARTICIPANTS 2>/dev/null || true)"
    if [ -z "$mp" ]; then
        check FALLA "MAX_PARTICIPANTS" "no definido en prosody: Prosody aplica 200 por defecto"
    elif [ "$mp" -lt $(( PARTICIPANTS * CONFERENCES + 10 )) ] 2>/dev/null; then
        check FALLA "MAX_PARTICIPANTS" "vale ${mp}; hacen falta >= $(( PARTICIPANTS * CONFERENCES + 10 )) (clientes + admin + 3 dispositivos reales). Subirlo en el .env y recrear prosody"
    else
        check OK "MAX_PARTICIPANTS" "${mp}"
    fi

    rl="$(srv docker exec jitsi-prosody printenv PROSODY_ENABLE_RATE_LIMITS 2>/dev/null || true)"
    if [ "${rl:-0}" = "1" ] || [ "${rl:-0}" = "true" ]; then
        check AVISO "rate limits de Prosody" "ACTIVOS: anade las IP de las VMs de carga a PROSODY_RATE_LIMIT_ALLOW_RANGES o fallaran logins (3/s por IP)"
    else
        check OK "rate limits de Prosody" "desactivados (PROSODY_ENABLE_RATE_LIMITS=${rl:-0})"
    fi
fi

# 6. Selenium Grid (Grid 4: /status en la raiz; Grid 3: /wd/hub/status)
grid_ok=""
for u in "${HUB%/}/status" "${HUB%/wd/hub}/status"; do
    if curl -s --max-time 10 "$u" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get("value",d); sys.exit(0 if v.get("ready", d.get("status")==0) else 1)' 2>/dev/null; then
        grid_ok="$u"; break
    fi
done
if [ -n "$grid_ok" ]; then check OK "Selenium Grid" "${grid_ok} ready"
else check FALLA "Selenium Grid" "${HUB} no responde o no esta ready"; fi

# 7. Malleus
if [ -x "${TORTURE}/scripts/malleus.sh" ]; then check OK "malleus.sh" "${TORTURE}/scripts/malleus.sh"
else check FALLA "malleus.sh" "no existe ${TORTURE}/scripts/malleus.sh (git clone https://github.com/jitsi/jitsi-meet-torture)"; fi
if command -v mvn >/dev/null 2>&1; then check OK "maven" "$(command -v mvn)"
else check FALLA "maven" "falta mvn (malleus.sh lo usa: apt install maven + JDK 17)"; fi

# --- tabla de comprobaciones ------------------------------------------------
echo
echo "Comprobaciones previas (sala ${ROOM}, ${PARTICIPANTS} clientes):"
printf '  %-6s | %-48s | %s\n' "ESTADO" "COMPROBACION" "DETALLE"
printf '  %s\n' "-------+--------------------------------------------------+---------------------------"
n_fail=0
for c in "${CHECKS[@]}"; do
    IFS='|' read -r st name detail <<< "$c"
    printf '  %-6s | %-48s | %s\n' "$st" "$name" "$detail"
    [ "$st" = "FALLA" ] && n_fail=$((n_fail + 1))
done
echo

# --- comando de Malleus -------------------------------------------------------
# El JWT va en el fragmento de la URL (#jwt=...), igual que en los enlaces
# del panel. Se pasa por extra-*-params porque la opcion --jwt de
# malleus.sh (-Dorg.jitsi.token) no la lee el codigo de Malleus en la
# version actual de jitsi-meet-torture (VERIFICAR en la version usada).
join_params() { local a="$1" b="$2"; if [ -n "$a" ] && [ -n "$b" ]; then printf '%s&%s' "$a" "$b"; else printf '%s%s' "$a" "$b"; fi; }
SENDER_PARAMS="$(join_params "jwt=__JWT__" "$EXTRA_SENDER")"
RECEIVER_PARAMS="$(join_params "jwt=__JWT__" "$EXTRA_RECEIVER")"

MALLEUS=("${TORTURE}/scripts/malleus.sh"
    --conferences="$CONFERENCES" --participants="$PARTICIPANTS"
    --senders="$SENDERS" --audio-senders="$AUDIO_SENDERS"
    --duration="$DURATION" --join-delay="$JOIN_DELAY"
    --room-name-prefix="$ROOM_PREFIX" --hub-url="$HUB"
    --instance-url="$INSTANCE" --headless
    --extra-sender-params="$SENDER_PARAMS"
    --extra-receiver-params="$RECEIVER_PARAMS")
[ "$LITE" -eq 1 ] && MALLEUS+=(--use-lite-mode)
[ "$SWITCH" -eq 1 ] && MALLEUS+=(--switch-speakers)

shown="$(printf '%q ' "${MALLEUS[@]}")"
echo "Comando de Malleus:"
echo "  ${shown//__JWT__/<JWT>}"
echo "  (entrada: $(( PARTICIPANTS * JOIN_DELAY / 1000 )) s; duracion por cliente: ${DURATION} s)"
echo

if [ "$RUN" -ne 1 ]; then
    echo "[dry-run] no se ha lanzado nada. Revisa la tabla y repite con --run."
    [ "$n_fail" -eq 0 ] || exit 1
    exit 0
fi

# --- ejecucion real -----------------------------------------------------------
[ "$n_fail" -eq 0 ] || die "${n_fail} comprobacion(es) previas fallan: no se lanza Malleus"
[ "$SERVER" != "none" ] || die "--run necesita --server local|ssh:... para medir el resultado"

RES="${RESULTS_ROOT}/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RES"
chmod 700 "$RES"
cat > "${RES}/params.env" <<EOF
INSTANCE=${INSTANCE}
ROOM=${ROOM}
PARTICIPANTS=${PARTICIPANTS}
CONFERENCES=${CONFERENCES}
SENDERS=${SENDERS}
AUDIO_SENDERS=${AUDIO_SENDERS}
DURATION=${DURATION}
JOIN_DELAY=${JOIN_DELAY}
LITE_MODE=${LITE}
PORT_MBPS=${PORT_MBPS}
EOF
START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST_CPUS="$(srv nproc 2>/dev/null || echo 1)"

# Muestreo en segundo plano. Claves de /colibri/stats de JVB 2.3
# (VERIFICAR con: docker exec jitsi-jvb curl -s localhost:8080/colibri/stats).
sampler() {
    echo "ts,participants,conferences,stress_level,loss_pct,bitrate_up_kbps,jvb_cpu_pct,prosody_cpu_pct,host_cpus"
    while :; do
        stats="$(srv docker exec jitsi-jvb curl -s --max-time 5 http://localhost:8080/colibri/stats 2>/dev/null || true)"
        cpu="$(srv docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' jitsi-jvb jitsi-prosody 2>/dev/null || true)"
        STATS="$stats" CPU="$cpu" python3 -I - "$HOST_CPUS" <<'PYEOF' || true
import json, os, sys, time
try:
    s = json.loads(os.environ["STATS"] or "{}")
except ValueError:
    s = {}
cpu = {}
for line in os.environ["CPU"].splitlines():
    parts = line.split()
    if len(parts) == 2:
        cpu[parts[0]] = parts[1].rstrip("%")
def g(k):
    v = s.get(k)
    return "" if v is None else v
loss = [s.get(k) for k in ("incoming_loss", "outgoing_loss", "overall_loss") if s.get(k) is not None]
print(",".join(str(x) for x in [
    int(time.time()), g("participants"), g("conferences"), g("stress_level"),
    (max(loss) * 100) if loss else "", g("bit_rate_upload"),
    cpu.get("jitsi-jvb", ""), cpu.get("jitsi-prosody", ""), sys.argv[1]]))
PYEOF
        sleep "$SAMPLE_EVERY"
    done
}
sampler > "${RES}/samples.csv" 2>/dev/null &
SAMPLER_PID=$!
trap 'kill "$SAMPLER_PID" 2>/dev/null || true' EXIT

echo "Lanzando Malleus (log en ${RES}/malleus.log)..."
set +e
# El token sustituye al marcador solo en el array que se ejecuta.
"${MALLEUS[@]//__JWT__/${TOKEN}}" > "${RES}/malleus.log" 2>&1
MALLEUS_RC=$?
set -e
echo "MALLEUS_RC=${MALLEUS_RC}" >> "${RES}/params.env"
sleep "$SAMPLE_EVERY"   # una muestra mas tras la salida de los clientes
kill "$SAMPLER_PID" 2>/dev/null || true

srv docker logs --since "$START_ISO" jitsi-prosody > "${RES}/prosody.log" 2>&1 || true
# Por si Malleus dejo el token en su log (URL con #jwt=): se borra.
sed -i -E 's/(jwt=)[A-Za-z0-9_.-]+/\1<JWT>/g' "${RES}/malleus.log"

set +e
python3 -I "${HERE}/summarize.py" "$RES" | tee "${RES}/summary.md"
VERDICT=${PIPESTATUS[0]}
set -e
echo
echo "Resultados en ${RES} (malleus.log, samples.csv, prosody.log, summary.md)"
exit "$VERDICT"
