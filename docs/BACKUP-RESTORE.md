# Respaldos y restauración (Fase 7.2)

Criterio de aceptación: **respaldo restaurado con éxito en un servidor limpio**.
Este documento es el procedimiento para cumplirlo (y para repetirlo una vez al mes).

## Estado en producción (verificado el 2-nov-2026)

| Qué | Estado |
|---|---|
| Respaldos en `/opt/jitsi-meet/backups/` | **1**: `cerroazul-backup-20261101-034041.tar.gz` |
| Passphrase | `/root/.backup_passphrase` en el VPS (600, root). Debe estar también fuera del servidor |
| Cron diario | **No instalado** (en `/etc/cron.d/` del VPS no hay `jitsi-backup`). Ver "Respaldo diario" |
| Restauración en un servidor limpio | **Pendiente** (criterio de la Fase 7.2) |

`admin.env` de producción ya no es solo la contraseña del panel. Lleva también
la marca (`JITSI_SITE_NAME`, `JITSI_SITE_SUBTITLE`, `JITSI_LEGAL_OWNER`) y las
dos API keys de la Fase 6 (`JITSI_API_KEY`, `JITSI_API_KEY_ADMIN`). Por eso va
**cifrado** en el respaldo y es grave que falte: sin él, el panel arranca con la
marca por defecto y votacionph deja de poder pedir tokens. Los valores reales no
se escriben nunca en el repo (aquí: `<oculto>`).

Con la passphrase en `/root/.backup_passphrase` (solo la passphrase, sin
`BACKUP_PASSPHRASE=`), el respaldo manual en el VPS es:

```bash
sudo bash -c 'BACKUP_PASSPHRASE="$(cat /root/.backup_passphrase)" BACKUP_ORIGEN=/opt/jitsi-meet /opt/jitsi-meet/scripts/backup.sh --keep 14'
```

*A verificar antes de usarlo:* que el fichero contenga solo la passphrase (no
se ha leído su contenido para este documento).

## El ciclo en una línea

```bash
# En el servidor de Jitsi (respaldo):
sudo BACKUP_PASSPHRASE='<passphrase>' BACKUP_ORIGEN=/opt/jitsi-meet scripts/backup.sh
# -> /opt/jitsi-meet/backups/cerroazul-backup-AAAAMMDD-HHMMSS.tar.gz  (otro sitio: BACKUP_DIR=... o --dest)
# Copiarlo FUERA del servidor. En el servidor nuevo, sobre un clon del repo (restauración):
sudo BACKUP_PASSPHRASE='<passphrase>' scripts/restore.sh cerroazul-backup-...tar.gz --dest /opt/jitsi-meet --dry-run
sudo BACKUP_PASSPHRASE='<passphrase>' scripts/restore.sh cerroazul-backup-...tar.gz --dest /opt/jitsi-meet
```

| Variable / opción | Script | Qué hace |
|---|---|---|
| `BACKUP_PASSPHRASE` | los dos | Passphrase del cifrado. **Obligatoria** en `backup.sh` (salvo `--allow-plaintext`); en `restore.sh`, si falta y hay terminal, se pide sin eco |
| `BACKUP_ORIGEN` / `--origen DIR` | `backup.sh` | Directorio del despliegue (default `JITSI_DIR`, si no `/opt/jitsi-meet`). Si no existe: exit 1, nada creado |
| `BACKUP_DIR` / `--dest DIR` | `backup.sh` | Dónde se deja el paquete (default `/opt/jitsi-meet/backups`) |
| `--turn-conf F`, `--keep N`, `--strict`, `--dry-run` | `backup.sh` | Ver `scripts/backup.sh --help` |
| `--dest DIR`, `--owner U[:G]` (o `RESTORE_OWNER`), `--yes`, `--dry-run` | `restore.sh` | Ver `scripts/restore.sh --help` |

### Por qué con `sudo`

En producción `.env`, `admin-panel/instance/admin.env` y `web/config/keys/cert.key` son
`600` de root (y `admin-panel/instance/` puede ser `700`). Un usuario sin root (p. ej.
`chatbotph`) no puede leerlos. `backup.sh` lo comprueba **antes de copiar nada** y, si
falta algún permiso, sale con exit 1 **sin crear ningún respaldo**:

```
[backup] ERROR: no se puede leer /opt/jitsi-meet/.env (permisos).
          Ejecuta el respaldo con sudo:
            sudo BACKUP_PASSPHRASE=... BACKUP_ORIGEN=/opt/jitsi-meet scripts/backup.sh
          No se ha creado ningun respaldo.
```

`sudo` no pasa el entorno: las variables van **en la misma línea** que `sudo`, como en el
ejemplo. La primera línea del log dice quién lo ejecutó (`ejecutando como root (sudo desde
chatbotph)`). `restore.sh` hace lo mismo con el destino: si no puede escribir algún
fichero (p. ej. un `.env` de root), lo dice con el comando `sudo` y no toca nada.

## Qué se respalda y qué no

El **código** (compose, plugins de Prosody, panel admin, bloque de Caddy) está en git:
no se respalda, se clona. El respaldo guarda el **estado** que se perdería con el disco.

`backup.sh` respalda lo que **exista** en el directorio de origen (`--origen DIR` o
`BACKUP_ORIGEN`, por defecto `/opt/jitsi-meet`). Lo que falte se lista al final de la
ejecución y en `MANIFEST.txt`, y el respaldo queda marcado `estado: incompleto`.

**Siempre presentes** (están en cualquier clon del repo):

| Qué | Cómo va en el respaldo | Por qué |
|---|---|---|
| `docker-compose.yml` | en claro | Por si el del servidor difiere del commit |
| `web/config/` (sin `keys/`) | en claro | En el repo solo contiene `custom-config.js` y `custom-interface_config.js` (sala grande, Fase 3). En un servidor en marcha contiene además la config que genera el contenedor `web` al arrancar, que también se guarda |
| `admin-panel/instance/` (sin `admin.env` ni `*.log`) | en claro; `reuniones.db` con una copia consistente (API de backup de SQLite) | Reuniones creadas en el panel. En el repo solo está `admin.env.example`; `reuniones.db` aparece cuando el panel crea la primera reunión |
| `turn/turnserver.conf` | en claro, **con `static-auth-secret` redactado** | El secreto ya va (cifrado) como `TURN_CREDENTIALS` del `.env` |

**Solo en un servidor desplegado** (no están en el repo; si faltan, se avisa y el respaldo sale `incompleto`):

| Qué | Cómo va en el respaldo | Por qué |
|---|---|---|
| `.env` | **cifrado** | Todos los secretos del stack. **Sin él el respaldo no sirve para restaurar** |
| `admin-panel/instance/admin.env` | **cifrado** | Contraseña del panel, `JITSI_API_KEY`/`JITSI_API_KEY_ADMIN` (Fase 6) y marca `JITSI_SITE_*`/`JITSI_LEGAL_OWNER` (Fase 9) |
| `web/config/keys/` | **cifrado** | `cert.key` es la clave privada TLS que genera el contenedor `web` |
| `prosody/config/`, `jicofo/config/`, `jvb/config/` | **cifrado** | Ver nota abajo |

> **Nota sobre `prosody/config/`, `jicofo/config/` y `jvb/config/`.** No están en el repo
> porque **los genera cada contenedor al arrancar**, a partir del `.env`. No son volúmenes
> Docker con nombre sino *bind mounts* del `docker-compose.yml`
> (`./prosody/config:/config`, `./jicofo/config:/config`, `./jvb/config:/config`): aparecen
> en el disco del host, dentro del directorio del despliegue, tras el primer
> `docker compose up`. Por eso en un clon donde el stack nunca ha arrancado no existen y
> `backup.sh` los marca como faltantes ("normal si el stack no ha arrancado aquí"). En el
> servidor de producción sí existen y se respaldan, cifrados, porque **contienen los mismos
> secretos en claro** (contraseñas XMPP de focus/jvb, `JWT_APP_SECRET`,
> `external_service_secret`). Si faltan en un respaldo no es grave: se regeneran desde el
> `.env` en el siguiente arranque. **No es un fallo del respaldo.**

### Respaldo INCOMPLETO: cuándo importa

Si algo de lo esperado no existe, el respaldo **se crea igual** pero el `MANIFEST.txt`
dice `estado: incompleto`, `backup.sh` lo lista al final con el motivo de cada ausencia y,
con `--strict`, termina con código 2 (para que cron avise). No todas las ausencias pesan
lo mismo:

| Falta | Gravedad |
|---|---|
| `.env` | **Grave.** Lleva todos los secretos del stack (XMPP, JWT, `TURN_CREDENTIALS`...). **Sin `.env` no se puede restaurar el stack**: habría que regenerar secretos, y entonces cambian los tokens del panel y el secreto del TURN |
| `admin-panel/instance/admin.env` | **Grave.** Sin él el panel no arranca con la misma contraseña, ni con las API keys que usa votacionph, ni con la marca del conjunto |
| `prosody/config`, `jicofo/config`, `jvb/config`, `web/config/keys` | Normal donde el stack no ha arrancado: los genera el contenedor al arrancar |
| `turn/turnserver.conf` | Normal: el TURN vive en otro servidor |

Ojo: un `.env` que existe pero **no se puede leer** no se trata como "falta": `backup.sh`
se para con el error de permisos de arriba (sin `sudo` no hay respaldo, ni a medias).

Integridad: `SHA256SUMS` (formato estándar de `sha256sum`, rutas relativas al paquete)
se genera **al final**, sobre los ficheros ya escritos, y cubre `files/`, `MANIFEST.txt`
y el bloque de secretos. Si no hay ningún fichero que respaldar, o el origen no existe,
`backup.sh` termina con error y **no crea ningún paquete**.

Códigos de salida de `backup.sh`: `0` respaldo creado; `1` error, no se ha creado nada;
`2` respaldo creado pero **incompleto** (solo con `--strict`, pensado para cron).

> El plan pedía cifrar con `openssl enc -aes-256-gcm`, pero **`openssl enc` no admite
> cifrados AEAD** (`enc: AEAD ciphers not supported`, verificado con OpenSSL 3.0.13).
> Se usa `aes-256-cbc` con PBKDF2 (600 000 iteraciones) + un **HMAC-SHA256** del fichero
> cifrado. El HMAC cumple el papel de GCM: una passphrase equivocada o un fichero
> manipulado se detectan **antes** de descifrar o de tocar nada.

Lo que **no** está en el respaldo y se rehace en el servidor nuevo:

- Las imágenes Docker (se descargan/construyen con `docker compose build`/`up`).
- El certificado público de `meet.bytracking.net` (lo emite Caddy solo, en el host).
  Lo que sí va (cifrado) es `web/config/keys/`, el certificado interno del contenedor `web`.
- El bloque de Caddy vive en el Caddyfile **del host** (ver README, sección Caddy):
  se reinstala desde `infra/caddy/meet.bytracking.net.caddy` con `scripts/sync-caddy.sh`.

## La passphrase

- Se pasa por la variable de entorno `BACKUP_PASSPHRASE` (nunca como argumento: quedaría
  en `ps` y en el historial).
- **Guárdala también FUERA del servidor** (gestor de contraseñas del conjunto). Si solo
  está en el servidor y el servidor se pierde, los respaldos no sirven para nada.
- Sin `BACKUP_PASSPHRASE`, `backup.sh` se niega a respaldar. Con `--allow-plaintext`
  lo hace, avisa a gritos y el fichero se llama `...-SECRETOS-EN-CLARO.tar.gz`.

## Respaldo diario

En el servidor de Jitsi, como root (`sudo -i`, o anteponiendo `sudo` como arriba):

```bash
# Passphrase en un fichero solo de root (y copia en el gestor de contraseñas)
install -m 600 /dev/null /root/.jitsi-backup.env
echo "BACKUP_PASSPHRASE='<passphrase larga>'" > /root/.jitsi-backup.env

# Probar a mano (primero en seco)
set -a; . /root/.jitsi-backup.env; set +a
export BACKUP_ORIGEN=/opt/jitsi-meet
/opt/jitsi-meet/scripts/backup.sh --dry-run      # qué existe y qué faltaría
/opt/jitsi-meet/scripts/backup.sh --keep 14      # debe terminar con "estado: COMPLETO"
# (otro directorio: --origen DIR o BACKUP_ORIGEN=DIR)

# Cron diario a las 03:30, guardando los 14 últimos. --strict: si falta algo
# (p. ej. el .env), sale con código 2 y cron avisa, aunque el paquete se cree.
cat > /etc/cron.d/jitsi-backup <<'EOF'
30 3 * * * root set -a; . /root/.jitsi-backup.env; set +a; /opt/jitsi-meet/scripts/backup.sh --keep 14 --strict >/var/log/jitsi-backup.log 2>&1 || echo "Fallo el respaldo de Jitsi (ver /var/log/jitsi-backup.log)"
EOF
```

**Copia fuera del servidor** (un respaldo en el mismo disco no sobrevive a perder el disco).
Por ejemplo, desde otro host que tire del servidor:

```bash
rsync -a --chmod=F600 usuario@servidor-jitsi:/opt/jitsi-meet/backups/ /srv/respaldos/jitsi/
```

El paquete es `cerroazul-backup-AAAAMMDD-HHMMSS.tar.gz` (chmod 600). Contiene
`MANIFEST.txt` (qué hay, si está `completo` o `incompleto` y qué falta; sin secretos),
`SHA256SUMS` (sumas de todo lo anterior y lo siguiente), `files/` (parte en claro) y
`secrets.tar.gz.enc` + `.mac` (parte cifrada). Para ver qué lleva sin restaurar:

```bash
tar -xzOf cerroazul-backup-*.tar.gz --wildcards '*/MANIFEST.txt'
```

## Restaurar en un servidor limpio (paso a paso)

`restore.sh` **no arranca nada**: verifica, pide confirmación, deja los ficheros y
termina. Cada fichero que sobrescribe lo copia antes a `<destino>/.pre-restore-<fecha>/`.

### 1. Preparar el servidor

Ubuntu con Docker y el plugin compose (ver `scripts/setup-vps.sh` y el README,
"Instalación desde cero"). Firewall: `443/tcp`, `80/tcp`, `10000/udp`; SSH solo desde
tus IPs.

### 2. Clonar el repo en el commit del respaldo

```bash
tar -xzOf /root/cerroazul-backup-XXXX.tar.gz --wildcards '*/MANIFEST.txt' | head
# -> "commit: 07cc2fb (restaurar sobre un clon de ese commit)"
git clone <url-del-repo> /opt/jitsi-meet
cd /opt/jitsi-meet && git checkout <commit>   # o main, si se quiere lo último
```

### 3. Verificar y restaurar

```bash
cd /opt/jitsi-meet
# Primero en seco: comprueba SHA256SUMS y HMAC y muestra qué escribiría, sin escribir nada
sudo BACKUP_PASSPHRASE='<passphrase>' scripts/restore.sh /root/cerroazul-backup-XXXX.tar.gz --dest /opt/jitsi-meet --dry-run
# De verdad (pide escribir 'si'; --yes para no preguntar)
sudo BACKUP_PASSPHRASE='<passphrase>' scripts/restore.sh /root/cerroazul-backup-XXXX.tar.gz --dest /opt/jitsi-meet
```

> Para que la passphrase no quede en el historial de la shell: deja que `restore.sh`
> la pida (sin eco) no definiendo `BACKUP_PASSPHRASE` (`sudo scripts/restore.sh ...`).
> `--dry-run` verifica sumas y HMAC en un directorio temporal y lista qué se crearía o
> sobrescribiría, **sin escribir nada** en el destino.

Si `SHA256SUMS` está vacío o mal formado, `restore.sh` lo dice así ("el respaldo no
contiene SHA256SUMS valido (esta vacio)") y pide generar un respaldo nuevo; si las sumas
no cuadran, es que el paquete está corrupto o manipulado. Si el `MANIFEST.txt` dice
`estado: incompleto`, avisa y lista lo que faltaba en el origen.

Códigos de salida: `0` todo restaurado; `1` error (no se tocó el destino); `3`
restauración **parcial** (sin passphrase: se restauró la parte en claro, no los secretos).

### 4. Ajustar al servidor nuevo

**Permisos y propietarios.** `restore.sh` deja:

- `600`: `.env`, `admin-panel/instance/admin.env`, `web/config/keys/*.key`, `turn/turnserver.conf`;
- `644`: los `.js`, `.yml`, `.json`, `.crt` de la parte en claro;
- el resto, con los permisos que traía el respaldo.

No cambia propietarios (con `sudo`, lo restaurado queda de root; los uid del servidor
viejo no tienen por qué existir). Compara cada fichero con el propietario esperado —el
del directorio destino, o el que se indique con `--owner usuario[:grupo]` /
`RESTORE_OWNER`— y, si no coincide, imprime **un `chown` por fichero**, listo para copiar:

```
[restore] AVISO: 2 ficheros restaurados no son de chatbotph:chatbotph (propietario esperado;
[restore] AVISO: cambialo con --owner U[:G] o RESTORE_OWNER). Ejecuta, uno por fichero:
            sudo chown chatbotph:chatbotph /opt/jitsi-meet/.env
            sudo chown chatbotph:chatbotph /opt/jitsi-meet/admin-panel/instance/admin.env
```

Si en ese servidor los secretos deben seguir siendo de root (como en producción), no
ejecutes esos `chown` (o restaura con `--owner root:root` y no saldrá aviso).

```bash
# Validar el .env
scripts/validate-env.sh .env
```

Si la **IP pública cambió**: actualizar `JVB_ADVERTISE_IPS` (y `JVB_PUBLIC_ADDRESS` si
se usa) en el `.env`, y el registro DNS de `meet.bytracking.net` (TTL bajo antes del cambio).

Los directorios `prosody/config`, `jicofo/config` y `jvb/config` restaurados (si el
respaldo los traía) sirven de referencia, pero las imágenes de Jitsi **los regeneran a partir del `.env` en cada
arranque**; lo que de verdad importa es que el `.env` sea el mismo.

### 5. El secreto del TURN

**Regla: `static-auth-secret` (coturn) == `TURN_CREDENTIALS` (`.env` de Jitsi).**

`TURN_CREDENTIALS` (en el `.env` de Jitsi) y `static-auth-secret` (en el
`turnserver.conf` de coturn) **tienen que ser el mismo valor**. El respaldo guarda el
`turnserver.conf` con `static-auth-secret=CAMBIAR_CON_EL_TURN_CREDENTIALS_DE_JITSI`
(redactado): el valor real solo va, cifrado, dentro del `.env`. Si se reinstala coturn
desde ese fichero **hay que volver a poner el secreto** en el servidor del TURN. Si no coinciden, el
TURN sigue respondiendo a STUN pero rechaza todas las credenciales y quien esté
detrás de una red que bloquea UDP se queda sin audio. El valor nunca se escribe en el repo.

**Caso A — el servidor del TURN sigue intacto.** No hay nada que hacer: el `.env`
restaurado trae el mismo `TURN_CREDENTIALS` que ya usa coturn. Compruébalo en el paso 7
con `scripts/check-turn.sh`.

**Caso B — también hay que rehacer el TURN, o se quiere un secreto nuevo.**
Se genera un secreto nuevo y se pone en los dos lados. Sin imprimirlo en pantalla:

```bash
# --- En el servidor de Jitsi ---
cd /opt/jitsi-meet
umask 077
python3 -c 'import secrets; print(secrets.token_hex(16))' > /root/turn.secret
# Sustituir TURN_CREDENTIALS en el .env sin mostrar el valor
python3 - .env /root/turn.secret <<'EOF'
import sys
env, sec = sys.argv[1], open(sys.argv[2]).read().strip()
lines = open(env).read().split("\n")
lines = [("TURN_CREDENTIALS=" + sec) if l.startswith("TURN_CREDENTIALS=") else l for l in lines]
open(env, "w").write("\n".join(lines))
EOF
# Copiar el fichero al servidor del TURN (canal cifrado) y borrarlo aquí después
scp /root/turn.secret root@<servidor-turn>:/root/turn.secret

# --- En el servidor del TURN ---
cd /opt/coturn
python3 - turnserver.conf /root/turn.secret <<'EOF'
import re, sys
conf, sec = sys.argv[1], open(sys.argv[2]).read().strip()
data = open(conf).read()
data, n = re.subn(r"(?m)^static-auth-secret=.*$", "static-auth-secret=" + sec, data)
assert n == 1, "no se encontro static-auth-secret"
open(conf, "w").write(data)
EOF
chown 65534:65534 turnserver.conf && chmod 600 turnserver.conf
docker restart coturn
shred -u /root/turn.secret

# --- De vuelta en el servidor de Jitsi ---
shred -u /root/turn.secret
```

Si el servidor del TURN se rehace desde cero: copiar `turn/turnserver.conf` y
`turn/docker-compose.turn.yml` a `/opt/coturn`, aplicar el paso anterior, emitir el
certificado con `scripts/turn-cert.sh issue ...` (ver `turn/README.md`) y
`docker compose -f docker-compose.turn.yml up -d`.

El cambio de `TURN_CREDENTIALS` en Jitsi se aplica al **recrear** prosody (no basta
`docker restart`: no relee variables de entorno). En un servidor recién restaurado
esto ocurre solo en el primer `docker compose up -d`.

### 6. Arrancar (decisión del operador)

```bash
cd /opt/jitsi-meet
scripts/install-prosody-plugins.sh      # si prosody/prosody-plugins no viene del clon
docker compose build && docker compose up -d
docker compose ps                        # los 5 servicios 'healthy'
```

Caddy: reinstalar el bloque `infra/caddy/meet.bytracking.net.caddy` en el Caddyfile
del host (`scripts/sync-caddy.sh --apply`).

### 7. Verificar (esto es lo que da por aprobado el criterio)

```bash
# a) El bridge operativo (no basta con 'healthy')
docker exec jitsi-jicofo curl -s http://127.0.0.1:8888/stats \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["bridge_selector"]["operational_bridge_count"])'
# -> 1

# b) El panel arranca con la db restaurada
curl -s https://meet.bytracking.net/healthz        # {"service":"jitsi-admin","status":"ok"}
# entrar en /admin/login con la contraseña de siempre y ver las reuniones existentes

# c) El TURN acepta la credencial del .env restaurado
scripts/check-turn.sh .env -v

# d) Una reunión de prueba con 2 personas: audio en ambos sentidos
```

Anota fecha, servidor y resultado en la tabla de criterios del README.

## Prueba mensual

Una vez al mes, repetir "Restaurar en un servidor limpio" en un VPS de usar y tirar
(alquilado por horas) **con un respaldo copiado fuera del servidor**, no con uno del
propio servidor. Es la única forma de saber que el respaldo, la passphrase guardada
fuera y este procedimiento funcionan juntos. Si el servidor de prueba usa otro dominio,
basta con llegar al punto 7 a) y b) con un `PUBLIC_URL` de prueba.
