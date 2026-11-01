# SPEC-GRABACION — Mockups (wireframes ASCII)

Complemento de [`SPEC-GRABACION.md`](SPEC-GRABACION.md). Usa los componentes y tokens existentes de `theme.css` (tarjeta `.card.sala__card`, botones `.btn--*`, avisos `.alert--*`, `<dialog class="dialog">`, `.live-dot`, `.badge`). Sin componentes nuevos salvo el vúmetro (5 barras con `--color-*`) y la franja `.grab-aviso`.

Leyenda: `[ Botón ]` primario · `( Botón )` secundario · `{! … }` aviso · `●` punto rojo pulsante · `▮▯` vúmetro.

---

## M0. Disposición de la sala (≥ 1024 px) con la grabación

Lo que cambia respecto a la sala actual: (1) la tarjeta **Grabación** pasa a ser la primera del lateral; (2) `#jitsi` queda dentro de `.grab-zona`, que lleva encima la franja legal, visible **solo mientras se graba**. Lo que se graba es `.grab-zona` (recorte, §4.1); el lateral no.

```
┌─ appbar ─────────────────────────────────────────────────────────────────────────┐
│ ▲ Cerro Azul  Reuniones                                                    (⋯)   │
└──────────────────────────────────────────────────────────────────────────────────┘
  ● MODERACIÓN EN VIVO                       ← al grabar: "● GRABANDO · MODERACIÓN EN VIVO"
  Asamblea Ordinaria 2026
  Sala ca-3f9a… · meet.urbcerroazul.com
  ▸ ¿Cómo funciona la moderación?

┌─ .grab-zona (sticky) ─── ZONA GRABADA ─────────────┐  ┌─ .sala__lado ─────────────┐
│ (franja legal M4, solo al grabar)                  │  │ ┌ Grabación (M1/M3) ────┐ │
│ ┌─ #jitsi ───────────────────────────────────────┐ │  │ └───────────────────────┘ │
│ │                                                │ │  │ ┌ Estado moderación ────┐ │
│ │            iframe de Jitsi (560 px)            │ │  │ └───────────────────────┘ │
│ │                                                │ │  │ ┌ Toda la sala (.gl) ───┐ │
│ │                                                │ │  │ └───────────────────────┘ │
│ └────────────────────────────────────────────────┘ │  │ ┌ Participantes ────────┐ │
└────────────────────────────────────────────────────┘  │ └───────────────────────┘ │
                                                        │ ▸ Registro técnico        │
                                                        └───────────────────────────┘
```

---

## M1. Tarjeta "Grabación" — estados antes de grabar

**M1a · Lista para grabar (Chrome de escritorio)**
```
┌ Grabación ──────────────────────────────┐
│ La grabación se guarda en este          │
│ computador. No se sube al servidor.     │
│                                         │
│ [ ● Grabar esta reunión               ] │  ← .btn--primary, ancho completo
│                                         │
│ ≈ 0,5 GB por hora · espacio libre ≈ 38 h│  ← .field__hint
└─────────────────────────────────────────┘
```

**M1b · Móvil o tablet**
```
┌ Grabación ──────────────────────────────┐
│ {! ⚠ La asamblea NO se está grabando.   │  ← .alert--warn, siempre visible
│    La grabación solo funciona en un     │
│    computador con Chrome (macOS o       │
│    Windows). Desde aquí puedes moderar. │
│  }                                      │
│ ( Grabar esta reunión )   [deshabilitado]│
└─────────────────────────────────────────┘
```

**M1c · Safari / Firefox**
```
┌ Grabación ──────────────────────────────┐
│ {! ⓘ Para grabar, abre esta página en   │  ← .alert--info
│    Google Chrome. Este navegador no     │
│    puede grabar el sonido de la reunión.│
│  }                                      │
│ ( Grabar esta reunión )   [deshabilitado]│
└─────────────────────────────────────────┘
```

**M1d · Hay una grabación anterior sin terminar (recuperación)**
```
┌ Grabación ──────────────────────────────┐
│ {! ⚠ Hay una grabación que no se guardó │
│    Asamblea-ordinaria-2026-2026-11-15-  │
│    0905.webm · 1 h 12 min · 540 MB      │
│    [ Descargar ]  ( Descartar )         │
│  }                                      │
│ [ ● Grabar esta reunión               ] │
└─────────────────────────────────────────┘
```

---

## M2. Diálogo de instrucciones (antes del diálogo de Chrome)

Texto definitivo después del paso 0 (capturas reales de Chrome en español). Se muestra la variante con selector clásico; la del diálogo simplificado cambia solo el punto 1.

```
╔═ Antes de grabar ══════════════════════════════════════════╗
║                                                            ║
║  Chrome te va a preguntar qué compartir.                   ║
║  Para que la grabación tenga sonido:                       ║
║                                                            ║
║   ①  Elige «Pestaña de Chrome» → la pestaña               ║
║       «Moderación · Asamblea Ordinaria 2026».              ║
║                                                            ║
║   ②  Marca «Compartir también el audio de la pestaña».    ║
║       ┌──────────────────────────────────────────────┐     ║
║       │ ☑ Compartir también el audio de la pestaña   │     ║  ← mini-captura / dibujo
║       └──────────────────────────────────────────────┘     ║
║       Sin esto la grabación sale SIN VOZ.                  ║  ← --danger, negrita
║                                                            ║
║   ③  Pulsa «Compartir».                                   ║
║                                                            ║
║  Después comprobaremos el sonido (oirás un bip corto).     ║
║  Usa auriculares para que no haya eco.                     ║
║                                                            ║
║  ☐ No volver a mostrar estas instrucciones                 ║
║                                                            ║
║                          ( Cancelar )   [ Continuar ]      ║
╚════════════════════════════════════════════════════════════╝
```

---

## M2b. Comprobación automática (tras "Compartir")

**Comprobando (≈ 3 s)**
```
┌ Grabación ──────────────────────────────┐
│ Comprobando…                            │
│  ✓ Pestaña correcta                     │
│  ✓ Audio de la pestaña                  │
│  ◌ Sonido (bip)…        ▮▮▮▯▯           │
│  ◌ Tu micrófono                         │
└─────────────────────────────────────────┘
```

**Error: casilla de audio sin marcar (bloquea)**
```
┌ Grabación ──────────────────────────────┐
│ {! ✕ No marcaste «Compartir audio de la │  ← .alert--danger
│    pestaña». La grabación no tendría    │
│    voz.                                 │
│  }                                      │
│ [ Volver a intentarlo ]  ( Cancelar )   │
└─────────────────────────────────────────┘
```

**Error: pestaña o ventana equivocada (bloquea)**
```
┌ Grabación ──────────────────────────────┐
│ {! ✕ Elegiste otra ventana o pestaña.   │
│    Hay que compartir ESTA pestaña       │
│    (Moderación · Asamblea…).            │
│  }                                      │
│ [ Volver a intentarlo ]  ( Cancelar )   │
└─────────────────────────────────────────┘
```

**Error: el bip no llegó (mudo)**
```
┌ Grabación ──────────────────────────────┐
│ {! ✕ La grabación no capta el sonido de │
│    la reunión. ¿Está silenciada la      │
│    pestaña o el volumen de Chrome?      │
│  }                                      │
│ [ Volver a intentarlo ]  ( Cancelar )   │
│ Grabar sin sonido                       │  ← enlace pequeño → confirmación de peligro
└─────────────────────────────────────────┘
```

**Aviso: sin micrófono (no bloquea)**
```
│ {! ⚠ Tu voz no quedará en la grabación  │  ← .alert--warn, sale ya grabando
│    (no hay acceso al micrófono).        │
│  }                                      │
```

---

## M3. Estado "grabando"

```
┌ Grabación ──────────────────────────────┐
│  ●  GRABANDO              01:23:45      │  ← .live-dot + .num (tabular)
│                                         │
│  682,4 MB  · ≈ 490 MB/hora              │  ← peso REAL escrito
│  Sonido   ▮▮▮▮▯                         │  ← vúmetro de la mezcla
│  Tu micro: en la grabación              │  ← "silenciado (no se graba)" si mute
│                                         │
│ ┌─────────────────────────────────────┐ │
│ │ Lee en voz alta al empezar:         │ │  ← solo el 1.er minuto, plegable
│ │ «Informo a los asistentes que, a    │ │
│ │ partir de este momento, la asamblea │ │
│ │ está siendo grabada…»               │ │
│ └─────────────────────────────────────┘ │
│                                         │
│ [ ■ Detener y guardar                 ] │  ← .btn--danger → confirmación
│ No cierres esta pestaña.                │  ← .field__hint
└─────────────────────────────────────────┘
```

**Recordatorio a la hora de fin prevista** (encima del botón):
```
│ {! ⓘ La asamblea debía terminar a las   │
│    11:00 a. m. ¿Sigues grabando?        │
│    [ Detener ]  ( Seguir grabando )     │
│  }                                      │
```

**Silencio prolongado (10 min)**
```
│ {! ⚠ Hace 10 min que no se graba        │
│    sonido. ¿Está hablando alguien?      │
│  }                                      │
```

**Confirmación de detener** (diálogo del sistema `theme.js`):
```
╔═ ¿Detener la grabación? ═══════════════════════╗
║ Se guardará el archivo en Descargas.           ║
║                ( Seguir grabando ) [ Detener ] ║
╚════════════════════════════════════════════════╝
```

**M3b · Guardado**
```
┌ Grabación ──────────────────────────────┐
│ ✓ Grabación guardada en Descargas       │
│   Asamblea-ordinaria-2026-2026-11-15-   │
│   0905.webm                             │
│   3 h 41 min · 1,82 GB                  │
│                                         │
│ ( Volver a descargar )                  │
│ ( Ya lo tengo guardado, borrar copia )  │
│ Copia interna: 1,82 GB                  │
│                                         │
│ ¿Necesitas MP4? Ver «Convertir»         │  ← enlace a la guía del admin
│ [ ● Grabar otra vez ]                   │
└─────────────────────────────────────────┘
```

---

## M4. Aviso legal en la sala

**M4a · Franja dentro de la zona grabada** (`.grab-aviso`, encima del iframe, solo mientras se graba). Fondo `--danger`, texto blanco, 1–2 líneas. **Sale en cada fotograma del archivo.**

```
┌─ .grab-zona ───────────────────────────────────────────────────────┐
│█ ● ESTA ASAMBLEA SE ESTÁ GRABANDO (audio y video) · Soporte del   █│
│█   acta, Ley 675 de 2001 · Datos tratados según Ley 1581 de 2012  █│
│ ┌─ #jitsi ───────────────────────────────────────────────────────┐ │
│ │ ● GRABANDO · Asamblea Ordinaria 2026            00:41  👥 37   │ │  ← subject (M4b)
│ │                                                                │ │
│ │                    [ video del ponente ]                       │ │
│ │                                                                │ │
│ │   🎤  📷  🖥  👥  ✋  💬  ⊞  ⚙  ☎                                │ │
│ └────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

**M4b · Lo que ve CADA asistente en su Jitsi** (móvil o PC; `subject` de la conferencia, también para quien entra tarde o desde votacionph.us):

```
┌──────────────────────────────────┐
│ ● GRABANDO · Asamblea Ordinaria  │  ← cabecera de Jitsi (subject)
│                                  │
│      [ video del ponente ]       │
│                                  │
│ 💬 Administración (09:05):       │  ← en el panel de chat (no emergente)
│   Esta asamblea se está grabando │
│   (audio y video). La adminis-   │
│   tración del Conjunto Cerro     │
│   Azul la graba como soporte del │
│   acta (Ley 675 de 2001)…        │
│                                  │
│   🎤   ✋   💬   ⚙   ☎             │
└──────────────────────────────────┘
```

**M4c · (opcional, Q7) Página pública `/reunion/<slug>` antes de entrar**
```
  Asamblea Ordinaria 2026
  Sáb 15 nov · 9:00 a. m.
  [ Tu nombre                  ]
  [        Entrar              ]
  ⓘ Esta reunión puede ser grabada como soporte del acta.   ← .field__hint
```
