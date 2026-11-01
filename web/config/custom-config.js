/* =====================================================================
 * custom-config.js - Fase 3: sala grande (estabilidad) - Cerro Azul
 *
 * QUE ES
 *   Las asambleas del conjunto son UNA sala grande (objetivo: 500
 *   personas) con un unico ponente (el administrador): 1 camara + pantalla
 *   compartida, y el resto escuchando. Jitsi por defecto esta pensado para
 *   reuniones pequenas donde todos envian y reciben video; a 500 personas
 *   eso satura el JVB y, sobre todo, los moviles/PCs modestos de los
 *   asistentes. Por eso aqui se RECORTA todo lo que no aporta en una
 *   asamblea: P2P, video de terceros, resolucion alta, reacciones,
 *   encuestas, sonidos, niveles de audio, peticiones a terceros...
 *
 * COMO SE APLICA
 *   El entrypoint de jitsi/web (/etc/cont-init.d/10-config) regenera
 *   /config/config.js en cada arranque desde las plantillas y, si existe
 *   /config/custom-config.js, lo CONCATENA AL FINAL:
 *       cat /config/custom-config.js >> /config/config.js
 *   Por eso cada linea es `config.X = ...` (JS plano, sin export): se
 *   ejecuta despues de la plantilla y pisa sus valores. El compose monta
 *   ./web/config:/config, asi que este fichero sobrevive a un
 *   `docker compose up -d --force-recreate web` (no esta en /defaults).
 *
 * VALIDACION
 *   Jitsi IGNORA EN SILENCIO cualquier clave que no conozca. Cada clave de
 *   este fichero se verifico contra jitsi/web:stable-11031: aparece en la
 *   plantilla de config.js o la lee app.bundle.min.js / lib-jitsi-meet.
 *   Comprobar de nuevo (p.ej. al cambiar JITSI_IMAGE_VERSION):
 *       ./scripts/verify-custom-config.sh
 *
 *   DESCARTADA A PROPOSITO: enableLayerSuspension. Venia en el plan pero
 *   NO existe en ningun bundle de stable-11031 (se elimino del cliente):
 *   ponerla no hace nada. No la reintroduzcas.
 *
 * ROLLBACK
 *   Borrar web/config/custom-config.js (y custom-interface_config.js) y
 *   `docker compose up -d --force-recreate web`.
 *
 * Sin secretos: este fichero se sirve en claro en /config.js.
 * ===================================================================== */

// --- Transporte -------------------------------------------------------
// Sin P2P: todo el medio pasa por el JVB. En P2P (2 personas) el medio va
// directo entre navegadores y el bridge no participa; al entrar el tercero
// hay renegociacion (cortes). Ademas la moderacion A/V se aplica en la
// conferencia del JVB. Se toca solo .enabled para no perder el resto del
// objeto que genera la plantilla (codecs). Tambien lo fija ENABLE_P2P=0.
config.p2p.enabled = false;

// --- Entrar silenciado ------------------------------------------------
// startWithAudioMuted / startWithVideoMuted (booleanos): ESTE cliente entra
// con micro y camara apagados. Es el "entra silenciado" del requisito.
config.startWithAudioMuted = true;
config.startWithVideoMuted = true;

// startAudioMuted / startVideoMuted NO son booleanos: son un NUMERO N que
// el cliente envia a Jicofo en la peticion de conferencia (lib-jitsi-meet,
// _createConferenceRequest) y significan "a partir del participante N,
// todos entran silenciados" (la plantilla pone 10; -1 lo desactiva).
// 0 = TODOS entran silenciados, sin excepcion por orden de llegada.
// Verificado en el bundle: NO impiden que el usuario encienda su micro
// despues; quien lo impide es la moderacion A/V de la Fase 2 (Prosody +
// JWT). Por eso NO se ponen a `true`: Jicofo espera un entero y un
// booleano, en el mejor caso, se interpreta como 1 (el primero que entra
// NO quedaria silenciado).
config.startAudioMuted = 0;
config.startVideoMuted = 0;

// Sin pantalla previa: con JWT el nombre viene del token, y la prejoin es
// un paso mas donde el usuario puede encender micro/camara antes de que la
// moderacion este activa. Tambien lo fija ENABLE_PREJOIN_PAGE=0.
config.prejoinConfig.enabled = false;

// --- Video: solo se ve al ponente --------------------------------------
// Cuantos videos remotos recibe cada asistente. El ponente usa como mucho
// 2 (camara + pantalla); 4 deja margen sin que 500 clientes descarguen
// mosaicos enteros.
config.channelLastN = 4;
// Videos en resolucion completa a la vez. Antes era 1: con una camara y
// una pantalla compartida, la pantalla se quedaba sin el hueco "full" y
// se enviaba degradada. Ahora 2 cubre el caso normal (ponente + su
// pantalla) sin que 500 clientes descarguen mosaicos enteros.
config.maxFullResolutionParticipants = 2;
// Captura a 360p: suficiente para la camara del ponente, y lo que de
// verdad se lee (los documentos) va por la pantalla compartida.
config.resolution = 360;
config.constraints = {
    video: {
        height: { ideal: 360, max: 720, min: 180 }
    }
};
// --- Pantalla compartida -------------------------------------------------
// PROBLEMA que habia aqui (corregido 1-Nov-2026): `config.resolution` y
// `config.constraints` se aplicaban TAMBIEN a la pantalla compartida, asi
// que al compartir se enviaba a 360p comprimido y se veia ilegible (el
// texto de un documento, imposible de leer).
//
// Verificado en lib-jitsi-meet: la resolucion de la pantalla sale de
// `desktopSharingResolution`, NO de `resolution`. Si no se define, hereda
// las constraints generales de video y acaba en 360p.
//
// Se sube la pantalla a 1080p conservando los fps bajos: para un
// documento lo que importa es la NITIDEZ (resolucion), no la fluidez.
// A 5-15 fps el aumento de resolucion apenas encarece el ancho de banda.
config.desktopSharingResolution = {
    width: { ideal: 1920, max: 1920 },
    height: { ideal: 1080, max: 1080 }
};
config.desktopSharingFrameRate = { min: 5, max: 15 };

// --- Audio --------------------------------------------------------------
// Voz en mono: el estereo duplica bitrate sin aportar nada en una asamblea.
config.audioQuality = { stereo: false };
// Los indicadores de nivel de audio se calculan por participante en cada
// cliente: con cientos de participantes cuestan CPU en moviles modestos.
config.disableAudioLevels = true;
// Avisos de "tu micro no capta audio" / "tu micro tiene ruido": con todos
// silenciados por moderacion solo generan confusion.
config.enableNoAudioDetection = false;
config.enableNoisyMicDetection = false;

// --- Ruido de interfaz --------------------------------------------------
// Reacciones y encuestas: con 500 personas son spam en pantalla y
// mensajes extra por el canal del bridge.
config.disableReactions = true;
config.disablePolls = true;
// Sonidos: 500 entradas/salidas y cada mensaje de chat sonando en todos
// los clientes hacen la asamblea inaudible.
config.disableJoinLeaveSounds = true;
config.disableIncomingMessageSound = true;

// Notificaciones: `notifications` es una LISTA BLANCA (verificado en el
// bundle: solo se muestra una notificacion si su titleKey/descriptionKey
// esta en la lista). Se dejan SOLO las de moderacion y conexion; se
// eliminan las de "X se ha unido/salido" y los avisos de chat, que a 500
// personas tapan la pantalla.
// OJO: si se quita notify.hostAskedUnmute, el boton "Pedir la palabra"
// del panel dejaria de mostrar el aviso al asistente.
config.notifications = [
    'connection.CONNFAIL',
    'notify.connectionFailed',
    'notify.dataChannelClosed',
    'notify.dataChannelClosedWithAudio',
    'notify.hostAskedUnmute',
    'notify.moderationInEffectTitle',
    'notify.moderationInEffectVideoTitle',
    'notify.moderationInEffectCSTitle',
    'notify.audioUnmuteBlockedTitle',
    'notify.videoUnmuteBlockedTitle',
    'notify.mutedTitle',
    'notify.mutedRemotelyTitle',
    'notify.videoMutedRemotelyTitle',
    'notify.desktopMutedRemotelyTitle',
    'notify.raisedHand',
    'notify.raisedHands',
    'notify.moderator',
    'notify.kickParticipant',
    'notify.suboptimalExperienceTitle'
];

// --- Privacidad y alcance ----------------------------------------------
// Sin peticiones a terceros (gravatar, etc.): privacidad de los
// residentes y menos dependencias externas al cargar.
config.disableThirdPartyRequests = true;
// El acceso es por enlace con JWT generado por el panel: invitar desde
// Jitsi no tiene sentido y confundiria.
config.disableInviteFunctions = true;
// El nombre viene del JWT; si faltara, se pide antes de entrar para que
// el administrador sepa a quien le da la palabra.
config.requireDisplayName = true;
config.defaultLanguage = 'es';
// Sin analitica ni rtcstats.
config.analytics = { disabled: true, rtcstatsEnabled: false };

// --- Barra de herramientas ----------------------------------------------
// En stable-11031 la barra se configura en config.js (`toolbarButtons`);
// interfaceConfig.TOOLBAR_BUTTONS esta obsoleto y el bundle solo lo usa
// si config.toolbarButtons NO es un array. Por eso va aqui y no en
// custom-interface_config.js.
// Valor por defecto del sitio = barra del ADMIN (ya recortada respecto a
// la de Jitsi). El panel admin la fija igual por configOverwrite y el
// proyecto de asistentes la reduce a la suya (ver README, Fase 3). La
// barra es solo UI: el control real de quien habla es la moderacion A/V.
config.toolbarButtons = [
    'microphone',
    'camera',
    'desktop',
    'participants-pane',
    'raisehand',
    'chat',
    'tileview',
    'settings',
    'hangup'
];
