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
├── web/config/custom-*.js        # Fase 3: config de sala grande (SI versionado)
├── web/config/ (resto), jicofo/config/, jvb/config/   # generados, NO versionar
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
│   ├── test-ci-local.sh            # Simula los pasos del CI en local
│   ├── check-turn.sh / check_turn.py  # Watchdog del TURN (STUN, Allocate, TLS) - Fase 7.1
│   ├── turn-cert.sh                # Certificado del TURN: issue/renew/install-hook - Fase 4
│   ├── turn-cert-cron.sh           # Renovacion desatendida + aviso si falla
│   ├── backup.sh                   # Respaldo cifrado del estado - Fase 7.2
│   └── restore.sh                  # Restauracion (no arranca nada) - Fase 7.2
├── turn/                           # Servidor TURN (coturn), se despliega aparte - Fase 4
├── loadtest/                       # Arnes de prueba de carga con Malleus - Fase 7.3
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
│   │   ├── page_reunion.html       # Pagina publica de reunion
│   │   └── static/                 # Tema visual (Fase 8)
│   │       ├── theme.css           # Sistema de diseno: tokens, componentes, claro/oscuro
│   │       └── theme.js            # Tema, menus, estado de carga, dialogos
│   ├── README.md                   # Rutas del panel y API interna (Fase 6)
│   └── instance/
│       └── admin.env.example        # Template de credenciales admin
├── integracion/                    # Cliente JS + ejemplo para votacionph.us - Fase 6
├── docs/
│   ├── SETUP_HISTORY.md            # TODA la conversacion de instalacion
│   ├── ARCHITECTURE.md             # Arquitectura detallada
│   ├── TROUBLESHOOTING.md          # Bugs encontrados y fixes
│   ├── BACKUP-RESTORE.md           # Respaldo y restauracion en servidor limpio
│   ├── INTEGRACION-JITSI.md        # Integracion con votacionph.us (Fase 6)
│   ├── SPEC-DISENO.md              # Spec del rediseno visual (Fase 8)
│   ├── SPEC-DISENO-mockups.md      # Wireframes de cada pantalla
│   ├── DISENO-AUDITORIA.md         # Que se cambio, como se verifico y evidencia
│   └── capturas-rediseno/          # 54 capturas: 5 paginas x 3 anchos x 2 temas
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

## Criterios de aceptación (estado)

Los criterios que pedía el plan del analista y en qué fase se resuelven:

| Criterio | Estado | Fase |
|---|---|---|
| El sitio sobrevive a un reinicio completo del servidor | **hecho** (vhost persistido en el Caddyfile del host; verificado reiniciando el contenedor de Caddy) | 0 |
| Un clon limpio levanta el stack completo; el CI pasa en verde | **hecho** (`scripts/test-ci-local.sh` simula el CI; clon real probado) | 1 |
| Sin JWT válido para esa sala no se puede entrar | **hecho** (SASL `FAILURE: token required`) | 2 |
| Solo quien trae `moderator: true` es moderador | **hecho** (`token_affiliation`; `enable-auto-owner=false`) | 2 |
| Ningún asistente transmite sin aprobación | **hecho** (el JVB recibe `force-mute` para ese endpoint) | 2 |
| El administrador da y quita la palabra | **hecho** ("Pedir la palabra" por participante y "Dar la palabra a todos") | 2 / 3 |
| Audio en ambos sentidos con UDP bloqueado (TURN en 443) | **pendiente de la prueba con dispositivo real** (TURN desplegado y relay verificado; falta un móvil con datos y un PC con UDP bloqueado oyendo y hablando) | 4 |
| Entrada desde Chrome, Chrome Android y Safari iPhone sin "instala la app" | **pendiente** | 6 |
| Prueba de carga con 600 clientes | **pendiente** (arnés listo en `loadtest/`, sin ejecutar) | 7 |
| Alertas: apagar el web dispara alerta en < 2 min | **hecho** (watchdog cada 2 min → Telegram; probado a mano) | 0 |
| Respaldo restaurado en un servidor limpio | **pendiente** (`scripts/backup.sh`/`restore.sh` probados en local sobre un clon limpio; falta la restauración en un servidor limpio real, ver `docs/BACKUP-RESTORE.md`) | 7 |

Estado de la Fase 4 (TURN): coturn desplegado en servidor aparte, relay verificado,
certificado autofirmado con renovación automatizable (`scripts/turn-cert.sh`).
Pendiente: DNS `turn.urbcerroazul.com` + Let's Encrypt y la prueba con dispositivo real.
Detalle en [Fase 4 — TURN](#fase-4--turn).

## Fase 3 — Sala grande (estabilidad)

Una asamblea es **una sala de hasta 500 personas con un solo ponente** (el
admin: 1 cámara + pantalla compartida) y el resto escuchando. Los valores por
defecto de Jitsi están pensados para reuniones pequeñas donde todos envían y
reciben vídeo; a 500 personas eso satura el JVB y, sobre todo, los móviles de
los asistentes. Se recorta todo lo que no aporta en una asamblea.

### Estado de cada punto de la fase

| Punto | Qué pedía el plan | Estado | Dónde |
|---|---|---|---|
| 3.1 | Vars de sala grande en `.env` | **hecho** | `.env.example`, `docker-compose.yml` |
| 3.2 | `custom-config.js` con la config de sala grande | **hecho** (27 claves, 1 descartada) | `web/config/custom-config.js` |
| 3.3 | Barra de herramientas según el rol | **hecho** | `admin-panel/app/app.py` (`jitsi_url`), `page_sala.html` |
| 3.4 | Entrada masiva (rate limits) | **hecho** (documentado; no se activan) | más abajo |

### Qué se recorta y dónde

| Capa | Fichero | Qué hace |
|---|---|---|
| Env del web | `.env` → `docker-compose.yml` | `ENABLE_P2P=0`, `ENABLE_PREJOIN_PAGE=0`, `ENABLE_BREAKOUT_ROOMS=0` (el compose pasa `0` si faltan: la plantilla del web tiene default `true`) |
| Cliente | `web/config/custom-config.js` | Claves `config.*` de la tabla de abajo |
| Interfaz | `web/config/custom-interface_config.js` | `DISABLE_VIDEO_BACKGROUND` (fondo difuminado = CPU en móviles) |
| Panel admin | `admin-panel/app/page_sala.html` | `toolbarButtons` del admin por `configOverwrite` |

El entrypoint del web (`/etc/cont-init.d/10-config`) regenera
`/config/config.js` en cada arranque y **concatena al final**
`/config/custom-config.js` (igual con `custom-interface_config.js`). Como el
compose monta `./web/config:/config`, los ficheros sobreviven a
`docker compose up -d --force-recreate web` (probado ejecutando `10-config`
dos veces en un contenedor desechable). El resto de `web/config/` es generado
y está en `.gitignore`.

### Claves (verificadas contra `jitsi/web:stable-11031`)

Jitsi **ignora en silencio** una clave que no conoce. Cada una se comprobó en
las plantillas de la imagen o en `app.bundle.min.js` / `lib-jitsi-meet.min.js`.

| Clave | Valor | Por qué |
|---|---|---|
| `p2p.enabled` | `false` | Todo el medio por el JVB (donde se aplica la moderación); sin renegociación al entrar el tercero |
| `startWithAudioMuted` / `startWithVideoMuted` | `true` | Este cliente entra con micro y cámara apagados |
| `startAudioMuted` / `startVideoMuted` | `0` | **Número**, no booleano: “a partir del participante N todos entran silenciados”; `0` = todos. Se envía a Jicofo; `true` no es un entero válido |
| `prejoinConfig.enabled` | `false` | Sin pantalla previa (nombre viene del JWT) |
| `channelLastN` | `4` | Cada asistente recibe como mucho 4 vídeos (el ponente usa 2) |
| `maxFullResolutionParticipants` | `1` | Solo el vídeo del escenario en resolución completa |
| `resolution` / `constraints` | `360` (máx. 720) | Cámara del ponente; los documentos van por la pantalla |
| `desktopSharingFrameRate` | `5–15 fps` | Documentos, no vídeo |
| `audioQuality` | `stereo: false` | Voz en mono |
| `disableAudioLevels` | `true` | Ahorra CPU en clientes con cientos de participantes |
| `enableNoAudioDetection` / `enableNoisyMicDetection` | `false` | Avisos inútiles con todos silenciados |
| `disableReactions` / `disablePolls` | `true` | Spam en pantalla y tráfico extra |
| `disableJoinLeaveSounds` / `disableIncomingMessageSound` | `true` | 500 entradas/salidas sonando |
| `notifications` | lista blanca | Solo moderación y conexión (incluye `notify.hostAskedUnmute`, necesario para “Pedir la palabra”) |
| `disableThirdPartyRequests` | `true` | Privacidad, sin gravatar |
| `disableInviteFunctions` | `true` | El acceso es por enlace con JWT del panel |
| `requireDisplayName` | `true` | El admin necesita saber a quién da la palabra |
| `defaultLanguage` | `'es'` | |
| `analytics` | `disabled: true` | Sin analítica ni rtcstats |
| `toolbarButtons` | barra del admin | En esta versión la barra va en `config.js`; `interfaceConfig.TOOLBAR_BUTTONS` está obsoleto y solo se usa si `config.toolbarButtons` no es un array |

**Descartada:** `enableLayerSuspension` — venía en el plan pero **no existe**
en ningún bundle de `stable-11031`. No reintroducirla.

`startAudioMuted`/`startVideoMuted` **no impiden** que el asistente encienda el
micro: eso lo hace la moderación A/V de la Fase 2. Estas claves son la capa de
UI.

Comprobar las claves (p. ej. al cambiar `JITSI_IMAGE_VERSION`). Una sola
ejecución de `docker run`, no levanta el stack:

```bash
./scripts/verify-custom-config.sh               # sale 1 si alguna clave no existe
./scripts/verify-custom-config.sh --check-only  # solo informa (CI)
```

### Límite de participantes

| Variable | Quién la aplica (stable-11031) |
|---|---|
| `MAX_PARTICIPANTS` | **Prosody** (`muc_max_occupants`). Jicofo **no** la lee en esta versión |
| `MAX_BRIDGE_PARTICIPANTS` | Jicofo (`max-bridge-participants`, por JVB) |
| `VISITORS_MAX_PARTICIPANTS` | Jicofo, solo con `ENABLE_VISITORS=1` (aquí `0`) |

Hasta la Fase 2 el compose pasaba `MAX_PARTICIPANTS` solo a Jicofo y JVB (que
no la usan), así que **el 200 del `.env` no se aplicaba**. Desde la Fase 3 llega
a Prosody: si el `.env` del VPS conserva `MAX_PARTICIPANTS=200`, la sala
quedaría limitada a 200 al recrear prosody.

**Ojo: quitar la variable NO la desactiva.** Sin `MAX_PARTICIPANTS` la plantilla
no renderiza `muc_max_occupants` y Prosody aplica su valor por defecto, que es
**200** (verificado renderizando la plantilla con y sin la variable). Para subir
el límite hay que **fijarla en 500**, no borrarla. `validate-env.sh` avisa si
están por debajo de 500.

### 3.4 Entrada masiva (rate limits de Prosody)

En una asamblea, cientos de personas entran en los mismos minutos. Prosody
trae un módulo de rate limit **desactivado por defecto**
(`PROSODY_ENABLE_RATE_LIMITS=0`), y sus valores por defecto en `stable-11031`
son:

| Variable | Default | Qué limita |
|---|---|---|
| `PROSODY_ENABLE_RATE_LIMITS` | `0` | activa/desactiva el módulo |
| `PROSODY_RATE_LIMIT_LOGIN_RATE` | `3` | **logins por segundo y IP** |
| `PROSODY_RATE_LIMIT_SESSION_RATE` | `200` | sesiones por segundo y IP |
| `PROSODY_RATE_LIMIT_TIMEOUT` | `60` | segundos de penalización |
| `PROSODY_RATE_LIMIT_CACHE_SIZE` | `10000` | tamaño de la caché |
| `PROSODY_RATE_LIMIT_ALLOW_RANGES` | `10.0.0.0/8` | rangos exentos |

**Decisión: NO activarlos.** El módulo está apagado y por eso hoy no hay
ningún límite artificial de entrada (mismo criterio que con los límites de
participantes). Además, si se activaran tal cual, `LOGIN_RATE=3` (3 logins por
segundo **y por IP**) sería peligroso: los asistentes del conjunto salen por la
misma IP pública (NAT) y se bloquearían entre sí al entrar en masa.

Si en la prueba de carga (Fase 7) se ven desconexiones o errores de rate limit
en el log de Prosody, se activan **subiendo primero** `LOGIN_RATE` y
`SESSION_RATE`, y **`RATE_LIMIT_ALLOW_RANGES` con la IP pública del
conjunto** para eximir a los asistentes:

```bash
PROSODY_ENABLE_RATE_LIMITS=1
PROSODY_RATE_LIMIT_LOGIN_RATE=50
PROSODY_RATE_LIMIT_SESSION_RATE=500
PROSODY_RATE_LIMIT_ALLOW_RANGES=10.0.0.0/8,<IP_PUBLICA_DEL_CONJUNTO>
```

### Barra por rol

La barra es solo UI (la moderación A/V es el control real), pero evita
confundir a los asistentes.

- **Admin** (`page_sala.html`, único que entra con `moderator: true`):
  `microphone, camera, desktop, participants-pane, raisehand, chat, tileview, settings, hangup`.
  Es también el valor por defecto del sitio en `custom-config.js`.
- **Asistente**: en el proyecto donde el asistente entra embebiendo Jitsi:

```js
// Barra reducida del asistente. Solo UI: quien habla lo decide la
// moderacion A/V del admin.
const botonesAsistente = ['microphone', 'raisehand', 'chat', 'settings', 'hangup'];

const api = new JitsiMeetExternalAPI('meet.urbcerroazul.com', {
  roomName: sala,
  jwt: tokenAsistente,           // moderator: false
  parentNode: document.getElementById('jitsi'),
  configOverwrite: {
    startWithAudioMuted: true,
    startWithVideoMuted: true,
    prejoinConfig: { enabled: false },
    disableDeepLinking: true,
    toolbarButtons: botonesAsistente
  }
});
```

> Los asistentes que entran por la página pública de **este** panel
> (`/reunion/<slug>` → `/unirse`) van a la URL directa de Jitsi, no a un
> iframe: ven la barra por defecto del sitio (la del admin; cámara y pantalla
> quedan bloqueadas por la moderación). Para darles la barra reducida habría
> que añadir `&config.toolbarButtons=[...]` al fragmento en `jitsi_url()` para
> tokens sin moderador (pendiente).

### Verificar que se aplicó

```bash
./scripts/validate-env.sh /opt/jitsi-meet/.env
docker compose up -d --force-recreate web
curl -s https://meet.urbcerroazul.com/config.js | grep -E 'p2p|channelLastN'
# Debe mostrar, al final del fichero:
#   config.p2p.enabled = false;
#   config.channelLastN = 4;
curl -s https://meet.urbcerroazul.com/interface_config.js | grep DISABLE_VIDEO_BACKGROUND
```

### Volver atrás

```bash
rm web/config/custom-config.js web/config/custom-interface_config.js
docker compose up -d --force-recreate web
```

(Las variables `ENABLE_P2P`/`ENABLE_PREJOIN_PAGE`/`ENABLE_BREAKOUT_ROOMS`
siguen en `0` por el compose; para revertirlas, ponerlas a `1` en el `.env`.)

## Fase 4 — TURN

### Qué es y qué problema resuelve

Un servidor **TURN** (coturn) reenvía el audio y el vídeo cuando el navegador no puede
hablar directamente por UDP con el JVB. **Sin TURN, quien está en una red que bloquea
UDP** (redes corporativas, algunos operadores móviles, wifi de hoteles) **entra a la sala
pero no oye nada**: el cliente solo tiene el candidato UDP directo al puerto 10000 y no
hay por dónde sacar el medio. Con TURN, el cliente sale por TCP o por **TLS en 443** (lo
que casi ninguna red bloquea) y coturn le reenvía los paquetes del JVB.

### Dónde vive y qué puertos usa

En un **servidor aparte** del de Jitsi, en `/opt/coturn` (contenedor `coturn`,
`coturn/coturn:4.6.3-r3`, `network_mode: host`). Va aparte porque necesita el 443 y en
el servidor de Jitsi ese puerto lo usa Caddy. Configuración versionada en `turn/`
(`turnserver.conf` con el secreto como placeholder, `docker-compose.turn.yml`);
despliegue y detalles en [turn/README.md](turn/README.md).

| Puerto | Uso |
|---|---|
| `3478/udp` y `3478/tcp` | STUN/TURN estándar (`listening-port`). El TCP entra cuando la red bloquea UDP |
| `443/tcp` | TURN sobre **TLS** (`tls-listening-port`): la variante para las redes más restrictivas |
| `443/udp` | Puerto UDP alterno (`alt-listening-port`) |
| `49160–49200/udp` | Puertos de relay (`min-port`/`max-port`) |

### Cómo se anuncia a los clientes

Prosody convierte las variables del `.env` de Jitsi en el bloque **`external_services`**
(`mod_external_services`) que recibe cada cliente al conectar. A cada participante le da
una **credencial TURN temporal** (`<expiración>:<nombre>` + HMAC-SHA1) firmada con
`TURN_CREDENTIALS`; el secreto nunca sale del servidor.

| Variable (`.env` de Jitsi) | Valor | Qué genera |
|---|---|---|
| `TURN_CREDENTIALS` | secreto de 32 hex | firma de las credenciales temporales (`external_service_secret`) |
| `TURN_HOST` / `TURN_PORT` / `TURN_TRANSPORT` | IP o nombre del TURN / `3478` / `udp,tcp` | entradas `turn:` |
| `TURNS_HOST` / `TURNS_PORT` | IP o nombre del TURN / `443` | entrada `turns:` (sin ellas Prosody **no** anuncia TURN sobre TLS) |
| `STUN_HOST` / `STUN_PORT` | IP o nombre del TURN / `3478` | entrada `stun:` |

`docker-compose.yml` pasa todas a prosody. Un cambio en ellas se aplica **recreando**
prosody (`docker compose up -d --force-recreate prosody`; `docker restart` no relee el `.env`).

> ⚠️ **`TURN_CREDENTIALS` debe ser EXACTAMENTE el mismo valor en el `.env` de Jitsi y en
> `static-auth-secret` del `turnserver.conf` de coturn.** Si difieren, el TURN sigue
> respondiendo a STUN (todo "parece" bien) pero rechaza todas las credenciales, y los
> usuarios detrás de redes que bloquean UDP vuelven a quedarse sin audio.
> **Ese valor nunca se escribe en claro en el repo**: en git solo hay placeholders
> (`CAMBIAR...`). Para rotarlo o rehacer el TURN, ver `docs/BACKUP-RESTORE.md`
> (paso "El secreto del TURN").

### Cómo verificar el TURN

```bash
# Desde cualquier host con python3 (STUN UDP, Allocate UDP y TLS, TLS en 443, caducidad del cert)
scripts/check-turn.sh /opt/jitsi-meet/.env -v
# Silencioso y con código de salida para watchdogs (ver turn/README.md para Hermes)
scripts/check-turn.sh /ruta/turn.env --host <IP_TURN> --port 3478 --turns-port 443
```

Prueba de navegador: [Trickle ICE](https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/)
con una credencial temporal → deben aparecer candidatos `relay` por UDP y por TLS 443.

### Cómo renovar el certificado

Hoy el TURN usa un certificado **autofirmado** (la zona DNS está en Netim y aún no existe
`turn.urbcerroazul.com`). Los clientes WebRTC no validan el certificado del TURN, así que
funciona; solo hay que renovarlo antes de que caduque. Cuando exista el registro DNS, se
pasa a Let's Encrypt (HTTP-01 standalone/webroot, o DNS-01 con IONOS).

```bash
# En el servidor del TURN (scripts copiados en /opt/coturn/scripts/)
/opt/coturn/scripts/turn-cert.sh status
/opt/coturn/scripts/turn-cert.sh issue --selfsigned --ip <IP_TURN>          # escenario de hoy
/opt/coturn/scripts/turn-cert.sh issue --standalone --email <correo>        # Let's Encrypt
/opt/coturn/scripts/turn-cert.sh renew                                     # solo si faltan < 30 días
/opt/coturn/scripts/turn-cert.sh install-hook                              # deploy-hook de certbot
# Cron diario con aviso por webhook/Telegram si falla:
#   17 4 * * * root /opt/coturn/scripts/turn-cert-cron.sh
```

Permisos que exige el contenedor (corre como `nobody`, uid 65534): certificado `644`,
clave `600`, ambos `65534:65534`. El script los aplica y reinicia coturn solo si el
certificado cambió.

### Estado de la Fase 4

| Punto | Estado |
|---|---|
| coturn desplegado en servidor aparte (UDP/TCP 3478, TLS 443, relay 49160–49200) | **hecho** |
| Relay verificado (`turnutils_uclient`: Allocate con credencial REST y relay address) | **hecho** |
| `TURN_*`/`TURNS_*`/`STUN_*` en el `.env` de Jitsi y `external_services` en Prosody | **hecho** |
| Certificado TLS + renovación con reinicio de coturn | **hecho** (autofirmado; `scripts/turn-cert.sh` + cron, listo también para Let's Encrypt cuando exista el DNS) |
| Registro DNS `turn.urbcerroazul.com` + Let's Encrypt | **pendiente** (zona en Netim) |
| Audio en ambos sentidos con UDP bloqueado | **pendiente** de la prueba con dispositivo real (móvil con datos + PC con UDP bloqueado) |

## Fase 7 — Operación

### 7.1 Monitorización

| Qué | Cómo | Estado |
|---|---|---|
| Web y `/healthz` del admin | watchdog de Hermes cada 2 min → Telegram (`check-meet-jitsi.sh`) | **hecho** |
| TURN (STUN, Allocate con credencial, TLS 443, caducidad del cert) | `scripts/check-turn.sh` (silencioso si va bien; instalación en Hermes en `turn/README.md`) | **listo**, falta darlo de alta en Hermes |
| Renovación del cert del TURN | `scripts/turn-cert-cron.sh` (aviso por `TURN_ALERT_WEBHOOK`/Telegram) | **listo**, falta el cron en el servidor del TURN |
| Prometheus + Grafana, alertas de CPU/red/bridge | plan 7.1 | **pendiente** |

### 7.2 Respaldos

En producción `.env`, `admin.env` y `web/config/keys/cert.key` son `600` de root: los dos
scripts se ejecutan con **`sudo`** (si falta algún permiso lo dicen antes de tocar nada,
con el comando exacto, y salen sin crear ni escribir nada).

```bash
sudo BACKUP_PASSPHRASE='...' BACKUP_ORIGEN=/opt/jitsi-meet scripts/backup.sh --dry-run   # qué se respaldaría
sudo BACKUP_PASSPHRASE='...' BACKUP_ORIGEN=/opt/jitsi-meet scripts/backup.sh --keep 14   # -> BACKUP_DIR (default /opt/jitsi-meet/backups)
sudo BACKUP_PASSPHRASE='...' scripts/restore.sh <respaldo> --dry-run                     # verifica sumas y HMAC, no escribe
sudo BACKUP_PASSPHRASE='...' scripts/restore.sh <respaldo> --dest /opt/jitsi-meet        # pide confirmación; NO arranca nada
```

Respalda `docker-compose.yml`, `web/config/` y `admin-panel/instance/` (db) en claro,
`turn/turnserver.conf` con el secreto redactado, y **cifrados** (`aes-256-cbc` + PBKDF2 +
HMAC-SHA256; `openssl enc` no admite GCM) `.env`, `admin-panel/instance/admin.env`,
`web/config/keys/` y, si existen, `prosody/config`, `jicofo/config` y `jvb/config`. Si
falta `.env` o `admin.env` el respaldo sale **INCOMPLETO** (sin `.env` no se puede
restaurar el stack). Procedimiento completo de restauración en un
servidor limpio, cron diario y copia fuera del servidor: **[docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md)**.

### 7.3 Prueba de carga

Arnés en [`loadtest/`](loadtest/README.md) para Malleus (`jitsi-meet-torture`):
`loadtest/run.sh` hace las comprobaciones previas (web, JWT de la sala, bridge operativo,
`MAX_PARTICIPANTS`, Selenium Grid), muestrea el JVB durante la prueba y genera la tabla de
criterios. **`--dry-run` por defecto.** Comandos concretos en
[`loadtest/malleus-sala-prueba.md`](loadtest/malleus-sala-prueba.md).

> Antes de la prueba de 600: `MAX_PARTICIPANTS` vale hoy `500` y Prosody rechaza en
> silencio a partir de ahí. Hay que subirlo (≥ 610) para la prueba; `run.sh` lo comprueba.

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
- **[docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md)** - Respaldo diario y restauración en un servidor limpio (Fase 7.2)
- **[turn/README.md](turn/README.md)** - Servidor TURN: despliegue, certificado y watchdog (Fases 4 y 7.1)
- **[loadtest/README.md](loadtest/README.md)** - Prueba de carga con Malleus y criterios de aprobación (Fase 7.3)

## Credenciales (protegidas, NO commitear)

- **DB**: SQLite en `/opt/jitsi-meet/admin-panel/instance/reuniones.db`
- **Passwords XMPP/JWT**: archivo `/opt/jitsi-meet/.env` (chmod 600)
- **Password admin**: archivo `/opt/jitsi-meet/admin-panel/instance/admin.env` (chmod 600)
- **TLS Caddy**: emitido automaticamente por Let's Encrypt

## Rotación de TURN_CREDENTIALS

`TURN_CREDENTIALS` es el secreto compartido (32 hex) que Prosody usa para firmar
las credenciales TURN de corta duración que reparte a los clientes. Desde la Fase 4 hay
un coturn en un servidor aparte que valida esas credenciales con el **mismo valor**
(`static-auth-secret`): **si se rota aquí, hay que ponerlo también en coturn** y
reiniciarlo, o el TURN rechazará a todos (ver [Fase 4 — TURN](#fase-4--turn) y el paso
"El secreto del TURN" de `docs/BACKUP-RESTORE.md`). Después: `scripts/check-turn.sh`.

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

## Fase 8 — Rediseño visual del panel

El panel se veía como una herramienta interna sin terminar. Se rediseñó con un sistema de diseño propio (inspiración macOS/iOS: jerarquía, espacio, tipografía y color con intención), **sin ninguna dependencia externa** (nada de CDN, el panel funciona con la red caída hacia fuera).

### Qué se cambió

| Pieza | Qué es |
|---|---|
| `admin-panel/app/static/theme.css` | Sistema de diseño: tokens (`--color-*`, `--space-*`, `--radius-*`, `--shadow-*`, `--font-*`), escala tipográfica 12/14/16/20/25/31/39, componentes (botón, campo, tarjeta, aviso, diálogo, menú, esqueleto) |
| `admin-panel/app/static/theme.js` | ≤ 3 KB: conmutador de tema (claro/oscuro/automático, guardado en `localStorage`), menús, estado de carga, diálogos. Todo funciona también sin JS |
| `page_login.html` | Acceso del administrador con marca y jerarquía |
| `page_panel.html` | Lista de reuniones primero; "Moderar" y "Ver QR" visibles, el resto en menú ⋯ |
| `page_qr_view.html` | QR grande, link público, botón de copiar |
| `page_reunion.html` | Página del residente, **móvil primero**: campos de 16 px (iOS no hace zoom) y botón de 52 px |
| `page_sala.html` | Moderación en vivo. **Solo capa visual**: el JS no se tocó |

### Por qué el CSS vive en `/admin/static/` y no en `/static/`

Caddy solo enruta al panel `/admin*`, `/reunion/*`, `/unirse`, `/healthz` y `/api/reuniones/*`. Todo lo demás va al contenedor `web` de Jitsi, que **ya usa `/static/`** para sus propios ficheros. Por eso Flask se registra con `static_url_path="/admin/static"`. No hubo que tocar Caddy.

### Bugs corregidos de paso

| Bug | Síntoma que veía el usuario |
|---|---|
| `UTC UTC` duplicado | La lista mostraba `2026-11-04 00:00 UTC UTC` |
| Descripción invisible | El administrador la escribía y **el residente nunca la veía** (`<!--DESC-->` no se sustituía) |
| Hora en UTC | Una asamblea del martes 19:00 aparecía como *miércoles 00:00*. Ahora se muestra en hora de Colombia |
| **JWT en el fragmento** | El residente rellenaba el formulario y veía **«Se requiere autenticación»**: esta versión de Jitsi solo lee el token de `?jwt=`. Corregido en `4535fd9` |

### Verificación

- `docs/SPEC-DISENO.md` — spec completo (tokens, componentes, plan por página, riesgos).
- `docs/SPEC-DISENO-mockups.md` — wireframes.
- `docs/DISENO-AUDITORIA.md` — tabla de **cada modificación**: archivo, cambio, cómo se verificó y evidencia.
- `docs/capturas-rediseno/` — **54 capturas**: 5 páginas × 360/768/1280 px × claro/oscuro, más la sala real con dos clientes conectados.

**Contratos que no se pueden romper** (el JS de la sala depende de ellos): `#jitsi`, `#lista`, `#cnt`, `#log`, `#st-audio`, `#st-video`, `.gl button[data-cmd]`, y las clases que el JS crea (`.p`, `.n`, `.mano`, `.m`, `.ok2`, `.d`).

## Licencia

Privado - Cerro Azul Residencial
