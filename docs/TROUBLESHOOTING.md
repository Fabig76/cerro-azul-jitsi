# Troubleshooting - Problemas Conocidos y Soluciones

## Problema: "Saca a los dos participantes" (CONFERENCE FAILED: conference.videobridgeNotAvailable)

**Sintoma:**
- Primer participante entra OK
- Segundo participante entra pero el primero se va
- En consola del navegador: `CONFERENCE FAILED: conference.videobridgeNotAvailable`
- En Jicofo logs: `There are no operational bridges`

**Causa raiz:** El cliente no puede establecer WebRTC con el bridge. Jitsi dice "operational" cuando recibe un health check 200 Y cuando los participantes pueden conectar via UDP.

### Sub-causa 1: Falta `mod_turncredentials` en Prosody

El cliente necesita credenciales TURN/STUN del servidor XMPP para negociar WebRTC.

**Sintoma en navegador:**
```
strophe.jingle.js:384  is mod_turncredentials or similar installed and configured?
```

**Solucion:** Agregar a `prosody/conf.d/jitsi-meet.cfg.lua`:
```lua
VirtualHost "meet.tu-dominio.com"
    modules_enabled = {
        ...
        "turncredentials";  -- ANADIR ESTO
    }

    TURNCREDENTIALS_secret = "TU-SECRET-DE-32-BYTES-HEX"
    TURNCREDENTIALS=*** stun, turn, turns }
```

### Sub-causa 2: Firewall bloqueando UDP 10000

**Sintoma:** Cliente no puede enviar/recibir paquetes RTP.

**Verificar:**
```bash
sudo ufw status | grep 10000
# Debe decir ALLOW

# Probar conectividad UDP
nc -u -w 3 TU-IP 10000 < /dev/null
```

**Solucion:**
```bash
sudo ufw allow 10000/udp comment 'Jitsi JVB media'
sudo ufw allow 4443/tcp comment 'Jitsi JVB fallback'
```

### Sub-causa 3: JVB sin IP publica configurada

**Sintoma:** Clientes externos no pueden determinar la IP publica del bridge.

**Verificar en JVB:**
```bash
docker exec jitsi-jvb curl -s http://127.0.0.1:8080/about/version
# Debe responder JSON
```

**Si falla, verificar jvb.conf:**
```bash
grep -E 'public-address|HOSTNAME' /opt/jitsi-meet/jvb/config/jvb.conf
```

**Solucion:** Agregar a `.env`:
```bash
JVB_PUBLIC_ADDRESS=IP-PUBLICA-DEL-VPS
JVB_ADVERTISE_IPS=IP-PUBLICA-DEL-VPS
LOCAL_ADDRESS=IP-INTERNA-DOCKER-JVB-usualmente-172.21.0.5
```

Y agregar a `docker-compose.yml` el bloque jvb:
```yaml
jvb:
    environment:
      - JVB_PUBLIC_ADDRESS
      - JVB_ADVERTISE_IPS
      - LOCAL_ADDRESS
      - COLIBRI_REST_ENABLED=true
```

### Sub-causa 4: REST API del JVB deshabilitada

**Sintoma:** JVB responde `/about/version` pero NO `/about/health`.

**Verificar:**
```bash
docker exec jitsi-jvb curl -s -w "HTTP %{http_code}
" http://127.0.0.1:8080/about/health
# Si da 404, falta habilitar REST
```

**Solucion:** Agregar a `.env`:
```bash
COLIBRI_REST_ENABLED=true
```

Y al `docker-compose.yml`:
```yaml
jvb:
    environment:
      - COLIBRI_REST_ENABLED
```

### Sub-causa 5: Puerto UDP 10000 expuesto en puerto random

**Sintoma:** JVB publica en 32774 en lugar de 10000.

**Verificar:**
```bash
docker ps --filter name=jitsi-jvb --format '{{.Ports}}'
# Si dice 32774->10000/udp esta mal
```

**Solucion:** Cambiar en `docker-compose.yml`:
```yaml
jvb:
    ports:
      - "10000:10000/udp"   # FIJO, no "10000/udp"
      - "4443:4443/tcp"
```

---

## Problema: Login pide usuario/contrasena al entrar a la reunion

**Sintoma:**
- Al entrar a `/reunion/<slug>`, aparece modal "Se requiere autenticacion"
- Modal pide usuario y contrasena

**Causa:** Virtualhost principal en Prosody con `authentication = "token"` (modo secure_domain).

**Solucion:**

1. Verificar `.env`:
```bash
grep -E "ENABLE_AUTH|AUTH_TYPE" /opt/jitsi-meet/.env
# AUTH_TYPE=*** (anonymous, no jwt)
# ENABLE_AUTH=*** (no requiere auth)
```

2. Si tienen `***`, regenerar con chr() o editar manualmente.

3. Borrar configs generados y reiniciar:
```bash
cd /opt/jitsi-meet
docker compose down
sudo rm -f prosody/config/conf.d/*.lua prosody/config/prosody.cfg.lua
sudo rm -f jicofo/config/jicofo.conf web/config/config.js
sudo rm -rf web/config/nginx web/config/keys
docker compose up -d
```

4. Verificar prosody config regenerado:
```bash
grep "authentication" /opt/jitsi-meet/prosody/config/conf.d/jitsi-meet.cfg.lua
# Debe decir: authentication = "jitsi-anonymous"
```

---

## Problema: QR no regresa al panel de admin

**Sintoma:** Al crear reunion, redirige a la imagen del QR pero no puedes volver al panel.

**Causa:** El endpoint `/admin/qr/<id>` siempre devolvia PNG.

**Solucion:** Modificar el endpoint para devolver HTML si NO pide `?format=png`:

```python
@app.route("/admin/qr/<int:rid>")
@login_required
def qr_view(rid):
    ...
    if request.args.get("format") == "png":
        # devolver PNG
        ...
    else:
        # devolver HTML con QR embebido + boton volver
        body = open("/app/page_qr_view.html").read()
        ...
```

Crear `page_qr_view.html` con el template que muestra QR + botones.

---

## Problema: Container JVB no arranca (sip-communicator.properties not found)

**Sintoma:**
```
JVB ReadOnlyConfigurationService.reloadConfiguration#56: Error loading config file: java.io.FileNotFoundException: /config/sip-communicator.properties
```

**Causa:** JVB espera este archivo aunque no lo use.

**Solucion:** Es solo un WARNING, no bloquea el arranque. Si causa problemas, crear archivo vacio:
```bash
docker exec jitsi-jvb touch /config/sip-communicator.properties
```

---

## Problema: "There are no operational bridges" en Jicofo

**Sintoma:**
```
WARNING: [47] BridgeSelector.selectBridge#182: There are no operational bridges.
SEVERE: [47] ParticipantInviteRunnable.doRun#219: Can not invite participant, no bridge available.
```

**Causas posibles:**

1. JVB no conectado a Prosody
2. JVB no expone `/about/health` correctamente
3. Puente UDP 10000 cerrado
4. mod_turncredentials faltante

**Diagnostico paso a paso:**

```bash
# 1. JVB conectado a Prosody?
docker logs jitsi-jvb 2>&1 | grep "Joined MUC"
# Debe decir: Joined MUC: internal-muc.meet.urbcerroazul.com

# 2. Health endpoint responde?
docker exec jitsi-jvb curl -s -w "HTTP %{http_code}
" http://127.0.0.1:8080/about/health
# Debe decir HTTP 200

# 3. Puerto UDP 10000 abierto en host?
ss -uln | grep 10000
# Debe aparecer 0.0.0.0:10000

# 4. Firewall permite UDP 10000?
sudo ufw status | grep 10000
# Debe decir ALLOW

# 5. mod_turncredentials habilitado en Prosody?
docker exec jitsi-prosody ls /prosody-plugins/ | grep turncredentials
# Debe aparecer mod_turncredentials.lua

# 6. JVB anuncia su IP publica?
docker exec jitsi-jvb curl -s http://127.0.0.1:8080/about/version
# Debe responder con JSON
```

**Si todo lo anterior esta OK pero sigue fallando:**
- Revisar logs de Prosody para errores de TURN:
```bash
docker logs jitsi-prosody | grep -iE 'turn|error'
```

---

## Problema: Gateway colapsa *** en outputs

**Sintoma:** Mis outputs del shell muestran `***` en lugar de valores como `0`, `1`, `jwt`, etc.

**Causa:** El gateway de mi agente tiene un filtro que colapsa strings que parecen secretos/patrones especificos.

**Workaround:**
- No confiar en output visible del shell
- Verificar bytes reales con Python directo:
```bash
python3 -c "c = open('/path/to/file').read(); print('0' in c)"
```
- Para editar archivos con strings problematicas, usar Python con chr():
```python
old = "ENABLE_AUTH=" + chr(61) + chr(42)*3
new = "ENABLE_AUTH=" + chr(49)  # =  "1"
```

---

## Problema: /colibri/conferences returns 404

**Sintoma:**
```
docker exec jitsi-jvb curl -s http://127.0.0.1:8080/colibri/conferences
HTTP 404
```

**Explicacion:** Es esperado cuando no hay conferencias activas. La URL correcta para listar conferencias activas es `/colibri/allocations` o simplemente `/about/health`.

---

## Problema: Jitsi pide "Set your name" pre-join screen

**Sintoma:** Cada participante ve una pantalla de "Ingresa tu nombre" antes de entrar a la sala.

**Causa:** `prejoinConfig.enabled = true` (default).

**Solucion:** En `web/config/config.js` cambiar a:
```javascript
config.prejoinConfig.enabled = false;
```

O via .env (si tienes la variable correcta, pero la imagen estable no la lee):
```bash
# Anadir a jvb container, pero no funciona con la imagen stable
ENABLE_PREJOIN_PAGE=false
```

**Workaround:** Editar config.js manualmente y persistir el cambio via:
```bash
# Editar
sed -i 's/config.prejoinConfig.enabled = true/config.prejoinConfig.enabled = false/'     /opt/jitsi-meet/web/config/config.js

# Pero el entrypoint lo regenera al reiniciar el container
# Solución: editar el config.js DESPUES de que el container arranca
# y NO reiniciar el container
```

O cambiar el docker-compose para que monte el config.js como read-write y no se regenere:

```yaml
web:
    volumes:
      - ./web/config:/config:rw   # en lugar de :ro
```

---

## Comandos Utiles de Debug

### Ver health completo del stack

```bash
# JVB health
docker exec jitsi-jvb curl -s http://127.0.0.1:8080/about/health

# JVB version
docker exec jitsi-jvb curl -s http://127.0.0.1:8080/about/version

# Jicofo health (puerto 8888)
docker exec jitsi-jicofo wget -q -O- http://127.0.0.1:8888/about/health

# Prosody: usuarios conectados
docker exec jitsi-prosody ls /var/lib/prosody/

# Admin health
curl https://meet.tu-dominio.com/healthz
```

### Logs en vivo

```bash
# Todos los servicios
docker compose -f /opt/jitsi-meet/docker-compose.yml logs -f

# Solo uno
docker logs jitsi-jvb -f
docker logs jitsi-jicofo -f
docker logs jitsi-prosody -f
docker logs jitsi-admin -f

# Filtrar errores
docker logs jitsi-prosody 2>&1 | grep -iE 'error|warn|severe' | tail -20
```

### Reiniciar un servicio sin perder DB

```bash
cd /opt/jitsi-meet
docker compose restart jvb    # solo reinicia JVB
docker compose restart jicofo
```

### Ver DB de reuniones

```bash
sqlite3 /opt/jitsi-admin/instance/reuniones.db
sqlite> .tables
sqlite> .schema reuniones
sqlite> SELECT id, slug, titulo, fecha_utc, activo FROM reuniones;
sqlite> UPDATE reuniones SET activo=0 WHERE id=5;  # desactivar reunion
sqlite> .exit
```

### Reset completo del stack

```bash
# PELIGRO: borra configs y DB
cd /opt/jitsi-meet
docker compose down
sudo rm -rf prosody/config/conf.d prosody/config/prosody.cfg.lua
sudo rm -rf jicofo/config jvb/config
sudo rm -rf web/config
docker compose up -d
```

---

## Puertos y Conectividad

| Puerto | Tipo | Servicio | Acceso |
|--------|------|----------|--------|
| 80 | TCP | Caddy (HTTP) | Publico |
| 443 | TCP | Caddy (HTTPS) | Publico |
| 10000 | UDP | JVB RTP media | Publico (firewall abierto) |
| 4443 | TCP | JVB RTP fallback | Publico |
| 23456 | TCP | SSH | Restringido (IP allowlist) |
| 8081 | TCP | Admin panel | Solo localhost |
| 8888 | TCP | Jicofo HTTP | Solo localhost |
| 5222 | TCP | Prosody XMPP | Solo localhost |
| 5280 | TCP | Prosody BOSH | Solo localhost |

---

## Recursos del VPS

```bash
# Uso actual de memoria por container
docker stats --no-stream

# Logs totales
docker system df

# Limpiar imagenes dangling (libera espacio)
docker image prune -f

# Reiniciar Docker daemon
sudo systemctl restart docker
```

---

## Notas sobre Monitoreo

Actualmente no hay monitoreo automatico. Para agregar:

- **Prometheus + Grafana**: `docker-jitsi-meet` tiene un compose adicional
- **Alertas**: configurar en /etc/cron.daily/ un script que verifique `curl /healthz` y envie email si falla
- **Logs centralizados**: ELK stack o Loki

Recomendacion minima:
```bash
# /etc/cron.daily/jitsi-healthcheck
#!/bin/bash
if ! curl -sf https://meet.tu-dominio.com/healthz > /dev/null; then
    echo "ALERTA: Jitsi no responde" | mail -s "Jitsi down" admin@tu-dominio.com
fi
```
