# DISENO-AUDITORIA — Registro de la implementación del rediseño

Implementación del plan de la sección 7 de [`SPEC-DISENO.md`](SPEC-DISENO.md) (decisiones D1–D8
aprobadas). Cada paso es un commit propio. Evidencias en [`auditoria/`](auditoria/).

Herramientas de verificación (creadas en el paso 0):

- `scripts/verificar-panel-local.py` — construye la imagen del panel (árbol de trabajo o un `--ref`),
  la arranca en un contenedor local con contraseña de prueba y recorre **todo** el flujo con sesión:
  login (OK/fallo/`?next=`/rate limit), crear (sin CSRF → 403, sin título → 400), panel, QR (+PNG),
  pública, 404, `/unirse` (302 a Jitsi con `#jwt`, 400, 410), sala (ids, `.gl` = 6 `data-cmd`),
  `entrar`, `moderador.json`, API sin key (401), eliminar (CSRF malo → 403, bueno → 302), logout.
  Por página imprime el contrato (ids, forms con method/action/names/csrf, scripts, estilos,
  marcadores sin sustituir, referencias externas). Además: `<script>` de la sala byte a byte contra
  `0782429`, `theme.css` sin `url(http)`/`@import`, bloques `SYNC-DARK` idénticos.
- `scripts/capturas-panel.py` — Playwright/Chromium: 11 vistas × {360, 768, 1280 px} × {claro, oscuro},
  bloquea toda petición que no vaya al panel (lista las bloqueadas) y avisa de scroll horizontal.
  En la sala inyecta filas de participantes con el **mismo DOM** que crea `pintar()` (el JS real no se
  toca; Jitsi queda bloqueado).

## Resumen

| Paso | Commit | Qué cambió | Verificación | Evidencia |
|---|---|---|---|---|
| 0 | `399da6a` | Scripts de verificación y capturas; spec versionado | Línea base local y de producción, capturas "antes" | `auditoria/paso0-*.txt` |
| 1 | `921c42b` (+`eaf8470` scripts) | `static/theme.css` + `theme.js`, `/admin/static`, `ASSET_V`, `render_page(kind,width)`, `COPY` en Dockerfile, `<link>`/`<script>` en `tpl.html` | 6.4 OK; diff = solo `<link>`/`<script>` nuevos y estáticos 404→200; capturas ≈ iguales | `auditoria/paso1-*.txt` |
| 2 | `c32bed7` | `tpl.html` nuevo (appbar + menú con tema y cerrar sesión, banda pública, pie con conmutador, skip link, `<main id=contenido>`), sin `<style>`; páginas viejas envueltas en `.c.legacy` | 6.4 OK, interacciones 33/36 (3 fallos = marcado viejo de pasos 5-6), capturas | `auditoria/paso2-*.txt` |
| 3 | `aacd4e3` | `page_login.html` (tarjeta con marca, `.field` con `for`/`autocomplete`, botón con carga), error como `.alert--error role=alert`, helper `alerta()`, tildes del login | 6.4 OK (solo ids nuevos), interacciones login+tema 100 % OK, capturas | `auditoria/paso3-*.txt` |
| 4 | `66a8ef1` | `page_reunion.html` (M4), 404 y 410 como `.empty` en tarjeta, D1 (`fecha_txt`: hora de Colombia), `{{rol}}`="asistente" | 6.4 OK, interacciones residente 100 % OK (1 solo `/unirse` con triple toque), capturas | `auditoria/paso4-*.txt` |
| 4b | (ver git log) | D2: `<!--DESC-->` se sustituye por la descripción escapada (antes se reemplazaba un `{{descripcion}}` inexistente) | 6.4 OK: `<!--DESC-->` desaparece, descripción visible, `<script>` de la descripción sigue escapado | `auditoria/paso4b-verificacion.txt` |
| 5 | `1d77e4f` | Panel (lista con baldosa de fecha, D3, menú "⋯", diálogo de eliminar), D1 con "a. m./p. m." (espacios U+00A0), vista QR (QR grande, link completo, **Copiar**, **Descargar QR**) | 6.4 OK; interacciones panel+QR OK (1 fallo = sala aún vieja, 11 px) | `auditoria/paso5-*.txt` |
| 6 | `af53e26` | `page_sala.html` (solo marcado) + bloque CSS "page: sala" con el contrato JS; `<script>` idéntico byte a byte | 6.4 OK; script SHA-256 igual; JS real contra API simulado 23/23; **producción con 2 clientes reales OK** | `auditoria/paso6-*.txt` |
| 7 | `a9809f4` | Fuera la compatibilidad temporal (sección 8 de `theme.css`, `.c.legacy`, parámetro `legacy`) | 6.4 OK; interacciones 156/156 OK; capturas finales | `auditoria/paso7-*.txt`, `auditoria/paso6-7-*.txt` |
| Prod | `a9809f4` desplegado | `desplegar-panel.sh HEAD` (build + recreate solo `admin`) | `/admin/login`, `/healthz`, `theme.css`, `theme.js` 200; 5/5 healthy; `operational_bridge_count=1`; flujo con sesión y login real OK | `auditoria/paso5-7-produccion.txt` |

---

## Paso 0 — Red de seguridad

**Cambios:** `scripts/verificar-panel-local.py`, `scripts/capturas-panel.py`; se versionan
`docs/SPEC-DISENO.md`, `docs/SPEC-DISENO-mockups.md` y `loadtest/verificar-panel.py`.

**Verificación:**
- Producción coincide con `HEAD` (sha256 de `app.py`, las 6 plantillas y el `Dockerfile` idénticos en
  `/opt/jitsi-meet/admin-panel`). Stack 5/5 healthy.
- `loadtest/verificar-panel.py` contra producción → `auditoria/paso0-linea-base-prod.txt`
  (login 200, healthz 200, API sin auth 401).
- `scripts/verificar-panel-local.py --ref 0782429` → `auditoria/paso0-linea-base-local.txt`:
  **RESULTADO OK**. Confirma los bugs del spec: H7 (`'UTC UTC' en el panel: SI`) y H8
  (`marcadores: ['<!--DESC-->']`, `descripcion visible: no`). 13 atributos `style=` y 2 `<style>`.
- Capturas "antes" (66 PNG): a 360 px el link público de cada reunión desborda la tarjeta; botones de
  12 px; todo en azul marino fijo también con el sistema en modo claro.

## Paso 1 — Infraestructura de estáticos

**Cambios:**
- `admin-panel/app/static/theme.css` (sistema completo: tokens claro/oscuro con bloques `SYNC-DARK`,
  base, layout, los componentes de 3.4/3.4.13 y alias de compatibilidad `.legacy`/`.c .m .r .mt .ac .b .e .o .d .qr`
  más las variables viejas `--b --m --ok …` que usa el `<style>` en línea de la sala hasta el paso 6).
  Se adelantan aquí los componentes (no se usan aún) para que los pasos 2-6 solo añadan reglas de página.
- `admin-panel/app/static/theme.js` (tema temprano, conmutador, menús, carga de formularios, diálogo).
  Ocupa 5,3 KB con comentarios (el spec estimaba ≤ 3 KB); no afecta al contrato.
- `app.py`: `Flask(__name__, static_url_path="/admin/static")`, `ASSET_V = "20261101a"`,
  `render_page(t, body, kind, width)` sustituye las 7 llamadas a `render_template_string` (refactor mecánico
  permitido por 5.1). `kind`/`width` por ruta según M6.
- `Dockerfile`: `COPY app/static /app/static`.
- `tpl.html`: viewport con `viewport-fit`, `color-scheme`, dos `theme-color`, `<link>` y `<script>` con `?v=`;
  **conserva** su `<style>`.

**Verificación:**
- `verificar-panel-local.py` → **OK** (`auditoria/paso1-verificacion.txt`). `diff` con la línea base
  (`auditoria/paso1-diff.txt`): únicamente `theme.css`/`theme.js` 404 → 200 (`text/css`, `text/javascript`),
  +1 `<script src>` y +1 stylesheet por página. Mismos ids, forms, names, csrf, códigos HTTP.
  `<script>` de la sala IDÉNTICO. `SYNC-DARK`: 2 bloques idénticos (36 tokens). Sin `url(http)`/`@import`.
- `ruff check --isolated app.py`: 18 avisos antes y 18 después (todos preexistentes).
- Capturas `paso1` (66): aspecto prácticamente igual al de antes; a 360 px el link público ya no desborda.
  Única petición externa: `external_api.js` de la sala (dominio propio, esperado).

**Despliegue del paso 1 en producción** (adelantado para validar pronto la ruta de estáticos por Caddy):
- Punto de rollback: `backups/admin-panel-pre-rediseno-20261101T060401Z.tgz` (ficheros) y la imagen
  anterior etiquetada `jitsi-admin:pre-rediseno` (`7ce6040cbca1`). `scripts/desplegar-panel.sh --rollback`
  la restaura sin rebuild.
- `scripts/desplegar-panel.sh` → admin healthy; `/admin/login` 200, `/healthz` 200,
  `/admin/static/theme.css` **200 `text/css`**, `theme.js` 200 `text/javascript`. Caddy sin cambios.
- `scripts/verificar-panel-prod.py --login-imagen` → **OK** (`auditoria/paso1-produccion.txt`):
  - Sesión firmada con la clave del panel (no tengo la contraseña real): panel, crear reunión de prueba
    (id 12) → 302 QR, PNG, pública 200, 404, `/unirse` 302 a Jitsi con `#jwt`, sala 200 con los 6 ids y
    los 6 `data-cmd`, `moderador.json` 200, eliminar con CSRF → 302 y ya no aparece; API sin key 401.
  - Login **real** (usuario + contraseña + `?next=`) con la imagen desplegada en un contenedor temporal
    del VPS (contraseña de prueba, puerto 18091 por túnel ssh, borrado al terminar): contraseña mala → error
    visible; correcta → 302 `/admin`; crear con CSRF → 302.

## Paso 2 — Layout + tema

**Cambios:**
- `tpl.html` reescrito según 4.1: `<title>{{ t }} · Cerro Azul</title>`; `body.page.page--{kind}.page--{width}`;
  skip link; `kind=admin` → `.appbar` (marca SVG en línea + menú `<details>` con control segmentado de tema y
  **Cerrar sesión**, D5); `kind=public` → banda `.hero` con la marca; `kind!=admin` → pie con `.theme-cycle`.
  **Se elimina el `<style>`**. Los controles de tema llevan `hidden data-js-only` y `theme.js` los muestra:
  sin JS no aparece un botón que no hace nada (el tema sigue al sistema por CSS).
- El menú no lleva `role="menu"` (el spec lo sugería): contiene un grupo de botones y un formulario, y
  `role="menu"` obligaría a navegación con flechas que no existe; `<details>` ya se anuncia como desplegable.
- `render_page(..., legacy=True)`: las páginas aún no migradas se envuelven en `<div class="c legacy">`;
  cada paso pone `legacy=False` en lo que migra. El botón "Cerrar sesión" del panel se mantiene (D5 dice que
  se quita en el paso 5), por lo que en este paso hay dos formularios de logout en el panel.
- `theme.css`: marca, `[hidden]`, corrección de `.legacy button.d` (salía azul) y sombra del skip link oculto
  (asomaba como una mancha en la banda). `ASSET_V = 20261101b`.

**Verificación:**
- `verificar-panel-local.py` → **OK**. Diff con el paso 1 (`auditoria/paso2-diff.txt`): ids nuevos
  `contenido`, `apariencia-t`; +1 form `POST /admin/logout` y +4 botones (menú/tema) en páginas de admin,
  +1 botón (tema) en públicas; `<style>` 1 → 0 en todas salvo la sala (su `<style>` propio, paso 6).
  Sala: 6 ids y 6 `data-cmd` intactos; `<script>` IDÉNTICO.
- `scripts/probar-interacciones.py` (nuevo; `auditoria/paso2-interacciones.txt`): tema auto/claro/oscuro,
  persistencia entre páginas, **tema aplicado antes de crear `<body>`** (sin parpadeo), `theme-color`, ciclo del
  pie, `aria-label`, `localStorage` bloqueado sin errores; skip link (primer Tab, visible, salta a `#contenido`);
  menú con Enter, Esc devuelve el foco, clic fuera cierra; anillo de foco de 3 px; sin scroll horizontal
  a 360/768/1280 en las 5 páginas. **3 fallos esperados** del marcado viejo: `<code>` a 10,5 px en el panel,
  campo del link del QR a 12 px y `#log` a 11 px en la sala (pasos 5 y 6).
- Capturas `paso2`: cabecera translúcida, menú abierto, banda de degradado en la pública con la tarjeta
  superpuesta, aurora del login en oscuro. La prueba de 44 px detectó que la animación `pop` (`scale .96`)
  falseaba la medida: se mide `offsetHeight`.
- Nota de método: `rate_login` cuenta también los logins correctos (5 por IP / 15 min); entre tandas de
  pruebas se reinicia el contenedor local.

## Paso 3 — Login

**Cambios:** `page_login.html` según M1 (marca en círculo con degradado, `h1` "Cerro Azul", subtítulo, campos
`.field` con `id`/`for`, `autocomplete="username"`/`"current-password"`, `autocapitalize="off"`,
`spellcheck="false"`, botón `btn--primary btn--lg btn--block` con `data-loading`, nota "Acceso restringido…").
Contrato intacto: `<!--ERR-->`, `<form method="post">` **sin `action`**, `name="user"`/`"password"`, `required`,
`autofocus`. `app.py`: helper `alerta(tipo, titulo, texto, role)` + iconos SVG en línea; el error del login usa
`alerta("error", err, role="alert")` (err es siempre constante del código); "contraseña" con tilde (D4);
título de pestaña "Iniciar sesión · Cerro Azul"; `legacy=False`. CSS `/* page: login */`. `ASSET_V=…c`.

**Verificación:**
- 6.4 → **OK**; diff con el paso 2 = solo ids `f-user`, `f-password`, `login-t` en las dos vistas de login.
  Se mantienen: login OK → 302 a `?next`, fallo → error visible, rate limit → "Demasiados intentos".
- Interacciones (`auditoria/paso3-interacciones.txt`, todo OK): sin sesión → login con `?next=/admin/qr/1`;
  form sin `action`; autofocus en usuario; `autocomplete` correcto; pulsar cada etiqueta enfoca su campo;
  error = `.alert--error[role=alert]` con el texto; el `?next` sobrevive al error; el login correcto vuelve a
  `/admin/qr/1`; al enviar el botón queda `aria-busy=true` y `disabled`.
- Capturas `paso3` (login y login-error, claro/oscuro, 360/768/1280): coinciden con M1; la vista de 1280 en
  la tanda de error muestra el mensaje de rate limit con el mismo aviso. Sin peticiones externas.

## Paso 4 — Páginas del residente (D1)

**Cambios:**
- `app.py`: D1 → `TZ_COL` (UTC−5 fijo), tablas `DIAS`/`MESES` propias, `fecha_col()`, `hora_12()` ("7:00 p. m."),
  `fecha_txt(fecha_utc, anio=False)` ("mar 3 nov · 7:00 p. m."); si la fecha no se puede leer devuelve el texto
  original. Comprobado: `2026-11-04 00:00 UTC` → `mar 3 nov · 7:00 p. m.`; `2026-10-31 20:09 UTC` →
  `sáb 31 oct · 3:09 p. m.`; `basura` → `basura`. La BD y los tokens no cambian.
- `reunion_publica()`: `{{fecha_utc}}` recibe `fecha_txt(...)` (mismo marcador, otro valor, como dice 4.4/4.5);
  `{{rol}}` = "asistente" (se muestra "Entras como asistente"). `legacy=False`.
- 404 y 410: helper `vacio(icono, título, texto, h1)` con iconos SVG en línea, dentro de `.card--sheet`;
  textos con tildes; títulos de pestaña "Reunión no encontrada"/"Reunión finalizada". `pagina_finalizada`
  sigue siendo la misma para `/unirse`, `/sala` y `/entrar` (como prevé 4.5).
- `page_reunion.html` según M4: eyebrow "Estás invitado", `h1`, chips de fecha/duración con icono,
  `.alert--info role=note`, campos con `for`/`id`, `autocomplete="off"`/`"name"`, `autocapitalize`,
  `enterkeyhint="go"`, botón `btn--lg btn--block` con `data-loading`. Contrato intacto: `{{titulo}} {{rol}}
  {{fecha_utc}} {{duracion}} <!--DESC--> {{slug}}`, `form POST /unirse` con `slug`/`apto`/`nombre`.
- CSS `/* page: reunión pública */`. `ASSET_V=…d`. Ruff: 18 = base (se evitaron 2 avisos nuevos).

**Verificación:**
- 6.4 → **OK**; diff = ids `f-apto`, `f-nombre`, `reunion-t` en la pública. `/unirse` sigue → 302 a Jitsi con
  `#jwt`, 400 sin nombre, 410 en reunión pasada; 404 en slug inexistente.
- Interacciones (`auditoria/paso4-interacciones.txt`): sin "UTC" en la página; fecha en hora de Colombia;
  etiquetas enfocan su campo; botón 52 px a ancho completo; `autocomplete`/`enterkeyhint`; **triple toque en
  "Entrar a la reunión" → 1 solo POST `/unirse`** (antes podía emitir varios tokens); 404 con `h1` y título.
  A 360 px la pública cumple texto ≥ 12, campos ≥ 16, controles ≥ 44. Fallos restantes = los 3 conocidos de
  páginas aún no migradas.
- Capturas `paso4` (pública, 404, 410 × claro/oscuro × 3 anchos): coinciden con M4.

## Paso 4b — D2: descripción visible al residente (commit aparte)

**Cambio:** `reunion_publica()` reemplaza `<!--DESC-->` por `<p class="reunion__desc">` + `escape_html(descripción)`
(o nada si está vacía). Se elimina el `replace("{{descripcion}}", …)` que no hacía nada. `white-space: pre-line`
respeta los saltos de línea que escriba el administrador. El verificador deja de tratar `<!--DESC-->` como
excepción: ahora cualquier marcador sin sustituir es fallo.

**Verificación:** diff 6.4 contra el paso 4 = exactamente dos líneas: `marcadores: ['<!--DESC-->'] → ninguno`
y `descripcion visible: no → si`. La reunión de prueba lleva `<script>x</script>` en la descripción:
`"<script> de la descripcion sin escapar: no"` (se muestra como texto). Captura `paso4b/publica-dark-360.png`:
la descripción aparece entre los chips y el aviso, como en M4.

---

## Paso 5 — Panel y vista QR (D1, D3)

**D1 confirmado.** La hora de Colombia ya estaba en `fecha_txt()` (paso 4): UTC-5 fijo (Colombia no tiene
horario de verano), días y meses de tablas propias (`DIAS`, `MESES`), sin `locale`. En la lista sale, por ejemplo,
`mar 5 nov · 7:00 p. m. · 60 min`. **Por qué no se veía "a. m./p. m." con grep:** `hora_12()` separa con
espacios de no separación (U+00A0, para que "p. m." no se parta en dos líneas), así que buscar `"p. m."` con
espacios normales no encuentra nada. Comprobación sobre el HTML real (U+00A0 mostrado como `⍽`):

```
$ curl -s -b cj http://127.0.0.1:18090/admin | grep -o 'list__meta num">[^<]*' | sed 's/\xc2\xa0/⍽/g'
list__meta num">mar 5 nov · 7:00⍽p.⍽m. · 60 min
```

La prueba `probar-interacciones.py` lo comprueba con `\s` en la regex (pública) y normalizando U+00A0 (panel):
`meta en hora de Colombia` → OK ("jue 4 mar · 6:30 p. m." para 2021-03-04 18:30 Colombia).

**Vista QR:** lo que faltaba: botón **Copiar** (mejora progresiva en `theme.js`: `navigator.clipboard` con
respaldo `execCommand`, texto "Copiado" 2 s y anuncio `aria-live`; sin JS queda oculto y sigue funcionando
"tocar para seleccionar"), **Descargar QR** (`?format=png` con `download`), y el **link completo** en Detalles
con ajuste de línea (en 360/768 el campo lo truncaba: visto en capturas y corregido). El campo se mantiene en
16 px (una primera versión a 14 px la detectó la prueba "anti-zoom iOS" y se revirtió).

## Paso 6 — Sala de moderación (D8: JS intacto)

- Marcado nuevo según M5; el `<style>` en línea pasa a `theme.css` ("page: sala"). Los 6 botones siguen
  dentro de `.gl` con su `data-cmd` y ningún otro `<button>` entra en `.gl`. Textos cortos ("Dar a todos",
  "Micrófonos", "Activar"…) con `aria-label` completo.
- Las clases que crea el JS (`div.p`, `div.n`, `span.mano`, `p.m`, botones `ok2`/`d`/sin clase) se
  re-visten bajo `#lista` (reglas permanentes). Fila con mano: fondo `--warn-soft` + barra de 3 px
  (`:has(.mano)`). Botones por participante en rejilla 2 × 2 (móvil y panel lateral) o fila de 4 (tablet).
- Ajustes hechos tras **mirar las capturas**: botones por participante escalonados en 3 filas → rejilla;
  "Silenciar a todos" partido en dos líneas → "Micrófonos"/"Cámaras" bajo "SILENCIAR"; recuadro del video
  sin borde en oscuro → anillo `--border`; textos apretados en 32 px → relleno vertical.
- **Script byte a byte** (`auditoria/paso6-script-sala.txt`): SHA-256 `64da205a…d654` antes (`6e7c7c5`) y
  después (HEAD); `diff` vacío.
- **Local, JS real contra un `JitsiMeetExternalAPI` simulado** (grupo `sala_js`, 23 comprobaciones): al
  unirse activa moderación A/V; `#st-*` = ACTIVA; B aparece en `#lista`; `#cnt`=(1); mano → `span.mano`
  "[mano] "; cada botón por participante manda su comando (`askToUnmute`, `muteRemoteParticipant`
  audio/video, `approveVideo`); los 6 `.gl` mandan los suyos; "Dar a todos" → `#st-audio` "apagada";
  `#log` registra; al salir B → `p.m` "Nadie mas en la sala."; sin errores de JS.
- **Producción, dos clientes reales** (`scripts/probar-sala-prod.py`, `auditoria/paso6-produccion-dos-clientes.txt`,
  19 OK): A = administrador en la sala rediseñada, B = residente por el link público. Moderación A/V activa
  al entrar; B en la lista; B moderado (no puede hablar); mano de B → "[mano]"; "Dar a todos" → B libre;
  "Quitar a todos" → B moderado otra vez; "Silenciar" → `#log`; Desactivar/Activar → estados; B cuelga →
  lista vacía; reunión de prueba borrada. Captura: `capturas-rediseno/prod-sala-dos-clientes-*-1280.png`.

## Paso 7 — Fin de la compatibilidad temporal

Se borran la sección 8 de `theme.css`, el envoltorio `.c.legacy` de `tpl.html` y el parámetro `legacy` de
`render_page`. Antes se comprobó con grep que ninguna plantilla, `app.py` ni `theme.js` usa ya
`.c .r .mt .ac .b .e .o .qr .legacy` ni las variables de una letra. Verificación: 6.4 OK y 156/156 en
interacciones (`auditoria/paso6-7-*.txt`).

## Despliegue a producción (2026-11-01, 06:5x UTC)

1. Comprobación previa: 0 conferencias activas (jicofo `/stats`), 5/5 healthy, `operational_bridge_count=1`.
2. Imagen de vuelta atrás: `jitsi-admin:local` → etiqueta **`jitsi-admin:pre-paso5`** (`c456c4a`, = `6e7c7c5`).
3. `scripts/desplegar-panel.sh HEAD` (`a9809f4`): copia `admin-panel/`, `docker compose build admin`,
   `up -d --force-recreate admin`. No se tocó Caddy ni otros servicios.
4. Resultado (`auditoria/paso5-7-produccion.txt`): `/admin/login` 200, `/healthz` 200,
   `/admin/static/theme.css` 200 (`?v=20261101m`), `theme.js` 200; 5/5 healthy; `operational_bridge_count=1`.
5. `verificar-panel-prod.py --login-imagen` → **OK**: flujo con sesión (panel, crear, QR + PNG, pública,
   404, `/unirse`, sala con los 6 ids y 6 `data-cmd`, `moderador.json`, eliminar) y **login real** (POST
   usuario/contraseña → 302, contraseña mala → error visible) contra la imagen desplegada en un contenedor
   temporal del VPS con contraseña de prueba (no se usa la contraseña del administrador).
6. Prueba con dos clientes reales (arriba): OK.

Vuelta atrás si hiciera falta: `ssh chatbotph 'cd /opt/jitsi-meet && sudo docker tag jitsi-admin:pre-paso5
jitsi-admin:local && sudo docker compose up -d --no-build --force-recreate admin'`.

## Hallazgo previo al rediseño: el residente no entra con `#jwt=` (RESUELTO en `4535fd9`)

> **Resuelto el 1-nov-2026:** el usuario aprobó el cambio y `jitsi_url()` manda ahora el token en `?jwt=` (commit `4535fd9`). Se acepta que quede en los logs de Caddy porque caduca. Lo de abajo es el registro del hallazgo.

Durante la prueba con dos clientes, B (que entra por `/reunion/<slug>` → `/unirse`) recibía en Jitsi
**"Se requiere autenticación"**. Con **el mismo token** pasado como `?jwt=` entra sin problema:

```
hash  unido: False  jwt en el store: False
query unido: True   jwt en el store: True
```

`jitsi_url()` pone el token en el fragmento desde la Fase 1 (`6388f2e`, ver `SETUP_HISTORY.md`), y el
rediseño **no lo ha tocado** (diff vacío de `jitsi_url`/`unirse` desde `399da6a`); el cliente web
stable-11031 solo lee el JWT de la query. Afecta a `/unirse` (residente) y a `/admin/reunion/<id>/entrar`;
**no** a la sala de moderación ni a votacionph.us (usan `external_api.js`, que pasa el `jwt` por su API).
No se cambia en esta tanda porque el fragmento fue una decisión de seguridad (el token en la query viaja al
servidor y puede quedar en logs/Referer) y la elección corresponde al usuario. Para la prueba de moderación,
B usó ese mismo token en `?jwt=` (el guion lo marca como AVISO).

## Tabla de modificaciones (pasos 5–7)

| # | Archivo | Qué se cambió | Cómo se verificó | Evidencia |
|---|---|---|---|---|
| 1 | `admin-panel/app/app.py` | `hora_12()`: "a. m./p. m." con U+00A0 | HTML real con curl; regex en interacciones (pública y panel) | este doc (paso 5), `paso5-interacciones.txt` |
| 2 | `admin-panel/app/app.py` | `estado_reunion()` (D3), `listar_reuniones()` como `.list` con baldosa, badge, "Moderar", "Ver QR", menú "⋯" y eliminar con `data-confirm` + `onclick` de respaldo | 6.4 (forms/csrf de eliminar), interacciones D3, menú con teclado, diálogo (Cancelar/Esc/Eliminar) y sin JS (`confirm()`) | `paso5-verificacion.txt`, `paso5-interacciones.txt`, `M-panel-*.png`, `M-panel-menu-*.png`, `M-panel-dialogo-*.png` |
| 3 | `admin-panel/app/app.py` | `qr_view()`: fecha con `fecha_txt(..., anio=True)`; `panel()`: aviso JWT con `alerta()` | 6.4; "sin 'UTC' en la vista QR" | `paso5-*.txt` |
| 4 | `admin-panel/app/page_panel.html` | Cabecera "Reuniones", lista + formulario (`.field`, `for`/`id`), mismo `<form action=/admin/reunion>` con sus 6 campos | 6.4 (names del form idénticos); etiquetas enfocan su campo; 1280 px formulario fijo; 360 px lista antes que formulario | `paso5-*.txt`, `panel-*-{360,768,1280}.png` |
| 5 | `admin-panel/app/page_qr_view.html` | Cabecera de confirmación, `.qrcard`, `<dl class="kv">` con link completo, campo + **Copiar**, **Descargar QR**, consejo `.alert--info` | Interacciones: QR blanco en oscuro, nítido, 2 columnas a 768, clic selecciona, Copiar → portapapeles + "Copiado" + aria-live, sin JS oculto, PNG, impresión | `paso6-7-interacciones.txt`, `qr-*-{360,768,1280}.png` |
| 6 | `admin-panel/app/static/theme.js` | Botón `[data-copy]` (portapapeles con respaldo) | Interacciones "Copiar …" (4 comprobaciones) | `paso6-7-interacciones.txt` |
| 7 | `admin-panel/app/page_sala.html` | Marcado M5; sin `<style>`; `<script>` sin tocar | SHA-256 igual; 6.4 "ids sala: todos", ".gl buttons: 6"; `sala` + `sala_js` locales; 2 clientes en prod | `paso6-script-sala.txt`, `paso6-7-*.txt`, `paso6-produccion-dos-clientes.txt`, `sala-*.png`, `M-sala-cargando-*.png`, `prod-sala-dos-clientes-*.png` |
| 8 | `admin-panel/app/app.py` | `sala_moderacion()`: título "Moderación · …", sin `legacy` | 6.4 sala 200 | `paso6-7-verificacion.txt` |
| 9 | `admin-panel/app/static/theme.css` | Bloques "page: panel", "page: qr" (+ `.copyfield`, `.qrview__url`), "page: sala" (contrato JS permanente) | Capturas 360/768/1280 × claro/oscuro revisadas; sin scroll horizontal; tamaños ≥ 12 px / campos ≥ 16 px / controles ≥ 44 px táctil | `capturas-rediseno/`, `paso6-7-interacciones.txt` |
| 10 | `admin-panel/app/static/theme.css`, `tpl.html`, `app.py` | Paso 7: fuera la compatibilidad temporal y `legacy` | grep sin usos; 6.4 OK; 156/156 | `paso7-diff.txt`, `paso6-7-*.txt` |
| 11 | `admin-panel/app/app.py` | `ASSET_V` → `20261101m` (rompe caché de `theme.css`/`theme.js`) | `?v=20261101m` en producción | `paso5-7-produccion.txt` |
| 12 | `scripts/probar-interacciones.py` | Grupos `panel`, `qr` (+Copiar/Descargar/sin JS), `sala`, `sala_js` (API simulado) | Se ejecutan: 156 OK | `paso6-7-interacciones.txt` |
| 13 | `scripts/probar-sala-prod.py` (nuevo) | Prueba de moderación en producción con 2 clientes reales; crea y borra su reunión | Ejecutado: OK (1 AVISO = hallazgo `#jwt`) | `paso6-produccion-dos-clientes.txt` |
| 14 | `docs/capturas-rediseno/` | 30 capturas (5 páginas × 3 anchos × 2 temas), 22 montajes (11 vistas) y 2 de producción | Revisadas una a una (ver abajo) | — |

### Cambios posteriores al rediseño en la sala (2-nov-2026, fuera de esta auditoría)

| Commit | Archivo | Qué se cambió | Cómo se verificó |
|---|---|---|---|
| `740da81`, `4193357`, `cbc4b47` | `page_sala.html` (barra `#manos-bajar` + `#manos-estado`, fuera de `#lista` y `.gl`), `static/bajar-manos.js` (nuevo) | Botones «Bajar todas las manos» y «Bajar la mano» por persona. El `<script>` congelado de la sala **no cambia** | `scripts/verificar-bajar-manos.py` (local, Jitsi simulado) y `scripts/probar-bajar-manos-prod.py` (producción, dos residentes reales: baja una, bajan todas, el botón vuelve a gris, la vía por el videobridge no baja ninguna). Confirmado por el operador en asamblea. Detalle: [`MODERACION-MANOS.md`](MODERACION-MANOS.md) |

## Revisión visual (capturas finales, `docs/capturas-rediseno/`)

Generadas con `scripts/capturas-panel.py` (Chromium; toda petición fuera del panel bloqueada → la única
bloqueada es `external_api.js` de la sala, esperado) y comprimidas a 256 colores. Revisadas en los montajes
`M-<vista>-<tema>.png` (360 | 768 | 1280):

| Página | Claro | Oscuro | Observaciones |
|---|---|---|---|
| Login | `M-login-light.png` | `M-login-dark.png` | Tarjeta centrada, foco visible, aviso legible; sin cortes. |
| Panel | `M-panel-light.png` | `M-panel-dark.png` | 360: acciones bajo cada reunión, títulos largos con elipsis; 1280: lista + formulario fijo. "7:00 p. m." en una línea. El aviso JWT rojo es propio del contenedor local (sin Prosody). |
| QR | `M-qr-light.png` | `M-qr-dark.png` | QR en tarjeta blanca también en oscuro; link completo legible en los 3 anchos (corregido); Copiar/Descargar/Volver. |
| Pública | `M-publica-light.png` | `M-publica-dark.png` | Tarjeta sobre la banda, botón a ancho completo, fecha en hora de Colombia. |
| Sala | `M-sala-light.png`, `M-sala-cargando-light.png` | `M-sala-dark.png`, `M-sala-cargando-dark.png` | 360/768: una columna (video 560 px arriba); 1280: video + panel lateral; fila con mano destacada; esqueleto + "Conectando…" antes de Jitsi. |
| Sala (producción) | `prod-sala-dos-clientes-light-1280.png` | `prod-sala-dos-clientes-dark-1280.png` | Jitsi real con B y su mano levantada. |
