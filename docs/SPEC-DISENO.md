# SPEC-DISENO — Rediseño visual del panel de Cerro Azul Jitsi

> Estado: **borrador para aprobar** (Fase 0, 2026-11-01). No hay código implementado.
> Acompaña a [`SPEC-DISENO-mockups.md`](SPEC-DISENO-mockups.md), que describe cada pantalla.
> Alcance: solo la **capa visual** del panel Flask (`admin-panel/`). No cambia rutas, códigos HTTP,
> cabeceras, nombres de campos, CSRF, tokens JWT ni la lógica JS de moderación.

---

## 0. Hallazgos del código que condicionan el enfoque

Leí `app.py` y las seis plantillas antes de diseñar. Hay cosas que **cambian el enfoque** respecto a
lo que se esperaría de "un panel Flask con plantillas Jinja":

| # | Hallazgo (con ubicación) | Consecuencia para el rediseño |
|---|---|---|
| H1 | **Las páginas no son plantillas Jinja.** `app.py` lee `page_*.html` como texto, sustituye marcadores con `str.replace` (`{{titulo}}`, `{{csrf}}`, `<!--ERR-->`, `<!--LISTA-->`, `<!--AVISO_JWT-->`) y lo inyecta en `tpl.html` con `{{ body\|safe }}`. Solo `tpl.html` pasa por Jinja (`render_template_string`, variables `t` y `body`). | En `page_*.html` **no** se puede usar `{% if %}`, `{% include %}` ni herencia. Toda lógica de layout (cabecera, ancho) vive en `tpl.html` y se controla con variables nuevas que pasa `app.py`. Los marcadores `{{x}}` y `<!--X-->` de cada página son **contrato**: no se renombran ni se borran. |
| H2 | **Parte del HTML se genera en Python**: la lista de reuniones (`listar_reuniones`, `app.py:341-372`), el error de login (`app.py:314`), el aviso JWT (`app.py:336`), "Reunión no encontrada" (`app.py:441`) y "Reunión finalizada" (`pagina_finalizada`, `app.py:454-458`). | El rediseño **toca `app.py`**, pero solo en cadenas de HTML. Es imposible dejar la lista de reuniones bonita sin editar esas cadenas. |
| H3 | **`/static/*` no llega al panel.** El bloque Caddy (`infra/caddy/meet.bytracking.net.caddy:26`) solo envía al panel `/admin* /reunion/* /unirse /healthz /api/reuniones/*`; todo lo demás va al contenedor `web` de Jitsi, que **ya usa `/static/`** para sus propios ficheros. | El CSS no puede servirse en la ruta por defecto de Flask (`/static`). Se sirve en **`/admin/static/`** (`Flask(__name__, static_url_path="/admin/static")`). `/admin*` ya está enrutado: **no hace falta tocar Caddy**. Las páginas públicas (`/reunion/...`) también lo cargan desde `/admin/static/` (Flask no exige login para estáticos). |
| H4 | **El Dockerfile copia fichero a fichero** (`COPY app/tpl.html ...`), y `app.py` va dentro de la imagen. | Hay que añadir `COPY app/static /app/static`. Cualquier cambio exige `docker compose build admin` + `up -d --force-recreate admin` (no basta con copiar ficheros al VPS). |
| H5 | **`page_sala.html` tiene un contrato JS** (sección 6.2): `#jitsi`, `#lista`, `#cnt`, `#log`, `#st-audio`, `#st-video`, `.gl button[data-cmd]`, y el JS **crea nodos con clases fijas**: `div.p`, `div.n`, `span.mano`, `p.m`, y botones con clase `ok2`, `d` o vacía. | Esas clases **no pueden desaparecer del CSS**: quedan como "clases de contrato" permanentes, estilizadas con el sistema nuevo. El texto `"[mano] "` lo escribe el JS: no se puede cambiar por un icono sin tocar JS (se estiliza como etiqueta). El color de `#st-audio`/`#st-video` según su valor (`ACTIVA`/`apagada`) tampoco: CSS no puede leer texto. |
| H6 | **El iframe de Jitsi recibe `height: 560`** desde el JS (`new JitsiMeetExternalAPI(..., {height: 560})`), que el API aplica como estilo en línea. | Se mantiene 560 px de alto. Hacerlo fluido exigiría `!important` contra un estilo en línea del API: se descarta por frágil. |
| H7 | **Bug visible: fecha duplicada.** `fecha_utc` ya termina en `" UTC"` y `listar_reuniones` le añade otro `" UTC"` (`app.py:359`) → la lista muestra `2026-11-04 00:00 UTC UTC`. | Se corrige de paso al reescribir esa cadena (es presentación). |
| H8 | **Bug: la descripción nunca se muestra al residente.** `page_reunion.html` tiene `<!--DESC-->`, pero `app.py:450` reemplaza `{{descripcion}}`, que no existe en la plantilla. El comentario llega tal cual al navegador. | Decisión **D2** (sección 9): propongo arreglarlo en un paso propio. |
| H9 | **El residente ve la hora en UTC.** Una asamblea creada para el martes a las 19:00 (Colombia) se guarda como `miércoles 00:00 UTC` y así se le muestra al residente (`page_reunion.html`, `page_qr_view.html`, lista). Para una persona no técnica, eso es la fecha **equivocada**. | Decisión **D1**: mostrar hora de Colombia (solo presentación; la BD sigue en UTC). La "baldosa de calendario" del diseño depende de esto. |
| H10 | **El formulario de login no tiene `action`.** Publica a la misma URL, conservando `?next=`. | No añadir `action` al `<form>` del login. |
| H11 | **Eliminar usa `onclick="return confirm(...)"`** en una cadena de Python (`app.py:368`). | Se conserva como respaldo sin JS; el diálogo bonito lo pone `theme.js` encima (sección 3.4.10). |
| H12 | `loadtest/verificar-panel.py` (sin versionar) existe para comparar antes/después, pero solo mira `/admin/login` y `/healthz` sin sesión, y su regex del CSRF (`name="csrf"` con comillas) **no detecta** el CSRF de la lista (`name=csrf` sin comillas). | Sirve como mínimo, pero no basta. Sección 6.4 especifica una verificación con sesión iniciada contra un contenedor local. |
| H13 | El CSP aplicado es solo `frame-ancestors 'none'` (y aún no está en el Caddyfile del VPS, ver `docs/` / memoria de despliegue). No restringe `style-src` ni `script-src`. | Los estilos y el JS van igualmente en ficheros propios (`'self'`), para que un CSP más estricto en el futuro no rompa nada. Se permite **un solo** `<script>` en línea en la sala (el que ya existe). |

---

## 1. Diagnóstico del estado actual

### 1.1 Problemas transversales

- **No hay sistema.** Las variables de `tpl.html` son de una letra (`--c`, `--b`, `--t`, `--m`, `--a`, `--h`, `--ok`, `--er`) y las clases también (`.c`, `.m`, `.r`, `.mt`, `.ac`, `.b`, `.e`, `.o`, `.d`). Nadie puede saber qué es `.o` sin leer el CSS. Además `page_sala.html` añade otro `<style>` dentro del `<body>` y otro color suelto (`#facc15`), y `page_qr_view.html` usa estilos en línea que duplican el botón (`style="background:var(--a); ... padding:9px 18px"`).
- **Solo modo oscuro, fijo.** Fondo `#0f172a` siempre. Un residente que abre el QR al sol, con el móvil en modo claro, recibe una pantalla azul marino. No hay `color-scheme`, ni `prefers-color-scheme`, ni conmutador.
- **Contraste insuficiente en botones** (texto blanco 14 px, AA pide 4.5:1):

  | Elemento | Colores | Ratio | AA texto normal |
  |---|---|---|---|
  | Botón primario | `#fff` / `#3b82f6` | **3.68** | ✗ |
  | Botón peligro (`.d`) | `#fff` / `#ef4444` | **3.76** | ✗ |
  | Badge éxito (`.b`), botón `.ok2` de la sala | `#fff` / `#10b981` | **2.54** | ✗ |
  | Borde de campo (`--b`) sobre tarjeta | `#334155` / `#1e293b` | **1.41** | ✗ (no-texto pide 3:1) |
  | Texto atenuado (`--m`) sobre tarjeta | `#94a3b8` / `#1e293b` | 5.71 | ✓ |

- **Foco invisible.** `tpl.html` hace `input:focus { outline:none; border-color:var(--a) }`: el único indicio de foco es un borde que pasa de 1.41:1 a 3.98:1. Los botones y enlaces no tienen estilo de foco propio. Con teclado no se sabe dónde se está.
- **Tamaños.** Hay texto de 11 px (`small`, `.b`, `#log`) y 12 px (acciones de la lista, botones de la sala). Los botones de acción miden ≈ 24-26 px de alto (`padding:5px 10px; font-size:12px`), muy por debajo de los 44 px táctiles. Los campos usan `font-size:14px`, y **iOS Safari hace zoom al enfocar un campo de menos de 16 px**: en el formulario del residente la página salta al tocar "Tu nombre".
- **Tipografía.** `system-ui, sans-serif` sin escala: tamaños sueltos 11/12/13/14/15/16/22 px, sin alturas de línea definidas, sin pesos con intención (todo es 400 salvo `<b>` sueltos).
- **Jerarquía por cajas y bordes.** Todo es una tarjeta con borde dentro de otra tarjeta con borde (`.c` > `.r`), y la importancia se marca con rojo/azul en vez de con tamaño y peso. Cinco acciones con el mismo peso visual en cada reunión.
- **Sin estados.** No hay hover distinguible en enlaces de acción, ni `disabled`, ni estado de carga al enviar (el botón "Entrar a la reunión" puede pulsarse dos veces y emitir dos tokens), ni estado vacío diseñado.
- **Sin estructura semántica.** No hay `<header>`, `<main>`, `<nav>`; las etiquetas `<label>` no están asociadas a sus campos (sin `for`/`id`), así que tocar la etiqueta no enfoca el campo y los lectores de pantalla no anuncian el nombre del campo. Sin `autocomplete` en el login. Títulos de pestaña genéricos ("Panel", "Login").
- **Responsive accidental.** Todo cabe en una tarjeta de 640 px centrada verticalmente (`body{display:flex; align-items:center}`): en pantallas bajas o con la lista larga, el centrado vertical empuja contenido; en escritorio se desperdicia el ancho. La sala usa `flex-wrap` sin puntos de corte pensados.
- **Ortografía sin tildes** ("Reunion", "Contrasena", "Sesion", "Moderacion"). Para un producto que ven residentes, transmite descuido (decisión **D4**).

### 1.2 Por página

| Página | Qué se ve hoy | Problema principal |
|---|---|---|
| `page_login.html` (312 B) | Un `<h1>`, una línea gris, dos campos y un botón azul en una caja oscura. | No hay marca ni contexto: no parece "el panel de Cerro Azul", parece un formulario genérico. Etiquetas sin asociar, sin `autocomplete`, foco invisible. El error es texto rojo `#ef4444` sobre un rojo translúcido. |
| `page_panel.html` (1210 B) + `listar_reuniones` | Formulario de crear arriba; debajo, la lista (generada en Python); al final un botón rojo "Cerrar sesión". | La pantalla más usada **empieza por el formulario**, no por las reuniones. Cada reunión muestra fecha UTC duplicada ("UTC UTC", H7), el código de sala y el link público en `<code>` (ruido técnico), y cinco acciones del mismo peso: 4 enlaces azules + un botón rojo "Eliminar" igual de prominente. "Cerrar sesión" en rojo parece una acción destructiva. |
| `page_qr_view.html` (1298 B) | Recuadro verde translúcido con los datos, el QR a 240 px, un campo con el link y dos enlaces con estilo en línea. | Funcional pero plano; el QR (lo importante) no destaca; estilos en línea duplicados; dos botones con apariencias distintas hechas a mano. |
| `page_reunion.html` (728 B) | Título, "Rol al entrar: **Asistente**", recuadro verde con fecha UTC y duración, explicación, dos campos y el botón. | La ve el **residente en el móvil**: hora UTC (H9), jerga ("Rol"), campos que provocan zoom en iOS, botón de 35 px que no ocupa el ancho, sin marca que le confirme que está en el sitio correcto, descripción perdida (H8). |
| `page_sala.html` (9764 B) | Iframe de Jitsi + columna con 6 botones globales, estado de moderación, lista de participantes con 4 botones cada uno, y un registro en monoespaciada. | Es la pantalla de más presión (asamblea en vivo) y todo tiene el mismo peso: seis botones de 12 px, la mitad rojos, sin agrupar por significado. La mano levantada es texto `[mano]` amarillo. Párrafos largos de explicación técnica siempre visibles. El registro técnico ocupa sitio fijo. |
| `tpl.html` (2587 B) | Layout único: una caja centrada de 640 px. | No distingue páginas de administrador (necesitan cabecera y menú) de páginas públicas (necesitan marca y nada más) ni páginas anchas (sala). |

---

## 2. Principios de diseño

La referencia es el lenguaje de macOS/iOS, traducido a reglas que se puedan comprobar:

1. **Claridad antes que decoración.** El contenido (reuniones, QR, participantes) es el protagonista; el "cromo" (bordes, cajas, fondos) se reduce al mínimo. *Por qué:* el administrador no es técnico y opera bajo presión durante una asamblea; cada borde extra es algo más que leer.
2. **Jerarquía por tamaño y peso, no por bordes.** Un título de página es 31 px/700; un título de tarjeta, 20 px/600; un metadato, 14 px/400 en gris. Se distinguen sin cajas. *Por qué:* es como lo hace Apple (Ajustes, Calendario), y es lo que permite quitar la "caja dentro de caja" actual.
3. **El espacio en blanco es estructura.** La separación entre grupos (24-32 px) es mayor que dentro del grupo (8-12 px), así el ojo agrupa solo (ley de proximidad). Escala fija de 4 px; nada de `margin: 10px` sueltos. *Por qué:* espacios coherentes son lo que más "calidad" transmite y lo que más falta hoy.
4. **Color con intención, no por adorno.** Un único color de acción (**azul Cerro Azul** `#0066CC`), un acento secundario (índigo `#5E5CE6`) solo para la marca/degradados, y los colores de estado (verde, ámbar, rojo) **solo** cuando significan estado. El rojo se reserva para lo destructivo; "Cerrar sesión" deja de ser rojo. *Por qué:* si todo es de color, nada destaca; el usuario pidió "colorido" y lo obtiene en la marca (degradados de login/cabecera pública, baldosas de fecha, estados), no en los botones.
5. **Una acción principal por pantalla.** Login → "Entrar"; panel → "Nueva reunión" y, por reunión, "Moderar"; QR → el propio QR; reunión pública → "Entrar a la reunión"; sala → los controles de palabra. Las acciones secundarias son botones grises o van a un menú. *Por qué:* reduce errores (p. ej. eliminar por accidente).
6. **Superficies y profundidad coherentes.** Tres niveles: fondo (`--bg`), superficie (`--surface`, tarjetas) y elevado (diálogos/menús, con sombra). Radios de esquina de una escala fija, con la regla "radio interior = radio exterior − separación" para que las esquinas anidadas sean concéntricas. *Por qué:* es la sensación "física" de Apple, con solo 3 sombras definidas.
7. **Movimiento discreto y útil.** Transiciones de 120-200 ms solo en color, sombra, opacidad y escala (presionar un botón lo encoge a 0.98). Nada de animaciones de entrada de página. Con `prefers-reduced-motion`, todo es instantáneo. *Por qué:* el movimiento confirma una acción; si decora, distrae.
8. **Móvil primero para el residente, escritorio primero para el administrador.** Las páginas públicas se diseñan para 360 px y se amplían; el panel y la sala se diseñan para 1280 px y se garantiza que funcionen a 360 px. *Por qué:* es como se usan de verdad (QR por WhatsApp vs. ordenador del administrador).
9. **Nativo y autocontenido.** Fuentes del sistema (San Francisco en Apple, Segoe en Windows, Roboto en Android), controles nativos (`<details>`, `<dialog>`, `<input type="date">`), cero dependencias. *Por qué:* restricción del proyecto (la red hacia fuera puede caer) y porque lo nativo es lo que hace que se sienta "de Apple" en un iPhone.

---

## 3. Sistema de diseño

Todo vive en `admin-panel/app/static/theme.css`. Los valores siguientes son **exactos**: el implementador los copia.

### 3.1 Tokens

#### 3.1.1 Color — modo claro (por defecto en `:root`)

Cada color de estado tiene tres variantes con roles distintos: `--x` (texto/icono sobre `--surface`), `--x-fill` (fondo sólido con texto `--on-fill`) y `--x-soft` + `--x-soft-text` (fondo tenue de avisos/etiquetas). Así nunca se usa un mismo hex para texto y para fondo con contraste distinto.

| Token | Valor | Uso |
|---|---|---|
| `--bg` | `#F5F5F7` | Fondo de página |
| `--surface` | `#FFFFFF` | Tarjetas, campos, cabecera |
| `--surface-2` | `#F0F0F3` | Hover de filas, botón secundario, pistas de esqueleto |
| `--surface-elevated` | `#FFFFFF` | Diálogos y menús (se distinguen por sombra) |
| `--border` | `#D2D2D7` | Separadores decorativos (filetes de 1 px) |
| `--border-strong` | `#86868B` | Bordes de campos de formulario (≥ 3:1) |
| `--text` | `#1D1D1F` | Texto principal |
| `--text-muted` | `#6E6E73` | Metadatos, ayudas, placeholders |
| `--accent` | `#0066CC` | Enlaces, iconos activos, anillo de foco |
| `--accent-fill` | `#0066CC` | Fondo del botón primario |
| `--accent-fill-hover` | `#005BB5` | Hover del primario |
| `--accent-fill-active` | `#004E9A` | Pulsado del primario |
| `--accent-soft` | `#E8F1FC` | Aviso info, baldosa de fecha, fila seleccionada |
| `--accent-soft-text` | `#0B5394` | Texto sobre `--accent-soft` |
| `--accent-2` | `#5E5CE6` | Índigo: solo marca y degradados |
| `--on-fill` | `#FFFFFF` | Texto sobre cualquier `*-fill` |
| `--success` | `#1A7F37` | Texto/icono de éxito |
| `--success-fill` | `#1A7F37` | Botón "Dar la palabra" |
| `--success-soft` | `#E6F4EA` | Fondo aviso/etiqueta éxito |
| `--success-soft-text` | `#14632C` | Texto sobre `--success-soft` |
| `--warn` | `#B25000` | Texto/icono de advertencia |
| `--warn-soft` | `#FFF4E5` | Fondo aviso/etiqueta advertencia, participante con mano |
| `--warn-soft-text` | `#8A3B00` | Texto sobre `--warn-soft` |
| `--danger` | `#C9190B` | Texto de botón ghost/soft peligro, errores de campo |
| `--danger-fill` | `#C9190B` | Fondo del botón de peligro |
| `--danger-fill-hover` | `#A81408` | Hover del botón de peligro |
| `--danger-soft` | `#FDECEC` | Fondo aviso/etiqueta error |
| `--danger-soft-text` | `#9F1239` | Texto sobre `--danger-soft` |
| `--focus-ring` | `#0066CC` | Contorno de foco |
| `--overlay` | `rgba(0, 0, 0, 0.40)` | Fondo detrás del diálogo |
| `--gradient-brand` | `linear-gradient(135deg, #0066CC 0%, #5E5CE6 100%)` | Marca, cabecera pública |
| `--gradient-aurora` | `radial-gradient(60% 50% at 20% 10%, rgba(0,102,204,.22), transparent 70%), radial-gradient(50% 40% at 85% 20%, rgba(94,92,230,.20), transparent 70%), radial-gradient(60% 50% at 50% 100%, rgba(48,176,199,.16), transparent 70%)` | Fondo del login |
| `--qr-bg` | `#FFFFFF` | Fondo del QR (**blanco también en oscuro**: los lectores de QR fallan con QR sobre negro) |

#### 3.1.2 Color — modo oscuro

Mismos nombres, otros valores. Se aplica con `@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { … } }` **y** con `:root[data-theme="dark"] { … }`. Los dos bloques llevan **los mismos valores** (CSS no permite unir un `@media` y un selector en una regla). Se marcan con el comentario `/* SYNC-DARK */` y la verificación (6.4) comprueba que son idénticos.

| Token | Valor | Token | Valor |
|---|---|---|---|
| `--bg` | `#000000` | `--success` | `#32D74B` |
| `--surface` | `#1C1C1E` | `--success-fill` | `#1F7A3A` |
| `--surface-2` | `#2C2C2E` | `--success-soft` | `#0E2E18` |
| `--surface-elevated` | `#2C2C2E` | `--success-soft-text` | `#8EE6A4` |
| `--border` | `#38383A` | `--warn` | `#FF9F0A` |
| `--border-strong` | `#8E8E93` | `--warn-soft` | `#3A2400` |
| `--text` | `#F5F5F7` | `--warn-soft-text` | `#FFD08A` |
| `--text-muted` | `#A1A1A6` | `--danger` | `#FF6961` |
| `--accent` | `#4DA3FF` | `--danger-fill` | `#D70015` |
| `--accent-fill` | `#0060DF` | `--danger-fill-hover` | `#B80012` |
| `--accent-fill-hover` | `#0A6CF0` | `--danger-soft` | `#3D1010` |
| `--accent-fill-active` | `#0052C2` | `--danger-soft-text` | `#FFB3B0` |
| `--accent-soft` | `#0F2A4A` | `--focus-ring` | `#4DA3FF` |
| `--accent-soft-text` | `#9CC9FF` | `--overlay` | `rgba(0, 0, 0, 0.60)` |
| `--accent-2` | `#7D7AFF` | `--gradient-brand` | `linear-gradient(135deg, #0060DF 0%, #5E5CE6 100%)` |
| `--on-fill` | `#FFFFFF` | `--qr-bg` | `#FFFFFF` |

`--gradient-aurora` en oscuro: mismas tres capas con opacidades `.35 / .30 / .20`.

*Por qué un `--accent-fill` distinto de `--accent` en oscuro:* el azul que se lee bien como texto sobre negro (`#4DA3FF`, 6.48:1) es demasiado claro para llevar texto blanco encima (≈ 2.6:1); el azul de iOS `#0A84FF` con blanco da 3.65:1 (falla AA). `#0060DF` con blanco da 5.62:1.

#### 3.1.3 Espaciado (base 4 px)

| Token | Valor | Token | Valor |
|---|---|---|---|
| `--space-0` | `0` | `--space-6` | `1.5rem` (24 px) |
| `--space-1` | `0.25rem` (4 px) | `--space-8` | `2rem` (32 px) |
| `--space-2` | `0.5rem` (8 px) | `--space-10` | `2.5rem` (40 px) |
| `--space-3` | `0.75rem` (12 px) | `--space-12` | `3rem` (48 px) |
| `--space-4` | `1rem` (16 px) | `--space-16` | `4rem` (64 px) |
| `--space-5` | `1.25rem` (20 px) | | |

Reglas: dentro de un componente 8-16 px; entre componentes de un grupo 16-24 px; entre secciones 32-48 px. Márgenes laterales de página: 16 px (< 768), 24 px (≥ 768), 32 px (≥ 1280).

#### 3.1.4 Radios

| Token | Valor | Uso |
|---|---|---|
| `--radius-sm` | `6px` | Etiquetas (badge), `<code>`, casillas |
| `--radius-md` | `10px` | Botones, campos |
| `--radius-lg` | `14px` | Tarjetas, avisos, filas de participante |
| `--radius-xl` | `20px` | Diálogos, tarjeta del login, tarjeta del QR |
| `--radius-full` | `999px` | Pastillas, avatar, conmutador |

Regla concéntrica: un elemento dentro de una tarjeta con relleno `p` usa radio `max(--radius-sm, radio_tarjeta − p)`.

#### 3.1.5 Sombras

| Token | Claro | Oscuro |
|---|---|---|
| `--shadow-1` (tarjetas) | `0 1px 2px rgba(0,0,0,.05), 0 1px 1px rgba(0,0,0,.03)` | `0 0 0 1px rgba(255,255,255,.06)` |
| `--shadow-2` (hover de tarjeta, menús, cabecera al hacer scroll) | `0 4px 12px rgba(0,0,0,.08), 0 1px 3px rgba(0,0,0,.05)` | `0 0 0 1px rgba(255,255,255,.08), 0 8px 24px rgba(0,0,0,.5)` |
| `--shadow-3` (diálogos, tarjeta del login) | `0 16px 40px rgba(0,0,0,.14), 0 2px 8px rgba(0,0,0,.06)` | `0 0 0 1px rgba(255,255,255,.10), 0 24px 56px rgba(0,0,0,.7)` |

*Por qué en oscuro la sombra es un filete:* sobre negro una sombra no se ve; Apple separa capas oscuras con superficies más claras y un borde de 1 px muy tenue.

#### 3.1.6 Tipografía

| Token | Valor |
|---|---|
| `--font-sans` | `-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", "Helvetica Neue", system-ui, "Segoe UI", Roboto, "Noto Sans", Ubuntu, Cantarell, Arial, sans-serif, "Apple Color Emoji", "Segoe UI Emoji"` |
| `--font-mono` | `ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace` |
| `--font-tabular` | `font-variant-numeric: tabular-nums` (no es variable: utilidad `.num` para horas, contador de participantes) |

`-apple-system` va primero porque en Safari/iOS selecciona San Francisco con su óptica (Text/Display) automática; `system-ui` va detrás porque en algunos Windows con idioma asiático elige una fuente CJK.

Escala modular **1.25 (tercera mayor)** con base 16 px. Tamaños en `rem` (respetan el tamaño de letra que el residente tenga configurado en el móvil):

| Token tamaño | rem / px | `--lh-*` | Peso típico | `letter-spacing` | Uso |
|---|---|---|---|---|---|
| `--text-xs` | `0.75rem` / 12 | `1rem` (16) | 500 | `0.01em` | Etiquetas, mes de la baldosa, "eyebrow" (mayúsculas) |
| `--text-sm` | `0.875rem` / 14 | `1.25rem` (20) | 400 | `0` | Metadatos, ayudas, botones pequeños |
| `--text-md` | `1rem` / 16 | `1.5rem` (24) | 400 | `0` | Cuerpo, campos, botones |
| `--text-lg` | `1.25rem` / 20 | `1.75rem` (28) | 600 | `-0.01em` | Títulos de tarjeta, `h3` |
| `--text-xl` | `1.5625rem` / 25 | `2rem` (32) | 600 | `-0.015em` | Títulos de sección, `h2` |
| `--text-2xl` | `1.9375rem` / 31 | `2.375rem` (38) | 700 | `-0.02em` | Título de página, `h1` |
| `--text-3xl` | `2.4375rem` / 39 | `2.75rem` (44) | 700 | `-0.025em` | Login/hero; día de la baldosa grande |

Pesos: `--weight-regular: 400`, `--weight-medium: 500`, `--weight-semibold: 600`, `--weight-bold: 700`. Por debajo de 768 px, `h1` baja a `--text-xl` y el hero a `--text-2xl`. **Ningún texto por debajo de 12 px** (desaparecen los 11 px actuales). **Ningún campo por debajo de 16 px** (evita el zoom de iOS).

#### 3.1.7 Movimiento

| Token | Valor | Uso |
|---|---|---|
| `--dur-fast` | `120ms` | Color/fondo de botones y enlaces, escala al pulsar |
| `--dur-base` | `200ms` | Sombra de tarjetas, apertura de menú, diálogo |
| `--dur-slow` | `320ms` | Brillo del esqueleto (por ciclo: `1200ms`) |
| `--ease-out` | `cubic-bezier(0.2, 0.8, 0.2, 1)` | Entradas |
| `--ease-in-out` | `cubic-bezier(0.4, 0, 0.2, 1)` | Cambios de estado |

#### 3.1.8 Layout

| Token | Valor | Uso |
|---|---|---|
| `--w-narrow` | `27.5rem` (440 px) | Login, reunión pública, páginas de estado |
| `--w-content` | `72rem` (1152 px) | Panel, QR |
| `--w-wide` | `90rem` (1440 px) | Sala de moderación |
| `--header-h` | `3.5rem` (56 px) | Cabecera del administrador |
| `--tap` | `2.75rem` (44 px) | Altura mínima táctil |

Puntos de corte (en `min-width`, móvil primero): **768 px** (tablet), **1024 px** (dos columnas en panel y sala), **1280 px** (márgenes amplios). CSS no permite variables en media queries: se escriben literales y se documentan en la cabecera del fichero.

### 3.2 Modo claro / oscuro y conmutador

- `:root { color-scheme: light dark; }` — los controles nativos (fecha, hora, barras de scroll) siguen el tema.
- Tres estados: **Automático** (sigue al sistema; por defecto), **Claro**, **Oscuro**. Se guarda en `localStorage` con la clave **`ca-tema`** y valores `"light"` / `"dark"`; "Automático" = clave ausente.
- `theme.js` se carga **en el `<head>`, síncrono**, y lo primero que hace es leer `ca-tema` y poner `document.documentElement.dataset.theme`. *Por qué síncrono:* si se cargara al final, la página se pintaría un instante con el tema del sistema y luego cambiaría (parpadeo). Es un fichero de < 3 KB, local, sin coste apreciable.
- `localStorage` puede lanzar excepción (Safari privado antiguo, almacenamiento bloqueado): todo acceso va en `try/catch`; si falla, se queda en Automático.
- Dos `<meta name="theme-color">`: `#F5F5F7` con `media="(prefers-color-scheme: light)"` y `#000000` con `media="(prefers-color-scheme: dark)"` (color de la barra del navegador en iOS/Android). Cuando hay tema manual, `theme.js` actualiza ambos al color del tema elegido.
- **Dónde está el conmutador:** en el menú de la cabecera del administrador (control segmentado de 3 opciones) y, en las páginas públicas, como botón discreto en el pie ("Apariencia: Automático ▾" que rota entre las tres). Es un `<button>` con `aria-label` que anuncia el estado ("Apariencia: oscuro").

### 3.3 Base (reset y elementos)

- `*, *::before, *::after { box-sizing: border-box; }`; márgenes a 0 en encabezados, `p`, listas.
- `body`: `font-family: var(--font-sans); font-size: var(--text-md); line-height: var(--lh-md); color: var(--text); background: var(--bg); -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; min-height: 100dvh;` **Sin** `display:flex; align-items:center` (se elimina el centrado vertical global).
- `a`: `color: var(--accent); text-decoration: none;` subrayado en `:hover` (`text-underline-offset: 0.2em`).
- `code`, `.mono`: `font-family: var(--font-mono); font-size: 0.875em; background: var(--surface-2); padding: 0.1em 0.4em; border-radius: var(--radius-sm);`
- `:focus-visible` global: `outline: 3px solid var(--focus-ring); outline-offset: 2px;` en campos el anillo va pegado (`outline-offset: 0`) más `box-shadow: 0 0 0 4px color-mix(in srgb, var(--focus-ring) 25%, transparent)`. **Nunca** `outline: none` sin reemplazo. (`color-mix` está en Safari ≥ 16.2, Chrome ≥ 111, Firefox ≥ 113; si no existe, queda solo el `outline`, que es suficiente.)
- `.visually-hidden` (accesible a lectores, invisible): patrón estándar `clip: rect(0 0 0 0); clip-path: inset(50%); width:1px; height:1px; overflow:hidden; position:absolute; white-space:nowrap;`
- `.skip-link`: "Saltar al contenido", visible solo con foco, primer elemento del `<body>`, apunta a `#contenido`.
- Utilidades mínimas (no un framework): `.stack` (`display:flex; flex-direction:column; gap: var(--stack-gap, var(--space-4))`), `.cluster` (fila con `flex-wrap` y `gap: var(--space-2)`), `.muted`, `.num` (`tabular-nums`), `.eyebrow` (`--text-xs`, 600, mayúsculas, `letter-spacing: .06em`, `--text-muted`).

### 3.4 Componentes

Notación: *DOM* = estructura que escribe la plantilla o `app.py`; *CSS clave* = reglas que no pueden faltar.

#### 3.4.1 Botón

DOM:
```html
<button class="btn btn--primary" type="submit">Entrar</button>
<a class="btn btn--secondary" href="/admin/qr/7" target="_blank">Ver QR</a>
<button class="btn btn--danger">Eliminar</button>
<button class="btn btn--ghost">Cancelar</button>
<!-- tamaños y variantes extra -->
<button class="btn btn--primary btn--lg btn--block">Entrar a la reunión</button>
<button class="btn btn--sm btn--soft-danger">Silenciar</button>
<!-- carga (lo pone theme.js) -->
<button class="btn btn--primary" aria-busy="true" disabled>…</button>
```
Variantes: `--primary` (fondo `--accent-fill`, texto `--on-fill`), `--secondary` (fondo `--surface-2`, texto `--text`), `--danger` (fondo `--danger-fill`), `--ghost` (transparente, texto `--accent`), y tintadas para la sala: `--soft-success`, `--soft-danger` (fondo `--*-soft`, texto `--*-soft-text`). Tamaños: normal 44 px, `--sm` 32 px (solo en escritorio; en táctil sube a 44), `--lg` 52 px. `--block` = ancho completo.

CSS clave:
```css
.btn { display:inline-flex; align-items:center; justify-content:center; gap:var(--space-2);
  min-height:var(--tap); padding:0 var(--space-5); border:0; border-radius:var(--radius-md);
  font:inherit; font-size:var(--text-md); font-weight:var(--weight-semibold); line-height:1;
  text-decoration:none; cursor:pointer; user-select:none; -webkit-tap-highlight-color:transparent;
  transition: background-color var(--dur-fast) var(--ease-in-out), color var(--dur-fast),
              box-shadow var(--dur-fast), transform var(--dur-fast); }
.btn:hover { text-decoration:none; }
.btn--primary:hover  { background:var(--accent-fill-hover); }
.btn--primary:active { background:var(--accent-fill-active); }
.btn:active:not(:disabled) { transform:scale(.98); }
.btn:focus-visible { outline:3px solid var(--focus-ring); outline-offset:2px; }
.btn:disabled, .btn[aria-disabled="true"] { opacity:.45; cursor:not-allowed; transform:none; }
.btn[aria-busy="true"] { color:transparent; position:relative; pointer-events:none; }
.btn[aria-busy="true"]::after { content:""; position:absolute; width:1.1em; height:1.1em;
  border:2px solid var(--on-fill); border-right-color:transparent; border-radius:50%;
  animation: spin 700ms linear infinite; }  /* en --secondary/--ghost el color es currentColor del estado normal */
@media (pointer:coarse) { .btn--sm { min-height:var(--tap); } }
```
Estados: hover (oscurece el fondo un paso), active (paso más + escala 0.98), focus-visible (anillo de 3 px separado 2 px), disabled (opacidad 0.45, sin hover), loading (`aria-busy="true"`, giro, texto oculto pero **conserva el ancho** para que no salte el layout).

#### 3.4.2 Campo de texto

DOM:
```html
<div class="field">
  <label class="field__label" for="f-titulo">Título</label>
  <input class="field__input" id="f-titulo" name="titulo" required maxlength="120" placeholder="…">
  <p class="field__hint" id="f-titulo-hint">Obligatorio</p>
</div>
```
`input`, `textarea` y `select` comparten `.field__input`. Etiqueta opcional marcada con texto ("Opcional") en `--text-muted`, nunca solo con color. Campos lado a lado (fecha + hora) con `.field-row` (grid 2 columnas ≥ 480 px, 1 columna debajo).

CSS clave: `min-height:var(--tap); padding:var(--space-3) var(--space-4); font-size:var(--text-md)` (**16 px**, anti-zoom iOS); `background:var(--surface); color:var(--text); border:1px solid var(--border-strong); border-radius:var(--radius-md);` `:hover` → borde `--text-muted`; `:focus-visible` → borde `--focus-ring` + halo; `:user-invalid` (Safari 16.5+/Chrome 119+/Firefox 88+) → borde `--danger` (no se usa `:invalid`, que pintaría rojo el formulario vacío antes de tocarlo); `[readonly]` → fondo `--surface-2`; `::placeholder { color: var(--text-muted); opacity:1 }`; `textarea { min-height: 6rem; resize: vertical; }`.

#### 3.4.3 Tarjeta

DOM: `<section class="card"> <header class="card__header"><h2 class="card__title">…</h2><p class="card__subtitle">…</p></header> <div class="card__body">…</div> <footer class="card__footer">…</footer></section>`

CSS clave: `background:var(--surface); border-radius:var(--radius-lg); box-shadow:var(--shadow-1); padding:var(--space-6);` (`--space-5` < 768 px). **Sin borde** en claro (la separación la da el contraste `#FFF` sobre `#F5F5F7` y la sombra). `.card--interactive:hover { box-shadow: var(--shadow-2) }` solo con `@media (hover:hover)`. **Nunca tarjeta dentro de tarjeta**: dentro de una tarjeta se separa con `.list` o con espacio.

#### 3.4.4 Lista

DOM:
```html
<ul class="list" role="list">
  <li class="list__item">
    <div class="list__leading">…baldosa/icono…</div>
    <div class="list__content"><p class="list__title">…</p><p class="list__meta">…</p></div>
    <div class="list__trailing">…acciones…</div>
  </li>
</ul>
```
CSS clave: estilo "lista agrupada" de iOS: el `ul` es una superficie con `--radius-lg`; los ítems tienen `padding: var(--space-4)`, grid `auto 1fr auto`, separador `box-shadow: inset 0 -1px var(--border)` que empieza tras el `leading` (como iOS), el último sin separador; hover `--surface-2` (solo si el ítem es clicable). < 768 px: `trailing` baja debajo del contenido a ancho completo. `role="list"` porque Safari elimina la semántica de lista cuando hay `list-style:none`.

#### 3.4.5 Tabla

**Uso actual: ninguno** (no hay datos tabulares en el panel; se define para que cualquier tabla futura sea coherente y no se invente otra). DOM: `<div class="table-wrap"><table class="table"><thead>…</thead><tbody>…</tbody></table></div>`. CSS clave: `.table-wrap { overflow-x:auto; border-radius:var(--radius-lg); background:var(--surface); box-shadow:var(--shadow-1) }`; `th` en `--text-xs`, 600, mayúsculas, `--text-muted`, alineado a la izquierda; celdas `padding: var(--space-3) var(--space-4)`; filas separadas por `1px solid var(--border)`; números con `.num` y alineados a la derecha. Sin rayado cebra.

#### 3.4.6 Badge / etiqueta de estado

DOM: `<span class="badge badge--success">En curso</span>`; con punto: `<span class="badge badge--success"><span class="badge__dot" aria-hidden="true"></span>En curso</span>`.

Variantes: `--neutral` (fondo `--surface-2`, texto `--text-muted`), `--info`, `--success`, `--warn`, `--danger` (fondo `--*-soft`, texto `--*-soft-text`). CSS clave: `display:inline-flex; align-items:center; gap:var(--space-1); padding:2px var(--space-2); border-radius:var(--radius-full); font-size:var(--text-xs); font-weight:var(--weight-semibold); line-height:var(--lh-xs); white-space:nowrap;`. El estado **nunca** se comunica solo por color: siempre lleva texto.

#### 3.4.7 Aviso (alert)

DOM:
```html
<div class="alert alert--error" role="alert">
  <svg class="alert__icon" aria-hidden="true">…</svg>
  <div class="alert__body"><p class="alert__title">Usuario o contraseña incorrectos.</p><p>…</p></div>
</div>
```
Variantes `--info`, `--success`, `--warn`, `--error`. `role="alert"` solo en errores que aparecen tras una acción (login fallido); los informativos estáticos llevan `role="note"` o nada. CSS clave: grid `auto 1fr`, `gap: var(--space-3)`, `padding: var(--space-4)`, `border-radius: var(--radius-lg)`, fondo `--*-soft`, texto `--*-soft-text`, **sin borde**; el icono (SVG en línea de 20 px, `currentColor`) diferencia el tipo además del color. Iconos: círculo con "i", círculo con ✓, triángulo con "!", círculo con "×" — dibujados como SVG en línea de 1-2 trazos dentro del propio HTML (sin ficheros ni fuentes de iconos).

#### 3.4.8 Cabecera (solo administrador)

DOM (en `tpl.html`):
```html
<header class="appbar">
  <div class="appbar__inner">
    <a class="brand" href="/admin"><svg class="brand__mark" aria-hidden="true">…</svg><span class="brand__name">Cerro Azul</span><span class="brand__product">Reuniones</span></a>
    <details class="menu">…(3.4.9)…</details>
  </div>
</header>
```
CSS clave: `position:sticky; top:0; z-index:10; height:var(--header-h);` fondo translúcido estilo macOS: `background: color-mix(in srgb, var(--surface) 72%, transparent); backdrop-filter: saturate(180%) blur(20px); -webkit-backdrop-filter: …;` filete inferior `box-shadow: 0 1px 0 var(--border)`. Fallback sin `backdrop-filter`/`color-mix` (`@supports not (backdrop-filter: blur(1px))`): fondo `--surface` opaco. La **marca**: un SVG en línea de dos picos de montaña con `fill: url(#grad)` del degradado de marca (sin imágenes externas), "Cerro Azul" en 600 y "Reuniones" en `--text-muted`.

#### 3.4.9 Menú

Basado en `<details>`/`<summary>`: funciona sin JS, con teclado (Enter/Espacio) y se anuncia como desplegable.
```html
<details class="menu">
  <summary class="btn btn--ghost menu__trigger" aria-label="Menú">… ⋯ …</summary>
  <div class="menu__popover" role="menu">
    <div class="menu__section"> …conmutador de tema (3.2)… </div>
    <form method="post" action="/admin/logout"><button class="menu__item" role="menuitem">Cerrar sesión</button></form>
  </div>
</details>
```
CSS clave: `summary { list-style:none } summary::-webkit-details-marker { display:none }`; `.menu { position:relative }`; `.menu__popover { position:absolute; right:0; top:calc(100% + var(--space-2)); min-width:14rem; background:var(--surface-elevated); border-radius:var(--radius-lg); box-shadow:var(--shadow-3); padding:var(--space-2); }`; `.menu__item { display:flex; width:100%; min-height:var(--tap); padding:0 var(--space-3); border-radius:calc(var(--radius-lg) - var(--space-2)); background:none; border:0; font:inherit; text-align:left; color:var(--text) }` hover/focus `--surface-2`; `.menu__item--danger { color: var(--danger) }`; separador `.menu__sep` (1 px `--border`). `theme.js` añade: cerrar al hacer clic fuera, cerrar con `Esc` devolviendo el foco al `summary`, y solo un menú abierto a la vez. Sin JS, se cierra volviendo a pulsar el botón.

Se usa en: cabecera (tema + cerrar sesión) y en cada reunión de la lista ("Más acciones": página pública, entrar como administrador, eliminar).

#### 3.4.10 Diálogo

Solo para confirmar **Eliminar reunión**. Elemento nativo `<dialog>` (Safari ≥ 15.4), creado por `theme.js` una sola vez:
```html
<dialog class="dialog" aria-labelledby="dlg-t" aria-describedby="dlg-d">
  <h2 class="dialog__title" id="dlg-t">¿Eliminar esta reunión?</h2>
  <p class="dialog__text" id="dlg-d">«Asamblea ordinaria». El link y el QR dejarán de funcionar.</p>
  <div class="dialog__actions"><button class="btn btn--secondary" value="cancel">Cancelar</button><button class="btn btn--danger" value="ok">Eliminar</button></div>
</dialog>
```
Comportamiento (en `theme.js`): busca `button[data-confirm]`; **anula su `onclick` nativo** (`btn.onclick = null`) y en su lugar abre el diálogo con `showModal()`; si se confirma, llama a `form.submit()`. Foco inicial en **Cancelar** (la opción segura). `Esc` cancela. **Sin JS** (o si `HTMLDialogElement` no existe) se conserva el `onclick="return confirm(...)"` actual: nunca se pierde la confirmación.
CSS clave: `.dialog { border:0; border-radius:var(--radius-xl); padding:var(--space-6); max-width:min(26rem, calc(100vw - 2*var(--space-4))); background:var(--surface-elevated); color:var(--text); box-shadow:var(--shadow-3) }`, `::backdrop { background: var(--overlay) }`, entrada `opacity 0→1` + `scale(.96→1)` en `--dur-base`. En < 480 px, los botones del diálogo se apilan a ancho completo con **Eliminar arriba y Cancelar abajo** (Cancelar queda más cerca del pulgar, como en las hojas de acción de iOS).

#### 3.4.11 Esqueleto de carga

DOM: `<div class="skeleton skeleton--row" aria-hidden="true"></div>` dentro de un contenedor con `aria-busy="true"` y un texto `.visually-hidden` "Conectando…".
CSS clave: `background: linear-gradient(90deg, var(--surface-2) 0%, color-mix(in srgb, var(--surface-2) 60%, var(--surface)) 50%, var(--surface-2) 100%); background-size:200% 100%; animation: shimmer 1200ms var(--ease-in-out) infinite; border-radius: var(--radius-md); height: 3.5rem;` Con `prefers-reduced-motion`: sin animación (bloque estático).
Se usa en: lista de participantes de la sala antes de conectar (el JS lo borra con `cont.textContent = ""` en el primer `pintar()`, sin cambios en JS) y como fondo del QR mientras carga la imagen.

#### 3.4.12 Estado vacío

DOM: `<div class="empty"><svg class="empty__icon" aria-hidden="true">…</svg><p class="empty__title">Aún no hay reuniones</p><p class="empty__text">Crea la primera con el formulario.</p></div>`
CSS clave: centrado, `padding: var(--space-10) var(--space-6)`, icono de 40 px en `--text-muted` dentro de un círculo `--surface-2` de 64 px, título `--text-lg`/600, texto `--text-muted`.
Se usa en: "No hay reuniones" (`app.py:345`), "Nadie más en la sala" (lo genera el JS como `p.m` dentro de `#lista`: se estiliza con el selector de contrato `#lista > p.m`), "Reunión no encontrada", "Reunión finalizada".

#### 3.4.13 Componentes de dominio (composición de los anteriores)

- **Baldosa de fecha** (`.datetile`): cuadrado de 56 px, `--radius-md`, fondo `--accent-soft`; arriba el mes en `--text-xs`/700 mayúsculas en `--accent` ("NOV"), abajo el día en `--text-xl`/700 `--text` ("4"), `.num`. Evoca el icono de Calendario sin copiarlo. **Depende de D1** (hora Colombia): con UTC, una asamblea de las 19:00 mostraría el día siguiente.
- **Tarjeta QR** (`.qrcard`): fondo `--qr-bg` (blanco siempre), `--radius-xl`, `padding: var(--space-5)`, `box-shadow: var(--shadow-2)`; imagen a `min(280px, 100%)` con `image-rendering: pixelated` (el PNG del QR se escala sin difuminarse) y `aspect-ratio: 1`.
- **Hero de marca** (`.hero`): banda con `--gradient-brand`, texto `--on-fill`, marca en blanco; en páginas públicas mide 160 px en móvil y la tarjeta del contenido se superpone 48 px (`margin-top: -3rem`), efecto "hoja" de iOS.
- **Control segmentado** (`.segmented`) para el tema: 3 `<button aria-pressed>` dentro de una pista `--surface-2` `--radius-full`; el activo con fondo `--surface` y `--shadow-1`.

### 3.5 Accesibilidad

**Contraste (WCAG 2.1 AA; calculados con la fórmula de luminancia relativa):**

| Par (claro) | Ratio | | Par (oscuro) | Ratio |
|---|---|---|---|---|
| `--text` `#1D1D1F` / `--surface` `#FFF` | 16.83 | | `--text` `#F5F5F7` / `--surface` `#1C1C1E` | 15.63 |
| `--text` / `--bg` `#F5F5F7` | 15.46 | | `--text` / `--bg` `#000` | 19.29 |
| `--text-muted` `#6E6E73` / `--surface` | 5.07 | | `--text-muted` `#A1A1A6` / `--surface` | 6.61 |
| `--text-muted` / `--bg` | 4.66 | | `--text-muted` / `--surface-2` `#2C2C2E` | 5.42 |
| `--accent` `#0066CC` / `--surface` | 5.57 | | `--accent` `#4DA3FF` / `--surface` | 6.48 |
| `--accent` / `--bg` | 5.11 | | `--accent` / `--surface-2` | 5.31 |
| `--on-fill` / `--accent-fill` `#0066CC` | 5.57 | | `--on-fill` / `--accent-fill` `#0060DF` | 5.62 |
| `--on-fill` / `--danger-fill` `#C9190B` | 5.79 | | `--on-fill` / `--danger-fill` `#D70015` | 5.38 |
| `--on-fill` / `--success-fill` `#1A7F37` | 5.08 | | `--on-fill` / `--success-fill` `#1F7A3A` | 5.38 |
| `--warn` `#B25000` / `--surface` | 5.20 | | `--warn` `#FF9F0A` / `--surface` | 8.28 |
| `--danger` `#C9190B` / `--surface` | 5.79 | | `--danger` `#FF6961` / `--surface` | 6.03 |
| `--accent-soft-text` / `--accent-soft` | 6.87 | | `#9CC9FF` / `#0F2A4A` | 8.42 |
| `--success-soft-text` / `--success-soft` | 6.49 | | `#8EE6A4` / `#0E2E18` | 9.84 |
| `--warn-soft-text` / `--warn-soft` | 7.14 | | `#FFD08A` / `#3A2400` | 10.22 |
| `--danger-soft-text` / `--danger-soft` | 7.02 | | `#FFB3B0` / `#3D1010` | 9.63 |
| `--on-fill` / `--accent-2` `#5E5CE6` (fin del degradado) | 5.06 | | `--border-strong` `#8E8E93` / `--surface` (no-texto) | 5.22 |
| `--border-strong` `#86868B` / `--surface` (no-texto, ≥ 3) | 3.62 | | `--border-strong` / `--surface-2` (no-texto) | 4.27 |

Prohibido: `--text-muted` sobre `--surface-2` en claro (4.46, por debajo de 4.5) para texto < 18.66 px en negrita/24 px normal; `--border` (1.51 en claro) para nada que tenga que verse para usarse (es decorativo). Un texto blanco sobre el degradado de marca solo se usa en ≥ `--text-md`/600 (peor punto 5.06).

**Foco:** visible siempre (sección 3.3), nunca eliminado; contraste del anillo ≥ 3:1 con el fondo (5.57 / 6.48). En la sala, el iframe de Jitsi gestiona su propio foco; el panel lateral es alcanzable con Tab tras el iframe.

**Teclado:** orden de tabulación = orden visual (no se usa `order` de flex/grid para reordenar contenido interactivo; el cambio de orden del panel se hace en el HTML). Enlace "Saltar al contenido". Menús con `<details>` (Enter/Espacio; `Esc` con JS). Diálogo con trampa de foco nativa de `showModal()`.

**Movimiento:** `@media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation-duration: .01ms !important; animation-iteration-count: 1 !important; transition-duration: .01ms !important; scroll-behavior: auto !important; } }`.

**Táctil:** todo control interactivo ≥ 44 × 44 px con `@media (pointer: coarse)`; separación mínima de 8 px entre controles vecinos. En escritorio (`pointer: fine`) se permiten botones `--sm` de 32 px en la lista de participantes.

**Semántica:** `<header>`, `<main id="contenido">`, `<footer>`; un solo `<h1>` por página; `label for`/`id` en todos los campos; `autocomplete` (`username`, `current-password`, `name`, `off` en apartamento); `enterkeyhint="go"` en el último campo de los formularios del residente; `aria-live="polite"` en el contador de participantes (`#cnt`) y en el estado de moderación (atributo añadido en HTML, sin JS).

**Zoom de texto:** todo en `rem`; la interfaz debe aguantar el tamaño de letra al 200 % sin solaparse (los botones crecen en alto, las filas pasan a columna).

---

## 4. Plan por página

Convención: "Contrato" = lo que **no** puede cambiar. "Cambia" = lo que se toca.

### 4.1 `tpl.html` — layout base

**Contrato:** recibe `t` y `body` (`{{ body|safe }}`); `lang="es"`; `charset utf-8`.

**Cambia:**
- `<head>`: viewport `width=device-width, initial-scale=1, viewport-fit=cover`; `<title>{{ t }} · Cerro Azul</title>`; `meta color-scheme`; dos `theme-color`; `<link rel="stylesheet" href="/admin/static/theme.css?v={{ v }}">` y `<script src="/admin/static/theme.js?v={{ v }}"></script>` (síncrono, ver 3.2). **Se elimina todo el `<style>`.**
- Dos variables nuevas que pasa `app.py` (con valores por defecto en la plantilla para que una llamada que se olvide no rompa nada):
  - `kind`: `"admin"` (con cabecera), `"public"` (marca + pie con conmutador), `"auth"` (login: sin cabecera, fondo aurora). Por defecto `public`.
  - `width`: `"narrow"`, `"content"` o `"wide"`. Por defecto `narrow`.
- `v`: versión de los estáticos para romper caché, constante `ASSET_V` en `app.py` (p. ej. `"20261101a"`) que se sube a mano en cada cambio de CSS/JS.
- Estructura:
  ```html
  <body class="page page--{{ kind|default('public') }}">
    <a class="skip-link" href="#contenido">Saltar al contenido</a>
    {% if kind == 'admin' %}<header class="appbar">…marca + menú…</header>{% endif %}
    <main id="contenido" class="container container--{{ width|default('narrow') }}">{{ body|safe }}</main>
    {% if kind != 'admin' %}<footer class="footer">Cerro Azul · <button class="theme-cycle" type="button">Apariencia: Automático</button></footer>{% endif %}
  </body>
  ```
  (En `auth`, el pie es igual pero sobre el fondo aurora.)
- **Cerrar sesión pasa al menú de la cabecera** (decisión D5) y desaparece del pie del panel. El formulario conserva `method="post" action="/admin/logout"` (la ruta no comprueba CSRF hoy, y se deja igual).

### 4.2 `page_login.html` — acceso del administrador

**Contrato:** `<!--ERR-->`; `<form method="post">` **sin `action`** (H10); `name="user"`, `name="password"`, `required`, `autofocus` en usuario; un botón submit.

**Cambia (se ve como producto, ver mockup M1):** fondo `--bg` con `--gradient-aurora`; tarjeta `--radius-xl` + `--shadow-3`, ancho `--w-narrow`, centrada con margen superior (no centrado vertical rígido); dentro: marca grande (SVG de 56 px sobre círculo con degradado), `h1` "Cerro Azul" en `--text-2xl`, subtítulo "Panel de reuniones" en `--text-muted`; error (`<!--ERR-->`) como `.alert--error`; campos `.field` con `id`/`for`, `autocomplete="username"` / `"current-password"`, `autocapitalize="off"`, `spellcheck="false"`; botón `btn--primary btn--lg btn--block` "Entrar" con estado de carga; pie "Acceso restringido al personal autorizado de Cerro Azul" en `--text-xs`.
**`app.py`:** `login()` → `kind="auth", width="narrow"`; la cadena del error pasa a `'<div class="alert alert--error" role="alert">' + icono + '<p class="alert__title">' + err + '</p></div>'` (los mensajes son constantes del código, no entrada del usuario).

### 4.3 `page_panel.html` + `listar_reuniones` — la pantalla más usada

**Contrato:** marcadores `{{csrf}}`, `{{user}}`, `<!--AVISO_JWT-->`, `<!--LISTA-->`; el formulario `method="post" action="/admin/reunion"` con `csrf` (hidden), `titulo` (required, maxlength 120), `descripcion` (maxlength 500), `fecha` (date, required), `hora` (time, required), `duracion` (number, value 60, min 15, max 480) — **todos dentro del mismo `<form>`**; en cada reunión, los hrefs `/admin/qr/<id>`, `https://PUB/reunion/<slug>`, `/admin/reunion/<id>/sala`, `/admin/reunion/<id>/entrar` con `target=_blank`, y el form `POST /admin/reunion/<id>/eliminar` con su `csrf`.

**Cambia (mockup M2):**
- Orden: cabecera de página ("Reuniones" `h1` + "Sesión iniciada como **{{user}}**" en muted + botón `btn--primary` "Nueva reunión" que es un **enlace ancla** a `#nueva`); aviso JWT (`.alert--error`, prioridad máxima, arriba); **la lista primero**; el formulario después, en una tarjeta con `id="nueva"`.
- ≥ 1024 px: rejilla `1fr 22.5rem` (lista a la izquierda, formulario a la derecha, `position: sticky; top: calc(var(--header-h) + var(--space-6))`). En esa anchura el botón "Nueva reunión" se oculta (el formulario está a la vista). < 1024 px: una columna (lista, luego formulario).
- Formulario: `.field` por campo; fecha y hora en `.field-row`; la nota "El acceso se cierra 30 min después…" como `.field__hint` del campo duración; "(AAAA-MM-DD, hora Colombia UTC-5)" se convierte en la ayuda "Hora de Colombia" (el selector nativo ya impone el formato); botón `btn--primary btn--block` "Crear reunión y generar QR" con estado de carga.
- `listar_reuniones` genera una `.list` (DOM en mockup M2): `leading` = baldosa de fecha (D1); `content` = título (`--text-lg`/600, una línea con elipsis, título completo en `title`), meta "mar 3 nov · 7:00 p. m. · 60 min" (D1), badge de estado (D3) y el link público en `--font-mono` `--text-xs` muted con elipsis; `trailing` = `btn--primary btn--sm` "Moderar" (→ sala), `btn--secondary btn--sm` "Ver QR", y menú "⋯" con "Página pública", "Entrar como administrador", separador, "Eliminar" (`menu__item--danger`, dentro de su `<form>` con `csrf`, `data-confirm` **y** el `onclick` de respaldo).
- El código de sala (`sala_jitsi`) sale de la lista (es ruido técnico para el administrador; sigue visible en la vista QR y en la sala). *Nota:* no es información perdida, está a un clic.
- Atributos HTML generados **con comillas** (`name="csrf" value="…"`), lo que de paso hace que `verificar-panel.py` los detecte.
- Corrige "UTC UTC" (H7).
- Lista vacía → `.empty` "Aún no hay reuniones / Crea la primera con el formulario".
- `app.py`: `panel()` → `kind="admin", width="content"`; la cadena del aviso JWT pasa a `.alert--error` (sigue escapando cada problema con `escape_html`). Todo valor de la BD que entra en el HTML sigue pasando por `escape_html` (también el nuevo `title=` y el texto de `data-confirm`).

### 4.4 `page_qr_view.html` — reunión creada / ver QR (administrador)

**Contrato:** `{{titulo}}`, `{{fecha_utc}}`, `{{duracion}}`, `{{sala}}`, `{{link_publico}}` (dos usos), `{{qr_url}}`; el `input readonly onclick="this.select();"`; enlaces "Probar como participante" (`target=_blank`) y "Volver al panel" (`/admin`).

**Cambia (mockup M3):** cabecera de confirmación: icono ✓ en círculo `--success-soft`, eyebrow "REUNIÓN CREADA" en `--success`, `h1` con el título; ≥ 768 px dos columnas (izquierda la `.qrcard` grande, derecha detalles + link + acciones); < 768 una columna con el QR primero. Detalles como lista de pares (`<dl class="kv">`: Fecha, Duración, Sala en `<code>`). Link en `.field__input` monoespaciado de solo lectura. Acciones: `btn--primary` "Probar como participante", `btn--secondary` "Volver al panel". El consejo de WhatsApp como `.alert--info` con un ejemplo de mensaje entre comillas. **Se eliminan todos los estilos en línea.**
**`app.py`:** `qr_view()` → `kind="admin", width="content"`; si se aprueba D1, `{{fecha_utc}}` recibe la fecha en hora de Colombia formateada (mismo marcador, otro valor).

*Nota sobre el título:* esta página se usa también desde "Ver QR" para reuniones viejas; el eyebrow "REUNIÓN CREADA" es cierto en ambos casos (no se añade lógica para distinguirlos).

### 4.5 `page_reunion.html` — página pública del residente (móvil primero)

**Contrato:** `{{titulo}}`, `{{rol}}`, `{{fecha_utc}}`, `{{duracion}}`, `<!--DESC-->`, `{{slug}}`; `<form method="post" action="/unirse">` con `slug` (hidden), `apto` (maxlength 20), `nombre` (required, maxlength 50); un submit.

**Cambia (mockup M4):** `.hero` con degradado y marca blanca "Cerro Azul" (160 px en móvil); tarjeta superpuesta (`--radius-xl`) con: eyebrow "ESTÁS INVITADO", `h1` título (`--text-xl` en móvil); fila de "chips" con fecha/hora y duración (icono calendario/reloj + texto); `<!--DESC-->` (si D2) como párrafo; `.alert--info` "Entrarás con micrófono y cámara apagados. Para hablar, levanta la mano ✋ y la administración te dará la palabra."; formulario con `.field` (`apto`: `autocomplete="off"`, `inputmode="text"` — puede ser "T2-302"; `nombre`: `autocomplete="name"`, `autocapitalize="words"`, `enterkeyhint="go"`) y botón `btn--primary btn--lg btn--block` **"Entrar a la reunión"** (52 px) con estado de carga (evita el doble envío que emite dos tokens). "Rol al entrar: **Asistente**" se convierte en una línea pequeña "Entras como asistente" bajo el botón (se conserva `{{rol}}`).
**Rendimiento:** la página carga 1 HTML + 1 CSS + 1 JS, todo local; objetivo < 40 KB transferidos sin comprimir, sin imágenes (el degradado y la marca son CSS/SVG en línea). En 3G lenta debe pintar en < 1 s tras el HTML.
**`app.py`:** `reunion_publica()` → `kind="public", width="narrow"`; "Reunión no encontrada" (`app.py:441`) y `pagina_finalizada` pasan a `.empty` con icono, también `kind="public"`. **Ojo:** `pagina_finalizada` se usa también desde `/admin/reunion/<id>/sala` y `/entrar` (administrador); ahí también se mostrará con `kind="public"` (sin cabecera). Es aceptable (es una página de estado) y **no** se añade lógica para distinguir quién la ve: el contenido es siempre el mismo.

### 4.6 `page_sala.html` — moderación en vivo (la delicada)

**Regla absoluta: el bloque `<script>` final se copia byte a byte.** Ni una coma. Se verifica con `diff` (6.4).

**Contrato con el JS** (todo lo que el script lee o crea):

| Elemento | Uso en el JS | Regla |
|---|---|---|
| `#jitsi` | `parentNode` del iframe | Mantener `id`, vacío, contenedor de bloque. |
| `#log` | `log()` escribe `textContent` | Mantener `id`. Puede ir dentro de un `<details>` (sigue existiendo en el DOM). |
| `#lista` | `pintar()` vacía y rellena | Mantener `id`. Su contenido estático inicial (hoy "Conectando...") se puede cambiar por el esqueleto: el JS lo borra. |
| `#cnt` | `textContent = "(n)"` | Mantener `id`; se estiliza como badge neutro con `.num`. El texto "(n)" con paréntesis lo pone el JS. |
| `#st-audio`, `#st-video` | `textContent = "ACTIVA"/"apagada"` | Mantener `id`s; se estilizan como badge neutro (no se puede colorear por valor sin JS). |
| `.gl button` + `data-cmd` | `querySelectorAll(".gl button")` + `getAttribute("data-cmd")` | Los 6 botones deben seguir **dentro** de un ancestro `.gl` y **ningún otro `<button>`** puede entrar en `.gl` (el JS le asignaría un listener). Los 6 `data-cmd` se conservan tal cual. Se pueden reagrupar en sub-contenedores dentro de `.gl` y añadir clases. |
| `div.p`, `div.n`, `span.mano`, `p.m` creados por JS | clases fijas | Estilos permanentes en `theme.css` bajo `#lista` (sección "contrato sala"). |
| botones creados por JS con clase `ok2`, `d` o `""` | clases fijas | Estilizados bajo `#lista .p button` (base `--sm` secundario), `#lista .p button.ok2` (`--soft-success`), `#lista .p button.d` (`--soft-danger`). |
| `<script src="https://{{domain}}/external_api.js">` | carga el API de Jitsi | Mantener (es el mismo dominio del proyecto, no un CDN). |
| `{{titulo}}`, `{{sala}}`, `{{domain}}`, `{{cfg_json}}` | marcadores de `app.py` | Mantener. |

**Cambia (mockup M5):**
- Se elimina el `<style>` en línea (pasa a `theme.css`, bloque `/* page: sala */`).
- Título compacto: eyebrow "MODERACIÓN EN VIVO" con punto rojo pulsante (pulso desactivado con reduced-motion), `h1` `{{titulo}}` en `--text-xl`, meta "Sala `{{sala}}` · {{domain}}". El párrafo técnico largo pasa a un `<details class="disclosure">` "¿Cómo funciona la moderación?" cerrado por defecto (mismo texto, con tildes).
- ≥ 1024 px: rejilla `minmax(0,1fr) 22.5rem` (video | panel lateral). < 1024: una columna (video arriba a ancho completo, 560 px de alto por H6; panel debajo).
- `#jitsi`: `--radius-lg`, `overflow:hidden`, fondo `#000`, `box-shadow: var(--shadow-2)`.
- Panel lateral = pila de tarjetas:
  1. **Estado**: "Audio" badge `#st-audio` · "Video" badge `#st-video` (`aria-live="polite"` en el contenedor).
  2. **Toda la sala** (`.gl`): tres grupos con subtítulo eyebrow, cada uno una fila de 2 botones a medio ancho:
     - "PALABRA": `dar-palabra-todos` (`btn--soft-success`) · `quitar-palabra-todos` (`btn--soft-danger`)
     - "SILENCIAR": `mute-all-audio` · `mute-all-video` (ambos `btn--soft-danger`)
     - "MODERACIÓN A/V": `mod-on` (`btn--secondary`) · `mod-off` (`btn--secondary` con texto `--danger`)
     Debajo, la aclaración "Pedir la palabra… es una petición…" como `.field__hint`.
     Los textos visibles se acortan bajo su subtítulo ("Dar a todos", "Activar"…), pero cada botón lleva `aria-label` con el texto completo actual con tildes ("Dar la palabra a todos", "Activar moderación A/V"), para que un lector de pantalla no anuncie un "Activar" ambiguo. El `data-cmd` no cambia.
  3. **Participantes** + `#cnt`: la ayuda corta en muted; `#lista` con esqueleto inicial (3 filas). Cada `div.p` → fila con `--radius-md`, fondo `--surface-2`, nombre (`div.n`) en `--text-md`/500 con elipsis, botones en `.cluster` debajo. **Mano levantada:** `#lista .p:has(.mano)` → fondo `--warn-soft` y borde izquierdo de 3 px `--warn`; `span.mano` como badge `--warn` (el texto "[mano]" se mantiene). `:has()` requiere Safari 15.4 / Chrome 105 / Firefox 121; sin él, la etiqueta `.mano` sigue destacando sola. Lista con `max-height: 50vh; overflow:auto` en ≥ 1024 para que no empuje el panel.
  4. **Registro técnico**: `<details>` cerrado con `#log` dentro (monoespaciada `--text-xs`, fondo `--surface-2`, `max-height: 10rem`).
- `app.py`: `sala_moderacion()` → `kind="admin", width="wide"`.

**Cómo se garantiza que el comportamiento no cambia:** el script es idéntico (diff vacío); los selectores del contrato se comprueban con la verificación de 6.4; la prueba manual de 6.3 se ejecuta antes del despliegue y otra vez en producción.

---

## 5. Arquitectura de los estilos

```
admin-panel/app/
├── app.py                 (+ static_url_path, kind/width/v en cada render, cadenas HTML)
├── tpl.html               (layout; sin <style>)
├── page_*.html            (sin <style> ni style="…")
└── static/
    ├── theme.css          (único CSS)
    └── theme.js           (único JS compartido)
```

### 5.1 Registro en Flask

```python
ASSET_V = "20261101a"   # subir al cambiar theme.css/theme.js
app = Flask(__name__, static_url_path="/admin/static")   # static_folder por defecto: <dir de app.py>/static
```
- Dentro del contenedor `app.py` está en `/app/app.py`, así que los estáticos se buscan en `/app/static/`.
- **Dockerfile:** añadir `COPY app/static /app/static` junto a los demás `COPY`.
- URL pública: `https://meet.bytracking.net/admin/static/theme.css`. Entra por `@admin path /admin*` de Caddy: **sin cambios en Caddy** (H3). No requiere sesión (Flask sirve estáticos sin pasar por `login_required`), así que las páginas públicas lo pueden cargar.
- Caché: Flask ≥ 2.0 envía `ETag`/`Last-Modified` y sin `max-age` por defecto → el navegador revalida (304) en cada carga; el `?v=` garantiza que un cambio se vea al instante. No se toca `SEND_FILE_MAX_AGE_DEFAULT`.
- Cada `render_template_string(..., t=..., body=...)` (7 llamadas: `app.py:317, 339, 434, 442, 452, 458, 513`) añade `kind=`, `width=` y `v=ASSET_V`. Para no repetir, se puede crear `def render_page(t, body, kind="public", width="narrow")` que lea `tpl.html` y llame a `render_template_string`; es un refactor puramente mecánico y se permite.

### 5.2 Organización de `theme.css` (orden fijo, un solo fichero, ~ 25-35 KB sin minificar)

1. Cabecera: índice, puntos de corte, regla `SYNC-DARK`.
2. Tokens claro (`:root`), tokens oscuro (`@media` + `[data-theme="dark"]`).
3. Base/reset, tipografía, enlaces, foco, utilidades.
4. Layout: `.container--*`, `.appbar`, `.footer`, `.hero`, rejillas de página.
5. Componentes (en el orden de 3.4).
6. Componentes de dominio (`.datetile`, `.qrcard`, `.segmented`, `.kv`, `.disclosure`).
7. Páginas: `/* page: panel */`, `/* page: sala */` (incluye el **contrato sala**: `#jitsi`, `#lista .p`, `.n`, `.mano`, `.ok2`, `.d`, `#lista > p.m`, `#log`, `#cnt`, `#st-*`).
8. Movimiento reducido, `@media print` (QR: imprime solo la tarjeta del QR y el título).
9. **Compatibilidad temporal** (solo pasos 1-5 del plan): alias de las clases viejas (`.c .m .r .mt .ac .b .e .o .d .qr`) con aspecto del sistema nuevo, para que una página no migrada no se vea rota. Se borra en el paso 7, **excepto** `.d` / `.m` usados por el contrato de la sala, que viven en el bloque 7 con selector acotado (`#lista …`).

Nada de `<style>` en las plantillas. Excepción admitida: ninguna. Atributos `style=""` en HTML: prohibidos (salvo los que genere el API de Jitsi dentro de `#jitsi`).

### 5.3 `theme.js` (sí hace falta; ≤ 3 KB, sin dependencias, ES5 + `classList`/`dataset`)

Contenido completo, nada más:
1. **Tema temprano** (se ejecuta al cargar, en el `<head>`): leer `ca-tema` → `documentElement.dataset.theme`; actualizar `theme-color`.
2. Al `DOMContentLoaded`:
   - **Conmutador**: `.segmented [data-theme-set]` (menú admin) y `.theme-cycle` (pie público) → escriben/borran `ca-tema`, actualizan `dataset.theme`, `aria-pressed` y la etiqueta.
   - **Menús**: cerrar `details.menu[open]` al hacer clic fuera o con `Esc` (foco vuelve al `summary`); abrir uno cierra los demás.
   - **Carga en formularios**: en `form[data-loading]`, al evento `submit` → `aria-busy="true"` y `disabled` en su botón submit. En `pageshow` con `event.persisted` (volver atrás en Safari/iOS) → quitarlos. *No* se aplica al formulario de eliminar (lo gestiona el diálogo) ni a nada de la sala.
   - **Diálogo de confirmación**: `button[data-confirm]` (sección 3.4.10), solo si existe `HTMLDialogElement`.
- **No toca** nada de la sala: no registra listeners en `.gl`, `#lista`, ni lee `CFG`. La sala sigue funcionando aunque `theme.js` falle o no cargue.
- Envuelto en una IIFE, `"use strict"`, sin variables globales.

---

## 6. Riesgos y compatibilidad

### 6.1 Qué podría romperse y cómo se evita

| Riesgo | Cómo se rompería | Prevención |
|---|---|---|
| Renombrar/borrar un marcador (`{{csrf}}`, `<!--LISTA-->`…) | `str.replace` no encuentra nada: CSRF vacío → **403 al crear**; lista desaparece; se ve `{{titulo}}` literal | Lista de contrato por página (sección 4); verificación automática de que en el HTML final **no queda ningún `{{` ni `<!--` de marcador** (excepto `<!--DESC-->` si D2 no se aprueba). |
| Cambiar `name` o sacar un campo del `<form>` | El servidor no recibe `titulo`/`fecha`/`nombre`… → 400 "Faltan datos" | No renombrar `name`; comprobar con la extracción de 6.4 que cada `form` mantiene sus `name`s. |
| Añadir `action` al login | Se pierde `?next=` | H10, comprobado en 6.4. |
| CSRF de la lista sin comillas / roto | Eliminar → 403 | Las cadenas nuevas usan comillas; prueba de eliminar en 6.3. |
| Meter otro `<button>` dentro de `.gl` | El JS le pone un listener; al pulsarlo no pasa nada grave, pero rompe el contrato | Regla de 4.6; verificación: `.gl button` = exactamente 6 y todos con `data-cmd`. |
| Tocar el `<script>` de la sala | Moderación rota en plena asamblea | Diff byte a byte del bloque `<script>…</script>` antes/después (debe ser vacío). |
| CSS que oculta o reduce `#jitsi` | Iframe invisible o cortado | `#jitsi` sin `display:none`, `min-height:560px`; prueba manual. |
| Ruta de estáticos en `/static` | Caddy la manda a Jitsi → 404, panel sin estilo | `static_url_path="/admin/static"` (H3); `curl -I /admin/static/theme.css` → 200 `text/css`. |
| Olvidar el `COPY` en el Dockerfile | 404 del CSS en producción, aunque funcione en local con Flask directo | Paso 1 del plan; la verificación se hace contra el **contenedor**, no contra `python app.py`. |
| Caché del navegador con CSS viejo y HTML nuevo | Página descuadrada tras desplegar | `?v=ASSET_V`. |
| `theme.js` falla | Sin tema manual, sin diálogo bonito | Todo es mejora progresiva: confirm nativo, `<details>` nativo, tema del sistema por CSS. |
| XSS al generar HTML nuevo en Python | Título de reunión con `<script>` | Todo dato de BD por `escape_html` (también en `title=` y `data-confirm=`); `escape_html` ya escapa `"`. |
| Tildes y UTF-8 | Caracteres rotos | `tpl.html` ya declara `utf-8`; Flask responde `text/html; charset=utf-8`; los ficheros se guardan en UTF-8. Los mensajes de log no cambian. |
| Watchdog / monitores que buscan texto | Falsa alarma | Revisado: el watchdog usa `/healthz` (JSON, no cambia). Ningún script del repo busca texto de las páginas salvo `loadtest/verificar-panel.py` (diff esperado, ver 6.4). |
| Respuesta del servidor | — | No cambian: rutas, métodos, códigos (200/302/400/403/404/410), redirecciones, cabeceras, cookies, JSON de `/healthz`, `/moderador.json`, `/api/...`. Solo cambia el cuerpo HTML y aparecen dos ficheros estáticos nuevos. |

### 6.2 Cosas que el rediseño **no** puede hacer (y quedan anotadas)

- Cambiar "[mano]" por "✋", colorear `#st-audio` según su valor, o cambiar el alto del iframe: exigen tocar el JS de la sala (prohibido). Propuestas para una fase posterior.
- Botón "Copiar link" y "Descargar QR": serían funcionalidad nueva (prohibido). Propuestas para después.

### 6.3 Prueba manual de moderación (antes de desplegar, en local con stack de prueba, y repetida en producción)

Con dos navegadores (A = administrador en la sala, B = residente desde un móvil o ventana privada):
1. A abre "Moderar": el iframe carga, el registro muestra "unido como…", estado pasa a `ACTIVA / ACTIVA`.
2. B entra por el QR/link: aparece en `#lista`, `#cnt` = (1).
3. B levanta la mano → su fila sube, se pinta ámbar y muestra `[mano]`.
4. A pulsa "Pedir la palabra" → a B le llega la petición. "Silenciar" → B queda silenciado. "Habilitar cámara" / "Apagar cámara" → efecto en B.
5. A pulsa cada uno de los 6 botones globales y el registro muestra el comando correspondiente (`muteEveryone("audio")`, `toggleModeration(false, "audio")`…); estado se actualiza.
6. B sale → desaparece; con nadie, aparece el estado vacío "Nadie más en la sala".
7. Repetir 1-6 en modo oscuro y a 360 px de ancho.

### 6.4 Verificación automática (script a crear en el paso 0: `scripts/verificar-panel-local.py`)

Contra el **contenedor local** (como `scripts/test-ci-local.sh`: `docker build` + `docker run` con un `instance/admin.env` de prueba con hash conocido), con sesión iniciada:
1. Login (POST), crear una reunión, abrir panel, QR, pública, sala, y extraer por página: `id`s, `name`s por `form`, `action`/`method` de cada `form`, presencia de `csrf` (con y sin comillas), número de `.gl button[data-cmd]`, existencia de `#jitsi #lista #cnt #log #st-audio #st-video`.
2. Marcadores residuales: ningún `{{` en el HTML final; ningún `<!--ERR-->`, `<!--LISTA-->`, `<!--AVISO_JWT-->`.
3. `diff` del bloque `<script>` de `page_sala.html` contra `main` → vacío.
4. Sin dependencias externas: en todos los HTML, ningún `src=`/`href=` a dominios distintos de `meet.bytracking.net` (la única referencia externa admitida es `external_api.js` de ese dominio y los links públicos de reunión); en `theme.css` ningún `url(http`, ningún `@import`.
5. `GET /admin/static/theme.css` → 200 `text/css`; `theme.js` → 200 `text/javascript` o `application/javascript`.
6. Bloques `SYNC-DARK` idénticos.
7. Eliminar la reunión de prueba (POST con CSRF) → 302 a `/admin`.

Salida en texto estable para `diff` antes/después. **Diferencias esperadas** (y solo estas): `id`s nuevos de accesibilidad (`f-*`, `contenido`, `nueva`), más `<button>` (menú, tema), +1 `<script>` (theme.js) por página. Cualquier otra diferencia en `name`, `action` o `csrf` es un fallo.

---

## 7. Plan de implementación (pasos pequeños, cada uno desplegable)

Despliegue de cada paso (topología actual: el VPS no es git): copiar los ficheros cambiados a `/opt/jitsi-meet/admin-panel/…`, `docker compose build admin`, `docker compose up -d --force-recreate admin`, comprobar `/healthz`. Rollback: volver a copiar los ficheros de `main` anteriores y repetir build/recreate (la BD no se toca en ningún paso).

| Paso | Contenido | Verificación propia |
|---|---|---|
| **0. Red de seguridad** | Escribir `scripts/verificar-panel-local.py` (6.4). Ejecutarlo sobre `main` actual → `/tmp/panel-antes.txt`. No cambia producción. | El script corre y produce la línea base. |
| **1. Infraestructura de estáticos** | `static/theme.css` con tokens + base + **alias de compatibilidad** que reproducen el aspecto **actual** a grandes rasgos; `static/theme.js`; `static_url_path`, `ASSET_V`, `kind/width/v` en los `render`; Dockerfile `COPY`; `tpl.html` enlaza CSS/JS y **conserva** su `<style>` de momento. | Visualmente casi igual. `curl -I` del CSS = 200 en producción. Diff 6.4 solo con las diferencias esperadas. |
| **2. Layout + tema** | `tpl.html` nuevo (cabecera, main, pie, conmutador), se elimina su `<style>`; los alias ya dan el aspecto nuevo a lo no migrado. Logout al menú (D5) — en este paso el botón del panel se mantiene también, para que no haya un momento sin logout. | Modo claro/oscuro/auto funciona y persiste; skip link; 360/768/1280 sin scroll horizontal. |
| **3. Login** | `page_login.html` + cadena de error. | Login correcto, login fallido (alerta), `?next=` sigue funcionando, rate-limit muestra su mensaje. |
| **4. Páginas del residente** | `page_reunion.html`, "no encontrada", "finalizada". (D1, D2 en este paso si se aprueban.) | Desde un móvil real: carga, no hay zoom al enfocar, botón ≥ 52 px, doble toque no emite dos `/unirse` (ver log del panel), entra a Jitsi. Lighthouse accesibilidad ≥ 95. |
| **5. Panel + QR** | `page_panel.html`, `listar_reuniones`, `page_qr_view.html`, diálogo de eliminar, badge (D3). Se quita el logout duplicado del paso 2. | Crear reunión → QR; QR escaneable en claro **y oscuro**; eliminar con diálogo y sin JS (confirm nativo); menú "⋯" por teclado. |
| **6. Sala** | `page_sala.html` (marcado + bloque `page: sala` en CSS). Desplegar **fuera de horario de asamblea**. | Diff del `<script>` vacío; prueba manual 6.3 completa en local y en producción. |
| **7. Limpieza** | Borrar alias de compatibilidad; tildes restantes (D4) en cadenas de `app.py` visibles al usuario; repasar que no queda `style=` en plantillas. | 6.4 completo; criterios de la sección 8. |

Cada paso es un commit propio. Si un paso falla en producción, se revierte solo ese paso.

---

## 8. Criterios de aceptación visuales (comprobables)

**Sistema**
- [ ] Solo existe un CSS (`/admin/static/theme.css`) y un JS compartido (`/admin/static/theme.js`). Ninguna plantilla tiene `<style>` ni atributos `style=`.
- [ ] Todos los colores del CSS salen de tokens: fuera del bloque de tokens no hay ningún literal `#xxxxxx`/`rgb()` (excepción: `#000` del fondo del iframe y `--qr-bg`).
- [ ] Todos los espacios son múltiplos de 4 px (tokens `--space-*`).

**Contraste y accesibilidad**
- [ ] Todos los pares de la tabla 3.5 cumplen (texto ≥ 4.5:1; texto grande y elementos no textuales ≥ 3:1), en claro y en oscuro.
- [ ] Recorrido completo con Tab en cada página: el foco se ve siempre (anillo de 3 px) y el orden es lógico; menús y diálogo operables solo con teclado; `Esc` cierra.
- [ ] Con `prefers-reduced-motion: reduce`: ninguna animación ni transición visible.
- [ ] En un móvil táctil, todo control mide ≥ 44 × 44 px (inspector: `pointer: coarse`).
- [ ] Cada campo tiene `label` asociada (pulsar la etiqueta enfoca el campo). Ningún texto < 12 px. Ningún campo < 16 px.
- [ ] Lighthouse (móvil) Accesibilidad ≥ 95 en login, reunión pública y panel.

**Responsive** (Chrome DevTools y un iPhone/Android real)
- [ ] **360 px**: sin scroll horizontal en ninguna página; botón principal del residente a ancho completo; lista de reuniones en una columna con acciones debajo; la sala usable (video arriba, controles debajo, botones que se ajustan).
- [ ] **768 px**: QR en dos columnas; formularios con fecha/hora lado a lado.
- [ ] **1280 px**: panel en dos columnas (lista + formulario fijo); sala con video y panel lateral lado a lado; contenido centrado con el ancho máximo del token.
- [ ] Texto del navegador al 200 %: nada se solapa ni se corta.

**Temas**
- [ ] Automático sigue al sistema (cambiar el modo del SO cambia la página sin recargar).
- [ ] Claro/Oscuro manual persiste entre páginas y recargas (`localStorage["ca-tema"]`), sin parpadeo al cargar.
- [ ] El QR se ve sobre blanco en ambos temas y se escanea con la cámara de un iPhone y un Android.

**Sin dependencias**
- [ ] Con el servidor sin salida a Internet (o DevTools bloqueando todo menos `meet.bytracking.net`), todas las páginas se ven completas. En la pestaña Red solo aparecen peticiones al propio dominio.
- [ ] Ninguna fuente web, imagen externa, `@import` ni CDN.

**Sin cambios en el servidor**
- [ ] `verificar-panel-local.py`: solo las diferencias esperadas (6.4).
- [ ] Mismos códigos HTTP y redirecciones en: login OK/fallo, crear, eliminar, `/unirse`, reunión inexistente (404), finalizada (410), `/healthz`, `/api/reuniones/<id>/token` sin key (401).
- [ ] Bloque `<script>` de la sala idéntico a `main`; prueba 6.3 superada.

---

## 9. Decisiones que hay que aprobar antes de implementar

| # | Decisión | Recomendación | Si se rechaza |
|---|---|---|---|
| **D1** | Mostrar la hora en **hora de Colombia** (p. ej. "mar 3 nov · 7:00 p. m.") en lista, QR y página pública, en vez de "2026-11-04 00:00 UTC". Formato fijo: día de la semana y mes abreviados en español, hora de 12 h con "a. m./p. m." (uso colombiano), generado en Python sin depender del locale del contenedor (tablas de nombres en el código). Solo presentación: la BD y los tokens siguen en UTC; se calcula restando 5 h (Colombia no tiene horario de verano). | **Sí.** Hoy el residente ve una fecha que parece del día siguiente. | Se muestra el texto UTC tal cual y **se quita la baldosa de fecha** (mostraría el día equivocado). |
| **D2** | Arreglar el bug de la descripción (H8): reemplazar `<!--DESC-->` en `app.py` con la descripción escapada. Técnicamente cambia lo que ve el residente (aparece un texto que el administrador ya escribió). | **Sí**, en el paso 4, commit aparte. | La descripción sigue sin mostrarse; el comentario se deja. |
| **D3** | Etiqueta de estado por reunión (**Próxima** / **En curso** / **Finalizada**) calculada con datos existentes (`fecha_utc`, `duracion_min`, margen) en `listar_reuniones`. | **Sí**: ayuda a encontrar la reunión de hoy. No es funcionalidad nueva, es presentación de datos existentes. | Sin etiqueta; la baldosa de fecha basta. |
| **D4** | Corregir tildes y ortografía en todo el texto visible ("Reunión", "Contraseña", "Sesión", "Moderación", "¿Eliminar…?"), incluidas las cadenas de `app.py` que ve el usuario. Los mensajes de log no se tocan. | **Sí.** | Se mantienen sin tildes. |
| **D5** | "Cerrar sesión" pasa del pie del panel al menú de la cabecera (disponible en panel, QR y sala). | **Sí.** | Se queda como botón secundario (no rojo) al final del panel. |
| **D6** | Color de marca: **azul `#0066CC`** + **índigo `#5E5CE6`** en degradados; verde/ámbar/rojo solo para estados. | **Sí.** (Alternativa: verde-azulado como marca, si el conjunto tiene colores corporativos: decírmelo y recalculo contrastes.) | — |
| **D7** | Tema por defecto: **Automático** (sigue al sistema), con conmutador manual. | **Sí.** | Fijar uno por defecto. |
| **D8** | Aceptar que la sala mantenga el texto "[mano]", el alto de 560 px y los estados sin color (no se toca su JS). | **Sí** para esta fase; los cambios de JS, en una fase posterior con su propia prueba. | Habría que autorizar cambios mínimos en el JS de la sala. |
