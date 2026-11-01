# Troubleshooting - Problemas Conocidos y Soluciones

## ⭐ BUG #6 (CRÍTICO): "There are no operational bridges" por JVB_BREWERY_MUC mal configurado

**Síntoma:** Jicofo dice "no operational bridges", los participantes se desconectan al entrar el segundo.

**Causa raíz DEFINITIVA:** En el `.env` estaba:
```
JVB_BREWERY_MUC=internal-muc.meet.bytracking.net   ← MAL
```

El template de JVB concatena `JVB_BREWERY_MUC` + `@` + `internal-muc.meet.bytracking.net`. Con el valor mal, el JVB se unía a la sala equivocada y Jicofo (que espera en `jvbbrewery@internal-muc...`) nunca lo veía.

**Valor correcto:**
```
JVB_BREWERY_MUC=jvbbrewery   ← BIEN (solo el nombre, NO el dominio completo)
```

**Verificación clave (antes vs después):**
```bash
docker exec jitsi-jicofo wget -q -O - http://127.0.0.1:8888/stats | python3 -c 'import json,sys; print(json.load(sys.stdin)["bridge_selector"]["operational_bridge_count"])'
# ANTES: 0   ❌
# DESPUÉS: 1 ✅
```

## ⭐ BUG #7 (CRÍTICO): Audio/video no se transmite + "DTLS 0xFEFC" por imágenes viejas

**Síntoma:**
- Varios participantes se conectan (señalización OK)
- El moderador NO transmite audio ni video
- Mensaje en cliente: "bridge channel has been disconnected and thus video quality is limited"

**Error en logs del JVB:**
```
SEVERE: Error during DTLS connection: Unsupported version: DTLS 0xFEFC
SEVERE: Error during DTLS negotiation, closing this transport manager
```

**Causa raíz:** `DTLS 0xFEFC` = DTLS 1.3. Las imágenes `stable-9111` (JVB 2.3.61, de 2023/2024) NO soportan DTLS 1.3 que usa Chrome 152+. Además, esa versión tiene el bug del AwsCandidateHarvester (issue #2008).

**Solución:**
1. Actualizar imágenes a `stable-11031` (o superior) en docker-compose.yml
2. Agregar `DISABLE_AWS_HARVESTER=true` al .env

```bash
cd /opt/jitsi-meet
# Backup
cp -a /opt/jitsi-meet /opt/jitsi-meet-backup-$(date +%F-%H%M)

# Cambiar version en docker-compose.yml (stable-9111 -> stable-11031)
sed -i 's/stable-9111/stable-11031/g' docker-compose.yml

# Agregar al .env:
echo "DISABLE_AWS_HARVESTER=true" >> .env

# Limpiar configs y recrear
docker compose down
sudo rm -f prosody/config/conf.d/*.lua prosody/config/prosody.cfg.lua
sudo rm -f jicofo/config/jicofo.conf jvb/config/jvb.conf web/config/config.js
sudo rm -rf web/config/nginx web/config/keys
docker compose pull
docker compose up -d
```

**Verificación:** El JVB debe reportar versión 2.3.29x (no 2.3.61):
```bash
docker exec jitsi-jvb curl -s http://127.0.0.1:8080/about/version
# {"name":"JVB","version":"2.3.295-g8d5c0037b","os":"Linux"}
```

---

## Problema: "Saca a los dos participantes" (CONFERENCE FAILED: conference.videobridgeNotAvailable)
 (CONFERENCE FAILED: conference.videobridgeNotAvailable)

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
# Debe decir: Joined MUC: internal-muc.meet.bytracking.net

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
# web/config: NO borrar el directorio entero, tiene los custom-*.js
# versionados (Fase 3). Borrar solo lo generado y restaurar con git:
sudo find web/config -mindepth 1 ! -name 'custom-*.js' -delete
git checkout -- web/config/
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

---

## BUG: "Comparto pantalla pero los demás no la ven" (1-Nov-2026)

**Síntoma.** Un invitado pulsa compartir pantalla, Chrome le pide qué
compartir, acepta... y en la sala no aparece nada. Sin errores.

### Lo que NO era

- **No era `channelLastN = 4`.** Se sospechó primero, pero el log del JVB
  lo descartó: la pantalla llegaba al servidor con 6 fuentes
  `videoType="desktop"` y Prosody no registraba ningún bloqueo.
- **No era falta de ancho de banda** ni un fallo del JVB.

### La causa real

Se había activado `toggleModeration(..., "desktop")` en el panel. Esa
moderación **sí existe** en `stable-11031`:

```
desktopModerationEnabled · desktopWhitelist · desktopUnmuteApproved
pendingDesktop · "desktop-moderation" · "raise-hand-desktop"
```

El problema: al activarla, el servidor **bloquea** el compartir de todos
los que no estén en la lista blanca, y el panel **no tenía** ningún botón
para añadir a alguien a esa lista. El invitado compartía, el servidor lo
descartaba en silencio y nadie veía nada.

### La solución

**Moderar solo `audio` y `video`.** La pantalla queda fuera de la
moderación y compartir funciona para todos:

```js
function activarModeracion() {
  cmd("toggleModeration", true, "audio");
  cmd("toggleModeration", true, "video");
  // NO añadir "desktop" sin un botón de permiso por participante
}
```

### Cómo verificarlo

```bash
# 1. La pantalla llega al servidor (debe aparecer desktop)
ssh chatbotph 'docker logs jitsi-jvb --since 5m | grep -c "videoType=\"desktop\""'

# 2. El panel NO activa moderación de desktop
ssh chatbotph 'docker exec jitsi-admin grep -c "toggleModeration.*desktop" /app/page_sala.html'
# debe dar 0

# 3. La barra del sitio incluye desktop
curl -sk https://meet.bytracking.net/config.js | grep -A12 "^config.toolbarButtons"
```

### Errores que se cometieron en el camino (para no repetirlos)

1. **Creer que `config.toolbarButtons` se puede pasar por la query.** No
   se puede: el bundle no lee esa clave de la URL (0 apariciones). Solo
   `configOverwrite` por iframe, o el `config.js` del servidor (global).
2. **Quitar `desktop` de la barra** para impedir compartir: rompe las
   reuniones pequeñas donde alguien tiene que mostrar un documento.
3. **No probar end-to-end.** Verificar que "el JVB recibe la pantalla"
   no prueba que "el invitado la vea". Hay que abrir dos navegadores y
   comprobarlo en la sala.

---

## BUG: "La pantalla compartida se ve OSCURA / en negro" (1-Nov-2026)

**Síntoma.** Alguien comparte pantalla y el receptor ve el tile **negro**,
no la imagen. La pantalla se está transmitiendo, pero no se ve.

### Lo que NO era (se probó y se descartó)

| Hipótesis | Prueba | Veredicto |
|---|---|---|
| Falta de resolución (360p heredado) | `desktopSharingResolution = 1920×1080` | ❌ **Empeoró**: más oscura aún |
| Resolución excesiva para el JVB | `desktopSharingResolution = 800×600` | ❌ **Siguió oscura** |
| Hueco de calidad completa ocupado | `maxFullResolutionParticipants = 2` | ❌ No cambió nada |
| Moderación de pantalla bloqueando | `toggleModeration("desktop")` | ❌ Ya estaba descartado antes |

**Conclusión: no era la resolución.** Los tres ajustes se revirtieron.

### La causa real: el ancho de banda del RECEPTOR

El log del JVB lo dice sin ambigüedad:

```
BandwidthAllocator.allocate#279: Sources suspended due to insufficient
bandwidth (bwe=346343 bps): [3fadf6ff-v1]
```

- `bwe=346343 bps` → el estimador de ancho de banda mide **346 kbps**.
- `[3fadf6ff-v1]` → la fuente suspendida es la **`v1`**, la pista de
  pantalla (`videoType="desktop"`).

Cuando el BWE del receptor baja de lo que necesita la pista, el JVB
**deja de enviarla** ("Sources suspended"). El cliente no recibe vídeo y
pinta el tile en negro. No hay ningún error visible: es una decisión
correcta del servidor, no un fallo.

Subir la resolución **multiplica** lo que se necesita:

| Resolución de pantalla | Ancho de banda necesario |
|---|---|
| 800×600 @ 5-15 fps | ~500-800 kbps |
| 1280×720 | ~1-1,5 Mbps |
| 1920×1080 | ~2-3 Mbps |

Con 346 kbps disponibles, **ninguna de las tres cabe**. La de 1080p se
suspende antes y más a menudo: por eso al subirla se veía *peor*.

### Configuración que funciona (estado actual)

Idéntica a la Fase 3. **No añadir `desktopSharingResolution`**:

```js
config.resolution = 360;
config.constraints = { video: { height: { ideal: 360, max: 720, min: 180 } } };
config.channelLastN = 4;
config.maxFullResolutionParticipants = 1;
config.desktopSharingFrameRate = { min: 5, max: 15 };
```

### Cómo diagnosticarlo en 10 segundos

```bash
ssh chatbotph 'docker logs jitsi-jvb --since 30m 2>&1 | grep -i "insufficient bandwidth"'
```

- **Aparece** `Sources suspended ... [-v1]` con `bwe` bajo
  → es la red del receptor. **No hay nada que cambiar en el servidor.**
  Esa persona necesita cable o mejor wifi.
- **No aparece** y aun así se ve negro
  → problema distinto: mirar la consola del navegador del receptor.

### Lección

Un "no se ve" no siempre se arregla en el servidor. Antes de tocar
parámetros: **leer el log del JVB**. Ahí estaba la respuesta desde el
principio (`insufficient bandwidth`), y se ignoró durante dos intentos
de ajuste de resolución.
