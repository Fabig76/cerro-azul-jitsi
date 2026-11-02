# Troubleshooting - Problemas Conocidos y Soluciones

> Los problemas de la instalación inicial (septiembre de 2026, imágenes
> `stable-9111`, Prosody anónimo) se conservan como referencia. El que más
> afecta hoy a las asambleas es el de la **pantalla compartida**, al final:
> [ir a la sección](#-bug-comparto-pantalla-pero-los-demás-no-la-ven-12-nov-2026).
> Después va el del botón **"Bajar todas las manos"** (resuelto):
> [ir a la sección](#-bug-el-botón-bajar-todas-las-manos-no-hace-nada-2-nov-2026).

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

> **Histórico (antes de la Fase 2).** Desde la Fase 2 el acceso es **con JWT
> obligatorio** (`ENABLE_AUTH=1`, `AUTH_TYPE=jwt`): no hay que volver a
> anónimo. Hoy, "Se requiere autenticación" al entrar significa que el token
> no llegó o no es válido. Con `stable-11031` el token tiene que ir en
> `?jwt=` (query), **no** en `#jwt=` (corregido en `4535fd9`). Ver también
> los logs de Prosody (`token required`, `signature verification failed`).

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
sqlite3 /opt/jitsi-meet/admin-panel/instance/reuniones.db
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

Hoy hay un watchdog de Hermes cada 2 min (web, `/healthz` y TURN) que avisa por
Telegram; corre en el host de desarrollo `vmi3186036` (ver README, Fase 7.1).
Pendiente (Fase 7.1): Prometheus + Grafana. Ideas originales:

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

## ⭐ BUG: "Comparto pantalla pero los demás no la ven" (1/2-Nov-2026)

> **Compartir pantalla requiere que el administrador habilite la cámara de
> quien comparte.** Es contraintuitivo, pero así funciona Jitsi.
> Investigación completa: [`INVESTIGACION-PANTALLA.md`](INVESTIGACION-PANTALLA.md).
> Procedimiento y alternativas: [`SOLUCION-PANTALLA.md`](SOLUCION-PANTALLA.md).

Esta sección **sustituye** a las dos versiones anteriores del 1-nov
("era la moderación de `desktop`" y "era el ancho de banda del receptor").
Las dos estaban equivocadas como causa principal.

### Síntoma exacto

- Un **residente** (no el admin) pulsa "Compartir pantalla", elige qué
  compartir y **él ve su pantalla** (la vista es local).
- **Los demás no ven nada.** Sin errores en ningún lado.
- Si comparte el **admin**, se ve siempre.
- "Antes funcionaba" y deja de funcionar cuando el residente recarga.

### Cómo distinguirlo de un problema de red

En el log del JVB, la pista de pantalla del emisor **sí aparece** (llega al
servidor), pero el JVB no la reenvía, y para ese endpoint la última línea de
`forceMuteVideo` es *Muting*:

```
… name="e0dae905-v1" ssrc="…" videoType="desktop" …              <- la pantalla llega
Transceiver.forceMuteVideo#322: … epId=e0dae905 … Muting incoming video   <- y se descarta
```

Un problema de red del **receptor** se ve distinto: `Sources suspended due
to insufficient bandwidth (bwe=…)` para un receptor concreto, y solo cuando
el emisor ya está des-silenciado. Afecta a esa persona, no a todos. No es
falta de capacidad del servidor: con un solo ponente, la subida del VPS
alcanza para 500 oyentes ([`CAPACIDAD-500.md`](CAPACIDAD-500.md)). El JVB
recorta la pista a quien no puede recibirla.

### Causa

Con la moderación de **vídeo** activa (la sala de moderación del panel la
activa siempre), Jicofo manda `forceMuteVideo` al JVB para cada participante
no moderador que entra. El JVB silencia **por endpoint, no por pista**: tira
todos los paquetes de vídeo del residente, cámara (`-v0`) **y pantalla**
(`-v1`, `videoType=desktop`). Cada reconexión vuelve a aplicarlo. Igual en
`stable-11031`, `stable-11248` y `master`: actualizar no lo arregla.

### Arreglo: habilitar la cámara de quien comparte

1. Moderación de vídeo activada (audio + vídeo), la recomendada para asambleas.
2. El residente que va a compartir **levanta la mano**.
3. El admin le pulsa **"Habilitar cámara"** (`approveVideo`): entra en la
   whitelist de vídeo.
4. El residente pulsa "Compartir pantalla". Se ve en unos segundos.
5. Si a los 10 s no se ve: el residente **enciende su cámara** un momento
   (ya puede) y la apaga si quiere. Esa petición es la que hace que el JVB
   pase a `Unmuting incoming video`.
6. **Si el residente recarga o se reconecta, repetir desde el paso 3.**

Plan B: "Apagar cámara" sobre el residente también levanta el silenciado
(comprobado), o que comparta el admin. Detalle en `SOLUCION-PANTALLA.md` §a.

Confirmado en producción el 2-nov a las 12:33 (Bogotá): "Habilitar cámara"
→ `Will unmute … for VIDEO` → `Unmuting incoming video` → la pantalla se vio.

### Diagnóstico en 2 minutos (solo lectura, desde el host de desarrollo)

```bash
# 1. ¿Quién comparte? -> id del endpoint (lo que va antes de -v1)
ssh chatbotph 'docker logs jitsi-jvb --since 15m 2>&1 | grep -o "name=\"[0-9a-f]*-v1\" ssrc=\"[0-9]*\" videoType=\"desktop\"" | cut -d\" -f2 | sort -u'

# 2. ¿El JVB lo está silenciando?
EP=e0dae905
ssh chatbotph "docker logs jitsi-jvb --since 4h 2>&1 | grep 'epId=$EP' | grep forceMuteVideo | tail -1"
#   Muting incoming video   -> es este bug: "Habilitar cámara" (arriba)
#   Unmuting incoming video -> el JVB sí reenvía; mirar el paso 3
#   (nada)                  -> emisor moderador o sin moderación de vídeo; paso 3

# 3. ¿Algún receptor sin ancho de banda?
ssh chatbotph 'docker logs jitsi-jvb --since 15m 2>&1 | grep "insufficient bandwidth"'
```

Si el paso 1 no devuelve nada, la pantalla ni siquiera llegó al JVB:
problema en el emisor (permisos del navegador o de macOS).

Las horas del log están en hora de Bogotá (`TZ` de los contenedores).

### Falsas pistas (descartadas, con evidencia)

| Pista | Por qué no era |
|---|---|
| `desktopSharingResolution` | 1080p (`ce48ac9`) y 800×600 (`99ffbe7`) dieron pantalla en negro. Coincidieron con reconexiones (`MUTED`). Sin la clave (estado actual, `86e6319`) siguió fallando 6 veces seguidas (12:14–12:51) hasta que se usó "Habilitar cámara". **No añadirla** |
| `channelLastN = 4` | Con 3–5 participantes la pantalla cabe. Las dos veces que se vio (1-nov 10:50, 2-nov 12:33) fue con `lastN=4` |
| `maxFullResolutionParticipants` | Actúa en la selección del receptor, no en el descarte en la entrada del JVB. Dejarlo en `1` |
| `source-add: 0` en Jicofo | **Normal** con SSRC rewriting (`use-ssrc-rewriting = true`): Jicofo no manda `source-add` a los receptores; las fuentes las anuncia el JVB por el canal de datos |
| `insufficient bandwidth` | Real, pero solo para **receptores concretos** con poca banda (346 kbps; 285 → 30 kbps), y solo si el emisor ya está des-silenciado. No explica "no lo ve nadie" |
| Moderación de `desktop` | Nunca llegó a activarse (0 `Setting enabled=true for DESKTOP` en Jicofo el 1-nov) |

### Errores que se cometieron (para no repetirlos)

1. Diagnosticar sin mirar `forceMuteVideo`, que estaba en el mismo log del JVB.
2. Redesplegar y reiniciar Jicofo (1-nov 12:55) con gente dentro: cada
   reconexión reaplicaba el silenciado y el fallo parecía aleatorio.
3. Pedir a los residentes que recargaran: con este bug, **recargar lo rompe otra vez**.
4. Dar por bueno un cambio sin dos personas reales (una comparte, otra mira).

---

## ⭐ BUG: "El botón 'Bajar todas las manos' no hace nada" (2-Nov-2026)

> **Resuelto en `4193357`** (desplegado y confirmado por el operador en una
> asamblea real). Uso del botón: [`MODERACION-MANOS.md`](MODERACION-MANOS.md).

### Síntoma

- El admin pulsa **"Bajar todas las manos"** en la sala de moderación del panel
  (primera versión, `740da81`): no baja ninguna mano. Sin error en el panel.
- El **"Lower all hands"** nativo de Jitsi (pie del panel de participantes, `⋯`)
  tampoco: usa exactamente el mismo mensaje por el mismo camino.
- Síntoma espejo que dio la pista: **"las manos una a una sí se bajan desde
  Jitsi"**. Lo que sí funciona es que **cada residente baje la suya** con su
  botón ✋: eso cambia su propia presencia XMPP y no pasa por el videobridge.
  En cambio el «Lower hand» que el moderador pulsa sobre otra persona va por el
  videobridge (`sendEndpointMessage(<id>, …)` en el bundle) y en la medición
  tampoco bajó la mano (ni en broadcast ni dirigido).

### Causa

La primera versión enviaba lo mismo que el botón nativo, por el **canal del
videobridge (JVB)**:

```js
APP.conference.sendEndpointMessage("", { name: "lower-hand-message" });
```

que en `lib-jitsi-meet` (`stable-11031`) acaba en:

```js
sendEndpointMessage(e,t){this.rtc.sendChannelMessage(e,t)}
sendMessage(e,t){this._send({colibriClass:"EndpointMessage",msgPayload:t,to:e})}
```

Medido en producción el 2-nov con dos residentes reales con la mano levantada
(mirando la trama que **recibe** el residente, hook en `rtc._channel`): el JVB
`2.3-295` **enruta bien** el mensaje (`to=""` es broadcast válido; `to=<id>`
solo le llega a ese id) pero lo **reenvía sin `msgPayload`**:

```
{"colibriClass":"EndpointMessage","to":"…","from":"…"}     <- sin {"name":"lower-hand-message"}
```

El cliente no sabe qué hacer con eso y la mano no baja. Causa probable (no
demostrada): `jackson-databind 2.18.0` + `jackson-module-kotlin 2.17.1` en la
imagen del JVB y el `@JsonAnyGetter` de `otherFields`. No se ha tocado el JVB.

### Lo que hay (y no hay) en el log del JVB

Durante el diagnóstico aparecieron estos WARNING (copiados del log de
producción, hora de Bogotá):

```
JVB 2026-11-02 14:07:09.987 WARNING: [...] AbstractEndpointMessageTransport.onMessage#70:
Invalid message received (Cannot deserialize value of type `java.lang.String` from Object
value (token `JsonToken.START_OBJECT`) ... EndpointMessage["to"]):
{"colibriClass":"EndpointMessage","msgPayload":{"name":"lower-hand-message"},"to":{}}

JVB 2026-11-02 13:59:34.462 WARNING: [...] AbstractEndpointMessageTransport.onMessage#70:
Invalid message received (Instantiation of [simple type, class
org.jitsi.videobridge.message.EndpointMessage] value failed for JSON property to due to
missing (therefore NULL) value ...): {"colibriClass":"EndpointMessage","msgPayload":{"name":"lower-hand-message"},"to":null}
```

**No son la causa del fallo del botón**, son de las **sondas de diagnóstico**
(entre 13:59 y 14:08): el `to` llegaba como `{}` o `null` porque el script de
prueba de Playwright pasaba mal el id (`frame_locator(...).evaluate(fn, arg)`
recibe el **elemento** como primer argumento). En las mismas 24 h hay 15
WARNING de este tipo y **ninguno con `"to":""`**: el JVB acepta el broadcast
del botón. Quedan como lección: que el JVB no se queje no significa que el
mensaje llegue entero. **Hay que mirar lo que recibe el residente.**

```bash
# Comprobar (solo lectura): ¿mensajes rechazados por el JVB?
ssh chatbotph 'cd /opt/jitsi-meet && sudo docker compose logs --since 2h jvb 2>&1 | grep -A1 "Invalid message received"'
```

### Solución (`4193357`)

Mensaje **privado por XMPP** (MUC de Prosody, fuente de verdad del estado de la
mano), **uno a cada participante** con la mano levantada, en vez del broadcast
por el JVB:

```js
conf.sendMessage({ name: "lower-hand-message" }, id);   // por cada id, sin 3er argumento
```

El receptor es el mismo que el del botón nativo (`lower-hand-message` +
emisor moderador + `disableLowerHandByModerator` sin definir → baja la mano).
Detalle en [`MODERACION-MANOS.md`](MODERACION-MANOS.md#cómo-funciona-técnico).
Verificación: `scripts/probar-bajar-manos-prod.py` (dos residentes reales; el
paso de control comprueba que la vía por el JVB **sigue sin** bajar la mano y
avisa si un día empieza a hacerlo).

### ⚠️ Efecto colateral: otras funciones por el videobridge (PENDIENTE)

Si el JVB reenvía **todos** los `EndpointMessage` sin `msgPayload`, todo lo que
use `sendEndpointMessage` también estaría roto. En el bundle de `stable-11031`
lo usan, entre otros: «Lower hand» / «Lower all hands» nativos, las
**reacciones** (emojis; `lib-jitsi-meet` también tiene un `sendReaction` por
el MUC, así que puede que solo falle una parte), `send-endpoint-text-message` y
`send-camera-facing-mode-message` del iframe API, el control remoto y las
caras (`face-landmarks`). **No se ha comprobado una por una.** No afecta a lo
que usa el panel (iframe API y XMPP) ni al chat (XMPP).
