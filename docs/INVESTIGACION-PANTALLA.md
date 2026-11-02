# Investigación: la pantalla compartida no llega a los demás

> **Este documento es solo de la pantalla compartida.** El botón «Bajar todas
> las manos» del panel (otro problema, también del 2-nov) está en
> [`MODERACION-MANOS.md`](MODERACION-MANOS.md) y en
> [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#-bug-el-botón-bajar-todas-las-manos-no-hace-nada-2-nov-2026).

> Fecha de la investigación: 2026-11-02 (03:00–03:30 UTC).
> Alcance: **solo lectura**. No se tocó el servidor.
>
> **Corregido el 2026-11-02 tras la confirmación en producción (§7).** La
> causa (H1) queda confirmada. La versión anterior de este documento decía
> que "Habilitar cámara" no levantaba el silenciado y recomendaba "Apagar
> cámara": era incompleto. El procedimiento correcto está en
> [`SOLUCION-PANTALLA.md`](SOLUCION-PANTALLA.md) §a: **el admin habilita la
> cámara de quien va a compartir**.
>
> **Todas las horas de los logs son de Bogotá (UTC-5)**, día 2026-11-01:
> los contenedores tienen `TZ=America/Bogota`. Las fechas de los commits
> están en `+0100` (host de desarrollo): `ce48ac9` "17:55 +0100" = **11:55 Bogotá**.

---

## 0. Resumen en cinco líneas

1. **Causa más probable (confirmada en código y en logs):** cuando la
   moderación de **vídeo** está activa, Jicofo ordena al JVB *silenciar a
   la fuerza todo el vídeo entrante* de cada residente que entra
   (`forceMuteVideo`). El JVB aplica ese silenciado **por endpoint**, no por
   pista: descarta todos los paquetes de vídeo, **también los de la pantalla
   (`-v1`, `videoType=desktop`)**. El residente comparte y ve su captura,
   Jicofo acepta la pista, el JVB la registra… y la tira a la basura.
2. De las 13 veces que alguien compartió pantalla el 1-nov, **la única que
   el JVB llegó a reenviar (10:50, `Ward-Hbn`) venía de un endpoint sin el
   silenciado forzado.** Las otras 12 venían de endpoints con
   `forceMuteVideo = MUTED`.
3. La pista de `source-add` / `groups=[]` / `sendQueuedRemoteSources` es
   una **pista falsa**: con *SSRC rewriting* (activo por defecto) Jicofo
   **nunca** envía `source-add` a los receptores. Verlo a 0 es lo normal.
4. **Ninguno de los cambios de configuración de hoy fue la causa**
   (resolución, `maxFullResolutionParticipants`, `channelLastN`, moderación
   de `desktop`). La moderación de `desktop` **nunca llegó a activarse** en
   ninguna sala. Lo que sí hicimos mal: diagnosticar sin mirar el
   `forceMuteVideo` y atribuir a la resolución o al ancho de banda lo que era
   este bloqueo. Además, los redespliegues y las recargas provocaron
   reconexiones, y **cada reconexión vuelve a aplicar el silenciado
   forzado**.
5. **Confirmado en producción el 2-nov a las 12:33** (§7): el admin pulsó
   "Habilitar cámara" sobre el residente que compartía, Jicofo procesó su
   des-silenciado de vídeo, el JVB pasó a `Unmuting incoming video` y la
   pantalla se vio. *(A la hora de escribir la primera versión, 03:12 UTC,
   no había ninguna asamblea en curso: §4.1.)*

---

## 1. Correcciones a las premisas del encargo

| Premisa | Lo que dicen los datos |
|---|---|
| "Producción está en una asamblea en curso" | Falso a la hora de esta investigación. `colibri/stats`: `"conferences":0, "participants":0`. Jicofo `/stats`: `"conferences":0`. Último `Member left … Last member left, stopping` a las **14:22:49**. |
| "Jicofo nunca envía el `source-add`" (señal de bug) | Es el **comportamiento normal** con `use-ssrc-rewriting = true`. Ver §3.1. |
| "`groups=[]` en todos los invites" | Normal: el `session-initiate` solo lleva las 2 fuentes propias del JVB (1 audio y 1 vídeo). Las fuentes remotas, cámaras incluidas, las anuncia el JVB por el canal de datos. |
| "Puede que el nivel INFO oculte el `source-add`" | No. `Sending a queued source-…` es INFO y `Can not signal remote sources…` es WARN (verificado en el bytecode, §3.1). Si ocurrieran, se verían. |
| `140cd43`: "el bloqueo era la moderación de desktop activa" | Falso. En todo el log de Jicofo **no aparece ni una vez** `Setting enabled=true for DESKTOP`. La moderación de pantalla nunca se activó en ninguna sala. |
| `0173bcf`: "la causa real es el ancho de banda del receptor" | Solo parcialmente cierto: explica **2 receptores** concretos (§4.4). Para el resto, la pantalla nunca salió del JVB. |
| La cronología no incluye ningún reinicio de Jicofo | Hubo un **reinicio de Jicofo a las 12:55:51** (`Stopping services` → `Starting Jicofo` a las 12:55:58). Eso tira todas las conferencias. |
| "`Endpoint.expire` a las 12:20:52 = reconexión en cadena" | A las 12:20:52 solo sale **un** endpoint (`e0dae905`). La salida masiva está a las **12:50:29** (4 endpoints en el mismo segundo). |

---

## 2. Investigación externa

> Nota: `community.jitsi.org` devolvió **403 ("Crawler is not allowed")** a
> todos los intentos de lectura automática. Los hilos del foro se citan solo
> cuando otra fuente los enlaza. En StackOverflow no se encontró nada
> relevante.

### 2.1 Lo que dicen las fuentes

| # | Fuente (URL) | Fecha | Lo que dice la fuente |
|---|---|---|---|
| F1 | https://github.com/jitsi/jicofo/issues/1315 — *"Screen-share (desktop) source silently lost for participants when Jingle session transitions during allocation"* | Abierto 2026-09-08, cerrado 2026-10-28 | Es **el "hilo" que citábamos** (no está en el foro, está en GitHub). Mismo JVB `2.3.295-g8d5c0037b`, 30–42 participantes, log `Can not signal remote sources, Jingle session not established`. Respuesta de **bgrozev** (equipo Jitsi, 2026-10-27): *"I don't agree with your root cause analysis… The warning in your log is for the participant that left… in this mode [SSRC rewriting] sources are NOT signaled to receivers via jicofo at all. They are signaled on-demand by JVB to a client over the data channel"*. El autor cierra: *"the issue was resolved after we updated to the latest stable images"* y atribuye el resto a su red (VPN). (Verificado con `gh api` el 2026-11-02.) |
| F2 | https://github.com/jitsi/jicofo/pull/1336 (commit `ef69ab60`) | 2026-10-29 | *"Ignore stale session-accept and source-add after leave or re-invite"*. Según el subagente, es posterior a `stable-11248` y no está en ningún tag estable. |
| F3 | https://github.com/jitsi/jicofo/pull/1235 — *"feat: Handles mute desktop IQ"* | 2025-07-11 | Añade el tipo `DESKTOP` a la moderación en Jicofo. **No modifica** `ParticipantInviteRunnable.java` (lista de ficheros del PR verificada con `gh api`). |
| F4 | https://github.com/jitsi/jitsi-meet/pull/16177 — *"feat(av-moderation) implement screen-sharing moderation"* | 2025-07-11 | Lado cliente de la moderación de pantalla. |
| F5 | https://github.com/jitsi/jitsi-videobridge/pull/2443 — *"Screenshare bandwidth allocation: starvation, oversend gating, burst-proof measurement"* | 2026-09-04 | *"Screenshares are suspended for 'insufficient bandwidth' in circumstances where that is surprising"*. Enlaza a https://community.jitsi.org/t/screen-sharing-turned-off-due-to-insufficient-bandwidth/142455 (no legible: 403). |
| F6 | https://github.com/jitsi/jitsi-videobridge/pull/2444 — *"For screen sharing, prefer full resolution over full frame rate"* | 2026-09-04 | Mejora de la asignación para pantalla. |
| F7 | https://github.com/jitsi/jitsi-meet/pull/17495 — *"resubscribe streaming status on p2p<->jvb track swap"* | 2026-06-26 | Tesela con avatar aunque el vídeo fluye, al pasar de P2P a JVB. No nos aplica: tenemos `p2p.enabled = false`. |
| F8 | Releases de docker-jitsi-meet / tags de jicofo | — | Última estable: **`stable-11248-2` (2026-10-23)**. Anteriores: 11248 (2026-09-14), 11146 (2026-08-03), **11031 (2026-06-04, la nuestra)**. |
| F9 | `jicofo/src/main/java/org/jitsi/jicofo/conference/ParticipantInviteRunnable.java` en los refs `stable/jitsi-meet_11031`, `stable/jitsi-meet_11248` y `master` | Consultado el 2026-11-02 | El bloque que decide `forceMuteVideo` es **idéntico en los tres**: `if (chatRoom.isAvModerationEnabled(MediaType.VIDEO)) forceMuteVideo = true;` (ver §3.2). Último commit de ese fichero en master: 2026-10-27 (`0f63945e`), que no lo toca. |
| F10 | Búsqueda de issues (`gh api search/issues`) en jicofo y jitsi-meet sobre moderación de vídeo + pantalla | 2026-11-02 | **No hay ningún issue abierto** que describa "con la moderación de vídeo activa, la pantalla de un participante no moderador no llega". El más cercano es https://github.com/jitsi/jitsi-meet/issues/17613 ("Better Moderation", 2026-07-14, abierto, genérico). |

### 2.2 Lo que deduzco yo (no lo dice ninguna fuente)

- F1 **no es nuestro caso**: su mensaje de error no aparece en nuestros logs
  y el propio equipo de Jitsi descarta ese mecanismo con SSRC rewriting.
- El mecanismo de §3.2 **no está documentado ni reportado upstream** (F10).
  Actualizar a 11248-2 o a master **no lo arreglaría** (F9). Sí traería
  F5/F6, que atacan el problema secundario de ancho de banda (§4.4).

---

## 3. Auditoría del código

### 3.1 Jicofo (bytecode de la imagen en producción, `jicofo-1.0-1183`)

Se copiaron los `.jar` del contenedor por `docker exec … cat` (solo lectura)
y se desensamblaron con `javap`.

**`Participant.addRemoteSources()`**: lo primero que hace es
`if (useSsrcRewriting()) return;`. `useSsrcRewriting()` =
`ConferenceConfig.useSsrcRewriting && hasSsrcRewritingSupport()`, y
`reference.conf` trae `use-ssrc-rewriting = true`. Los clientes web de 11031
anuncian `SSRC_REWRITING_V1`. **Conclusión: Jicofo no envía `source-add` a
los receptores. Las fuentes las anuncia el JVB por el canal de datos.** Esto
explica los 0 `source-add`, los `groups=[]` y que el `session-initiate` solo
contenga `sources={jvb=[audio=[…], video=[…]]}`. Cámaras y pantalla usan el
mismo camino, y las cámaras funcionan.

Mensajes y niveles (constant pool de `Participant.class`):

| Mensaje | Nivel |
|---|---|
| `Can not signal remote sources, Jingle session not established.` | `Logger.warn` |
| `Sending a queued source-<add/remove>, sources=…` | `Logger.info` |
| `Scheduling a task to signal queued remote sources after … ms.` | (no aparece en el log) |

Logging de Jicofo en producción: `.level=INFO`. **Los tres mensajes tienen 0
apariciones en todo el log del día**, que es lo esperado con SSRC rewriting.

### 3.2 El mecanismo del fallo (Jicofo + JVB)

**a) Al entrar un participante** (`ParticipantInviteRunnable.<init>`, F9 y bytecode):

```java
if (chatRoom != null && !participant.hasModeratorRights() && !participant.shouldSuppressForceMute()) {
    if (chatRoom.isAvModerationEnabled(MediaType.AUDIO)) forceMuteAudio = true;
    if (chatRoom.isAvModerationEnabled(MediaType.VIDEO)) forceMuteVideo = true;   // <- no mira DESKTOP
}
```

**b) En el JVB** (`jitsi-media-transform-2.3-295`, `VideoMuteNode`):

```
if (packet instanceof VideoRtpPacket && forceMute) packetInfo.setShouldDiscard(true)
```

Descarta **todo** paquete de vídeo del endpoint, sea de la cámara (`-v0`) o
de la pantalla (`-v1`). No hay distinción por fuente. El log lo deja
explícito: `Transceiver.forceMuteVideo#322: Muting incoming video`.

**c) Cuándo se levanta** (`JitsiMeetConferenceImpl.handleMuteRequest`,
bytecode, offsets 311–368). Solo cuando llega una petición de
silenciar o des-silenciar de tipo VIDEO o DESKTOP. En ese momento Jicofo
manda al JVB:

```
muteVideoEnBridge = !isMemberAllowedToUnmute(jid, VIDEO) && !isMemberAllowedToUnmute(jid, DESKTOP)
```

Con la moderación de `desktop` apagada, `allowed(DESKTOP)` es verdadero y el
resultado es `false`: **se levanta el silenciado**. Esto ocurre también
cuando la petición es de *silenciar* (ver §4.3, 10:47:56 y 12:04:50).
También se levanta al desactivar la moderación de vídeo.

**d) Qué no lo levanta por sí solo:**
- La whitelist de vídeo ("Habilitar cámara", `approveVideo`) **sola**, sin
  una petición de mute/unmute de vídeo después. Ejemplo: `e0dae905` entró en
  la whitelist a las 12:13:38, nunca pidió des-silenciar, y el JVB lo seguía
  teniendo `MUTED` cuando compartió a las 12:14:16.
  **Corrección (§7):** "Habilitar cámara" **sí es el paso necesario**. Es lo
  que autoriza al residente; en cuanto se procesa su siguiente petición de
  unmute de vídeo (al encender la cámara, o la que llegó 6 s después de la
  aprobación el 2-nov), el bloqueo se levanta. Lo mismo pasó el 1-nov a las
  10:47 (aprobación + cámara encendida → la pantalla de las 10:50 se vio).
- Empezar a compartir pantalla. *(Deducción, apoyada en los logs: el cliente
  solo pide des-silenciar `desktop` si antes un moderador se la silenció. En
  todo el día solo hay una petición así: `795a05db` a las 11:47:17, justo
  después de que el admin le silenciara la pantalla a las 11:46:53.)*

**Resultado:** con moderación de vídeo activa y de pantalla inactiva, el
cliente deja compartir (no hay moderación de pantalla), Jicofo acepta la
fuente y la manda al JVB (§4.2), y **el JVB descarta los paquetes**. Es una
**incoherencia de Jitsi**. La moderación de pantalla se añadió en jul-2025
(F3, F4), pero el silenciado forzado del bridge sigue siendo un único
interruptor de "vídeo" que se decide solo con la moderación de VIDEO al
entrar. Sigue igual en master (F9).

### 3.3 Proyecto: `admin-panel/app/app.py`

- `TOOLBAR_ADMIN` / `TOOLBAR_ASISTENTE` (l. 308–310) y `jitsi_url()`
  (l. 313–329): la barra viaja en la **query** (`&config.toolbarButtons=…`).
  Jitsi lee los `config.*` de la URL del **fragmento** (`#config.x=`), no de
  la query, así que es probable que se ignore *(deducción; coincide con lo
  que `89529c6` encontró en el bundle)*. **No afecta a esta incidencia:** el
  residente acaba con la barra del sitio, que incluye `desktop`. Por eso
  puede compartir y por eso lo intenta.
- `sign_jwt()` (l. 264–293): `context.user.moderator` solo es `true` para el
  admin. Correcto. **Un moderador nunca recibe `forceMuteVideo`**
  (`!participant.hasModeratorRights()`), así que **la pantalla del admin
  siempre llega** (salvo por ancho de banda).

### 3.4 Proyecto: `admin-panel/app/page_sala.html`

- `videoConferenceJoined` → `activarModeracion()` → `toggleModeration(true,
  "audio")` y `toggleModeration(true, "video")` (l. 192–198 y 275–281).
  **Es el disparador:** cada vez que el admin entra o recarga la página de
  moderación, la moderación de vídeo queda activa, y desde ese momento cada
  residente que entra o se reconecta recibe `forceMuteVideo`.
- "Habilitar cámara" = `approveVideo` → añade a la whitelist (§3.2 d). Con
  la siguiente petición de unmute de vídeo del residente, el bridge lo
  des-silencia. **Es el procedimiento recomendado** (§7, SOLUCION §a).
- "Apagar cámara" = `muteRemoteParticipant(id, "video")` → pasa por
  `handleMuteRequest` VIDEO y, por el cálculo de §3.2 c, también le quita el
  silenciado del bridge (comprobado en §4.3 y el 2-nov a las 12:33:33 con
  `f30c0f56`). Funciona, pero es contraintuitivo y depende de un detalle
  interno: queda como **plan B**, no como procedimiento normal.
- No hay ninguna llamada con `desktop` (estado tras `140cd43`).

### 3.5 Proyecto: `web/config/custom-config.js`

Idéntico a `e30c36d` (`git diff e30c36d HEAD` vacío). Claves de vídeo:
`p2p.enabled=false`, `channelLastN=4`, `maxFullResolutionParticipants=1`,
`resolution=360` + `constraints` 360/720/180, `desktopSharingFrameRate
{5,15}`, sin `desktopSharingResolution`. **Ninguna de ellas puede hacer que
el JVB descarte paquetes en la entrada.** Actúan en la captura del emisor o
en la selección del receptor, y en un caso de "no hay paquetes" no
intervienen.

### 3.6 `docker-compose.yml`

`ENABLE_P2P=0`, `ENABLE_AV_MODERATION` (pasa a Prosody),
`XMPP_MUC_MODULES` (token_affiliation), `MAX_PARTICIPANTS`,
`MAX_BRIDGE_PARTICIPANTS`, `ENABLE_COLIBRI_WEBSOCKET=1`. Nada relacionado
con el reenvío de la pista `desktop`.

### 3.7 Prosody

- `muc.meet.bytracking.net` carga `token_affiliation` y `token_verification`.
  `mod_token_affiliation.lua` solo fija la afiliación (owner o member) en
  `muc-occupant-pre-join`. **No toca medios ni moderación.** Su único efecto
  aquí es indirecto, y correcto: el residente es `member`, no moderador, y
  por eso Jicofo le aplica el silenciado forzado.
- `Component "avmoderation…" "av_moderation_component"`: soporta `audio`,
  `video` y `desktop` (l. 95, 226, 352 de `mod_av_moderation_component.lua`).
  Gestiona las whitelists. **El silenciado en el JVB lo decide Jicofo**,
  no Prosody.
- Avisos `Concurrent moderator enable/disable request or something is out of
  sync`: 2 por cada entrada del admin (10:08, 10:42, 11:45, 12:11, 12:50,
  13:17). La causa es que `activarModeracion()` se llama dos veces seguidas
  (`videoConferenceJoined` y `participantRoleChanged`). Es inofensivo para
  esta incidencia, pero es ruido.

### 3.8 Configuración de Jicofo

`max-bridge-participants = "500"`, `brewery-jid =
"jvbbrewery@internal-muc…"`, `max-ssrcs-per-user = 20`. Con 1 JVB y menos
de 10 participantes, **nada de esto interviene**. Solo hay un bridge
(`BridgeSelectionStrategy.select` → siempre el mismo) y las 12 fuentes por
participante (6 de cámara + 6 de pantalla) están por debajo de 20.

---

## 4. Auditoría en vivo (salidas reales, 2026-11-02 ~03:10 UTC)

### 4.1 Estado actual

```
$ docker ps  (extracto)
jitsi-web     jitsi/web:stable-11031      Up 9 hours (healthy)
jitsi-admin   jitsi-admin:local           Up 9 hours (healthy)
jitsi-jicofo  jitsi/jicofo:stable-11031   Up 9 hours (healthy)
jitsi-jvb     jitsi/jvb:stable-11031      Up 12 hours (healthy)
jitsi-prosody jitsi-prosody-cerroazul:stable-11031 Up 12 hours (healthy)

$ docker inspect …
/jitsi-jicofo created=2026-11-01T15:06:25Z started=2026-11-01T17:55:56Z restarts=0   <- reinicio 12:55 Bogotá
/jitsi-jvb    created=2026-11-01T15:06:25Z started=2026-11-01T15:06:40Z
/jitsi-web    created=2026-11-01T17:38:01Z                                          <- recreado 12:38 Bogotá
/jitsi-admin  created=2026-11-01T17:38:01Z

$ curl 127.0.0.1:8080/colibri/stats (JVB)
"conferences":0  "participants":0  "endpoints":0  "current_timestamp":"2026-11-02 03:12:48.163"
$ curl 127.0.0.1:8888/stats (Jicofo)
"conferences":0  "participants":0
```

### 4.2 Comandos pedidos

```
$ docker logs jitsi-jicofo --since 2h | grep -iE "source-add|source-remove|queued|not established" | head -40
(sin salida)
$ docker logs jitsi-jvb --since 2h | grep -iE "desktop|groups|suspended" | head -40
(sin salida)
```

Ambos salen vacíos porque **no ha habido actividad en las últimas 2 h**: la
última conferencia terminó a las 14:22 (Jicofo) y el último evento del JVB es
de las 12:58. Por eso se analizó el **log completo del día** (copiado en
local, 944 líneas de Jicofo y 3248 del JVB):

```
grep -c "Sending a queued"      jicofo.log  -> 0
grep -c "Scheduling a task"     jicofo.log  -> 0
grep -c "Can not signal"        jicofo.log  -> 0
sources= en session-initiate (todos):  sources={jvb=[audio=[N], video=[M], groups=[]]}
```

Ejemplo real de lo que Jicofo **sí** manda al JVB cuando un residente comparte
(12:14:16, `conference-modify`, recortado). La pantalla llega con simulcast
de 3 capas + RTX:

```xml
<endpoint id="e0dae905" stats-id="Savannah-pVK"><sources>
  <media-source id="e0dae905-v0" type="video"> … videoType="camera" … </media-source>
  <media-source id="e0dae905-v1" type="video">
    <source name="e0dae905-v1" ssrc="220506860" videoType="desktop"/> … (6 SSRC)
    <ssrc-group semantics="SIM"> 3 capas </ssrc-group> <ssrc-group semantics="FID"> ×3 </ssrc-group>
  </media-source>
</sources></endpoint>
```

**La señalización emisor → Jicofo → JVB funciona.** El corte está en el JVB,
en la entrada del endpoint emisor.

```
$ docker exec jitsi-jicofo cat /config/jicofo.conf   (extracto; la contraseña se omite)
bridge { max-bridge-participants = "500"; brewery-jid = "jvbbrewery@internal-muc.meet.bytracking.net" }
codec.rtp-extensions { video-layers-allocation.enabled = false; mid.enabled = false }
conference { enable-auto-owner = false; max-ssrcs-per-user = "20"; max-ssrc-groups-per-user = "20" }
octo.enabled = false ; sctp.enabled = true
xmpp.client { hostname = "prosody"; username = "focus"; password = "<OMITIDA>"; … }
include "custom-jicofo.conf"

$ docker exec jitsi-jicofo cat /config/logging.properties
.level=INFO
```

> ⚠ `cat /config/jicofo.conf` imprime la contraseña de `focus` en claro. No
> pegues esa salida en tickets ni en chats.

```
$ docker exec jitsi-prosody grep -E "av_moderation|token_affiliation|muc_" /config/conf.d/jitsi-meet.cfg.lua  (extracto)
        "token_affiliation";
    muc_max_occupants = "500"
Component "avmoderation.meet.bytracking.net" "av_moderation_component"
```

### 4.3 Correlación: cada vez que se compartió pantalla el 1-nov

Reconstruido con un script sobre el log del JVB. Para cada `conference-modify`
con `videoType="desktop"` se mira el último `Transceiver.forceMuteVideo` de
ese mismo `epId`.

| Hora | Sala | Endpoint (stats-id) | `forceMuteVideo` en el JVB al compartir | ¿Se reenvió? (evidencia) |
|---|---|---|---|---|
| 10:50:28 | b319 | 3fadf6ff (Ward-Hbn) | **UNMUTED** (el admin aprobó su vídeo a las 10:47:34, él encendió la cámara a las 10:47:37 → `Will unmute … for VIDEO`) | **Sí**: el JVB la reenviaba y la suspendió para un receptor con poca banda (`Jack-Bs9`, bwe 346 kbps). **Esta es la vez que "funcionaba".** |
| 11:31:27 | b319 | 071d6a07 (Savannah-pVK) | MUTED | No hay rastro de reenvío |
| 11:37:53 | b319 | 4bf7c972 (Savannah-pVK) | MUTED | No |
| 11:43:11 | b319 | 795a05db (Savannah-pVK) | MUTED… | …hasta las **11:45:21**: se desactiva y reactiva la moderación → `Unmuting incoming video`. **Desde ahí sí se reenvía**: 11:51:14 y 11:51:37 la suspende para `Lessie-zKQ` (bwe 285 kbps → 30 kbps). |
| 11:56:18 | b319 | 47819e51 (Savannah-pVK) | MUTED | No ("pantalla oscura": se atribuyó al 1080p de `ce48ac9`, 11:55) |
| 12:00:32 | b319 | b7be1ba0 (Savannah-pVK) | MUTED… | …hasta las **12:04:50**: el admin pulsa "silenciar vídeo" sobre ella (`Will mute /b7be1ba0 … for VIDEO`) y el JVB responde `Unmuting incoming video`. |
| 12:14:16 | 664e | e0dae905 (Savannah-pVK) | MUTED (en la whitelist de vídeo desde 12:13:38, pero sin des-silenciar) | No |
| 12:21:25 | 664e | 265262aa (Savannah-pVK) | MUTED | No |
| 12:32:35 | 664e | f5267190 (Ward-Hbn) | MUTED (el mismo usuario de las 10:50, reconectado: el silenciado vuelve a aplicarse) | No |
| 12:33:43 | 664e | 11b6588e (Jack-Bs9) | MUTED | No |
| 12:36:36 | 664e | e3a6e946 (Jack-Bs9) | MUTED | No |
| 12:49:59 | 664e | 0f814b35 (Jack-Bs9) | MUTED | No |
| 12:51:07 | 664e | faf78904 (Jack-Bs9) | MUTED | No (12:55 reinicio de Jicofo) |

Otras observaciones del mismo log:

- **10:47:56**, "silenciar vídeo a todos" del admin: el JVB pasa a
  `Unmuting incoming video` a f5547b1b, b2e5efb6 y 97b4dd59, que estaban
  `MUTED` desde que entraron. Es la confirmación empírica de §3.2 c.
- Las 2 únicas líneas `Sources suspended` del día (10:50 y 11:51)
  corresponden a emisores con el vídeo **des-silenciado**. Ningún emisor
  `MUTED` produjo suspensiones, lo cual cuadra: el allocator no tiene
  bitrate que repartir si los paquetes se descartan en la entrada.
- Reconexiones de residentes cada ~5 min (Savannah: 11:25, 11:31, 11:37,
  11:42, 11:56, 12:00, 12:12, 12:21). Delante de varias de ellas Prosody
  registra `auth_token … token required` (11:25:02, 11:30:51, 11:35:54,
  11:41:38, 11:42:34). *Deducción, sin verificar:* el usuario recarga (F5),
  el primer intento llega sin token válido (no sé si porque la URL ya no
  lleva el `?jwt=` o por otra razón), falla, vuelve a abrir el enlace y
  entra con un endpoint nuevo, **otra vez `MUTED`**. Cada "voy a recargar a ver si se arregla" deshace cualquier
  des-silenciado previo.

### 4.4 El problema secundario (real, pero distinto)

`Sources suspended due to insufficient bandwidth`, 2 casos, ambos de
receptores con poca banda (346 kbps; 285 → 30 kbps). Ahí el receptor tiene la
pantalla en negro aunque el emisor esté bien. Es el comportamiento
documentado del allocator (F5: *"suspended … in circumstances where that is
surprising"*), mejorado en `stable-11248` (F5, F6). **Afecta a receptores
concretos, no a "todos menos el que comparte".**

---

## 5. Diagnóstico razonado: hipótesis ordenadas

| # | Hipótesis | Probabilidad | A favor | En contra / qué la descarta | Prueba que falta |
|---|---|---|---|---|---|
| **H1** | **Silenciado forzado de vídeo en el JVB** (moderación de vídeo activa) que descarta también la pista `desktop` del residente | **CONFIRMADA en producción el 2-nov 12:33 (§7)** | Código de Jicofo y del JVB (§3.2). 12 de 13 pantallas desde endpoints `MUTED`, la única reenviada desde `UNMUTED` (§4.3). Dos des-silenciados a mitad de pantalla (11:45, 12:04) y justo después hay reenvío (suspensiones). Explica "antes funcionaba" (10:50) y por qué dejó de funcionar al reconectarse los mismos usuarios. | Ninguna evidencia en contra. El síntoma "ni siquiera hay tesela" no lo explica del todo (ver H3). | Hecha (§7): residente comparte → invisible; el admin pulsa "Habilitar cámara" → `Unmuting incoming video` → visible sin recargar. |
| H2 | Ancho de banda del receptor (suspensión por el allocator) | Media como causa **parcial** | 2 suspensiones reales. | Solo con emisores ya des-silenciados y para receptores concretos. No explica que nadie la vea. | `grep "insufficient bandwidth"` durante la incidencia (procedimiento de 2 min). |
| H3 | La tesela no se crea en el receptor (presencia `SourceInfo` / `VideoSourcesMap`) | Baja-media, sin comprobar | El operador dice "ni un tile negro". | Con SSRC rewriting, la tesela se crea **por presencia** (F1, código de jitsi-meet). Lo más probable es que la tesela exista pero muestre avatar o fondo vacío porque no llegan fotogramas, que es lo que se vería con H1. | Consola del navegador del receptor: buscar `SourceInfo` del emisor con `-v1 … desktop, muted:false` y `Received VideoSourcesMap`. |
| H4 | Bug de Jicofo `sendQueuedRemoteSources` (F1) | **Descartada** | — | SSRC rewriting: esa ruta no se ejecuta (`addRemoteSources` sale al principio). 0 apariciones del WARN. El propio equipo de Jitsi lo descarta (F1). | — |
| H5 | Configuración de hoy (resolución, `maxFullResolutionParticipants`, `channelLastN`) | **Descartada** | — | La configuración vigente es la original. Los fallos ocurren igual con la configuración original (12:14–12:51, tras `86e6319`). Ninguna de esas claves descarta paquetes en la entrada del JVB. | — |
| H6 | Moderación de `desktop` (commit `4e19178`) | **Descartada** | — | Nunca se activó: 0 `enabled=true for DESKTOP` en Jicofo. | — |
| H7 | `token_affiliation` / `token_verification` | **Descartada como causa directa** | — | Solo asignan el rol. Su efecto (residente = no moderador) es lo que hace que H1 se aplique, y es el comportamiento deseado. | — |
| H8 | Conectividad / TURN | **Descartada** | — | Audio y cámaras fluyen por el mismo transporte. ICE nominado en los 49 endpoints. | — |
| H9 | `desktopSharingResolution` (1080p / 800×600) | **Descartada** | — | No existe en la config vigente y los fallos siguieron sin ella (12:14–12:51). La "pantalla oscura" con 1080p (11:56) y 800×600 (12:00) coincidió con endpoints `MUTED`. | — |
| H10 | `source-add: 0` como señal de bug | **Descartada** | — | Normal con SSRC rewriting (§3.1). | — |

---

## 6. Qué hicimos mal (sin rodeos)

1. **Diagnosticamos sin mirar `forceMuteVideo`**, que estaba en el mismo log
   del JVB que usamos para "demostrar" otras causas (45 líneas
   `Transceiver.forceMuteVideo`).
2. **`140cd43` inventó una causa**: la moderación de `desktop` "activa" nunca
   llegó a estarlo.
3. **`ce48ac9` → `99ffbe7` → `86e6319`**: atribuimos a la resolución unos
   fallos que coincidían con reconexiones (11:56, 12:00). Cada reconexión
   volvía a aplicar el silenciado. "Funciona con la configuración original"
   no se comprobó: con la configuración original fallaron 6 pantallas
   seguidas (12:14–12:51).
4. **`0173bcf` documentó como "causa real" el ancho de banda.** Es una causa
   secundaria de 2 receptores, no la de "nadie lo ve". *(Corregido en el
   README y en `docs/TROUBLESHOOTING.md` el 2-nov.)*
5. **Redespliegues y un reinicio de Jicofo (12:55)** con gente dentro.
   Además de las molestias, cada reconexión deshacía cualquier
   des-silenciado que hubiera, lo que hacía que el problema pareciera
   aleatorio.
6. Lo que **no** hicimos mal: la configuración final es la original, y la
   causa de fondo (H1) existía antes de hoy. Solo aparece cuando un
   **residente** (no el admin) comparte con la moderación de vídeo activa.

---

## 7. Confirmación en producción (2026-11-02, hora de Bogotá)

Sala `asamblea-5cb1d58c…`, con la moderación de audio y vídeo activa.
Extraído de `docker logs` de `jitsi-jvb` y `jitsi-jicofo` (solo lectura):

| Hora | Componente | Evento |
|---|---|---|
| 12:19:39 | Jicofo | Entra el admin `6d3a42a2` (`role=OWNER`) |
| 12:20:08 | Jicofo | Entra el residente `79924f72` (Jack-Bs9, `role=PARTICIPANT`) |
| 12:20:10 | JVB | `epId=79924f72 … Muting incoming video` (silenciado al entrar) |
| 12:20:25 | JVB | `79924f72-v1 … videoType="desktop"`: empieza a compartir. **No se ve** |
| 12:33:36 | Jicofo | `Setting whitelist for VIDEO: […, 79924f72]` ← admin: **"Habilitar cámara"** |
| 12:33:42.400 | Jicofo | `Will unmute 79924f72 on behalf of 79924f72 for VIDEO` |
| 12:33:42.437 | JVB | `epId=79924f72 … Unmuting incoming video` → **la pantalla se ve** (confirmado por el autor) |

En la misma sala, a las 12:33:21–12:33:33, otro residente (`f30c0f56`)
recibió "Habilitar cámara" y después "Apagar cámara": el JVB también pasó a
`Unmuting incoming video` (confirma la variante A′ de SOLUCION §a).

**Conclusión:** H1 confirmada. El procedimiento es **habilitar la cámara de
quien comparte**. El bloqueo se levanta con la petición de unmute de vídeo que
llega después de la aprobación. *A verificar:* si esa petición la envía el
cliente solo (el residente ya estaba compartiendo) o si el residente pulsó la
cámara. Por eso el procedimiento incluye "encender la cámara un momento" si a
los 10 s no se ve.
