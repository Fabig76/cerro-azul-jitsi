# Grabación — Paso 0: verificación en los PCs reales

> **Para el autor.** La grabación está implementada y desplegada, pero **nadie la ha probado todavía en un Mac ni en un Windows reales**. Desde el servidor de desarrollo (Linux, sin pantalla ni tarjeta de sonido) **no se puede**. Este documento separa lo que sí se verificó aquí de lo que tienes que comprobar tú, con una checklist para cada PC.
>
> Hasta que esta checklist esté completa en los dos PCs, **no confíes en la grabación para una asamblea real**. Haz al menos un ensayo de 30 min (punto 6).

Spec: [`SPEC-GRABACION.md`](SPEC-GRABACION.md) · Guía de uso: [`GRABACION-ADMIN.md`](GRABACION-ADMIN.md)

---

## 1. Qué se verificó aquí (Chromium 148 headless en Linux)

`scripts/grabacion/probar-grabacion-headless.py` ejecuta `grabacion.js` en un Chromium real con la captura de pestaña **auto-aceptada** (`--auto-accept-this-tab-capture`), un micrófono falso de Chromium y una **API de Jitsi simulada** (un iframe que emite un tono como si fuera un participante remoto). Usa las API reales del navegador: `getDisplayMedia`, Capture Handle, `cropTo`, Web Audio, `MediaRecorder`, OPFS en un worker, Web Locks y descargas.

| Comprobación | Resultado |
|---|---|
| Captura de esta pestaña, Capture Handle propio, `cropTo` a `.grab-zona` | OK |
| Bip de prueba captado en la pista de la pestaña | OK (ver nota del bip) |
| Grabación de 20 s → `.webm` con 1 pista `vp8` + 1 `opus`, duración correcta, audio con señal | OK |
| La franja legal sale en el vídeo (fotograma a los 5 s) y el panel lateral **no** | OK |
| La cabecera del WebM ya tiene el tamaño **con** la franja (sin cambio de resolución a mitad) | OK |
| Subject «● GRABANDO · …», mensaje en el chat con el responsable, mensaje de fin, subject restaurado | OK (en la API simulada) |
| Puerta del micro: al abrir el micro en Jitsi, «Tu micro: en la grabación» | OK |
| Recordatorio a la hora de fin + «Seguir grabando» | OK |
| Cerrar la pestaña de golpe a los 13 s → al volver, «Hay una grabación que no se guardó» → se descarga `…-recuperada.webm` reproducible (≈ 10 s) | OK |
| Zona de la reunión fuera de la pantalla → se graba la pestaña entera y se vuelve a recortar al volver; el archivo cubre todo el tramo | OK |
| Casilla de audio desmarcada → bloqueo rojo, no graba | OK (simulado quitando la pista) |
| Pestaña muda → «no capta el sonido» + «Grabar sin sonido» con confirmación | OK (simulado con pista muda) |
| Otra pestaña (handle distinto) → rechazo | OK (simulado) |
| Cancelar el diálogo de Chrome → aviso neutro, no graba | OK (simulado) |
| Navegador sin Region Capture (Safari/Firefox) → «abre esta página en Google Chrome» | OK (simulado quitando `CropTarget`) |
| Móvil (emulación) → «La reunión NO se está grabando», botón deshabilitado | OK |
| Copias de más de 7 días → se borran solas al abrir la sala | OK |
| Conversión con `convertir-mp4.command` (bash, en Linux) → MP4 h264/yuv420p + aac, `moov` al principio (`+faststart`), rutas con espacios, no sobrescribe | OK |
| `convertir-mp4.command` sin ffmpeg → explica cómo instalarlo y no hace nada más | OK |

### Hallazgos de estas pruebas que cambiaron el código

1. **Zona fuera de pantalla = grabación vacía (riesgo R9, resuelto).** Con el recorte puesto sobre un elemento que no está en pantalla, Chromium no entrega fotogramas y el WebM **no escribe nada, ni siquiera el audio** (0 bytes en 15 s; reproducido con `prueba-paso0.html`). Ahora, si la zona deja de verse entera durante 2 s, se quita el recorte y se graba la pestaña completa hasta que vuelva. Además, si pasan 15 s sin datos, sale un aviso rojo.
2. **Bip a ráfagas.** En headless el audio capturado llega a ráfagas (una lectura con señal cada ~500 ms y ceros entre medias), así que el criterio del spec, «3 lecturas **seguidas** ≥ −45 dBFS», fallaba con una señal de −7 dBFS. Ahora es «≥ 3 lecturas ≥ −45 dBFS en una ventana de 2 s». El registro técnico guarda la serie completa para diagnosticarlo en tu PC.
3. **Franja antes de grabar.** Si la franja aparecía después del primer fotograma, el WebM quedaba con la altura sin franja en la cabecera y cambiaba de resolución a mitad. Ahora la franja se muestra antes de arrancar el grabador.

## 2. Qué NO se pudo verificar aquí

- La captura real de pestaña en **macOS** y **Windows**: el diálogo de Chrome, que aquí se salta.
- El **permiso «Grabación de pantalla» de macOS**: si Chrome lo pide para capturar una pestaña.
- El **diálogo de Chrome en español**: textos exactos, si con `preferCurrentTab` muestra «esta pestaña» directamente y si la casilla de audio viene marcada.
- El **MP4 nativo** de `MediaRecorder` (Q5: se graba en WebM, así que es solo informativo) y que el MP4 convertido abra en QuickTime y en el Reproductor de Windows.
- Que **el bip llegue** con el audio real del sistema (altavoces/auriculares, volumen, «silenciar sitio»).
- La **cancelación de eco** de la segunda captura del micro con altavoces.
- La **Jitsi real** (subject y chat en los clientes de los asistentes, `getCurrentDevices`, `audioMuteStatusChanged`). Aquí se usó un simulador.
- El comportamiento con la **pestaña en segundo plano** o la ventana minimizada.
- Rendimiento y estabilidad en una **sesión larga** (4 h): memoria, CPU, tamaño real por hora.
- Edge.

---

## 3. Preparación (una vez por PC)

1. Google Chrome actualizado (⋮ → Ayuda → Información de Google Chrome).
2. Auriculares conectados.
3. **macOS:** Ajustes del Sistema → Privacidad y seguridad → **Micrófono** → Google Chrome activado. **No** actives todavía «Grabación de pantalla»: el punto 4.3 comprueba si hace falta.
4. Copia `scripts/grabacion/prueba-paso0.html` al PC y sírvela en local (cuenta como contexto seguro):
   - macOS: `cd carpeta-del-archivo && python3 -m http.server 8765` → abre `http://localhost:8765/prueba-paso0.html` en Chrome.
   - Windows (si tienes Python): `py -m http.server 8765` en la carpeta del archivo. Si no tienes Python, salta la página de prueba y haz directamente el punto 5 en el panel real.

## 4. Página de prueba (`prueba-paso0.html`)

Al terminar pulsa **«Copiar resultados»** y pega el texto en la tabla del punto 7.

| # | Qué hacer | Qué anotar / resultado esperado |
|---|---|---|
| 4.1 | Abrir la página | Tabla 1: versión de Chrome; `CropTarget`, Capture Handle y OPFS = sí; `video/webm;codecs=vp8,opus` = sí; **anota si `video/mp4;codecs=avc1…` = sí** |
| 4.2 | Botón **A)**. **Haz una captura del diálogo de Chrome** antes de pulsar «Compartir» | ¿Ofrece directamente «esta pestaña»? ¿Textos exactos? ¿La casilla «Compartir también el audio de la pestaña» viene **marcada**? Resultado: `displaySurface = browser`, handle «coincide», 1 pista de audio, `cropTo` funciona, **bip ≥ 3 lecturas** (verde) |
| 4.3 | (solo macOS) ¿Pidió macOS el permiso «Grabación de pantalla» en 4.2? | Si lo pidió: anota el texto. Concédelo, reinicia Chrome y repite 4.2 |
| 4.4 | Botón **B)**, desmarcando la casilla de audio | Esperado: «pistas de audio = 0» |
| 4.5 | Botón **C)**: intenta elegir otra pestaña o una ventana | Esperado: Chrome no lo permite (por `preferCurrentTab`) o el handle sale «vacío/otro» |
| 4.6 | Botón A) con la pestaña silenciada (clic derecho en la pestaña → «Silenciar sitio») | Anota cuántas lecturas da el bip. Esperado: «−» (mudo) |
| 4.7 | **Micrófono doble** | Esperado: «2.ª captura… echoCancellation=true» y las dos «live» |
| 4.8 | **Grabar 15 s en WebM** con los auriculares puestos y hablando | Se descarga `paso0-webm-….webm`. Ábrelo en Chrome (arrástralo a una pestaña): ¿se ve solo la **zona roja** (sin «PANEL LATERAL»)? ¿Se oye el tono **y tu voz**? Anota los MB/hora |
| 4.9 | **Grabar 15 s en MP4 nativo** (si 4.1 dijo sí) | Ábrelo en QuickTime / Reproductor multimedia. Solo informativo |
| 4.10 | (opcional) Abre la página en **Firefox** y pulsa «Firefox: probar…» | Esperado: error (confirma la nota F del spec) |
| 4.11 | **Escritura OPFS** | Esperado: «100 MB en … ms» |

## 5. Prueba en el panel real (los dos PCs)

Crea en el panel una reunión «Prueba grabación» (hora actual, 60 min). Necesitas un segundo dispositivo (el móvil) como asistente por el enlace público.

| # | Qué hacer | Resultado esperado |
|---|---|---|
| 5.1 | Abre la sala (Moderación). Mira la tarjeta **Grabación** | «La grabación se guarda en este computador…», botón azul activo, «≈ 0,5 GB por hora · espacio libre ≈ X h» |
| 5.2 | Abre la misma sala en el **móvil** (logueado como admin) | Aviso «La reunión NO se está grabando», botón gris |
| 5.3 | En el PC: **Grabar esta reunión** → lee el diálogo → **Continuar** → diálogo de Chrome → **Compartir** | Oyes un **bip corto**; las 4 comprobaciones en verde; empieza a grabar solo; franja roja encima de Jitsi; cabecera «Grabando · Moderación en vivo» |
| 5.4 | En el móvil (asistente) | Cabecera de Jitsi: «● GRABANDO · Prueba grabación». En el chat: el aviso con el **responsable** (`JITSI_LEGAL_OWNER`) |
| 5.5 | En el PC: activa el micro en Jitsi y habla 30 s; **silencia** el micro en Jitsi y habla 30 s; vuelve a activarlo y habla 30 s. Desde el móvil, habla también | «Tu micro» cambia entre «en la grabación» y «silenciado en Jitsi (no se graba)» |
| 5.6 | Con **altavoces** (sin auriculares), que hable el móvil 30 s | Prueba de eco (se escucha en 5.9) |
| 5.7 | Baja con la rueda hasta el final de la página | La reunión sigue fija arriba; no debería salir el aviso «no está entera a la vista». Si sale, anótalo (no es grave: se graba la pestaña completa) |
| 5.8 | Cambia a otra pestaña 1 min y vuelve | Anota si sale «La grabación no está recibiendo datos» |
| 5.9 | **Detener y guardar** → confirmar | Se descarga `Asamblea-prueba-grabacion-AAAA-MM-DD-HHMM.webm`. Ábrelo arrastrándolo a Chrome: se ve la reunión con la franja y **sin** el panel lateral; tu voz se oye **solo** en los tramos con micro abierto; la voz del móvil se oye; no hay eco molesto en el tramo de 5.6 |
| 5.10 | **Grabar otra vez** → a los 2 min **cierra Chrome a la fuerza** (macOS: ⌥⌘⎋ → Forzar salida; Windows: Administrador de tareas → Finalizar tarea) → vuelve a abrir la sala | Aviso «Hay una grabación que no se guardó» → **Descargar** → el archivo `…-recuperada.webm` se reproduce hasta el minuto ~1:55 |
| 5.11 | Graba otra vez y pulsa **«Dejar de compartir»** en la barra de Chrome | Se detiene y se guarda solo, con el aviso correspondiente |
| 5.12 | Graba otra vez y **cuelga** en Jitsi | Se detiene y se guarda sola |
| 5.13 | Graba otra vez y **cierra la pestaña** | Chrome pregunta «¿Salir del sitio?». Pulsa Cancelar |
| 5.14 | Convierte el archivo de 5.9 con `convertir-mp4.command` (Mac) o `convertir-mp4.bat` (Windows); la primera vez sin ffmpeg instalado | Sin ffmpeg: explica cómo instalarlo (brew / winget). Con ffmpeg: crea el `.mp4` junto al `.webm` |
| 5.15 | Abre el `.mp4` en **QuickTime** (Mac) y en **Reproductor multimedia** (Windows 11) | Imagen y sonido; la barra de tiempo permite saltar. Anota el tiempo de conversión |
| 5.16 | Si tienes `ffprobe`: `ffprobe -v error -show_entries stream=codec_name,width,height -of compact ARCHIVO.webm` | 1 `vp8` ≤ 1280×720 y 1 `opus` |
| 5.17 | Registro técnico (al final de la sala) → copia las líneas `[grabación]` | Sobre todo la del **bip** (máx, lecturas y serie) y la de «grabando …» |

## 6. Ensayo largo (antes de la primera asamblea real)

30 min como mínimo (4 h si se puede), con el móvil hablando de vez en cuando. Anota: tamaño final (esperado ≈ 0,25 GB en 30 min, ≈ 2 GB en 4 h), que el audio está en todo el tramo, la CPU de Chrome (Administrador de tareas de Chrome) y que la memoria no crece sin parar.

## 7. Resultados (rellenar)

| Punto | macOS (versión: ……, Chrome ……) | Windows (versión: ……, Chrome ……) |
|---|---|---|
| 4.1 capacidades / MP4 nativo | | |
| 4.2 diálogo: «esta pestaña»; casilla marcada por defecto; textos | | |
| 4.3 permiso de pantalla de macOS para pestaña | | n/a |
| 4.6 bip con pestaña silenciada | | |
| 4.7 AEC en la 2.ª captura | | |
| 4.8 recorte / voz / MB por hora | | |
| 5.3 comprobaciones (copiar línea del bip) | | |
| 5.4 subject y chat en el móvil | | |
| 5.5 puerta del micro | | |
| 5.6 eco con altavoces | | |
| 5.7–5.8 scroll / otra pestaña | | |
| 5.10 recuperación tras forzar salida | | |
| 5.11–5.13 dejar de compartir / colgar / cerrar | | |
| 5.14–5.15 conversión y reproducción del MP4 (tiempo) | | |
| 6 ensayo largo | | |

Con esta tabla completa, se fijan los textos del diálogo de instrucciones (§3.4 del spec) con los de tu Chrome y se cierra el Paso 0.
