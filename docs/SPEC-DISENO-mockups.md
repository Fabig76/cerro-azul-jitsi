# SPEC-DISENO — Mockups de pantallas

> Complemento de [`SPEC-DISENO.md`](SPEC-DISENO.md). Sirve para **aprobar el aspecto antes de escribir código**.
> Los nombres entre `‹ ›` son tokens o componentes del spec (sección 3). Los textos asumen aprobadas
> D1 (hora de Colombia), D2 (descripción), D3 (estado), D4 (tildes) y D5 (cerrar sesión en el menú).
> Fechas de ejemplo: la asamblea es el **martes 3 de noviembre de 2026 a las 7:00 p. m.** (Colombia).

Leyenda de los dibujos:

```
┌──┐ tarjeta / superficie ‹surface›      [ Botón ]  botón primario (relleno azul)
░░░░ degradado de marca                  ( Botón )  botón secundario (gris)
▓▓▓▓ esqueleto de carga                  { Botón }  botón tintado (soft-success / soft-danger)
⋯    menú desplegable (<details>)        ‹badge›    etiqueta de estado
```

---

## M0. Elementos comunes

### Cabecera del administrador (`kind="admin"`), fija arriba, translúcida

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  ◭ Cerro Azul  Reuniones                                                  ⋯  │  56 px
└──────────────────────────────────────────────────────────────────────────────┘
   └ marca: SVG 2 picos con degradado azul→índigo; "Cerro Azul" 600; "Reuniones" gris
```

Menú `⋯` abierto (popover con sombra 3, radio 14):

```
                                                   ┌─────────────────────────────┐
                                                   │ APARIENCIA                  │
                                                   │ ┌─────────────────────────┐ │
                                                   │ │ Auto │ Claro │ Oscuro   │ │  control segmentado
                                                   │ └─────────────────────────┘ │
                                                   │ ─────────────────────────── │
                                                   │ Cerrar sesión               │  44 px de alto
                                                   └─────────────────────────────┘
```

### Pie de las páginas públicas y del login

```
                Cerro Azul  ·  Apariencia: Automático ◐
                (texto 12 px gris; el botón rota Auto → Claro → Oscuro)
```

---

## M1. Login del administrador (`/admin/login`)

**Intención:** primera impresión de producto. Fondo con "aurora" (tres manchas de color difuminadas: azul arriba-izquierda, índigo arriba-derecha, verde-azulado abajo) sobre `‹bg›`. Una sola tarjeta flotante.

### Escritorio (1280 px)

```
 ·  ·  ·  ·  (aurora azul)  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  (aurora índigo)  ·  ·  ·
                                                                                    
                        ┌────────────────────────────────────┐   radio 20, sombra 3
                        │                                    │   ancho 440 px
                        │              ( ◭ )                 │   círculo 64 px con degradado,
                        │                                    │   montaña blanca dentro
                        │            Cerro Azul              │   31 px / 700
                        │        Panel de reuniones          │   16 px gris
                        │                                    │
                        │  ┌──────────────────────────────┐  │   ← solo si hay error:
                        │  │ ⓧ Usuario o contraseña       │  │     alert--error (rojo tenue)
                        │  │   incorrectos.               │  │
                        │  └──────────────────────────────┘  │
                        │                                    │
                        │  Usuario                           │   etiqueta 14 px / 500
                        │  ┌──────────────────────────────┐  │
                        │  │                              │  │   campo 44 px, texto 16 px
                        │  └──────────────────────────────┘  │
                        │  Contraseña                        │
                        │  ┌──────────────────────────────┐  │
                        │  │ ••••••••                     │  │
                        │  └──────────────────────────────┘  │
                        │                                    │
                        │  [            Entrar             ] │   52 px, ancho completo
                        │                                    │
                        └────────────────────────────────────┘
                     Acceso restringido al personal autorizado de Cerro Azul
                                                                                    
 ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  (aurora verde-azulada)  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·
                         Cerro Azul · Apariencia: Automático ◐
```

- Margen superior de la tarjeta: 12 vh (no centrado vertical rígido: con el teclado del móvil abierto no salta).
- Al pulsar "Entrar": el texto se sustituye por un giro (spinner) y el botón queda deshabilitado.

### Móvil (360 px)

```
┌────────────────────────────────┐
│ (aurora)                       │
│  ┌──────────────────────────┐  │   tarjeta a 16 px de los bordes
│  │          ( ◭ )           │  │
│  │        Cerro Azul        │  │   25 px
│  │    Panel de reuniones    │  │
│  │                          │  │
│  │  Usuario                 │  │
│  │  ┌────────────────────┐  │  │
│  │  └────────────────────┘  │  │
│  │  Contraseña              │  │
│  │  ┌────────────────────┐  │  │
│  │  └────────────────────┘  │  │
│  │  [       Entrar       ]  │  │
│  └──────────────────────────┘  │
│   Acceso restringido…          │
└────────────────────────────────┘
```

---

## M2. Panel de reuniones (`/admin`) — la pantalla más usada

**Intención:** ver de un vistazo qué reuniones hay y llegar a "Moderar" en un clic. Crear es secundario (se hace una vez por asamblea).

### Escritorio (1280 px): dos columnas

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  ◭ Cerro Azul  Reuniones                                                          ⋯  │
└──────────────────────────────────────────────────────────────────────────────────────┘

   Reuniones                                                     31 px / 700
   Sesión iniciada como Hguaza76                                 14 px gris

   ┌──────────────────────────────────────────────┐   ┌──────────────────────────────┐
   │ (solo si hay problema JWT)                   │   │ Nueva reunión          20/600│
   │ ⓧ Configuración JWT incoherente              │   │ Genera el link y el QR       │
   │   Jitsi rechazará los tokens…                │   │                              │
   └──────────────────────────────────────────────┘   │ Título                       │
                                                      │ ┌──────────────────────────┐ │
   ┌──────────────────────────────────────────────┐   │ │Ej: Asamblea ordinaria nov│ │
   │ ┌─────┐                                      │   │ └──────────────────────────┘ │
   │ │ NOV │ Asamblea ordinaria noviembre         │   │ Descripción       Opcional   │
   │ │  3  │ mar 3 nov · 7:00 p. m. · 60 min      │   │ ┌──────────────────────────┐ │
   │ └─────┘ ‹● Próxima›                          │   │ │Agenda, temario…          │ │
   │         meet.bytracking.net/reunion/ab12cd │   │ │                          │ │
   │                    [ Moderar ] ( Ver QR ) ⋯  │   │ └──────────────────────────┘ │
   │ ──────────────────────────────────────────── │   │ Fecha            Hora        │
   │ ┌─────┐                                      │   │ ┌───────────┐  ┌──────────┐ │
   │ │ OCT │ Reunión consejo de administración    │   │ │ 03/11/2026│  │ 07:00 p.m│ │
   │ │ 28  │ mié 28 oct · 6:30 p. m. · 90 min     │   │ └───────────┘  └──────────┘ │
   │ └─────┘ ‹Finalizada›                         │   │ Hora de Colombia             │
   │         meet.bytracking.net/reunion/x9y8z7 │   │ Duración estimada (minutos)  │
   │                    [ Moderar ] ( Ver QR ) ⋯  │   │ ┌──────────────────────────┐ │
   │ ──────────────────────────────────────────── │   │ │ 60                       │ │
   │   … hasta 50 reuniones …                     │   │ └──────────────────────────┘ │
   └──────────────────────────────────────────────┘   │ El acceso se cierra 30 min   │
                                                      │ después del fin previsto:    │
          columna izquierda: 1fr                      │ pon una duración holgada.    │
                                                      │                              │
                                                      │ [Crear reunión y generar QR] │
                                                      └──────────────────────────────┘
                                                        columna derecha: 360 px, fija
                                                        (sticky) al hacer scroll
```

Detalle de una fila de la lista (`.list__item`):

| Zona | Contenido | Estilo |
|---|---|---|
| leading | Baldosa de fecha 56×56: "NOV" + "3" | fondo `‹accent-soft›`, mes 12 px/700 azul, día 25 px/700 |
| content · título | "Asamblea ordinaria noviembre" | 20 px/600, una línea con "…" |
| content · meta | "mar 3 nov · 7:00 p. m. · 60 min" | 14 px gris, cifras tabulares |
| content · estado | `‹Próxima›` azul / `‹● En curso›` verde (punto) / `‹Finalizada›` gris | badge 12 px |
| content · link | `meet.bytracking.net/reunion/ab12cd` | mono 12 px gris, con "…" |
| trailing | `[ Moderar ]` (primario pequeño) · `( Ver QR )` (secundario) · `⋯` | 32 px en escritorio, 44 px táctil |

Menú `⋯` de una reunión:

```
                         ┌───────────────────────────────┐
                         │ Página pública           ↗    │
                         │ Entrar como administrador ↗   │
                         │ ───────────────────────────── │
                         │ Eliminar                      │  ← texto rojo ‹danger›
                         └───────────────────────────────┘
```

Diálogo al pulsar "Eliminar":

```
                ┌──────────────────────────────────────────┐   radio 20, sombra 3,
                │  ¿Eliminar esta reunión?          20/600 │   fondo oscurecido detrás
                │                                          │
                │  «Asamblea ordinaria noviembre». El link │
                │  y el QR dejarán de funcionar.           │
                │                                          │
                │                ( Cancelar )  [Eliminar]  │  ← Eliminar en rojo relleno;
                └──────────────────────────────────────────┘    foco inicial en Cancelar
```

Estado vacío (sin reuniones), en la columna izquierda:

```
   ┌──────────────────────────────────────────────┐
   │                   ( 📅 )                      │   icono SVG gris en círculo 64 px
   │            Aún no hay reuniones              │   20/600
   │       Crea la primera con el formulario.     │   gris
   └──────────────────────────────────────────────┘
```

### Móvil (360 px): una columna, lista primero

```
┌────────────────────────────────┐
│ ◭ Cerro Azul               ⋯   │
├────────────────────────────────┤
│ Reuniones                      │  25 px
│ Sesión iniciada como Hguaza76  │
│ [      + Nueva reunión      ]  │  ancla a #nueva (baja al formulario)
│                                │
│ ┌────────────────────────────┐ │
│ │┌───┐ Asamblea ordinaria n… │ │
│ ││NOV│ mar 3 nov · 7:00 p. m.│ │
│ ││ 3 │ ‹● Próxima›           │ │
│ │└───┘ meet.urbcerro…/ab12cd │ │
│ │ [  Moderar  ] ( Ver QR ) ⋯ │ │  acciones debajo, 44 px
│ │────────────────────────────│ │
│ │┌───┐ Reunión consejo…      │ │
│ ││OCT│ …                     │ │
│ └────────────────────────────┘ │
│                                │
│ ┌────────────────────────────┐ │  id="nueva"
│ │ Nueva reunión              │ │
│ │ Título                     │ │
│ │ ┌────────────────────────┐ │ │
│ │ └────────────────────────┘ │ │
│ │ …(fecha y hora apiladas)…  │ │
│ │ [Crear reunión y generar QR]│ │
│ └────────────────────────────┘ │
└────────────────────────────────┘
```

---

## M3. Reunión creada / Ver QR (`/admin/qr/<id>`)

**Intención:** el QR es el protagonista; todo lo demás, a un lado.

### Escritorio (≥ 768 px)

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  ◭ Cerro Azul  Reuniones                                                          ⋯  │
└──────────────────────────────────────────────────────────────────────────────────────┘

   (✓)  REUNIÓN CREADA                                   círculo verde tenue; eyebrow verde
   Asamblea ordinaria noviembre                          31 px / 700
   Comparte este link o el QR con los participantes. La sala se crea sola cuando entren.

   ┌────────────────────────────────┐      Detalles
   │                                │      ─────────────────────────────────────────
   │   ██▀▀▀▀██  ▄▄ ▀▄  ██▀▀▀▀██    │      Fecha       mar 3 nov 2026 · 7:00 p. m.
   │   ██ ██ ██  ▀▄▀▄█  ██ ██ ██    │      Duración    60 min
   │   ██▄▄▄▄██  █ ▄ █  ██▄▄▄▄██    │      Sala        `asamblea-3f9c0a1b2d4e5f60`
   │   ▄▄▄ ▄▄▄▄▀▄█▀▄ ▀▄▄ ▄▄▄ ▄▄    │
   │   ▀█▄▀ ▄▀ ▄██▀ ▄▀█▄ ▀▄▄▀▀█    │      Link directo
   │   ██▀▀▀▀██ ▄▀ █▄▀  ▄▀▄ █▀ ▄    │      ┌──────────────────────────────────────┐
   │   ██ ██ ██ █▀▄▄ ▀█▄▀▄ ▄▀█▀    │      │ https://meet.bytracking.net/reun…  │ mono,
   │   ██▄▄▄▄██ ▄█ ▀▄ █▀ ▀▄█ ▄█    │      └──────────────────────────────────────┘ solo lectura;
   │                                │      Toca el link para seleccionarlo.          clic = seleccionar
   │  Escanéalo con la cámara       │
   └────────────────────────────────┘      [ Probar como participante ↗ ] ( Volver al panel )
     tarjeta BLANCA siempre (también
     en modo oscuro), radio 20,            ┌──────────────────────────────────────┐
     QR a 280 px, nítido (pixelated)       │ ⓘ Consejo: envía el QR por WhatsApp  │ alert--info
                                           │   con un mensaje como «Te esperamos  │
                                           │   el martes a las 7 p. m. Escanea el │
                                           │   QR o toca el link para entrar».    │
                                           └──────────────────────────────────────┘
```

### Móvil (360 px)

```
┌────────────────────────────────┐
│ ◭ Cerro Azul               ⋯   │
├────────────────────────────────┤
│ (✓) REUNIÓN CREADA             │
│ Asamblea ordinaria noviembre   │
│ Comparte este link o el QR…    │
│ ┌────────────────────────────┐ │
│ │        ██▀▀ QR ▀▀██        │ │  QR a ancho completo (máx. 280)
│ │        ██▄▄    ▄▄██        │ │
│ └────────────────────────────┘ │
│ Detalles (Fecha / Duración /   │
│ Sala)                          │
│ Link directo [campo]           │
│ [ Probar como participante ]   │  botones a ancho completo, apilados
│ (     Volver al panel      )   │
│ ⓘ Consejo: …                   │
└────────────────────────────────┘
```

Impresión (`@media print`): solo título, fecha y la tarjeta del QR, centrados en la hoja (para pegar en la cartelera del conjunto).

---

## M4. Página pública del residente (`/reunion/<slug>`) — móvil primero

**Intención:** que un residente de cualquier edad, desde el celular, entienda en 3 segundos dónde está, cuándo es, y pulse un botón grande.

### Móvil (360 px) — diseño de referencia

```
┌────────────────────────────────┐
│░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│  banda con degradado azul→índigo, 160 px
│░░   ◭ Cerro Azul            ░░░│  marca en blanco, 16 px / 600
│░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│
│░░┌──────────────────────────┐░░│  tarjeta superpuesta (sube 48 px sobre la banda)
│  │ ESTÁS INVITADO           │  │  eyebrow 12 px gris
│  │ Asamblea ordinaria       │  │  25 px / 700, hasta 3 líneas
│  │ noviembre                │  │
│  │                          │  │
│  │ 📅 mar 3 nov · 7:00 p. m.│  │  "chips" 14 px con icono SVG
│  │ ⏱ 60 minutos             │  │
│  │                          │  │
│  │ Orden del día: 1. Verifi-│  │  descripción (D2), 16 px, gris oscuro;
│  │ cación del quórum…       │  │  solo si existe
│  │                          │  │
│  │ ┌──────────────────────┐ │  │  alert--info (azul tenue)
│  │ │ⓘ Entrarás con micró- │ │  │
│  │ │ fono y cámara apaga- │ │  │
│  │ │ dos. Para hablar, le-│ │  │
│  │ │ vanta la mano ✋ y la │ │  │
│  │ │ administración te da-│ │  │
│  │ │ rá la palabra.       │ │  │
│  │ └──────────────────────┘ │  │
│  │                          │  │
│  │ Apartamento   Opcional   │  │
│  │ ┌──────────────────────┐ │  │  16 px: sin zoom al enfocar
│  │ │ 302 o T2-302         │ │  │
│  │ └──────────────────────┘ │  │
│  │ Tu nombre                │  │
│  │ ┌──────────────────────┐ │  │  autocompleta el nombre; teclado con "Ir"
│  │ │ Cómo te identificarán│ │  │
│  │ └──────────────────────┘ │  │
│  │                          │  │
│  │ [ Entrar a la reunión  ] │  │  52 px, ancho completo, 16 px / 600
│  │   Entras como asistente  │  │  12 px gris (marcador {{rol}})
│  └──────────────────────────┘  │
│                                │
│ Cerro Azul · Apariencia: Auto ◐│
└────────────────────────────────┘
```

- Al pulsar el botón: giro + deshabilitado (un segundo toque no genera otro acceso).
- En modo oscuro: banda con el degradado oscuro, tarjeta `#1C1C1E`, fondo negro.

### Tablet/escritorio (≥ 768 px)

Igual, centrado en 440 px de ancho; la banda de degradado ocupa todo el ancho de la ventana (200 px de alto) y la tarjeta se superpone en el centro.

### Estados de error (misma estructura de banda + tarjeta, con `‹empty›` dentro)

```
  Reunión no encontrada (404)              Reunión finalizada (410)
  ┌──────────────────────────┐             ┌──────────────────────────┐
  │          ( ? )           │             │          ( ⏱ )           │
  │  Reunión no encontrada   │             │   Reunión finalizada     │
  │  Verifica el link o      │             │  El acceso a «Asamblea…» │
  │  contacta a la adminis-  │             │  se cerró 30 minutos     │
  │  tración.                │             │  después del fin previs- │
  │                          │             │  to. Contacta a la ad-   │
  └──────────────────────────┘             │  ministración.           │
                                           └──────────────────────────┘
```

---

## M5. Sala de moderación (`/admin/reunion/<id>/sala`)

**Intención:** en plena asamblea, el administrador ve el video y, a la derecha, **quién pide la palabra** y los controles agrupados por lo que hacen. Nada técnico a la vista salvo que se pida.

### Escritorio (1280 px y más): video | panel lateral (360 px)

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│  ◭ Cerro Azul  Reuniones                                                              ⋯  │
└──────────────────────────────────────────────────────────────────────────────────────────┘
  ● MODERACIÓN EN VIVO                       (punto rojo con pulso suave; sin pulso si reduced-motion)
  Asamblea ordinaria noviembre                                         25 px / 700
  Sala `asamblea-3f9c…` · meet.bytracking.net                        14 px gris
  ▸ ¿Cómo funciona la moderación?                                      (desplegable cerrado)

  ┌─────────────────────────────────────────────────────┐  ┌──────────────────────────────┐
  │                                                     │  │ Estado                       │
  │                                                     │  │ Audio ‹ACTIVA›  Video ‹ACTIVA›│
  │                                                     │  └──────────────────────────────┘
  │                                                     │  ┌──────────────────────────────┐
  │                 #jitsi  (iframe)                    │  │ Toda la sala      (.gl)      │
  │                 560 px de alto                      │  │ PALABRA                      │
  │                 radio 14, fondo negro,              │  │ {Dar a todos} {Quitar a todos}│ verde | rojo tenue
  │                 sombra 2                            │  │ SILENCIAR                    │
  │                                                     │  │ {Silenciar a todos}{Apagar   │ rojo tenue ambos
  │                                                     │  │                     cámaras} │
  │                                                     │  │ MODERACIÓN A/V               │
  │                                                     │  │ ( Activar )  ( Desactivar )  │ gris | gris texto rojo
  │                                                     │  │ "Pedir la palabra" es una    │
  │                                                     │  │ petición: el asistente…      │ 12 px gris
  └─────────────────────────────────────────────────────┘  └──────────────────────────────┘
                                                           ┌──────────────────────────────┐
                                                           │ Participantes  ‹(3)›         │ #cnt
                                                           │ Mano levantada primero.      │
                                                           │ ┌──────────────────────────┐ │
                                                           │ ┃ ‹[mano]› Apto 302 - Ana  │ │ ← fondo ámbar tenue +
                                                           │ ┃ {Pedir la palabra}       │ │   barra ámbar 3 px
                                                           │ ┃ {Silenciar} (Habilitar   │ │
                                                           │ ┃ cámara) {Apagar cámara}  │ │
                                                           │ └──────────────────────────┘ │
                                                           │ ┌──────────────────────────┐ │
                                                           │ │ Apto 504 - Luis          │ │ ← fondo surface-2
                                                           │ │ {Pedir la palabra} …     │ │
                                                           │ └──────────────────────────┘ │
                                                           │  (lista con scroll propio,   │
                                                           │   máx. 50 % de la pantalla)  │
                                                           └──────────────────────────────┘
                                                           ┌──────────────────────────────┐
                                                           │ ▸ Registro técnico           │ <details> con #log
                                                           └──────────────────────────────┘
```

Botones por participante (los crea el JS; solo cambia su aspecto):

| Botón (texto del JS) | Clase que pone el JS | Aspecto |
|---|---|---|
| Pedir la palabra | `ok2` | `{ }` verde tenue |
| Silenciar | `d` | `{ }` rojo tenue |
| Habilitar cámara | (vacía) | `( )` gris |
| Apagar cámara | `d` | `{ }` rojo tenue |

Antes de conectar, `#lista` muestra 3 filas de esqueleto:

```
  │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │   brillo que recorre la fila (estático con reduced-motion)
  │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
  │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │
```

Sin participantes (el JS escribe "Nadie más en la sala."): texto centrado gris con más aire, estilo `‹empty›`.

### Tablet (768 px) y móvil (360 px): una columna

```
┌────────────────────────────────┐
│ ◭ Cerro Azul               ⋯   │
├────────────────────────────────┤
│ ● MODERACIÓN EN VIVO           │
│ Asamblea ordinaria noviembre   │
│ ▸ ¿Cómo funciona…?             │
│ ┌────────────────────────────┐ │
│ │                            │ │
│ │     #jitsi (560 px alto,   │ │  ancho completo
│ │     ancho completo)        │ │
│ │                            │ │
│ └────────────────────────────┘ │
│ Estado: Audio ‹ACTIVA› Video…  │
│ Toda la sala                   │
│ {Dar a todos } {Quitar a todos}│  2 por fila, 44 px
│ {Silenciar a.} {Apagar cámaras}│
│ ( Activar )    ( Desactivar )  │
│ Participantes ‹(3)›            │
│ ┃ [mano] Apto 302 - Ana        │
│ ┃ {Pedir la palabra}{Silenciar}│  botones 44 px, se ajustan
│ ┃ (Habilitar cámara){Apagar c.}│
│ ▸ Registro técnico             │
└────────────────────────────────┘
```

---

## M6. Resumen de pantallas y su `kind` / `width`

| Pantalla | Ruta | `kind` | `width` | Cabecera | Pie | Fondo |
|---|---|---|---|---|---|---|
| Login | `/admin/login` | `auth` | `narrow` | no | sí | aurora |
| Panel | `/admin` | `admin` | `content` | sí | no | `‹bg›` |
| QR | `/admin/qr/<id>` | `admin` | `content` | sí | no | `‹bg›` |
| Sala | `/admin/reunion/<id>/sala` | `admin` | `wide` | sí | no | `‹bg›` |
| Reunión pública | `/reunion/<slug>` | `public` | `narrow` | no (banda de marca) | sí | banda + `‹bg›` |
| No encontrada (404) | `/reunion/<slug>` | `public` | `narrow` | no (banda) | sí | banda + `‹bg›` |
| Finalizada (410) | `/unirse`, `/sala`, `/entrar` | `public` | `narrow` | no (banda) | sí | banda + `‹bg›` |

## M7. Qué aprobar de estos mockups

1. Orden del panel: **lista primero**, formulario a la derecha (escritorio) / debajo (móvil).
2. Acciones por reunión: "Moderar" + "Ver QR" visibles; el resto en `⋯` (incluido Eliminar, con diálogo).
3. Baldosa de fecha y etiqueta de estado (dependen de D1 y D3).
4. Página del residente con banda de degradado y tarjeta superpuesta.
5. Sala: controles globales reagrupados en Palabra / Silenciar / Moderación A/V; explicación y registro plegados.
6. Fondo "aurora" en el login y degradado azul→índigo como sello de marca.
