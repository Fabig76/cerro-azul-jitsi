# Cerro Azul - Jitsi Meet

Plataforma de videoconferencias self-hosted para el Conjunto Residencial Cerro Azul, corriendo en `meet.urbcerroazul.com`.

## Stack

- **Jitsi Meet** stable-9111 (web + prosody + jicofo + jvb)
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

# 6. Agregar el virtualhost al Caddy (reverse proxy existente)
# Ver docs/SETUP_HISTORY.md seccion "PASO 4" para el bloque Caddy
```

### Verificar

```bash
# Healthcheck del admin
curl https://meet.tu-dominio.com/healthz
# Esperado: {"service":"jitsi-admin","status":"ok"}

# Login admin
# Abrir https://meet.tu-dominio.com/admin/login
# Usuario: Hguaza76
# Contrasena: la que configuraste en /opt/jitsi-admin/instance/admin.env
```

## Estructura del Repositorio

```
.
├── README.md                       # Este archivo
├── docker-compose.yml              # Stack Jitsi completo
├── .env.example                    # Template de configuracion
├── .env                            # NO COMMITEAR - configuracion real
├── gen-passwords.sh                # Genera passwords aleatorios
├── .gitignore                      # Ignora .env, __pycache__, etc
├── prosody/
│   ├── conf.d/
│   │   └── jitsi-meet.cfg.lua      # Configuracion Prosody con TURN
│   └── prosody-plugins/            # 84 plugins de Jitsi
├── admin-panel/
│   ├── Dockerfile                  # Imagen Docker del admin
│   ├── app.py                       # App Flask principal
│   ├── tpl.html                     # Template base
│   ├── page_login.html              # Pagina de login
│   ├── page_panel.html              # Panel de admin
│   ├── page_qr_view.html            # Vista del QR + link
│   ├── page_reunion.html            # Pagina publica de reunion
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
sqlite3 /opt/jitsi-admin/instance/reuniones.db "SELECT id, slug, titulo FROM reuniones WHERE activo=1"
```

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

- **DB**: SQLite en `/opt/jitsi-admin/instance/reuniones.db`
- **Passwords XMPP/JWT**: archivo `/opt/jitsi-meet/.env` (chmod 600)
- **Password admin**: archivo `/opt/jitsi-admin/instance/admin.env` (chmod 600)
- **TLS Caddy**: emitido automaticamente por Let's Encrypt

## Stack Tecnologico

- Docker + Docker Compose
- Jitsi Meet stable-9111
- Prosody XMPP server (con 84 plugins de auth_token, av_moderation, breakout, polls, etc.)
- Flask 3 + Gunicorn para el admin panel
- Caddy 2 como reverse proxy
- Python 3.12 + SQLite para el admin

## Licencia

Privado - Cerro Azul Residencial
