# Guía del administrador: grabar una reunión

La grabación se hace **desde la sala de moderación del panel**, en **tu computador**. El archivo se guarda en tu carpeta **Descargas**. **No se sube a ningún servidor.**

> Estado: implementada; pendiente de la verificación en los PCs reales ([`GRABACION-PASO0.md`](GRABACION-PASO0.md)). Haz un ensayo antes de la primera asamblea real.

---

## 1. Antes del día de la reunión (una sola vez)

**Navegador:** **Google Chrome** de escritorio, actualizado, en macOS o Windows. Safari y Firefox **no pueden grabar el sonido**. Desde un móvil o una tablet **no se puede grabar** (el panel lo avisa).

**macOS**
- Ajustes del Sistema → Privacidad y seguridad → **Micrófono** → Google Chrome activado.
- Ajustes del Sistema → Privacidad y seguridad → **Grabación de pantalla y audio del sistema** (en macOS 13–14: «Grabación de pantalla») → Google Chrome activado. Hace falta para compartir la pantalla en Jitsi y puede que también para grabar. Al activarlo, macOS **obliga a reiniciar Chrome**: hazlo antes, **nunca durante** la reunión.
- Energía: el portátil **enchufado** y con la tapa abierta.

**Windows**
- Configuración → Privacidad y seguridad → **Micrófono** → «Permitir que las aplicaciones de escritorio accedan al micrófono» activado.
- Configuración → Sistema → Inicio/apagado y batería → que **no suspenda** mientras está enchufado.

**Los dos**
- **Usa auriculares.** Con altavoces, tu micrófono recoge la voz de la sala y la grabación tiene eco.
- **Espacio en disco:** ≈ **0,5 GB por hora**. Hace falta el **doble** libre (copia interna de Chrome + archivo en Descargas). La tarjeta «Grabación» muestra el espacio libre en horas.
- Para convertir a MP4 instala **ffmpeg** o **HandBrake** (punto 5).

## 2. Grabar

1. En el panel, abre la reunión → **Moderación**.
2. En la tarjeta **Grabación** (la primera de la derecha), pulsa **● Grabar esta reunión**.
3. Lee el aviso «Antes de grabar» y pulsa **Continuar**.
4. Chrome pregunta qué compartir:
   - Debe ser **esta pestaña** (la de «Moderación · …»).
   - Deja **marcada** la casilla **«Compartir también el audio de la pestaña»**. **Sin ella, la grabación sale sin voz** (el panel no te deja seguir).
   - Pulsa **Compartir**.
5. Oirás un **bip corto**: es la prueba de sonido. Si todo está bien, la grabación **empieza sola**:
   - Punto rojo, contador de tiempo y tamaño del archivo, que tiene que ir **creciendo**.
   - Una **franja roja** encima de la reunión con el aviso legal. Sale en cada fotograma del vídeo.
   - Todos los asistentes ven en Jitsi «● GRABANDO · *título*», y en el chat aparece el aviso con el responsable.
6. **Lee en voz alta** el texto que aparece en la tarjeta («Informo a los asistentes que…»). Así el aviso queda también en el audio.

Después de la primera grabación, el diálogo ofrece «No volver a mostrar estas instrucciones». Las comprobaciones se hacen **siempre**.

### Qué se graba

- La **reunión** (lo que ves en Jitsi) y la franja legal. **No** se graba el panel de la derecha (nombres, botones de moderación).
- El sonido de la reunión **y tu micrófono**, pero **solo cuando tu micro está abierto en Jitsi**. Si te silencias en Jitsi, lo que digas no se graba.
- Lo que **tú** ves y oyes: si tu conexión falla, la grabación también.

## 3. Mientras graba

- **No cierres la pestaña** ni recargues la página. Si lo intentas, Chrome pregunta «¿Salir del sitio?».
- Puedes moderar con normalidad.
- **No bajes la página** para tapar la reunión. Si la reunión deja de verse, el panel graba la pestaña entera (panel incluido) hasta que vuelva a verse, y te avisa.
- Avisos que pueden salir:

| Aviso | Qué hacer |
|---|---|
| «Tu voz no quedará en la grabación» | Chrome no deja usar el micrófono. Revisa el permiso (punto 1). El resto de la reunión sí se graba |
| «El sonido llega muy bajo» | Sube el volumen de la pestaña o del sistema |
| «Hace 10 min que no se graba sonido» | Comprueba que la pestaña no esté silenciada (clic derecho en la pestaña) |
| «La reunión debía terminar a las …» | Pulsa **Detener** o **Seguir grabando** (vuelve a avisar cada 15 min). **No hay límite de duración** |
| «Queda espacio para ≈ N min» | Libera espacio en el disco o detén la grabación. Si el disco se llena, la grabación **se detiene y se guarda sola** |
| «La grabación no está recibiendo datos» | Vuelve a la pestaña de la sala y comprueba que la reunión se ve |
| «La reunión no está entera a la vista» | Sube en la página |

## 4. Terminar

- Pulsa **■ Detener y guardar** → **Detener**. El archivo se descarga en **Descargas** con un nombre como `Asamblea-ordinaria-2026-2026-11-15-0905.webm`.
- La grabación también **se detiene y se guarda sola** si pulsas «Dejar de compartir» en la barra de Chrome o si cuelgas en Jitsi.
- Si la descarga falló, pulsa **Volver a descargar**.
- Cuando tengas el archivo copiado donde corresponda, pulsa **«Ya lo tengo guardado, borrar copia»**.

### Copia de seguridad y recuperación

Mientras graba, Chrome guarda una **copia interna cada 5 segundos**. Si Chrome o el PC se cierran de golpe, al volver a abrir la sala aparece **«Hay una grabación que no se guardó»** → **Descargar** (archivo `…-recuperada.webm`, que se reproduce hasta el corte) o **Descartar**.

Las copias internas están en «**Copias en este computador**», al final de la tarjeta, y **se borran solas a los 7 días**. Ocupan espacio del disco, aunque no se vean en ninguna carpeta.

## 5. Convertir a MP4

El `.webm` se abre en Chrome, Edge, Firefox y **VLC**. **QuickTime (Mac)** y algunos reproductores de Windows **no lo abren**: para eso, convierte a **MP4**.

### Opción A: conversor de un clic (ffmpeg)

Los archivos están en `scripts/grabacion/` del repositorio. Cópialos a tu PC (por ejemplo, a Descargas).

**macOS: `convertir-mp4.command`**
1. Instala ffmpeg una vez. Instala Homebrew siguiendo <https://brew.sh> y después, en la app Terminal: `brew install ffmpeg`.
2. Doble clic en `convertir-mp4.command`. La primera vez macOS lo bloquea: **clic derecho → Abrir → Abrir**.
3. Arrastra el `.webm` a la ventana y pulsa Enter. Con Enter sin nada, convierte **todas** las grabaciones `Asamblea-*.webm` de Descargas que aún no tengan su MP4.

**Windows: `convertir-mp4.bat`**
1. Instala ffmpeg una vez: abre «Terminal» y escribe `winget install --id Gyan.FFmpeg -e`. Si no está instalado, el propio `.bat` te ofrece instalarlo.
2. **Arrastra el `.webm` encima de `convertir-mp4.bat`**, o haz doble clic para convertir todas las de Descargas. Si SmartScreen avisa: «Más información» → «Ejecutar de todas formas».

El MP4 aparece **junto al original**, con el mismo nombre. El `.webm` no se borra. Formato: H.264 + AAC, preparado para web (`+faststart`). Una reunión de 4 h tarda **minutos**, no horas.

Comando equivalente, por si prefieres escribirlo tú:
```sh
ffmpeg -i Asamblea-….webm -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -preset veryfast -crf 26 -r 15 \
       -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart Asamblea-….mp4
# Solo el audio, para el acta o para transcribir:
ffmpeg -i Asamblea-….webm -vn -c:a libmp3lame -q:a 4 Asamblea-….mp3
```

### Opción B: HandBrake (sin terminal)

1. Descarga **HandBrake** (gratis, macOS y Windows) de <https://handbrake.fr> e instálalo.
2. Abre HandBrake → **Open Source** / «Abrir origen» → elige el `.webm`.
3. En **Preset** elige **General → Fast 720p30**.
4. En **Format** deja **MP4** y marca **Web Optimized** (equivale a `+faststart`).
5. Abajo, en **Save As**, elige nombre y carpeta → **Start**.
6. Al terminar, abre el `.mp4` en QuickTime o en el Reproductor multimedia para comprobarlo.

HandBrake **no** cambia la grabación original.

## 6. Si algo falla

| Problema | Causa probable | Solución |
|---|---|---|
| El botón está gris y dice «abre esta página en Google Chrome» | Safari, Firefox u otro navegador | Usa Google Chrome |
| «La reunión NO se está grabando» | Estás en un móvil o una tablet | Graba desde un computador |
| «No marcaste Compartir audio de la pestaña» | Casilla de audio desmarcada | **Volver a intentarlo** y deja la casilla marcada |
| «Elegiste otra ventana o pestaña» | Se compartió otra cosa | **Volver a intentarlo** y elige esta pestaña |
| «La grabación no capta el sonido» | Pestaña silenciada o volumen a cero | Clic derecho en la pestaña → «Activar sonido del sitio» → Volver a intentarlo |
| «Chrome no tiene permiso para grabar la pantalla» (Mac) | Falta el permiso de macOS | Punto 1 (macOS) y **reinicia Chrome** |
| Se cerró Chrome a mitad | — | Vuelve a abrir la sala → «Hay una grabación que no se guardó» → Descargar |

## 7. Configuración (para quien instala el panel)

El panel no lleva ningún nombre fijo. En `admin-panel/instance/admin.env` (ver `admin.env.example`):

| Variable | Para qué | Si falta |
|---|---|---|
| `JITSI_SITE_NAME` | Nombre visible del conjunto o entidad (cabecera, login, pestaña) | «Panel de reuniones» |
| `JITSI_SITE_SUBTITLE` | Texto pequeño junto a la marca | «Reuniones» |
| `JITSI_LEGAL_OWNER` | **Responsable del tratamiento** de los datos: pie de la franja de grabación, mensaje del chat y texto para leer en voz alta. Pon la razón social exacta | El valor de `JITSI_SITE_NAME` |

El texto del aviso es genérico: «Esta reunión se está grabando en audio y vídeo. Al participar, usted lo autoriza.», seguido del responsable. **Lo valida el administrador** antes de usarlo. Para cambiarlo, edita `#grab-aviso-texto` en `admin-panel/app/page_sala.html`. Tras cambiar `admin.env`, reinicia el contenedor del panel (`docker compose up -d --force-recreate admin`).
