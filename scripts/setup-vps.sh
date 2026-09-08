#!/usr/bin/env bash
# ============================================================
# setup-vps.sh - Script de despliegue inicial para nuevo VPS
# ============================================================
# Uso: Ejecutar como root en un VPS Ubuntu 24.04 limpio
# Pre-requisitos: Dominio DNS apuntando al VPS
# ============================================================

set -e

VPS_DOMAIN="meet.tu-dominio.com"
VPS_IP="TU-IP-PUBLICA"
VPS_USER="chatbotph"

echo "=== 1. Instalar Docker ==="
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "=== 2. Crear estructura de directorios ==="
mkdir -p /opt/jitsi-meet/{web,prosody,prosody/prosody-plugins-custom,jicofo,jvb}
mkdir -p /opt/jitsi-admin/{app,instance}
chown -R $VPS_USER:$VPS_USER /opt/jitsi-meet /opt/jitsi-admin

echo "=== 3. Clonar el repo (clonar primero manualmente antes de correr este script) ==="
echo "    git clone git@github.com:Fabig76/cerro-azul-jitsi.git /tmp/cerro-azul-jitsi"
echo "    cp -r /tmp/cerro-azul-jitsi/* /opt/jitsi-meet/ && cp -r /tmp/cerro-azul-jitsi/admin-panel /opt/jitsi-admin/"
echo ""
echo "    AHORA: cd /opt/jitsi-meet && cp .env.example .env && ./gen-passwords.sh >> .env"
echo "    Editar .env con tus valores reales"

echo "=== 4. Configurar firewall ==="
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 10000/udp comment 'Jitsi JVB media'
ufw allow 4443/tcp comment 'Jitsi JVB fallback'
ufw --force enable

echo "=== 5. Construir imagen del admin panel ==="
cd /opt/jitsi-admin
docker build -t jitsi-admin:local .

echo "=== 6. Levantar el stack ==="
cd /opt/jitsi-meet
docker compose up -d

echo "=== 7. Verificar ==="
sleep 20
docker ps --filter "name=jitsi" --format "table {{.Names}}\t{{.Status}}"
echo ""
echo "Health check:"
curl -s https://$VPS_DOMAIN/healthz
echo ""

echo "=== Setup completo ==="
echo ""
echo "SIGUIENTE: Agregar bloque Caddy (ver docs/SETUP_HISTORY.md seccion PASO 4)"
echo ""
echo "URL: https://$VPS_DOMAIN/admin/login"
echo "Usuario: Hguaza76"
echo "Password: la que pusiste en admin-panel/instance/admin.env"
