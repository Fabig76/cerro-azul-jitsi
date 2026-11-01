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
| 4 | (ver git log) | `page_reunion.html` (M4), 404 y 410 como `.empty` en tarjeta, D1 (`fecha_txt`: hora de Colombia), `{{rol}}`="asistente" | 6.4 OK, interacciones residente 100 % OK (1 solo `/unirse` con triple toque), capturas | `auditoria/paso4-*.txt` |

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
