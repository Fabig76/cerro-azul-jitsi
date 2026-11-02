# Solución: la pantalla compartida no llega a los demás

> Complementa a [`INVESTIGACION-PANTALLA.md`](INVESTIGACION-PANTALLA.md)
> (§0, §3.2 y §7). Escrito el 2026-11-02 y corregido ese mismo día, tras
> **confirmarse en producción** a las 12:33 (hora de Bogotá).
> **No se ha cambiado código.** La solución es un procedimiento del operador.

> **Compartir pantalla requiere que el administrador habilite la cámara
> de quien comparte.** Es contraintuitivo, pero así funciona Jitsi
> `stable-11031` con la moderación de vídeo activa.

## La causa, en una frase

Con la **moderación de vídeo** activa (la sala de moderación del panel la
activa siempre al entrar el admin), Jicofo ordena al JVB `forceMuteVideo`
para cada residente que entra. El JVB silencia **por endpoint, no por
pista**, así que descarta todo el vídeo del residente, **también la pantalla**
(`-v1`, `videoType=desktop`). El residente ve su propia pantalla porque la
vista es local. Los demás no ven nada. El admin es moderador y nunca recibe
`forceMuteVideo`, así que su pantalla siempre llega.

El silenciado se levanta cuando Jicofo procesa una petición de silenciar o
des-silenciar el vídeo de ese residente (`handleMuteRequest`) **y** este ya
está autorizado. "Habilitar cámara" (`approveVideo`) es lo que lo autoriza
(lo mete en la whitelist de vídeo).

---

## a) Procedimiento operativo (la solución)

### Pasos

1. **Moderación de vídeo activada** (audio + vídeo). Es la configuración
   recomendada para asambleas grandes y la que pone el panel solo.
2. El residente que va a compartir **levanta la mano**.
3. El admin, en la fila de ese residente: **"Habilitar cámara"**.
4. El residente pulsa **"Compartir pantalla"**. En unos segundos la ven todos.
5. Si **no** aparece en unos 10 s: el residente **enciende su cámara** un
   momento (ya le está permitido) y puede volver a apagarla. Eso manda la
   petición de des-silenciado que levanta el bloqueo.
6. **Si el residente recarga o se reconecta, hay que repetirlo desde el paso 3.**
   Cada entrada nueva es un endpoint nuevo y vuelve a aplicarse el silenciado.

### Por qué el paso 5

Lo que levanta el silenciado en el JVB no es la whitelist en sí, sino la
**siguiente petición de mute/unmute de vídeo** que procesa Jicofo para ese
residente. Los logs lo muestran en los tres casos que tenemos:

| Fecha y hora (Bogotá) | Residente | Qué pasó | Resultado en el JVB |
|---|---|---|---|
| 2-nov 12:33:36 → 12:33:42 | `79924f72` (Jack-Bs9), ya compartiendo desde 12:20:25 | Admin: "Habilitar cámara" → 6 s después, Jicofo: `Will unmute 79924f72 on behalf of 79924f72 for VIDEO` | `12:33:42.437 Unmuting incoming video` → **la pantalla se vio** (confirmado por el autor) |
| 1-nov 10:47:34 → 10:47:37 | `3fadf6ff` (Ward-Hbn) | Admin aprueba vídeo → el residente enciende la cámara (`Will unmute … for VIDEO`) | Desbloqueado. Compartió a las 10:50:28 y **se vio** |
| 1-nov 12:13:38 | `e0dae905` (Savannah-pVK) | Admin aprueba vídeo **antes** de que comparta; ninguna petición de unmute después | Siguió `MUTED`. Compartió a las 12:14:16 y **no se vio** |

*A verificar:* si el `Will unmute` del 2-nov lo envió el cliente solo, al
recibir la aprobación con la pantalla ya activa, o si el residente pulsó la
cámara. El paso 5 cubre los dos casos.

### Verificarlo en el momento

Ver §b, paso 2: tras el paso 3–5 el JVB debe registrar
`Unmuting incoming video` para ese endpoint.

### Alternativas (si el procedimiento no basta)

| # | Alternativa | Comentario |
|---|---|---|
| A′ | Admin pulsa **"Apagar cámara"** sobre el residente | También levanta el silenciado: `handleMuteRequest` calcula `!permitido(VIDEO) && !permitido(DESKTOP)` y con la moderación de pantalla apagada da `false`. Comprobado el 1-nov 12:04:50 (`b7be1ba0`) y el 2-nov 12:33:33 (`f30c0f56`). Es menos claro para el operador ("apagar" para "que se vea") y depende de un detalle interno de Jitsi: **plan B, no el procedimiento normal** |
| A″ | Que comparta el **admin** (el residente le pasa el documento) | Siempre funciona: el moderador no recibe `forceMuteVideo` |
| B | Modo "reunión pequeña": en esas reuniones el panel activa solo la moderación de **audio** | Requiere cambiar `page_sala.html`, `app.py` y la BD. Sin moderación de vídeo no hay `forceMuteVideo`. **No aplicado** |
| D | Parchear Jicofo (`ParticipantInviteRunnable`) para que `forceMuteVideo` mire también DESKTOP | Fork de Jicofo y reinicio con la sala vacía. **No aplicado**; abrir antes un issue upstream |
| E | Actualizar a `stable-11248-2` | **No arregla la causa**: el código de `ParticipantInviteRunnable` es idéntico en master (INVESTIGACION F9). Solo mejora el problema secundario de ancho de banda |

---

## b) Diagnóstico en 2 minutos (mientras ocurre)

Todo es **solo lectura**. Desde el host de desarrollo. Las horas del log
están en hora de Bogotá.

**Paso 1. ¿Quién está compartiendo? (endpoint emisor)**

```bash
ssh chatbotph 'docker logs jitsi-jvb --since 15m 2>&1 | grep -o "name=\"[0-9a-f]*-v1\" ssrc=\"[0-9]*\" videoType=\"desktop\"" | cut -d\" -f2 | sort -u'
```

Devuelve algo como `e0dae905-v1`: el endpoint es `e0dae905`. Si no devuelve
nada, la pantalla **no llegó al JVB** (permisos del navegador del emisor,
o no llegó a compartir). Es otro problema.

**Paso 2. ¿El JVB está silenciando ese endpoint?**

```bash
EP=e0dae905   # el del paso 1
ssh chatbotph "docker logs jitsi-jvb --since 4h 2>&1 | grep 'epId=$EP' | grep forceMuteVideo | tail -1"
```

| Última línea | Significa | Qué hacer |
|---|---|---|
| `… Muting incoming video` | **Es esta causa.** El JVB tira la pantalla | Procedimiento de §a (pasos 3–5). Repetir el paso 2: debe salir `Unmuting incoming video` |
| `… Unmuting incoming video` | El JVB sí reenvía | Paso 3 |
| Nada | El emisor es moderador o la moderación de vídeo no está activa | Paso 3 |

**Paso 3. ¿Algún receptor con poca banda?**

```bash
ssh chatbotph 'docker logs jitsi-jvb --since 15m 2>&1 | grep "insufficient bandwidth"'
```

- `Sources suspended … (bwe=NNN bps): [<EP>-v1]` con `bwe` bajo (menos de
  unos 500 kbps): **ese receptor concreto** ve negro por su red. Los demás
  sí la ven. Solución: mejor conexión en ese receptor; en el servidor no hay
  nada que tocar.
- Nada: paso 4.

**Paso 4.** Si nada de lo anterior lo explica, pedir al receptor la consola
del navegador (F12) y buscar `VideoSourcesMap` y el `SourceInfo` del emisor
(`<EP>-v1 … "videoType":"desktop","muted":false`). Guardarla y avisar
(hipótesis H3 de la investigación).

---

## c) Reglas para no romper una asamblea

- **No reiniciar ni recrear** `web`, `jicofo`, `jvb` ni `prosody` con gente
  dentro. Recrear `web` corta la señalización de todos; reiniciar Jicofo tira
  todas las conferencias (pasó el 1-nov a las 12:55).
- Antes de reiniciar algo, comprobar que no hay nadie (los dos deben dar 0):

```bash
ssh chatbotph 'docker exec jitsi-jvb curl -s http://127.0.0.1:8080/colibri/stats | tr "," "\n" | grep -E "\"conferences\"|\"participants\""'
ssh chatbotph 'docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats | tr "," "\n" | grep -E "\"conferences\"|\"participants\""'
```

- **No pedir a los residentes que "recarguen a ver si se arregla".** Con esta
  causa, recargar **lo vuelve a romper**: endpoint nuevo, silenciado nuevo.
- `scripts/probar-sala-prod.py` usa clientes headless: sirve para la
  moderación, **no** para la pantalla. "El JVB recibe la pantalla" no prueba
  que otro la vea. Hacen falta dos personas reales.

---

## d) Falsas pistas: qué NO volver a intentar

| Intento | Por qué está descartado (evidencia) |
|---|---|
| `desktopSharingResolution` (1080p, 800×600) | Se probó el 1-nov (`ce48ac9`, `99ffbe7`): pantalla en negro las dos veces. Esas pruebas coincidieron con reconexiones (`MUTED`), no con la resolución. El fallo es que el JVB no reenvía paquetes; la resolución solo cambia cuántos bits llevan |
| `maxFullResolutionParticipants = 2` | Actúa sobre la selección del receptor, no sobre el descarte en la entrada del JVB |
| `channelLastN` (4, 15…) | Con 3–5 participantes y `lastN=4` la pantalla cabe. La que se vio el 1-nov (10:50) y la del 2-nov (12:33) se reenviaron con `lastN=4` |
| `source-add: 0` / `groups=[]` en Jicofo | **Normal** con SSRC rewriting (`use-ssrc-rewriting = true`): Jicofo nunca envía `source-add` a los receptores; las fuentes las anuncia el JVB por el canal de datos (código de Jicofo y respuesta del equipo de Jitsi en jicofo#1315) |
| `insufficient bandwidth` como "la causa" | Solo explica casos de **un receptor** con poca banda (346 kbps el 1-nov 10:50; 285 → 30 kbps a las 11:51). Solo aparece si el emisor ya está des-silenciado. No explica "no lo ve nadie" |
| Moderación de `desktop` (`toggleModeration(..., "desktop")`) | Nunca llegó a activarse el 1-nov (0 `Setting enabled=true for DESKTOP` en Jicofo). El iframe API de 11031 no tiene `approveDesktop` |
| Quitar o poner `desktop` en la barra | Solo cambia si aparece el botón |
| Subir el log de Jicofo a DEBUG | Exige reiniciar Jicofo y no aporta nada (los mensajes relevantes ya son INFO/WARN) |
| Activar P2P | Solo arreglaría salas de 2 personas; la Fase 3 lo desactiva a propósito |
| Actualizar Jitsi "porque el foro dice que se arregló" | El usuario de jicofo#1315 tenía otro problema. El código que nos afecta es idéntico en `stable-11248` y en `master` |
| Redesplegar o reiniciar durante una asamblea "para probar" | Cada reconexión reaplica el silenciado y hace que el fallo parezca aleatorio |

---

## e) ¿Es un bug de Jitsi?

Es una **incoherencia de Jitsi**, presente en 11031, en 11248-2 y en `master`
(a 2026-10-27). El silenciado del bridge es un único interruptor de "vídeo"
para cámara y pantalla. Al entrar, se decide solo con la moderación de VIDEO.
Al pedir un mute/unmute, se decide con VIDEO **y** DESKTOP. Con la moderación
de vídeo activa y la de pantalla inactiva, la UI deja compartir pero el bridge
descarta la pantalla. No hay issue abierto upstream (búsqueda del 2026-11-02).

### Pendientes detectados de paso (no tocados)

- `activarModeracion()` se ejecuta dos veces al entrar el admin (avisos
  `Concurrent moderator enable/disable` en Prosody). Inofensivo.
- La barra reducida del residente viaja en la *query* y Jitsi la ignora
  (INVESTIGACION §3.3).
- El mensaje del commit `140cd43` atribuye el fallo a una moderación de
  `desktop` que nunca se activó. Los mensajes de commit no se reescriben;
  la versión correcta está en este documento.
