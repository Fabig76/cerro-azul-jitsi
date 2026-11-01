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
| 0 | (este) | Scripts de verificación y capturas; spec versionado | Línea base local y de producción, capturas "antes" | `auditoria/paso0-*.txt` |

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
