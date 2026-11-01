# =====================================================================
# turn/ - Servidor TURN de Cerro Azul (Fase 4)
#
# QUE ES ESTO
#   Un servidor TURN/STUN propio. Sin TURN, quien este en una red
#   corporativa o en un operador movil que bloquea UDP entra a la sala
#   pero NO OYE NADA: el cliente solo ve el candidato 'host' (UDP
#   directo) y no hay por donde sacar el audio. Con TURN, el medio se
#   relayiza: el cliente sale por TCP/TLS y el servidor le devuelve los
#   paquetes del JVB.
#
# POR QUE ESTA EN OTRO SERVIDOR
#   El TURN necesita el puerto 443 y en el servidor de Jitsi ese
#   puerto (TCP) lo usa Caddy. En el servidor del TURN el 443 esta
#   libre, asi que se puede ofrecer TURN sobre TLS en 443, que es la
#   variante que entra en las redes mas restrictivas.
#
# QUE HAY QUE CONFIGURAR EN JITSI (.env del servidor de Jitsi)
#   TURN_CREDENTIALS=<secreto>      # el MISMO que usa coturn
#   TURN_HOST=<IP o nombre del TURN>
#   TURN_PORT=3478
#   TURN_TRANSPORT=udp,tcp
#   TURNS_HOST=<IP o nombre del TURN>
#   TURNS_PORT=443
#   STUN_HOST=<IP o nombre del TURN>
#   STUN_PORT=3478
#
#   Prosody convierte esas variables en el bloque 'external_services'
#   (ver /defaults/prosody.cfg.lua de la imagen), que es lo que viaja
#   al cliente. Cada participante recibe una credencial TURN TEMPORAL
#   firmada por Prosody con TURN_CREDENTIALS: el secreto nunca sale del
#   servidor.
#
# DESPLEGUE
#   En el servidor del TURN:
#     mkdir -p /opt/coturn && cd /opt/coturn
#     # copiar turnserver.conf y docker-compose.turn.yml
#     # poner el secreto real en static-auth-secret
#     # (el fichero debe ser legible por el usuario del contenedor)
#     chown 65534:65534 turnserver.conf && chmod 600 turnserver.conf
#     docker compose -f docker-compose.turn.yml up -d
#
#   Reglas de firewall (ufw en el servidor del TURN):
#     ufw allow 3478/udp ; ufw allow 3478/tcp
#     ufw allow 443/udp
#     ufw allow 443/tcp          <-- OBLIGATORIA para el TURN sobre TLS
#     ufw allow 49160:49200/udp     # puertos de relay
#
#   Trampa: coturn abre el 443/TCP (tls-listening-port) pero si el
#   firewall no lo permite, el TLS no funciona y no se ve en los logs de
#   coturn (que solo dicen "TLS/TCP listener opened"). El sintoma es un
#   timeout al hacer el handshake TLS desde fuera. Con 443/udp abierto y
#   443/tcp no, el STUN por UDP funciona y el TLS no: parece un problema
#   de coturn, pero es del firewall.
#
# COMPROBAR QUE FUNCIONA
#   En el servidor del TURN (dentro del contenedor):
#     turnutils_uclient -v -t -y <IP_TURN> -r urbcerroazul.com \
#         -u "<timestamp>:jitsi-test" -W <secreto> -C : -p 3478 \
#         -e <IP_JVB>:10000 <IP_TURN>
#   Debe imprimir "success" y "Received relay addr: ...". La opcion -W
#   hace que el propio cliente calcule la credencial REST a partir del
#   secreto plano (mismo HMAC que usa Prosody).
#
# NOTAS IMPORTANTES
#   - coturn solo acepta UN 'listening-port'. Si se pone dos veces, el
#     segundo SOBREESCRIBE al primero y el primero deja de escuchar (asi
#     se comporto en la primera prueba: al anadir 443 desaparecio 3478).
#     Para mas de un puerto UDP esta 'alt-listening-port'.
#   - El contenedor corre como nobody (65534): el turnserver.conf (con
#     el secreto) y la clave privada del certificado deben ser de ese
#     usuario, o no los podra leer.
#   - El healthcheck mira /proc/net (la imagen no trae netstat ni ss).
# =====================================================================

## Certificado TLS del TURN (`scripts/turn-cert.sh`)

coturn sirve TURN sobre TLS en 443 con `certs/turn_server_cert.pem` y
`certs/turn_server_pkey.pem`. Si el certificado caduca, el TURN por UDP sigue
funcionando y nadie lo nota… salvo quien está en una red que solo deja salir 443/TLS.

Los scripts se copian al servidor del TURN, junto a `turnserver.conf`:

```bash
mkdir -p /opt/coturn/scripts
cp scripts/turn-cert.sh scripts/turn-cert-cron.sh /opt/coturn/scripts/
# Copiados ahí, el directorio por defecto ya es /opt/coturn (--turn-dir no hace falta)
/opt/coturn/scripts/turn-cert.sh status
```

**Escenario B — autofirmado (el de hoy).** El instalado hoy es autofirmado y dura
~10 años. Para regenerarlo (365 días, con la IP como SAN):

```bash
/opt/coturn/scripts/turn-cert.sh issue --selfsigned --ip <IP_TURN> --dry-run
/opt/coturn/scripts/turn-cert.sh issue --selfsigned --ip <IP_TURN>
```

**Escenario A — Let's Encrypt (preferido).** Requiere el registro DNS
`turn.urbcerroazul.com` → IP del TURN (la zona está en **Netim**).

```bash
apt install certbot
# HTTP-01 sin servidor web: certbot abre el 80 (abrirlo en ufw: ufw allow 80/tcp)
/opt/coturn/scripts/turn-cert.sh issue --standalone --email <correo> --staging   # prueba
/opt/coturn/scripts/turn-cert.sh issue --standalone --email <correo>
# o con un servidor web que sirva /var/www/certbot en el 80:
/opt/coturn/scripts/turn-cert.sh issue --webroot /var/www/certbot --email <correo>
# o DNS-01 con IONOS (solo si la zona, o un CNAME _acme-challenge.turn, está en IONOS):
pip install certbot-dns-ionos
/opt/coturn/scripts/turn-cert.sh issue --dns-ionos /root/.secrets/ionos.ini --email <correo>
```

`issue` deja instalado el **deploy-hook** de certbot en la propia emisión; para verlo o
instalarlo como fichero en `renewal-hooks/deploy/`:

```bash
/opt/coturn/scripts/turn-cert.sh install-hook
```

**Renovación desatendida** (vale para los dos escenarios: si hay emisión de Let's Encrypt
renueva esa; si no, regenera el autofirmado). Solo actúa si faltan < 30 días y, si
renueva, reinicia coturn. Si falla, avisa por `TURN_ALERT_WEBHOOK` (POST JSON
`{"text": ...}`) o por Telegram (`TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`):

```bash
cat > /etc/cron.d/turn-cert <<'CRON'
TURN_DIR=/opt/coturn
# TURN_ALERT_WEBHOOK=https://...
17 4 * * * root /opt/coturn/scripts/turn-cert-cron.sh
CRON
/opt/coturn/scripts/turn-cert-cron.sh --dry-run; tail /var/log/turn-cert.log
```

Requisitos en el servidor del TURN: `openssl`, `docker`, `python3` (para los avisos) y,
solo en el escenario A, `certbot` (+ `certbot-dns-ionos` para DNS-01). Ninguno viene
en la imagen de coturn; los scripts corren en el **host**, no en el contenedor.

## Monitorización (`scripts/check-turn.sh`)

Comprueba el TURN como lo usaría un cliente, solo con python3 (stdlib):

| Comprobación | Qué detecta |
|---|---|
| STUN Binding por UDP (`TURN_PORT`, 3478) → XOR-MAPPED-ADDRESS | coturn caído o UDP cerrado en el firewall |
| TURN Allocate por UDP con credencial REST → XOR-RELAYED-ADDRESS | `TURN_CREDENTIALS` de Jitsi ≠ `static-auth-secret` de coturn (el fallo silencioso: STUN responde, nadie consigue relay) |
| STUN Binding sobre TLS (`TURNS_PORT`, 443) | certificado roto o puerto TLS cerrado |
| TURN Allocate sobre TLS | lo que hace un navegador en una red que bloquea UDP |
| Caducidad del certificado TLS | menos de 14 días (`--cert-min-days`) |

Silencioso si todo va bien (sale con 0); si algo falla imprime el detalle y sale con 1;
error de configuración: 2. El secreto no se imprime nunca.

```bash
scripts/check-turn.sh /opt/jitsi-meet/.env -v                         # a mano, con detalle
scripts/check-turn.sh /ruta/turn.env --host <IP_TURN> --port 3478 --turns-port 443
scripts/check-turn.sh --host <IP_TURN> --no-allocate                  # sin secreto: solo STUN/TLS
```

El fichero que se le pasa puede ser el `.env` de Jitsi o uno con **solo** la línea
`TURN_CREDENTIALS=...` (copiada del `.env` de Jitsi, chmod 600). Usar el valor **de
Jitsi** (no el del `turnserver.conf`) es lo que permite detectar que ambos divergen.

### Instalarlo en el watchdog de Hermes

Hermes ejecuta scripts de `/root/.hermes/scripts/` **sin argumentos** y con el patrón
`no_agent` (si el script no imprime nada, no se envía nada; si imprime, se manda el texto
por Telegram), igual que `check-meet-jitsi.sh`. Por eso se crea un envoltorio:

```bash
# 1. El secreto de JITSI, en un fichero solo de root (nunca en el repo)
install -d -m 700 /root/.hermes/secrets
install -m 600 /dev/null /root/.hermes/secrets/turn.env
#    copiar en él la línea TURN_CREDENTIALS=... del .env del servidor de Jitsi
#    (por scp, sin pegarla en la terminal)

# 2. El envoltorio
cat > /root/.hermes/scripts/check-turn-cerroazul.sh <<'EOF2'
#!/usr/bin/env bash
# Watchdog del TURN de Cerro Azul: silencioso si va bien.
exec /root/cerro-azul-jitsi/scripts/check-turn.sh /root/.hermes/secrets/turn.env \
    --host <IP_O_NOMBRE_DEL_TURN> --port 3478 --turns-port 443
EOF2
chmod 700 /root/.hermes/scripts/check-turn-cerroazul.sh
/root/.hermes/scripts/check-turn-cerroazul.sh; echo "rc=$?"     # sin salida y rc=0
```

3. Dar de alta el trabajo en Hermes con los mismos campos que `watchdog-meet-urbcerroazul`
   (en `/root/.hermes/cron/jobs.json`, mediante la herramienta de cron de Hermes):
   `"name": "watchdog-turn-cerroazul"`, `"script": "check-turn-cerroazul.sh"`,
   `"no_agent": true`, `"schedule": {"kind": "interval", "minutes": 5}`,
   `"deliver": "telegram:..."` (el mismo destino que el watchdog de meet).
4. Probar la alerta: con un secreto equivocado en una copia de `turn.env`, el script debe
   imprimir `🔴 ALERTA ... credencial rechazada (401)`.

> **Limitación:** hoy Hermes corre **en el mismo host que el TURN**. Desde ahí la
> comprobación detecta coturn caído, certificado roto/caducado y secretos que divergen,
> pero **no** un firewall o una red del proveedor que bloquee el tráfico de fuera (el
> paquete no sale del host). Para cubrir eso, programar también `check-turn.sh` desde
> otro host, por ejemplo por cron en el servidor de Jitsi, que además ya tiene el `.env`:
> `*/5 * * * * root /opt/jitsi-meet/scripts/check-turn.sh /opt/jitsi-meet/.env --host <IP_TURN>`
> (con `MAILTO` o redirigiendo la salida a un aviso).
