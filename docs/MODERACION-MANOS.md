# Manos levantadas: cómo bajarlas desde el panel

> Función del **panel de moderación de Cerro Azul** (`/admin/reunion/<id>/sala`),
> no de Jitsi. Desplegada y verificada en producción el 2-nov-2026
> (commits `740da81`, `4193357`, `cbc4b47`). El operador la confirmó en una
> asamblea real: «funciona perfecto».
> Diagnóstico técnico del fallo original: [TROUBLESHOOTING](TROUBLESHOOTING.md#-bug-el-botón-bajar-todas-las-manos-no-hace-nada-2-nov-2026).

## Para qué sirven

En una asamblea los micrófonos están cerrados. Quien quiere hablar **levanta la
mano**: el botón ✋ de su barra de Jitsi (en el computador, también la tecla
`R`). El administrador ve la lista en el panel, con la mano levantada primero y
la etiqueta `[mano]`, y le da la palabra con «Pedir la palabra».

Cuando termina el turno (o tras una votación), las manos se quedan levantadas
hasta que alguien las baja. Eso es lo que hace el panel.

## Qué puede hacer el administrador

En la tarjeta **Participantes** del panel:

| Botón | Dónde | Qué hace |
|---|---|---|
| **Bajar todas las manos** | Barra encima de la lista | Baja la mano de **todos** los que la tienen levantada, de un golpe |
| **Bajar la mano** | Una fila por cada persona con la mano levantada, debajo de esa barra | Baja solo la de esa persona |

- El botón global está **gris (deshabilitado)** cuando nadie tiene la mano
  levantada. Al lado dice cuántas hay («2 manos levantadas.»).
- Cada pulsación queda anotada en el **registro** (`#log`) del panel: a cuántas
  personas se envió, con qué ids y, 5 s después, si bajaron.
- Junto a cada participante siguen los botones de siempre: *Pedir la palabra*,
  *Silenciar*, *Habilitar cámara*, *Apagar cámara*.

¿Por qué no basta el botón nativo de Jitsi («Lower all hands»)? Vive escondido
en el pie del panel de participantes de Jitsi (botón `⋯`), y además en este
servidor **no funciona** (va por el videobridge, ver más abajo).

## Procedimiento

1. Abre la sala de moderación del panel y espera a que Jitsi cargue.
   **Si se acaba de desplegar una versión nueva del panel, recarga la página**
   (Ctrl+F5) antes de la asamblea, para no quedarte con el JavaScript viejo.
2. Cuando quieras limpiar la cola: **Bajar todas las manos**. Para una sola
   persona: su **Bajar la mano**.
3. En menos de un segundo las etiquetas `[mano]` desaparecen y el botón vuelve a
   ponerse gris.

## Si no funciona (1 minuto)

Mira el **registro** al pie del panel (la línea más nueva va arriba):

| Lo que dice | Qué significa / qué hacer |
|---|---|
| `bajar todas las manos: todas las manos enviadas han bajado` | Funcionó |
| `siguen levantadas 5 s después: [id, …]` | Ese cliente no obedeció. Prueba «Bajar la mano» en esa persona; si sigue, pídele que la baje ella (¿app móvil? ver limitaciones) |
| `fallo (la sala de Jitsi aún no está lista), reintento en 2 s` | Jitsi aún cargaba; reintenta solo una vez |
| `ERROR … no eres moderador en la sala` | Entraste sin rol de moderador: vuelve a abrir la sala desde el panel |
| `ERROR … el panel y la sala no están en el mismo dominio` | El panel no se abrió desde `meet.bytracking.net/admin/…` |
| `AVISO Jitsi tiene N manos y #lista muestra M` | La lista del panel y Jitsi no coinciden (ver limitaciones); se envía igual a las N de Jitsi |
| No aparece ninguna línea al pulsar | JavaScript viejo en caché: recarga la página (Ctrl+F5) |

## Limitaciones conocidas

- **App móvil de Jitsi: sin probar.** El mensaje es privado, uno por persona.
  Usa la misma biblioteca, pero no se ha comprobado con la app. Si alguien
  entra con la app y su mano no baja, pídele que la baje él.
- **La mano del propio administrador** no se baja desde el panel: bájala con el
  botón ✋ de tu barra de Jitsi.
- **Recargar el panel a mitad de asamblea: sin probar.** La lista `[mano]` del
  panel se pinta con el evento `raiseHandUpdated`. Si las manos ya estaban
  levantadas antes de recargar, puede que no aparezcan en la lista (y el botón
  global siga gris) hasta que cambie alguna mano. Las filas «Bajar la mano»
  salen del estado de Jitsi y deberían aparecer igualmente.

## Cómo funciona (técnico)

- El panel y Jitsi están en el mismo origen, así que el JavaScript del panel
  (`admin-panel/app/static/bajar-manos.js`) llega al `APP` del iframe.
- Saca la lista de quién tiene la mano de
  `APP.store.getState()["features/base/participants"].raisedHandsQueue` (sin
  el admin). Son los mismos ids que trae `raiseHandUpdated`: id de
  participante = endpoint id (8 hex).
- Envía a **cada uno**, por separado, un mensaje privado **por XMPP** (el MUC
  de Prosody), no por el videobridge:
  ```js
  conf.sendMessage({ name: "lower-hand-message" }, id);   // por cada id
  ```
- El cliente de cada residente ya trae el receptor (verificado en
  `app.bundle.min.js` de `stable-11031`):
  ```js
  r.name===qU && t.isModerator()
    && !(… a()["features/base/config"].raisedHands?.disableLowerHandByModerator)
    && o(tk(!1))                 // qU = "lower-hand-message"; tk(!1) baja la mano
  ```
  Solo obedece si quien lo envía es moderador. Nuestra config no define
  `disableLowerHandByModerator`, así que está permitido.
- Verificación: `scripts/verificar-bajar-manos.py` (local, Jitsi simulado) y
  `scripts/probar-bajar-manos-prod.py` (producción, dos residentes reales
  B1/B2 que levantan la mano de verdad): «Bajar la mano» de B1 baja solo la de
  B1; «Bajar todas las manos» baja las dos, el admin ve 0 `[mano]` y el botón
  vuelve a gris; la vía antigua por el videobridge no baja ninguna (control).
