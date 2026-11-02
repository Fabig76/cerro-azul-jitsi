# Asambleas Virtuales (votacionph.us): índice de su documentación

**Repo:** <https://github.com/Fabig76/asambleas-virtuales> (privado, mismo autor).
Descripción en GitHub: *"Portal de Asambleas Virtuales ByTracking - App (M00-M16)"*.
Revisado el 3-nov-2026 sobre el commit `77c3cdc` (último push 2026-10-31):
**44 ficheros `.md`**.

Este documento **no copia** su contenido: explica qué es cada documento y cuál
leer según lo que necesites. Los enlaces apuntan a la rama `main` de ese repo
(hace falta acceso a GitHub con la cuenta `Fabig76`). Si GitHub no está
disponible, el respaldo de migración lleva una copia completa del repo en
`claro/repos/asambleas-virtuales.bundle` (`git clone` de ese fichero; ver
[`RESTAURAR-EN-OTRO-SERVIDOR.md`](RESTAURAR-EN-OTRO-SERVIDOR.md)).

## Qué es y cómo encaja con este proyecto

Es la **otra mitad del sistema**: el portal donde los propietarios de un
conjunto (propiedad horizontal, Ley 675 de 2001, Colombia) se identifican con
su cédula y un código personal, registran asistencia, y **votan**; calcula
quórum y mayorías, guarda una bitácora encadenada como prueba y genera el acta.
App Node.js/TypeScript (Fastify 5, Socket.IO, SQLite), Docker Compose con Caddy y
cloudflared, publicada en `https://votacionph.us/asambleasvirtuales/` desde
**otro servidor** (no está en `chatbotph` ni en `vmi3186036`; su manual lo llama
`vps2938`).

Cerro Azul Jitsi pone la **videoconferencia**: votacionph.us pide a nuestro panel
un enlace con JWT por persona (`POST /api/reuniones/<id>/token`, Fase 6) y abre
la sala de Jitsi. Esa integración está documentada **en este repo**
([`INTEGRACION-JITSI.md`](INTEGRACION-JITSI.md), [`integracion/`](../integracion/)),
no en el suyo: sus documentos se escribieron para Google Meet (el SPEC lo da
por supuesto) y todavía no mencionan Jitsi salvo en la comparativa del SPEC.

Qué cubre nuestro respaldo de ese proyecto: **solo el código** (`git bundle`).
Sus secretos (`/opt/bytracking/secrets/`), su base de datos (volumen
`infra_app_data`) y su despliegue van con su propio procedimiento: ver
`infra/respaldo.sh` y `docs/MANUAL_TECNICO.md` §14 de su repo.

## Qué leer según lo que necesites

| Si necesitas… | Lee, en este orden |
|---|---|
| Entender el producto en 10 minutos | `README.md` → `docs/MANUAL_TECNICO.md` §1–3 |
| Trabajar en el código (persona o agente) | `AGENTS.md` (completo, manda) → `docs/MANUAL_TECNICO.md` → `docs/contratos/README.md` → el `docs/modulos/Mxx` del módulo |
| Saber por qué se diseñó así | `docs/SPEC.md` (§1 decisiones, §5 Meet, §8 fórmulas) |
| Operar una asamblea real | `docs/OPERACION.md` (T−7 días … T+1 hora, contingencias) |
| Desplegar o reconstruir su servidor | `docs/DESPLIEGUE.md` → `docs/MANUAL_TECNICO.md` §14 → `docs/modulos/M15-infraestructura.md` |
| Integrarse por API | `docs/contratos/api.md` (+ `eventos.md` para tiempo real) |
| Preparar la hoja de un conjunto | `docs/contratos/sheet.md` → `docs/modulos/M04-hoja.md`, `M05-importacion.md` |
| Revisar algo legal / de datos personales | `docs/legal/VERSIONES.md` → el texto concreto → `docs/legal/hashes.md` |
| Saber qué está pendiente de decidir | `docs/DECISIONES_PENDIENTES.md` y `docs/PREGUNTAS.md` |
| Saber qué se hizo y cuándo | `docs/BITACORA_AGENTE.md` (cronológico por módulo) |
| Cambiar la interfaz | `docs/diseno/SISTEMA_DE_DISENO.md` |

## Índice razonado

Base de enlaces: `https://github.com/Fabig76/asambleas-virtuales/blob/main/`.

### Raíz

| Documento | Tamaño | Qué es / para qué sirve |
|---|---|---|
| [`AGENTS.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/AGENTS.md) | 12 KB | **Reglas de trabajo** para quien toque el código: orden de lectura, qué manda si dos textos chocan, reglas para no inventar (dependencias, versiones, rutas), ficheros sellados, qué significa "terminado", cuándo parar y preguntar, formato del reporte y comandos. Léelo antes de cualquier cambio |
| [`CLAUDE.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/CLAUDE.md) | 0,2 KB | Solo remite a `AGENTS.md` |
| [`README.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/README.md) | 4 KB | Estado del proyecto (oct-2026: M00–M15 hechos, M16 parcial, 338 tests), estructura del repo (`src/`, `pruebas/`, `herramientas/`, `infra/`) y URL de producción |

### `docs/` — documentos generales

| Documento | Tamaño | Qué es / para qué sirve |
|---|---|---|
| [`SPEC.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/SPEC.md) | 53 KB | **Especificación técnica y funcional** original, con fuentes: por qué Meet no se incrusta (portal "compañero"), comparativa de plataformas, actores, flujos, requisitos con criterios de aceptación, fórmulas legales (quórum, mayorías, art. 46, cuociente), modelo de datos, seguridad del VPS, cumplimiento, plan de pruebas, hoja de ruta y riesgos. Es el **porqué**; el detalle vigente está en contratos y módulos |
| [`MANUAL_TECNICO.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/MANUAL_TECNICO.md) | 23 KB | **Arquitectura y convenciones**: capas, convenciones de código, ciclo de vida de una asamblea, reglas de negocio, seguridad, interfaz, orden de construcción, pruebas, escalabilidad, diferencias con el SPEC, glosario, y §14 **operación en producción** (volúmenes, secretos, usuario del proceso) |
| [`BITACORA_AGENTE.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/BITACORA_AGENTE.md) | 56 KB | **Diario de construcción** por módulo y fecha: qué se hizo, qué se probó, commits. Para reconstruir la historia de una decisión o un fallo |
| [`DESPLIEGUE.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/DESPLIEGUE.md) | 9 KB | **Estado del despliegue real** en votacionph.us: URLs verificadas, servicios del compose (app, caddy, cloudflared), secretos (nombres, no valores), desviaciones del SPEC, el bug de rutas de Fastify 5, pendientes y cronología |
| [`OPERACION.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/OPERACION.md) | 5 KB | **Guía del día de la asamblea**: lista T−7 días, T−2 h, durante, cierre, T+1 h; contingencias; scripts (`encender.sh`, `apagar.sh`, `respaldo.sh`); SMTP con Gmail |
| [`DECISIONES_PENDIENTES.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/DECISIONES_PENDIENTES.md) | 4 KB | Tabla D-01… de decisiones **del cliente o del abogado** (morosos, topes de poderes, parqueaderos…), con el valor por defecto que usa el sistema y dónde se configura |
| [`PREGUNTAS.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/PREGUNTAS.md) | 3 KB | Preguntas abiertas del agente (P-002…) que necesitan a una persona: credenciales reales, pruebas con Sheet/SMTP/VPS… |

### `docs/contratos/` — lo que comparten los módulos (máxima autoridad)

| Documento | Tamaño | Qué fija |
|---|---|---|
| [`README.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/contratos/README.md) | 2 KB | Índice de contratos y dónde vive cada uno (algunos son código: esquemas SQL, motor, puertos) |
| [`api.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/contratos/api.md) | 20 KB | **Todas las rutas HTTP** (prefijo `/asambleasvirtuales`), formato de error, fechas, y el catálogo de códigos de error |
| [`eventos.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/contratos/eventos.md) | 4 KB | Tiempo real (Socket.IO en `/asambleasvirtuales/ws`): autenticación, salas, eventos, límites. Los votos **no** van por socket |
| [`estados.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/contratos/estados.md) | 5 KB | Ciclo de vida (`borrador → … → archivada`) e interruptores: qué se permite en cada estado |
| [`bitacora.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/contratos/bitacora.md) | 4 KB | Registro encadenado (prueba legal, art. 42): reglas, tipos de entrada, qué nunca contiene |
| [`sheet.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/contratos/sheet.md) | 7 KB | Pestañas, columnas y valores del **Google Sheet** de cada conjunto |
| [`entorno.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/contratos/entorno.md) | 3 KB | Variables de entorno y **nombres** de secretos que lee `src/config.ts` |
| [`dependencias.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/contratos/dependencias.md) | 5 KB | Lista cerrada de paquetes npm permitidos y la regla de instalación (sin versiones de memoria) |

### `docs/modulos/` — un fichero por módulo (M00–M17)

Cada uno: estado, dependencias, ficheros que toca, comportamiento y pruebas.
Algunos añaden "Cambios verificados en producción (oct-2026)".

| Módulo | Estado (oct-2026) | De qué trata |
|---|---|---|
| [`M00-base`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M00-base.md) | hecho | Servidor, configuración validada, logs sin datos personales, `/salud` |
| [`M01-motor`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M01-motor.md) | hecho, **sellado** | Reglas legales puras: coeficientes, poderes, quórum, mayorías, cuociente, art. 46. No se toca sin aprobación |
| [`M02-datos`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M02-datos.md) | hecho | SQLite (una base por asamblea + plataforma), esquema, bitácora, repositorios |
| [`M03-seguridad`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M03-seguridad.md) | hecho | Cifrado de datos personales, sesiones, límites, CSRF, verificación humana, credenciales |
| [`M04-hoja`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M04-hoja.md) | hecho | Leer/escribir el Google Sheet |
| [`M05-importacion`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M05-importacion.md) | hecho | Importar el padrón; contactos cifrados |
| [`M06-codigos-mensajeria`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M06-codigos-mensajeria.md) | hecho (correo) | Códigos de acceso y envío por SMTP |
| [`M07-publico`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M07-publico.md) | hecho | Portada y buscador de conjuntos |
| [`M08-acceso`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M08-acceso.md) | hecho | Ingreso con cédula + código; constancia de asistencia |
| [`M09-tiempo-real`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M09-tiempo-real.md) | hecho | Presencia, quórum en vivo, Socket.IO |
| [`M10-votaciones`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M10-votaciones.md) | hecho (sí/no, opción única) | Crear, abrir, votar, cerrar, publicar |
| [`M11-entorno-asistente`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M11-entorno-asistente.md) | hecho | Pantalla del asistente; Turnstile condicional |
| [`M12-panel`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M12-panel.md) | hecho | Panel `/admin` y su API |
| [`M13-proyeccion`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M13-proyeccion.md) | hecho | Pantalla de proyección (pregunta, avance, resultado) |
| [`M14-reportes`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M14-reportes.md) | hecho (CSV, hoja) | Acta, exportes y verificación de la bitácora |
| [`M15-infraestructura`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M15-infraestructura.md) | hecho | VPS, compose, Caddy + cloudflared, **permisos de secretos** (UID 10001) |
| [`M16-extremo-a-extremo`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M16-extremo-a-extremo.md) | parcial (k6 pendiente) | Recorrido completo verificado en producción; prueba de carga pendiente |
| [`M17-fase-2`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/modulos/M17-fase-2.md) | parcial | Lo que **no** entra en el MVP (planchas, WhatsApp, impresos, API de Meet, PDF) y qué falta para cada cosa |

### `docs/diseno/`

| Documento | Tamaño | Qué es |
|---|---|---|
| [`SISTEMA_DE_DISENO.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/diseno/SISTEMA_DE_DISENO.md) | 12 KB | Sistema visual "ventanas encendidas" (el quórum dibujado como edificios), colores por conjunto, temas claro/oscuro, componentes; pantallas de referencia en `referencia/` |

### `docs/legal/` — textos legales v1.0 (vigentes desde 2026-10-10)

Aprobados por el abogado del operador. **No se editan sin nueva versión**: cada
texto tiene un hash que la bitácora guarda con cada aceptación.

| Documento | Tamaño | Qué es |
|---|---|---|
| [`VERSIONES.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/legal/VERSIONES.md) | 2 KB | Índice de los textos, versión y fecha de vigencia. Empezar aquí |
| [`autorizacion-ingreso.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/legal/autorizacion-ingreso.md) | 4 KB | Autorización en la pantalla de ingreso (casillas y cómo se registra) |
| [`aviso-privacidad.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/legal/aviso-privacidad.md) | 4 KB | Aviso corto junto a la casilla (Decreto 1074 de 2015) |
| [`politica-tratamiento.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/legal/politica-tratamiento.md) | 7 KB | Política publicada en `/privacidad` |
| [`condiciones-tratamiento.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/legal/condiciones-tratamiento.md) | 11 KB | Contrato de encargo ByTracking ↔ copropiedad (Ley 1581 de 2012) |
| [`hoja-adhesion.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/legal/hoja-adhesion.md) | 3 KB | Hoja que firma el representante legal en el panel |
| [`hashes.md`](https://github.com/Fabig76/asambleas-virtuales/blob/main/docs/legal/hashes.md) | 2 KB | sha256 de cada texto (recalculados el 2026-10-29) |

## Cómo listar los documentos de nuevo

```bash
gh api 'repos/Fabig76/asambleas-virtuales/git/trees/main?recursive=1' \
  --jq '.tree[] | select(.path|endswith(".md")) | "\(.size)\t\(.path)"'
```

Si el número deja de ser 44, actualizar este índice.
