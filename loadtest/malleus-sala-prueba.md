# Malleus contra la sala de prueba de meet.urbcerroazul.com

Comandos concretos para este proyecto. Contexto, criterios y lectura del informe en
`loadtest/README.md`. Nada de esto se ejecuta solo.

## Valores del proyecto

| Variable | Valor |
|---|---|
| Instancia | `https://meet.urbcerroazul.com` |
| Prefijo de sala (Malleus) | `cargatest` → sala **`cargatest0`** |
| Emisor del JWT (`iss`) | primer valor de `JWT_ACCEPTED_ISSUERS` (hoy `cerroazul-panel`) |
| Audiencia (`aud`) | primer valor de `JWT_ACCEPTED_AUDIENCES` (hoy `cerroazul`) |
| Firma | HS256 con `JWT_APP_SECRET` del `.env` del servidor |
| Contenedores | `jitsi-prosody`, `jitsi-jicofo`, `jitsi-jvb` |

La sala de prueba **no** es una reunión del panel: Malleus impone el nombre
`<prefijo>0`, y los clientes de carga comparten un único token sin `context.user.id`
(ver `make-token.py`). Con `JWT_ALLOW_EMPTY=0`, sin ese token nadie entra en la sala.

## 0. En el servidor de Jitsi: preparar el límite y el token

```bash
cd /opt/jitsi-meet
# Límite de participantes para la prueba (con 500 se quedarían fuera 100 clientes)
sed -i 's/^MAX_PARTICIPANTS=.*/MAX_PARTICIPANTS=620/; s/^MAX_BRIDGE_PARTICIPANTS=.*/MAX_BRIDGE_PARTICIPANTS=620/' .env
docker compose up -d --force-recreate prosody jicofo
docker exec jitsi-prosody printenv MAX_PARTICIPANTS      # -> 620

# Token de la sala de prueba, válido 3 h (escrito con chmod 600, no se imprime)
python3 loadtest/make-token.py .env --room cargatest0 --hours 3 --out /root/cargatest0.jwt
```

Copiarlo a la VM de control por un canal cifrado:

```bash
scp root@meet.urbcerroazul.com:/root/cargatest0.jwt ~/cargatest0.jwt && chmod 600 ~/cargatest0.jwt
```

## 1. En la VM de control: preparar Malleus

```bash
git clone https://github.com/jitsi/jitsi-meet-torture ~/jitsi-meet-torture
sudo apt install -y openjdk-17-jdk maven
# Selenium Grid 4 con nodos Chrome en las VMs de carga (docker-selenium: hub + node-chrome)
curl -s http://<grid>:4444/status        # "ready": true
```

## 2. Comprobaciones previas (dry-run, no lanza nada)

```bash
cd ~/cerro-azul-jitsi
loadtest/run.sh \
    --server ssh:root@meet.urbcerroazul.com \
    --instance https://meet.urbcerroazul.com \
    --room-prefix cargatest \
    --jwt-file ~/cargatest0.jwt \
    --hub http://<grid>:4444/wd/hub \
    --torture ~/jitsi-meet-torture
```

Debe salir todo `OK` (web 200, JWT de `cargatest0` vigente, `operational_bridge_count=1`,
JVB sano, `MAX_PARTICIPANTS` ≥ 610, Grid ready, malleus.sh y mvn presentes).

## 3. Prueba de humo: 10 clientes, 5 minutos

```bash
loadtest/run.sh --server ssh:root@meet.urbcerroazul.com --jwt-file ~/cargatest0.jwt \
    --hub http://<grid>:4444/wd/hub --torture ~/jitsi-meet-torture \
    --participants 10 --audio-senders 1 --duration 300 --join-delay 1000 --run
```

Mientras corre, entra con tu dispositivo a la sala con el token del administrador y
comprueba (**VERIFICAR**, son las incógnitas de esta configuración):

- aparecen **10 participantes distintos** "carga" (no uno solo: el token compartido no
  lleva `context.user.id`);
- el audio-sender se oye. Si entra silenciado por `startAudioMuted=0` (Fase 3), repetir
  con `--extra-sender-params 'config.startWithAudioMuted=false'`;
- cuánta CPU gastan las VMs de carga por cliente → dimensionar las VMs para 600.

## 4. La prueba de 600

```bash
loadtest/run.sh --server ssh:root@meet.urbcerroazul.com --jwt-file ~/cargatest0.jwt \
    --hub http://<grid>:4444/wd/hub --torture ~/jitsi-meet-torture \
    --participants 600 --senders 1 --audio-senders 3 \
    --duration 2700 --join-delay 300 --port-mbps 1000 --run
```

El comando de Malleus que se ejecuta (el token se muestra como `<JWT>`):

```text
~/jitsi-meet-torture/scripts/malleus.sh --conferences=1 --participants=600 --senders=1 \
    --audio-senders=3 --duration=2700 --join-delay=300 --room-name-prefix=cargatest \
    --hub-url=http://<grid>:4444/wd/hub --instance-url=https://meet.urbcerroazul.com \
    --headless --extra-sender-params=jwt=<JWT> --extra-receiver-params=jwt=<JWT> --use-lite-mode
```

Durante la prueba (45 min + 3 de entrada):

- el **administrador real** entra con su token del panel, enciende la cámara, a los
  ~30 min comparte pantalla 10 minutos y da la palabra a sus 3 dispositivos de prueba;
- los **3 dispositivos reales** (móvil con datos, PC normal, PC con UDP bloqueado)
  escuchan todo el tiempo y anotan cualquier corte con la hora;
- vigilar la CPU de las VMs de carga (si pasan del ~85 %, la prueba no es válida).

## 5. Resultado

`run.sh` imprime y guarda `results/<fecha>/summary.md`. Para rehacer la tabla:

```bash
loadtest/run.sh --summarize loadtest/results/<fecha>
```

## 6. Limpieza

```bash
shred -u ~/cargatest0.jwt                                  # VM de control
ssh root@meet.urbcerroazul.com 'shred -u /root/cargatest0.jwt'
# En el servidor: devolver MAX_PARTICIPANTS al valor decidido y recrear prosody/jicofo
```
