# Botones de la sala que muestran el estado real

**Problema (operador, 2026-11-02):** «cuando se hace clic no se ve el cambio de condición, no se sabe si
funcionan o no». Los botones de `page_sala.html` tenían clases fijas: los globales en el HTML y los de
cada participante recreados en cada `pintar()` con clases fijas. Ningún botón reflejaba el estado.

**Ahora:** cada botón dice **lo que hará según el estado real** y cambia de texto, de estilo y de `aria-*`.
Nada se marca como hecho al pulsar. El cambio solo se pinta cuando Jitsi lo confirma con un evento.

## Qué se mide y de dónde sale

Todo lo de esta tabla se midió en producción el 2026-11-02 con un admin y un residente headless en una sala
propia. La sonda registraba los eventos del iframe API en el admin y el estado en el cliente del residente.

| Estado | Fuente | Notas |
|---|---|---|
| Micro / cámara / pantalla de **cada participante** | evento `participantMuted {id, isMuted, mediaType}` (`audio`/`video`/`desktop`) | Llega cuando se añade la pista del residente y cada vez que cambia. |
| Estado **inicial** del micro | store de Jitsi del iframe (`features/base/tracks`), mismo origen | Quien entra con el micro apagado **no tiene pista de audio**. Jitsi no emite ningún `participantMuted` de audio hasta que lo abre. Sin pista, el admin no recibe ese medio: se pinta como cerrado. Si el store no se puede leer, queda «sin datos». |
| Permiso (¿la moderación le impide abrir?) | `api.isParticipantForceMuted(id, "audio"\|"video")` | Se vuelve a consultar con `moderationParticipantApproved`, `moderationParticipantRejected` y `moderationStatusChanged`. |
| Mano levantada | `raiseHandUpdated` | Ya existía. |
| Moderación A/V (global) | `moderationStatusChanged {mediaType, enabled}` + `api.isModerationOn` | Ya existía para los badges `#st-audio` / `#st-video`. |
| «Dar a todos» / «Quitar a todos» | = moderación de **audio** apagada / encendida | Estado real, no optimista. |
| «Micrófonos» / «Cámaras» (silenciar a todos) | recuento de micros abiertos y cámaras encendidas a partir de `participantMuted` | Es una orden puntual, no un interruptor: no lleva `aria-pressed`. Su resultado se ve en la línea «Ahora: N micros abiertos». No hizo falta estado optimista. |

**Lo que NO sirve, aunque el nombre lo sugiera:** `audioMuteStatusChanged` y `videoMuteStatusChanged` solo
informan del **propio admin**: traen `{muted}` sin id. Por eso no se usan para las filas.

`null` significa **no se sabe**. El chip dice «sin datos» y el botón sale neutro: sin clase y sin
`aria-pressed`.

## Silenciar = `muteRemoteParticipant` + `rejectParticipant`

Medido con un residente que tenía la palabra:

- `muteRemoteParticipant(id, "audio")` le cierra el micro, **pero conserva la aprobación**. Pulsó «m» y
  volvió a hablar.
- `rejectParticipant(id, "audio")` **sí existe** (`rejectParticipant: "reject-participant"` en
  `external_api.js`) y revoca la aprobación, **pero no le cierra el micro**. Siguió hablando hasta que
  lo cerró él.
- Con las dos órdenes, el micro se cierra y no puede reabrirlo. Es lo mismo que hace el menú «Silenciar»
  del propio Jitsi: en `app.bundle.min.js`, `KV(id, AUDIO)` + `Aa(id)`. `muteEveryone` hace igual con
  cada participante.

Firma en el bundle: `"reject-participant": (e, t) => { …; const n = t === "video" ? rechazarVideo : rechazarAudio; … }`.
Se pasa siempre el tipo explícito (`"audio"` o `"video"`). Sin tipo rechaza el audio, no «todo».

El comentario anterior de `page_sala.html` («NO existe 'rejectParticipant'») era **falso** y se ha corregido.

## Cómo se pinta cada botón de participante

Lo calcula `SalaEstado.boton()` (`admin-panel/app/static/sala-estado.js`, funciones puras) en cada
`pintar()`. Al pulsar, la acción se recalcula con el estado actual, no con el del momento en que se pintó.

| Estado real | Botón de micro | Botón de cámara | Clase | `aria-pressed` |
|---|---|---|---|---|
| abierto | Silenciar | Apagar cámara | `d` | `true` |
| cerrado, sin permiso | Dar la palabra (con mano: «Dar la palabra (la pidió)» + `.pide`) | Habilitar cámara | `ok2` | `false` |
| cerrado, con permiso | Quitar la palabra | Quitar la cámara | `d` | `true` |
| cerrado, moderación apagada | Micro cerrado (`aria-disabled`) | Cámara apagada (`aria-disabled`) | — | `false` |
| sin datos | Silenciar (neutro) | Apagar cámara (neutro) | — | — |
| orden enviada sin confirmar | «Enviando…» (`aria-busy`, `aria-disabled`) | ídem | — | — |

Encima de los botones, los chips dicen en texto el estado: «Micro abierto», «Cámara apagada»,
«Cámara: sin datos», «Comparte pantalla». No se depende solo del color. El `aria-label` empieza por el
texto visible y añade el nombre y el estado.

Hay **dos botones** por persona en lugar de cuatro. Cada uno alterna entre las acciones que antes estaban
separadas: «Pedir la palabra» / «Silenciar» y «Habilitar cámara» / «Apagar cámara». En cada estado solo se
ofrece la acción que tiene sentido.

## Botones globales

Son interruptores con etiqueta **fija** y `aria-pressed`. Es el patrón accesible de un botón conmutador: la
etiqueta no cambia y el estado sí. El pulsado lleva `✓` y borde (CSS). Además, cada grupo tiene una línea
«Ahora: …» (`#gl-est-palabra`, `#gl-est-silencio`, `#gl-est-mod`).

- «Activar» / «Desactivar» actúan sobre audio **y** vídeo. Solo está pulsado el que coincide con las dos.
  Tras «Dar a todos» la moderación queda mixta (audio apagada, vídeo activa) y no hay ninguno pulsado.
- «Micrófonos» / «Cámaras» se ponen en rojo solo si hay algo abierto que cerrar.

## Errores

`executeCommand` no devuelve resultado.

- Si **lanza**, se anota `ERROR <comando>: …` en `#log` y el botón no cambia.
- Si **no lanza**, el botón pasa a «Enviando…» hasta que llegue el evento que lo confirma. Si a los 6 s no
  ha llegado, vuelve al estado real y se anota `AVISO …: sin confirmar en 6 s`.
- Las órdenes globales se comprueban a los 2,5 s con `isModerationOn`. Si no coinciden, se anota un AVISO.

## `data-id` en cada fila

Se añadió `div.p[data-id="<id del participante>"]`. Es un atributo nuevo y las clases e ids del contrato no
cambian. Sirve para conservar el foco del teclado al repintar (`button[data-accion]`) y para que las pruebas
localicen la fila de un residente concreto.

## Contrato

Sin cambios: ids `#jitsi #lista #cnt #log #st-audio #st-video`, `.gl` con exactamente 6
`button[data-cmd]` y las clases `.p .n .mano .m .ok2 .d`.

Nuevo: `div.p[data-id]`, `div.est`, `button[data-accion]`, `.pide`, `#gl-est-*` y
`/admin/static/sala-estado.js`, que se carga entre `grabacion.js` y el script de la sala.

El script de la sala estaba congelado (regla D8) y se abrió a sabiendas. La comprobación «idéntico a
0782429» de `verificar-panel-local.py` ya fallaba desde 4e19178/140cd43. Se ha sustituido por una
comprobación del contrato del JS.

## Verificación

- `scripts/probar-sala-estado.js`: tabla de casos de `SalaEstado` con node. La ejecuta
  `scripts/verificar-panel-local.py`, que además pasa `node --check` y comprueba el contrato del JS.
- `scripts/probar-estado-botones-prod.py`: producción, un admin y dos residentes reales. Ver la cabecera.
  También se lanza con `scripts/verificar-panel-prod.py --estado-botones`.
