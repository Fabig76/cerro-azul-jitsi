// =====================================================================
// integracion/jitsi-cliente.js — Cerro Azul Jitsi, Fase 6
//
// Cliente reutilizable para embeber la sala de Jitsi
// (meet.bytracking.net) dentro de votacionph.us.
//
// - ES module plano, sin dependencias. Carga el iframe API oficial
//   (https://<dominio>/external_api.js) solo cuando hace falta.
// - El iframe se crea SOLO al llamar a crearSalaJitsi(): llamala desde el
//   manejador de un clic ("Entrar a la asamblea"). En celular, sin un gesto
//   previo del usuario, el navegador bloquea el audio.
// - El JWT lo firma SIEMPRE el servidor (API del panel). Este archivo nunca
//   ve JWT_APP_SECRET ni las API keys: solo el JWT de la persona.
// - Reconexion: ante un error fatal o una salida que el usuario no pidio,
//   avisa "Reconectando", pide un token nuevo y recrea el iframe a los 3 s.
//   Maximo 5 intentos seguidos; si se agotan, avisa y para.
// =====================================================================

/** Barra del administrador (misma lista que TOOLBAR_ADMIN del panel). */
export const BOTONES_ADMIN = Object.freeze([
  'microphone', 'camera', 'desktop', 'participants-pane',
  'raisehand', 'chat', 'tileview', 'settings', 'hangup',
]);

/** Barra del asistente (misma lista que TOOLBAR_ASISTENTE del panel). */
export const BOTONES_ASISTENTE = Object.freeze([
  'microphone', 'raisehand', 'chat', 'settings', 'hangup',
]);

/** Eventos del iframe API que se reenvian a onEvento. */
export const EVENTOS_JITSI = Object.freeze([
  'videoConferenceJoined',
  'videoConferenceLeft',
  'participantJoined',
  'participantLeft',
  'raiseHandUpdated',
  'errorOccurred',
]);

const ESPERA_RECONEXION_MS = 3000;
const MAX_INTENTOS = 5;

/** @type {Map<string, Promise<void>>} */
const cargas = new Map();

/**
 * Carga https://<dominio>/external_api.js una sola vez por dominio.
 * Se puede llamar al cargar la pagina para adelantar la descarga (no crea
 * ningun iframe ni pide permisos).
 *
 * @param {string} dominio  p. ej. 'meet.bytracking.net'
 * @returns {Promise<void>}
 */
export function cargarApiJitsi(dominio) {
  if (typeof window !== 'undefined' && window.JitsiMeetExternalAPI) {
    return Promise.resolve();
  }
  if (cargas.has(dominio)) return cargas.get(dominio);
  const p = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = 'https://' + dominio + '/external_api.js';
    s.async = true;
    s.onload = () => (window.JitsiMeetExternalAPI
      ? resolve()
      : reject(new Error('external_api.js cargo pero no define JitsiMeetExternalAPI')));
    s.onerror = () => {
      cargas.delete(dominio);
      s.remove();
      reject(new Error('No se pudo cargar https://' + dominio + '/external_api.js'));
    };
    document.head.appendChild(s);
  });
  cargas.set(dominio, p);
  return p;
}

/**
 * @typedef {Object} TokenJitsi
 * @property {string} jwt           JWT firmado por el panel
 * @property {string} [roomName]    sala (si cambia respecto a la inicial)
 */

/**
 * @callback OnEvento
 * @param {string} nombre  Nombre del evento: uno de EVENTOS_JITSI, o uno de
 *   los propios del cliente: 'reconectando' ({intento, maximo, causa}),
 *   'reconexionAgotada' ({intentos}), 'colgado' ({}), 'aviso' ({texto}).
 * @param {Object} datos   Datos del evento tal como los entrega Jitsi.
 * @returns {void}
 */

/**
 * @typedef {Object} SalaJitsi
 * @property {() => any} api  Instancia actual de JitsiMeetExternalAPI
 *   (cambia en cada reconexion; null mientras se recrea).
 * @property {Promise<void>} listo  Se resuelve cuando el iframe esta creado
 *   (no cuando la persona entro: para eso, 'videoConferenceJoined').
 * @property {(comando: string, ...args: any[]) => boolean} ejecutar
 *   executeCommand sobre la instancia actual (p. ej. 'askToUnmute', id).
 *   Devuelve false si no hay iframe en ese momento.
 * @property {() => void} dispose  Cuelga, desmonta el iframe y cancela
 *   cualquier reconexion pendiente. Idempotente.
 */

/**
 * Crea la sala de Jitsi dentro de `contenedor`.
 *
 * Llamala desde un gesto del usuario (clic). Ejemplo:
 *
 *   boton.onclick = async () => {
 *     const t = await pedirTokenAMiBackend();
 *     sala = crearSalaJitsi({ dominio: t.domain, roomName: t.roomName,
 *       jwt: t.jwt, soyModerador: t.soyModerador, contenedor,
 *       onEvento: (n, d) => console.log(n, d),
 *       obtenerToken: pedirTokenAMiBackend });
 *   };
 *
 * @param {Object} opciones
 * @param {string} opciones.dominio        'meet.bytracking.net'
 * @param {string} opciones.roomName       sala devuelta por la API del panel
 * @param {string} opciones.jwt            JWT devuelto por la API del panel
 * @param {boolean} [opciones.soyModerador=false]  barra de admin o de asistente
 * @param {HTMLElement} opciones.contenedor  elemento donde va el iframe
 * @param {OnEvento} [opciones.onEvento]   recibe los eventos reenviados
 * @param {() => Promise<TokenJitsi>} [opciones.obtenerToken]  pide un JWT
 *   NUEVO al backend para reconectar. Si falta, se reintenta con el mismo
 *   JWT (sirve mientras no venza: vence al fin de la reunion + 30 min).
 * @param {boolean} [opciones.activarModeracion]  si es moderador, activa la
 *   moderacion de audio y video al entrar (igual que /admin/.../sala).
 *   Por defecto: true si soyModerador.
 * @param {boolean} [opciones.mostrarAvisos=true]  pinta "Reconectando..."
 *   sobre el contenedor. Ponlo en false si la pagina muestra sus avisos.
 * @param {string|number} [opciones.alto='100%']  alto del iframe
 * @returns {SalaJitsi}
 */
export function crearSalaJitsi({
  dominio,
  roomName,
  jwt,
  soyModerador = false,
  contenedor,
  onEvento = () => {},
  obtenerToken,
  activarModeracion = soyModerador,
  mostrarAvisos = true,
  alto = '100%',
}) {
  if (!dominio || !roomName || !jwt || !contenedor) {
    throw new Error('crearSalaJitsi: faltan dominio, roomName, jwt o contenedor');
  }

  let api = null;
  let sala = roomName;
  let token = jwt;
  let intentos = 0;
  let colgo = false;       // el usuario pulso "colgar"
  let destruido = false;   // se llamo dispose()
  let temporizador = null; // reconexion programada
  let avisoEl = null;

  const emitir = (nombre, datos) => {
    try { onEvento(nombre, datos || {}); } catch (e) { console.error('[jitsi] onEvento fallo', e); }
  };

  const aviso = (texto) => {
    emitir('aviso', { texto });
    if (!mostrarAvisos) return;
    if (!texto) { if (avisoEl) { avisoEl.remove(); avisoEl = null; } return; }
    if (!avisoEl) {
      avisoEl = document.createElement('div');
      avisoEl.setAttribute('role', 'status');
      avisoEl.style.cssText = 'position:absolute;top:8px;left:50%;transform:translateX(-50%);'
        + 'background:#1f2937;color:#fff;padding:6px 12px;border-radius:6px;'
        + 'font:14px system-ui,sans-serif;z-index:10;';
      if (getComputedStyle(contenedor).position === 'static') contenedor.style.position = 'relative';
      contenedor.appendChild(avisoEl);
    }
    avisoEl.textContent = texto; // textContent: nunca HTML
  };

  const desmontar = () => {
    if (api) {
      try { api.dispose(); } catch (_) { /* el iframe ya no existe */ }
      api = null;
    }
  };

  const moderar = () => {
    if (!api || !activarModeracion) return;
    // Igual que la pagina /admin/reunion/<id>/sala (Fase 2): en
    // stable-11031 solo existen los tipos 'audio' y 'video'; la pantalla
    // compartida cae bajo 'video'.
    api.executeCommand('toggleModeration', true, 'audio');
    api.executeCommand('toggleModeration', true, 'video');
  };

  const programarReconexion = (causa) => {
    if (destruido || colgo || temporizador) return;
    if (intentos >= MAX_INTENTOS) {
      desmontar();
      aviso('No se pudo reconectar el audio/video. Recarga la pagina. (Puedes seguir votando.)');
      emitir('reconexionAgotada', { intentos });
      return;
    }
    intentos += 1;
    aviso('Reconectando... (intento ' + intentos + ' de ' + MAX_INTENTOS + ')');
    emitir('reconectando', { intento: intentos, maximo: MAX_INTENTOS, causa });
    temporizador = setTimeout(async () => {
      temporizador = null;
      if (destruido || colgo) return;
      desmontar();
      try {
        if (obtenerToken) {
          const t = await obtenerToken();
          if (!t || !t.jwt) throw new Error('obtenerToken no devolvio jwt');
          token = t.jwt;
          if (t.roomName) sala = t.roomName;
        }
        if (destruido || colgo) return;
        await montar();
      } catch (e) {
        console.warn('[jitsi] reconexion fallida', e);
        programarReconexion('error_reconexion');
      }
    }, ESPERA_RECONEXION_MS);
  };

  const montar = async () => {
    await cargarApiJitsi(dominio);
    if (destruido) return;
    const botones = soyModerador ? BOTONES_ADMIN : BOTONES_ASISTENTE;
    api = new window.JitsiMeetExternalAPI(dominio, {
      roomName: sala,
      jwt: token,
      parentNode: contenedor,
      width: '100%',
      height: alto,
      lang: 'es',
      configOverwrite: {
        toolbarButtons: [...botones],
        // Imprescindible en celular: si no, Jitsi muestra "instala la app".
        disableDeepLinking: true,
        deeplinking: { disabled: true },
        prejoinConfig: { enabled: false },
        startWithAudioMuted: true,
        startWithVideoMuted: true,
        lang: 'es',
        defaultLanguage: 'es',
      },
    });
    const actual = api;

    for (const nombre of EVENTOS_JITSI) {
      actual.addListener(nombre, (datos) => {
        if (actual !== api) return; // evento tardio de un iframe ya desmontado
        emitir(nombre, datos);
        if (nombre === 'videoConferenceJoined') {
          intentos = 0;
          aviso('');
          moderar();
        } else if (nombre === 'errorOccurred') {
          // Solo los errores fatales tumban la conferencia; los demas
          // (p. ej. avisos de red que Jitsi recupera solo) se reenvian
          // pero no recrean el iframe.
          if (datos && datos.isFatal) programarReconexion('errorOccurred');
        } else if (nombre === 'videoConferenceLeft') {
          // Al colgar, Jitsi emite videoConferenceLeft y luego readyToClose.
          // Se espera ESPERA_RECONEXION_MS: si llega readyToClose en ese
          // tiempo, la salida fue voluntaria y se cancela la reconexion.
          programarReconexion('videoConferenceLeft');
        }
      });
    }
    // Si el rol de moderador llega despues del join, reintentar.
    actual.addListener('participantRoleChanged', (e) => {
      if (actual === api && e && e.role === 'moderator') moderar();
    });
    actual.addListener('readyToClose', () => {
      if (actual !== api) return;
      colgo = true;
      if (temporizador) { clearTimeout(temporizador); temporizador = null; }
      aviso('');
      desmontar();
      emitir('colgado', {});
    });
  };

  const listo = montar().catch((e) => {
    aviso('No se pudo cargar la sala de audio/video.');
    emitir('errorOccurred', { name: 'carga', message: String(e && e.message || e), isFatal: true });
    throw e;
  });
  // Evita "unhandled rejection" si quien llama no espera a `listo`.
  listo.catch(() => {});

  return {
    api: () => api,
    listo,
    ejecutar(comando, ...args) {
      if (!api) return false;
      api.executeCommand(comando, ...args);
      return true;
    },
    dispose() {
      if (destruido) return;
      destruido = true;
      if (temporizador) { clearTimeout(temporizador); temporizador = null; }
      aviso('');
      desmontar();
    },
  };
}
