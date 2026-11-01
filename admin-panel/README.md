# Panel admin (Flask) — Cerro Azul Jitsi

`app/app.py`, servido por gunicorn en `admin:8081` (red Docker `jitsi`) y
publicado por Caddy en `https://meet.urbcerroazul.com` para las rutas
`/admin*`, `/reunion/*`, `/unirse`, `/healthz` y `/api/reuniones/*`.

Configuración: `instance/admin.env` (600, **nunca** en git; plantilla en
`instance/admin.env.example`) y el `.env` de Jitsi (montado de solo lectura,
de ahí salen `JWT_APP_SECRET`, `JWT_APP_ID`, `JWT_ACCEPTED_*`, `PUBLIC_URL`).
`admin.env` se lee **al arrancar**: tras editarlo,
`docker compose up -d --force-recreate admin`.

## Rutas

| Ruta | Quién | Para qué |
|---|---|---|
| `GET /healthz` | healthcheck | Siempre 200; `jwt_config_ok` dice si la config JWT es coherente |
| `/admin`, `/admin/login`, ... | admin con sesión | Crear/eliminar reuniones, QR |
| `GET /admin/reunion/<id>/sala` | admin con sesión | Jitsi embebido + controles de moderación |
| `GET /admin/reunion/<id>/moderador.json` | admin con sesión (navegador) | Token de moderador para embeber Jitsi |
| `GET /admin/reunion/<id>/entrar` | admin con sesión | Jitsi a pantalla completa como moderador |
| `GET /reunion/<slug>`, `POST /unirse` | público (QR) | Token de asistente |
| `POST /api/reuniones/<id>/token` | **servidor** de votacionph.us | Token de asistente o moderador (Fase 6) |

## `POST /api/reuniones/<id>/token` (API interna, Fase 6)

Servidor a servidor. **Nunca** se llama desde un navegador: la API key no
puede llegar al navegador. Ver `../integracion/README.md` y
`../docs/INTEGRACION-JITSI.md`.

### Autenticación

`Authorization: Bearer <API_KEY>`, comparada con `hmac.compare_digest`.
Dos claves en `instance/admin.env`:

| Variable | Puede pedir |
|---|---|
| `JITSI_API_KEY` | solo tokens de asistente (`moderador: false`) |
| `JITSI_API_KEY_ADMIN` | asistente **y** moderador |

- Mínimo 32 caracteres; una clave más corta se ignora (se registra
  `CONFIG API: ... se ignora` en el log). Generarlas en el servidor:
  `openssl rand -hex 32`.
- Si no hay **ninguna** clave válida, el endpoint responde `503` y no firma nada.
- Si las dos claves son iguales se registra un aviso (la de asistente podría
  pedir moderador).

### Petición

```http
POST /api/reuniones/7/token
Authorization: Bearer <JITSI_API_KEY>
Content-Type: application/json

{"nombre": "Ana Pérez", "apto": "302", "moderador": false}
```

| Campo | Tipo | Regla |
|---|---|---|
| `nombre` | string | obligatorio, 1..80 caracteres (tras recortar espacios) |
| `apto` | string | opcional, 0..20 caracteres |
| `moderador` | bool | opcional (por defecto `false`); `true` solo con `JITSI_API_KEY_ADMIN` |

El nombre visible en Jitsi es `Apto 302 - Ana Pérez` (o solo el nombre si no
hay apto), igual que en `/unirse`.

### Respuesta 200

```json
{
  "jwt": "eyJ...",
  "domain": "meet.urbcerroazul.com",
  "roomName": "asamblea-0123456789abcdef",
  "soyModerador": false,
  "exp": 1793520000,
  "participantId": "api-1a2b3c4d5e6f7a8b"
}
```

- El token se firma con `sign_jwt(sala, nombre_visible, mod=<bool>,
  exp=exp_reunion(r), pid=<nuevo en cada petición>)`: vence al fin previsto
  de la reunión + `JWT_EXP_MARGIN_MIN` (30 min por defecto).
- `participantId` es único por petición (`api-…` asistente, `admin-…`
  moderador): cada reconexión o pestaña es un participante distinto.
- Todas las respuestas llevan `Cache-Control: no-store`.

### Errores

Cuerpo JSON `{"error": "<código>", "motivo": "<texto en español>"}`.
Se comprueban en este orden (sin key válida no se revela si la reunión existe):

| HTTP | `error` | Cuándo |
|---|---|---|
| 503 | `api_no_configurada` | no hay `JITSI_API_KEY` ni `JITSI_API_KEY_ADMIN` |
| 401 | `no_autorizado` | sin `Authorization: Bearer` o key incorrecta |
| 400 | `datos_invalidos` | cuerpo no JSON, `nombre`/`apto` fuera de rango, `moderador` no booleano |
| 403 | `moderador_no_permitido` | `moderador: true` con la key de asistente |
| 404 | `reunion_no_existe` | id inexistente o reunión eliminada |
| 405 | `reunion_finalizada` | ya pasó el fin previsto + margen (no se firma un token muerto) |

Nota: `/unirse` usa 410 para "reunión finalizada"; la API usa 405 por
especificación de la Fase 6. Un `GET` a la ruta también da 405 (de Flask, en
HTML): distinguir por el `error` del JSON.

### Log

Una línea por petición, **sin el token ni la key**:

```
INFO api token id=7 origen=203.0.113.5 key=asistente pide_moderador=False -> 200 mod=False pid=api-…
WARNING api token id=7 origen=203.0.113.5 key=asistente pide_moderador=True -> 403 moderador sin key de admin
WARNING api token id=7 origen=203.0.113.5 -> 401 key ausente o incorrecta
```

`origen` es el primer valor de `X-Forwarded-For` (lo pone Caddy). Ver con
`docker logs jitsi-admin` o `instance/app.log`.

### Probar

```bash
# En el VPS (llega directo al contenedor, sin pasar por Caddy):
set -a; . /opt/jitsi-meet/admin-panel/instance/admin.env; set +a
curl -s -X POST http://127.0.0.1:8081/api/reuniones/1/token \
  -H "Authorization: Bearer $JITSI_API_KEY" -H 'Content-Type: application/json' \
  -d '{"nombre":"Prueba","apto":"000"}' | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("jwt",None); print(d)'
```

(El `pop("jwt")` evita dejar el token en la terminal o en el historial.)
