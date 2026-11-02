# Arquitectura

> Estado a 2-nov-2026. La versión anterior de este documento describía la
> instalación de septiembre (`stable-9111`, Prosody anónimo, admin en
> `/opt/jitsi-admin`) y ya no era válida. El histórico está en
> [`SETUP_HISTORY.md`](SETUP_HISTORY.md).

## Vista general

```
                    Internet
                       |
   DNS: A meet.bytracking.net -> 84.247.165.81  (zona en ipage.com)
                       |
+----------------------v-------------------------------------------------+
| VPS "chatbotph"  84.247.165.81          /opt/jitsi-meet (NO es un git)  |
|                                                                         |
|  hermes-caddy (:80/:443, compartido con otros sitios del host)          |
|    bloque 'meet.bytracking.net' en /home/chatbotph/chatbotph/Caddyfile  |
|      /admin* /reunion/* /unirse /healthz /api/reuniones/* -> admin:8081 |
|      todo lo demas                                       -> web:80      |
|                                                                         |
|  red Docker jitsi-meet_jitsi                                            |
|    jitsi-web      jitsi/web:stable-11031      Nginx + UI, proxy WS      |
|    jitsi-prosody  jitsi-prosody-cerroazul:stable-11031 (+mod_http_health)|
|    jitsi-jicofo   jitsi/jicofo:stable-11031   foco de conferencias      |
|    jitsi-jvb      jitsi/jvb:stable-11031      10000/udp, 4443/tcp       |
|    jitsi-admin    jitsi-admin:local           Flask/Gunicorn :8081      |
+-------------------------------------------------------------------------+

+----------------------------------------------+
| vmi3186036  155.133.22.222  (host de desarrollo) |
|   coturn 4.6.3-r3 (/opt/coturn, network host)  |
|     3478 udp/tcp, 443 udp + tcp (TLS)          |
|     relay 49160-49200/udp                      |
|   watchdog de Hermes (cada 2 min -> Telegram)  |
|   este repo (/root/cerro-azul-jitsi)           |
+----------------------------------------------+

+----------------------------------------------+
| PC del administrador (Chrome de escritorio)  |
|   sala de moderacion del panel (iframe)      |
|   grabacion local: WebM en disco (Fase 9)    |
+----------------------------------------------+
```

Los 5 contenedores estaban `healthy` con ~24 h de uptime el 2-nov-2026.
TLS público: Let's Encrypt emitido por Caddy, válido hasta el 30-ene-2027.

## Componentes

### Caddy (`hermes-caddy`, del host)

- No es parte de este stack: es el Caddy compartido del host. El bloque
  está **escrito en el Caddyfile del host** (no en la admin API: así se cayó
  el sitio dos semanas en octubre).
- Fuente de verdad: `infra/caddy/meet.bytracking.net.caddy`.
- **Diferencia conocida con el host:** el bloque del repo pone
  `frame-ancestors 'self' https://votacionph.us` en Jitsi y
  `frame-ancestors 'none'` + `X-Frame-Options: DENY` en el panel. **En el
  host aún no está aplicado, a propósito** (Fase 6 pendiente). La ruta
  `/api/reuniones/*` sí está en el host desde el 1-nov.
- El Caddyfile del host es un bind de **fichero**: editarlo en sitio (sin
  `sed -i`), `caddy validate` y `caddy reload` dentro del contenedor.

### jitsi-web

- `jitsi/web:stable-11031`, publicado solo en `127.0.0.1:8080` (Caddy le
  llega por la red Docker como `web:80`).
- Hace de proxy de `/xmpp-websocket` y `/colibri-ws`: **recrearlo corta la
  señalización de todos** los participantes.
- `web/config/custom-config.js` y `custom-interface_config.js` (versionados,
  Fase 3) se concatenan al `config.js` generado en cada arranque.
  Config de sala vigente: idéntica a `e30c36d` (ver README, "Compartir pantalla").

### jitsi-prosody

- Imagen propia `jitsi-prosody-cerroazul:stable-11031` = oficial +
  `mod_http_health` (sin él no se registran `focus@`/`jvb@` y no hay medio).
- Autenticación **JWT obligatoria** (`authentication = "token"`).
- `muc.meet.bytracking.net` carga `token_verification` y `token_affiliation`
  (moderador solo si `context.user.moderator = true`).
- `avmoderation.meet.bytracking.net`: whitelists de audio/vídeo/pantalla.
- `muc_max_occupants = 500` (`MAX_PARTICIPANTS`).
- `external_services`: anuncia el TURN por IP (`155.133.22.222`): `stun`,
  `turn` udp, `turn` tcp y `turns` 443, con `secret=true` (credenciales
  temporales firmadas con `TURN_CREDENTIALS`).

### jitsi-jicofo

- `jitsi/jicofo:stable-11031`. `enable-auto-owner = false`,
  `max-bridge-participants = 500`, `use-ssrc-rewriting = true` (por defecto).
- Con la moderación de vídeo activa manda `forceMuteVideo` al JVB para cada
  no moderador que entra. **Esto también bloquea su pantalla compartida**:
  ver [`SOLUCION-PANTALLA.md`](SOLUCION-PANTALLA.md).

### jitsi-jvb

- `jitsi/jvb:stable-11031` (JVB 2.3.295). `10000/udp` y `4443/tcp` publicados.
- Un solo bridge (sin Octo).
- **Capacidad (sala grande):** en la asamblea transmite una sola persona, así
  que el JVB manda una pista de vídeo + audio a cada oyente. Medido el 2-nov
  con `loadtest/medir-bitrate.py`: **0,32–0,41 Mbit/s de subida por oyente** →
  160–200 Mbit/s a 500, frente a ~220 Mbit/s de subida del VPS. El límite es la
  subida, no la CPU (17 % con 48 simultáneos). En producción hay un
  `bitrate: { ideal: 280000, max: 320000 }` en `config.constraints`. La
  cámara sí lo aplica (medido: 0,405 → 0,316 Mbit/s por receptor); la
  pantalla compartida no usa esas constraints. El tope
  real (bitrate del emisor) lo regula el JVB de forma adaptativa según el
  ancho de banda de cada receptor. Ver
  [`CAPACIDAD-500.md`](CAPACIDAD-500.md).
- REST privado en `:8080` (`/about/health`, `/colibri/stats`, `/debug`).

### jitsi-admin (panel)

- `jitsi-admin:local`, construido desde `admin-panel/` (Flask + Gunicorn, 1
  worker). `app.py` va **dentro de la imagen**: un cambio exige `build`.
- Volúmenes: `./admin-panel/instance:/app/instance` (`reuniones.db`,
  `admin.env`) y el `.env` de Jitsi en solo lectura (para leer
  `JWT_APP_SECRET`).
- Funciones:
  - Login (5 intentos / 15 min por IP), crear reuniones, QR, página pública
    `/reunion/<slug>` y `POST /unirse` (JWT por persona, redirige a
    `https://meet.bytracking.net/<sala>?jwt=…`).
  - Sala de moderación `/admin/reunion/<id>/sala`: Jitsi en iframe, activa la
    moderación de audio y vídeo, botones por participante (*Pedir la
    palabra*, *Silenciar*, *Habilitar camara*, *Apagar camara*) y, para las
    manos levantadas, *Bajar la mano* por persona y **Bajar todas las manos**
    (`static/bajar-manos.js`, ver [MODERACION-MANOS.md](MODERACION-MANOS.md)).
    - Casi todo va por el **iframe API**. Bajar manos no puede (el iframe API
      no tiene ese comando): como panel y Jitsi comparten origen, el JS lee
      `APP.store` del iframe y manda `conference.sendMessage({name:
      "lower-hand-message"}, id)`, un **mensaje privado XMPP por el MUC de
      Prosody**, uno por cada persona con la mano levantada.
    - **No va por el videobridge** (lo que hace el botón nativo de Jitsi): el
      JVB `2.3-295` reenvía los `EndpointMessage` sin `msgPayload` y la mano no
      baja. Ver [TROUBLESHOOTING](TROUBLESHOOTING.md#-bug-el-botón-bajar-todas-las-manos-no-hace-nada-2-nov-2026).
  - API servidor a servidor `POST /api/reuniones/<id>/token` (Fase 6).
  - Grabación local (Fase 9): `static/grabacion.js` + `grabacion-worker.js`.
- **Panel multi-conjunto**: marca y responsable legal por variables de
  `admin.env`. En producción: `JITSI_SITE_NAME=bytracking`,
  `JITSI_SITE_SUBTITLE="Asambleas virtuales"`, `JITSI_LEGAL_OWNER=bytracking LLC`.

### TURN (servidor aparte)

- coturn `4.6.3-r3` en `vmi3186036` (155.133.22.222), `/opt/coturn`.
- Va aparte porque necesita el 443 y en el VPS de Jitsi lo usa Caddy.
- Certificado autofirmado `CN=turn.urbcerroazul.com` (hasta 2036). Ese
  nombre **no tiene DNS**; los clientes usan la IP. Detalle en
  [`../turn/README.md`](../turn/README.md).

### Grabación (PC del administrador)

- Chrome graba la pestaña de la sala (`getDisplayMedia` + `MediaRecorder`,
  vídeo + audio, 720p/15 fps, WebM, ~0,5 GB/h) con 4 comprobaciones contra
  la grabación muda y guardado incremental en OPFS.
- **Nada se sube al servidor.** Conversión a MP4 en el propio PC con
  `scripts/grabacion/convertir-mp4.{command,bat}`.
- Guía: [`GRABACION-ADMIN.md`](GRABACION-ADMIN.md).

## Flujo de entrada de un residente

```
1. QR / enlace -> https://meet.bytracking.net/reunion/<slug>   (Caddy -> admin)
2. Formulario (apto + nombre) -> POST /unirse
3. El panel firma un JWT por persona (moderator:false, room=<sala>,
   exp = fin de la reunión + 30 min) y redirige a
   https://meet.bytracking.net/<sala>?jwt=<token>               (Caddy -> web)
4. El cliente abre wss://meet.bytracking.net/xmpp-websocket -> Prosody valida el JWT
5. Jicofo asigna el JVB. Con moderación de vídeo: forceMuteVideo para el residente
6. ICE: UDP 10000 directo al JVB; si la red lo bloquea, relay por el TURN
   (3478 udp/tcp o TLS 443 en 155.133.22.222)
```

Para votacionph.us el flujo es el mismo desde el paso 3, pero el token lo
pide su backend a `POST /api/reuniones/<id>/token` y el iframe lo crea
`integracion/jitsi-cliente.js` ([`INTEGRACION-JITSI.md`](INTEGRACION-JITSI.md)).

## Persistencia y respaldo

| Qué | Dónde | Respaldo |
|---|---|---|
| Reuniones | `/opt/jitsi-meet/admin-panel/instance/reuniones.db` | `scripts/backup.sh` (en claro, copia consistente) |
| Secretos del stack | `/opt/jitsi-meet/.env` (600) | `backup.sh`, cifrado |
| Contraseña, API keys y marca del panel | `/opt/jitsi-meet/admin-panel/instance/admin.env` (600) | `backup.sh`, cifrado |
| Cert interno del web | `/opt/jitsi-meet/web/config/keys/` | `backup.sh`, cifrado |
| Config generada de Prosody/Jicofo/JVB | `prosody/config`, `jicofo/config`, `jvb/config` | `backup.sh`, cifrado (se regeneran desde el `.env`) |
| Cert público | Caddy del host | lo renueva Caddy |
| Grabaciones | PC del administrador | responsabilidad del administrador |

Procedimiento: [`BACKUP-RESTORE.md`](BACKUP-RESTORE.md).

## Operaciones que cortan una asamblea

| Acción | Efecto |
|---|---|
| Recrear o reiniciar `web` | Corta la señalización de todos |
| Reiniciar `jicofo` | Tira todas las conferencias (pasó el 1-nov a las 12:55) |
| Reiniciar `jvb` o `prosody` | Corta medio o señalización de todos |
| Recrear solo `admin` | Jitsi sigue; `/unirse` y el panel no responden ~10–20 s |
| Recargar la página de un residente | Le vuelve a aplicar `forceMuteVideo` (su pantalla deja de verse) |

Antes de reiniciar algo, comprobar que hay 0 conferencias en el JVB y en
Jicofo (comandos en `SOLUCION-PANTALLA.md` §c).
