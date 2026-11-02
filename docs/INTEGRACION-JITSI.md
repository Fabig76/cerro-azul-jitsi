# Integración Jitsi ↔ votacionph.us (Fase 6)

> **Estado (2-nov-2026): parcial.**
> - ✅ Hecho y desplegado: endpoint `POST /api/reuniones/<id>/token` en el panel,
>   cliente `integracion/jitsi-cliente.js`, esta documentación y la ruta
>   `/api/reuniones/*` en el Caddy del host (desde el 1-nov).
> - ⏳ Pendiente: que el portal votacionph.us use el cliente.
> - ⏳ Pendiente: aplicar `frame-ancestors 'self' https://votacionph.us` en el Caddy
>   del host. Está en el repo (`infra/caddy/meet.bytracking.net.caddy`) pero **no
>   aplicado en el host, a propósito**, hasta que el portal lo use (ver el final).

Jitsi (`meet.bytracking.net`) es solo el canal de audio/video. Quién entra,
con qué rol, la asistencia, los votos y el quórum los decide **votacionph.us**
(`Fabig76/asambleas-virtuales`). Si alguien pierde el audio, sigue votando.

Archivos: `integracion/` (cliente JS, ejemplo, README para el otro equipo),
`admin-panel/README.md` (referencia del endpoint),
`infra/caddy/meet.bytracking.net.caddy` (cabeceras).

## La regla de oro

> **El token se firma en el servidor.** El navegador nunca ve
> `JWT_APP_SECRET` ni las API keys. `JWT_APP_SECRET` vive solo en el `.env`
> de Jitsi (lo lee el panel); las API keys viven en `admin.env` del panel y
> en el `.env` del backend de votacionph. Al navegador solo llega el JWT de
> esa persona, para esa sala, que vence al fin de la reunión + 30 min.

## Flujo completo

```
 Navegador (votacionph.us)          Backend votacionph            Panel Jitsi (meet.../api)         Jitsi (Prosody)
 ─────────────────────────          ──────────────────            ────────────────────────          ───────────────
 1. clic "Entrar a la asamblea"
 2. POST /api/reuniones/7/token ──▶ 3. sesión → nombre, apto, rol
    (cookie de sesión, mismo           elige key (asistente/admin)
     origen; sin keys)              4. POST https://meet.bytracking.net/api/reuniones/7/token
                                       Authorization: Bearer <key> ─▶ 5. compara key (compare_digest)
                                       {"nombre","apto","moderador"}     valida datos, reunión activa
                                                                       6. sign_jwt(sala, "Apto 302 - Ana",
                                                                          mod, exp_reunion, pid único)
                                    ◀─ 7. {jwt, roomName, soyModerador, exp, participantId, domain}
 ◀─ 8. {jwt, roomName, soyModerador}
 9. crearSalaJitsi(...) → iframe https://meet.bytracking.net/<sala>#jwt=… ─────────────────────▶ 10. valida firma, iss,
                                                                                                       aud, room, nbf/exp;
                                                                                                       moderator:true → owner
11. eventos (videoConferenceJoined, raiseHandUpdated…) → onEvento → backend votacionph (asistencia, cola)
```

Puntos clave:
- Paso 2 va al **backend de votacionph**, nunca directo al panel.
- Paso 4 es servidor a servidor por HTTPS. Pasa por Caddy de meet
  (`/api/reuniones/*` → `admin:8081`).
- Paso 9: el JWT lo pone `external_api.js` en la URL del iframe. Con
  `stable-11031` tiene que ir en la query `?jwt=`: esta versión **ignora
  `#jwt=`** (por eso el panel lo pasó a la query en `4535fd9`). *A verificar*
  en la primera prueba real del iframe que la URL lleva `?jwt=`.
- El iframe se crea dentro del clic (paso 1): en celular, sin gesto previo,
  el navegador bloquea el audio.

## Los dos endpoints del panel que dan tokens a otro cliente

| Endpoint | Quién lo llama | Auth | Rol |
|---|---|---|---|
| `GET /admin/reunion/<id>/moderador.json` | **navegador** del admin del panel (mismo origen) | cookie de sesión del panel | siempre moderador |
| `POST /api/reuniones/<id>/token` | **servidor** de votacionph | `Authorization: Bearer <key>` | asistente; moderador solo con `JITSI_API_KEY_ADMIN` |

`moderador.json` sirve para páginas del propio panel. Para votacionph se usa
**la API interna**. Detalle completo (cuerpo, log): `admin-panel/README.md`.

### `POST /api/reuniones/<id>/token`

- **Auth:** `Authorization: Bearer <key>` (no `X-API-Key`).
- **Dos keys**, ambas en `admin.env` del panel y en el `.env` del backend de
  votacionph (valores: `<oculto>`, nunca en el repo):

| Variable | Puede pedir | Uso |
|---|---|---|
| `JITSI_API_KEY` | solo **asistente** (`moderador:false`) | la de uso normal |
| `JITSI_API_KEY_ADMIN` | asistente **y moderador** | solo para el administrador de la asamblea |

- **Cuerpo JSON:** `nombre` (obligatorio, 1–80 caracteres), `apto` (opcional,
  0–20), `moderador` (`true`/`false`).
- **Respuesta 200:** `{jwt, roomName, soyModerador, exp, participantId, domain}`.

| Código | Cuándo |
|---|---|
| **200** | Token emitido |
| **401** | Sin `Authorization` o key incorrecta |
| **403** | Se pide `moderador:true` con la key de asistente |
| 400 | JSON inválido, falta `nombre`, tipos incorrectos |
| 404 | La reunión no existe (solo se revela con key válida) |
| 405 | La reunión ya terminó |
| 503 | El panel no tiene ninguna key configurada |

Orden de comprobación en `app.py`: 503 → 401 → 400 → 403 → 404 → 405 (sin key
válida no se revela si una reunión existe).

Ejemplo de petición (desde un servidor):
```bash
curl -s -X POST https://meet.bytracking.net/api/reuniones/7/token \
  -H "Authorization: Bearer $JITSI_API_KEY" -H 'Content-Type: application/json' \
  -d '{"nombre":"Ana Pérez","apto":"302","moderador":false}'
```

## Uso del cliente `integracion/jitsi-cliente.js`

Módulo ES sin dependencias: carga `https://meet.bytracking.net/external_api.js` él
solo (`cargarApiJitsi`). La función principal es `crearSalaJitsi(opciones)`:

```js
import { crearSalaJitsi } from './jitsi-cliente.js';

boton.onclick = async () => {                       // dentro del clic: audio en móviles
  const t = await pedirTokenAMiBackend();           // tu backend llama a la API del panel
  const sala = crearSalaJitsi({
    dominio: t.domain, roomName: t.roomName, jwt: t.jwt,
    soyModerador: t.soyModerador,                   // barra de admin o de asistente
    contenedor: document.getElementById('jitsi'),
    onEvento: (nombre, datos) => enviarAMiBackend(nombre, datos),
    obtenerToken: pedirTokenAMiBackend,             // token nuevo en cada reconexión
  });
  // sala.ejecutar('askToUnmute', id) · sala.ejecutar('approveVideo', id) · sala.dispose()
};
```

- Si `soyModerador`, activa la moderación de audio y vídeo al entrar (igual
  que la sala del panel). Con eso, **para que un asistente comparta pantalla
  el moderador tiene que ejecutar `approveVideo` sobre él** (ver
  [`SOLUCION-PANTALLA.md`](SOLUCION-PANTALLA.md)).
- Ejemplo completo: `integracion/ejemplo-votacionph.js`. Guía para el otro
  equipo: `integracion/README.md`.

## Eventos y qué hacer con cada uno

| Evento | Qué hacer |
|---|---|
| `videoConferenceJoined` | Registrar **asistencia con hora de entrada** en votacionph (cada cliente, el suyo). Reinicia el contador de reconexión. Si es moderador, el cliente activa la moderación A/V. |
| `videoConferenceLeft` | Registrar hora de salida. Si el usuario no colgó, el cliente reconecta (si después llega `reconectando`, no fue una salida real). |
| `participantJoined` / `participantLeft` | Solo en el cliente del **administrador**: lista de presentes. No mandarlo desde los 500 asistentes. |
| `raiseHandUpdated` | Solo administrador: **cola de "mano levantada"** (`handRaised` = timestamp para ordenar, `0` = la bajó). Botones "Dar palabra" → `askToUnmute`, "Habilitar cámara" → `approveVideo`, "Silenciar a todos" → `muteEveryone`. |
| `errorOccurred` | Log. Si `isFatal`, el cliente reconecta. |
| `reconectando` *(cliente)* | Mostrar "Reconectando… tu voto sigue funcionando". |
| `reconexionAgotada` *(cliente)* | Tras 5 intentos: avisar, ofrecer recargar. |
| `colgado` *(cliente)* | El usuario colgó: no reconectar; registrar salida. |

**Reconexión:** errorOccurred fatal o videoConferenceLeft sin colgar →
"Reconectando" → a los 3 s token nuevo (`obtenerToken`) y iframe nuevo →
máximo 5 intentos seguidos → si se agotan, aviso y alto. Cada reconexión es un
`participantId` nuevo en Jitsi (el pid es único por petición): la asistencia
debe ligarse a la **persona de votacionph**, no al id de Jitsi.

## Cabeceras (iframe)

- meet.bytracking.net, vhost de Jitsi:
  `Content-Security-Policy: frame-ancestors 'self' https://votacionph.us`.
  Rutas del panel (`/admin*`, `/reunion/*`, `/unirse`, `/healthz`,
  `/api/reuniones/*`): `frame-ancestors 'none'` + `X-Frame-Options: DENY`.
- votacionph.us: `frame-src https://meet.bytracking.net` y
  `script-src … https://meet.bytracking.net`. Su `frame-ancestors 'none'`
  **se queda**: controla quién embebe a votacionph, no lo que ella embebe.
  Detalle en `integracion/README.md`.

## Cómo probar

### Consola del navegador (F12 en la página de votacionph)
- Sin errores `Refused to frame` (si aparece: `frame-ancestors` → Caddy de
  meet; `frame-src` → CSP de votacionph).
- Sin `Refused to load the script 'https://meet.bytracking.net/external_api.js'`
  (falta `script-src` en votacionph).
- Network: `POST /api/reuniones/<id>/token` va a **votacionph.us** (mismo
  origen), nunca a meet; la respuesta no contiene ninguna key.
- Al entrar: el `onEvento` del ejemplo registra `videoConferenceJoined`. No
  aparece la pantalla de "instala la app" ni el prejoin.
- `401`/`403` en el token → key equivocada en el `.env` de votacionph.

### Logs de Prosody (VPS)
```bash
docker logs --since 10m jitsi-prosody 2>&1 | grep -iE 'token|jwt|auth' | tail -30
```
- Entrada correcta: sin `Token ... not allowed`/`signature verification failed`.
- `signature verification failed` → el panel firma con otro `JWT_APP_SECRET`.
- `Token is expired` / `nbf` → reloj o reunión vencida.
- `room ... not allowed` → el `roomName` no coincide con el claim `room`.

### Logs del panel (VPS)
```bash
docker logs --since 10m jitsi-admin 2>&1 | grep 'api token'
```
Una línea por petición: `id`, `origen`, `key=asistente|admin`,
`pide_moderador`, resultado y `pid`. Nunca aparece el token ni la key.
`curl -s https://meet.bytracking.net/healthz` → `"jwt_config_ok": true`.

## Criterios de verificación de la Fase 6

En **Chrome escritorio**, **Chrome Android** y **Safari iPhone**:

- [ ] La persona entra desde votacionph con **un clic**, sin pantalla de
      "instala la app" ni prejoin.
- [ ] Oye al administrador.
- [ ] Levanta la mano; el administrador la ve en su cola (`raiseHandUpdated`).
- [ ] El administrador le da la palabra (`askToUnmute`) y la persona habla.
- [ ] Asistencia registrada en votacionph con hora de entrada y salida.
- [ ] **Corte de wifi 20 s**: la sesión se recupera sola (por Jitsi o por la
      reconexión del cliente, con aviso "Reconectando"); el voto sigue
      funcionando durante el corte.
- [ ] Un asistente no puede pedir token de moderador (403 con la key de
      asistente).
- [ ] Jitsi no se puede embeber desde otro dominio (prueba con un HTML local:
      la consola muestra `frame-ancestors`).

Estado a 2026-11-02: API desplegada y probada desde el VPS; la ruta
`/api/reuniones/*` está en el Caddy del host. Las pruebas en dispositivos reales
y el corte de wifi están **pendientes** (requieren la integración en votacionph).

## Paso manual pendiente: `frame-ancestors` en el Caddy del host

El Caddyfile del host (`/home/chatbotph/chatbotph/Caddyfile`, montado en el
contenedor `hermes-caddy`) lo edita el operador. Desde el 1-nov ya tiene
`/api/reuniones/*` en `@admin`. Lo que **falta, a propósito**, son las
cabeceras: `frame-ancestors 'self' https://votacionph.us` en Jitsi y
`frame-ancestors 'none'` + `X-Frame-Options: DENY` en el panel. Hasta
aplicarlas, cualquier sitio podría embeber Jitsi. Se aplicarán cuando
votacionph esté listo para probar el iframe.

> El Caddyfile del host es un bind de **fichero único**: hay que editarlo en
> sitio, conservando el inodo (sin `sed -i` ni editores que reemplacen el
> fichero), o el contenedor seguirá viendo el viejo.

```bash
ssh chatbotph
CF=/home/chatbotph/chatbotph/Caddyfile
cp -p "$CF" "$CF.bak.fase6.$(date +%Y%m%d_%H%M%S)"
# Editar EN SITIO: sustituir el bloque 'meet.bytracking.net { ... }' por el de
# /opt/jitsi-meet/infra/caddy/meet.bytracking.net.caddy (sin las lineas de
# comentario de cabecera si se prefiere). Despues:
docker exec hermes-caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
docker exec hermes-caddy caddy reload --adapter caddyfile --config /etc/caddy/Caddyfile
# Comprobar:
curl -sI https://meet.bytracking.net/ | grep -i content-security-policy
curl -sI https://meet.bytracking.net/admin/login | grep -iE 'content-security-policy|x-frame-options'
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://meet.bytracking.net/api/reuniones/1/token   # 401
# Rollback: cp -p "$CF.bak.fase6.<fecha>" "$CF" y el mismo validate + reload.
```

`caddy reload` recarga la config sin reiniciar el contenedor (no afecta a los
otros vhosts si el Caddyfile es válido; por eso el `validate` va antes).

Comprobar antes y después, desde el host de desarrollo (solo lectura):
`./scripts/sync-caddy.sh` → antes muestra el diff; después debe decir
`OK: el bloque del host coincide con el del repo`. **No usar `--apply`**
desde el host de desarrollo: hace `cat` de la ruta local del bloque *dentro*
del SSH remoto, donde ese fichero no existe (el `set -e` lo aborta antes del
`mv`, pero no aplica nada).
