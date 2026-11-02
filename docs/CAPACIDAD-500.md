# Capacidad para 500 personas (Fase 5)

> Estado a 3-nov-2026. **Decisión: no se compra servidor dedicado.** Con el uso
> real de la asamblea, el VPS actual tiene ancho de banda suficiente según la
> medición del 2-nov. Lo que queda sin probar está en [Pendiente](#pendiente).

## 1. El modelo de uso real

El plan original pedía, para 500 asistentes, un JVB en un servidor dedicado con
1 Gbit/s sin tope de tráfico. Ese plan suponía muchos vídeos a la vez. La
asamblea no funciona así. Lo explica el administrador:

> *"se conectan 500 pero solo el moderador prende la cámara y/o presenta
> pantalla; nadie más; los demás tienen el micrófono cerrado. Y cuando otro pide
> la palabra, el moderador le da la palabra y ya nada más. O sea: todos están
> escuchando a una única persona presentando siempre."*

Así que nunca hay más de una o dos personas transmitiendo vídeo. El JVB
reenvía **una** pista de vídeo (más el audio de quien habla) a cada oyente. El
coste crece con el número de oyentes, no con el de emisores. El límite es la
**subida del VPS**, no su CPU: con 48 simultáneos el JVB no pasó del 17 % de
CPU ([`loadtest/README.md`](../loadtest/README.md)).

## 2. Metodología

Herramienta: [`loadtest/medir-bitrate.py`](../loadtest/medir-bitrate.py), en el
host de desarrollo.

1. Crea una reunión de prueba en el panel de producción (la borra al terminar).
2. Abre 1 emisor con la cámara falsa de Chromium y N receptores reales en
   Chromium headless. Todos entran por `/unirse`, como un vecino.
3. Lee dos veces `/proc/net/dev` del VPS y resta los bytes **enviados** por las
   interfaces físicas (sin `lo`, `docker0` ni `veth*`) entre las dos lecturas.
4. Divide entre N para obtener la subida por receptor y la multiplica por 100,
   300 y 500.

Por qué se mide así:

- **Se mide por receptor y se extrapola.** No se pueden generar 500 clientes:
  las pruebas de carga del 1-nov se quedaron en 48 simultáneos porque se agotó
  la RAM de las máquinas que lanzaban los navegadores, no el servidor. Lo que
  cuesta cada oyente sí se puede medir con pocos.
- **Se mide la subida del host.** Es lo que se acaba primero. Incluye todo:
  vídeo, audio, RTCP, señalización y el resto del tráfico del VPS en ese momento
  (por eso el resultado es un poco pesimista).
- **Cámara, no pantalla.** En headless `getDisplayMedia` falla, así que la
  fuente es la cámara falsa. La pantalla compartida suele usar más bitrate
  que una cámara a 360p (ver §4).

## 3. Números

| Dato | Valor | Origen |
|---|---|---|
| Subida del VPS | **~220 Mbit/s** | Medida antes de la prueba (descarga ~149 Mbit/s). VPS de 4 vCPU, 8 GB de RAM y 145 GB de disco (110 libres) |
| Prueba con 50 personas reales | **sin problemas** | El operador, 2-nov-2026: cámara, audio y pantalla. Sin medición de red; es la prueba real más grande |
| Pico de la prueba de carga | 48 simultáneos, JVB 9–17 % CPU | 1-nov-2026, commit `0782429` |

Medición del 2-nov-2026 (6 receptores reales + 1 emisor con cámara):

| | Antes de la línea `bitrate` | Después |
|---|---|---|
| Subida total | 2,43 Mbit/s | 1,90 Mbit/s |
| **Por receptor** | 0,405 Mbit/s | **0,316 Mbit/s** |
| **Extrapolado a 500** | 203 Mbit/s | **158 Mbit/s** |

Desglose estimado a 500 personas, si el vídeo del ponente se mantiene en
~320 kbit/s:

| Flujo | Consumo |
|---|---|
| Audio (500 oyentes, Opus mono) | ~15 Mbit/s |
| Vídeo del ponente a 320 kbit/s | ~160 Mbit/s |
| Señalización y overhead | ~10 Mbit/s |
| **Total** | **~175–185 Mbit/s** de 220 |

**Las dos mediciones caben por debajo de 220 Mbit/s.** Con 203 Mbit/s, la de
"antes" tiene poco margen.

## 4. El cambio de configuración (y lo que no está verificado)

Añadido el 2-nov en `web/config/custom-config.js` y **ya desplegado en
producción** (en el repo está pendiente de commit):

```js
config.constraints = {
    video: {
        height: { ideal: 360, max: 720, min: 180 },
        bitrate: { ideal: 280000, max: 320000 }
    }
};
```

**Advertencia: no está demostrado que esta línea limite nada.** Revisión del
bundle desplegado (`jitsi/web:stable-11031`, 3-nov):

- `config.constraints` solo se usa al construir las constraints de
  `getUserMedia` para la **cámara**: `const i=hs(t.constraints||Co)` en
  `lib-jitsi-meet.min.js`. Ningún código lee `constraints.video.bitrate`, y
  `bitrate` no es una constraint estándar de `getUserMedia`: el navegador la
  ignora.
- La **pantalla compartida no usa `config.constraints`**.
  `obtainScreenFromGetDisplayMedia` solo toma `desktopSharingFrameRate`,
  `resolution` y `screenShareSettings`. Así que la idea de que la pantalla
  comparte constraints con la cámara **no se confirma** en esta versión.
- En esta versión, Jitsi limita el bitrate del emisor con
  `config.videoQuality.maxBitratesVideo` (por códec y capa: `low`, `standard`,
  `high`, `ssHigh` para la pantalla…). Hoy no está definida en la config, así
  que se aplican los valores por defecto del bundle.

En resumen: el paso de 0,405 a 0,316 Mbit/s por receptor es una medición real,
pero **no se puede atribuir a la línea `bitrate`**. Puede venir de la
variación entre ejecuciones: arranque del estimador de ancho de banda, la
cámara falsa o el resto del tráfico del host. Para un tope real habría que
usar `videoQuality.maxBitratesVideo` y volver a medir antes y después
([Pendiente](#pendiente)).

La conclusión de la Fase 5 **no depende de este tope**: con la medición sin
él (203 Mbit/s a 500) también se queda por debajo de la subida del VPS.

## 5. La calidad depende de la red de cada vecino

El JVB manda la misma pista a todos, pero **adapta lo que envía a cada
receptor** según su estimación de ancho de banda (BWE). Si un vecino solo puede
recibir 300 kbit/s, el JVB le baja la capa de vídeo o le **suspende** la
pantalla (`Sources suspended due to insufficient bandwidth` en el log del JVB),
y la ve degradada o en negro. Con 3,2 Mbit/s (el máximo visto en los logs del
JVB) la ve perfecta. Eso es un problema de **su** conexión: en el servidor no
hay nada que tocar ([`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)).

Por eso la **moderación A/V** importa también para la capacidad. Si solo
transmite quien tiene la palabra, todo el ancho de banda de cada receptor va
a esa persona, y la subida del VPS se queda en una pista por oyente.

## 6. Conclusión

- **No hace falta servidor dedicado** para asambleas de 500 con un ponente.
- El límite del servidor es la **subida del VPS (~220 Mbit/s)**. Por debajo de
  eso, el límite lo pone la red de cada vecino.
- Si algún día hubiera varios vídeos a la vez (otra forma de reunión), esta
  cuenta deja de valer: cada pista extra suma ~0,3–0,4 Mbit/s por oyente.

## Pendiente

| Qué | Por qué | Cómo |
|---|---|---|
| **Tope de tráfico mensual del VPS** | No se puede ver desde dentro del servidor. Una asamblea de 2 h a ~180 Mbit/s son unos 160 GB de salida | Panel del proveedor (Contabo) |
| **Prueba con 500 reales** | La mayor prueba real es de **50** (operador, 2-nov). La de 48 la hizo el generador de clientes. 500 es una extrapolación | Asamblea real o ensayo, vigilando la subida del host y `insufficient bandwidth` |
| **Muchas redes distintas a la vez** | Las mediciones se hicieron desde un solo host con buena red. No se ha visto cuántos vecinos tendrán la pantalla recortada por el BWE | Contar `insufficient bandwidth` en el log del JVB durante una asamblea grande |
| **Tope de bitrate efectivo** | La línea `constraints.video.bitrate` no parece hacer nada (§4) | Probar `config.videoQuality.maxBitratesVideo` y medir con `medir-bitrate.py` antes y después |
| **Modo "asamblea" en el panel** | Propuesto: cuando la reunión es grande, el panel baja `channelLastN` a 1 y el bitrate de la pantalla | En cola, **no implementado** |
