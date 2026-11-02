/* bajar-manos.js - "Bajar todas las manos" (y una a una) en la sala de moderacion.

   QUE SE ENVIA: un mensaje {name: "lower-hand-message"} a CADA participante con
   la mano levantada, uno a uno, como mensaje privado XMPP del MUC
   (JitsiConference.sendMessage(objeto, id) -> <json-message>). El cliente de
   cada participante lo recibe como ENDPOINT_MESSAGE_RECEIVED, igual que el
   boton nativo, y baja la mano si el emisor es moderador y
   config.raisedHands.disableLowerHandByModerator no esta activo (nuestra
   config no lo define).

   POR QUE NO VA POR EL VIDEOBRIDGE (lo que hace el boton nativo de Jitsi y lo
   que hacia la primera version de este fichero con
   APP.conference.sendEndpointMessage): medido el 2026-11-02 en produccion con
   dos residentes reales con la mano levantada (sala de prueba propia):
     - to="" (broadcast) y to="<id>" (individual): el JVB 2.3-295 los ENRUTA
       bien (el individual solo le llega a su destinatario; "" es broadcast
       valido: EndpointMessage.isBroadcast() = to.isBlank()), pero los
       reenvia SIN msgPayload: el residente recibe
       {"colibriClass":"EndpointMessage","to":"…","from":"…"} y no sabe que
       hacer. Ninguna mano baja, ni en broadcast ni una a una. (Probable
       causa: jackson-databind 2.18.0 + jackson-module-kotlin 2.17.1 en la
       imagen del JVB y el @JsonAnyGetter de otherFields; no se puede tocar
       sin reiniciar el JVB.)
     - Mensaje privado XMPP al mismo id: la mano de ESE residente baja en
       <1 s y la del otro no; el #lista del admin lo refleja.
   Por eso se envia uno a uno por XMPP: no depende del JVB y solo toca a quien
   tiene la mano levantada.

   DE DONDE SALEN LOS IDS: de features/base/participants.raisedHandsQueue del
   store de Jitsi del iframe (sin el id local). No de la variable `gente` del
   script congelado de la sala porque es privada de su closure (no se puede
   leer sin tocar ese script). Es la MISMA fuente: el evento raiseHandUpdated
   con el que el script congelado pinta [mano] lo emite el iframe a partir de
   este mismo estado, con los mismos ids (id de participante = recurso MUC =
   endpoint id, 8 hex). Ademas se cruza con las span.mano que el admin VE en
   #lista y el #log anota si no coinciden.

   Por que no la iframe API: no tiene comando para bajar la mano a otros.
   Llegamos al iframe porque el panel (/admin*) y Jitsi comparten origen.

   No toca el script congelado: solo LEE #lista y ESCRIBE en #log (mismo
   formato). Los botones individuales se crean en #manos-lista, FUERA de
   #lista (el script congelado la vacia al repintar) y de .gl (engancha todos
   sus <button>). */
(function () {
  "use strict";

  var NOMBRE_MSG = "lower-hand-message";   // verificado en app.bundle.min.js (qU)
  var REINTENTO_MS = 2000;
  var COMPROBAR_MS = 5000;

  var btn = document.getElementById("manos-bajar");
  var estado = document.getElementById("manos-estado");
  var lista = document.getElementById("lista");
  var logEl = document.getElementById("log");
  if (!btn || !estado || !lista) return;

  // Contenedor de los botones individuales, justo despues de la barra.
  var barra = btn.parentNode;
  var listaManos = document.createElement("ul");
  listaManos.id = "manos-lista";
  listaManos.className = "manos-lista";
  listaManos.setAttribute("aria-label", "Manos levantadas");
  listaManos.hidden = true;
  barra.parentNode.insertBefore(listaManos, barra.nextSibling);
  // Estilos aqui y no en page_sala.html para no tocar la plantilla de la
  // sala; solo tokens del sistema de diseno.
  var css = document.createElement("style");
  css.textContent =
    ".manos-lista{list-style:none;margin:0 0 var(--space-3);padding:0;display:flex;flex-direction:column;gap:var(--space-1)}" +
    ".manos-lista li{display:flex;align-items:center;justify-content:space-between;gap:var(--space-2)}" +
    ".manos-lista__nombre{font-size:var(--text-sm);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}";
  document.head.appendChild(css);

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

  // Lo que el admin VE: una span.mano por participante (sin el admin).
  function manosVisibles() { return lista.querySelectorAll(".mano").length; }

  // window.APP del iframe o un Error con texto para el admin.
  function app() {
    var iframe = document.querySelector("#jitsi iframe");
    if (!iframe) throw new Error("la sala de Jitsi aún no se ha cargado");
    var w = iframe.contentWindow, a;
    try { a = w && w.APP; }
    catch (e) { throw new Error("el panel y la sala no están en el mismo dominio (" + e.name + ")"); }
    if (!a || !a.store) throw new Error("la sala de Jitsi aún no está lista");
    return a;
  }

  // [{id, nombre}] de quien tiene la mano levantada, en orden de llegada.
  // Lanza si el iframe no esta listo.
  function conMano() {
    var p = app().store.getState()["features/base/participants"];
    if (!p || !Array.isArray(p.raisedHandsQueue)) throw new Error("la sala de Jitsi aún no está lista");
    var yo = p.local && p.local.id;
    return p.raisedHandsQueue.filter(function (h) { return h && h.id && h.id !== yo; }).map(function (h) {
      var r = p.remote && p.remote.get ? p.remote.get(h.id) : null;
      return { id: h.id, nombre: (r && r.name) || h.id };
    });
  }

  // JitsiConference con sendMessage, comprobando que somos moderador.
  function conferencia() {
    var a = app();
    var st = a.store.getState();
    var conf = st["features/base/conference"] && st["features/base/conference"].conference;
    if (!conf) throw new Error("la sala de Jitsi aún no está lista");
    if (typeof conf.sendMessage !== "function") {
      var err = new Error("esta versión de Jitsi no lo permite");
      err.definitivo = true;
      throw err;
    }
    // Los clientes ignoran el mensaje si no viene de un moderador: mejor
    // avisar que enviar algo que nadie va a obedecer.
    var local = (st["features/base/participants"] || {}).local;
    if (local && local.role && local.role !== "moderator") {
      var e2 = new Error("no eres moderador en la sala (rol: " + local.role + ")");
      e2.definitivo = true;
      throw e2;
    }
    return conf;
  }

  // Envia a cada id por separado; un fallo no corta el bucle.
  // Devuelve {ok: [ids], mal: [[id, motivo]]}. Lanza solo si no hay conferencia.
  function enviar(ids) {
    var conf = conferencia();
    var res = { ok: [], mal: [] };
    ids.forEach(function (id) {
      try {
        // Objeto nuevo cada vez: sendMessage le anade "type" al serializar.
        // Sin tercer argumento (o false) va por XMPP, no por el JVB.
        conf.sendMessage({ name: NOMBRE_MSG }, id);
        res.ok.push(id);
      } catch (e) {
        res.mal.push([id, (e && e.message) || String(e)]);
      }
    });
    return res;
  }

  function texto(n) { return n === 1 ? "1 mano levantada." : n + " manos levantadas."; }

  function pintarIndividuales() {
    var gente = [];
    try { gente = conMano(); } catch (e) { /* iframe cargando: sin lista */ }
    listaManos.textContent = "";
    gente.forEach(function (g) {
      var li = document.createElement("li");
      var nom = document.createElement("span");
      nom.className = "manos-lista__nombre";
      nom.textContent = g.nombre;   // lo escribe el asistente: nunca innerHTML
      var b = document.createElement("button");
      b.type = "button";
      b.className = "btn btn--sm btn--ghost";
      b.textContent = "Bajar la mano";
      b.setAttribute("aria-label", "Bajar la mano de " + g.nombre);
      b.disabled = enviando;
      b.addEventListener("click", function () { pulsar([g], "bajar la mano de " + g.nombre); });
      li.appendChild(nom);
      li.appendChild(b);
      listaManos.appendChild(li);
    });
    listaManos.hidden = gente.length === 0;
  }

  function refrescar() {
    pintarIndividuales();
    if (enviando) return;
    var n = manosVisibles();
    // Deshabilitado sin manos: el mensaje no haria nada y un boton activo
    // invitaria a pulsarlo "por si acaso" sin saber si ha servido.
    btn.disabled = n === 0;
    if (estado.getAttribute("data-tono") === "error" && n > 0) return;   // no tapar el error
    aviso(n === 0 ? "Nadie tiene la mano levantada." : texto(n));
  }

  function terminar(ok, txt, tono) {
    enviando = false;
    btn.removeAttribute("aria-busy");
    // refrescar() antes del aviso: las manos aun no han bajado y si no
    // pisaria el resultado con el recuento viejo.
    refrescar();
    if (ok) aviso(txt, tono); else { aviso(txt, "error"); btn.disabled = manosVisibles() === 0; }
  }

  // objetivo: null = todos los que tengan la mano; [{id, nombre}] = esos.
  function intentar(objetivo, etq, reintento) {
    try {
      var gente = objetivo || conMano();
      var visibles = manosVisibles();
      if (!objetivo && gente.length !== visibles) {
        log(etq + ": AVISO Jitsi tiene " + gente.length + " manos y #lista muestra " + visibles);
      }
      if (!gente.length) {
        log(etq + ": no se envia nada, nadie tiene la mano levantada");
        terminar(true, "Nadie tiene la mano levantada: no se ha enviado nada.");
        return;
      }
      var ids = gente.map(function (g) { return g.id; });
      var r = enviar(ids);
      log(etq + ": " + NOMBRE_MSG + " enviado a " + r.ok.length + " de " + ids.length +
          " [" + r.ok.join(", ") + "]" + (reintento ? " (al reintentar)" : ""));
      r.mal.forEach(function (m) { log("ERROR " + etq + ": fallo el envio a " + m[0] + " (" + m[1] + ")"); });
      if (!r.ok.length) {
        terminar(false, "No se pudo bajar las manos: falló el envío a " + ids.length +
                 (ids.length === 1 ? " persona." : " personas."));
        return;
      }
      terminar(true, r.mal.length
        ? "Orden enviada a " + r.ok.length + " de " + ids.length + ". Falló con " + r.mal.length + "."
        : (r.ok.length === 1 ? "Orden enviada a 1 persona." : "Orden enviada a " + r.ok.length + " personas."),
        r.mal.length ? "error" : null);
      // El mensaje no tiene acuse: comprobamos despues si esas manos bajaron
      // para que quede rastro en el registro si algun cliente no obedecio.
      setTimeout(function () {
        var quedan = [];
        try {
          var ahora = conMano().map(function (g) { return g.id; });
          quedan = r.ok.filter(function (id) { return ahora.indexOf(id) !== -1; });
        } catch (e) { return; }
        log(etq + ": " + (quedan.length === 0 ? "todas las manos enviadas han bajado"
            : "siguen levantadas " + COMPROBAR_MS / 1000 + " s después: [" + quedan.join(", ") + "]"));
        if (quedan.length) {
          aviso((quedan.length === 1 ? "1 mano sigue levantada" : quedan.length + " manos siguen levantadas") +
                ". Prueba con «Bajar la mano» en esa persona.", "error");
        }
      }, COMPROBAR_MS);
    } catch (e) {
      var motivo = (e && e.message) || String(e);
      if (!reintento && !(e && e.definitivo)) {
        // Lo normal es que el iframe aun este cargando: un solo reintento.
        log(etq + ": fallo (" + motivo + "), reintento en " + REINTENTO_MS / 1000 + " s");
        setTimeout(function () { intentar(objetivo, etq, true); }, REINTENTO_MS);
        return;
      }
      log("ERROR " + etq + ": " + motivo);
      terminar(false, "No se pudo bajar las manos: " + motivo + ".");
    }
  }

  function pulsar(objetivo, etq) {
    if (enviando) return;
    enviando = true;
    btn.disabled = true;
    btn.setAttribute("aria-busy", "true");
    listaManos.querySelectorAll("button").forEach(function (b) { b.disabled = true; });
    aviso(objetivo ? "Bajando la mano…" : "Bajando las manos…");
    log(etq + ": pulsado con " + manosVisibles() + " manos visibles");
    intentar(objetivo, etq, false);
  }

  btn.addEventListener("click", function () {
    if (!btn.disabled) pulsar(null, "bajar todas las manos");
  });

  // El script congelado reconstruye #lista entera en cada cambio (incluido
  // raiseHandUpdated): es la señal para repintar.
  new MutationObserver(refrescar).observe(lista, { childList: true, subtree: true });
  refrescar();
})();
