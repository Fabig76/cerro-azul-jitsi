# Restaurar Cerro Azul Jitsi en otro servidor

Guía para levantar el proyecto en un VPS nuevo **sin conocerlo de antes** y
sin depender de nada que solo exista en las máquinas actuales. Parte del
**respaldo de migración** que genera `scripts/backup-proyecto.sh` (un único
`cerro-azul-jitsi-AAAAMMDD-HHMM.tar.gz` en Google Drive). Cada paso tiene los
comandos exactos y lo que debe salir; si algo no sale así, para y mira
[Trampas conocidas](#7-trampas-conocidas).

> Hay otra guía más antigua, [`RESTAURAR.md`](RESTAURAR.md), para los dos
> paquetes de `scripts/backup-completo.sh`. Esta es la de referencia para el
> paquete único. La diferencia entre los tipos de respaldo está en
> [`BACKUP-RESTORE.md`](BACKUP-RESTORE.md#respaldo-completo-del-proyecto-migración-de-servidor).

**Tiempo estimado:** 1,5–2 horas la primera vez (30 min de instalación y
descarga, 15 min de restaurar ficheros, 10 min de arranque, el resto
verificación y TURN). La propagación del DNS puede añadir más.

## Índice

1. [Requisitos previos](#1-requisitos-previos)
2. [Qué hay en el respaldo](#2-qué-hay-en-el-respaldo)
3. [Pasos](#3-pasos) (1 a 9)
4. [Verificación final](#4-verificación-final)
5. [Qué NO se puede recuperar](#5-qué-no-se-puede-recuperar)
6. [Si cambia la IP o el dominio](#6-si-cambia-la-ip-o-el-dominio)
7. [Trampas conocidas](#7-trampas-conocidas)

---

## 1. Requisitos previos

**Servidor de Jitsi**

| Qué | Mínimo |
|---|---|
| Sistema | Ubuntu 22.04 o 24.04 LTS, 64 bits |
| CPU / RAM / disco | 4 vCPU, 8 GB RAM, 145 GB de disco |
| Red | **1 Gbit/s sin tope de tráfico**, o al menos ~250 Mbit/s de **subida** sostenida (el JVB reenvía el vídeo del ponente a cada asistente; ver [`CAPACIDAD-500.md`](CAPACIDAD-500.md)) |
| Puertos libres | **80/tcp**, **443/tcp y 443/udp** (Caddy: HTTPS y HTTP/3), **10000/udp** (medio del JVB, obligatorio) y 22/tcp para SSH |

**DNS**: registro **A** de `meet.bytracking.net` apuntando a la IP del servidor
nuevo **antes del paso 6** (Caddy pide el certificado de Let's Encrypt al
arrancar). El TURN hoy se anuncia **por IP** (155.133.22.222):
`turn.urbcerroazul.com` no tiene registro DNS, solo es el nombre del
certificado. Si el TURN cambia de servidor, ver [§6](#6-si-cambia-la-ip-o-el-dominio).

**Servidor del TURN** (opcional, paso 8): puede ser otro VPS pequeño (1 vCPU).
Necesita 3478/udp+tcp, **443/tcp+udp** y 49160–49200/udp. **No** lo pongas en el
mismo servidor que Caddy: los dos quieren el 443.

**Accesos**

- La carpeta de Drive `BACKUP-cerro-azul-jitsi-2026-11-03`
  (<https://drive.google.com/drive/folders/1qse_NViTNEjRXYLi18D5nuZkMyqSjlWK>).
- **La passphrase** del bloque cifrado. **No está en el repo ni en Drive.** El
  operador la guarda en su gestor de contraseñas; copia local en
  `/root/.backup-proyecto-passphrase` del host de desarrollo (`vmi3186036`).
  Sin ella el bloque `cifrado/` no se abre y hay que regenerar todos los
  secretos (ver [§5](#5-qué-no-se-puede-recuperar)).

Cómo estaba repartido al hacer el respaldo:

| Máquina | IP | Qué corre |
|---|---|---|
| `chatbotph` | 84.247.165.81 | Jitsi (`/opt/jitsi-meet`) y Caddy del host (contenedor `hermes-caddy`, compartido con otros sitios) |
| `vmi3186036` | 155.133.22.222 | TURN (`/opt/coturn`), repo de desarrollo, watchdog de Hermes, `rclone` |

---

## 2. Qué hay en el respaldo

```
cerro-azul-jitsi-AAAAMMDD-HHMM.tar.gz
├── MANIFEST.txt        fecha, host de origen, imágenes de los contenedores, QUÉ FALTA
├── SHA256SUMS          sumas de todo lo de abajo
├── claro/              sin secretos
│   ├── RESTAURAR-EN-OTRO-SERVIDOR.md      esta guía
│   ├── repos/cerro-azul-jitsi.bundle      el repo con todo su historial
│   ├── repos/asambleas-virtuales.bundle   el portal de votaciones (la otra mitad, ver ASAMBLEAS-VIRTUALES.md)
│   ├── produccion/opt-jitsi-meet/         lo que corría en producción, sin secretos
│   ├── caddy/meet.bytracking.net.caddy    el bloque de Jitsi del Caddyfile del host
│   └── hermes/                            watchdog (check-meet-jitsi.sh) y su job
└── cifrado/
    └── secretos.tar.gz.gpg   gpg simétrico AES256. Dentro:
        opt-jitsi-meet/.env                               variables del stack (JWT, XMPP, TURN...)
        opt-jitsi-meet/admin-panel/instance/admin.env     credenciales del panel, marca, API keys
        opt-jitsi-meet/admin-panel/instance/reuniones.db  las reuniones (copia sqlite consistente)
        opt-jitsi-meet/web/config/keys/                   TLS interno del contenedor web
        opt-jitsi-meet/prosody/config/certs/              certificados de Prosody
        opt-jitsi-meet/prosody/config/data/               cuentas XMPP (focus@, jvb@...)
        opt-jitsi-meet/jicofo/config/, jvb/config/        config generada por los contenedores
        opt-coturn/                                       TURN: turnserver.conf, .secret, compose, certs
        hermes/secrets/turn.env                           secreto del TURN para el watchdog
        vps-root/.backup_passphrase                       passphrase de scripts/backup.sh (respaldo operativo)
        LISTA.txt, SHA256SUMS
```

> **Producción no es un clon del repo**: se despliega copiando ficheros. Lo
> que corría de verdad está en `claro/produccion/opt-jitsi-meet/`; el MANIFEST
> dice si su `docker-compose.yml` es igual al del repo. Esta guía restaura desde
> el **repo** (paso 3) y usa `produccion/` para comparar.

---

## 3. Pasos

Todos los comandos, como un usuario con `sudo` (en el servidor actual era
`chatbotph`). `$R` es el directorio de trabajo.

### Paso 1 — Docker y Docker Compose

```bash
sudo apt-get update && sudo apt-get install -y git gnupg python3 sqlite3 curl
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER" && newgrp docker
docker compose version          # -> Docker Compose version v2.x (>= 2.20)
docker run --rm hello-world     # -> "Hello from Docker!"

sudo ufw allow 22/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
sudo ufw allow 443/udp && sudo ufw allow 10000/udp comment 'Jitsi JVB'
sudo ufw --force enable && sudo ufw status
```

Abre los mismos puertos en el firewall del proveedor si lo tiene.

### Paso 2 — Descargar el respaldo y descifrarlo

Baja de la carpeta de Drive el `.tar.gz` **más reciente** y su `.sha256`
(navegador y `scp`, o `rclone copy gdrive:BACKUP-cerro-azul-jitsi-2026-11-03/<fichero> .`
si tienes rclone configurado).

```bash
R=~/restaurar; mkdir -p $R && cd $R
# (copiar aquí cerro-azul-jitsi-AAAAMMDD-HHMM.tar.gz y .tar.gz.sha256)
sha256sum -c cerro-azul-jitsi-*.tar.gz.sha256        # -> ...: OK
mkdir paquete && tar -xzf cerro-azul-jitsi-*.tar.gz -C paquete
(cd paquete && sha256sum -c --quiet SHA256SUMS) && echo "paquete integro"
sed -n '/QUE FALTA/,/^$/p' paquete/MANIFEST.txt      # -> "nada: estan todos..."
```

Si `QUE FALTA` lista algo, esa pieza no está en el respaldo: apúntala y
consulta [§5](#5-qué-no-se-puede-recuperar) para regenerarla.

Descifrar (pide la passphrase; no queda en el historial):

```bash
mkdir -m 700 $R/secretos
gpg --decrypt paquete/cifrado/secretos.tar.gz.gpg \
  | sudo tar -xzpf - --numeric-owner -C $R/secretos
(cd $R/secretos && sudo sha256sum -c --quiet SHA256SUMS) && echo "secretos integros"
sudo cat $R/secretos/LISTA.txt | head -20
```

`gpg: decryption failed: Bad session key` = passphrase equivocada.
`--numeric-owner` conserva los UID de los contenedores (Prosody, Jicofo y JVB
corren con su propio usuario dentro); **no** lo quites.

### Paso 3 — Clonar desde el bundle

Desde el bundle y no de GitHub: así obtienes exactamente el commit respaldado
aunque el repo haya cambiado o no esté accesible.

```bash
cd $R
git clone paquete/claro/repos/cerro-azul-jitsi.bundle cerro-azul-jitsi
git -C cerro-azul-jitsi log -1 --format='%H %s'
grep -A1 '^  cerro-azul-jitsi' paquete/MANIFEST.txt | head -1     # mismo HEAD

sudo mkdir -p /opt/jitsi-meet && sudo chown "$USER": /opt/jitsi-meet
git -C cerro-azul-jitsi archive HEAD | tar -x -C /opt/jitsi-meet
diff -q /opt/jitsi-meet/docker-compose.yml paquete/claro/produccion/opt-jitsi-meet/docker-compose.yml \
  && echo "compose igual que en produccion"
diff -rq /opt/jitsi-meet/admin-panel/app paquete/claro/produccion/opt-jitsi-meet/admin-panel/app
```

Si el `diff` del compose o del panel muestra diferencias, **manda producción**:
copia esos ficheros desde `paquete/claro/produccion/opt-jitsi-meet/`.

(El portal de votaciones, si también hay que reconstruirlo:
`git clone paquete/claro/repos/asambleas-virtuales.bundle` y seguir su
`docs/DESPLIEGUE.md`; ver [`ASAMBLEAS-VIRTUALES.md`](ASAMBLEAS-VIRTUALES.md).)

### Paso 4 — Secretos y configuración en sus rutas

```bash
D=/opt/jitsi-meet; S=$R/secretos/opt-jitsi-meet

# Ficheros del usuario que lanza docker compose (600)
sudo install -m 600 -o "$USER" -g "$USER" $S/.env                          $D/.env
sudo install -d -m 755 -o "$USER" $D/admin-panel/instance
sudo install -m 600 -o "$USER" -g "$USER" $S/admin-panel/instance/admin.env $D/admin-panel/instance/admin.env
chmod 600 $D/docker-compose.yml

# Directorios de los contenedores: cp -a conserva dueños numéricos y permisos
for d in web/config/keys prosody/config/certs prosody/config/data jicofo/config jvb/config; do
  sudo mkdir -p "$D/$d" && sudo cp -a "$S/$d/." "$D/$d/"
done
sudo chmod 600 $D/web/config/keys/cert.key
sudo chmod 400 $D/prosody/config/certs/*.key
sudo chmod 750 $D/prosody/config/data

# Passphrase del respaldo operativo (scripts/backup.sh)
sudo install -m 600 -o root -g root $R/secretos/vps-root/.backup_passphrase /root/.backup_passphrase

# Comprobar
ls -l $D/.env $D/admin-panel/instance/admin.env       # -rw------- tuyo
sudo ls $D/prosody/config/data/                      # auth%2emeet%2ebytracking%2enet ...
cd $D && docker compose config -q && echo "compose + .env OK"
scripts/validate-env.sh .env                         # sin errores
```

Si la IP pública cambia (lo normal en un VPS nuevo), **antes de seguir** ajusta
`JVB_ADVERTISE_IPS` en `.env` ([§6](#6-si-cambia-la-ip-o-el-dominio)).

La base de reuniones se coloca en el paso 7 (antes de que el panel arranque
con una vacía no pasa nada: se sobrescribe con el contenedor parado).

### Paso 5 — Levantar el stack y esperar al bridge

Dos imágenes se **construyen** aquí (no se descargan):
`jitsi-prosody-cerroazul:stable-11031` (añade `mod_http_health`) y
`jitsi-admin:local` (el panel, con `app.py` dentro).

```bash
cd /opt/jitsi-meet
docker compose pull web jicofo jvb
docker compose build prosody admin
docker compose up -d
docker compose ps        # en 1-2 min: 5 contenedores "Up (healthy)"
```

Esperar a `operational_bridge_count = 1` (no basta con `healthy`):

```bash
for i in $(seq 1 30); do
  n=$(docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["bridge_selector"]["operational_bridge_count"])' 2>/dev/null)
  echo "bridges=$n"; [ "$n" = 1 ] && break; sleep 10
done
# -> bridges=1
```

Si se queda en 0: [Trampas](#7-trampas-conocidas) → *mod_http_health* y *JVB_ADVERTISE_IPS*.

### Paso 6 — Caddy (HTTPS público)

Jitsi solo escucha en `127.0.0.1:8080` (web) y `127.0.0.1:8081` (panel). Caddy
corre **en un contenedor** unido a la red `jitsi-meet_jitsi` y llega a los
servicios por nombre (`web:80`, `admin:8081`), nunca por `127.0.0.1`.

**Servidor nuevo sin Caddy** (lo normal):

```bash
sudo mkdir -p /opt/caddy
sudo cp $R/paquete/claro/caddy/meet.bytracking.net.caddy /opt/caddy/Caddyfile
docker run -d --name hermes-caddy --restart unless-stopped \
  -p 80:80 -p 443:443 -p 443:443/udp \
  -v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v caddy_data:/data -v caddy_config:/config \
  --network jitsi-meet_jitsi caddy:2-alpine
docker exec hermes-caddy caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
# -> "Valid configuration"
docker logs hermes-caddy 2>&1 | grep -i "certificate obtained"    # tras unos segundos
```

**Servidor que ya tiene un Caddy con otros sitios**: añade el bloque de
`claro/caddy/meet.bytracking.net.caddy` a su Caddyfile, conecta el contenedor a
la red (`docker network connect jitsi-meet_jitsi <caddy>`), y `caddy validate`
+ `caddy reload` dentro del contenedor. **Nunca** `docker restart` del Caddy
compartido. Si el Caddyfile es un bind-mount de fichero, edítalo en sitio
(`cat nuevo > Caddyfile`), no con `sed -i` ni `mv`.

El bloque debe tener `/api/reuniones/*` en el matcher `@admin` (si no, la API
de votacionph.us recibe 405).

### Paso 7 — Restaurar la base de datos de reuniones

```bash
cd /opt/jitsi-meet
docker compose stop admin
sudo install -m 644 -o "$USER" -g "$USER" \
  $R/secretos/opt-jitsi-meet/admin-panel/instance/reuniones.db admin-panel/instance/reuniones.db
sqlite3 admin-panel/instance/reuniones.db 'pragma integrity_check; select count(*) from reuniones;'
# -> ok / el mismo número que "REUNIONES" en MANIFEST.txt
docker compose up -d --no-build admin
```

### Paso 8 — TURN (si se ha perdido su servidor)

En el **otro** VPS. Imagen oficial `coturn/coturn:4.6.3-r3`. El secreto del
`turnserver.conf` respaldado ya coincide con `TURN_CREDENTIALS` del `.env`.
Copia antes `$R/secretos/opt-coturn/` a ese servidor por `scp`.

```bash
sudo mkdir -p /opt/coturn && cd /opt/coturn
sudo cp -a ~/opt-coturn/. /opt/coturn/
sudo chown 65534:65534 turnserver.conf && sudo chmod 600 turnserver.conf docker-compose.turn.yml
sudo chown -R 65534:65534 certs && sudo chmod 600 certs/turn_server_pkey.pem
sudo ufw allow 3478 && sudo ufw allow 443 && sudo ufw allow 49160:49200/udp
sudo docker compose -f docker-compose.turn.yml up -d
sudo docker ps --filter name=coturn       # Up
```

Desde el servidor de Jitsi: `scripts/check-turn.sh .env -v` → relay OK por
UDP, TCP y TLS. Si la IP del TURN cambia, ver [§6](#6-si-cambia-la-ip-o-el-dominio).

**Watchdog (Hermes)**, en la máquina que lo ejecute (no en la de Jitsi, para
que detecte su caída):

```bash
sudo install -m 711 $R/paquete/claro/hermes/scripts/check-meet-jitsi.sh /root/.hermes/scripts/check-meet-jitsi.sh
sudo install -d -m 700 /root/.hermes/secrets
sudo install -m 600 $R/secretos/hermes/secrets/turn.env /root/.hermes/secrets/turn.env
cat $R/paquete/claro/hermes/hermes-job-watchdog.json   # recrear el job: cada 2 min, no_agent, Telegram
sudo bash /root/.hermes/scripts/check-meet-jitsi.sh; echo "salida=$?"   # con todo bien: sin texto
```

### Paso 9 — Verificar el servicio

Haz la [verificación final](#4-verificación-final) completa. Las pruebas con
personas (reunión, residente, pantalla, moderación) necesitan dos
dispositivos, uno con datos móviles (prueba el TURN).

Al terminar: **borra los secretos en claro** y haz un respaldo nuevo desde el
servidor nuevo.

```bash
sudo rm -rf $R/secretos
```

---

## 4. Verificación final

| # | Qué | Comando / acción | Resultado esperado |
|---|---|---|---|
| 1 | Contenedores | `cd /opt/jitsi-meet && docker compose ps` | `jitsi-web`, `jitsi-prosody`, `jitsi-jicofo`, `jitsi-jvb`, `jitsi-admin` en `Up (healthy)` |
| 2 | Bridge | bucle del paso 5 | `bridges=1` |
| 3 | JVB por UDP | `sudo ss -ulnp \| grep ':10000 '` | `0.0.0.0:10000` |
| 4 | Los 6 endpoints | `for p in / /healthz /admin/login /external_api.js /config.js /http-bind; do printf '%s %s\n' $(curl -s -o /dev/null -w '%{http_code}' https://meet.bytracking.net$p) $p; done` | seis líneas `200` |
| 5 | Certificado | `curl -sI https://meet.bytracking.net/ \| head -1` | `HTTP/2 200` sin `-k` (Let's Encrypt válido) |
| 6 | Salud del panel | `curl -s https://meet.bytracking.net/healthz` | `{"service":"jitsi-admin","status":"ok"}` |
| 7 | Login del panel | navegador: `https://meet.bytracking.net/admin` con la contraseña de siempre | entra (el hash vino en `admin.env`). Máx. 5 intentos / 15 min por IP |
| 8 | Datos | lista de reuniones en el panel | las mismas que antes (`REUNIONES` del MANIFEST) |
| 9 | Crear reunión | panel → nueva reunión → abrir su sala de moderación | se crea, QR y enlace funcionan |
| 10 | Entra un residente | abrir el enlace de residente en otro dispositivo (con datos móviles) | entra a la sala; el admin lo ve y se oyen en ambos sentidos |
| 11 | Pantalla compartida | el residente comparte pantalla; el admin pulsa **Habilitar cámara** de ese residente | todos ven la pantalla (sin ese botón no se ve: [trampa](#7-trampas-conocidas) *forceMuteVideo*) |
| 12 | Moderación | Silenciar / Bajar todas las manos / Habilitar audio desde el panel | el estado del botón cambia y el residente lo nota |
| 13 | API de tokens | `curl -s -X POST -H "Authorization: Bearer <JITSI_API_KEY de admin.env>" -H 'Content-Type: application/json' -d '{"nombre":"prueba"}' https://meet.bytracking.net/api/reuniones/<id>/token` | JSON con el token; nunca 405 |
| 14 | TURN | `scripts/check-turn.sh .env -v` | relay OK (UDP, TCP, TLS) |
| 15 | Watchdog | `sudo bash /root/.hermes/scripts/check-meet-jitsi.sh` | sin salida |
| 16 | Respaldo operativo | `sudo bash -c 'BACKUP_PASSPHRASE="$(cat /root/.backup_passphrase)" BACKUP_ORIGEN=/opt/jitsi-meet /opt/jitsi-meet/scripts/backup.sh --dry-run'` (ver [`BACKUP-RESTORE.md`](BACKUP-RESTORE.md)) | lista lo que respaldaría, sin elementos que falten |

---

## 5. Qué NO se puede recuperar

| No se recupera | Consecuencia / qué hacer |
|---|---|
| Certificados **Let's Encrypt** de Caddy | Se reemiten solos al arrancar Caddy si el DNS apunta bien (paso 6). Límite de Let's Encrypt: 5 certificados por semana para el mismo nombre; no borres el volumen `caddy_data` a lo loco |
| Sesiones activas (panel, salas) | Todo el mundo vuelve a entrar; los JWT emitidos siguen valiendo si `JWT_APP_SECRET` no cambia |
| Reuniones en curso, chat, manos levantadas | Viven en memoria de Prosody/Jicofo; se pierden |
| Reuniones creadas **después** del respaldo | No están en `reuniones.db`; recrearlas a mano en el panel |
| Grabaciones | Se graban en el PC del admin (`GRABACION-ADMIN.md`), nunca en el servidor |
| `web/config/config.js`, `interface_config.js`, nginx interno | Los genera el contenedor web en cada arranque desde `.env` + `custom-*.js` |
| Imágenes Docker | Se descargan (`stable-11031`, `coturn:4.6.3-r3`) o se construyen (paso 5). Si `stable-11031` dejara de existir en Docker Hub, usar la siguiente estable y revisar las trampas |
| Historial de logs y métricas | No hacen falta para el servicio |
| Secretos y datos de **asambleas-virtuales** | Ese portal corre en otro servidor (votacionph.us); aquí solo va su código. Sus secretos van con su propio procedimiento (`infra/respaldo.sh` de ese repo) |
| **Sin la passphrase** | Se pierde todo el bloque cifrado: hay que generar `.env` nuevo (`gen-passwords.sh`), contraseña del panel (`scripts/change_admin_password.sh`), API key nueva (avisar a votacionph.us), secreto del TURN (`scripts/rotate-turn-secret.sh`) y las reuniones se pierden |

---

## 6. Si cambia la IP o el dominio

```bash
grep -nE '^(PUBLIC_URL|XMPP_DOMAIN|JVB_ADVERTISE_IPS|TURN_HOST|TURNS_HOST|STUN_HOST)=' /opt/jitsi-meet/.env
```

- **Nueva IP del servidor de Jitsi** → `JVB_ADVERTISE_IPS=<IP pública nueva>`.
  Sin esto el JVB anuncia la IP vieja: la gente entra pero no hay audio ni vídeo.
- **Nueva IP del TURN** → `TURN_HOST`, `TURNS_HOST`, `STUN_HOST`. Prosody lee
  estos valores al arrancar: `docker compose up -d --force-recreate prosody`
  (con las salas vacías).
- **Nuevo dominio** → `PUBLIC_URL` y `XMPP_DOMAIN` en `.env`, el bloque de Caddy,
  `admin.env` si lo menciona, el watchdog (`check-meet-jitsi.sh`) y avisar a
  votacionph.us (su integración apunta a `meet.bytracking.net`). Prosody creará
  cuentas y certificados nuevos para el dominio nuevo.

Tras cambiar `.env`: `docker compose up -d` (recrea lo afectado) y repetir el
paso 5 hasta `bridges=1`.

---

## 7. Trampas conocidas

Todas nos han pasado ya.

**`mod_http_health` no está en la imagen oficial de Prosody.** Sin él, el
`register-setup` agota sus 60 intentos, focus/jvb no se registran, 0 bridges y
nadie se oye. Por eso Prosody usa la imagen propia
`jitsi-prosody-cerroazul:stable-11031` (`prosody/Dockerfile.prosody`). Si
`docker compose ps` muestra `jitsi/prosody` en vez de la propia, falta el
`docker compose build prosody`.

**`docker compose up -d` no reconstruye si la imagen ya existe.** `app.py`,
plantillas y `mod_http_health` van **dentro** de las imágenes. Tras cambiar
código: `docker compose build admin` (o `prosody`) y luego
`docker compose up -d --no-build --force-recreate admin`.

**El JWT va en `?jwt=`, no en `#jwt=`.** `stable-11031` ignora el token en el
fragmento y la sala pide contraseña o entra como invitado sin permisos.

**El JVB y los mensajes de endpoint.** Los `EndpointMessage` por el canal del
bridge llegan **sin `msgPayload`** con `stable-11031`, y un `to=""` explícito lo
rechaza el JVB. Las órdenes del panel (bajar manos, etc.) van por XMPP con
`conference.sendMessage(obj, id)`; no "arreglarlo" volviendo a
`sendEndpointMessage`.

**`forceMuteVideo`: no se ve la pantalla de un residente.** Con la moderación de
vídeo activa (la sala del panel la activa siempre), el JVB descarta todo el
vídeo de los no moderadores, pantalla incluida. El admin pulsa **Habilitar
cámara** de ese residente. Detalle: [`SOLUCION-PANTALLA.md`](SOLUCION-PANTALLA.md).

**No reiniciar con gente dentro.** Reiniciar `jvb`, `jicofo` o `prosody` con una
reunión en marcha expulsa a todos a la vez. Antes de cualquier reinicio:
`participants` y `conferences` = 0 en `/stats` de jicofo.

**405 en la API de tokens.** Falta `/api/reuniones/*` en el `@admin` del bloque
de Caddy: el `POST` va al nginx de Jitsi.

**Caddy: `validate` antes de `reload`, nunca `POST /load`.** La admin API vive en
memoria y se pierde al reiniciar (el sitio estuvo caído dos semanas así en
octubre de 2026). Y un Caddyfile montado como fichero único se edita en sitio.

**Sin audio con 10000/udp cerrado.** El puerto debe ser fijo (`10000:10000/udp`
en el compose) y estar abierto en `ufw` **y** en el firewall del proveedor.

**El watchdog alerta 401 del TURN.** `turn.env` no coincide con
`TURN_CREDENTIALS` del `.env` (p. ej. tras rotar el secreto): actualizarlo.

**`git bundle verify` fuera de un repo falla** ("need a repository"). Para
comprobar un bundle: `git clone <bundle>` o `git bundle list-heads <bundle>`.

**`config.constraints.video.bitrate` no hace nada** en `stable-11031` (aunque
esté en `custom-config.js`): nadie lo lee y la pantalla no usa `constraints`. Para
limitar de verdad: `config.videoQuality.maxBitratesVideo`, midiendo antes y
después con `loadtest/medir-bitrate.py` (ver `CAPACIDAD-500.md`).

Más problemas y su diagnóstico: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
