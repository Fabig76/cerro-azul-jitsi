/* bajar-manos.js - Boton "Bajar todas las manos" de la sala de moderacion.

   Por que existe: en Jitsi stable-11031 "Lower all hands" solo esta en el
   menu del pie del panel de participantes NATIVO, escondido para el admin.
   Aqui se replica lo que hace ese boton: un mensaje de endpoint
   "lower-hand-message" en broadcast (destinatario ""). Cada cliente lo acepta
   si lo manda un moderador y config.raisedHands.disableLowerHandByModerator
   no esta activo (nuestra config no lo define).

   Por que asi y no con la iframe API: la API externa no tiene comando para
   bajar la mano a otros. Llegamos a APP.conference del iframe porque el panel
   (/admin*) y Jitsi se sirven desde el mismo origen.

   No toca el script congelado de la sala: solo LEE #lista (cuenta las manos
   que el ya pinta) y ESCRIBE en #log con el mismo formato. */
(function () {
  "use strict";

  var MSG = { name: "lower-hand-message" };   // nombre verificado en app.bundle.min.js
  var REINTENTO_MS = 2000;
  var COMPROBAR_MS = 5000;

  var btn = document.getElementById("manos-bajar");
  var estado = document.getElementById("manos-estado");
  var lista = document.getElementById("lista");
  var logEl = document.getElementById("log");
  if (!btn || !estado || !lista) return;

  var enviando = false;

  function log(msg) {
    if (!logEl) return;
    var t = new Date().toLocaleTimeString();
    logEl.textContent = t + "  " + msg + "\n" + logEl.textContent;
  }

  function aviso(txt, tono) {
    estado.textContent = txt;
    if (tono) estado.setAttribute("data-tono", tono); else estado.removeAttribute("data-tono");
  }

  // La fuente de verdad es lo que el admin VE: el script congelado pinta una
  // span.mano por cada participante (sin contar al admin) con la mano arriba.
  function manos() { return lista.querySelectorAll(".mano").length; }

  function refrescar() {
    if (enviando) return;
    var n = manos();
    // Deshabilitado sin manos: el mensaje no haria nada y un boton activo
    // invitaria a pulsarlo "por si acaso" sin saber si ha servido.
    btn.disabled = n === 0;
    if (estado.getAttribute("data-tono") === "error" && n > 0) return;   // no tapar el error
    aviso(n === 0 ? "Nadie tiene la mano levantada."
                  : n === 1 ? "1 mano levantada." : n + " manos levantadas.");
  }

  // Devuelve el modulo APP.conference del iframe o lanza un Error con un
  // texto pensado para el admin.
  function conferencia() {
    var iframe = document.querySelector("#jitsi iframe");
    if (!iframe) throw new Error("la sala de Jitsi aún no se ha cargado");
    var w = iframe.contentWindow, app;
    try { app = w && w.APP; }
    catch (e) { throw new Error("el panel y la sala no están en el mismo dominio (" + e.name + ")"); }
    if (!app || !app.conference) throw new Error("la sala de Jitsi aún no está lista");
    if (typeof app.conference.sendEndpointMessage !== "function") {
      var err = new Error("esta versión de Jitsi no lo permite");
      err.definitivo = true;
      throw err;
    }
    // Los clientes ignoran el mensaje si no viene de un moderador: mejor
    // avisar que enviar algo que nadie va a obedecer.
    try {
      var local = app.store.getState()["features/base/participants"].local;
      if (local && local.role && local.role !== "moderator") {
        var e2 = new Error("no eres moderador en la sala (rol: " + local.role + ")");
        e2.definitivo = true;
        throw e2;
      }
    } catch (e) { if (e.definitivo) throw e; /* sin store: se intenta igual */ }
    return app.conference;
  }

  function enviar() {
    // APP.conference.sendEndpointMessage delega en la JitsiConference; antes
    // de unirse (o sin canal con el bridge) lanza, de ahi el try.
    conferencia().sendEndpointMessage("", MSG);
  }

  function terminar(ok, txt) {
    enviando = false;
    btn.removeAttribute("aria-busy");
    // refrescar() antes del aviso: las manos aun no han bajado y si no
    // pisaria "Orden enviada" con el recuento viejo.
    if (ok) { refrescar(); aviso(txt); } else { aviso(txt, "error"); btn.disabled = manos() === 0; }
  }

  function intentar(reintento) {
    var antes = manos();
    try {
      enviar();
      log("bajar todas las manos: enviado lower-hand-message a todos (" + antes + " manos visibles" +
          (reintento ? ", al reintentar" : "") + ")");
      terminar(true, "Orden enviada.");
      // El mensaje no tiene acuse: comprobamos despues si las manos bajaron
      // para que quede rastro en el registro si algun cliente no obedecio.
      setTimeout(function () {
        var quedan = manos();
        log("bajar todas las manos: " + (quedan === 0 ? "ya no queda ninguna mano levantada"
            : "siguen " + quedan + " manos levantadas " + COMPROBAR_MS / 1000 + " s después"));
        if (quedan > 0) aviso("Siguen " + quedan + " manos levantadas. Puedes bajarlas una a una desde Jitsi.", "error");
      }, COMPROBAR_MS);
    } catch (e) {
      var motivo = (e && e.message) || String(e);
      if (!reintento && !(e && e.definitivo)) {
        // Lo normal es que el iframe aun este cargando: un solo reintento.
        log("bajar todas las manos: fallo (" + motivo + "), reintento en " + REINTENTO_MS / 1000 + " s");
        setTimeout(function () { intentar(true); }, REINTENTO_MS);
        return;
      }
      log("ERROR bajar todas las manos: " + motivo);
      terminar(false, "No se pudo bajar las manos: " + motivo + ".");
    }
  }

  btn.addEventListener("click", function () {
    if (enviando || btn.disabled) return;
    enviando = true;
    btn.disabled = true;
    btn.setAttribute("aria-busy", "true");
    aviso("Bajando las manos…");
    log("bajar todas las manos: pulsado con " + manos() + " manos visibles");
    intentar(false);
  });

  // El script congelado reconstruye #lista entera en cada cambio.
  new MutationObserver(refrescar).observe(lista, { childList: true, subtree: true });
  refrescar();
})();
