# Prueba de carga (Fase 7.3)

Criterio de aceptación: **prueba de carga con 600 clientes aprobada**. Obligatoria antes
de cada asamblea de más de 300 personas (T-7 días en el checklist de la Fase 7.4).

Este directorio **prepara** la prueba; no la ejecuta nadie automáticamente.

## Qué se probó realmente (1-nov-2026, commit `0782429`)

Se lanzaron pruebas de **10, 50 y 120 receptores** con tres scripts:
`escalonado.sh` (grid local), `carga-remota.sh` (grid en `vps2938` por túnel
SSH) y `prueba-3vps.sh` (grids en `vps2938` y `vmi3186036`, 60 por VPS).
Mediciones registradas en el commit:

| Participantes simultáneos | Resultado |
|---|---|
| 10 receptores | 0 fallos, sala creada, 93 s de vida |
| 32 | JVB 0,4 % CPU, 374 MB, 0 `bridge_failures` |
| **48 (pico, 2 grids)** | JVB 9–17 % CPU, 380 MB, 0 `bridge_failures`, 30 MB enviados, 0 errores en Prosody |

Ninguna prueba llegó a meter a la vez los 50 ni los 120 objetivo.

Montaje común: sala única `cargatest0`, 1 emisor (admin) con audio + receptores
con `--use-load-test` y varios receptores por pestaña (`--receivers-per-tab`).
El VPS de producción (`chatbotph`) fue **solo servidor bajo prueba**, nunca
generador de clientes.

**Conclusión:** el límite fue la **RAM de los hosts que generaban los clientes**,
no el servidor de Jitsi. Con 48 simultáneos el JVB no pasó del 17 % de CPU.
**No está demostrado** cuánto aguanta por encima de eso: la prueba de 600 sigue
pendiente y forma parte de la Fase 5. Antes de comprar un servidor dedicado, hacer
un **ensayo real con 50–100 vecinos**.

### Cómo repetirlo

```bash
# Token de la sala de prueba en /tmp/jwt-carga.txt (lo leen los tres scripts)
python3 loadtest/make-token.py /opt/jitsi-meet/.env --room cargatest0 --hours 3 --out /tmp/jwt-carga.txt
# (make-token.py necesita el .env de Jitsi: generarlo en el VPS y copiarlo, chmod 600)

loadtest/escalonado.sh 10 120 3000 5          # humo: receptores, duración s, join-delay ms, recv/pestaña
loadtest/carga-remota.sh 50 180 1000 8        # requiere: ssh -N -L 4444:localhost:4444 vps2938
loadtest/prueba-3vps.sh 60 180 6              # 60 por VPS generador -> 120 objetivo
shred -u /tmp/jwt-carga.txt                   # al terminar
```

Requisitos: clon de `jitsi-meet-torture` en `/root/jitsi-meet-torture`, JDK 17 y
Maven, y un Selenium Grid (`docker-compose.selenium.yml`) en cada generador.
*A verificar antes de repetir:* las pruebas pasaban el JWT con
`--extra-*-params=jwt=…` el 1-nov por la mañana, antes de que se descubriera que
`stable-11031` ignora `#jwt=` (`4535fd9`). Si los clientes no entran
("token required" en Prosody), es eso.

Las secciones siguientes describen `run.sh`, el envoltorio pensado para la
prueba completa de 600 con criterios automáticos. Se escribió antes de las
mediciones; las pruebas de arriba usaron los tres scripts directamente.

| Fichero | Para qué |
|---|---|
| `run.sh` | Envoltorio de Malleus: comprobaciones previas, muestreo del JVB durante la prueba y tabla de resultados. **`--dry-run` por defecto**; solo lanza con `--run` |
| `make-token.py` | Firma el JWT de la sala de prueba (en el servidor de Jitsi; solo stdlib) |
| `summarize.py` | Genera la tabla de resultados (la llama `run.sh`; también `run.sh --summarize DIR`) |
| `malleus-sala-prueba.md` | Los comandos concretos para `meet.bytracking.net` |
| `results/` | Un subdirectorio por prueba (ignorado por git) |

## La herramienta: Malleus

Malleus es el script `scripts/malleus.sh` de **[jitsi-meet-torture](https://github.com/jitsi/jitsi-meet-torture)**
(el repositorio oficial de Jitsi). Arranca navegadores Chrome reales en un **Selenium
Grid** y los mete en la sala. *(La URL `github.com/maleus/jitsi-meet-load-tests` que
circulaba en el brief no existe: devuelve 404.)*

Malleus **no** tiene `--users`/`--rooms`; sus equivalentes son:

| Lo que se quiere | Opción de Malleus | Valor para la prueba de 600 |
|---|---|---|
| Número de salas | `--conferences` | `1` (una asamblea = una sala) |
| Clientes por sala | `--participants` | `600` |
| Clientes que envían vídeo | `--senders` | `1` (el administrador en cámara) |
| Clientes que envían audio | `--audio-senders` | `3` (los oradores) |
| Cuánto dura cada cliente | `--duration` (s) | `2700` (45 min) |
| Ritmo de entrada | `--join-delay` (ms; el cliente *i* entra en *i × delay*) | `300` → 600 entradas en 3 min |
| Cliente ligero | `--use-lite-mode` | sí (los receptores no decodifican vídeo) |

### Detalles verificados en el código actual de jitsi-meet-torture

- **Nombre de la sala:** Malleus la llama `<room-name-prefix><índice>`. Con
  `--room-name-prefix=cargatest` y una conferencia, la sala es **`cargatest0`**. El JWT
  debe ser para esa sala exacta (`run.sh` lo comprueba).
- **El JWT:** `malleus.sh --jwt` lo pasa como `-Dorg.jitsi.token`, pero **ningún código de
  Malleus lee esa propiedad** en la versión actual. Por eso `run.sh` mete el token en el
  fragmento de la URL con `--extra-sender-params=jwt=…` y `--extra-receiver-params=jwt=…`
  (queda `…/cargatest0#jwt=…`, igual que los enlaces del panel). **VERIFICAR** si se usa
  otra versión.
- **`--use-load-test`** (el cliente de carga "de verdad") abre `…/_load-test/<sala>`, que
  **no existe en la imagen `jitsi/web`**: habría que construir y servir el cliente
  `load-test` de jitsi-meet. Por eso se usa `--use-lite-mode`
  (`config.flags.runInLiteMode=true` sobre el cliente normal).

## Antes de la prueba

1. **Subir `MAX_PARTICIPANTS`.** En el `.env` vale `500`, y Prosody **rechaza en
   silencio** a partir de ese número: con 600 clientes, 100 no entrarían y la prueba
   fallaría por configuración, no por capacidad. Para la prueba: `MAX_PARTICIPANTS=620`
   y `MAX_BRIDGE_PARTICIPANTS=620` (clientes + administrador + 3 dispositivos reales +
   margen), y recrear: `docker compose up -d --force-recreate prosody jicofo`.
   `run.sh` lo comprueba. Si para las asambleas reales se quiere volver a 500, decidirlo
   *después* de la prueba.
2. **Rate limits de Prosody.** Hoy están desactivados (`PROSODY_ENABLE_RATE_LIMITS=0`,
   ver README 3.4). Si se activan, las VMs de carga comparten pocas IP y chocarían con
   `login_rate=3/s por IP`: añade sus IP a `PROSODY_RATE_LIMIT_ALLOW_RANGES`.
3. **VMs de carga.** Los clientes simulados gastan CPU real: repártelos en varias VMs
   grandes alquiladas por horas (orientativo: 1 vCPU y ~1 GB por cada 4–6 clientes en lite
   mode; **medir en la prueba de humo**). Si las VMs se saturan, la prueba falla por ellas
   y no por el servidor: vigila su CPU durante la prueba.
4. **Selenium Grid** (Grid 4) con nodos Chrome en esas VMs; la VM de control necesita
   el clon de jitsi-meet-torture, JDK 17 y Maven.
5. **Acceso al servidor** para medir: `run.sh --server ssh:root@<servidor>` (clave SSH
   sin contraseña) o ejecutar `run.sh --server local` en el propio servidor.
6. **Monitorización abierta** (Grafana si ya existe, o `docker stats` + `htop`).
7. **Tres dispositivos reales** (un móvil con datos, un PC normal y un PC con UDP
   bloqueado → prueba también el TURN) conectados a la sala durante toda la prueba.

## Cómo ejecutarla

Ver `malleus-sala-prueba.md` para los comandos exactos. En resumen:

```bash
# 1. En el servidor de Jitsi: token para la sala de prueba (no se imprime)
python3 loadtest/make-token.py /opt/jitsi-meet/.env --room cargatest0 --hours 3 --out /root/cargatest0.jwt
# 2. Copiarlo a la VM de control (scp) y allí:
loadtest/run.sh --server ssh:root@meet.bytracking.net --jwt-file ~/cargatest0.jwt \
    --hub http://<grid>:4444/wd/hub --torture ~/jitsi-meet-torture            # dry-run
# 3. Prueba de humo: 10 clientes, 5 minutos
loadtest/run.sh ...mismos argumentos... --participants 10 --duration 300 --join-delay 1000 --run
# 4. La prueba de 600
loadtest/run.sh ...mismos argumentos... --run
```

**Escenario mínimo** del plan: entrada de 600 en 3 minutos, 45 minutos con el
administrador en cámara y 3 oradores rotando, 10 minutos con pantalla compartida.
La pantalla compartida y la rotación de oradores las hace **el administrador real** desde
su dispositivo durante la prueba (Malleus no comparte pantalla). `--switch-speakers` de
Malleus hace hablar por turnos a los audio-senders.

## Cómo leer el informe

`run.sh --run` deja en `results/<fecha>/`:

- `malleus.log` — salida de Malleus/Maven (el token aparece como `<JWT>`). Al final:
  `Tests run: N, Failures: F, Errors: E`.
- `samples.csv` — una muestra cada 15 s: participantes y conferencias del JVB,
  `stress_level`, pérdida, bitrate de salida, CPU de los contenedores jvb y prosody.
  **Mira la columna `participants`**: debe subir en rampa hasta ~600 en 3 min y
  quedarse plana; un escalón hacia abajo es una desconexión masiva.
- `prosody.log` — log de Prosody del periodo de la prueba.
- `summary.md` — la tabla de criterios con PASA / FALLA / MANUAL.

Las claves de `/colibri/stats` (`participants`, `stress_level`, `incoming_loss`,
`outgoing_loss`, `bit_rate_upload`) son las de JVB 2.3; **VERIFICAR** una vez con
`docker exec jitsi-jvb curl -s localhost:8080/colibri/stats` que existen (si falta
alguna, su criterio sale `SIN DATOS` y la prueba no se da por aprobada).

## Criterios para aprobar (objetivos)

La prueba **pasa** solo si se cumplen **todos**:

| # | Criterio | Umbral | De dónde sale |
|---|---|---|---|
| 1 | Clientes conectados a la vez | **≥ 95 %** de 600 (≥ 570) en el pico | `participants` del JVB |
| 2 | Malleus sin fallos | `Failures + Errors = 0` | `malleus.log` |
| 3 | Sin desconexión masiva | la curva de `participants` no cae más de un 5 % de golpe | `samples.csv` (manual) |
| 4 | CPU del servidor (JVB) | **< 70 %** de la máquina en el pico | `docker stats` normalizado por nº de CPU |
| 5 | CPU de Prosody | **< 70 % de UN núcleo** | Prosody es de un solo hilo: 100 % de un núcleo = saturado aunque haya 16 |
| 6 | Saturación del JVB | `stress_level` **< 0,7** | `/colibri/stats` |
| 7 | Pérdida de paquetes | **< 2 %** | `incoming_loss`/`outgoing_loss` del JVB |
| 8 | Red de salida | **< 70 %** del puerto (`--port-mbps`, 1000 por defecto) | `bit_rate_upload` del JVB |
| 9 | Prosody sin rate limit | 0 líneas `rate exceeded` / `Enabling throttle` | `prosody.log` |
| 10 | Prosody sin errores de autenticación | 0 líneas `Error verifying token` / `not-authorized` | `prosody.log` |
| 11 | Audio real | sin cortes en los **3 dispositivos reales** durante toda la prueba | manual |

Latencia: el JVB publica `rtt_aggregate` en `/colibri/stats`; como referencia, un RTT
medio por encima de ~300 ms se nota en la conversación. No es criterio automático porque
depende de dónde estén las VMs de carga; los 3 dispositivos reales son la medida que
importa.

Los umbrales se pueden ajustar por variable de entorno (`MIN_CONNECTED_PCT`,
`MAX_STRESS`, `MAX_JVB_CPU_PCT`, `MAX_PROSODY_CPU_PCT`, `MAX_LOSS_PCT`, `MAX_NET_PCT`),
pero cambiarlos para que una prueba "pase" invalida el criterio.

Si la prueba falla, el orden habitual de sospechosos (Fase 5 del plan): Prosody (CPU de
un núcleo), la red de salida, y por último el JVB.

## Después

- Anotar resultado, fecha y versión en la tabla de criterios del README.
- Volver a dejar `MAX_PARTICIPANTS` en el valor decidido y recrear prosody/jicofo.
- Borrar el token: `shred -u ~/cargatest0.jwt` (en la VM de control y en el servidor).
