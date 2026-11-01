#!/usr/bin/env bash
# =====================================================================
# prueba-3vps.sh - Prueba de carga distribuida
#
# DECISION DE SEGURIDAD:
#   chatbotph corre JITSI EN PRODUCCION. Aunque tiene 3.1 GB libres, no
#   se le mete carga: Chrome headless puede crecer sin control y tumbar
#   una asamblea real. Se usa solo como SERVIDOR BAJO PRUEBA, nunca como
#   generador de clientes.
#
#   Generadores: vps2938 (7.0 GB libres) y vmi3186036 (4.3 GB libres).
#
# Uso: prueba-3vps.sh <receptores_por_vps> <duracion_s> <recv_por_tab>
# =====================================================================
set -uo pipefail

REPO=/root/cerro-azul-jitsi
TORTURE=/root/jitsi-meet-torture
URL=https://meet.bytracking.net
JWT=$(cat /tmp/jwt-carga.txt)

POR_VPS="${1:-60}"
DURACION="${2:-180}"
RECV_TAB="${3:-6}"

# Slots conservadores: dejan margen para lo que ya corre en cada VPS.
declare -A SLOTS=( [vps2938]=12 [vmi3186036]=8 )
GENERADORES=( vps2938 vmi3186036 )

echo "==================================================="
echo " PRUEBA DISTRIBUIDA EN 2 VPS"
echo " Objetivo: $(( POR_VPS * 2 )) receptores"
echo "==================================================="
echo "  Servidor bajo prueba: chatbotph (NO genera carga)"
echo "  Generadores: ${GENERADORES[*]}"
echo

# ── 1. Levantar grid en cada generador ────────────────────────────
for H in "${GENERADORES[@]}"; do
    echo "--- $H: grid de ${SLOTS[$H]} slots ---"
    scp -q "$REPO/loadtest/docker-compose.selenium.yml" "$H:/tmp/sel.yml" 2>/dev/null
    ssh -o ConnectTimeout=15 "$H" "mkdir -p /opt/loadtest && mv /tmp/sel.yml /opt/loadtest/docker-compose.selenium.yml && cd /opt/loadtest && NODE_MAX_SESSIONS=${SLOTS[$H]} docker compose -f docker-compose.selenium.yml up -d 2>&1 | tail -2"
done

echo
echo "--- esperando grids (35 s) ---"
sleep 35

# ── 2. Tuneles ────────────────────────────────────────────────────
echo "--- tuneles SSH ---"
PORTS=(); I=0
for H in "${GENERADORES[@]}"; do
    P=$((4444 + I))
    ssh -o ConnectTimeout=15 -N -L "$P:localhost:4444" "$H" &
    TUNNEL_PIDS+=($!)
    echo "  $H -> localhost:$P"
    PORTS+=("$H:$P")
    I=$((I + 1))
done
sleep 6

# ── 3. Verificar grids ────────────────────────────────────────────
echo
echo "--- estado de los grids ---"
LISTOS=0
for entry in "${PORTS[@]}"; do
    H="${entry%%:*}"; P="${entry##*:}"
    curl -s --max-time 8 "http://127.0.0.1:$P/status" -o "/tmp/gs-$H.json" 2>/dev/null
    python3 -c "
import json
try:
    v = json.load(open('/tmp/gs-$H.json')).get('value', {})
    s = sum(n.get('maxSessions',0) for n in v.get('nodes',[]))
    print('  $H: ready=%s slots=%d' % (v.get('ready'), s))
except Exception:
    print('  $H: SIN RESPUESTA')
"
done

# ── 4. Metricas antes ─────────────────────────────────────────────
echo
echo "--- Jitsi antes de la prueba ---"
ssh -o ConnectTimeout=15 chatbotph 'cat /sys/class/net/eth0/statistics/tx_bytes' > /tmp/tx3-a.txt 2>/dev/null
ssh -o ConnectTimeout=15 chatbotph 'docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats' > /tmp/jf3-a.json 2>/dev/null

# ── 5. Lanzar en paralelo ─────────────────────────────────────────
echo
echo "--- lanzando Malleus en los 2 grids ---"
PIDS=()
for entry in "${PORTS[@]}"; do
    H="${entry%%:*}"; P="${entry##*:}"
    (
        cd "$TORTURE" || exit 1
        timeout $((DURACION + 900)) ./scripts/malleus.sh \
            --conferences=1 \
            --participants="$POR_VPS" \
            --senders=1 --audio-senders=1 \
            --duration="$DURACION" \
            --join-delay=1500 \
            --room-name-prefix=cargatest \
            --hub-url="http://127.0.0.1:$P/wd/hub" \
            --instance-url="$URL" \
            --headless --use-load-test \
            --receivers-per-tab="$RECV_TAB" \
            --extra-sender-params="jwt=$JWT" \
            --extra-receiver-params="jwt=$JWT" \
            > "/tmp/lt-${H}.log" 2>&1
        echo "  $H -> codigo $?"
    ) &
    PIDS+=($!)
done

echo "  esperando (~$((DURACION / 60 + 5)) min)..."
wait "${PIDS[@]}" 2>/dev/null

# ── 6. Resultados ─────────────────────────────────────────────────
echo
echo "==================================================="
echo " RESULTADOS"
echo "==================================================="
for H in "${GENERADORES[@]}"; do
    L="/tmp/lt-${H}.log"
    echo "--- $H ---"
    [ -f "$L" ] && grep -cE "lib-jitsi-meet version" "$L" 2>/dev/null | sed 's/^/  navegadores: /'
    [ -f "$L" ] && grep -E "Tests run:.*Failures" "$L" 2>/dev/null | tail -1 | sed 's/^/  /'
done

echo
echo "--- SERVIDOR DE JITSI ---"
ssh -o ConnectTimeout=15 chatbotph 'docker stats --no-stream --format "  {{.Name}} CPU {{.CPUPerc}} MEM {{.MemUsage}}" $(docker ps -q --filter name=jitsi)' 2>/dev/null
ssh -o ConnectTimeout=15 chatbotph 'docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats' > /tmp/jf3-b.json 2>/dev/null
python3 -c "
import json
try:
    d = json.load(open('/tmp/jf3-b.json'))
    print('  participantes alcanzados:', d.get('total_participants'))
    print('  mayor conferencia:', d.get('largest_conference'))
    print('  bridge_failures:', d.get('bridge_failures'))
except Exception as e:
    print('  sin datos:', e)
"

A=$(cat /tmp/tx3-a.txt 2>/dev/null | tr -d '[:space:]')
B=$(ssh -o ConnectTimeout=15 chatbotph 'cat /sys/class/net/eth0/statistics/tx_bytes' 2>/dev/null | tr -d '[:space:]')
[ -n "$A" ] && [ -n "$B" ] && [ "$B" -gt "$A" ] 2>/dev/null && echo "  trafico enviado: $(( (B-A)/1024/1024 )) MB"

echo
ssh -o ConnectTimeout=15 chatbotph 'docker logs jitsi-prosody --since 30m 2>&1 | grep -icE "error|rate.?limit|not.?authorized"' 2>/dev/null | sed 's/^/  errores en Prosody: /'

# ── 7. Limpieza ───────────────────────────────────────────────────
echo
echo "--- limpieza ---"
for p in "${TUNNEL_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
for H in "${GENERADORES[@]}"; do
    ssh -o ConnectTimeout=15 "$H" "cd /opt/loadtest && docker compose -f docker-compose.selenium.yml down 2>&1 | tail -1" 2>/dev/null
done
echo "  grids desmontados, tuneles cerrados"
