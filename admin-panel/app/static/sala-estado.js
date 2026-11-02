/* sala-estado.js - Como se pintan los botones de la sala de moderacion segun
   el estado REAL de cada participante y de la sala.

   Funciones puras (sin DOM ni Jitsi): reciben el estado y devuelven texto,
   clase y atributos aria. El script de page_sala.html las llama en cada
   repintado de #lista, de modo que el aspecto de un boton se DERIVA siempre
   del estado real y nunca de "lo que se pinto la ultima vez" (pintar()
   reconstruye las filas enteras). Se prueban con node en
   scripts/verificar-panel-local.py (sin navegador).

   DE DONDE SALE CADA DATO (medido en produccion el 2026-11-02 con un admin y
   un residente headless; ver docs/MODERACION-ESTADO-BOTONES.md):
     mic / cam / pantalla  evento participantMuted {id, isMuted, mediaType}
                           ("audio" | "video" | "desktop"). Llega al anadirse
                           la pista del residente y cada vez que cambia.
                           OJO: audioMuteStatusChanged y videoMuteStatusChanged
                           son SOLO del admin (traen {muted}, sin id): no
                           sirven para las filas.
     bloqueado             api.isParticipantForceMuted(id, tipo): true si la
                           moderacion le impide abrir ese medio. Se vuelve a
                           preguntar con moderationParticipantApproved /
                           moderationParticipantRejected / moderationStatusChanged.
     mano                  raiseHandUpdated (timestamp o 0).
     moderacion            moderationStatusChanged {mediaType, enabled} y
                           api.isModerationOn(tipo).
   Valores: true / false / null. null = NO SE SABE y se pinta neutro: no se
   inventa estado. */
(function (raiz) {
  "use strict";

  // Texto visible de cada estado (no se depende solo del color).
  var TXT = {
    audio: { on: "Micro abierto", off: "Micro cerrado", nul: "Micro: sin datos" },
    video: { on: "Cámara encendida", off: "Cámara apagada", nul: "Cámara: sin datos" }
  };

  /* Estado de un medio de un participante -> chip de estado.
     g = gente[id]; tipo = "audio" | "video". */
  function chip(g, tipo) {
    var v = g[tipo === "audio" ? "mic" : "cam"];
    var t = TXT[tipo];
    if (v === true) return { texto: t.on, clase: "badge badge--success" };
    if (v === false) return { texto: t.off, clase: "badge badge--neutral" };
    return { texto: t.nul, clase: "badge badge--neutral est--nul" };
  }

  /* Boton de un medio ("audio" = palabra/micro, "video" = camara).
     g: {name, hand, mic, cam, bloq: {audio, video}}
     mod: moderacion de ese tipo (true/false/null)
     pend: accion en curso para este boton (o null)
     Devuelve {accion, texto, clase, pressed, disabled, ayuda}:
       accion   "silenciar" | "dar" | "quitar" | null (no hace nada)
       pressed  "true" | "false" | null (sin aria-pressed: desconocido)
                "true" = ese medio esta abierto o tiene permiso para abrirlo.
       clase    clases del contrato: "d" (quitar), "ok2" (dar), "" (neutro);
                + "pide" si tiene la mano levantada y se le puede dar la palabra. */
  function boton(g, tipo, mod, pend) {
    var audio = tipo === "audio";
    var abierto = audio ? g.mic : g.cam;
    var bloq = g.bloq ? g.bloq[tipo] : null;
    var nombre = g.name || "";
    var r;
    if (abierto === true) {
      // Abierto: lo que toca es cerrarlo. "Silenciar" = mute + reject, como
      // el menu del propio Jitsi (solo mute deja que lo vuelva a abrir; solo
      // reject le deja hablando: medido).
      r = { accion: "silenciar", texto: audio ? "Silenciar" : "Apagar cámara", clase: "d", pressed: "true",
            disabled: false };
    } else if (abierto === false || abierto === null) {
      if (mod === false) {
        // Moderacion apagada: todos pueden abrir; no hay permiso que dar ni
        // quitar. Con el medio cerrado no hay nada que hacer.
        r = abierto === false
          ? { accion: null, texto: audio ? "Micro cerrado" : "Cámara apagada", clase: "", pressed: "false",
              disabled: true }
          : { accion: "silenciar", texto: audio ? "Silenciar" : "Apagar cámara", clase: "", pressed: null,
              disabled: false };
      } else if (bloq === true) {
        r = { accion: "dar", texto: audio ? "Dar la palabra" : "Habilitar cámara", clase: "ok2", pressed: "false",
              disabled: false };
        if (audio && g.hand) { r.texto = "Dar la palabra (la pidió)"; r.clase = "ok2 pide"; }
      } else if (bloq === false && abierto === false) {
        // Tiene permiso pero aun no ha abierto: se le puede retirar.
        r = { accion: "quitar", texto: audio ? "Quitar la palabra" : "Quitar la cámara", clase: "d", pressed: "true",
              disabled: false };
      } else {
        // No se sabe si esta abierto o si tiene permiso: boton neutro. La
        // accion segura es cerrar (idempotente).
        r = { accion: "silenciar", texto: audio ? "Silenciar" : "Apagar cámara", clase: "", pressed: null,
              disabled: false };
      }
    }
    // aria-label contiene el texto visible (WCAG 2.5.3) + a quien y su estado.
    r.ayuda = r.texto + " · " + nombre + " · " + chip(g, tipo).texto +
      (bloq === true && mod !== false ? ", sin permiso" : bloq === false && mod === true ? ", con permiso" : "");
    // Orden enviada y aun sin confirmar por Jitsi: no se pinta el resultado
    // esperado (seria mentir si falla); se pinta "Enviando…" hasta que llegue
    // el evento real o venza el plazo.
    if (pend) {
      r.busy = true;
      r.disabled = true;
      r.texto = "Enviando…";
      r.ayuda = "Enviando: " + pend + " · " + nombre;
    }
    return r;
  }

  /* Botones globales (.gl). Son interruptores con etiqueta FIJA ("Dar a
     todos", "Activar"...) y aria-pressed: el patron accesible de un boton
     conmutador es no cambiar la etiqueta y cambiar el estado. El estado se
     ve ademas por estilo + marca ✓ (CSS) + una linea de texto por grupo.
     mod = {audio, video} (true/false/null);
     cuenta = {mic: {on, nul}, cam: {on, nul}} de los participantes (sin el admin).
     Devuelve {pressed: {data-cmd: "true"|"false"|null}, palabra, silencio, mod}
     (las tres ultimas, el texto de estado de cada grupo). */
  function globales(mod, cuenta) {
    var a = mod.audio, v = mod.video;
    function par(on, si, no) { return on === null || on === undefined ? null : on ? si : no; }
    // "Activar"/"Desactivar" actuan sobre audio Y video: solo esta pulsado
    // el que coincide con las dos. Mixta (p. ej. tras "Dar a todos") = ninguno.
    var ambas = a === true && v === true ? true : a === false && v === false ? false : null;
    function abiertos(c, uno, varios, ning) {
      var t = c.on === 0 ? ning : c.on === 1 ? uno : c.on + " " + varios;
      return c.nul ? t + " (" + c.nul + " sin datos)" : t;
    }
    function nombre(on) { return on === true ? "activa" : on === false ? "apagada" : "sin datos"; }
    return {
      pressed: {
        // Dar/Quitar a todos = moderacion de AUDIO apagada/encendida.
        "dar-palabra-todos": par(a, "false", "true"),
        "quitar-palabra-todos": par(a, "true", "false"),
        "mod-on": par(ambas, "true", "false"),
        "mod-off": par(ambas, "false", "true"),
        // Silenciar a todos NO es un interruptor: es una orden puntual. Su
        // estado real es cuantos micros/camaras siguen abiertos.
        "mute-all-audio": null,
        "mute-all-video": null
      },
      abiertos: { "mute-all-audio": cuenta.mic.on, "mute-all-video": cuenta.cam.on },
      palabra: a === true ? "Ahora: solo habla quien tenga la palabra."
        : a === false ? "Ahora: todos pueden hablar." : "Ahora: sin datos de la moderación de audio.",
      silencio: "Ahora: " + abiertos(cuenta.mic, "1 micro abierto", "micros abiertos", "ningún micro abierto") +
        " · " + abiertos(cuenta.cam, "1 cámara encendida", "cámaras encendidas", "ninguna cámara encendida") + ".",
      mod: "Ahora: audio " + nombre(a) + " · vídeo " + nombre(v) + "."
    };
  }

  /* Pistas que el admin recibe de un participante, leidas del store de Jitsi
     del iframe (mismo origen: el panel y Jitsi comparten dominio, como en
     bajar-manos.js). Sirve para el estado INICIAL: un residente que entra con
     el micro apagado no tiene pista de audio y Jitsi no emite ningun
     participantMuted de audio hasta que lo abre (medido). Sin pista = el
     admin no recibe nada de ese medio = cerrado.
     Devuelve {audio, video} con true(abierto)/false(cerrado)/null(no se
     pudo leer el store: se queda en "sin datos"). */
  function pistas(iframe, id) {
    var res = { audio: null, video: null };
    try {
      var st = iframe.contentWindow.APP.store.getState();
      var tr = st["features/base/tracks"];
      if (!Array.isArray(tr)) return res;
      res.audio = false; res.video = false;
      tr.forEach(function (t) {
        if (t.local || t.participantId !== id) return;
        if (t.mediaType === "audio") res.audio = !t.muted;
        else if (t.mediaType === "video" && t.videoType !== "desktop") res.video = !t.muted;
      });
    } catch (e) { /* iframe cargando u otro origen: sin datos */ }
    return res;
  }

  raiz.SalaEstado = { chip: chip, boton: boton, globales: globales, pistas: pistas };
})(typeof window !== "undefined" ? window : globalThis);
