#!/usr/bin/env bash
# =====================================================================
# Prueba de carga apuntando al Grid REMOTO de vps2938
#
# El generador de clientes (Malleus) corre aqui, pero los navegadores
# viven en vps2938, que tiene 7 GB libres. Asi no se compite por la RAM
# del host donde se lanza el test.
#
# Uso: carga-remota.sh <receptores> <duracion_s> <join_delay_ms> <recv_por_tab>
# =====================================================================
set -uo pipefail

TORTURE=/root/jitsi-meet-torture
# El grid corre en vps2938 y se alcanza por un tunel SSH
# (ssh -N -L 4444:localhost:4444 vps2938), no por la IP publica:
# asi no hay que abrir el 4444 al mundo.
HUB=http://127.0.0.1:4444/wd/hub
URL=https://meet.bytracking.net
JWT=$(cat /tmp/jwt-carga.txt)
ROOM=cargatest0

PASO="${1:-100}"
DURACION="${2:-180}"
JOIN_DELAY="${3:-1000}"
RECV_POR_TAB="${4:-8}"

echo "==============================================="
echo " CARGA: ${PASO} receptores | 1 admin con audio"
echo "==============================================="
echo "  sala:      $ROOM"
echo "  grid:      $HUB (vps2938)"
echo "  duracion:  ${DURACION}s"
echo "  entrada:   ${JOIN_DELAY} ms"
echo "  recv/tab:  $RECV_POR_TAB"
echo

# Metricas ANTES
ssh -o ConnectTimeout=15 chatbotph 'docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats' > /tmp/jf-a.json 2>/dev/null
ssh -o ConnectTimeout=15 chatbotph 'cat /sys/class/net/eth0/statistics/tx_bytes' > /tmp/tx-a.txt 2>/dev/null

cd "$TORTURE" || exit 1
timeout $((DURACION + 1200)) ./scripts/malleus.sh \
    --conferences=1 \
    --participants="$PASO" \
    --senders=1 \
    --audio-senders=1 \
    --duration="$DURACION" \
    --join-delay="$JOIN_DELAY" \
    --room-name-prefix=cargatest \
    --hub-url="$HUB" \
    --instance-url="$URL" \
    --headless \
    --use-load-test \
    --receivers-per-tab="$RECV_POR_TAB" \
    --extra-sender-params="jwt=$JWT" \
    --extra-receiver-params="jwt=$JWT" \
    > "/tmp/loadtest-remoto-${PASO}.log" 2>&1
RC=$?

echo "  Malleus termino: codigo $RC"
echo "  log: /tmp/loadtest-remoto-${PASO}.log"

echo
echo "--- metricas del SERVIDOR ---"
ssh -o ConnectTimeout=15 chatbotph 'docker stats --no-stream --format "  {{.Name}} CPU {{.CPUPerc}} MEM {{.MemUsage}}" $(docker ps -q --filter name=jitsi)' 2>/dev/null

ssh -o ConnectTimeout=15 chatbotph 'docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats' > /tmp/jf-b.json 2>/dev/null
python3 -c "
import json
try:
    d = json.load(open('/tmp/jf-b.json'))
    print('  total_participants (acumulado):', d.get('total_participants'))
    print('  largest_conference alcanzada:  ', d.get('largest_conference'))
    print('  bridge_failures:               ', d.get('bridge_failures'))
except Exception as e:
    print('  sin datos de jicofo:', e)
"

echo
echo "--- ancho de banda enviado por el JVB durante la prueba ---"
A=$(cat /tmp/tx-a.txt 2>/dev/null | tr -d '[:space:]')
B=$(ssh -o ConnectTimeout=15 chatbotph 'cat /sys/class/net/eth0/statistics/tx_bytes' 2>/dev/null | tr -d '[:space:]')
if [ -n "$A" ] && [ -n "$B" ] && [ "$B" -gt "$A" ] 2>/dev/null; then
    echo "  enviado: $(( (B - A) / 1024 / 1024 )) MB"
fi

echo
echo "--- errores en Prosody ---"
ssh -o ConnectTimeout=15 chatbotph 'docker logs jitsi-prosody --since 20m 2>&1 | grep -icE "error|rate.?limit|not.?authorized"' 2>/dev/null | sed 's/^/  lineas con error: /'

echo
echo "--- resultado de Malleus ---"
grep -E "Tests run|Failures:|conference.*created|maximum.*participants" "/tmp/loadtest-remoto-${PASO}.log" 2>/dev/null | tail -6 | sed 's/^/  /'

echo "==============================================="
echo " FIN codigo $RC"
echo "==============================================="
