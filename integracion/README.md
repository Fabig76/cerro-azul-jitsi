# Integración Jitsi ↔ votacionph.us (Fase 6)

Archivos para que **votacionph.us** (`Fabig76/asambleas-virtuales`) embeba la
sala de audio/video de `meet.bytracking.net`. Jitsi es solo el canal de
audio/video: asistencia, votos y quórum viven en votacionph. Si alguien pierde
el audio, sigue pudiendo votar.

| Archivo | Qué es |
|---|---|
| `jitsi-cliente.js` | Cliente reutilizable (ES module, sin dependencias): `crearSalaJitsi(...)` |
| `ejemplo-votacionph.js` | Ejemplo mínimo de navegador: botón → token → sala → eventos |

Visión completa y pruebas: [`../docs/INTEGRACION-JITSI.md`](../docs/INTEGRACION-JITSI.md).
Referencia del endpoint: [`../admin-panel/README.md`](../admin-panel/README.md).

## Regla de oro

> **El token se firma en el servidor.** El navegador nunca ve
> `JWT_APP_SECRET` ni las API keys (`JITSI_API_KEY`, `JITSI_API_KEY_ADMIN`).
> Solo recibe el JWT de *esa* persona para *esa* sala.

## Qué necesita el backend de votacionph.us

1. **Variables de entorno** (en su `.env`, nunca en el repo ni en el JS):
   ```
   JITSI_PANEL_URL=https://meet.bytracking.net
   JITSI_API_KEY=<la key de asistente>
   JITSI_API_KEY_ADMIN=<la key de admin; solo si votacionph tiene administradores>
   ```
   Las keys las genera el operador del Jitsi en su servidor y se las pasa por
   un canal seguro (no por chat/correo en claro).
2. **Una ruta propia** para el navegador, con su sesión normal, p. ej.
   `POST /api/reuniones/:id/token` en votacionph. Esa ruta decide quién es la
   persona (nombre, apto, si es administradora) a partir de **su sesión**, no
   de lo que mande el navegador, y llama al panel:

   ```js
   // Node 18+ (fetch nativo). Express como ejemplo.
   app.post('/api/reuniones/:id/token', requiereSesion, async (req, res) => {
     const u = req.user;                         // de la sesión de votacionph
     const esAdmin = u.rol === 'administrador';
     const r = await fetch(`${process.env.JITSI_PANEL_URL}/api/reuniones/${encodeURIComponent(req.params.id)}/token`, {
       method: 'POST',
       headers: {
         'Content-Type': 'application/json',
         Authorization: 'Bearer ' + (esAdmin ? process.env.JITSI_API_KEY_ADMIN
                                             : process.env.JITSI_API_KEY),
       },
       body: JSON.stringify({ nombre: u.nombre, apto: u.apto || '', moderador: esAdmin }),
       signal: AbortSignal.timeout(5000),
     });
     const datos = await r.json().catch(() => ({}));
     res.set('Cache-Control', 'no-store');
     if (!r.ok) {
       // No reenviar el detalle tal cual al navegador si no hace falta.
       console.warn('jitsi token', r.status, datos.error);
       return res.status(r.status === 405 ? 410 : 502).json({ error: datos.error || 'jitsi' });
     }
     res.json({ jwt: datos.jwt, roomName: datos.roomName,
                soyModerador: datos.soyModerador, domain: datos.domain });
   });
   ```
   - No guardar el JWT en la base de datos ni en logs.
   - El `id` es el id de la reunión **en el panel** de Jitsi (el que se ve en
     `/admin`). votacionph debe guardar esa correspondencia asamblea → id.
3. **Una ruta para los eventos** (opcional pero recomendada), p. ej.
   `POST /api/reuniones/:id/eventos-jitsi`, para la asistencia con hora.

Respuestas del panel: 200, 400 (datos), 401 (key), 403 (moderador sin key de
admin), 404 (reunión no existe), 405 (reunión finalizada), 503 (el panel no
tiene keys configuradas).

## Uso del cliente

```js
import { crearSalaJitsi } from './jitsi-cliente.js';

boton.onclick = async () => {               // SIEMPRE dentro de un clic
  const t = await pedirToken();             // a TU backend, no al panel
  const sala = crearSalaJitsi({
    dominio: 'meet.bytracking.net',
    roomName: t.roomName,
    jwt: t.jwt,
    soyModerador: t.soyModerador,
    contenedor: document.getElementById('jitsi'),
    onEvento: (nombre, datos) => { /* ver tabla */ },
    obtenerToken: pedirToken,               // token nuevo en cada reconexión
  });
  // sala.ejecutar('askToUnmute', participantId)  (vista de administrador)
  // sala.dispose()                              (al salir de la página)
};
```

Lo que hace por ti:

- Crea el iframe **solo** al llamar a la función. En celular, sin un gesto
  previo del usuario, el navegador bloquea el audio: llámala desde el clic de
  "Entrar a la asamblea" (puedes adelantar la descarga con
  `cargarApiJitsi(dominio)` al cargar la página; eso no crea el iframe).
- `configOverwrite`: barra de admin o de asistente (mismas listas que el
  panel), `disableDeepLinking: true` (sin esto el celular manda a "instala la
  app"), `prejoinConfig: {enabled: false}`, micrófono y cámara apagados al
  entrar, `lang: 'es'`.
- Si es moderador: activa la moderación de audio y video al entrar (igual que
  `/admin/reunion/<id>/sala`).
- Reconexión: ver abajo.

## Eventos (`onEvento(nombre, datos)`)

| Evento | Para qué sirve | Quién debe enviarlo al backend |
|---|---|---|
| `videoConferenceJoined` | **Asistencia con hora de entrada** (`datos.id` = participantId en Jitsi) | cada cliente, el suyo |
| `videoConferenceLeft` | Hora de salida (también salta en cortes: si llega `reconectando` después, no es una salida real) | cada cliente, el suyo |
| `participantJoined` / `participantLeft` | Lista de presentes en la vista del admin | **solo el cliente del administrador** (si no, 500 clientes × 500 eventos) |
| `raiseHandUpdated` | **Cola de "mano levantada"**: `datos.handRaised` es un timestamp (orden de la cola) o `0` al bajarla | solo el administrador |
| `errorOccurred` | Diagnóstico; si `datos.isFatal`, dispara la reconexión | log |
| `reconectando` *(propio)* | `{intento, maximo, causa}`: mostrar "Reconectando… tu voto sigue funcionando" | — |
| `reconexionAgotada` *(propio)* | Tras 5 intentos: avisar y ofrecer recargar; el voto sigue funcionando | log |
| `colgado` *(propio)* | El usuario pulsó colgar (no se reconecta) | cada cliente, el suyo |
| `aviso` *(propio)* | `{texto}`: el texto de estado actual (vacío = sin aviso) | — |

**Reconexión:** ante `errorOccurred` fatal o `videoConferenceLeft` sin que el
usuario haya colgado, el cliente avisa "Reconectando", espera 3 s, pide un
token nuevo con `obtenerToken` y recrea el iframe. Máximo 5 intentos
seguidos (el contador vuelve a 0 al entrar bien); si se agotan, avisa y para.
Los cortes cortos de red los recupera Jitsi solo sin cerrar la conferencia: en
ese caso no hay recreación.

Vista del administrador (con `sala.ejecutar`): `askToUnmute` (dar la palabra:
le pide al asistente activar el micro), `approveVideo` (habilitar cámara),
`muteRemoteParticipant <id> 'audio'|'video'`, `muteEveryone 'audio'`.
Comandos verificados en `jitsi/web:stable-11031` (ver README raíz, Fase 2).

## Cabeceras: qué tiene que permitir cada lado

**meet.bytracking.net** (este repo, `infra/caddy/meet.bytracking.net.caddy`):
```
header Content-Security-Policy "frame-ancestors 'self' https://votacionph.us"
```
Solo `votacionph.us` (y el propio dominio) pueden embeber Jitsi. El panel
(`/admin*`, `/reunion/*`, `/api/...`) lleva `frame-ancestors 'none'`.

**votacionph.us** (su Caddyfile / su CSP) debe permitir **embeber** Jitsi:
```
Content-Security-Policy: ...; frame-src https://meet.bytracking.net; script-src ... https://meet.bytracking.net; ...
```
- `frame-src` (o `child-src`) con `https://meet.bytracking.net`: deja
  cargar el iframe.
- `script-src` con `https://meet.bytracking.net`: deja cargar
  `external_api.js`.
- Si tienen `Permissions-Policy`, debe permitir `camera`, `microphone`,
  `display-capture` y `autoplay` para `https://meet.bytracking.net`
  (p. ej. `microphone=(self "https://meet.bytracking.net")`).

> ⚠️ **No cambien su `frame-ancestors 'none'`.** `frame-ancestors` dice
> **quién puede embeber SU página** (protege a votacionph de clickjacking);
> no tiene nada que ver con lo que ella embebe. Para embeber Jitsi lo que
> cuenta es `frame-src`. Quitar `frame-ancestors 'none'` no arregla nada y
> abre un agujero.

Si la consola del navegador muestra *"Refused to frame
'https://meet.bytracking.net/' because an ancestor violates ... frame-ancestors"*
→ falta el cambio de **este** lado (Caddy de meet). Si muestra *"Refused to
frame ... because it violates ... frame-src"* → falta el cambio en
**votacionph**.
