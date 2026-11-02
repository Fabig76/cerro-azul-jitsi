# Copia de seguridad completa en Google Drive (Fase 10)

Objetivo: si se pierde un servidor, poder restaurar el proyecto entero
(código, configuración, secretos y datos) siguiendo [`RESTAURAR.md`](RESTAURAR.md).

Esto **complementa** a `scripts/backup.sh` (Fase 7.2, ver
[`BACKUP-RESTORE.md`](BACKUP-RESTORE.md)), que guarda el estado dentro del
propio VPS: una copia en el mismo disco no sobrevive a la pérdida del disco.

## Qué se guarda y dónde

Carpeta **backup** de Drive (`1Ov4zUYBtyp01QLlDT8arobe29q6n8VuB`,
<https://drive.google.com/drive/folders/1Ov4zUYBtyp01QLlDT8arobe29q6n8VuB>),
dos ficheros por copia:

| Paquete | Cifrado | Contenido |
|---|---|---|
| `cerro-azul-jitsi-proyecto-<fecha>.tar.gz` | no (no lleva secretos) | repo con historial (`git bundle --all`) + árbol de trabajo; `/opt/jitsi-meet` de producción sin secretos; Caddyfile del host; watchdog de Hermes y la definición de su job |
| `cerro-azul-jitsi-secretos-<fecha>.tar.gz.enc` | **sí**, AES-256-CBC | `.env`, `admin.env`, `reuniones.db`, `web/config/keys/`, `prosody/config/certs/`, `/root/.backup_passphrase` del VPS, `turn.env` del watchdog, y del TURN `turnserver.conf`, `.secret`, `docker-compose.turn.yml` y `certs/` |

Cada paquete lleva dentro un `MANIFIESTO.txt` (qué hay, tamaños, fecha, cómo
restaurar) y un `SHA256SUMS`.

**Frecuencia:** manual por ahora (antes y después de cada cambio importante).
**Propuesta** (no instalada): semanal por cron en el host de desarrollo, que es
quien tiene las claves SSH y el acceso a Drive:

```cron
# /etc/cron.d/cerro-azul-backup-drive  (domingo 04:30, fuera de asambleas)
30 4 * * 0 root /root/cerro-azul-jitsi/scripts/backup-completo.sh >> /var/log/cerro-azul-backup-drive.log 2>&1
```

Si a esa hora hay gente en una sala el script sale con código 3 sin tocar nada;
convendría que el watchdog de Hermes avisara si la última copia tiene más de
8 días. La retención en Drive es manual (borrar las copias viejas a mano).

## El script

```bash
cd /root/cerro-azul-jitsi
scripts/backup-completo.sh                 # copia completa + subida + verificación
scripts/backup-completo.sh --sin-subir     # solo genera y verifica en local
scripts/backup-completo.sh --sin-verificar # sube pero no descarga para comprobar
```

Se ejecuta como root en el host de desarrollo (`vmi3186036`). Pasos:

1. Lee `/stats` de jicofo en `chatbotph`. Si `participants` o `conferences` > 0,
   **aborta** (código 3): la BD no se copia en caliente.
2. Crea `/root/.cerro-azul-backup/trabajo/backup-<AAAAMMDD-HHMM>/` (700).
3. Paquete A: `git bundle create --all` + los ficheros que ve git (sin
   ignorados, sin `__pycache__`/`.venv`/`node_modules`); por SSH, el deploy sin
   secretos, el Caddyfile; el watchdog.
4. Paquete B: por SSH con `sudo`, los secretos; `reuniones.db` con la API de
   backup de sqlite (copia consistente, comprobada con `integrity_check`); los
   secretos del TURN; la clave. Falla si falta alguno.
5. Escribe `MANIFIESTO.txt` y `SHA256SUMS`, empaqueta, cifra B y **borra los
   ficheros en claro**.
6. Verifica en local: extrae A, comprueba sumas, `git bundle verify`, clona el
   bundle y compara el `HEAD`; descifra B y comprueba sumas.
7. Sube los dos a Drive, los **vuelve a descargar**, compara los sha256 con lo
   subido, repite la verificación del paso 6 sobre lo descargado y comprueba
   con `drive get` que están en la carpeta.

Deja los paquetes (600) y `DRIVE_IDS.txt` en el directorio de trabajo.
No reinicia ni cambia nada en los servidores. Variables:
`BACKUP_CLAVE`, `DRIVE_CARPETA`, `HOST_JITSI`, `HOST_TURN`, `BACKUP_TRABAJO`.

## La clave de cifrado

- Fuente de verdad: **`/root/.cerro-azul-backup/CLAVE.txt`** en el host de
  desarrollo (600, root). El script la lee de ahí, o de `BACKUP_CLAVE`.
- ⚠️ **Nunca** en el repo (`.gitignore` excluye `CLAVE.txt` y `*.clave`) ni en
  Drive en claro. El script no la imprime ni la escribe en el manifiesto.
- El paquete B lleva una copia de la clave **dentro** (cifrada con ella misma):
  sirve para que, una vez abierto, quede junto a los secretos; **no** sirve para
  abrirlo. Por eso el dueño debe guardar otra copia fuera de los servidores
  (gestor de contraseñas). Si el host de desarrollo se pierde y no hay otra
  copia de la clave, el paquete B es irrecuperable.
- Es distinta de `/root/.backup_passphrase` del VPS (la de `scripts/backup.sh`),
  que va dentro del paquete B.

Cifrado: `openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -md sha256 -pass file:CLAVE`.
`openssl enc` no admite AEAD; la integridad la dan los `SHA256SUMS` de dentro
del paquete (una clave equivocada da `bad decrypt` o un tar ilegible).

## Restaurar

Ver [`RESTAURAR.md`](RESTAURAR.md).

## Comprobar que la última copia está bien

```bash
GAPI="python $HOME/.hermes/skills/productivity/google-workspace/scripts/google_api.py"
$GAPI drive search "'1Ov4zUYBtyp01QLlDT8arobe29q6n8VuB' in parents and trashed = false" --raw-query
# bajar los dos de la fecha más reciente a un directorio vacío
mkdir -m 700 /tmp/v && cd /tmp/v
$GAPI drive download <ID_A> --output a.tar.gz
$GAPI drive download <ID_B> --output b.tar.gz.enc

mkdir a b
tar xzf a.tar.gz -C a && (cd a && sha256sum -c --quiet SHA256SUMS) && echo "A ok"
git bundle verify a/repo/cerro-azul-jitsi.bundle
git clone -q a/repo/cerro-azul-jitsi.bundle clon && git -C clon log --oneline | head -3
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
  -pass file:/root/.cerro-azul-backup/CLAVE.txt -in b.tar.gz.enc | tar xzf - -C b
(cd b && sha256sum -c --quiet SHA256SUMS) && echo "B ok"

# comparar con producción
ssh chatbotph 'sudo sha256sum /opt/jitsi-meet/docker-compose.yml /opt/jitsi-meet/web/config/custom-config.js'
sha256sum a/produccion/opt-jitsi-meet/docker-compose.yml a/produccion/opt-jitsi-meet/web/config/custom-config.js

cd / && rm -rf /tmp/v
```

Los `.tar.gz` con fecha guardados en `/root/.cerro-azul-backup/trabajo/` tienen
los mismos bytes que lo subido (`SHA256SUMS.paquetes`).
