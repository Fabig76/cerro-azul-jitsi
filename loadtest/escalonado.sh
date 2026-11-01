#!/usr/bin/env bash
# =====================================================================
# Prueba de carga escalonada (Fase 7.3)
#
# Estrategia: empezar con pocos clientes para validar que el pipeline
# funciona (grid + malleus + JWT), y subir solo si el anterior paso va
# bien. Los receptores van en modo load-test, con varios por navegador,
# porque no hay RAM para 600 Chrome.
#
# Cada paso escribe su salida en /tmp/loadtest-<paso>.log
# =====================================================================
set -uo pipefail

TORTURE=/root/jitsi-meet-torture
REPO=/root/cerro-azul-jitsi
HUB=http://localhost:4444/wd/hub
URL=https://meet.bytracking.net
JWT=$(cat /tmp/jwt-carga.txt)
ROOM=cargatest0

# Cuantos clientes por paso (receptores). Senders: 1 admin con audio.
PASO="${1:-10}"
DURACION="${2:-120}"      # segundos de conversacion por cliente
JOIN_DELAY="${3:-3000}"   # ms entre entradas
RECV_POR_TAB="${4:-5}"    # receptores dentro de cada navegador

echo "==============================================="
echo " PRUEBA DE CARGA - ${PASO} receptores"
echo "==============================================="
echo "  sala:       $ROOM"
echo "  grid:       $HUB"
echo "  duracion:   ${DURACION}s"
echo "  entrada:    ${JOIN_DELAY} ms entre clientes"
echo "  recibidores por navegador: $RECV_POR_TAB"
echo

# Comprobacion previa: el grid responde y tiene slots libres
curl -s --max-time 10 "$HUB/status" -o /tmp/grid-antes.json 2>/dev/null
python3 -c "
import json
d = json.load(open('/tmp/grid-antes.json'))
v = d.get('value', {})
libres = sum(1 for n in v.get('nodes', []) for s in n.get('slots', []) if not s.get('session'))
print('  grid ready:', v.get('ready'), '| slots libres:', libres)
" 2>/dev/null || echo "  AVISO: no se pudo leer el estado del grid"

# Metricas del servidor ANTES
echo
echo "--- JVB antes ---"
ssh -o ConnectTimeout=15 chatbotph 'docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats' > /tmp/jicofo-antes.json 2>/dev/null
ssh -o ConnectTimeout=15 chatbotph 'docker stats --no-stream --format "{{.Name}} {{.CPUPerc}} {{.MemUsage}}" $(docker ps -q --filter name=jitsi)' > /tmp/stats-antes.txt 2>/dev/null
cat /tmp/stats-antes.txt 2>/dev/null | sed 's/^/  /'

echo
echo "--- lanzando Malleus ---"
cd "$TORTURE" || exit 1
timeout $((DURACION + 900)) ./scripts/malleus.sh \
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
    > "/tmp/loadtest-${PASO}.log" 2>&1
RC=$?

echo "  malleus termino con codigo $RC"
echo "  log: /tmp/loadtest-${PASO}.log ($(wc -l < "/tmp/loadtest-${PASO}.log") lineas)"

echo
echo "--- resumen de Malleus ---"
grep -iE "conference|participant|failed|error|stats|delay|loss" "/tmp/loadtest-${PASO}.log" 2>/dev/null | tail -20 | sed 's/^/  /'

echo
echo "--- metricas del servidor DESPUES ---"
ssh -o ConnectTimeout=15 chatbotph 'docker stats --no-stream --format "{{.Name}} {{.CPUPerc}} {{.MemUsage}}" $(docker ps -q --filter name=jitsi)' > /tmp/stats-despues.txt 2>/dev/null
cat /tmp/stats-despues.txt 2>/dev/null | sed 's/^/  /'

echo
echo "--- errores en Prosody (ultimos 5 min) ---"
ssh -o ConnectTimeout=15 chatbotph 'docker logs jitsi-prosody --since 5m 2>&1 | grep -icE "error|rate.?limit|not.?authorized"' 2>/dev/null | sed 's/^/  lineas con error: /'

echo
echo "==============================================="
echo " FIN. Codigo: $RC"
echo "==============================================="
