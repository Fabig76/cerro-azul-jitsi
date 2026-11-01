#!/usr/bin/env bash
# =====================================================================
# desplegar-panel.sh - Despliega admin-panel/ de un commit al VPS
#
# El VPS no es un repo git: se copian los ficheros del commit a un
# staging y de ahi a /opt/jitsi-meet/admin-panel, luego build + recreate
# del contenedor admin (app.py y los estaticos van DENTRO de la imagen).
#
# Uso:
#   scripts/desplegar-panel.sh [REF]          # por defecto HEAD
#   scripts/desplegar-panel.sh --rollback     # vuelve a jitsi-admin:pre-rediseno
#
# No toca Caddy ni otros servicios. Solo el contenedor 'admin'.
# =====================================================================
set -euo pipefail

HOST="${DEPLOY_HOST:-chatbotph}"
DIR=/opt/jitsi-meet
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

comprobar() {
    echo "--- comprobaciones ---"
    for i in $(seq 1 30); do
        st=$(ssh "$HOST" "sudo docker inspect -f '{{.State.Health.Status}}' jitsi-admin" 2>/dev/null || true)
        [ "$st" = "healthy" ] && break
        sleep 3
    done
    echo "jitsi-admin: $st"
    for u in /admin/login /healthz /admin/static/theme.css /admin/static/theme.js; do
        printf '%-28s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "https://meet.urbcerroazul.com$u")"
    done
}

if [ "${1:-}" = "--rollback" ]; then
    ssh "$HOST" "cd $DIR && sudo docker tag jitsi-admin:pre-rediseno jitsi-admin:local \
        && sudo docker compose up -d --no-build --force-recreate admin"
    comprobar
    exit 0
fi

REF="${1:-HEAD}"
SHA=$(git -C "$REPO" rev-parse --short "$REF")
echo "Desplegando admin-panel de $SHA en $HOST"
STG="/tmp/deploy-panel-$SHA"
git -C "$REPO" archive "$REF" admin-panel/app admin-panel/Dockerfile \
    | ssh "$HOST" "rm -rf $STG && mkdir -p $STG && tar -x -C $STG"
# Copia fichero a fichero (cp --parents falla con nombres repetidos en una sola llamada)
ssh "$HOST" "cd $STG && find admin-panel -type f | while read -r f; do \
        sudo install -D -o chatbotph -g chatbotph -m 644 \"\$f\" \"$DIR/\$f\"; done \
    && cd $DIR && sudo docker compose build -q admin \
    && sudo docker compose up -d --force-recreate admin && rm -rf $STG"
comprobar
