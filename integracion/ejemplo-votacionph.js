// =====================================================================
// integracion/ejemplo-votacionph.js — ejemplo minimo (lado NAVEGADOR)
//
// HTML esperado en la pagina de la asamblea de votacionph.us:
//
//   <button id="entrar-asamblea">Entrar a la asamblea</button>
//   <p id="estado-jitsi" role="status"></p>
//   <div id="jitsi" style="height:70vh" data-reunion="ID_DE_LA_REUNION_EN_EL_PANEL"></div>
//   <script type="module" src="/js/ejemplo-votacionph.js"></script>
//
// Flujo: clic -> POST /api/reuniones/{id}/token al BACKEND DE
// votacionph.us (mismo origen, con la cookie de sesion) -> ese backend
// llama a la API del panel con la API key (ver README) -> devuelve
// {jwt, roomName, soyModerador, domain} -> se crea la sala.
//
// El navegador NUNCA llama directo a meet.urbcerroazul.com/api/...: la
// API key no puede estar en el navegador.
// =====================================================================

import { crearSalaJitsi, cargarApiJitsi } from './jitsi-cliente.js';

const DOMINIO = 'meet.urbcerroazul.com';
const boton = document.getElementById('entrar-asamblea');
const estado = document.getElementById('estado-jitsi');
const contenedor = document.getElementById('jitsi');
// (document.currentScript es null en los ES modules: el id va en el div.)
const REUNION_ID = contenedor.dataset.reunion;

/** @type {import('./jitsi-cliente.js').SalaJitsi | null} */
let sala = null;

// Adelantar la descarga de external_api.js (no crea iframe ni pide permisos).
cargarApiJitsi(DOMINIO).catch(() => { /* se reintenta al hacer clic */ });

/**
 * Pide un token a NUESTRO backend. Quien es la persona (nombre, apto, si es
 * administradora) lo decide el backend con su sesion, no el navegador.
 * @returns {Promise<{jwt:string, roomName:string, soyModerador:boolean, domain?:string}>}
 */
async function pedirToken() {
  const r = await fetch('/api/reuniones/' + encodeURIComponent(REUNION_ID) + '/token', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: '{}',
  });
  if (!r.ok) throw new Error('token HTTP ' + r.status);
  return r.json();
}

/** Avisa al backend de votacionph (asistencia con hora). */
function registrar(tipo, datos) {
  const cuerpo = JSON.stringify({ tipo, datos, hora: new Date().toISOString() });
  // sendBeacon sobrevive al cierre de la pestana; fetch como respaldo.
  if (!navigator.sendBeacon('/api/reuniones/' + REUNION_ID + '/eventos-jitsi', cuerpo)) {
    fetch('/api/reuniones/' + REUNION_ID + '/eventos-jitsi', {
      method: 'POST', credentials: 'same-origin', keepalive: true,
      headers: { 'Content-Type': 'application/json' }, body: cuerpo,
    }).catch(() => {});
  }
}

boton.addEventListener('click', async () => {
  // El iframe se crea DENTRO del clic: en celular el audio necesita el gesto.
  boton.disabled = true;
  estado.textContent = 'Conectando...';
  try {
    const t = await pedirToken();
    sala = crearSalaJitsi({
      dominio: t.domain || DOMINIO,
      roomName: t.roomName,
      jwt: t.jwt,
      soyModerador: t.soyModerador,
      contenedor,
      obtenerToken: pedirToken, // token nuevo en cada reconexion
      onEvento(nombre, datos) {
        switch (nombre) {
          case 'videoConferenceJoined':
            estado.textContent = 'En la asamblea.';
            registrar('entrada', { participantId: datos.id });
            break;
          case 'videoConferenceLeft':
            registrar('salida', { sala: datos.roomName });
            break;
          case 'reconectando':
            estado.textContent = 'Reconectando... (' + datos.intento + '/' + datos.maximo
              + '). Tu voto sigue funcionando.';
            break;
          case 'reconexionAgotada':
            estado.textContent = 'Sin audio/video. Recarga la pagina; puedes seguir votando.';
            boton.disabled = false;
            break;
          case 'colgado':
            estado.textContent = 'Saliste de la sala de audio/video.';
            sala = null;
            boton.disabled = false;
            break;
          // Solo interesa en la vista del administrador (ver README):
          case 'participantJoined':
          case 'participantLeft':
          case 'raiseHandUpdated':
            if (t.soyModerador) console.debug('[jitsi]', nombre, datos);
            break;
          case 'errorOccurred':
            console.warn('[jitsi] error', datos);
            break;
        }
      },
    });
  } catch (e) {
    console.error(e);
    estado.textContent = 'No se pudo entrar a la sala de audio/video. Intenta de nuevo.';
    boton.disabled = false;
  }
});

window.addEventListener('pagehide', () => { if (sala) sala.dispose(); });
