#!/usr/bin/env bash
# =====================================================================
# test-ci-local.sh - Simula los pasos del CI en local
#
# Ejecuta en un directorio temporal los mismos pasos que .github/
# workflows/ci.yml, para poder verificarlos antes de pushear.
# =====================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
step() { echo; echo "=== $* ==="; }

echo "Clon simulado en $WORK"
# Copiar como git clone (sin .git ni archivos ignorados).
mkdir -p "$WORK/repo"
(cd "$REPO" && git ls-files -z | xargs -0 tar cf -) | tar xf - -C "$WORK/repo"
cd "$WORK/repo"

# ───────────────────────────────────────────────────────────────────
step "1. validate-env.sh con .env de prueba"
cp .env.example .env
sed -i \
  -e 's|^PUBLIC_URL=.*|PUBLIC_URL=meet.example.com|' \
  -e 's|^XMPP_DOMAIN=.*|XMPP_DOMAIN=meet.example.com|' \
  -e 's|^XMPP_AUTH_DOMAIN=.*|XMP...=example.com|' \
  -e 's|^XMPP_MUC_DOMAIN=.*|XMPP_MUC_DOMAIN=muc.meet.example.com|' \
  -e 's|^XMPP_INTERNAL_MUC_DOMAIN=.*|XMPP_INTERNAL_MUC_DOMAIN=internal-muc.meet.example.com|' \
  -e 's|^XMPP_RECORDER_DOMAIN=.*|XMPP_RECORDER_DOMAIN=recorder.meet.example.com|' \
  -e 's|^JVB_WS_DOMAIN=.*|JVB_WS_DOMAIN=meet.example.com|' \
  -e 's|^TURN_HOST=.*|TURN_HOST=meet.example.com|' \
  -e 's|^JVB_ADVERTISE_IPS=.*|JVB_ADVERTISE_IPS=203.0.113.10|' \
  .env
./gen-passwords.sh | grep -E '^[A-Z_]+=' | while IFS= read -r l; do
    k="${l%%=*}"; v="${l#*=}"
    sed -i "s|^${k}=.*|${k}=${v}|" .env
done
./scripts/validate-env.sh .env > /tmp/ve.out 2>&1
if [ $? -ne 0 ]; then
    echo "FALLO validate-env"; tail -20 /tmp/ve.out; FAIL=1
else
    tail -2 /tmp/ve.out
fi

# ───────────────────────────────────────────────────────────────────
step "2. docker compose config"
docker compose config --quiet 2>/tmp/dc.err
if [ $? -ne 0 ]; then
    echo "FALLO compose config"; cat /tmp/dc.err; FAIL=1
else
    echo "compose config OK"
fi

step "3. imagenes con version fija"
if docker compose config | grep -E 'image:.*:(stable|latest)$'; then
    echo "FALLO: hay imagen sin version fija"; FAIL=1
else
    echo "OK: todas las imagenes fijadas"
fi

step "4. los 5 servicios tienen healthcheck"
n=$(docker compose config --format json | python3 -c "import json,sys; print(len([s for s in json.load(sys.stdin)['services'].values() if 'healthcheck' in s]))")
echo "servicios con healthcheck: $n"
[ "$n" -eq 5 ] || { echo "FALLO: faltan healthchecks"; FAIL=1; }

step "5. build de la imagen admin"
docker build -q -t jitsi-admin:ci-test ./admin-panel > /tmp/build.log 2>&1
if [ $? -ne 0 ]; then
    echo "FALLO build"; tail -20 /tmp/build.log; FAIL=1
else
    echo "build OK"
    step "6. el admin responde /healthz"
    mkdir -p "$WORK/inst"
    docker run --rm -d --name admci -p 18082:8081 -v "$WORK/inst:/app/instance" \
        -e JITSI_ENV_FILE=/nonexistent jitsi-admin:ci-test > /dev/null 2>&1
    ok=0
    for i in $(seq 1 20); do
        if curl -fsS http://127.0.0.1:18082/healthz > /dev/null 2>&1; then
            ok=1; break
        fi
        sleep 2
    done
    docker rm -f admci > /dev/null 2>&1
    docker rmi -f jitsi-admin:ci-test > /dev/null 2>&1
    [ "$ok" -eq 1 ] && echo "admin OK" || { echo "FALLO: admin no responde"; FAIL=1; }
fi

step "7. caddy validate del bloque"
docker run --rm -v "$WORK/repo/infra/caddy:/conf:ro" caddy:2-alpine \
    caddy validate --adapter caddyfile --config /conf/meet.bytracking.net.caddy 2>&1 | tail -3
if [ ${PIPESTATUS[0]} -ne 0 ]; then echo "FALLO caddy validate"; FAIL=1; fi

step "8. el bloque no usa 127.0.0.1"
if grep -nE 'reverse_proxy[[:space:]]+127\.0\.0\.1' infra/caddy/meet.bytracking.net.caddy; then
    echo "FALLO: usa 127.0.0.1"; FAIL=1
else
    echo "OK: usa DNS de red"
fi

step "9. bash -n en todos los scripts"
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 bash -n
echo "sintaxis OK"

step "10. ruff"
if command -v ruff >/dev/null 2>&1; then
    ruff check admin-panel/app/app.py && echo "ruff OK" || { echo "FALLO ruff"; FAIL=1; }
else
    echo "(ruff no instalado localmente, el CI lo instala)"
fi

step "11. no hay secretos en los archivos versionados"
if git -C "$REPO" ls-files -z | xargs -0 grep -lE 'external_service_secret = "[0-9a-f]{32,}"' 2>/dev/null; then
    echo "FALLO: hay un secret commiteado"; FAIL=1
else
    echo "OK: sin secretos en el HEAD"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    echo "RESULTADO: todos los pasos del CI pasan."
    exit 0
fi
echo "RESULTADO: hay pasos del CI que fallan."
exit 1
