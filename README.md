# bytracking - Jitsi Meet

> ## Estado (verificado 2-Nov-2026)
> - ✅ `https://meet.bytracking.net/` en 200. TLS de Let's Encrypt válido hasta el **30-ene-2027**.
>   DNS: `A meet.bytracking.net → 84.247.165.81` (zona en ipage.com)
> - ✅ Stack: `jitsi-web`, `jitsi-prosody` (imagen propia con `mod_http_health`), `jitsi-jicofo`,
>   `jitsi-jvb`, `jitsi-admin` → **5/5 healthy**, ~24 h de uptime. Todas en `stable-11031`
> - ✅ TURN propio en servidor aparte (`vmi3186036`, 155.133.22.222), coturn 4.6.3-r3
> - ✅ Panel `https://meet.bytracking.net/admin/login`, marca `bytracking` / "Asambleas virtuales"
> - ✅ Grabación local en el PC del administrador (Fase 9)
> - ✅ Panel: **"Bajar todas las manos"** y "Bajar la mano" por persona (por XMPP; el
>   videobridge reenvía esos mensajes vacíos). Ver [docs/MODERACION-MANOS.md](docs/MODERACION-MANOS.md)
> - ⚠️ **Compartir pantalla: el administrador tiene que pulsar "Habilitar cámara" sobre
>   quien va a compartir**, o los demás no ven nada. Ver
>   [Compartir pantalla](#compartir-pantalla-qué-se-puede-y-qué-no-importante)
>
> **Versión:** Jitsi `stable-11031` (JVB 2.3.295, openjdk 17)
> **URL:** https://meet.bytracking.net
> El dominio anterior, `meet.urbcerroazul.com`, **ya no se sirve** (migración del 1-nov-2026).
>
> **¿Qué documento leer?** → [Índice de la documentación](#índice-de-la-documentación)

Plataforma de videoconferencias self-hosted para **bytracking**, corriendo en `meet.bytracking.net`. Nació para el Conjunto Residencial Cerro Azul y el panel está preparado para reutilizarse en otros conjuntos (Fase 9): la marca, el subtítulo y el responsable legal se configuran por variables de entorno.

## Stack

- **Jitsi Meet** stable-11031 (web + prosody + jicofo + jvb)
- **Admin Panel** Flask + Gunicorn para crear reuniones y generar QR
- **Caddy** reverse proxy (existente) sirve HTTPS con Let's Encrypt

## Arquitectura

```
Internet
    |
    v
[Caddy :443] ── meet.bytracking.net
    |
    +── /admin/*        ──> [jitsi-admin:8081]   (Flask/Gunicorn)
    +── /reunion/*      ──> [jitsi-admin:8081]   (Flask/Gunicorn)
    +── /unirse         ──> [jitsi-admin:8081]   (Flask/Gunicorn)
    +── /healthz        ──> [jitsi-admin:8081]   (Flask/Gunicorn)
    +── /api/reuniones/*──> [jitsi-admin:8081]   (API de tokens, Fase 6)
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
        +-- 80/tcp, 443/tcp  (Caddy: hermes-caddy, compartido con otros sitios)
        +-- 10000/udp        (RTP media - JVB)
        +-- 4443/tcp         (fallback RTP)

[Servidor TURN vmi3186036 155.133.22.222]   (aparte; Fase 4)
    +-- coturn 4.6.3-r3: 3478 udp/tcp, 443 udp + tcp (TLS), relay 49160-49200/udp
    +-- watchdog de Hermes (web, /healthz y TURN cada 2 min -> Telegram)

[PC del administrador]
    +-- grabacion de la reunion en local (Chrome, Fase 9); nada se sube al servidor
```

Detalle: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

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
#    El repo es la fuente de verdad: infra/caddy/meet.bytracking.net.caddy
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

# 2. Agregar el bloque (ver infra/caddy/meet.bytracking.net.caddy)

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
curl -sI https://meet.bytracking.net/     # debe seguir en 200
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
└── infra/caddy/meet.bytracking.net.caddy    # bloque Caddy (fuente de verdad)
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
├── README.md                       # Este archivo (estado, fases, operación)
├── docker-compose.yml              # Stack Jitsi completo (5 servicios)
├── .env.example                    # Template de configuracion (.env real: NO commitear)
├── gen-passwords.sh                # Genera passwords aleatorios
├── infra/caddy/
│   └── meet.bytracking.net.caddy   # Bloque Caddy (fuente de verdad; su frame-ancestors aun NO esta aplicado en el host)
├── web/config/
│   ├── custom-config.js            # Config de sala grande (Fase 3)
│   └── custom-interface_config.js
├── prosody/
│   ├── Dockerfile.prosody          # Imagen propia: anade mod_http_health
│   ├── prosody-plugins/            # 86 modulos .lua (del .deb de unstable)
│   └── prosody-plugins-custom/     # Modulos propios (mod_http_health)
├── admin-panel/
│   ├── Dockerfile
│   ├── README.md                   # Rutas del panel y API de tokens (Fase 6)
│   ├── app/
│   │   ├── app.py                  # App Flask (panel, /unirse, API de tokens)
│   │   ├── tpl.html, page_*.html   # login, panel, QR, reunion (residente), sala (moderacion)
│   │   └── static/
│   │       ├── theme.css, theme.js # Sistema de diseno (Fase 8)
│   │       ├── grabacion.js        # Grabacion local en el PC del admin (Fase 9)
│   │       └── grabacion-worker.js # Escritura incremental en OPFS (Fase 9)
│   └── instance/admin.env.example  # Template de credenciales y marca del panel
├── integracion/                    # Fase 6: cliente JS para votacionph.us
│   ├── jitsi-cliente.js            # crearSalaJitsi(): iframe, eventos, reconexion
│   ├── ejemplo-votacionph.js       # Ejemplo de uso desde el portal
│   └── README.md                   # Para el equipo de votacionph
├── turn/                           # Servidor TURN (coturn), se despliega aparte - Fase 4
├── loadtest/                       # Prueba de carga con Malleus - Fase 7.3
│   ├── run.sh, summarize.py, make-token.py
│   ├── escalonado.sh, carga-remota.sh, prueba-3vps.sh   # las pruebas que se ejecutaron
│   ├── docker-compose.selenium.yml # Selenium Grid
│   └── malleus-sala-prueba.md
├── scripts/
│   ├── setup-vps.sh, validate-env.sh, make-test-env.sh, test-ci-local.sh
│   ├── install-prosody-plugins.sh, verify-custom-config.sh
│   ├── sync-caddy.sh               # Diff del bloque Caddy con el host (--apply no funciona desde el host dev)
│   ├── rotate-turn-secret.sh, check-turn.sh, check_turn.py, turn-cert.sh, turn-cert-cron.sh
│   ├── backup.sh, restore.sh       # Respaldo cifrado - Fase 7.2
│   ├── desplegar-panel.sh, change_admin_password.sh
│   ├── verificar-panel-local.py, verificar-panel-prod.py, probar-sala-prod.py,
│   │   probar-interacciones.py, capturas-panel.py      # verificacion del panel (Fase 8)
│   └── grabacion/                  # convertir-mp4.{command,bat}, prueba-paso0.html, pruebas (Fase 9)
└── docs/                           # ver "Índice de la documentación" más abajo
    ├── ARCHITECTURE.md, TROUBLESHOOTING.md, BACKUP-RESTORE.md, INTEGRACION-JITSI.md
    ├── INVESTIGACION-PANTALLA.md, SOLUCION-PANTALLA.md   # bug de la pantalla compartida
    ├── GRABACION-ADMIN.md, GRABACION-PASO0.md, SPEC-GRABACION.md, SPEC-GRABACION-mockups.md
    ├── SPEC-DISENO.md, SPEC-DISENO-mockups.md, DISENO-AUDITORIA.md
    ├── SETUP_HISTORY.md            # historico de la instalacion (no se actualiza)
    └── auditoria/, capturas-rediseno/, capturas-grabacion/
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
> nadie**: ni por `https://meet.bytracking.net/<sala>` directo, ni con token
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
   `https://meet.../<sala>?jwt=<token>`. El token va en la **query**:
   `stable-11031` ignora `#jwt=` (corregido en `4535fd9`). Se acepta que quede
   en los logs de Caddy porque caduca al terminar la reunión + 30 min.
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
  con *Pedir la palabra / Silenciar / Habilitar camara / Apagar camara* (así se
  llaman los botones), y
  *Silenciar a todos / Apagar todas las cámaras*. Registra cada comando.
  Para las manos levantadas: **Bajar todas las manos** (barra encima de la
  lista; gris si nadie tiene la mano) y **Bajar la mano** por persona. Bajan la
  mano de verdad en el cliente del residente; el `#log` dice a cuántos y a qué
  ids se envió y si bajaron. Ver [docs/MODERACION-MANOS.md](docs/MODERACION-MANOS.md).
- `GET /admin/reunion/<id>/moderador.json` — `{domain, roomName, jwt,
  participantId, exp, expired}` para que **otro cliente** embeba Jitsi como
  moderador. Requiere sesión del panel (cookie), `Cache-Control: no-store`.
- `GET /admin/reunion/<id>/entrar` — Jitsi a pantalla completa como moderador;
  la moderación se maneja desde el panel de participantes nativo de Jitsi.

Snippet para el cliente:

```html
<script src="https://meet.bytracking.net/external_api.js"></script>
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
// Quitar la palabra ('rejectParticipant' NO existe en la API de 11031):
api.executeCommand('muteRemoteParticipant', participantId, 'audio');
// Habilitar cámara (necesario también para que se vea su pantalla compartida):
api.executeCommand('approveVideo', participantId);
// Apagar cámara:
api.executeCommand('muteRemoteParticipant', participantId, 'video');
// Silenciar a todos:
api.executeCommand('muteEveryone', 'audio');
// participantId: eventos participantJoined / raiseHandUpdated, o api.getRoomsInfo().
</script>
```

**Bajar manos no está en el iframe API.** El panel lo hace leyendo el `APP` del
iframe (mismo origen) y mandando un mensaje privado XMPP a cada persona con la
mano levantada: `conference.sendMessage({ name: "lower-hand-message" }, id)`.
**No usar** `sendEndpointMessage` (la vía del botón nativo «Lower all hands»):
el JVB `2.3-295` la reenvía sin contenido y no baja nada
([TROUBLESHOOTING](docs/TROUBLESHOOTING.md#-bug-el-botón-bajar-todas-las-manos-no-hace-nada-2-nov-2026)).
Un cliente externo con solo el iframe API (votacionph) **no puede** bajar manos.

Comandos verificados en `external_api.min.js` de `jitsi/web:stable-11031` y
usados en asambleas reales (1 y 2-nov-2026). La moderación de `desktop`
existe en Prosody, pero el iframe API no tiene `approveDesktop`, así que el
panel no la activa. **Con la moderación de vídeo activa, la pantalla de un
residente no llega hasta que el admin le pulsa "Habilitar cámara"** (ver
[Compartir pantalla](#compartir-pantalla-qué-se-puede-y-qué-no-importante)).

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

## Fases y estado (2-Nov-2026)

| Fase | Qué | Estado |
|---|---|---|
| 0 | Restaurar el sitio y persistir el vhost de Caddy | **completa** |
| 1 | Repo reproducible (clon limpio + CI) | **completa** |
| 2 | JWT obligatorio y moderación A/V | **completa** |
| 3 | Sala grande (config de cliente) | **completa**: la config vigente es idéntica a `e30c36d` |
| 4 | TURN propio | **completa** (pendiente: prueba con dispositivo real, ver criterios) |
| 5 | Capacidad 500+ / servidor dedicado | **Resuelta: no hace falta hardware nuevo.** En la asamblea solo transmite una persona; medido a ~0,3–0,4 Mbit/s por oyente → 160–200 Mbit/s a 500, dentro de los ~220 de subida del VPS. Pendiente: prueba con 500 reales y tope de tráfico del proveedor ([sección Fase 5](#fase-5--capacidad-para-500-personas)) |
| 6 | Integración con votacionph.us | **parcial**: API `POST /api/reuniones/<id>/token`, `integracion/jitsi-cliente.js` y doc hechos. Falta que el portal lo use y aplicar `frame-ancestors` en el Caddy del host ([docs/INTEGRACION-JITSI.md](docs/INTEGRACION-JITSI.md)) |
| 7 | Operación: monitorización, respaldos, prueba de carga | **completa** (pendientes: cron de respaldo y restauración en servidor limpio, ver criterios) |
| 8 | Rediseño visual del panel | **completa** |
| 9 | Grabación local + panel multi-conjunto | **implementada y desplegada**; falta la checklist en los PCs reales ([docs/GRABACION-PASO0.md](docs/GRABACION-PASO0.md)) |

## Criterios de aceptación (estado)

| Criterio | Estado | Fase |
|---|---|---|
| El sitio sobrevive a un reinicio completo del servidor | **hecho** (vhost persistido en el Caddyfile del host; verificado reiniciando el contenedor de Caddy) | 0 |
| Un clon limpio levanta el stack completo; el CI pasa en verde | **hecho** (`scripts/test-ci-local.sh` simula el CI; clon real probado) | 1 |
| Sin JWT válido para esa sala no se puede entrar | **hecho** (SASL `FAILURE: token required`) | 2 |
| Solo quien trae `moderator: true` es moderador | **hecho** (`token_affiliation`; `enable-auto-owner=false`) | 2 |
| Ningún asistente transmite sin aprobación | **hecho** (el JVB recibe `forceMuteVideo` para ese endpoint; efecto secundario: también bloquea su pantalla, ver "Compartir pantalla") | 2 |
| El administrador da y quita la palabra | **hecho** ("Pedir la palabra" por participante y "Dar la palabra a todos") | 2 / 3 |
| El administrador baja las manos levantadas (una o todas) | **hecho** ("Bajar la mano" / "Bajar todas las manos", por XMPP; probado en producción con dos residentes reales y confirmado en asamblea el 2-nov). App móvil **sin probar** | 2 / 3 |
| Un residente comparte pantalla y todos la ven | **hecho** con el procedimiento "Habilitar cámara" (confirmado en producción el 2-nov a las 12:33) | 3 |
| Audio en ambos sentidos con UDP bloqueado (TURN en 443) | TURN desplegado, relay verificado y vigilado por el watchdog. **A verificar** con dispositivo real (móvil con datos + PC con UDP bloqueado) | 4 |
| Entrada desde Chrome, Chrome Android y Safari iPhone sin "instala la app" | **pendiente** (depende de que votacionph integre el cliente) | 6 |
| Prueba de carga | **parcial**: se lanzaron 10, 50 y 120 receptores; **pico de 48 simultáneos**, 0 `bridge_failures`, JVB al 9–17 % de CPU. El límite lo puso el generador de clientes, no el servidor. Prueba real del operador con **50 personas** (2-nov) sin problemas; ancho de banda por oyente medido con `loadtest/medir-bitrate.py`. La de 500–600 reales sigue pendiente ([loadtest/README.md](loadtest/README.md), [docs/CAPACIDAD-500.md](docs/CAPACIDAD-500.md)) | 7 / 5 |
| Alertas: apagar el web dispara alerta en < 2 min | **hecho** (watchdog cada 2 min → Telegram; probado a mano) | 0 |
| Respaldo restaurado en un servidor limpio | **pendiente** (scripts probados en local sobre un clon limpio; en producción hay 1 respaldo, del 1-nov 03:40, y **sin cron diario**; ver `docs/BACKUP-RESTORE.md`) | 7 |

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

const api = new JitsiMeetExternalAPI('meet.bytracking.net', {
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
> iframe: ven la barra por defecto del sitio (la del admin, con `desktop`).
> Pueden pulsar "Compartir pantalla", pero con la moderación de vídeo activa
> nadie la ve hasta que el admin les pulsa "Habilitar cámara". `jitsi_url()`
> manda `config.toolbarButtons` en la query y Jitsi la ignora (pendiente).

### Verificar que se aplicó

```bash
./scripts/validate-env.sh /opt/jitsi-meet/.env
docker compose up -d --force-recreate web
curl -s https://meet.bytracking.net/config.js | grep -E 'p2p|channelLastN'
# Debe mostrar, al final del fichero:
#   config.p2p.enabled = false;
#   config.channelLastN = 4;
curl -s https://meet.bytracking.net/interface_config.js | grep DISABLE_VIDEO_BACKGROUND
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

Hoy el TURN usa un certificado **autofirmado** con `CN=turn.urbcerroazul.com`, válido
hasta el 29-oct-2036 (comprobado el 2-nov-2026). El nombre `turn.urbcerroazul.com` se
mantiene **a propósito** (el TURN está en otro servidor y no se migró con
`meet.bytracking.net`), pero **no tiene registro DNS** (no resuelve, 2-nov-2026): Prosody
anuncia el TURN por **IP** (`TURN_HOST`/`TURNS_HOST`/`STUN_HOST` = `155.133.22.222`). Los
clientes WebRTC no validan el certificado del TURN, así que funciona. Si algún día se crea
el registro DNS, se puede pasar a Let's Encrypt (HTTP-01 standalone/webroot, o DNS-01).

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
| Servidor del TURN | `vmi3186036` (155.133.22.222), coturn `4.6.3-r3`, `/opt/coturn` |
| Anuncio a los clientes | Prosody: `stun`, `turn` udp, `turn` tcp y `turns` 443, con `secret=true` (credenciales temporales) |
| Registro DNS `turn.urbcerroazul.com` + Let's Encrypt | **no se hará por ahora**: se usa la IP y el autofirmado (a propósito) |
| Audio en ambos sentidos con UDP bloqueado | **pendiente** de la prueba con dispositivo real (móvil con datos + PC con UDP bloqueado) |

## Fase 5 — Capacidad para 500 personas

**Resuelta sin hardware nuevo.** El plan pedía un JVB en un servidor dedicado
(1 Gbit/s, sin tope de tráfico). Con el uso real no hace falta. Detalle,
metodología y pendientes: [docs/CAPACIDAD-500.md](docs/CAPACIDAD-500.md).

**Modelo de uso real** (palabras del administrador):

> *"se conectan 500 pero solo el moderador prende la cámara y/o presenta
> pantalla; nadie más; los demás tienen el micrófono cerrado. […] todos están
> escuchando a una única persona presentando siempre."*

El JVB reenvía una sola pista de vídeo a cada oyente. El coste crece con los
oyentes y el límite es la **subida del VPS (~220 Mbit/s medidos)**, no la CPU.

**Medición en producción (2-nov-2026)**: 6 receptores reales + 1 emisor con
cámara, contando los bytes enviados por las interfaces físicas del host
(`/proc/net/dev`):

| | Antes de la línea `bitrate` | Después |
|---|---|---|
| Subida total | 2,43 Mbit/s | 1,90 Mbit/s |
| Por receptor | 0,405 Mbit/s | 0,316 Mbit/s |
| Extrapolado a 500 | 203 Mbit/s | 158 Mbit/s |

Desglose estimado a 500 con el vídeo del ponente a ~320 kbit/s: audio ~15 +
vídeo ~160 + señalización ~10 = **~175–185 Mbit/s de 220**. Además, el operador
hizo el 2-nov una prueba con **50 personas** (cámara, audio y pantalla) sin
problemas.

**Cambio de configuración** (desplegado en producción el 2-nov; en el repo,
pendiente de commit):

```js
config.constraints = {
    video: {
        height: { ideal: 360, max: 720, min: 180 },
        bitrate: { ideal: 280000, max: 320000 }
    }
};
```

> ⚠️ **Alcance del tope, verificado.** En el bundle de
> `stable-11031`, `config.constraints` solo alimenta el `getUserMedia` de la
> **cámara**, y la **pantalla compartida no usa `config.constraints`**: toma
> `desktopSharingFrameRate`, `resolution` y
> `screenShareSettings`. El tope `constraints.video.bitrate` **sí** lo aplica el
> navegador a la cámara (medido: 0,405 → 0,316 Mbit/s por receptor; es una
> medición controlada, no un A/B con repeticiones). Para la pantalla, el
> bitrate lo regula el JVB de forma adaptativa según la red de cada receptor.
> **La conclusión no depende del tope**: sin él salen 203 Mbit/s, también por
> debajo de 220.

**Conclusión:** no hace falta servidor dedicado. Por encima de la subida del
VPS, el límite es **la red de cada vecino**. El JVB adapta lo que envía a cada
receptor: a quien no puede recibir la pantalla se la recorta o la suspende
(`insufficient bandwidth` en el log del JVB) y la ve degradada; con ~3 Mbit/s la
ve perfecta. Por eso la **moderación A/V** es importante: si solo transmite quien
tiene la palabra, el ancho de banda de cada uno se reserva para esa persona.

**Repetir la medición:** `python3 loadtest/medir-bitrate.py [N_RECEPTORES] [SEGUNDOS]`
(por defecto 6 y 40). Crea y borra una reunión de prueba en producción
([loadtest/README.md](loadtest/README.md#medir-el-ancho-de-banda-por-oyente-medir-bitratepy)).

**Pendiente:** tope de tráfico mensual del VPS (panel del proveedor), prueba con
500 reales, comportamiento con muchas redes distintas a la vez y el modo
"asamblea" del panel (`channelLastN` a 1 y menos bitrate de pantalla en
reuniones grandes; en cola, **no implementado**).

## Fase 7 — Operación

### 7.1 Monitorización

| Qué | Cómo | Estado |
|---|---|---|
| Web y `/healthz` del admin | watchdog de Hermes cada 2 min → Telegram (`check-meet-jitsi.sh`) | **hecho** |
| TURN (STUN, Allocate con credencial, TLS 443, caducidad del cert) | `scripts/check-turn.sh`, llamado al final de `check-meet-jitsi.sh` (mismo watchdog, cada 2 min) | **hecho** (desde el 1-nov) |
| Renovación del cert del TURN | `scripts/turn-cert-cron.sh` | **no instalado**: no hace falta mientras se use el autofirmado (caduca en 2036) |
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

Estado en producción (2-nov-2026): **1 respaldo** (`cerroazul-backup-20261101-034041.tar.gz`
en `/opt/jitsi-meet/backups/`), passphrase en `/root/.backup_passphrase` (600, root) y
**sin cron diario** todavía.

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

**Lo que se midió (1-nov-2026, commit `0782429`):** sala única, 1 admin con audio +
receptores en modo load-test. Se lanzaron pruebas de 10, 50 y 120 receptores; el **pico fue
de 48 participantes simultáneos**, con 0 `bridge_failures`, JVB al 9–17 % de CPU y 380 MB,
y 0 errores en Prosody. El límite lo puso la RAM de los hosts que generaban los clientes,
**no el servidor**. Detalle y cómo repetirlo: [loadtest/README.md](loadtest/README.md).

> Antes de una prueba de 600: `MAX_PARTICIPANTS` vale hoy `500` y Prosody rechaza en
> silencio a partir de ahí. Hay que subirlo (≥ 610) para la prueba; `run.sh` lo comprueba.

## Limitaciones Conocidas

- **500 es una extrapolación, no una prueba**: la mayor prueba real es de 50 personas
  (2-nov) y el pico de la prueba de carga, de 48. El ancho de banda por oyente está medido y
  a 500 cabe en la subida del VPS, **si solo transmite una persona** (ver Fase 5).
- **Para que un residente comparta pantalla**, el admin tiene que pulsar "Habilitar cámara", y
  repetirlo si el residente recarga (ver la sección de pantalla compartida).
- Grabación solo en el PC del admin (Chrome de escritorio). No hay Jibri ni grabación en servidor.
- **El videobridge reenvía los mensajes de endpoint sin contenido** (JVB `2.3-295`): por eso
  «Lower all hands» nativo no funciona y el panel baja las manos por XMPP. Otras funciones de
  Jitsi que usan ese canal (reacciones, control remoto…) **pueden estar afectadas: pendiente de
  revisar**. Bajar manos desde la **app móvil** de Jitsi: sin probar.
- Sin autoescalado (un solo JVB, sin Octo).
- 1 solo worker de Gunicorn para el admin panel (suficiente).
- El TLS público lo pone el Caddy compartido del host (`hermes-caddy`), no este stack.

## Índice de la documentación

| Documento | Léelo cuando… |
|---|---|
| [README.md](README.md) | Quieres el estado actual, las fases y cómo operar el sistema (este fichero) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Necesitas saber qué corre dónde: servidores, contenedores, rutas de Caddy, TURN, grabación |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Algo falla. Si "no se ve la pantalla", empieza por el bug de la pantalla compartida; si "no bajan las manos", por el del botón "Bajar todas las manos" |
| [docs/MODERACION-MANOS.md](docs/MODERACION-MANOS.md) | Vas a moderar y quieres bajar las manos levantadas (una o todas): procedimiento, diagnóstico en 1 min, limitaciones |
| [docs/SOLUCION-PANTALLA.md](docs/SOLUCION-PANTALLA.md) | Vas a moderar una asamblea donde un residente compartirá pantalla: procedimiento, diagnóstico en 2 min y falsas pistas |
| [docs/INVESTIGACION-PANTALLA.md](docs/INVESTIGACION-PANTALLA.md) | Quieres la evidencia completa del bug de la pantalla (código de Jicofo y del JVB, logs, cronología) |
| [docs/BACKUP-RESTORE.md](docs/BACKUP-RESTORE.md) | Vas a respaldar, programar el cron o restaurar en un servidor limpio |
| [docs/INTEGRACION-JITSI.md](docs/INTEGRACION-JITSI.md) | Trabajas en la integración con votacionph.us (API de tokens, cliente JS, cabeceras) |
| [integracion/README.md](integracion/README.md) | Eres del equipo de votacionph y vas a embeber Jitsi |
| [admin-panel/README.md](admin-panel/README.md) | Necesitas la referencia de las rutas del panel y de la API de tokens |
| [turn/README.md](turn/README.md) | Vas a tocar el TURN: despliegue, firewall, certificado, watchdog |
| [docs/CAPACIDAD-500.md](docs/CAPACIDAD-500.md) | Quieres saber por qué el VPS aguanta 500 oyentes, de dónde salen los números y qué falta probar |
| [loadtest/README.md](loadtest/README.md) | Vas a repetir o ampliar la prueba de carga o la medición de ancho de banda |
| [loadtest/malleus-sala-prueba.md](loadtest/malleus-sala-prueba.md) | Necesitas los comandos exactos de Malleus para `meet.bytracking.net` |
| [docs/GRABACION-ADMIN.md](docs/GRABACION-ADMIN.md) | Eres el administrador y vas a grabar una asamblea o convertirla a MP4 |
| [docs/GRABACION-PASO0.md](docs/GRABACION-PASO0.md) | Vas a verificar la grabación en los PCs reales (checklist pendiente) |
| [docs/SPEC-GRABACION.md](docs/SPEC-GRABACION.md) (+ mockups) | Quieres el diseño de la grabación (Fase 9). Es una spec, no el estado actual |
| [docs/SPEC-DISENO.md](docs/SPEC-DISENO.md) (+ mockups) | Quieres el diseño del rediseño visual (Fase 8). Es una spec, no el estado actual |
| [docs/DISENO-AUDITORIA.md](docs/DISENO-AUDITORIA.md) | Quieres ver cómo se implementó y verificó el rediseño, paso a paso |
| [docs/SETUP_HISTORY.md](docs/SETUP_HISTORY.md) | Te interesa la historia: la instalación original de septiembre (dominio viejo). No se actualiza |

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
- Prosody XMPP server (con 86 plugins de auth_token, av_moderation, breakout, polls, etc.)
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
`static/bajar-manos.js` (posterior al rediseño) añade los suyos: `#manos-bajar`, `#manos-estado`,
`#jitsi iframe`, y lee `#lista .mano`; crea `#manos-lista` fuera de `#lista` y de `.gl`.

## Fase 9 — Grabación local y panel multi-conjunto

### Panel multi-conjunto (sin marca fija)

Ninguna plantilla lleva el nombre del conjunto. Todo sale de `admin-panel/instance/admin.env` (ver `admin.env.example`), con valores por defecto neutros. El panel funciona igual si faltan las variables:

| Variable | Uso | Default |
|---|---|---|
| `JITSI_SITE_NAME` | Cabecera, login, `<title>`, banda y pie de las páginas públicas | `Panel de reuniones` |
| `JITSI_SITE_SUBTITLE` | Texto junto a la marca / bajo el título del login | `Reuniones` |
| `JITSI_LEGAL_OWNER` | Responsable del tratamiento en el aviso de grabación | `JITSI_SITE_NAME` |

El dominio ya era variable (`PUBLIC_URL` en el `.env` de Jitsi).

En producción (2-nov-2026): `JITSI_SITE_NAME=bytracking`, `JITSI_SITE_SUBTITLE="Asambleas virtuales"`, `JITSI_LEGAL_OWNER=bytracking LLC`. El aviso legal de la grabación usa `JITSI_LEGAL_OWNER`.

### Grabación en el PC del administrador

Botón **Grabar esta reunión** en la sala de moderación (`/admin/reunion/<id>/sala`). Graba **vídeo + audio** (720p/15 fps, WebM VP8/Opus, ≈ 0,5 GB/h) de la pestaña recortada a la reunión, mezcla el micro del admin (solo cuando está abierto en Jitsi) y **guarda en el PC del admin**. **Cero subida al servidor**: no hay ninguna ruta que reciba grabaciones. Solo Chrome de escritorio (macOS y Windows). Sin límite de duración.

| Pieza | Qué es |
|---|---|
| `admin-panel/app/static/grabacion.js` | Detección, 4 comprobaciones anti-grabación-muda, mezcla, `MediaRecorder`, avisos, recuperación. Se carga **entre** `external_api.js` y el script congelado de la sala, cuyo código **no cambia** (envuelve el constructor de la API) |
| `admin-panel/app/static/grabacion-worker.js` | Escritura incremental en OPFS cada 5 s (sobrevive a un cierre brusco de Chrome; copias 7 días) |
| `page_sala.html` | Tarjeta «Grabación», diálogos, `.grab-zona` (envuelve `#jitsi` + franja legal) |
| `scripts/grabacion/convertir-mp4.{command,bat}` | Conversión a MP4 (H.264 + AAC, `+faststart`) en el PC del admin |
| `scripts/grabacion/prueba-paso0.html` | Página de verificación para los PCs reales |
| `scripts/grabacion/probar-grabacion-headless.py` | Prueba automática de punta a punta en Chromium (API de Jitsi simulada) |

Grabar **no depende** de la pantalla compartida de Jitsi: el admin graba su propia pestaña (`getDisplayMedia`), así que el bug de la pantalla compartida no le afecta. Si un residente comparte, la grabación recoge lo que el admin ve en su pestaña.

Documentos: [`docs/SPEC-GRABACION.md`](docs/SPEC-GRABACION.md) (diseño + §10 implementación), [`docs/GRABACION-ADMIN.md`](docs/GRABACION-ADMIN.md) (guía de uso y conversión, también con HandBrake), [`docs/GRABACION-PASO0.md`](docs/GRABACION-PASO0.md) (**checklist pendiente en Mac y Windows**).

## Compartir pantalla: qué se puede y qué no (importante)

> **Compartir pantalla requiere que el administrador habilite la cámara de quien
> comparte. Es contraintuitivo, pero así funciona Jitsi.**

Costó dos días y varios redespliegues en plena asamblea. La evidencia completa está en
[docs/INVESTIGACION-PANTALLA.md](docs/INVESTIGACION-PANTALLA.md). El procedimiento, el
diagnóstico y las alternativas, en [docs/SOLUCION-PANTALLA.md](docs/SOLUCION-PANTALLA.md).

### El mecanismo real

1. La sala de moderación del panel activa la moderación de **audio y vídeo** al entrar el
   admin. Es lo correcto en una asamblea: nadie transmite sin permiso.
2. Con la moderación de vídeo activa, Jicofo manda **`forceMuteVideo`** al JVB para cada
   participante no moderador que entra.
3. El JVB silencia **por endpoint, no por pista**: descarta todo el vídeo de ese
   participante, la cámara (`-v0`) **y también la pantalla** (`-v1`, `videoType=desktop`).
4. El residente comparte y **ve su pantalla** (la vista es local). El JVB la recibe y la
   descarta. **Los demás no ven nada**, y no sale ningún error.
5. Cuando el admin pulsa **"Habilitar cámara"** (`approveVideo`), el residente entra en la
   whitelist de vídeo. Con su siguiente petición de des-silenciado, Jicofo le quita el
   `forceMuteVideo` y el JVB reenvía la pantalla.
6. El admin es moderador: nunca recibe `forceMuteVideo` y su pantalla siempre llega.

Pasa igual en `stable-11248` y en `master`: **actualizar Jitsi no lo arregla**.

### Procedimiento para que un residente comparta pantalla

1. **Moderación de vídeo activada** (audio + vídeo). Es la recomendada para asambleas grandes.
2. El participante que va a compartir **levanta la mano**.
3. El administrador le pulsa **"Habilitar cámara"** → entra en la whitelist de vídeo → el
   JVB deja de silenciar su endpoint.
4. Ese participante pulsa **"Compartir pantalla"**. Ahora sí la ven todos.
5. Si a los ~10 s no se ve, que el participante **encienda su cámara** un momento (ya puede)
   y la apague si quiere. Esa petición es la que levanta el bloqueo en el JVB.

> ⚠️ **Hay que repetirlo si el participante recarga o se reconecta.** Cada reconexión es
> un endpoint nuevo y vuelve a aplicarse el silenciado. Por eso **no** hay que decirle a
> nadie "recarga a ver si se arregla": eso lo vuelve a romper.

Confirmado en producción el 2-nov-2026 a las 12:33 (hora de Bogotá): "Habilitar cámara" →
`Will unmute … for VIDEO` en Jicofo → `Unmuting incoming video` en el JVB → la pantalla se vio.

Plan B si no funciona: "Apagar cámara" sobre ese participante (también levanta el bloqueo;
comprobado), o que comparta el admin.

Comprobarlo en el momento (solo lectura):

```bash
# endpoint de quien comparte
ssh chatbotph 'docker logs jitsi-jvb --since 15m 2>&1 | grep -o "name=\"[0-9a-f]*-v1\" ssrc=\"[0-9]*\" videoType=\"desktop\"" | cut -d\" -f2 | sort -u'
# ¿lo está silenciando el JVB? (Muting = sí; Unmuting = ya no)
EP=<id>; ssh chatbotph "docker logs jitsi-jvb --since 4h 2>&1 | grep 'epId=$EP' | grep forceMuteVideo | tail -1"
```

### Barra y moderación de pantalla en `stable-11031`

| Intento | ¿Funciona? |
|---|---|
| `config.toolbarButtons` en la **query** de la URL | ❌ **No.** El bundle no lee esa clave de la URL. Solo existe `config.customToolbarButtons`, que son botones EXTRA |
| `configOverwrite` en el **iframe** (`JitsiMeetExternalAPI`) | ✅ **Sí.** Es lo que usa la sala de moderación (el admin) |
| `config.toolbarButtons` en el **`config.js` del servidor** | ✅ **Sí**, pero es **global**: no distingue admin de residente |
| Moderar la pantalla con `toggleModeration(..., "desktop")` | ⚠️ Existe en Prosody, pero el iframe API **no** tiene `approveDesktop`: el panel no podría dar el permiso. **No se activa** |

Estado actual: la barra del sitio incluye `desktop` y la moderación es solo de `audio` y `video`.

### Configuración de vídeo y pantalla (NO cambiar sin leer esto)

Valores actuales, **idénticos a los de la Fase 3** (`e30c36d`):

```js
config.resolution = 360;                                        // cámara
config.constraints = { video: { height: { ideal: 360, max: 720, min: 180 } } };
// + en producción desde el 2-nov: bitrate: { ideal: 280000, max: 320000 } (ver Fase 5;
//   efecto no verificado, la pantalla no lee config.constraints)
config.channelLastN = 4;
config.maxFullResolutionParticipants = 1;
config.desktopSharingFrameRate = { min: 5, max: 15 };           // pantalla
// NO existe config.desktopSharingResolution: se deja sin definir a propósito
```

| Intento (1-nov) | Resultado |
|---|---|
| `desktopSharingResolution = 1920×1080` (`ce48ac9`) | Pantalla **en negro** |
| `desktopSharingResolution = 800×600` (`99ffbe7`) | **Igual**, en negro |
| Sin `desktopSharingResolution` (actual, `86e6319`) | Es la configuración que se mantiene. La pantalla se ve **si se habilita la cámara de quien comparte** |

**No añadas `desktopSharingResolution`.** La resolución no era la causa: aquellas pruebas
coincidieron con reconexiones del emisor, es decir, con el silenciado. Subirla solo aumenta
el ancho de banda que necesita cada receptor.

### Reglas para no romperlo otra vez

1. **No quites `desktop` de `config.toolbarButtons`**: rompe las reuniones pequeñas, donde
   alguien tiene que mostrar un documento.
2. **No actives `toggleModeration(..., "desktop")`**: el panel no tiene forma de aprobar.
3. **No añadas `config.desktopSharingResolution`.**
4. **No subas `maxFullResolutionParticipants`** a 2 ni toques `channelLastN` por este
   problema: no intervienen.
5. **No reinicies ni redespliegues `web`, `jicofo`, `jvb` o `prosody` durante una asamblea**
   para "probar": cada reconexión reaplica el silenciado y el fallo parece aleatorio.
6. Ante cualquier cambio aquí: **probar con dos personas reales** (una comparte, otra mira).
   Que "el JVB recibe la pantalla" **no** prueba que el otro la vea.

### Si la pantalla se ve negra solo para alguien

Si el emisor ya está des-silenciado (`Unmuting` arriba) y **una** persona la ve en negro,
es su red:

```bash
ssh chatbotph 'docker logs jitsi-jvb --since 30m 2>&1 | grep -i "insufficient bandwidth"'
```

`Sources suspended … (bwe=346343 bps): [<id>-v1]` → el JVB suspende la pantalla para ese
receptor por falta de ancho de banda. En el servidor no hay nada que tocar: esa persona
necesita mejor red (cable o wifi más cercano). Esto **no** explica que no la vea nadie.

## Licencia

Privado - bytracking LLC
