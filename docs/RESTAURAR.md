# Restaurar Cerro Azul Jitsi en un servidor nuevo

Esta guía sirve para reconstruir el proyecto entero si se pierde un servidor,
usando la copia de seguridad que `scripts/backup-completo.sh` deja en Google
Drive (ver [`BACKUP-DRIVE.md`](BACKUP-DRIVE.md)). Se puede seguir sin conocer el
proyecto: cada paso tiene los comandos exactos y lo que debe salir.

## 0. Qué hay que tener

Dos ficheros de la carpeta **backup** de Drive
(<https://drive.google.com/drive/folders/1Ov4zUYBtyp01QLlDT8arobe29q6n8VuB>),
de la **misma fecha**:

| Fichero | Qué es |
|---|---|
| `cerro-azul-jitsi-proyecto-AAAAMMDD-HHMM.tar.gz` | Paquete A, **sin cifrar**: el repo con su historial (`git bundle`), el árbol de trabajo, el deploy de producción sin secretos, el Caddyfile y el watchdog |
| `cerro-azul-jitsi-secretos-AAAAMMDD-HHMM.tar.gz.enc` | Paquete B, **cifrado**: `.env`, `admin.env`, la BD de reuniones, certificados y claves, y los secretos del TURN |

Y **la clave** de cifrado del paquete B. **No está en el repo ni en Drive en
claro.** Copia local: `/root/.cerro-azul-backup/CLAVE.txt` en el host de
desarrollo; el dueño debe tener otra copia fuera de los servidores (gestor de
contraseñas). Sin ella el paquete B no se puede abrir.

Cómo está repartido hoy (para saber qué se ha perdido):

| Máquina | IP | Qué corre |
|---|---|---|
| `chatbotph` | 84.247.165.81 | Jitsi (`/opt/jitsi-meet`) + Caddy del host (contenedor `hermes-caddy`) |
| `vmi3186036` | 155.133.22.222 | TURN (`/opt/coturn`), el repo de desarrollo y el watchdog de Hermes |

## 1. Requisitos del servidor nuevo

- **Ubuntu 24.04** con Docker Engine y el plugin compose (`docker compose version` ≥ 2.20).
  ```bash
  curl -fsSL https://get.docker.com | sudo sh
  sudo apt-get install -y git openssl python3 sqlite3
  ```
- **Dominio**: hoy `meet.bytracking.net`. Su registro **A** debe apuntar a la IP del
  servidor nuevo **antes** del paso 7 (Caddy pide el certificado de Let's Encrypt al arrancar).
- **Puertos abiertos** en el firewall del servidor y en el del proveedor:
  ```bash
  sudo ufw allow 22/tcp
  sudo ufw allow 80/tcp
  sudo ufw allow 443/tcp
  sudo ufw allow 10000/udp comment 'Jitsi JVB media'
  sudo ufw enable
  ```
- Unos 4 GB de RAM y 2 vCPU como mínimo (el JVB es Java).

## 2. Recuperar los paquetes y el código

```bash
mkdir -p ~/restaurar && cd ~/restaurar
# Bajar los dos ficheros de Drive (navegador, o con la herramienta de Hermes):
#   GAPI="python $HOME/.hermes/skills/productivity/google-workspace/scripts/google_api.py"
#   $GAPI drive search "name contains 'cerro-azul-jitsi-' and '1Ov4zUYBtyp01QLlDT8arobe29q6n8VuB' in parents" --raw-query
#   $GAPI drive download <ID> --output <nombre>

mkdir proyecto && tar xzf cerro-azul-jitsi-proyecto-*.tar.gz -C proyecto
cat proyecto/MANIFIESTO.txt
(cd proyecto && sha256sum -c --quiet SHA256SUMS) && echo "paquete A integro"
```

El código, de una de estas dos formas (dan lo mismo; el bundle sirve aunque
GitHub no esté disponible):

```bash
git clone https://github.com/Fabig76/cerro-azul-jitsi.git
# o desde el bundle:
git bundle verify proyecto/repo/cerro-azul-jitsi.bundle
git clone proyecto/repo/cerro-azul-jitsi.bundle cerro-azul-jitsi
git -C cerro-azul-jitsi log --oneline | head
```

El MANIFIESTO dice en qué commit (`HEAD`) estaba el repo al hacer la copia.

> **Ojo: producción NO es un clon del repo.** Se despliega copiando ficheros,
> así que puede ir por delante o por detrás del repo. Lo que corría de verdad
> está en `proyecto/produccion/opt-jitsi-meet/`. Para restaurar producción tal
> cual estaba, usa esa copia como base (paso 4) y el repo solo como referencia.
> Compara antes: `diff -r cerro-azul-jitsi/admin-panel/app proyecto/produccion/opt-jitsi-meet/admin-panel/app`.

## 3. Descifrar los secretos

```bash
cd ~/restaurar
install -m 600 /dev/null CLAVE.txt
nano CLAVE.txt     # pegar la clave (una línea), guardar

openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -pass file:CLAVE.txt -in cerro-azul-jitsi-secretos-*.tar.gz.enc -out secretos.tar.gz
mkdir -m 700 secretos && sudo tar xzpf secretos.tar.gz -C secretos
rm secretos.tar.gz
sudo cat secretos/MANIFIESTO.txt
(cd secretos && sudo sha256sum -c --quiet SHA256SUMS) && echo "paquete B integro"
```

Si `openssl` dice `bad decrypt`, la clave no es la buena (o el fichero está
corrupto: compara su tamaño con el de Drive). El paquete B contiene:

```
opt-jitsi-meet/.env                                JWT_APP_SECRET, TURN_CREDENTIALS, contraseñas XMPP...
opt-jitsi-meet/admin-panel/instance/admin.env      hash de la contraseña del panel, API keys, marca
opt-jitsi-meet/admin-panel/instance/reuniones.db   las reuniones (copia consistente de sqlite)
opt-jitsi-meet/web/config/keys/                    cert.crt / cert.key del contenedor web
opt-jitsi-meet/prosody/config/certs/               certificados y claves de Prosody
vps-root/.backup_passphrase                        passphrase de scripts/backup.sh en el VPS
hermes/turn.env                                    TURN_CREDENTIALS para el watchdog
turn-vps/turnserver.conf, .secret,                 el TURN completo (con su static-auth-secret)
  docker-compose.turn.yml, certs/
CLAVE.txt                                          copia de la clave
```

## 4. Colocar los ficheros en `/opt/jitsi-meet`

```bash
D=/opt/jitsi-meet
sudo mkdir -p $D && sudo chown $USER: $D

# 4.1 El deploy tal cual estaba en producción (sin secretos)
cp -a ~/restaurar/proyecto/produccion/opt-jitsi-meet/. $D/
#     (alternativa: partir del repo -> cp -a ~/restaurar/cerro-azul-jitsi/. $D/ ; rm -rf $D/.git)

# 4.2 Los secretos, con sus permisos
S=~/restaurar/secretos/opt-jitsi-meet
sudo install -m 600 -o $USER $S/.env                               $D/.env
sudo install -m 600 -o $USER $S/admin-panel/instance/admin.env     $D/admin-panel/instance/admin.env
sudo install -m 644 -o $USER $S/admin-panel/instance/reuniones.db  $D/admin-panel/instance/reuniones.db
sudo mkdir -p $D/web/config/keys $D/prosody/config/certs
sudo cp -a $S/web/config/keys/.      $D/web/config/keys/
sudo cp -a $S/prosody/config/certs/. $D/prosody/config/certs/
sudo chmod 600 $D/web/config/keys/cert.key
sudo chmod 400 $D/prosody/config/certs/*.key
chmod 600 $D/docker-compose.yml

# 4.3 Passphrase de los respaldos locales del VPS (scripts/backup.sh)
sudo install -m 600 -o root -g root ~/restaurar/secretos/vps-root/.backup_passphrase /root/.backup_passphrase
```

**Si cambia la IP del servidor**, editar `$D/.env`:

```bash
grep -nE '^(PUBLIC_URL|XMPP_DOMAIN|JVB_ADVERTISE_IPS|TURN_HOST|TURNS_HOST|STUN_HOST)=' $D/.env
# JVB_ADVERTISE_IPS = IP pública NUEVA del servidor de Jitsi
# TURN_HOST / TURNS_HOST / STUN_HOST = IP del servidor del TURN (solo si también cambia)
# PUBLIC_URL / XMPP_DOMAIN = el dominio (solo si cambia el dominio)
```

Si cambia el **dominio**, además de `.env` hay que cambiarlo en el bloque de
Caddy (paso 7), en `admin.env` si lo menciona, y avisar a votacionph.us
(integración de la Fase 6).

Prosody (UID dentro del contenedor ≠ tu usuario) reescribe dueños de
`prosody/config` al arrancar; no hace falta tocarlos a mano.

## 5. Reconstruir las imágenes derivadas

Dos imágenes **no** se descargan: se construyen aquí.

| Servicio | Imagen | Se construye con |
|---|---|---|
| prosody | `jitsi-prosody-cerroazul:stable-11031` | `prosody/Dockerfile.prosody` (añade `mod_http_health`; sin él no se registran focus/jvb → 0 bridges → sin audio) |
| admin | `jitsi-admin:local` | `admin-panel/Dockerfile` (`app.py` y las plantillas van **dentro** de la imagen) |

```bash
cd /opt/jitsi-meet
docker compose config -q && echo "compose OK"        # valida .env + compose
docker compose build prosody admin
docker compose pull web jicofo jvb
```

## 6. Levantar

```bash
cd /opt/jitsi-meet
docker compose up -d --build
docker compose ps
```

Qué esperar: en 1–2 minutos los cinco contenedores (`jitsi-web`, `jitsi-prosody`,
`jitsi-jicofo`, `jitsi-jvb`, `jitsi-admin`) en `Up ... (healthy)`. El admin
espera a que Prosody esté sano. La primera vez el contenedor web genera
`web/config/config.js` e `interface_config.js` (por eso no se respaldan) y
aplica encima `custom-config.js` / `custom-interface_config.js`.

```bash
docker compose logs --tail=30 jvb | grep -i "joined\|error"
docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["bridge_selector"]; print("bridges:", d["operational_bridge_count"])'
# -> bridges: 1
```

## 7. Caddy (TLS público)

Jitsi escucha solo en `127.0.0.1:8080` (web) y `127.0.0.1:8081` (panel). El
HTTPS lo pone **Caddy en un contenedor** conectado a la red `jitsi-meet_jitsi`,
y llega a los servicios por nombre (`web:80`, `admin:8081`), nunca por `127.0.0.1`.

**Caso A — el servidor de Jitsi sigue siendo `chatbotph` con `hermes-caddy`:**
el Caddyfile del host está en el paquete A (`produccion/Caddyfile`) y lleva
también otros sitios (monitorlegal.org, minutasegura.com...).

```bash
F=/home/chatbotph/chatbotph/Caddyfile
cp -p $F $F.bak.$(date +%Y%m%d_%H%M%S)
# Es un bind-mount de FICHERO: sobrescribir EN SITIO (conserva el inodo).
# Nada de sed -i, mv ni editores que reemplazan el fichero.
cat ~/restaurar/proyecto/produccion/Caddyfile > $F
docker network connect jitsi-meet_jitsi hermes-caddy 2>/dev/null || true
docker exec hermes-caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
# -> "Valid configuration"
docker exec hermes-caddy caddy reload --adapter caddyfile --config /etc/caddy/Caddyfile
```

**Caso B — servidor nuevo sin Caddy:** se monta uno solo para Jitsi con el
bloque del repo (`infra/caddy/meet.bytracking.net.caddy`, que es la fuente de
verdad del vhost de Jitsi):

```bash
sudo mkdir -p /opt/caddy && cd /opt/caddy
sudo cp /opt/jitsi-meet/infra/caddy/meet.bytracking.net.caddy Caddyfile
docker run -d --name hermes-caddy --restart unless-stopped \
  -p 80:80 -p 443:443 -p 443:443/udp \
  -v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v caddy_data:/data -v caddy_config:/config \
  --network jitsi-meet_jitsi caddy:2-alpine
docker exec hermes-caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
```

Reglas (aprendidas por las malas):

- **`caddy validate` antes de `caddy reload`. Nunca `docker restart hermes-caddy`**
  (tira todos los sitios del host y, si el Caddyfile está mal, no vuelve).
- Nunca persistir con `POST /load` a la admin API: vive en memoria y se pierde
  al reiniciar (así estuvo el sitio caído dos semanas en octubre de 2026).
- El bloque debe tener **`/api/reuniones/*`** en el matcher `@admin` (ver
  "Problemas frecuentes").

## 8. El TURN (solo si se ha perdido el servidor del TURN)

Va en un **servidor aparte** (hoy 155.133.22.222), con la imagen oficial
`coturn/coturn:4.6.3-r3`. Su secreto (`static-auth-secret`) **debe ser igual**
a `TURN_CREDENTIALS` del `.env` de Jitsi; el del paquete ya lo es.

```bash
sudo mkdir -p /opt/coturn && cd /opt/coturn
T=~/restaurar/secretos/turn-vps
sudo cp -a $T/turnserver.conf $T/.secret $T/docker-compose.turn.yml /opt/coturn/
sudo cp -a $T/certs /opt/coturn/
# (alternativa: turn/docker-compose.turn.yml y turn/turnserver.conf del repo
#  y poner el secreto real en static-auth-secret)
sudo chown 65534:65534 turnserver.conf && sudo chmod 600 turnserver.conf
sudo chown -R 65534:65534 certs && sudo chmod 600 certs/turn_server_pkey.pem
sudo chmod 600 docker-compose.turn.yml
# turnserver.conf no fija ninguna IP (el contenedor usa la red del host).
# Si cambia la IP del TURN: TURN_HOST / TURNS_HOST / STUN_HOST en el .env
#   de Jitsi (y recrear prosody con las salas vacías).

sudo ufw allow 3478/udp ; sudo ufw allow 3478/tcp
sudo ufw allow 443/udp  ; sudo ufw allow 443/tcp     # 443/tcp OBLIGATORIO para turns
sudo ufw allow 49160:49200/udp                       # puertos de relay

sudo docker compose -f docker-compose.turn.yml up -d
```

Comprobar desde otra máquina con `scripts/check-turn.sh` (ver `turn/README.md`):
debe dar relay `OK` por UDP, TCP y TLS. Si el certificado del TURN se perdiera,
`scripts/turn-cert.sh` genera otro autofirmado (los clientes no lo validan).

Si el TURN cambia de IP o se cambia el secreto, **actualizar también**
`/root/.hermes/secrets/turn.env` del watchdog (paso 9) o alertará con 401.

## 9. El watchdog (Hermes)

Corre en el host de desarrollo (hoy `vmi3186036`), **fuera** del servidor de
Jitsi, para detectar también la caída del VPS entero. Cada 2 minutos mira
`https://meet.bytracking.net/`, `/healthz` y el TURN, y solo escribe (a
Telegram) si algo falla.

```bash
sudo install -m 711 ~/restaurar/proyecto/watchdog/check-meet-jitsi.sh /root/.hermes/scripts/check-meet-jitsi.sh
sudo install -d -m 700 /root/.hermes/secrets
sudo install -m 600 ~/restaurar/secretos/hermes/turn.env /root/.hermes/secrets/turn.env
cat ~/restaurar/proyecto/watchdog/hermes-job-watchdog.json
```

Recrear el job en Hermes con los datos de ese JSON: `script:
check-meet-jitsi.sh`, `no_agent: true`, cada 2 minutos, entrega
`telegram:Fabio Lesmes`. (Si Hermes conserva su `cron/jobs.json`, el job
`62f0e5f5f4bd` ya existe y basta con poner el script.) Probarlo a mano: con el
sitio arriba **no debe imprimir nada**:

```bash
sudo bash /root/.hermes/scripts/check-meet-jitsi.sh; echo "salida=$?"
```

## 10. Verificación

| Qué | Cómo | Esperado |
|---|---|---|
| Contenedores | `docker compose ps` | 5 × `healthy` |
| Web + TLS | `curl -sI https://meet.bytracking.net/` | `HTTP/2 200`, certificado válido |
| Panel | `curl -s https://meet.bytracking.net/healthz` | `200` y JSON de salud |
| Bridge | `/stats` de jicofo (paso 6) | `operational_bridge_count: 1` |
| JVB por UDP | `sudo ss -uln \| grep 10000` | `0.0.0.0:10000` (puerto fijo, no aleatorio) |
| Login del panel | `https://meet.bytracking.net/admin` con la contraseña de siempre | entra (el hash vino en `admin.env`); 5 intentos / 15 min por IP |
| Datos | en el panel, la lista de reuniones | las mismas que antes (vienen de `reuniones.db`) |
| Reunión de prueba | crear una reunión, entrar con 2 dispositivos (uno con datos móviles) | se ven y se oyen; el del móvil confirma el TURN |
| Pantalla de un residente | el residente comparte; el admin pulsa **Habilitar cámara** | los demás la ven (ver `forceMuteVideo` abajo) |
| Grabación | sala de moderación del panel → Grabar, en Chrome de escritorio | se descarga el fichero (se graba en el PC del admin, ver `GRABACION-ADMIN.md`) |
| API de tokens | `curl -X POST -H "Authorization: Bearer <JITSI_API_KEY>" -H 'Content-Type: application/json' -d '{"nombre":"prueba"}' https://meet.bytracking.net/api/reuniones/<id>/token` | JSON con el token (no 405) |
| Watchdog | paso 9 | sin salida |

Después, **hacer una copia nueva** con `scripts/backup-completo.sh` para que la
siguiente restauración parta del servidor nuevo.

## 11. Qué NO se copia, y por qué

| No se copia | Por qué |
|---|---|
| `web/config/config.js`, `interface_config.js`, `nginx/` | Los genera el contenedor web en cada arranque a partir del `.env` |
| `prosody/config/*` salvo `certs/`, `jicofo/config`, `jvb/config` | Los genera cada contenedor desde el `.env` (llevan los mismos secretos) |
| `prosody/data`, cuentas XMPP | Se recrean al arrancar (focus/jvb se registran solos) |
| Bases de datos de Prometheus / métricas | Son históricos de monitorización; no hacen falta para que el servicio funcione |
| `__pycache__/`, `*.pyc`, `.venv/`, `node_modules/` | Se regeneran; solo ocupan |
| Imágenes Docker (Jitsi, coturn, `jitsi-admin:local`...) | Se descargan (`stable-11031`, `coturn:4.6.3-r3`) o se reconstruyen (paso 5) |
| `admin-panel/instance/app.log`, logs de contenedores | Logs, no estado |
| `.env.bak.*`, `admin.env.bak*`, `docker-compose.yml.bak.*` | Copias antiguas; el `.env` vigente sí va |
| `/opt/jitsi-meet/backups/`, `repo-sync/` | Respaldos locales y una copia de trabajo anteriores; este paquete los sustituye |
| Certificado de Let's Encrypt de Caddy | Caddy lo vuelve a pedir solo si el DNS apunta bien |

## Problemas frecuentes (ya resueltos antes)

**`docker compose up -d` no aplica los cambios del panel o de Prosody.**
`app.py`, plantillas y `mod_http_health` van **dentro** de imágenes construidas
aquí (`jitsi-admin:local`, `jitsi-prosody-cerroazul`). `up -d` sin `--build`
reutiliza la imagen vieja. Hacer `docker compose build admin` (o `prosody`) y
`docker compose up -d --no-build --force-recreate admin`. Para volver atrás:
`docker tag jitsi-admin:<etiqueta-previa> jitsi-admin:local` y el mismo `up`.

**`Endpoint.expire` en el log del JVB y todos fuera de la sala tras un reinicio.**
Reiniciar `jvb`, `jicofo` o `prosody` con gente dentro expira todos los
endpoints a la vez (salida masiva en el mismo segundo) y la reunión se cae para
todos. **Solo se reinicia o se recrea con las salas vacías**: comprobar antes
`participants` y `conferences` = 0 en `/stats` de jicofo (paso 6). El script de
copia hace la misma comprobación.

**El JVB y los mensajes de endpoint con `to` vacío (501 / mensajes que llegan sin contenido).**
Con `jitsi/jvb:stable-11031` los `EndpointMessage` por el canal del bridge se
enrutan (`to=""` es broadcast), pero llegan al receptor **sin `msgPayload`**:
nada de lo que vaya por `sendEndpointMessage` funciona. Las órdenes del panel
(bajar manos, etc.) van por XMPP: `conference.sendMessage(obj, id)`. No "arreglar"
volviendo al canal del bridge.

**No se ve la pantalla compartida de un residente (`forceMuteVideo`).**
Con la moderación de vídeo activa (la sala del panel la activa siempre), Jicofo
manda `forceMuteVideo` al JVB para cada no moderador y el JVB descarta todo su
vídeo, pantalla incluida. Arreglo: el admin pulsa **Habilitar cámara** de ese
residente; si a los 10 s no se ve, que el residente encienda la cámara un
momento. Cada reconexión lo vuelve a aplicar. Diagnóstico:
`docker logs jitsi-jvb --since 4h 2>&1 | grep "epId=<EP>" | grep forceMuteVideo | tail -1`.
Detalle en `SOLUCION-PANTALLA.md`.

**405 al pedir tokens desde votacionph.us.**
Si el bloque de Caddy no incluye `/api/reuniones/*` en `@admin`, el `POST` va
al contenedor web (nginx de Jitsi) en lugar de al panel y responde 405. Añadir
la ruta al matcher `@admin path /admin* /reunion/* /unirse /healthz /api/reuniones/*`,
`caddy validate` y `caddy reload`.

**Sin audio / "There are no operational bridges".** Ver `TROUBLESHOOTING.md`:
puerto `10000:10000/udp` fijo en el compose, UDP 10000 abierto en el firewall,
`JVB_ADVERTISE_IPS` con la IP pública **nueva**, imagen de Prosody con
`mod_http_health` (paso 5).

**El watchdog alerta 401 del TURN.** `/root/.hermes/secrets/turn.env` no
coincide con `TURN_CREDENTIALS` del `.env` (p. ej. tras rotar el secreto).
