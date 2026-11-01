# SPEC — Grabación de la asamblea en el PC del administrador

> **Estado:** auditado, aprobado e **implementado** (Fase 2, 2026-11-01). Ver §10 para las decisiones del autor y las desviaciones. Pendiente: verificación en los PCs reales ([`GRABACION-PASO0.md`](GRABACION-PASO0.md)).
> **Fecha:** 2026-11-01 · **Alcance:** `admin-panel/app/page_sala.html`, `admin-panel/app/static/` (+ 1 línea de `app.py`), `web/config/custom-config.js` (solo si se elige la alternativa A2).
> **Wireframes:** [`SPEC-GRABACION-mockups.md`](SPEC-GRABACION-mockups.md)

Convenciones: **[V]** = verificado en este repo o en el bundle de Jitsi que sirve producción (`https://meet.urbcerroazul.com/libs/app.bundle.min.js`, stable-11031). **[P0]** = hay que confirmarlo en el *paso 0* (prueba de verificación, §8) en los PCs reales del administrador antes de escribir código. El resto es diseño.

---

## 0. Hallazgos del código que cambian el enfoque

Antes del diseño, cuatro cosas que encontré al leer el código y que contradicen o matizan el brief:

### H1. El iframe de Jitsi NO es cross-origin: es del mismo origen que el panel [V]

`infra/caddy/meet.urbcerroazul.com.caddy` sirve **el panel y Jitsi desde el mismo host**: `/admin*` va a `admin:8081` y todo lo demás a `web:80`, ambos bajo `https://meet.urbcerroazul.com`. `page_sala.html` crea el iframe con `CFG.domain` = ese mismo host. Por tanto, la página `/admin/reunion/<id>/sala` y el iframe `https://meet.urbcerroazul.com/<sala>` son **del mismo origen** (mismo esquema, host y puerto).

Consecuencias:
- La premisa "no se puede leer el audio del iframe por CORS" **no se cumple aquí**. En teoría, el panel podría entrar en `iframe.contentWindow` y sacar las pistas de audio de los `<audio>` de Jitsi **sin `getDisplayMedia` y sin ningún diálogo**.
- **Igual lo descarto** como vía principal: depende de detalles internos de Jitsi (el DOM y el global `APP`, que no son API pública), se rompe en silencio al actualizar `JITSI_IMAGE_VERSION`, solo daría audio (sin video) y obligaría a seguir a mano qué `<audio>` aparecen y desaparecen. Lo dejo documentado como alternativa D (§1) por si el autor prefiere "solo audio y cero diálogos".
- Si algún día el panel y Jitsi se separan en dominios distintos, H1 deja de valer y la alternativa A2 (abajo) también deja de funcionar embebida.

### H2. Jitsi stable-11031 ya trae "grabación local" en el navegador [V]

El bundle de producción incluye un `LocalRecordingManager` que hace casi exactamente lo que pide el brief:
- `getDisplayMedia({video:{displaySurface:"browser",frameRate:30}, audio:{autoGainControl:false, echoCancellation:false, noiseSuppression:false, suppressLocalAudioPlayback:false, …}, preferCurrentTab:true, surfaceSwitching:"exclude"})`.
- **Mezcla con WebAudio el audio de la pestaña y el micrófono local** (el del propio grabador).
- Escribe a disco **por trozos** (`MediaRecorder.start(5000)` + `showSaveFilePicker` + `createWritable`). Al terminar corrige la duración del WebM reescribiendo el primer trozo.
- Formato fijo `video/webm;codecs=vp8,opus` y `videoBitsPerSecond: 2.5 Mbps`.
- Si no hay pista de audio, lanza el error `NoAudioTrackFound`. **No mide si el audio está mudo.**
- Solo funciona en Chromium de escritorio, y **embebido solo si el padre está en el mismo host** (`window.self.location.host === window.parent.location.host`), que es nuestro caso (H1).
- Se puede arrancar desde el panel: `api.executeCommand('startRecording', {mode:'local', onlySelf:false})`, y el panel recibe el evento `recordingStatusChanged` con `mode:"local"`.
- Puede avisar a todos los participantes (`localRecording.notifyAllParticipants`) con el texto "`{{name}}` has started a local recording".

Eso es una **alternativa A2** seria (ver §1). Veredicto: **no la tomo como principal** porque no deja controlar justo lo que el brief considera crítico:
- no comprueba el nivel de audio antes de empezar;
- el nombre del archivo es `<sala>_<ISO>.webm`, y la sala es un hex aleatorio, ilegible para la administración;
- el bitrate fijo de 2.5 Mbps da ≈ 4.7 GB en 4 h;
- el aviso a los asistentes sale como notificación pasajera (y nuestra lista blanca de `config.notifications` la **filtraría**: habría que añadir las claves);
- los diálogos son de Jitsi, dentro del iframe, y no se pueden adaptar.

Sí **copio sus técnicas probadas**: `preferCurrentTab`, constraints de audio, mezcla con el micro, trozos de 5 s y comprobación de la superficie con *Capture Handle*.

### H3. El `<script>` de `page_sala.html` está congelado (regla D8 de `SPEC-DISENO.md` §4.6) y `api` es privado

El script final es una IIFE: `api` y `CFG` son variables locales, y el rediseño exigió copiar ese bloque **byte a byte**. La grabación necesita `api`: para saber si el admin tiene el micro silenciado, cambiar el *subject*, escuchar `videoConferenceLeft` y leer `getCurrentDevices()`. Hay dos salidas:
- **(recomendada) Sin tocar D8:** cargar `grabacion.js` **entre** `external_api.js` y el script congelado, y que **envuelva** el constructor `window.JitsiMeetExternalAPI` para quedarse con la instancia (y con `options.jwt`, de donde sale la hora de vencimiento). El script congelado no cambia ni un byte; `typeof JitsiMeetExternalAPI` sigue siendo `"function"`.
- (alternativa) Romper D8 a sabiendas con una línea `window.CA_SALA = {api: api};`. Es más legible, pero hay que actualizar el `diff` de verificación.

**Decisión del autor** (pregunta Q1).

### H4. Lo que se captura es la pestaña entera, panel lateral incluido

Capturar la pestaña graba **todo lo visible**: la cabecera, la lista de participantes con sus nombres, los botones de moderación y el registro técnico. Para que la grabación muestre solo la reunión se usa **Region Capture** (`CropTarget.fromElement()` + `track.cropTo()`, Chromium ≥ 104, solo cuando la pestaña se captura a sí misma). Eso **obliga a envolver `#jitsi`** en un contenedor nuevo (`.grab-zona`) que también contiene el aviso legal visible (§6). `#jitsi` conserva su `id` y queda vacío para el iframe, así que el contrato se respeta. Pero el `position: sticky` que hoy tiene `#jitsi` en ≥ 1024 px (`theme.css`) pasa al contenedor.

Observaciones menores:
- No hay `Permissions-Policy` en `/admin*`, así que `display-capture` está permitido para `'self'` por defecto [V].
- `external_api.js` ya pone `display-capture` en el `allow` del iframe [V].
- `theme.js` pesa 6.8 KB, no ≤ 3 KB como dice el brief. No afecta: la grabación va en un archivo aparte.

---

## 1. Análisis de alternativas

| Criterio | **A1** `getDisplayMedia` + `MediaRecorder` propio (`grabacion.js`) | **A2** Grabación local nativa de Jitsi, arrancada por API | **B** Jibri en el servidor | **C** OBS manual en el PC | **D** Audio del iframe por mismo origen (H1) |
|---|---|---|---|---|---|
| Dónde corre | PC del admin | PC del admin | Servidor (4 vCPU, 3.1 GB libres) | PC del admin | PC del admin |
| Carga en el servidor | Ninguna | Ninguna | 2–4 núcleos + Chrome headless: **degrada la asamblea** | Ninguna | Ninguna |
| Clics del admin | 1 nuestro + "Compartir" de Chrome | 1 + selector de archivo + "Compartir" | 0 (botón) | Muchos, fuera del portal | 0 diálogos (solo el botón) |
| Comprobación de audio antes de empezar | **Sí** (diseñada, §3.4) | No (solo "¿hay pista?") | n/a | Manual (vúmetro de OBS) | Sí |
| Nombre de archivo legible | Sí | No (`<hex>_<ISO>`) | Configurable | Manual | Sí |
| Tamaño 4 h | ≈ 2 GB (configurable) | ≈ 4.7 GB (fijo) | Configurable | Configurable | ≈ 0.17 GB (solo audio) |
| Video | Sí, recortado a Jitsi | Sí, pestaña entera | Sí | Sí | **No** |
| Sobrevive a que se caiga el PC | Parcial (trozos en OPFS, §4.6) | Parcial (trozos en archivo; ver riesgo `.crswap`) | **Sí** | Parcial | Parcial |
| Graba si el admin entra por móvil | No | No | **Sí** | No | No |
| Aviso a los asistentes | Subject + chat + franja dentro del video (§6) | Notificación de Jitsi (hay que permitirla en la lista blanca) | Etiqueta REC nativa | Ninguno | Igual que A1 |
| Dependencia de detalles internos de Jitsi | Baja (solo API pública del iframe) | Media (comando público, comportamiento interno) | Alta (otro servicio) | Ninguna | **Alta** (DOM/`APP`) |
| Mantenimiento | ~1 archivo JS + CSS | Config + pocas líneas | Contenedor, VPS más grande | Formación | Frágil en cada actualización |

**Veredicto: A1.** Es la única opción que hace que el **riesgo principal** (grabación muda) sea *comprobable antes de empezar*, que da un archivo con nombre útil y tamaño controlado, que no toca el servidor y que solo usa la API pública del iframe más las API estándar del navegador. A2 es el **plan B**: si A1 se complica, A2 se activa con ~10 líneas de configuración, aceptando sus limitaciones. B queda descartada por CPU: un Jibri en la misma máquina competiría con el JVB durante la asamblea de 500 personas, que es justo lo que la Fase 3 optimizó. C se descarta por operativa: fuera del portal, sin aviso legal integrado y con mucha formación.

**Qué se pierde con A1, dicho claramente:**
1. **Si el PC del admin se cae, se apaga o Chrome se cierra de golpe, la grabación se corta.** Con el guardado incremental (§4.6) se conserva hasta los últimos ~5 s, no todo; sin él, se pierde entera.
2. **Si el admin entra desde un móvil o una tablet, no hay grabación.** No es un fallo del diseño: los navegadores móviles no tienen `getDisplayMedia`.
3. **La grabación es "lo que oye y ve el admin".** Si su conexión empeora, la grabación lo refleja: cortes, video congelado, participantes que el JVB no le reenvía (`channelLastN = 4`). Jibri sería un participante más con su propia conexión, igual de limitado por `lastN`.
4. **No existe la grabación sin clics.** `getDisplayMedia()` exige siempre la confirmación del usuario. El mínimo real es **1 clic nuestro + 1 clic en el diálogo de Chrome** (§3.2).

---

## 2. Compatibilidad macOS + Windows

### 2.1 Tabla por navegador

| Capacidad | Chrome macOS | Chrome Windows | Edge macOS | Edge Windows | Safari macOS | Firefox macOS / Windows |
|---|---|---|---|---|---|---|
| `getDisplayMedia` de **pestaña** | Sí | Sí | Sí | Sí | **No** (solo pantalla/ventana) | **No** (solo pantalla/ventana) |
| **Audio de la pestaña** | Sí (casilla) | Sí (casilla) | Sí (casilla) | Sí (casilla) | **No** | **No** (ver nota F) |
| Audio del sistema con pantalla completa | No fiable / según versión de macOS [P0] | Sí ("Compartir audio del sistema") | Ídem Chrome | Sí | No | No |
| `preferCurrentTab` (ofrecer solo esta pestaña) | Sí (≥ 94) | Sí | Sí | Sí | No | No |
| Region Capture `cropTo` | Sí (≥ 104) | Sí | Sí | Sí | No | No |
| Capture Handle (saber que es *esta* pestaña) | Sí (≥ 102) | Sí | Sí | Sí | No | No |
| OPFS + `createSyncAccessHandle` (§4.6) | Sí | Sí | Sí | Sí | Sí | Sí |
| `MediaRecorder` produce | WebM VP8/VP9 + Opus; MP4 H.264 en versiones recientes [P0] | Ídem | Ídem | Ídem | MP4 H.264 + AAC | WebM VP8 + Opus |
| Screen Wake Lock | Sí | Sí | Sí | Sí | Sí (≥ 16.4) | No |

**Nota F (corrección al brief).** El brief dice que Firefox permite `{video:false, audio:true}` para grabar solo audio. Según lo que sé de la especificación de Screen Capture, `getDisplayMedia` **rechaza `video:false` con `TypeError` en todos los navegadores**, y Firefox **no entrega audio** en `getDisplayMedia`. No lo he podido probar desde aquí: queda como **[P0]**. No cambia la recomendación, pero si es cierto, Firefox no sirve ni para grabar solo audio.

Lo que sí es posible **en Chrome** es grabar **solo el audio**: se pide la pestaña con video (obligatorio), pero al `MediaRecorder` se le pasa **solo la pista de audio** mezclada → `audio/webm;codecs=opus`. Video capturado pero no grabado (pregunta Q4).

### 2.2 Recomendación: **Google Chrome (escritorio) en los dos sistemas**; Edge aceptado como equivalente en Windows

Por qué:
- **Es el único motor con todo lo que el diseño necesita**: pestaña con audio, `preferCurrentTab`, Region Capture, Capture Handle y OPFS. Chrome y Edge son el mismo motor (Chromium), pero conviene **un único navegador oficial** para tener **un solo juego de instrucciones y capturas** en macOS y Windows. Los textos del diálogo de compartir varían entre Chrome y Edge y entre versiones.
- Safari queda descartado: no captura pestañas ni audio. Una grabación de Safari sería pantalla sin sonido.
- Firefox queda descartado: no captura audio con `getDisplayMedia` (nota F).
- Edge en Windows viene instalado. Si el admin lo usa, funciona igual; solo cambian los textos del diálogo, que se documentan aparte (pregunta Q2).

El panel **detecta el motor por capacidades** (§3.1), no por la cadena *User-Agent*, y en Safari o Firefox muestra "Para grabar, abre esta página en Google Chrome".

### 2.3 Avisos por sistema operativo

**macOS**
- **Micrófono:** Ajustes del Sistema → Privacidad y seguridad → **Micrófono** → Google Chrome activado. Ya hace falta para hablar en Jitsi.
- **Grabación de pantalla:** Ajustes del Sistema → Privacidad y seguridad → **Grabación de pantalla y audio del sistema** (macOS 15; "Grabación de pantalla" en macOS 13–14) → Google Chrome. Corrijo el brief: este permiso es **obligatorio para compartir una ventana o la pantalla** (por ejemplo, el botón "Compartir pantalla" de Jitsi para presentar documentos), pero **no debería serlo para capturar una pestaña de Chrome**, porque Chrome se captura a sí mismo **[P0]**. La guía del admin lo recomendará igualmente, porque lo necesita para presentar.
  - Al concederlo, macOS **obliga a reiniciar Chrome**. Por eso hay que hacerlo **antes** del día de la asamblea, nunca durante.
  - macOS 15 vuelve a pedir esa confirmación cada cierto tiempo. Conviene probar el día anterior.
- **Energía:** con el portátil cerrado o el Mac en reposo se corta todo. El panel pide *Screen Wake Lock* mientras graba (§4.6), pero si el portátil va con batería y se cierra la tapa, no hay mitigación posible.

**Windows**
- No hace falta ningún permiso del sistema para capturar la pestaña.
- **Micrófono:** Configuración → Privacidad y seguridad → **Micrófono** → "Permitir que las aplicaciones de escritorio accedan al micrófono" activado. Ya hace falta para Jitsi.
- **Energía:** Configuración → Sistema → Inicio/apagado y batería → que **no suspenda** durante la asamblea. Wake Lock evita que se apague la pantalla, pero no siempre gana a una directiva de energía de la empresa.
- **Disco:** la grabación crece ≈ 0.5 GB/h en el disco del sistema (perfil de Chrome) y después se copia a Descargas. Hay que tener al menos el doble del tamaño previsto libre.

**Los dos**
- **Auriculares muy recomendados.** Con altavoces, el micro del admin recoge la voz de los asistentes, y la grabación tendría eco: la voz directa de la pestaña más la que se cuela por el micro. La cancelación de eco de Chrome debería quitarlo, pero hay que comprobarlo **[P0]**.

---

## 3. Diseño funcional

### 3.1 Detección del dispositivo y del navegador (al cargar la sala)

Se decide **por capacidades**, en este orden, y el resultado determina el estado de la tarjeta "Grabación":

| # | Condición | Estado de la tarjeta | Mensaje |
|---|---|---|---|
| 1 | `navigator.userAgentData?.mobile === true`, **o** `matchMedia('(pointer: coarse)')` sin `(any-pointer: fine)`, **o** iPadOS (`navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1`), **o** no existe `navigator.mediaDevices.getDisplayMedia` | Botón **deshabilitado** | "La grabación solo funciona en un computador (Chrome en macOS o Windows). Desde este dispositivo puedes moderar, pero **la asamblea no se está grabando**." (aviso `alert--warn`) |
| 2 | No existe `CropTarget` **o** no existe `MediaStreamTrack.prototype.getCaptureHandle` (no es Chromium) | Botón **deshabilitado** | "Para grabar, abre esta página en **Google Chrome**. Este navegador no puede grabar el sonido de la reunión." |
| 3 | `MediaRecorder.isTypeSupported` no admite ninguno de los formatos de §4.2 | Deshabilitado | "Este navegador no puede crear el archivo de grabación. Actualiza Chrome." |
| 4 | Hay una grabación anterior sin terminar en OPFS (§4.6) | Activo + **aviso de recuperación** | "Hay una grabación anterior que no se guardó (… min, … MB). [Descargar] [Descartar]" |
| 5 | Todo bien | **Activo** | — |

Por qué por capacidades: el *User-Agent* miente (Edge, Brave, iPad "de escritorio"). Lo que importa es si las API existen. El caso móvil se detecta explícitamente **para avisar**, no solo para ocultar: el riesgo real es que el admin crea que está grabando.

### 3.2 Flujo paso a paso

```
[Inactivo] --clic "Grabar esta reunión"--> [Diálogo de instrucciones]
[Diálogo]  --clic "Continuar"--> getDisplayMedia() --> diálogo de Chrome --> "Compartir"
                                          |                               '-- "Cancelar" --> [Inactivo] + aviso neutro
                                          v
                               [Comprobando] (automático, ~3 s)
                                 a) ¿superficie = esta pestaña?  no --> [Error: pestaña equivocada] -> reintentar
                                 b) ¿hay pista de audio?          no --> [Error: casilla de audio] -> reintentar
                                 c) bip de prueba captado?        no --> [Error: audio mudo] -> reintentar | "grabar sin audio" (confirmación)
                                 d) micrófono                     (informativo, no bloquea)
                                          | todo OK
                                          v
                               [Grabando]  (empieza solo, sin otro clic)
                                 - punto rojo pulsante + 00:00:00 + "≈ 0 MB"
                                 - subject de Jitsi + chat + franja "Esta asamblea se está grabando"
                                 - beforeunload activo, Wake Lock
[Grabando] --clic "Detener y guardar" (confirmación)--> [Guardando] --> descarga --> [Guardado]
[Grabando] --Chrome "Dejar de compartir" / colgar en Jitsi / límite de duración--> [Guardando] (automático)
```

**Clics reales:** 1 ("Grabar esta reunión") + 1 ("Continuar" de nuestro diálogo) + 1 ("Compartir" de Chrome). Tras la primera grabación correcta, el diálogo ofrece "No volver a mostrar estas instrucciones" (en `localStorage`). A partir de ahí, **"Grabar esta reunión" llama directamente a `getDisplayMedia`**: **1 clic nuestro + 1 de Chrome**, que es el mínimo posible. Las comprobaciones **no se saltan nunca**, aunque se oculten las instrucciones.

**Por qué empieza sola tras las comprobaciones:** el brief pide "1 decisión + 1 clic". La decisión ya se tomó al pulsar "Grabar"; un botón "Empezar" extra no añade seguridad. Las comprobaciones son las que dan seguridad.

### 3.3 Botón y ubicación

Una **tarjeta nueva "Grabación"**, la **primera** del panel lateral (`.sala__lado`), por encima de "Estado de la moderación" (mockup M1). Va arriba porque es lo primero que se hace al abrir la asamblea y porque mientras graba tiene que estar siempre a la vista.

- La tarjeta es `<section class="card sala__card grab">`, **fuera** de `.gl`. Cualquier `<button>` dentro de `.gl` recibiría el listener del script congelado (contrato).
- `id`s nuevos con prefijo `grab-` (`#grab-btn`, `#grab-estado`, `#grab-tiempo`, `#grab-peso`, `#grab-dlg`). No coinciden con ningún `id` del contrato.
- En la cabecera (`.salahead__live`), mientras graba, el texto "Moderación en vivo" pasa a "**Grabando** · Moderación en vivo". Así el admin lo ve aunque haga scroll.

### 3.4 Diálogo previo de instrucciones

Es un `<dialog class="dialog">` estático en `page_sala.html`, con los estilos del sistema (`.dialog__title`, `.dialog__actions`). El texto depende de lo que muestre Chrome. Como pedimos `preferCurrentTab: true`, Chrome **debería** mostrar un diálogo simplificado ("¿Compartir esta pestaña?") y no el selector de 3 pestañas. **[P0]**: confirmar con capturas en macOS y Windows cuál aparece y los **textos exactos en español** antes de fijar las instrucciones.

Texto propuesto (variante con selector clásico, la del brief; se ajusta tras P0):

> **Antes de grabar**
> Chrome te va a preguntar qué compartir. Para que la grabación tenga sonido:
> 1. Elige **"Pestaña de Chrome"** → la pestaña **«Moderación · {título}»**.
> 2. Marca **"Compartir también el audio de la pestaña"**. **Sin esto la grabación sale sin voz.**
> 3. Pulsa **Compartir**.
>
> Después comprobaremos el sonido automáticamente (oirás un bip corto).
> ☐ No volver a mostrar estas instrucciones
> [Cancelar] [Continuar]

Variante con diálogo simplificado: "1. Comprueba que pone **esta pestaña**. 2. Deja **marcada** la casilla de audio. 3. Pulsa **Compartir**."

### 3.5 Comprobaciones antes de grabar (lo que impide la grabación muda)

Se hacen en este orden. Las tres primeras **bloquean**:

**a) Superficie correcta.** `track.getSettings().displaySurface === 'browser'` **y** `track.getCaptureHandle()?.handle === <handle aleatorio de esta carga>`. El handle se fija al cargar con `navigator.mediaDevices.setCaptureHandleConfig({handle, permittedOrigins:['*']})`. Si falla: "Elegiste otra ventana o pestaña. Hay que compartir **esta** pestaña." Se paran las pistas y se ofrece [Reintentar]. Ver §7, riesgo R2.

**b) Hay pista de audio.** `stream.getAudioTracks().length === 0` es **exactamente** lo que pasa cuando no se marca la casilla. Es una comprobación **determinista**, no estadística, y es la defensa principal contra el riesgo n.º 1. Si falla, se muestra en rojo: "**No marcaste "Compartir audio de la pestaña".** La grabación no tendría voz." [Reintentar] (vuelve a abrir el diálogo de Chrome). **No se ofrece continuar**: sin pista de audio no hay nada que mezclar.

**c) El audio llega de verdad: bip de prueba.** Una pista de audio puede existir y estar muda (pestaña silenciada, salida desviada…). Medir "unos segundos" el nivel no basta: en una sala recién abierta y con todos silenciados por la moderación, **el silencio es lo normal**, y un umbral sobre silencio real daría falsos "mudo". Por eso se **genera una señal conocida**:
- La página reproduce un **tono de 1 kHz durante 600 ms a −20 dBFS** (`OscillatorNode` → `GainNode` → `ctx.destination`). Suena por la pestaña, así que entra en la captura de pestaña. El admin lo oye; **los asistentes no** (la salida de audio de la pestaña no se envía a Jitsi).
- Se mide la pista capturada con un `AnalyserNode` (`fftSize 2048`, `getFloatTimeDomainData`, RMS cada 50 ms) **en una ventana de 1.5 s** desde el inicio del tono.
- **Criterio de "audio OK":** al menos 3 muestras consecutivas con RMS ≥ **−45 dBFS** (el tono llega a ~−20 dBFS; 25 dB de margen para atenuaciones del sistema).
- **Criterio de "mudo":** el RMS máximo en la ventana < **−60 dBFS**.
- **Zona intermedia** (entre −60 y −45): "El sonido llega muy bajo. Revisa el volumen de la pestaña." Se permite continuar.
- Si queda mudo: aviso rojo "**La grabación no capta el sonido de la reunión.**" Se ofrecen [Reintentar] y, debajo, un enlace secundario "Grabar sin sonido" que abre una **confirmación explícita** ("La grabación no tendrá voz. ¿Seguro?", botón de peligro). Se permite (no se bloquea del todo) porque puede haber casos legítimos: grabar solo la pantalla compartida.
- Si el AudioContext está suspendido (política de autoplay), se reanuda con `ctx.resume()`. Hay gesto de usuario reciente (el clic en "Continuar"), así que no debería fallar **[P0]**.

**d) Micrófono del admin (informativo).** La pestaña **no contiene la voz del propio admin**: Jitsi no reproduce el micro local. Hay que mezclarlo aparte (§4.3). Se pide `getUserMedia` con el **mismo dispositivo que usa Jitsi** (`api.getCurrentDevices()` → `audioInput.deviceId`). Si se deniega o falla: aviso ámbar "**Tu voz no quedará en la grabación** (no hay acceso al micrófono)". Se permite continuar, porque el resto de la sala sí se graba. No se mide el nivel del micro: el admin está callado mientras lee el diálogo, y un umbral daría falsos avisos.

### 3.6 Indicador mientras graba

En la tarjeta (mockup M3):
- **Punto rojo pulsante** (`.live-dot`, ya existe; respeta `prefers-reduced-motion`).
- **Duración** `HH:MM:SS`, desde `MediaRecorder` `onstart`, actualizada cada segundo, con `font-variant-numeric: tabular-nums` (`.num`).
- **Peso real** (no estimado): suma de `event.data.size` de los trozos escritos, en MB/GB con 1 decimal. Debajo, "≈ X MB/hora" calculado sobre la media de los últimos 5 min. Así el admin ve que el archivo **crece**: si el peso deja de crecer, algo va mal.
- **Vúmetro** pequeño de 5 barras con el nivel de la mezcla. Sirve para ver que entra sonido mientras habla alguien.
- **Estado del micro:** "Tu micro: en la grabación" / "Tu micro: silenciado (no se graba)". Ver §4.3.
- **Vigilancia de silencio:** si la mezcla está por debajo de −60 dBFS durante **10 min seguidos**, aviso ámbar no bloqueante: "Hace 10 min que no se graba sonido. ¿Está hablando alguien?". Diez minutos porque en una asamblea moderada puede haber pausas largas (lectura en silencio, votación).

### 3.7 "Detener y guardar"

Botón `btn--danger`, con confirmación (diálogo del sistema `theme.js`): "¿Detener la grabación? Se guardará el archivo en Descargas." Por qué confirmar: un clic accidental corta una asamblea que no se puede repetir.

Al detener: `recorder.stop()` → se escribe el último trozo → se cierra el archivo OPFS → se descarga con `<a download>` (§4.7). Se restaura el *subject* de Jitsi, se envía el mensaje de fin al chat, se libera el Wake Lock y se quita `beforeunload`. Estado "Guardado": nombre del archivo, duración y peso, más el enlace "Volver a descargar" (desde OPFS, por si la descarga falló).

### 3.8 Nombre del archivo

`Asamblea-<titulo-slug>-<YYYY-MM-DD>-<HHMM>.<ext>`
- Título: el `textContent` de `h1.salahead__title` (ya escapado por `app.py`; en el DOM es texto plano).
- Slug: NFD → quitar diacríticos → minúsculas → `[^a-z0-9]+` → `-` → recortar guiones → máximo 60 caracteres. **Si el slug empieza por `asamblea-`, se quita**, para no generar `Asamblea-asamblea-…`.
- Fecha y hora: **inicio de la grabación** en `America/Bogota` (`Intl.DateTimeFormat` con `timeZone`), igual que `fecha_col()` en `app.py`, sea cual sea la zona horaria del PC.
- `ext` = `webm` (o `mp4` si se elige Q3).
- Ejemplo: título "Asamblea Ordinaria 2026", inicio 15-nov-2026 09:05 → `Asamblea-ordinaria-2026-2026-11-15-0905.webm`.
- Si el slug queda vacío, se usa `reunion`.

### 3.9 Si el admin cierra la pestaña, recarga o se cae la conexión

| Evento | Comportamiento |
|---|---|
| Cerrar pestaña / recargar / navegar fuera | `beforeunload` con `preventDefault()`: Chrome muestra su diálogo genérico "¿Salir del sitio?". **No se puede personalizar el texto.** Si sale de todos modos, los trozos ya escritos en OPFS se conservan (§4.6) y al volver a la sala se ofrece recuperarlos. |
| Pulsa "Dejar de compartir" en la barra de Chrome | `track.onended` → **detener y guardar automáticamente** + aviso "La grabación se detuvo porque dejaste de compartir la pestaña. Archivo guardado." |
| Cuelga en Jitsi (botón *hangup*) | Evento `videoConferenceLeft` → detener y guardar automáticamente. No tiene sentido seguir grabando una sala vacía. |
| Se cae la red | Jitsi reconecta solo. La grabación **sigue** (graba lo que se ve: la pantalla de reconexión). No se detiene. Se escribe en `#log`. |
| Se cae la red y el JWT ya venció (fin + margen) | Jitsi no puede volver a entrar. Se detecta igual que el caso anterior; la grabación sigue hasta que el admin la detenga o salte el límite. Riesgo menor, documentado. |
| Chrome o el PC se cuelgan o se apagan | Se pierde lo que no se haya escrito (≤ 5 s con OPFS). Recuperación al volver (§4.6). |

---

## 4. Diseño técnico

### 4.1 Captura

```js
// Al cargar la página (una vez):
navigator.mediaDevices.setCaptureHandleConfig({ handle: HANDLE, permittedOrigins: ['*'] });

// En el clic (gesto de usuario):
const stream = await navigator.mediaDevices.getDisplayMedia({
  video: {
    displaySurface: 'browser',
    width:  { max: 1280 },
    height: { max: 720 },
    frameRate: { ideal: 15, max: 15 }
  },
  audio: {
    echoCancellation: false,   // es audio de la pestaña, no de un micro
    noiseSuppression: false,
    autoGainControl: false,
    suppressLocalAudioPlayback: false  // el admin tiene que seguir oyendo la sala
  },
  preferCurrentTab: true,          // ofrecer solo ESTA pestaña
  selfBrowserSurface: 'include',
  surfaceSwitching: 'exclude',     // sin "compartir esta pestaña en su lugar"
  monitorTypeSurfaces: 'exclude',  // no ofrecer pantalla completa
  systemAudio: 'exclude'
});
```

Por qué así:
- **720p a 15 fps:** Jitsi ya limita la pantalla compartida a 5–15 fps y la cámara a 360p (`custom-config.js`). Más resolución o más fps no añaden información y multiplican el tamaño.
- **Sin procesado de audio:** la cancelación de eco o el control de ganancia sobre el audio de la pestaña lo degradan (es lo mismo que hace Jitsi en su grabación local).
- `monitorTypeSurfaces: 'exclude'` y `preferCurrentTab` reducen el riesgo R2 en la propia interfaz de Chrome, antes de llegar a la comprobación.

**Recorte a la zona de Jitsi** (H4): `const t = await CropTarget.fromElement(document.querySelector('.grab-zona')); await videoTrack.cropTo(t);`. Si `cropTo` falla, se graba la pestaña entera y se muestra un aviso ("Se grabará también el panel lateral"). No se bloquea.

### 4.2 `MediaRecorder`

Formatos por orden de preferencia (el primero que pase `MediaRecorder.isTypeSupported`):

1. `video/webm;codecs=vp8,opus` — **preferido.** Es el más probado en Chromium (lo usa Jitsi), tiene coste de CPU bajo y el WebM truncado se puede recuperar.
2. `video/webm;codecs=vp9,opus` — ~30 % menos peso con la misma calidad, pero más CPU. Solo si VP8 no está.
3. `video/webm` — dejar que Chrome elija.
4. (Q3) `video/mp4;codecs=avc1.42E01F,mp4a.40.2` — Chrome reciente puede grabar MP4 directamente **[P0]**. Si funciona en los dos PCs, **elimina la conversión (§5)**. No es la opción por defecto hasta verificar dos cosas: que un MP4 fragmentado truncado por una caída se reproduce, y que el `isTypeSupported` es real en macOS y Windows.

Modo solo audio (Q4): `audio/webm;codecs=opus`, grabando únicamente la pista de la mezcla.

Parámetros:
```js
new MediaRecorder(mixedStream, {
  mimeType,
  videoBitsPerSecond: 1_000_000,
  audioBitsPerSecond: 96_000
});
recorder.start(5000);   // ondataavailable cada 5 s
```
Por qué 1 Mbps: con 720p a 15 fps, contenido casi estático (caras y documentos) y VP8, 1 Mbps es nítido para texto. 2.5 Mbps (lo que usa Jitsi) sobra. Por qué 96 kbps de Opus: voz con margen. 64 kbps bastaría para voz en mono, pero la mezcla puede llevar música o vídeos compartidos.

### 4.3 Grafo de WebAudio (todo en el cliente, nada sale al servidor)

```
 pista audio pestaña ──► MediaStreamSource(tab) ──────────────┬──────────────► MediaStreamDestination ──► pista "mezcla" ──┐
                                                              │                         ▲                                  ├─► MediaStream ──► MediaRecorder
 pista micro (getUserMedia,  ► MediaStreamSource(mic) ► Gain "puerta" (1 = abierto, 0 = silenciado en Jitsi)                  │
   mismo deviceId que Jitsi,                                                                                                  │
   echoCancellation:true)                                                                                                     │
                                                                                                                              │
 pista video (recortada) ─────────────────────────────────────────────────────────────────────────────────────────────────────┘

 Medición (sin sonido duplicado):
   MediaStreamDestination.stream ► MediaStreamSource ► AnalyserNode ► Gain(0) ► ctx.destination
   (bip de prueba)  Oscillator ► Gain(−20 dBFS) ► ctx.destination            (solo durante la comprobación)
```

Puntos clave y por qué:
- **Nunca se conecta el audio capturado a `ctx.destination` con ganancia distinta de 0.** La pestaña ya suena por sí misma. Conectarla otra vez **duplicaría la sala en los altavoces del admin**, y como la salida de la pestaña se captura, **crearía un bucle de realimentación**. El `AnalyserNode` se encadena a un `Gain(0)` hacia `destination` porque Chromium no procesa de forma fiable un nodo que no acaba en `destination`; con ganancia 0 no suena nada.
- El brief proponía `source → analyser → destination`. **Así tal cual no**: duplicaría el sonido. Con `Gain(0)` en medio sí.
- **Puerta del micro sincronizada con Jitsi:** `api.isAudioMuted()` al empezar y el evento `audioMuteStatusChanged` → `gain.setTargetAtTime(muted ? 0 : 1, now, 0.02)`. Por qué: el admin tiene el micro **silenciado en Jitsi** buena parte del tiempo; sin la puerta, la grabación captaría sus conversaciones privadas, que la sala no oyó. La grabación tiene que ser fiel a lo que se dijo en la asamblea.
- **El micro con `echoCancellation: true`:** esta pista sí es un micro y tiene que quitar lo que suena por los altavoces. Es una segunda captura del mismo dispositivo que ya usa Jitsi; Chrome lo permite **[P0]** (incluido que la cancelación de eco funcione en esta segunda pista).
- Si el admin cambia de micro en Jitsi (`deviceListChanged`/ajustes), se vuelve a abrir `getUserMedia` con el nuevo `deviceId` y se reconecta el nodo. La pista que va al `MediaRecorder` (la del `MediaStreamDestination`) **no cambia**, así que la grabación no se corta.
- **Ni un byte de audio ni de video sale del navegador hacia el servidor.** No hay `fetch`, `XMLHttpRequest`, `WebSocket` ni `sendBeacon` en `grabacion.js`. El servidor no se entera de que se graba (salvo el *subject* y el mensaje de chat de §6, que viajan por Jitsi como texto).

### 4.4 Tamaño estimado

Fórmula: `(video + audio) bit/s × 3600 / 8 = bytes/hora`.

| Perfil | Video | Audio | MB/hora | 4 h |
|---|---|---|---|---|
| **Recomendado** | 1.0 Mbps | 96 kbps | (1 096 000 × 3600) / 8 ≈ **493 MB** | ≈ **1.97 GB** |
| Económico | 0.6 Mbps | 64 kbps | ≈ 299 MB | ≈ 1.2 GB |
| Solo audio (Q4) | — | 96 kbps | ≈ 43 MB | ≈ 173 MB |
| Referencia: grabación nativa de Jitsi (A2) | 2.5 Mbps | ~128 kbps | ≈ 1.18 GB | ≈ 4.7 GB |

`videoBitsPerSecond` es un **objetivo**: con contenido estático VP8 suele quedarse por debajo, y con mucho movimiento puede pasarse ±30 %. Lo valida el criterio de aceptación de §8.

### 4.5 Trozos

`recorder.start(5000)`: un `dataavailable` cada **5 s**. Cada trozo se pasa al *worker* de escritura (§4.6) en cuanto llega. Por qué 5 s: es lo que usa Jitsi. Es un buen equilibrio: como mucho se pierden 5 s ante una caída, y son 720 escrituras por hora de ~340 KB, que no cuestan nada. Con 1 s serían 3 600 escrituras pequeñas por hora sin ganancia real.

### 4.6 Guardado incremental y recuperación (OPFS)

**Problema:** si los trozos se guardan solo en memoria (`chunks[]` → `Blob` al final), un cuelgue de Chrome a las 3 h pierde **todo**. Encima, 2 GB en memoria es arriesgado (Chrome los pasa a disco, pero sin garantías).

**Opciones analizadas:**

| Opción | Clics extra | Qué queda tras un cuelgue | Veredicto |
|---|---|---|---|
| Solo memoria + `Blob` | 0 | **Nada** | Inaceptable para una asamblea de horas |
| `showSaveFilePicker` + `createWritable()` (lo que hace Jitsi) | 1 (elegir dónde guardar) | Chrome escribe a un temporal **`.crswap`** y solo lo pasa al nombre final en `close()`. Tras un cuelgue, el archivo elegido puede estar **vacío**, y el `.crswap` puede quedar o borrarse **[P0]** | Clic extra y recuperación dudosa |
| **OPFS** (`navigator.storage.getDirectory()`) + `createSyncAccessHandle()` en un *Worker* | **0** | Escritura **en el sitio**, sin temporal: queda todo hasta el último trozo | **Elegida** |

Diseño:
- `grabacion-worker.js` (mismo origen, `/admin/static/`) recibe cada `Blob` por `postMessage`, lo convierte a `ArrayBuffer` y llama a `handle.write(buf, {at: offset}); handle.flush();`.
- Junto al archivo `grabaciones/<nombre>.webm` se guarda un `grabaciones/<nombre>.json` con `{estado:"grabando", inicio, bytes, ultimoTrozo}`, actualizado cada trozo. Al terminar bien pasa a `estado:"completa"`.
- **Recuperación:** al cargar la sala, `grabacion.js` lista `grabaciones/`. Si hay alguna en `estado:"grabando"` (o sin json), muestra el aviso de §3.1 caso 4: [Descargar] (la descarga como `<nombre>-recuperada.webm`) y [Descartar] (con confirmación). Un WebM de `MediaRecorder` truncado **se reproduce hasta el corte** (VLC y Chrome lo abren) y `ffmpeg` lo convierte sin problema.
- **Limpieza:** las grabaciones completas se quedan en OPFS hasta que el admin pulse "Ya lo tengo guardado, borrar copia", o como mucho **7 días** (Q6). Por qué no borrar justo después de descargar: el navegador no avisa si la descarga terminó bien. La tarjeta muestra siempre cuánto ocupa la copia interna, porque es espacio "invisible" en el perfil de Chrome.
- **Espacio:** antes de grabar, `navigator.storage.estimate()`. Si `quota − usage` < 2.5 GB (4 h del perfil recomendado + margen), aviso ámbar no bloqueante: "Queda poco espacio para la grabación (≈ X h)". `navigator.storage.persist()` para que Chrome no borre los datos por presión de disco.
- **Merece la pena:** sí. Es un *worker* de ~40 líneas. Elimina el único fallo con pérdida total, gana además la eliminación de los 2 GB en memoria, y no añade clics.
- Plan de respaldo si OPFS falla (cuota denegada…): `chunks[]` en memoria + aviso "Si Chrome se cierra se perderá la grabación".

**Wake Lock:** `navigator.wakeLock.request('screen')` al empezar. Se vuelve a pedir en `visibilitychange` (el navegador lo suelta al ocultar la pestaña). Evita que el PC apague la pantalla o suspenda durante las horas de asamblea en la mayoría de configuraciones.

**Duración en el WebM:** los WebM de `MediaRecorder` no llevan la duración en la cabecera, así que algunos reproductores no muestran la barra de tiempo o tardan en buscar. Opciones: (a) la conversión de §5 lo arregla; (b) reescribir el elemento *Duration* del primer trozo al terminar, como hace Jitsi (escribe una duración ficticia del mismo tamaño y luego la corrige en el sitio). Con OPFS se puede hacer `write(at:0)`. **Propuesta:** v1 = (a); (b) en un paso opcional, porque es código EBML delicado sin una librería (prohibido CDN).

### 4.7 Cero subida al servidor (confirmación explícita)

**El archivo nunca sale del PC del administrador.** Al detener:
```js
const file = await opfsHandle.getFile();          // File respaldado por disco, no RAM
const url  = URL.createObjectURL(file);
const a = Object.assign(document.createElement('a'), { href: url, download: nombre });
document.body.append(a); a.click(); a.remove();
setTimeout(() => URL.revokeObjectURL(url), 60_000);
```
El navegador copia el archivo a **Descargas** (o pregunta dónde, si el admin tiene activado "Preguntar dónde guardar"). No hay ruta en `app.py` para recibir grabaciones, y **no se debe crear ninguna**. Hoy no hay CSP en `/admin*` que bloquee `blob:` o los *workers*. Si algún día se añade, necesitará `worker-src 'self'` (el `<a download>` con `blob:` no necesita `media-src`).

### 4.8 Dónde vive el código y cómo se sirve

| Archivo | Contenido | Por qué |
|---|---|---|
| `admin-panel/app/static/grabacion.js` (nuevo, ~10–12 KB sin minificar) | Detección, diálogo, captura, comprobaciones, mezcla, grabación, indicador, recuperación, envoltura del constructor (H3) | En archivo aparte y no en `page_sala.html`: (1) el script de la sala está congelado (D8); (2) se puede cachear; (3) se carga **solo** en la sala, no en todo el panel como `theme.js`. |
| `admin-panel/app/static/grabacion-worker.js` (nuevo, ~1 KB) | Escritura OPFS síncrona | `createSyncAccessHandle` solo existe dentro de un *Worker*. |
| `admin-panel/app/static/theme.css` | Bloque nuevo `/* page: sala · grabación */` con tokens existentes; `sticky` pasa de `#jitsi` a `.grab-zona` | Sistema de diseño único. |
| `admin-panel/app/page_sala.html` | Tarjeta `.grab`, `<dialog id="grab-dlg">`, envoltorio `.grab-zona` (con `#jitsi` y la franja legal dentro), `<script src="/admin/static/grabacion.js?v={{asset_v}}">` **entre** `external_api.js` y el script congelado | El script congelado no se toca (H3). |
| `admin-panel/app/app.py` | 1 línea en `sala_moderacion()`: `body = body.replace("{{asset_v}}", ASSET_V)` + subir `ASSET_V` | El cuerpo de `page_sala.html` no pasa por Jinja (`render_page` lo inyecta con `|safe`), así que `{{ v }}` no se resuelve ahí. |

Servido por Flask (`static_url_path="/admin/static"`) bajo la regla `@admin path /admin*` de Caddy, con las cabeceras `frame-ancestors 'none'` de esa ruta (correcto: el panel no se embebe). El `Dockerfile` ya copia `app/static` entero: no cambia. Como `app.py` va dentro de la imagen, hay que **reconstruir** `jitsi-admin:local` y desplegar copiando archivos al VPS (el VPS no es un repo git).

---

## 5. Conversión a MP4

**Por qué hace falta:** un WebM VP8/Opus lo abren Chrome, Edge, Firefox y VLC. Pero **QuickTime (macOS) no**, y el reproductor de Windows depende de extensiones; la administración o un juzgado esperan un MP4 H.264/AAC. Además, el WebM sin duración (§4.6) se busca mal.

**Dónde corre: en el PC del administrador, bajo demanda.** No en el servidor:
- **Servidor descartado:** obligaría a **subir** 2 GB (contradice §4.7 y la decisión de fondo), y transcodificar 4 h de video con x264 se comería los 4 vCPU que necesita el JVB si coincide con otra reunión.
- **No automático en el navegador:** no existe transcodificación H.264 nativa en el navegador sin WebCodecs + un *muxer* MP4 escrito a mano (muy complejo) o `ffmpeg.wasm` (≈ 30 MB y lento). Y está la regla "sin CDN".

**Herramienta: `ffmpeg`. Hay que instalarlo** (no viene con ninguno de los dos sistemas):
- macOS: `brew install ffmpeg` (requiere Homebrew), o el binario estático de evermeet.cx copiado a `/usr/local/bin`.
- Windows 10 1809+/11: `winget install --id Gyan.FFmpeg` (winget viene con el sistema).
- **Alternativa sin terminal:** **HandBrake** (gratis, macOS y Windows): abrir el `.webm` → preset "Fast 720p30" → MP4. Probablemente sea la mejor opción para un admin no técnico (Q5).

**Comandos** (se entregan como scripts de un doble clic / arrastrar y soltar en `scripts/grabacion/`: `convertir-mp4.command` para macOS y `convertir-mp4.bat` para Windows):
```sh
# Video → MP4 compatible con todo (H.264 + AAC), arranque rápido en reproductores web
ffmpeg -i "Asamblea-….webm" -c:v libx264 -preset veryfast -crf 26 -r 15 \
       -c:a aac -b:a 96k -movflags +faststart "Asamblea-….mp4"

# Solo audio → MP3 (para el acta o para transcribir)
ffmpeg -i "Asamblea-….webm" -vn -c:a libmp3lame -q:a 4 "Asamblea-….mp3"

# Solo arreglar la duración del WebM (sin recodificar, segundos)
ffmpeg -i "Asamblea-….webm" -c copy "Asamblea-…-fix.webm"
```
- Tiempo orientativo: x264 `veryfast` a 720p15 en un PC de escritorio actual va **muy por encima de tiempo real**; una asamblea de 4 h debería convertirse en minutos, no horas. Se mide en el paso 7 y se documenta.
- Pegas reales: en macOS, un `.command` descargado lo **bloquea Gatekeeper** la primera vez (clic derecho → Abrir). En Windows, SmartScreen puede avisar con un `.bat`. Se documenta en la guía del admin.
- Si P0 confirma que Chrome graba MP4 directamente en los dos PCs (Q3), esta sección pasa a ser **opcional** (solo para el MP3).

---

## 6. Aviso legal

**Contexto (no es asesoría jurídica; la redacción final la debe validar el abogado o el revisor fiscal de la copropiedad):**
- **Ley 675 de 2001, art. 42**: en las reuniones no presenciales debe quedar **"prueba inequívoca, como fax, grabación magnetofónica o similar"**. La grabación es justo el soporte que la ley contempla. **Art. 47**: las actas.
- **Ley 1581 de 2012** (*habeas data*) y su reglamento (Decreto 1377 de 2013, compilado en el Decreto 1074 de 2015): la voz y la imagen son **datos personales**. Hay que **informar** del tratamiento, de la finalidad y del responsable **antes o al momento** de recogerlos.
- **Constitución, art. 29**: la prueba obtenida con violación del debido proceso es nula de pleno derecho. Una grabación de la que no se avisó puede ser impugnada. **Avisar es lo que protege el valor probatorio.**

**Texto propuesto:**

> **Corto** (*subject* de Jitsi, ≤ 60 caracteres): `● GRABANDO · {título}`
>
> **Largo** (franja dentro de la zona grabada y mensaje de chat):
> **Esta asamblea se está grabando (audio y video).** La administración del Conjunto Cerro Azul la graba como soporte del acta (Ley 675 de 2001). Los datos se tratan según la Ley 1581 de 2012. Si permanece en la reunión, queda informado de la grabación.
>
> **Para leer en voz alta** (en el diálogo, para el admin, justo al empezar): "Informo a los asistentes que, a partir de este momento, la asamblea está siendo grabada en audio y video como soporte del acta, conforme a la Ley 675 de 2001. Sus datos se tratarán según la Ley 1581 de 2012."

**Dónde se muestra.** El aviso tiene que **quedar dentro de la grabación** y llegar a **todos**:

| # | Dónde | Lo ven | ¿Queda en la grabación? | Por qué |
|---|---|---|---|---|
| 1 | **Franja fija** `.grab-aviso` dentro de `.grab-zona`, encima del iframe (rojo, 1 línea, texto largo resumido) | El admin | **Sí, en cada fotograma** (está dentro del recorte de §4.1) | Es la garantía visual de que el aviso está **en el archivo mismo**. Por eso va encima del iframe (siempre visible) y no superpuesta (taparía la reunión). |
| 2 | **Subject de la conferencia** `api.executeCommand('subject', '● GRABANDO · …')` [V: el comando existe en stable-11031] | **Todos los asistentes**, incluidos los que entran tarde y los que vienen de votacionph.us | Sí (se ve en la cabecera de Jitsi dentro de la zona grabada) **[P0]** | Es lo único de Jitsi que se ve de forma persistente en todos los clientes sin tocar la configuración. Al terminar se cambia a `{título}`. |
| 3 | **Mensaje de chat** con el texto largo al empezar y "La grabación ha terminado" al acabar | Los presentes en ese momento | Solo si el chat está abierto | Deja constancia escrita con hora en el chat. Ojo: con `disableIncomingMessageSound` y la lista blanca de notificaciones, **no aparece ninguna alerta emergente**; solo queda en el panel de chat. |
| 4 | **Lectura en voz alta** por el admin | Todos | **Sí, en el audio** | El aviso más fuerte como prueba: está en la propia pista de audio, al principio. El diálogo de "Grabando" muestra el texto para leer durante el primer minuto. |
| 5 | **Página pública** `/reunion/<slug>` (`page_reunion.html`): línea "Esta reunión puede ser grabada como soporte del acta." | Residentes antes de entrar | No | Aviso **previo**. Requiere tocar otra plantilla (Q7). No cubre a quien entra desde votacionph.us: habría que pedírselo a ese proyecto. |

No se usa la notificación nativa "X has started a local recording" de Jitsi: solo existe con A2, sale en inglés salvo traducción, desaparece a los segundos y está filtrada por nuestra lista blanca.

---

## 7. Riesgos y mitigaciones

| # | Riesgo | Prob. | Impacto | Mitigación | Riesgo que queda |
|---|---|---|---|---|---|
| R1 | **Grabación muda** (casilla de audio sin marcar) | Alta sin mitigar | Crítico | Instrucciones (§3.4) + **comprobación determinista** "¿hay pista de audio?" (§3.5 b) que **bloquea** + bip de prueba (§3.5 c) + vúmetro y aviso a los 10 min de silencio (§3.6) | Bajo: solo si el admin fuerza "Grabar sin sonido" tras la confirmación |
| R2 | Elige **otra pestaña, una ventana o la pantalla** | Media | Alto (se grabaría otra cosa: otra pestaña con su audio, o una ventana **sin audio**) | `preferCurrentTab`, `monitorTypeSurfaces:'exclude'` y `surfaceSwitching:'exclude'` lo dificultan en la propia interfaz. Comprobación `displaySurface === 'browser'` + **Capture Handle** igual al de esta carga (§3.5 a) → se rechaza y se reintenta | Muy bajo |
| R3 | **Se cae el PC** o Chrome se cuelga | Baja–media | Alto | OPFS con escritura en el sitio cada 5 s + recuperación al volver (§4.6) + Wake Lock + guía (enchufado, sin suspensión) | Se pierden ≤ 5 s **y lo que pase mientras el PC esté caído**. El hueco no se recupera |
| R4 | **Permisos de macOS** denegados | Media la primera vez | Medio | La captura de pestaña no debería necesitarlo **[P0]**. Si `getDisplayMedia` falla con `NotAllowedError` sin que el usuario cancele, mensaje con la ruta exacta de Ajustes y "hay que reiniciar Chrome". La guía dice: hacerlo el día antes | Bajo |
| R5 | **Archivos enormes** (4 h) | Segura | Medio | 1 Mbps + 15 fps + 720p ⇒ ≈ 2 GB en 4 h; perfil "solo audio" ≈ 0.17 GB (Q4); comprobación de espacio (§4.6); escritura en disco, no en RAM | Hace falta disco libre ≥ 2× el tamaño (copia OPFS + Descargas) |
| R6 | **Olvida detener** | Media | Bajo–medio | (a) Al colgar en Jitsi se detiene solo; (b) **aviso a la hora de fin prevista** (sale del `exp` del JWT − margen, o de un `data-fin` en la plantilla) y cada 15 min después: "La asamblea debía terminar a las 11:00. ¿Sigues grabando?" [Detener] [Seguir]; (c) **límite duro de 6 h** → se detiene y guarda sola (Q6) | Bajo: el archivo solo tendría un final largo vacío |
| R7 | **Eco** de la sala por el micro del admin (altavoces) | Media | Medio (audio sucio, no mudo) | `echoCancellation:true` en el micro + puerta sincronizada con el silencio de Jitsi + auriculares en la guía | **[P0]**: comprobar la cancelación de eco en la segunda captura |
| R8 | Graba **conversaciones privadas** del admin con el micro silenciado | Alta sin mitigar | Alto (privacidad) | Puerta de ganancia sincronizada con `audioMuteStatusChanged` (§4.3) | Bajo: ventana de ~50 ms al cambiar de estado |
| R9 | El admin hace **scroll** o estrecha la ventana y `.grab-zona` sale de pantalla | Media | Medio (fotogramas negros o congelados en el recorte) | `.grab-zona` *sticky* en ≥ 1024 px; mientras graba, en < 1024 px se fija arriba. Aviso si `IntersectionObserver` ve la zona oculta > 5 s **[P0]**: qué entrega `cropTo` con la zona fuera de pantalla | Bajo |
| R10 | Se **actualiza Jitsi** y cambia la API del iframe | Baja (versión fijada) | Medio | Solo se usa API pública (`subject`, `sendChatMessage`, `isAudioMuted`, `getCurrentDevices`, eventos). Volver a probar con el plan de §9 al cambiar `JITSI_IMAGE_VERSION` | Bajo |
| R11 | Chrome cambia los **textos** del diálogo de compartir | Media a medio plazo | Bajo | Instrucciones genéricas con captura fechada; la comprobación determinista no depende del texto | Bajo |
| R12 | El admin entra desde **móvil** | Baja | Alto (no hay grabación) | Detección + aviso permanente "la asamblea **no** se está grabando" (§3.1) | No mitigable técnicamente: solo con procedimiento |
| R13 | Copias en OPFS ocupan disco sin que se vean | Media | Bajo | Tamaño visible en la tarjeta + borrado manual o a 7 días (§4.6) | Bajo |

---

## 8. Plan de implementación

Pasos pequeños; cada uno se despliega y se verifica solo. Nada de producción se toca hasta el paso 1.

**Paso 0 — Verificación en los PCs reales (sin código del panel).** Una página HTML de prueba **local** (no se despliega; se abre con un servidor estático local o como archivo en `localhost`, que cuenta como contexto seguro) que ejecuta las llamadas de §4.1–4.3 y muestra resultados. Se rellena una tabla con todas las **[P0]**: versión de Chrome; `isTypeSupported` de los 4 formatos; capturas del diálogo de compartir con `preferCurrentTab` en español (macOS y Windows) y si la casilla de audio viene marcada por defecto; si macOS pide el permiso de pantalla para la pestaña; Firefox y `video:false` (nota F); segunda captura del micro con AEC; `cropTo` sobre un contenedor con iframe; comportamiento de `.crswap`.
- *Aceptación:* tabla P0 completa y añadida a este SPEC como §10; instrucciones de §3.4 fijadas con los textos reales.

**Paso 1 — Estructura y detección.** Marcado de la tarjeta, el diálogo y `.grab-zona` en `page_sala.html`; CSS; `grabacion.js` solo con la envoltura del constructor (H3) y la detección (§3.1); `{{asset_v}}` en `app.py`.
- *Aceptación:* (a) `diff` del script congelado = vacío; (b) `loadtest/verificar-panel.py` sin diferencias en el contrato; (c) en Chrome de escritorio, botón activo; en Safari y Firefox, mensaje "usa Chrome"; en un móvil real y en la emulación de DevTools, aviso "no se está grabando"; (d) la moderación sigue funcionando (prueba manual de 2 clientes de la Fase 8).

**Paso 2 — Captura y comprobaciones, sin grabar.** `getDisplayMedia`, superficie y handle, pista de audio, bip, micro; estados de error.
- *Aceptación:* con la casilla de audio **sin marcar** → bloqueo rojo y no se puede continuar; al elegir una ventana (si Chrome la ofrece) u otra pestaña → rechazo; con la pestaña silenciada (clic derecho → Silenciar sitio) → "mudo" con confirmación; con todo bien → verde en < 3 s; sin permiso de micro → aviso ámbar.

**Paso 3 — Grabación básica.** Mezcla (sin micro todavía), `MediaRecorder`, trozos en memoria, indicador, "Detener y guardar", nombre del archivo, descarga, *subject*, chat y franja legal.
- *Aceptación:* grabación de 5 min → archivo `Asamblea-<slug>-<fecha>-<hora>.webm` en Descargas; `ffprobe` muestra 1 pista `vp8` ≤ 1280×720 y 1 pista `opus`; duración 5 min ± 5 s (§9); tamaño 41 MB ± 40 %; `volumedetect` con `max_volume` > −20 dB cuando habla el cliente remoto; un fotograma en el segundo 10 muestra la franja legal; el segundo cliente ve "● GRABANDO · …".

**Paso 4 — Micrófono del admin con puerta.**
- *Aceptación:* guion "admin habla con micro abierto 30 s → silencia en Jitsi y habla 30 s → abre y habla 30 s" ⇒ `silencedetect` encuentra silencio (o solo el remoto) **solo** en el tramo del medio; con altavoces y un remoto hablando, no hay eco audible (prueba de escucha).

**Paso 5 — Recorte a Jitsi.**
- *Aceptación:* los fotogramas solo muestran `.grab-zona` (aviso + reunión), nada del panel lateral; si `cropTo` falla (forzado), aviso y grabación de la pestaña completa.

**Paso 6 — Robustez.** *Worker* OPFS, json de estado, recuperación, `beforeunload`, `track.onended`, `videoConferenceLeft`, Wake Lock, comprobación de espacio, recordatorios de fin, límite de 6 h.
- *Aceptación:* matar Chrome (`kill -9` en macOS / Administrador de tareas en Windows) a los 10 min → al volver a la sala aparece "grabación sin terminar" → el archivo descargado se reproduce en VLC hasta el minuto ~9:55; cerrar la pestaña → diálogo de Chrome; "Dejar de compartir" → se guarda solo; colgar en Jitsi → se guarda solo; con el límite bajado a 3 min para la prueba → se guarda solo.

**Paso 7 — Conversión y guía del admin.** `scripts/grabacion/convertir-mp4.{command,bat}` + `docs/GRABACION-ADMIN.md` (preparación del PC, permisos, auriculares, paso a paso con capturas, conversión con ffmpeg o HandBrake).
- *Aceptación:* el MP4 de una grabación de 30 min abre en QuickTime (macOS) y en "Reproductor multimedia" (Windows 11), con imagen y sonido y buscando bien; tiempo de conversión anotado.

**Paso 8 — Prueba larga y despliegue.** Ensayo de 4 h (§9); reconstrucción de la imagen; copia al VPS; README "Fase 9".
- *Aceptación:* archivo de 4 h ± 1 min, ≈ 2 GB ± 40 %, audio en todo el tramo (sin silencios > 10 min que no se hayan provocado); uso de memoria de la pestaña estable (Administrador de tareas de Chrome: sin crecimiento sostenido > 300 MB en 4 h); CPU del PC del admin < 30 % de media.

---

## 9. Verificación sin una asamblea real

**Montaje:**
1. Crear en el panel una reunión de prueba ("Prueba grabación").
2. **Admin:** Chrome en el Mac y, en otra sesión, en el PC con Windows. Abrir `/admin/reunion/<id>/sala`.
3. **Asistente 1 (humano):** móvil o segundo PC por el enlace público: voz real, mano levantada, pedir la palabra.
4. **Asistente 2 (automático, señal conocida):** un nodo de `loadtest/docker-compose.selenium.yml` (Chrome con `--use-fake-device-for-media-stream`, que **emite un pitido periódico**) unido con un token de `loadtest/make-token.py`. Da audio remoto **continuo y reconocible** durante las 4 h sin que nadie hable. La moderación de audio debe estar desactivada para ese cliente ("Dar a todos").

**Comprobaciones del archivo** (en el PC del admin con ffmpeg instalado):
```sh
# Pistas y códecs: tiene que haber exactamente 1 video (vp8) y 1 audio (opus)
ffprobe -v error -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate -of compact "$F"

# Duración real (el WebM no la lleva en la cabecera: hay que leerlo entero)
ffprobe -v error -count_packets -show_entries format=duration -of default=nw=1 "$F" \
  || ffmpeg -i "$F" -f null - 2>&1 | grep -o 'time=[0-9:.]*' | tail -1

# Que tiene sonido de verdad: max_volume > -20 dB y mean_volume > -50 dB
ffmpeg -i "$F" -vn -af volumedetect -f null - 2>&1 | grep -E 'mean_volume|max_volume'

# Tramos mudos largos (no debería haber > 30 s con el pitido del cliente automático)
ffmpeg -i "$F" -vn -af silencedetect=n=-50dB:d=30 -f null - 2>&1 | grep silence_

# Aviso legal en la imagen
ffmpeg -ss 00:00:10 -i "$F" -frames:v 1 aviso.png

# Tamaño (MB por minuto ≈ 8.2 con el perfil recomendado)
ls -l "$F"
```

**Casos negativos** (cada uno con resultado esperado documentado): casilla de audio sin marcar; otra pestaña; ventana; cancelar el diálogo de Chrome; pestaña silenciada; micro denegado; matar Chrome; cerrar pestaña; "Dejar de compartir"; colgar; Safari; Firefox; móvil; poco espacio (simulado con la cuota de DevTools → Application → Storage → "Simulate custom storage quota").

---

## Resumen de decisiones

| # | Decisión | Porqué en una línea |
|---|---|---|
| D1 | **A1: `grabacion.js` propio** con `getDisplayMedia` de la pestaña + `MediaRecorder`; A2 (grabación local de Jitsi) como plan B | Es la única que permite comprobar el audio antes de empezar, con nombre y tamaño controlados y sin servidor |
| D2 | **Chrome de escritorio** en macOS y Windows (Edge aceptado en Windows) | Único motor con audio de pestaña, `preferCurrentTab`, recorte y Capture Handle |
| D3 | Comprobación **determinista** (pista de audio presente) + **bip de prueba** en vez de "medir unos segundos" | En una sala moderada el silencio es lo normal; un umbral sobre silencio da falsos "mudo" |
| D4 | Mezclar el **micro del admin** con una **puerta** sincronizada con su silencio en Jitsi | La pestaña no contiene la voz del propio admin; y no hay que grabar lo que la sala no oyó |
| D5 | **Recortar** el video a la zona de Jitsi (+ franja legal) | No grabar el panel de moderación ni la lista de nombres; el aviso queda en cada fotograma |
| D6 | **OPFS + Worker** con escritura en el sitio cada 5 s, más recuperación | Sin clics extra; una caída no pierde la asamblea entera |
| D7 | **720p, 15 fps, 1 Mbps + 96 kbps** ⇒ ≈ 0.5 GB/h | Calidad suficiente para caras y documentos; 4 h ≈ 2 GB |
| D8 | **No tocar el script congelado**: envolver el constructor de la API | Respeta la regla D8 del rediseño |
| D9 | **Conversión a MP4 en el PC del admin, bajo demanda** (ffmpeg o HandBrake) | Subir al servidor contradice "cero subida" y le robaría CPU al JVB |
| D10 | Aviso legal **en 4 capas** (franja grabada, *subject* para todos, chat, lectura en voz alta) | Que quede en la imagen y en el audio del propio archivo, y que lo vean los que entran tarde |

## Preguntas para el autor (antes de implementar)

- **Q1.** ¿Envolver el constructor `JitsiMeetExternalAPI` (respeta D8, recomendado) o romper D8 con una línea `window.CA_SALA = {api}`?
- **Q2.** ¿Chrome como único navegador oficial, o también Edge en Windows (doble juego de capturas en la guía)?
- **Q3.** Si el paso 0 confirma que Chrome graba MP4 H.264 en los dos PCs, ¿grabar directamente en MP4 (sin conversión) o mantener WebM (más probado y recuperable)?
- **Q4.** ¿Video + audio por defecto, o **solo audio** (≈ 43 MB/h)? ¿Ofrecer el selector al admin?
- **Q5.** Conversión: ¿scripts de ffmpeg, HandBrake o ambos? ¿Quién instala ffmpeg o HandBrake en los PCs?
- **Q6.** Límite duro de duración (propuesta 6 h) y tiempo de conservación de la copia interna (propuesta 7 días).
- **Q7.** ¿Se añade el aviso previo en `page_reunion.html`? ¿Se pide lo mismo a votacionph.us?
- **Q8.** Texto legal: ¿quién lo valida (abogado / revisor fiscal)? ¿Responsable del tratamiento = "Administración del Conjunto Cerro Azul" o la razón social exacta?
- **Q9.** ¿Debe la grabación incluir el panel lateral (lista de asistentes como evidencia de quórum) o solo la reunión (propuesta)? El quórum ya lo lleva votacionph.
- **Q10.** ¿Se acepta que la grabación refleje la conexión del admin (`lastN = 4`, cortes)? Si no, la única alternativa real es un servidor de grabación aparte (Jibri en otra máquina).

## Lo más frágil del diseño

1. **Depender de la persona y del PC.** Todo depende de que el admin use Chrome en un computador, enchufado, que no suspenda y que no cierre la pestaña. Las mitigaciones reducen el daño (recuperación, avisos), pero **ninguna garantiza la grabación** como lo haría un servidor. Si la asamblea **tiene** que grabarse sí o sí, conviene una **segunda grabación de respaldo** (otro PC con Chrome en la misma sala o el móvil grabando el audio de los altavoces) como procedimiento, no como software.
2. **La interfaz de compartir de Chrome no es nuestra.** Los textos, si la casilla viene marcada o no, y el diálogo con `preferCurrentTab` cambian entre versiones. La comprobación determinista (§3.5 b) hace que un cambio de interfaz **no produzca grabaciones mudas en silencio**, pero las instrucciones envejecerán.
3. **Las piezas [P0] sin verificar.** Cancelación de eco en la segunda captura del micro, `cropTo` con la zona fuera de pantalla, permiso de macOS para la pestaña y MP4 nativo. Si alguna falla, cambia un trozo del diseño (no el enfoque). Por eso el paso 0 va antes que cualquier código.
4. **El mismo origen (H1)** sostiene A2 y facilita todo. Si el panel se muda a otro dominio, A2 deja de funcionar embebida (A1 sigue funcionando).

---

## 10. Implementación (Fase 2): decisiones del autor y desviaciones

### 10.1 Respuestas del autor

| Pregunta del autor | Decisión | Cómo quedó |
|---|---|---|
| Vídeo o solo audio | **Vídeo + audio** 720p/15 fps | `video/webm;codecs=vp8,opus`, 1 Mbps + 96 kbps. Sin selector de solo audio |
| Navegador | **Solo Chrome de escritorio** (macOS y Windows) | Detección por capacidades (§3.1). Edge funciona igual, pero no es oficial |
| Aviso legal | Lo **valida el administrador**; **genérico y reutilizable**; **sin "Cerro Azul"** | «Esta reunión se está grabando en audio y vídeo. Al participar, usted lo autoriza.» + «Responsable: `JITSI_LEGAL_OWNER`». Se quitaron las referencias a leyes concretas del texto de §6 |
| Límite de horas | **Sin límite** | Se quitó el límite duro de 6 h (R6 c). Se mantienen la comprobación de espacio (antes y cada minuto) y los recordatorios a la hora de fin (cada 15 min) |
| Formato | **WebM**; sí poder convertir a MP4 | `convertir-mp4.command` / `.bat` + HandBrake en `GRABACION-ADMIN.md` |
| Copia OPFS | **7 días** | Se borran al abrir la sala si superan 7 días desde su fin o su último trozo |
| Panel lateral | **Solo la reunión** | `cropTo(.grab-zona)` (salvo la reserva de 10.2 n.º 1) |
| Conexión del admin | Aceptado | — |
| Envolver el constructor o romper D8 | (sin respuesta explícita) → la **recomendada**: envolver | El script congelado sigue idéntico a `0782429` (lo comprueba `verificar-panel-local.py`) |

**Tarea 0 (multi-conjunto):** `JITSI_SITE_NAME`, `JITSI_SITE_SUBTITLE` y `JITSI_LEGAL_OWNER` en `admin.env`. Ninguna plantilla contiene ya un nombre fijo. `verificar-panel-local.py` falla si alguna página renderizada contiene «Cerro Azul».

### 10.2 Desviaciones del diseño (probadas en Chromium headless)

1. **R9 era peor de lo previsto.** Con `cropTo` sobre un elemento fuera de la pantalla, Chromium no entrega fotogramas y el WebM no escribe **nada, ni el audio**. Mitigación: si `.grab-zona` deja de verse entera (< 98 %) durante 2 s, `cropTo(null)` (se graba la pestaña entera, panel incluido) y se vuelve a recortar al reaparecer. Además, aviso rojo si pasan 15 s sin trozos. Se prioriza no perder el audio frente a Q9.
2. **Criterio del bip.** «≥ 3 lecturas ≥ −45 dBFS en 2 s» en vez de «3 seguidas en 1,5 s». En headless la captura llega a ráfagas. El registro técnico guarda la serie para revisarla en los PCs reales.
3. **La franja se muestra antes de arrancar el grabador.** El WebM fija en su cabecera el tamaño del primer fotograma.
4. **Superficie:** si el Capture Handle viene vacío pero `cropTo` funciona (solo posible al capturarse a sí misma), se acepta como «esta pestaña».
5. **Web Locks:** la pestaña que graba tiene un cerrojo, para que otra pestaña de la sala no ofrezca «recuperar» una grabación que sigue viva.
6. **Dimensiones pares y `yuv420p`** en la conversión: el recorte da tamaños arbitrarios, libx264 rechaza los impares y QuickTime exige 4:2:0.
7. El texto para leer en voz alta y el del chat son genéricos (sin leyes) y llevan el responsable configurado.

### 10.3 Verificación

- Aquí: `py_compile`, `node --check`, imagen Docker, `scripts/verificar-panel-local.py` (contrato de la sala, script congelado idéntico, sin marca fija, estáticos 200) y `scripts/grabacion/probar-grabacion-headless.py` (resultados en `GRABACION-PASO0.md` §1).
- Pendiente (no verificable aquí): `GRABACION-PASO0.md` §2–§7, en Mac y Windows.
