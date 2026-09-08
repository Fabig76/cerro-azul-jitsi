# Arquitectura Detallada

## Componentes

### 1. Jitsi Web (`jitsi-web:stable-9111`)

- Basado en Nginx + la UI de Jitsi Meet (HTML/JS)
- **Puerto interno:** 80
- **Puerto externo:** ninguno directo (Caddy hace proxy)
- **Imagen:** ~98 MB

Sirve los archivos estaticos de Jitsi Meet y maneja WebSocket para señalizacion cliente↔Jicofo.

**Configuracion personalizada (`config.js`):**
- `domain = 'meet.urbcerroazul.com'`
- `bosh = '/http-bind'` (ruta relativa, Caddy proxy)
- `websocket = 'wss://meet.urbcerroazul.com/xmpp-websocket'`
- `tokenAuthUrl = '/auth-token'` (para JWT del admin)
- `prejoinConfig.enabled = false` (entrada directa a la sala)
- Toolbar minima (sin filmstrip, sin etherpad, etc)
- Resolucion 720p max, audio Opus 32kbps

### 2. Prosody XMPP (`jitsi-prosody:stable-9111`)

- XMPP server de Jitsi
- **Puertos internos:** 5222 (cliente), 5347 (componentes), 5280 (BOSH/WS)
- **Imagen:** ~59 MB

**Virtualhosts:**
- `meet.urbcerroazul.com` - virtualhost principal con `authentication = "jitsi-anonymous"` (los participantes se conectan anonimos)
- `auth.meet.urbcerroazul.com` - virtualhost interno para componentes (focus, jvb) con `authentication = "internal_hashed"`

**Components internos:**
- `internal-muc.meet.urbcerroazul.com` - MUC para JVB (bridge selection)
- `muc.meet.urbcerroazul.com` - MUC de salas (donde entran los participantes)
- `focus.meet.urbcerroazul.com` - cliente proxy para Jicofo
- `speakerstats.meet.urbcerroazul.com` - estadisticas
- `conferenceduration.meet.urbcerroazul.com` - duracion de reuniones
- `endconference.meet.urbcerroazul.com` - eventos fin de reunion
- `avmoderation.meet.urbcerroazul.com` - moderacion de audio/video
- `lobby.meet.urbcerroazul.com` - lobby/sala de espera
- `breakout.meet.urbcerroazul.com` - salas secundarias

**Plugins habilitados (modules_enabled):**
```
bosh, websocket, smacks, turncredentials, pubsub, ping,
speakerstats, conference_duration, room_metadata,
end_conference, muc_lobby_rooms, muc_breakout_rooms,
av_moderation, mod_turncredentials
```

**Configuracion TURN (clave para que funcione):**
```lua
TURNCREDENTIALS_secret = "<32 bytes hex>"
TURNCREDENTIALS=*** stun, turn, turns }
```

### 3. Jicofo (`jitsi-jicofo:stable-9111`)

- Conference Focus - maneja las salas y asigna bridges
- **Puerto interno:** 8888 (HTTP)
- **Imagen:** ~144 MB

**Funciones:**
- Recibe conference-requests de los clientes via XMPP
- Asigna bridges (JVB) a cada sala
- Maneja la negociación SDP
- Detecta cuando un bridge se desconecta

**Configuracion:**
- `brewery-jid = "jvbbrewery@internal-muc.meet.urbcerroazul.com"` (donde se registran los JVBs)
- Conecta a Prosody como `focus@auth.meet.urbcerroazul.com`

### 4. JVB - Video Bridge (`jitsi-jvb:stable-9111`)

- El "router" de video/audio
- **Puerto interno privado:** 8080 (REST + health)
- **Puerto interno publico:** 9090 (WebSocket)
- **Puerto UDP:** 10000 (RTP media)
- **Puerto TCP fallback:** 4443
- **Imagen:** ~209 MB

**Dos servidores HTTP:**
- **Privado (8080):** `/about/health`, `/about/version`, `/colibri/*` - solo accesible internamente
- **Publico (9090):** WebSocket para clientes - este NO tiene `/about/health`

**Endpoints clave:**
- `http://jvb:8080/about/health` → 200 OK (lo que Jicofo consulta)
- `http://jvb:8080/about/version` → JSON con version
- `http://jvb:10000/udp` → media WebRTC de clientes

**Configuracion clave:**
- `apis.rest.enabled = true` (necesario para `/about/health`)
- `http-servers.private.host = 0.0.0.0` (puerto 8080)
- `http-servers.public.host = 0.0.0.0 port = 9090`
- `ice4j.harvest.mapping.static-mappings` con `public-address = "84.247.165.81"`
- `JVB_PUBLIC_ADDRESS=84.247.165.81` (IP publica para NAT traversal)

### 5. Admin Panel (`jitsi-admin:local`)

- Flask + Gunicorn para gestionar reuniones
- **Puerto interno:** 8081 (solo localhost)
- **Imagen:** ~150 MB (custom build)

**Funciones:**
- Login con usuario unico (Hguaza76)
- Crear reuniones (titulo, fecha, hora, duracion)
- Generar QR para cada reunion
- Lista de reuniones activas
- Firmar JWT unico por participante
- Pagina publica para unirse

**Stack:**
- Python 3.12 + Flask 3 + Gunicorn
- SQLite para DB
- qrcode para generar QRs
- PyJWT para firmar tokens

**Endpoints:**
- `GET /healthz` → JSON status
- `GET /admin/login` + `POST /admin/login`
- `GET /admin` (panel)
- `POST /admin/reunion`
- `GET /admin/qr/<id>` (vista HTML o PNG)
- `GET /reunion/<slug>` (publica)
- `POST /unirse` (genera JWT, redirige a Jitsi)

---

## Flujo de Datos

### Cuando un participante entra a una reunion:

```
1. Navegador carga https://meet.urbcerroazul.com/reunion/abc123
   |
   v
2. Caddy recibe request en :443
   - Ve host: meet.urbcerroazul.com
   - Ruta /reunion/* → reverse_proxy admin:8081
   |
   v
3. Flask admin panel recibe GET /reunion/abc123
   - Lee DB SQLite
   - Renderiza page_reunion.html con form
   |
   v
4. Usuario llena nombre y envia POST /unirse
   - Flask genera JWT unico (sub_id aleatorio)
   - Flask redirige (302) a:
     https://meet.urbcerroazul.com/<sala>#jwt=<token>
   |
   v
5. Navegador carga https://meet.urbcerroazul.com/<sala>
   - Caddy ve ruta que no matchea admin → reverse_proxy web:80
   |
   v
6. Jitsi Meet UI (Nginx) sirve index.html + JS
   - JS lee JWT del fragment (#jwt=)
   - JS abre WebSocket a wss://meet.urbcerroazul.com/xmpp-websocket
   |
   v
7. Caddy pasa WebSocket a Jitsi web
   - Nginx pasa a Prosody
   - Prosody autentica via JWT (mod_auth_token + token_verification)
   - Prosody verifica el JWT firmado por nuestro admin
   |
   v
8. Cliente envia conference-request IQ a focus@auth.meet.urbcerroazul.com
   - Pasa por Caddy → web → prosody → jicofo
   - Jicofo acepta y asigna JVB
   |
   v
9. Jicofo consulta /about/health al JVB en http://jvb:8080/about/health
   - JVB responde 200 OK → es operacional
   |
   v
10. Cliente envia STUN binding request para UDP 10000 al VPS:10000
    - Firewall lo deja pasar (abierto 10000/udp)
    - JVB procesa y negocia WebRTC
    |
    v
11. Cliente tambien pide credenciales TURN al Prosody
    - mod_turncredentials genera username/password basado en TURNCREDENTIALS_secret
    - Devuelve lista de servers TURN: meet.urbcerroazul.com:3478 (STUN), :443 (TURNS)
    - El cliente intenta TURN si UDP bloqueado
    |
    v
12. Conexion WebRTC establecida
    - Audio/video fluyen entre cliente y JVB via UDP 10000
    - JVB rutea entre participantes
```

---

## Red Docker

```
Network: jitsi-meet_jitsi (bridge)
├── jitsi-web       (172.21.0.X)
├── jitsi-prosody   (172.21.0.Y)
├── jitsi-jicofo    (172.21.0.Z)
├── jitsi-jvb       (172.21.0.5)
└── jitsi-admin     (172.21.0.7)
```

Caddy (en otra red `hermes-agent_hermes-net`) se conecta a `jitsi-meet_jitsi` via `docker network connect`.

---

## Volumenes

### Jitsi (`/opt/jitsi-meet/`)

| Directorio host | Container mount | Notas |
|------------------|------------------|-------|
| `./web/config` | `/config` | Regenerado por entrypoint |
| `./prosody/config` | `/config` | Regenerado por entrypoint |
| `./prosody/prosody-plugins` | `/prosody-plugins` | 84 plugins |
| `./jvb/config` | `/config` | Regenerado |
| `./jicofo/config` | `/config` | Regenerado |
| `./web/crash` | `/crash` | Crash dumps |
| `./web/letsencrypt` | `/etc/letsencrypt` | Certificados |

### Admin (`/opt/jitsi-admin/`)

| Directorio host | Container mount | Notas |
|------------------|------------------|-------|
| `./app/` | `/app/` | Codigo fuente |
| `./instance/` | `/app/instance/` | DB + admin.env + logs |

---

## SSL/TLS

- **HTTPS:** Terminado en Caddy existente
- **Let's Encrypt:** Automatico via Caddy para `meet.urbcerroazul.com`
- **Cert renewal:** Caddy lo maneja, no requiere intervencion
- **WebSocket:** `wss://` pasa por Caddy via Upgrade header

Los certificados DENTRO de los containers Jitsi (para XMPP) son **auto-firmados** porque solo se usan internamente entre containers Docker. El TLS público solo lo maneja Caddy.

---

## Persistencia

| Que | Donde | Backup |
|-----|-------|--------|
| DB reuniones | `/opt/jitsi-admin/instance/reuniones.db` | Copiar a S3/glacier |
| Cert Let's Encrypt | `/data/caddy` (volume Caddy) | Backup automatico Caddy |
| Config Prosody | `/opt/jitsi-meet/prosody/config/` | Git (anonimizado) |
| Passwords | `.env` files (chmod 600) | NO commitear a git |
| Certs XMPP (auto-firmados) | Se regeneran al iniciar | No criticos |

---

## Restart del Stack

```bash
# Si solo necesitas reiniciar servicios (config NO cambio):
cd /opt/jitsi-meet
docker compose restart jvb jicofo prosody web

# Si cambio el .env o docker-compose.yml:
cd /opt/jitsi-meet
docker compose down
docker compose up -d

# Si quiero regenerar configs desde .env (despues de cambios):
sudo rm -rf prosody/config/conf.d/*.lua prosody/config/prosody.cfg.lua
sudo rm -f jicofo/config/jicofo.conf jicofo/config/logging.properties
sudo rm -f web/config/config.js web/config/interface_config.js
sudo rm -rf web/config/nginx web/config/keys
docker compose up -d

# Para el admin panel:
docker restart jitsi-admin
# o:
cd /opt/jitsi-meet
docker compose up -d --force-recreate admin
```
