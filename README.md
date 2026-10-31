# Cerro Azul - Jitsi Meet

> ## Estado (verificado 31-Oct-2026)
> - ✅ `https://meet.urbcerroazul.com/` responde 200
> - ✅ El bloque de Caddy **persistido en el Caddyfile del host** y verificado
>    tras un `docker restart` completo del contenedor (prueba de persistencia)
> - ✅ `monitorlegal.org` y `minutasegura.com` siguen en 200
> - ✅ Bridge operativo (`operational_bridge_count: 1`), JVB `/about/health` = 200
>
> **Versión:** Jitsi `stable-11031` (JVB 2.3.295)
> **URL:** https://meet.urbcerroazul.com

Plataforma de videoconferencias self-hosted para el Conjunto Residencial Cerro Azul, corriendo en `meet.urbcerroazul.com`.

## Stack

- **Jitsi Meet** stable-11031 (web + prosody + jicofo + jvb)
- **Admin Panel** Flask + Gunicorn para crear reuniones y generar QR
- **Caddy** reverse proxy (existente) sirve HTTPS con Let's Encrypt

## Arquitectura

```
Internet
    |
    v
[Caddy :443] ── meet.urbcerroazul.com
    |
    +── /admin/*        ──> [jitsi-admin:8081]   (Flask/Gunicorn)
    +── /reunion/*      ──> [jitsi-admin:8081]   (Flask/Gunicorn)
    +── /unirse         ──> [jitsi-admin:8081]   (Flask/Gunicorn)
    +── /healthz        ──> [jitsi-admin:8081]   (Flask/Gunicorn)
    +── todo lo demas   ──> [jitsi-web:80]        (Nginx + Jitsi Meet UI)
    |
    |
[VPS Chatbotph 84.247.165.81]
    |
    +-- [Docker Network: jitsi-meet_jitsi]
    |   +-- jitsi-web       :80 (interno, proxy via Caddy)
    |   +-- jitsi-prosody   :5222 :5347 :5280 (XMPP server)
    |   +-- jitsi-jicofo    :8888 (conference focus)
    |   +-- jitsi-jvb       :8080 :9090 :10000/udp :4443 (video bridge)
    |   +-- jitsi-admin     :8081 (Flask admin panel)
    |
    +-- [Firewall UFW]
    |   +-- 80/tcp      (HTTP)
    |   +-- 443/tcp     (HTTPS)
    |   +-- 10000/udp   (RTP media - JVB)
    |   +-- 4443/tcp    (fallback RTP)
    |   +-- 80/tcp, 443/tcp  (Caddy reverse proxy)
```

## Quick Start

### Prerrequisitos

- VPS con Docker + Docker Compose
- Dominio con DNS apuntando al VPS (registro A para `meet.tu-dominio.com`)
- Puertos abiertos: 80, 443 (TCP), 10000 (UDP), 4443 (TCP)

### Instalación

```bash
# 1. Clonar el repo
git clone git@github.com:Fabig76/cerro-azul-jitsi.git
cd cerro-azul-jitsi

# 2. Crear el .env con passwords aleatorios
cp .env.example .env
./gen-passwords.sh >> .env
# Editar .env y reemplazar CAMBIAR-... con valores reales:
#   - PUBLIC_URL (tu dominio)
#   - JVB_PUBLIC_ADDRESS (IP publica del VPS)
#   - JVB_ADVERTISE_IPS (IP publica del VPS)
#   - LOCAL_ADDRESS (IP interna del container JVB, usualmente 172.21.0.5)

# 3. Crear directorios de configuracion (vacios al inicio)
mkdir -p prosody/prosody-plugins-custom

# 4. Levantar el stack
docker compose up -d

# 5. Configurar firewall
sudo ufw allow 10000/udp comment 'Jitsi JVB media'
sudo ufw allow 4443/tcp comment 'Jitsi JVB fallback'

# 6. Configurar el virtualhost en Caddy (reverse proxy existente)
#    El repo es la fuente de verdad: infra/caddy/meet.urbcerroazul.com.caddy
#    Sincronizar (verifica, y con --apply actualiza + valida + recarga):
./scripts/sync-caddy.sh
./scripts/sync-caddy.sh --apply
```

### Caddy: por qué el bloque debe vivir en el Caddyfile del host

El 21-Oct-2026 el sitio estuvo **caído ~2 semanas** (`HTTP 000`, `TLS internal error`)
aunque los 5 contenedores Jitsi estaban sanos y el certificado de Let's Encrypt
seguía válido en disco.

Causa: el bloque de Jitsi se había aplicado **solo** con `POST /load` a la admin API
de Caddy. Eso vive en la **memoria en runtime** del proceso: cuando el host reinició
(18-Oct) y todos los contenedores se recrearon (21-Oct), Caddy volvió a leer su
Caddyfile del host — que nunca contuvo el bloque de Jitsi — y el vhost desapareció.

**Regla:** la admin API sirve para *recargar*, nunca para *persistir*. El bloque
tiene que estar escrito en el Caddyfile del host.

```
/home/chatbotph/chatbotph/Caddyfile   (bind-mount ro -> /etc/caddy/Caddyfile)
```

Procedimiento (sin downtime, los otros sitios no se tocan):

```bash
# 1. Respaldo con fecha
cp -p /home/chatbotph/chatbotph/Caddyfile \
      /home/chatbotph/chatbotph/Caddyfile.bak.$(date +%Y%m%d_%H%M%S)

# 2. Agregar el bloque (ver infra/caddy/meet.urbcerroazul.com.caddy)

# 3. VALIDAR antes de aplicar
docker exec -i hermes-caddy caddy validate \
    --adapter caddyfile --config /etc/caddy/Caddyfile
# Debe terminar con "Valid configuration"

# 4. RECARGAR (no POST /load, no docker restart)
docker exec hermes-caddy caddy reload \
    --config /etc/caddy/Caddyfile --adapter caddyfile

# 5. Verificar que el vhost quedo en el runtime
docker exec hermes-caddy curl -s \
    http://localhost:2019/config/apps/http/servers/srv0/routes \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); \
    [print(x.get("match",[{}])[0].get("host","?")) for x in d]'
```

**Direcciones:** Caddy corre en un contenedor, así que `127.0.0.1` dentro de él es el
propio contenedor, **no** el host. Se usa el DNS de la red Docker (`web:80`,
`admin:8081`), igual que los otros bloques usan `ml-web:5051` y
`minuta-segura-backend-1:8000`. Comprobado:
`docker exec hermes-caddy wget http://127.0.0.1:8080/` no responde.

El contenedor `hermes-caddy` debe estar en la red de Jitsi para resolver esos nombres:

```bash
docker network connect jitsi-meet_jitsi hermes-caddy
```

**Prueba de persistencia** (la que faltaba y costó 2 semanas de caída):

```bash
docker restart hermes-caddy
sleep 5
curl -sI https://meet.urbcerroazul.com/     # debe seguir en 200
```

### Verificar

```bash
# Healthcheck del admin
curl https://meet.tu-dominio.com/healthz
# Esperado: {"service":"jitsi-admin","status":"ok"}

# Login admin
# Abrir https://meet.tu-dominio.com/admin/login
# Usuario: Hguaza76
# Contrasena: la que configuraste en /opt/jitsi-meet/admin-panel/instance/admin.env
```

## Instalación desde cero (clon limpio)

El repo es reproducible: un clon limpio levanta el stack completo.

```bash
# 1. Clonar
git clone git@github.com:Fabig76/cerro-azul-jitsi.git /opt/jitsi-meet
cd /opt/jitsi-meet

# 2. Configurar el .env
cp .env.example .env
./gen-passwords.sh | grep -E '^[A-Z_]+=' | while IFS= read -r l; do
    k="${l%%=*}"; v="${l#*=}"
    sed -i "s|^${k}=.*|${k}=${v}|" .env
done
# Editar PUBLIC_URL, XMPP_*, JVB_ADVERTISE_IPS y JVB_WS_DOMAIN con los
# valores reales del dominio y la IP publica.

# 3. Validar el .env (detecta los errores que rompen el stack)
./scripts/validate-env.sh .env

# 4. Plugins de Prosody (la imagen NO los trae)
./scripts/install-prosody-plugins.sh

# 5. Levantar
docker compose up -d --build

# 6. Verificar: los 5 servicios deben quedar 'healthy'
docker compose ps
```

### Layout en el servidor

```
/opt/jitsi-meet/                  # raiz del repo desplegado
├── docker-compose.yml             # rutas RELATIVAS a este directorio
├── .env                           # secretos (chmod 600, fuera de git)
├── admin-panel/                   # build context del panel admin
│   ├── Dockerfile
│   ├── app/                       # app.py + templates
│   └── instance/                  # admin.env, reuniones.db (persistido)
├── prosody/
│   ├── Dockerfile.prosody          # imagen con mod_http_health
│   ├── prosody-plugins/            # 86 modulos .lua (del .deb de unstable)
│   ├── prosody-plugins-custom/     # modulos propios (mod_http_health)
│   └── config/                     # generado por la imagen, NO versionar
├── web/config/, jicofo/config/, jvb/config/   # generados, NO versionar
└── infra/caddy/meet.urbcerroazul.com.caddy    # bloque Caddy (fuente de verdad)
```

### Por qué existe `prosody/Dockerfile.prosody`

La imagen oficial `jitsi/prosody` no trae el módulo `mod_http_health`, y el
servicio `70-register-setup` de la imagen **registra las cuentas `focus@`/`jvb@`
solo después** de que Prosody responda en `http://127.0.0.1:5280/health`.

Sin ese endpoint el register-setup agota los 60 intentos y hace `exit 1`
**sin registrar las cuentas**. Como consecuencia, Jicofo y JVB no pueden
autenticarse (`SASLError not-authorized`), el bridge queda con
`operational_bridge_count = 0` y **las reuniones no transmiten audio ni video**.

En un despliegue anterior esto no se notó porque las cuentas habían quedado
persistidas en `/config/data` desde el primer despliegue. Si se borra ese
directorio, el stack se rompe igual. La imagen propia elimina esa fragilidad.

### Verificación del bridge (la que de verdad importa)

```bash
docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["bridge_selector"]["operational_bridge_count"])'
# Debe imprimir 1
```

Un stack con los 5 servicios `healthy` pero `operational_bridge_count = 0`
**no sirve**: no hay medio. Verifica este número, no solo el estado de salud.

## Estructura del Repositorio

```
.
├── README.md                       # Este archivo
├── docker-compose.yml              # Stack Jitsi completo
├── .env.example                    # Template de configuracion
├── .env                            # NO COMMITEAR - configuracion real
├── gen-passwords.sh                # Genera passwords aleatorios
├── .gitignore                      # Ignora .env, __pycache__, etc
├── infra/
│   └── caddy/
│       └── meet.urbcerroazul.com.caddy  # Bloque Caddy (fuente de verdad)
├── scripts/
│   ├── setup-vps.sh                # Despliegue inicial en VPS limpio
│   ├── sync-caddy.sh               # Verifica/sincroniza el bloque Caddy con el host
│   ├── rotate-turn-secret.sh       # Rota TURN_CREDENTIALS (y external_service_secret)
│   ├── install-prosody-plugins.sh  # Instala los 86 modulos de Prosody de Jitsi
│   ├── validate-env.sh             # Valida el .env antes de desplegar
│   ├── make-test-env.sh            # Genera un .env de prueba (para CI)
│   └── test-ci-local.sh            # Simula los pasos del CI en local
├── prosody/
│   ├── Dockerfile.prosody          # Imagen propia: anade mod_http_health
│   ├── prosody-plugins/            # 86 modulos .lua (del .deb de unstable)
│   └── prosody-plugins-custom/     # Modulos propios (mod_http_health)
├── admin-panel/
│   ├── Dockerfile                  # Imagen Docker del admin
│   ├── app/                        # App Flask + templates
│   │   ├── app.py                  # App Flask principal
│   │   ├── tpl.html                # Template base
│   │   ├── page_login.html         # Pagina de login
│   │   ├── page_panel.html         # Panel de admin
│   │   ├── page_qr_view.html       # Vista del QR + link
│   │   └── page_reunion.html       # Pagina publica de reunion
│   └── instance/
│       └── admin.env.example        # Template de credenciales admin
├── docs/
│   ├── SETUP_HISTORY.md            # TODA la conversacion de instalacion
│   ├── ARCHITECTURE.md             # Arquitectura detallada
│   └── TROUBLESHOOTING.md          # Bugs encontrados y fixes
└── scripts/
    └── setup-vps.sh                # Script de despliegue
```

## Servicios y URLs

| Servicio | URL Interna | URL Publica | Notas |
|----------|-------------|-------------|-------|
| Admin Panel | http://admin:8081 | https://meet.tu-dominio.com/admin/login | Login con Hguaza76 |
| Jitsi Web | http://web:80 | https://meet.tu-dominio.com/ | UI principal |
| Prosody XMPP | xmpp://prosody:5222 | - | Señalizacion |
| JVB HTTP | http://jvb:8080 | - | Health check (interno) |
| JVB RTP | udp://0.0.0.0:10000 | udp://TU-IP:10000 | Media WebRTC |
| Healthz | http://admin:8081/healthz | https://meet.tu-dominio.com/healthz | Status check |

## Comandos Utiles

```bash
# Ver logs de un servicio
docker compose logs -f jvb
docker compose logs -f jicofo
docker compose logs -f prosody
docker compose logs -f admin

# Reiniciar todo
docker compose restart

# Recrear el stack (despues de cambios en compose o .env)
docker compose down
docker compose up -d

# Entrar al shell de un container
docker exec -it jitsi-prosody sh
docker exec -it jitsi-jvb sh

# Verificar health del bridge
docker exec jitsi-jvb curl -s http://127.0.0.1:8080/about/health
# Esperado: HTTP 200

# Ver conexiones activas en el bridge
docker exec jitsi-jvb curl -s http://127.0.0.1:8080/about/version

# Ver DB de reuniones (desde el host)
sqlite3 /opt/jitsi-meet/admin-panel/instance/reuniones.db "SELECT id, slug, titulo FROM reuniones WHERE activo=1"
```

## Fase 2 — JWT y moderación A/V

> **ATENCIÓN:** con `ENABLE_AUTH=1` + `JWT_ALLOW_EMPTY=0` **sin token no entra
> nadie**: ni por `https://meet.urbcerroazul.com/<sala>` directo, ni con token
> vencido, ni con token de otra sala. Todo acceso pasa por el panel.

### Roles

| Rol | Token | Qué puede hacer |
|---|---|---|
| Administrador | `context.user.moderator: true` (solo rutas `/admin/...` con login) | Hablar, cámara, pantalla; dar/quitar la palabra |
| Asistente autorizado | `moderator: false` | Hablar / cámara **solo** después de que el admin lo apruebe |
| Asistente normal | `moderator: false` | Levantar la mano y chat |

"Autorizado" no es un tipo de token distinto: es un asistente al que el
moderador aprobó en la moderación A/V durante la reunión.

### Flujo

1. El admin crea la reunión en `/admin`. La sala es `asamblea-` + 16 hex
   aleatorios (`secrets.token_hex(8)`), guardada en `reuniones.sala_jitsi`,
   independiente del `slug` del link público/QR.
2. Asistente: abre `/reunion/<slug>` (QR), escribe apto y nombre → `POST /unirse`
   → el panel firma **un token nuevo por persona** (`context.user.id` y `sub`
   únicos, nombre `Apto 302 - Ana Pérez`, `moderator: false`) y redirige a
   `https://meet.../<sala>#jwt=<token>`. El token va en el **fragmento**
   (`#`), que el navegador no envía al servidor: no queda en logs ni en Referer.
3. Admin: `/admin/reunion/<id>/sala` (Jitsi embebido + controles) o
   `/admin/reunion/<id>/entrar` (Jitsi directo). Token con `moderator: true`.
4. Prosody (`authentication = "token"`) valida firma HS256 (`JWT_APP_SECRET`),
   `iss ∈ JWT_ACCEPTED_ISSUERS`, `aud ∈ JWT_ACCEPTED_AUDIENCES`, `nbf/exp` y
   que `room` sea la sala. `token_affiliation` da `owner` (= moderador) solo si
   `context.user.moderator` es true; el resto queda `member`.

Claims: `iss`, `aud`, `sub`, `room`, `context.user.{id,name,moderator}`,
`nbf = ahora − 60 s`, `exp = fecha + duración + 30 min`, `iat`. Si la reunión
ya venció, `/unirse` responde **410 "Reunión finalizada"** en vez de emitir un
token muerto. El margen se cambia con `JWT_EXP_MARGIN_MIN` (admin.env). Prosody
valida `exp` al conectar: quien ya está dentro no es expulsado al vencer.

### Variables y trampas de nombres (verificadas en las imágenes stable-11031)

- **`PROSODY_AUTH_TYPE`, no `AUTH_TYPE`**: la plantilla de Prosody hace
  `PROSODY_AUTH_TYPE | default AUTH_TYPE`. Se definen las dos en `jwt`.
- **`XMPP_MUC_MODULES`, no `XMPP_MODULES`**: `XMPP_MODULES` se carga en el
  `VirtualHost`; `XMPP_MUC_MODULES` en el `Component "muc"`. `token_affiliation`
  engancha `muc-occupant-pre-join`, que solo existe en el componente MUC: en
  `XMPP_MODULES` se cargaría sin hacer nada y nadie sería moderador.
  Comprobado renderizando la plantilla: queda junto a `token_verification`.
- **`ENABLE_AUTO_OWNER=false`** (Jicofo): por defecto Jicofo hace moderador al
  primero que entra.
- **`JICOFO_ENABLE_AUTH=0`**: con auth JWT en Jicofo, *todo* usuario
  autenticado (todos traen JWT) sería owner. Va explícito porque su default es
  `ENABLE_AUTH`.
- **`JWT_ENABLE_DOMAIN_VERIFICATION=0`**: el panel pone un id de participante
  en `sub`; con verificación de dominio `sub` tendría que ser el dominio.
- `START_WITH_AUDIO_MUTED=1` / `START_WITH_VIDEO_MUTED=1` → `config.startWith*Muted = true`.
- `ENABLE_LOBBY=0`, `ENABLE_GUESTS=0`, `ENABLE_AV_MODERATION=1`.

`./scripts/validate-env.sh` falla si cualquiera de estas está mal. El panel
compara su `iss`/`aud` con lo que acepta Prosody al arrancar: si no coinciden lo
registra como `ERROR CONFIG JWT`, muestra un aviso rojo en `/admin` y
`/healthz` devuelve `"jwt_config_ok": false` (sigue respondiendo 200 para no
tumbar el healthcheck).

### Dar y quitar la palabra

La moderación la ejecuta el **navegador del moderador** con el iframe API
(el servidor del panel no habla XMPP con la sala). El panel ofrece:

- `GET /admin/reunion/<id>/sala` — página lista para usar: activa la moderación
  de audio y video al entrar, lista los participantes (mano levantada primero)
  con *Dar palabra / Quitar palabra / Habilitar cámara / Quitar cámara*, y
  *Silenciar a todos / Apagar todas las cámaras*. Registra cada comando.
- `GET /admin/reunion/<id>/moderador.json` — `{domain, roomName, jwt,
  participantId, exp, expired}` para que **otro cliente** embeba Jitsi como
  moderador. Requiere sesión del panel (cookie), `Cache-Control: no-store`.
- `GET /admin/reunion/<id>/entrar` — Jitsi a pantalla completa como moderador;
  la moderación se maneja desde el panel de participantes nativo de Jitsi.

Snippet para el cliente:

```html
<script src="https://meet.urbcerroazul.com/external_api.js"></script>
<script type="module">
const cfg = await (await fetch('/admin/reunion/ID/moderador.json',
                               { credentials: 'same-origin' })).json();
const api = new JitsiMeetExternalAPI(cfg.domain, {
  roomName: cfg.roomName, jwt: cfg.jwt,
  parentNode: document.getElementById('jitsi'),
  configOverwrite: { startWithAudioMuted: true, startWithVideoMuted: true },
});
api.addListener('videoConferenceJoined', () => {
  api.executeCommand('toggleModeration', true, 'audio');  // nadie habla sin aprobación
  api.executeCommand('toggleModeration', true, 'video');  // ni cámara / pantalla
});
// Dar la palabra (aprueba audio y le pide activar el micro):
api.executeCommand('askToUnmute', participantId);
// Quitar la palabra:
api.executeCommand('rejectParticipant', participantId, 'audio');
api.executeCommand('muteRemoteParticipant', participantId, 'audio');
// Habilitar / quitar cámara:
api.executeCommand('approveVideo', participantId);
api.executeCommand('rejectParticipant', participantId, 'video');
// Silenciar a todos:
api.executeCommand('muteEveryone', 'audio');
// participantId: eventos participantJoined / raiseHandUpdated, o api.getRoomsInfo().
</script>
```

Comandos verificados en `external_api.min.js` de `jitsi/web:stable-11031`.
En esa versión el cliente solo distingue `audio` y `video` en
`toggleModeration` (no existe tipo `desktop`), así que la pantalla compartida
queda bajo la moderación de video. **No probado en una reunión real.**

### Reuniones existentes (migración)

No hay cambio de esquema. Las filas viejas (`sala_jitsi = cerroazul-<slug>`)
**siguen funcionando**: el token se firma con el `sala_jitsi` guardado. Pero ese
nombre se deduce del link público, así que para asambleas importantes conviene
crear una reunión nueva (sala `asamblea-…`). Las reuniones viejas cuya fecha +
duración + 30 min ya pasó dan 410. Cambios de comportamiento:
`/reunion/<slug>?presenter=1` **ya no da moderador** (antes cualquiera podía
editar la URL), y el campo `rol` del formulario se ignora.

### Despliegue y rollback

```bash
# Despliegue: copiar el bloque de auth de .env.example al .env del VPS,
# luego validar y recrear.
./scripts/validate-env.sh /opt/jitsi-meet/.env
docker compose up -d --build --force-recreate prosody web jicofo admin
```

Rollback (salas abiertas como en la Fase 1): en `/opt/jitsi-meet/.env` poner
`ENABLE_AUTH=0`, `PROSODY_AUTH_TYPE=anonymous`, `AUTH_TYPE=anonymous` y
recrear `prosody web jicofo`. El panel sigue firmando tokens (Jitsi los ignora)
y mostrará el aviso "Jitsi no exige JWT". Ojo: con `ENABLE_AUTO_OWNER=false`
y sin token, nadie sería moderador; en rollback quitar también esa línea.

### Pendiente / riesgo conocido

Entre que entra un asistente y el admin activa la moderación, el asistente
*podría* encender el micro (entra apagado, pero no bloqueado). Mitigación:
el admin entra primero. El plugin `mod_muc_wait_for_host` (ya presente en
`prosody/prosody-plugins/`) haría esperar a los asistentes hasta que entre el
moderador; no está activado porque no se ha probado con `token_affiliation`.

## Limitaciones Conocidas

- Max ~100 participantes por sala (teorico 200 con el VPS actual de 4 cores)
- Sin grabación (Jibri no instalado)
- Sin autoescalado (no Octo)
- 1 solo worker de Gunicorn para el admin panel (suficiente)
- TLS/SSL viene de Caddy existente (no se autogenera en este stack)

## Documentación Adicional

- **[docs/SETUP_HISTORY.md](docs/SETUP_HISTORY.md)** - Conversación completa de instalación paso a paso (problemas encontrados, fixes aplicados, logs)
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** - Arquitectura detallada de cada servicio
- **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** - Problemas conocidos y soluciones

## Credenciales (protegidas, NO commitear)

- **DB**: SQLite en `/opt/jitsi-meet/admin-panel/instance/reuniones.db`
- **Passwords XMPP/JWT**: archivo `/opt/jitsi-meet/.env` (chmod 600)
- **Password admin**: archivo `/opt/jitsi-meet/admin-panel/instance/admin.env` (chmod 600)
- **TLS Caddy**: emitido automaticamente por Let's Encrypt

## Rotación de TURN_CREDENTIALS

`TURN_CREDENTIALS` es el secreto compartido (32 hex) que Prosody usa para firmar
las credenciales TURN de corta duración que reparte a los clientes. **No hay servidor
TURN (coturn) en este stack**, así que hoy no está en el camino del audio/video real
(que va por el JVB, UDP 10000); es una pieza que quedará operativa cuando se despliegue
coturn (Fase 4 del plan).

Para rotarlo (por ejemplo si se filtra, o periódicamente):

```bash
# En el VPS:
bash /tmp/rotate-turn-secret.sh          # o copiar scripts/rotate-turn-secret.sh
```

El script:
1. Genera un nuevo secreto de 32 hex (nunca lo imprime completo).
2. Reemplaza `TURN_CREDENTIALS` en `.env`.
3. Reemplaza `external_service_secret` en `prosody/config/prosody.cfg.lua`.
4. Recrea `prosody` (`--force-recreate`, para que lea la env var nueva; `docker restart`
   NO recarga variables de entorno — por eso el config se regenera solo con recreación).
5. Verifica sin errores de módulo.

**Nota de seguridad:** el valor antiguo quedó expuesto en el historial público de git
(como `external_service_secret` en `prosody/conf.d/jitsi-meet.cfg.lua`). Se rotó el
31-Oct-2026. Evitar volver a commitear cualquier secreto; usar `gitleaks` en CI.

## Stack Tecnologico

- Docker + Docker Compose
- Jitsi Meet stable-11031
- Prosody XMPP server (con 84 plugins de auth_token, av_moderation, breakout, polls, etc.)
- Flask 3 + Gunicorn para el admin panel
- Caddy 2 como reverse proxy
- Python 3.12 + SQLite para el admin

## Licencia

Privado - Cerro Azul Residencial
