/* grabacion.js - Grabacion de la reunion en el PC del administrador.
   Implementa docs/SPEC-GRABACION.md (alternativa A1). Solo se carga en la sala.

   - Se carga ENTRE external_api.js y el script congelado de page_sala.html
     (regla D8): envuelve el constructor JitsiMeetExternalAPI para quedarse con
     la instancia sin cambiar un byte de ese script (§0 H3).
   - Captura ESTA pestana con getDisplayMedia, la recorta a .grab-zona (reunion
     + franja legal), mezcla el audio de la pestana con el micro del admin
     (con puerta sincronizada con su silencio en Jitsi) y graba con
     MediaRecorder en trozos de 5 s.
   - Antes de grabar hace 4 comprobaciones (§3.5): superficie correcta, pista
     de audio presente, bip de prueba captado y micro (informativa).
   - Cada trozo se escribe en OPFS desde grabacion-worker.js: si Chrome se
     cae, al volver a la sala se ofrece recuperar la grabacion. Las copias se
     borran solas a los 7 dias.
   - CERO SUBIDA: aqui no hay fetch, XMLHttpRequest, WebSocket ni sendBeacon.
     El archivo solo sale del navegador hacia la carpeta Descargas del PC.
   - Sin limite de duracion (decision del autor). Si hay comprobacion de
     espacio libre y avisos a la hora de fin prevista. */
(function () {
  "use strict";

  // ---------------------------------------------------------------------
  // 0. Envoltura del constructor de la API de Jitsi (antes que nada)
  // ---------------------------------------------------------------------
  var api = null;
  var micSilenciadoJitsi = true;   // el admin entra con startWithAudioMuted
  var alColgar = null;             // callback mientras se graba

  function enganchar(inst) {
    api = inst;
    inst.addListener("audioMuteStatusChanged", function (e) {
      micSilenciadoJitsi = !!(e && e.muted);
      if (G.puerta) ajustarPuerta();
    });
    inst.addListener("videoConferenceLeft", function () { if (alColgar) alColgar(); });
  }

  var Orig = window.JitsiMeetExternalAPI;
  if (typeof Orig === "function") {
    var Envuelto = function (domain, options) {
      var inst = new Orig(domain, options);
      try { enganchar(inst); } catch (e) { /* la sala sigue funcionando sin grabacion */ }
      return inst;
    };
    Envuelto.prototype = Orig.prototype;
    try { Object.setPrototypeOf(Envuelto, Orig); } catch (e) { /* estaticos: no se usan */ }
    window.JitsiMeetExternalAPI = Envuelto;
  }

  // ---------------------------------------------------------------------
  // 1. Constantes
  // ---------------------------------------------------------------------
  var VERSION = (function () {
    var s = document.currentScript && document.currentScript.src;
    var m = s && s.match(/[?&]v=([^&]+)/);
    return m ? m[1] : "0";
  })();
  var DIR = "grabaciones";
  var LOCK = "ca-grab:";
  var DIAS_COPIA = 7;
  var TROZO_MS = 5000;
  var VIDEO_BPS = 1000000, AUDIO_BPS = 96000;
  var BYTES_HORA = (VIDEO_BPS + AUDIO_BPS) * 3600 / 8;       // ≈ 493 MB
  var MIN_LIBRE_AVISO = 2.5e9;                               // §4.6
  var SILENCIO_DB = -60, SILENCIO_MS = 10 * 60 * 1000;       // §3.6
  // Criterio "audio OK": al menos 3 lecturas >= -45 dBFS en la ventana (no
  // necesariamente seguidas: en Chromium sin tarjeta de sonido el audio
  // capturado llega a rafagas; ver docs/GRABACION-PASO0.md). Ventana de 2 s
  // (el SPEC decia 1,5 s) para tolerar la latencia de la captura.
  var BIP = { hz: 1000, ms: 600, amp: 0.1, ventana: 2000, ok: -45, mudo: -60, lecturas: 3 };
  var REPETIR_FIN_MS = 15 * 60 * 1000;                       // §7 R6
  var FORMATOS = ["video/webm;codecs=vp8,opus", "video/webm;codecs=vp9,opus", "video/webm"];
  var K_SALTAR = "ca-grab-saltar-instrucciones", K_OK = "ca-grab-hubo-grabacion";
  var HANDLE = (function () {
    var a = new Uint8Array(12);
    (window.crypto || {}).getRandomValues ? crypto.getRandomValues(a) : a.forEach(function (_, i) { a[i] = Math.random() * 256; });
    return "ca-sala-" + Array.prototype.map.call(a, function (b) { return ("0" + b.toString(16)).slice(-2); }).join("");
  })();

  var OPCIONES_CAPTURA = {
    video: { displaySurface: "browser", width: { max: 1280 }, height: { max: 720 }, frameRate: { ideal: 15, max: 15 } },
    audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false, suppressLocalAudioPlayback: false },
    preferCurrentTab: true,
    selfBrowserSurface: "include",
    surfaceSwitching: "exclude",
    monitorTypeSurfaces: "exclude",
    systemAudio: "exclude"
  };

  // Capture Handle lo antes posible: permite reconocer que se comparte ESTA pestana.
  try {
    if (navigator.mediaDevices && navigator.mediaDevices.setCaptureHandleConfig) {
      navigator.mediaDevices.setCaptureHandleConfig({ handle: HANDLE, permittedOrigins: ["*"] });
    }
  } catch (e) { /* sin Capture Handle: la deteccion lo marca como no compatible */ }

  // Estado de la grabacion en curso
  var G = {};
  var estado = "inicio";

  // ---------------------------------------------------------------------
  // 2. Utilidades de DOM y formato
  // ---------------------------------------------------------------------
  function $(id) { return document.getElementById(id); }

  function el(tag, props, hijos) {
    var n = document.createElement(tag);
    if (props) Object.keys(props).forEach(function (k) {
      var v = props[k];
      if (v === null || v === undefined || v === false) return;
      if (k === "text") n.textContent = v;
      else if (k === "class") n.className = v;
      else if (k.slice(0, 2) === "on") n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v === true ? "" : v);
    });
    (hijos || []).forEach(function (h) {
      if (h === null || h === undefined || h === false) return;
      n.appendChild(typeof h === "string" ? document.createTextNode(h) : h);
    });
    return n;
  }

  function boton(texto, clase, fn, extra) {
    return el("button", Object.assign({ type: "button", class: "btn " + clase, text: texto, onclick: fn }, extra || {}));
  }

  var SVG_NS = "http://www.w3.org/2000/svg";
  var ICONOS = {
    error: '<circle cx="12" cy="12" r="9"/><path d="m9 9 6 6M15 9l-6 6"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
    warn: '<path d="M12 3 2 20h20L12 3z"/><path d="M12 10v4M12 17h.01"/>',
    success: '<circle cx="12" cy="12" r="9"/><path d="m8 12.5 2.5 2.5L16 9.5"/>'
  };
  function icono(tipo) {
    var s = document.createElementNS(SVG_NS, "svg");
    s.setAttribute("class", "alert__icon"); s.setAttribute("viewBox", "0 0 24 24"); s.setAttribute("aria-hidden", "true");
    s.innerHTML = ICONOS[tipo] || ICONOS.info;   // constante del codigo, nunca datos
    return s;
  }

  /** Aviso .alert--{tipo} (info | warn | error | success). Texto siempre con textContent. */
  function alerta(tipo, titulo, texto, acciones, extra) {
    var cuerpo = el("div", { class: "alert__body" }, [
      el("p", { class: "alert__title", text: titulo }),
      texto ? el("p", { text: texto }) : null
    ].concat(extra || []));
    if (acciones && acciones.length) cuerpo.appendChild(el("div", { class: "grab__acciones" }, acciones));
    return el("div", { class: "alert alert--" + tipo, role: tipo === "error" ? "alert" : null }, [icono(tipo), cuerpo]);
  }

  function pintar(nodos) {
    var c = $("grab-cuerpo");
    if (!c) return;
    c.textContent = "";
    nodos.forEach(function (n) { if (n) c.appendChild(n); });
  }

  var LOC = "es-CO";
  function num1(x) { return x.toLocaleString(LOC, { minimumFractionDigits: 1, maximumFractionDigits: 1 }); }
  function fmtBytes(b) {
    if (b < 1e6) return Math.round(b / 1e3) + " KB";
    if (b < 1e9) return num1(b / 1e6) + " MB";
    return (b / 1e9).toLocaleString(LOC, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " GB";
  }
  function dos(n) { return ("0" + n).slice(-2); }
  function fmtReloj(ms) {
    var s = Math.max(0, Math.floor(ms / 1000));
    return dos(Math.floor(s / 3600)) + ":" + dos(Math.floor(s / 60) % 60) + ":" + dos(s % 60);
  }
  function fmtDur(ms) {
    var m = Math.round(Math.max(0, ms) / 60000);
    if (m < 1) return Math.max(0, Math.round(ms / 1000)) + " s";
    if (m < 60) return m + " min";
    return Math.floor(m / 60) + " h " + (m % 60) + " min";
  }
  function dB(rms) { return rms > 0 ? 20 * Math.log10(rms) : -Infinity; }

  var tarjeta = function () { return $("grab"); };
  function tzMin() { var t = tarjeta(); return parseInt((t && t.getAttribute("data-tz-min")) || "-300", 10); }
  /** Fecha en la zona horaria del panel (offset fijo, como fecha_col() de app.py). */
  function enZona(ms) { return new Date(ms + tzMin() * 60000); }
  var MESES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];
  function fmtFecha(ms) {
    var d = enZona(ms), h = d.getUTCHours();
    return d.getUTCDate() + " " + MESES[d.getUTCMonth()] + " · " + ((h % 12) || 12) + ":" + dos(d.getUTCMinutes())
      + " " + (h < 12 ? "a. m." : "p. m.");
  }

  /** Registro tecnico de la sala (#log), mismo formato que el script congelado. */
  function log(msg) {
    var l = $("log");
    if (!l) return;
    l.textContent = new Date().toLocaleTimeString() + "  [grabación] " + msg + "\n" + l.textContent;
  }

  function titulo() {
    var h = document.querySelector(".salahead__title");
    return ((h && h.textContent) || "").trim();
  }

  /** §3.8: Asamblea-<titulo-slug>-<YYYY-MM-DD>-<HHMM>.webm */
  function nombreArchivo(ms, ext) {
    var s = titulo().normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase()
      .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60).replace(/-+$/, "");
    s = s.replace(/^asamblea(-|$)/, "");
    if (!s) s = "reunion";
    var d = enZona(ms);
    return "Asamblea-" + s + "-" + d.getUTCFullYear() + "-" + dos(d.getUTCMonth() + 1) + "-" + dos(d.getUTCDate())
      + "-" + dos(d.getUTCHours()) + dos(d.getUTCMinutes()) + "." + ext;
  }

  function textoAviso() { var t = $("grab-aviso-texto"); return t ? t.textContent.trim() : ""; }
  function responsable() { var t = $("grab-aviso-resp"); return t ? t.textContent.trim() : ""; }
  /** " Responsable: X." sin doble punto si X ya acaba en punto. */
  function conPunto(t) { return /[.!?]$/.test(t) ? t : t + "."; }

  function jitsi(cmd) {
    if (!api) return;
    try { api.executeCommand.apply(api, arguments); } catch (e) { log(cmd + " falló: " + e.message); }
  }

  function conTiempo(p, ms) {
    return Promise.race([p, new Promise(function (_, rej) { setTimeout(function () { rej(new Error("tiempo agotado")); }, ms); })]);
  }

  // Confirmacion con el <dialog id="grab-conf"> (o confirm() si no hay <dialog>)
  function confirmar(tituloTxt, texto, okTxt, peligro) {
    var d = $("grab-conf");
    if (!d || typeof d.showModal !== "function") return Promise.resolve(window.confirm(tituloTxt + "\n\n" + texto));
    $("grab-conf-t").textContent = tituloTxt;
    $("grab-conf-d").textContent = texto;
    var si = $("grab-conf-si");
    si.textContent = okTxt;
    si.className = "btn " + (peligro ? "btn--danger" : "btn--primary");
    d.returnValue = "";
    d.showModal();
    $("grab-conf-no").focus();
    return new Promise(function (res) {
      d.addEventListener("close", function () { res(d.returnValue === "ok"); }, { once: true });
    });
  }

  // ---------------------------------------------------------------------
  // 3. Deteccion por capacidades (§3.1)
  // ---------------------------------------------------------------------
  function elegirFormato() {
    if (!window.MediaRecorder || !MediaRecorder.isTypeSupported) return null;
    for (var i = 0; i < FORMATOS.length; i++) if (MediaRecorder.isTypeSupported(FORMATOS[i])) return FORMATOS[i];
    return null;
  }

  function detectar() {
    var md = navigator.mediaDevices;
    var mm = window.matchMedia ? function (q) { return matchMedia(q).matches; } : function () { return false; };
    var movil = (navigator.userAgentData && navigator.userAgentData.mobile === true)
      || (mm("(pointer: coarse)") && !mm("(any-pointer: fine)"))
      || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
    if (movil || !md || !md.getDisplayMedia) return "movil";
    if (typeof window.CropTarget === "undefined" || !window.MediaStreamTrack
        || !MediaStreamTrack.prototype.getCaptureHandle) return "navegador";
    if (!elegirFormato()) return "formato";
    return "ok";
  }

  function hayOPFS() { return !!(navigator.storage && navigator.storage.getDirectory && window.Worker); }

  // ---------------------------------------------------------------------
  // 4. Estados de la tarjeta antes de grabar (M1)
  // ---------------------------------------------------------------------
  var deteccion = "ok";
  var avisoPrevio = null;   // aviso neutro que se muestra una vez en "listo"

  function pintarListo() {
    estado = "listo";
    if (deteccion === "movil") {
      pintar([
        alerta("warn", "La reunión NO se está grabando.",
          "La grabación solo funciona en un computador con Google Chrome (macOS o Windows). Desde este dispositivo puedes moderar."),
        boton("Grabar esta reunión", "btn--secondary btn--block", null, { disabled: true })
      ]);
      return;
    }
    if (deteccion === "navegador") {
      pintar([
        alerta("info", "Para grabar, abre esta página en Google Chrome.",
          "Este navegador no puede grabar el sonido de la reunión."),
        boton("Grabar esta reunión", "btn--secondary btn--block", null, { disabled: true })
      ]);
      return;
    }
    if (deteccion === "formato") {
      pintar([
        alerta("warn", "Este navegador no puede crear el archivo de grabación.", "Actualiza Google Chrome a la última versión."),
        boton("Grabar esta reunión", "btn--secondary btn--block", null, { disabled: true })
      ]);
      return;
    }
    var hint = el("p", { class: "field__hint", id: "grab-espacio", text: "≈ " + num1(BYTES_HORA / 1e9) + " GB por hora" });
    var nodos = [
      avisoPrevio,
      recuperacionPendiente(),
      el("p", { class: "grab__intro", text: "La grabación se guarda en este computador. No se sube al servidor." }),
      boton("● Grabar esta reunión", "btn--primary btn--block", clicGrabar, { id: "grab-btn" }),
      hint,
      el("div", { id: "grab-espacio-aviso" })
    ];
    avisoPrevio = null;
    pintar(nodos);
    espacioLibre().then(function (libre) {
      if (libre === null || estado !== "listo") return;
      var h = libre / BYTES_HORA;
      hint.textContent = "≈ " + num1(BYTES_HORA / 1e9) + " GB por hora · espacio libre ≈ "
        + (h >= 100 ? Math.round(h) : num1(h)) + " h";
      if (libre < MIN_LIBRE_AVISO) {
        var a = $("grab-espacio-aviso");
        if (a) a.appendChild(alerta("warn", "Queda poco espacio para la grabación (≈ " + fmtDur(h * 3600e3) + ").",
          "Libera espacio en el disco antes de una reunión larga."));
      }
    });
  }

  function espacioLibre() {
    if (!navigator.storage || !navigator.storage.estimate) return Promise.resolve(null);
    return navigator.storage.estimate().then(function (e) {
      return (e.quota || 0) - (e.usage || 0);
    }, function () { return null; });
  }

  function clicGrabar() {
    var saltar = false;
    try { saltar = localStorage.getItem(K_SALTAR) === "1"; } catch (e) { /* sin localStorage */ }
    var d = $("grab-dlg");
    if (saltar || !d || typeof d.showModal !== "function") { iniciarCaptura(); return; }
    $("grab-dlg-tab").textContent = document.title;
    var hubo = false;
    try { hubo = localStorage.getItem(K_OK) === "1"; } catch (e) { /* idem */ }
    $("grab-dlg-saltar-l").hidden = !hubo;
    $("grab-dlg-saltar").checked = false;
    d.returnValue = "";
    d.showModal();
    $("grab-dlg-ok").focus();
  }

  function prepararDialogo() {
    var ok = $("grab-dlg-ok");
    if (!ok) return;
    // getDisplayMedia exige un gesto del usuario: se llama DENTRO del clic en
    // "Continuar", no en el evento 'close' del dialogo.
    ok.addEventListener("click", function (ev) {
      ev.preventDefault();
      try { if ($("grab-dlg-saltar").checked) localStorage.setItem(K_SALTAR, "1"); } catch (e) { /* idem */ }
      $("grab-dlg").close("ok");
      iniciarCaptura();
    });
  }

  // ---------------------------------------------------------------------
  // 5. Captura y comprobaciones (§3.5)
  // ---------------------------------------------------------------------
  var CHECKS = [["sup", "Pestaña correcta"], ["aud", "Audio de la pestaña"], ["bip", "Sonido (bip de prueba)"], ["mic", "Tu micrófono"]];

  function pintarComprobando() {
    estado = "comprobando";
    pintar([
      el("p", { class: "grab__intro", text: "Comprobando… Si Chrome pregunta qué compartir, elige esta pestaña con el audio marcado." }),
      el("ul", { class: "grab__checks", id: "grab-checks" }, CHECKS.map(function (c) {
        return el("li", { class: "grab__check", "data-k": c[0], text: c[1] });
      })),
      el("span", { class: "grab-vu", id: "grab-vu-bip", "aria-hidden": "true" }, [el("span"), el("span"), el("span"), el("span"), el("span")])
    ]);
  }

  function marcar(k, st, texto) {
    var li = document.querySelector('#grab-checks [data-k="' + k + '"]');
    if (!li) return;
    li.setAttribute("data-st", st);
    if (texto) li.textContent = texto;
  }

  function pararPistas(stream) {
    if (stream) stream.getTracks().forEach(function (t) { try { t.onended = null; t.stop(); } catch (e) { /* ya parada */ } });
  }

  function pintarErrorCaptura(tituloTxt, texto, extra) {
    estado = "error";
    pintar([
      alerta("error", tituloTxt, texto, [
        boton("Volver a intentarlo", "btn--primary", function () { cancelarCaptura(); iniciarCaptura(); }),
        boton("Cancelar", "btn--secondary", function () { cancelarCaptura(); pintarListo(); })
      ]),
      extra || null
    ]);
  }

  function cancelarCaptura() {
    pararPistas(G.pantalla); G.pantalla = null;
    pararPistas(G.micStream); G.micStream = null;
  }

  function audioCtx() {
    if (!G.ctx || G.ctx.state === "closed") G.ctx = new (window.AudioContext || window.webkitAudioContext)();
    if (G.ctx.state === "suspended") G.ctx.resume();
    return G.ctx;
  }

  async function iniciarCaptura() {
    if (estado === "comprobando" || estado === "grabando" || estado === "guardando") return;
    pintarComprobando();
    var ctx = audioCtx();   // dentro del gesto: evita que la politica de autoplay lo suspenda
    var stream;
    try {
      stream = await navigator.mediaDevices.getDisplayMedia(OPCIONES_CAPTURA);
    } catch (e) {
      log("getDisplayMedia: " + e.name + " " + e.message);
      if (e.name === "NotAllowedError" && /system/i.test(e.message || "")) {
        pintarErrorCaptura("Chrome no tiene permiso para grabar la pantalla.",
          "En macOS: Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema → activa Google Chrome. "
          + "Después cierra Chrome del todo y vuelve a abrirlo. Hazlo antes de la reunión, no durante.");
      } else if (e.name === "NotAllowedError" || e.name === "AbortError") {
        avisoPrevio = alerta("info", "No se compartió nada.", "La grabación no empezó. Pulsa «Grabar esta reunión» para intentarlo otra vez.");
        pintarListo();
      } else {
        pintarErrorCaptura("Chrome no pudo capturar la pestaña.", "Error técnico: " + e.name + ". Recarga la página e inténtalo otra vez.");
      }
      return;
    }
    G.pantalla = stream;
    var video = stream.getVideoTracks()[0];
    var audios = stream.getAudioTracks();
    // Si el admin pulsa "Dejar de compartir" mientras comprobamos
    video.onended = function () { if (estado === "comprobando") { cancelarCaptura(); pintarListo(); } };

    // a) Superficie: esta pestana (displaySurface + Capture Handle; cropTo como desempate)
    marcar("sup", "run");
    var sup = await comprobarSuperficie(video);
    if (sup === "otra") {
      marcar("sup", "err");
      pintarErrorCaptura("Elegiste otra ventana o pestaña.", "Hay que compartir ESTA pestaña («" + document.title + "»).");
      return;
    }
    marcar("sup", "ok");
    G.recorteFallo = (sup === "sin-recorte");

    // b) Pista de audio: determinista. Sin casilla marcada no hay pista.
    marcar("aud", "run");
    if (!audios.length) {
      marcar("aud", "err");
      pintarErrorCaptura("No marcaste «Compartir audio de la pestaña».",
        "La grabación no tendría voz. Vuelve a intentarlo y deja marcada esa casilla en el diálogo de Chrome.");
      return;
    }
    marcar("aud", "ok");

    // c) Bip de prueba: se reproduce en la pestana y se mide en la pista capturada
    marcar("bip", "run");
    var bip = await bipDePrueba(ctx, audios[0]);
    log("bip de prueba: máx " + (isFinite(bip.max) ? bip.max.toFixed(1) : "-inf") + " dBFS, " + bip.altas
      + " lecturas ≥ " + BIP.ok + " dBFS (" + bip.seguidas + " seguidas)" + " → " + bip.res + " · serie dBFS cada 50 ms: " + bip.serie);
    G.audioBajo = false;
    if (bip.res === "mudo") {
      marcar("bip", "err");
      pintarErrorCaptura("La grabación no capta el sonido de la reunión.",
        "¿Está silenciada la pestaña o el volumen de Chrome? Clic derecho en la pestaña → «Activar sonido del sitio», y vuelve a intentarlo.",
        el("button", { type: "button", class: "grab__enlace", text: "Grabar sin sonido", onclick: function () {
          confirmar("¿Grabar sin sonido?", "La grabación no tendrá voz. Solo sirve si únicamente necesitas la imagen.", "Grabar sin sonido", true)
            .then(function (si) { if (si && G.pantalla) seguirConMicro(true); });
        } }));
      return;
    }
    if (bip.res === "bajo") { marcar("bip", "warn", "Sonido muy bajo"); G.audioBajo = true; }
    else marcar("bip", "ok");

    seguirConMicro(false);
  }

  async function seguirConMicro(sinSonido) {
    estado = "comprobando";
    if (!$("grab-checks")) { pintarComprobando(); ["sup", "aud"].forEach(function (k) { marcar(k, "ok"); }); marcar("bip", "err"); }
    // d) Micro del admin (informativo)
    marcar("mic", "run");
    G.micStream = await abrirMicro();
    marcar("mic", G.micStream ? "ok" : "warn", G.micStream ? null : "Sin micrófono");
    G.sinSonido = sinSonido;
    if (!G.pantalla || G.pantalla.getVideoTracks()[0].readyState !== "live") { cancelarCaptura(); pintarListo(); return; }
    empezar();
  }

  async function comprobarSuperficie(video) {
    var s = video.getSettings ? video.getSettings() : {};
    if (s.displaySurface && s.displaySurface !== "browser") return "otra";
    var h = null;
    try { h = video.getCaptureHandle && video.getCaptureHandle(); } catch (e) { h = null; }
    if (h && h.handle && h.handle !== HANDLE) return "otra";           // otra pestana (otra carga de la sala, u otra web)
    // Recorte a la zona de Jitsi (§4.1). cropTo solo funciona cuando la
    // pestana se captura a si misma: si falla y ademas no hay handle propio,
    // no podemos asegurar que sea esta pestana.
    var recorteOk = false;
    try {
      var objetivo = await CropTarget.fromElement($("grab-zona"));
      await video.cropTo(objetivo);
      recorteOk = true;
    } catch (e) {
      log("cropTo falló: " + e.name + " " + e.message);
    }
    var propia = !!(h && h.handle === HANDLE);
    if (!propia && !recorteOk) return "otra";
    if (!propia) log("Capture Handle vacío; se acepta porque el recorte (solo posible en esta pestaña) funcionó");
    return recorteOk ? "ok" : "sin-recorte";
  }

  function rms(an, buf) {
    an.getFloatTimeDomainData(buf);
    var s = 0;
    for (var i = 0; i < buf.length; i++) s += buf[i] * buf[i];
    return Math.sqrt(s / buf.length);
  }

  function vu(id, db) {
    var c = $(id);
    if (!c) return;
    // 5 barras entre -60 y -10 dBFS
    var n = isFinite(db) ? Math.max(0, Math.min(5, Math.ceil((db + 60) / 10))) : 0;
    Array.prototype.forEach.call(c.children, function (b, i) {
      if (i < n) b.setAttribute("data-on", ""); else b.removeAttribute("data-on");
    });
  }

  /** Bip de 1 kHz a -20 dBFS durante 600 ms por la salida de la pestana; mide la pista capturada. */
  function bipDePrueba(ctx, pista) {
    return new Promise(function (resolve) {
      var src = ctx.createMediaStreamSource(new MediaStream([pista]));
      var an = ctx.createAnalyser(); an.fftSize = 2048;
      var cero = ctx.createGain(); cero.gain.value = 0;   // no duplicar el sonido (§4.3)
      src.connect(an); an.connect(cero); cero.connect(ctx.destination);
      var osc = ctx.createOscillator(); osc.frequency.value = BIP.hz;
      var g = ctx.createGain();
      var t0 = ctx.currentTime + 0.05, t1 = t0 + BIP.ms / 1000;
      g.gain.setValueAtTime(0, t0);
      g.gain.linearRampToValueAtTime(BIP.amp, t0 + 0.01);
      g.gain.setValueAtTime(BIP.amp, t1 - 0.01);
      g.gain.linearRampToValueAtTime(0, t1);
      osc.connect(g); g.connect(ctx.destination);
      osc.start(t0); osc.stop(t1 + 0.02);
      var buf = new Float32Array(an.fftSize), max = -Infinity, seguidas = 0, mejor = 0, inicio = Date.now(), serie = [], altas = 0;
      var iv = setInterval(function () {
        var d = dB(rms(an, buf));
        serie.push(isFinite(d) ? Math.round(d) : "-");
        vu("grab-vu-bip", d);
        if (d > max) max = d;
        if (d >= BIP.ok) { altas += 1; seguidas += 1; } else seguidas = 0;
        if (seguidas > mejor) mejor = seguidas;
        if (Date.now() - inicio >= BIP.ventana) {
          clearInterval(iv);
          try { src.disconnect(); an.disconnect(); cero.disconnect(); g.disconnect(); } catch (e) { /* ya desconectado */ }
          vu("grab-vu-bip", -Infinity);
          resolve({ max: max, serie: serie.join(" "), seguidas: mejor, altas: altas,
            res: altas >= BIP.lecturas ? "ok" : (max < BIP.mudo ? "mudo" : "bajo") });
        }
      }, 50);
    });
  }

  /** Micro: el MISMO dispositivo que usa Jitsi, con cancelacion de eco. */
  async function abrirMicro(deviceId) {
    if (!api) { log("sin acceso a la API de Jitsi: no se mezcla el micrófono (no se sabría si está silenciado)"); return null; }
    if (deviceId === undefined) deviceId = await idMicroJitsi();
    var base = { echoCancellation: true, noiseSuppression: true, autoGainControl: true };
    try {
      return await navigator.mediaDevices.getUserMedia({
        audio: Object.assign({}, base, deviceId ? { deviceId: { exact: deviceId } } : {}) });
    } catch (e) {
      log("micrófono: " + e.name + " " + e.message);
      if (deviceId && (e.name === "OverconstrainedError" || e.name === "NotFoundError")) {
        try { return await navigator.mediaDevices.getUserMedia({ audio: base }); } catch (e2) { log("micrófono (por defecto): " + e2.name); }
      }
      return null;
    }
  }

  async function idMicroJitsi() {
    if (!api || !api.getCurrentDevices) return "";
    try {
      var d = await conTiempo(api.getCurrentDevices(), 2000);
      return (d && d.audioInput && d.audioInput.deviceId) || "";
    } catch (e) { return ""; }
  }

  // ---------------------------------------------------------------------
  // 6. Grabacion (§4.2, §4.3)
  // ---------------------------------------------------------------------
  function ajustarPuerta() {
    if (!G.puerta) return;
    G.puerta.gain.setTargetAtTime(micSilenciadoJitsi ? 0 : 1, G.ctx.currentTime, 0.02);
    var t = $("grab-mic");
    if (t) t.textContent = !G.micSrc ? "sin acceso (tu voz no se graba)"
      : micSilenciadoJitsi ? "silenciado en Jitsi (no se graba)" : "en la grabación";
  }

  function conectarMicro(stream) {
    if (G.micSrc) { try { G.micSrc.disconnect(); } catch (e) { /* idem */ } G.micSrc = null; }
    if (!stream) { ajustarPuerta(); return; }
    G.micSrc = G.ctx.createMediaStreamSource(stream);
    G.micSrc.connect(G.puerta);
    ajustarPuerta();
  }

  async function empezar() {
    var ctx = audioCtx();
    var video = G.pantalla.getVideoTracks()[0];
    var audioTab = G.pantalla.getAudioTracks()[0];
    // La franja legal se muestra ANTES de arrancar el grabador: el WebM fija en
    // su cabecera el tamano del primer fotograma, y si la franja apareciera
    // despues el video cambiaria de resolucion a mitad (algunos reproductores
    // lo llevan mal). Mientras se abre el archivo, el recorte ya la incluye.
    $("grab-aviso").hidden = false;
    G.mime = elegirFormato();
    G.inicio = Date.now();
    G.nombre = await nombreLibre(nombreArchivo(G.inicio, "webm"));
    G.bytes = 0; G.muestras = []; G.memoria = null; G.errorDisco = false;
    G.ultimoSonido = Date.now(); G.proximoAvisoFin = 0; G.ultimoTrozo = Date.now() + TROZO_MS;

    // Grafo: pestana + micro (con puerta) -> mezcla -> destino (pista grabada)
    //        mezcla -> analizador -> ganancia 0 -> altavoces (nunca suena: §4.3)
    G.mezcla = ctx.createGain();
    G.destino = ctx.createMediaStreamDestination();
    G.mezcla.connect(G.destino);
    G.tabSrc = ctx.createMediaStreamSource(new MediaStream([audioTab]));
    G.tabSrc.connect(G.mezcla);
    G.puerta = ctx.createGain(); G.puerta.gain.value = 0;
    G.puerta.connect(G.mezcla);
    G.analizador = ctx.createAnalyser(); G.analizador.fftSize = 2048;
    G.cero = ctx.createGain(); G.cero.gain.value = 0;
    G.mezcla.connect(G.analizador); G.analizador.connect(G.cero); G.cero.connect(ctx.destination);
    conectarMicro(G.micStream);
    if (api && api.isAudioMuted) {
      api.isAudioMuted().then(function (m) { micSilenciadoJitsi = !!m; ajustarPuerta(); }, function () { /* se queda cerrada */ });
    }
    G.idMicro = G.micStream ? ((G.micStream.getAudioTracks()[0].getSettings() || {}).deviceId || "") : "";

    // Guardado incremental en OPFS (§4.6); si falla, memoria + aviso
    if (hayOPFS()) {
      try {
        if (navigator.storage.persist) navigator.storage.persist().catch(function () {});
        G.worker = new Worker("/admin/static/grabacion-worker.js?v=" + encodeURIComponent(VERSION));
        prepararWorker(G.worker);
        await conTiempo(rpc("abrir", { nombre: G.nombre, meta: { titulo: titulo(), inicio: G.inicio, mime: G.mime } }), 5000);
      } catch (e) {
        log("OPFS no disponible: " + e.message);
        if (G.worker) G.worker.terminate();
        G.worker = null;
      }
    }
    if (!G.worker) G.memoria = [];

    // Cerrojo: otra pestana no debe ofrecer "recuperar" esta grabacion mientras sigue viva
    if (navigator.locks && navigator.locks.request) {
      navigator.locks.request(LOCK + G.nombre, function () {
        return new Promise(function (res) { G.soltarCerrojo = res; });
      }).catch(function () {});
    }

    await new Promise(function (r) { setTimeout(r, 300); });   // un par de fotogramas con la franja
    var pistas = [video, G.destino.stream.getAudioTracks()[0]];
    try {
      G.rec = new MediaRecorder(new MediaStream(pistas), { mimeType: G.mime, videoBitsPerSecond: VIDEO_BPS, audioBitsPerSecond: AUDIO_BPS });
    } catch (e) {
      log("MediaRecorder: " + e.name + " " + e.message);
      limpiar();
      pintarErrorCaptura("No se pudo iniciar la grabación.", "Error técnico: " + e.name + ".");
      return;
    }
    G.rec.ondataavailable = function (ev) { if (ev.data && ev.data.size) escribir(ev.data); };
    G.rec.onerror = function (ev) {
      var e = ev.error || {};
      log("MediaRecorder error: " + e.name + " " + e.message);
      detener("error");
    };
    G.rec.onstop = function () {
      // Si Chrome para el grabador por su cuenta (p. ej. terminan las pistas)
      if (estado === "grabando") { estado = "guardando"; G.motivo = G.motivo || "compartir"; G.finMs = Date.now(); }
      finalizar();
    };
    G.rec.start(TROZO_MS);

    estado = "grabando";
    log("grabando " + G.nombre + " (" + G.mime + ", " + (video.getSettings().width || "?") + "x" + (video.getSettings().height || "?")
      + (G.recorteFallo ? ", SIN recorte" : ", recortado a la reunión") + ", micro " + (G.micStream ? "sí" : "no")
      + ", guardado " + (G.worker ? "OPFS" : "memoria") + ")");

    // Avisos legales (§6): franja grabada (ya visible), subject para todos, chat
    document.querySelector(".sala").classList.add("sala--grabando");
    $("grab-rec").hidden = false;
    var ey = document.querySelector(".salahead__live .eyebrow");
    if (ey) { G.eyebrowTxt = ey.textContent; ey.textContent = "Grabando · " + G.eyebrowTxt; }
    var t = titulo(), subj = "● GRABANDO · " + t;
    jitsi("subject", subj.length > 60 ? subj.slice(0, 59) + "…" : subj);
    jitsi("sendChatMessage", textoAviso() + (responsable() ? " Responsable: " + conPunto(responsable()) : ""));

    // Robustez (§3.9, §4.6)
    alColgar = function () { log("salió de la reunión en Jitsi"); detener("colgar"); };
    video.onended = function () { detener("compartir"); };
    audioTab.onended = function () { detener("compartir"); };
    window.addEventListener("beforeunload", alSalir);
    pedirWakeLock();
    document.addEventListener("visibilitychange", alCambiarVisibilidad);
    vigilarZona();

    pintarGrabando();
    G.ivReloj = setInterval(tic, 1000);
    G.ivVu = setInterval(medir, 150);
    G.ivEspacio = setInterval(comprobarEspacio, 60000);
    G.ivMicro = setInterval(vigilarMicro, 10000);
  }

  async function nombreLibre(nombre) {
    if (!hayOPFS()) return nombre;
    try {
      var dir = await (await navigator.storage.getDirectory()).getDirectoryHandle(DIR, { create: true });
      var base = nombre.replace(/\.webm$/, ""), n = 1, cand = nombre;
      for (;;) {
        try { await dir.getFileHandle(cand); } catch (e) { return cand; }
        n += 1; cand = base + "-" + n + ".webm";
      }
    } catch (e) { return nombre; }
  }

  // RPC con el worker
  var rpcId = 0, pendientes = {};
  function prepararWorker(w) {
    w.onmessage = function (ev) {
      var r = ev.data || {}, p = pendientes[r.id];
      delete pendientes[r.id];
      if (p) { if (r.ok) p.res(r); else p.rej(new Error(r.error || "error")); }
    };
    w.onerror = function (ev) {
      Object.keys(pendientes).forEach(function (k) { pendientes[k].rej(new Error(ev.message || "worker")); delete pendientes[k]; });
    };
  }
  function rpc(tipo, extra) {
    return new Promise(function (res, rej) {
      var id = ++rpcId;
      pendientes[id] = { res: res, rej: rej };
      G.worker.postMessage(Object.assign({ id: id, tipo: tipo }, extra || {}));
    });
  }

  function escribir(blob) {
    G.ultimoTrozo = Date.now();
    if (G.avisoAtasco) { G.avisoAtasco = false; aviso("atasco", null); log("vuelven a llegar datos"); }
    G.bytes += blob.size;
    G.muestras.push([Date.now(), G.bytes]);
    if (G.muestras.length > 120) G.muestras.shift();
    if (G.memoria) { G.memoria.push(blob); return; }
    if (!G.worker || G.errorDisco) return;
    rpc("trozo", { blob: blob }).catch(function (e) {
      if (G.errorDisco) return;
      G.errorDisco = true;
      log("error al escribir en disco: " + e.message);
      detener("disco");
    });
  }

  // ---------------------------------------------------------------------
  // 7. Indicador mientras graba (M3)
  // ---------------------------------------------------------------------
  function pintarGrabando() {
    var vuEl = el("span", { class: "grab-vu", id: "grab-vu", "aria-hidden": "true" }, [el("span"), el("span"), el("span"), el("span"), el("span")]);
    var leer = el("div", { class: "grab__leer", id: "grab-leer" }, [
      el("span", { class: "eyebrow", text: "Lee en voz alta al empezar" }),
      el("p", { text: "«Informo a los asistentes que, a partir de este momento, esta reunión se está grabando en audio y vídeo. "
        + "Al participar, ustedes lo autorizan." + (responsable() ? " Responsable del tratamiento de los datos: " + conPunto(responsable()) : "") + "»" }),
      el("div", { class: "grab__acciones" }, [boton("Ya lo leí", "btn--secondary btn--sm", function () { leer.remove(); })])
    ]);
    setTimeout(function () { if (leer.isConnected) leer.remove(); }, 5 * 60 * 1000);
    var avisos = el("div", { id: "grab-avisos", class: "grab__avisos" });
    pintar([
      el("div", { class: "grab__vivo" }, [
        el("span", { class: "live-dot", "aria-hidden": "true" }),
        el("span", { class: "eyebrow", text: "Grabando" }),
        el("span", { class: "grab__tiempo", id: "grab-tiempo", role: "timer", text: "00:00:00" })
      ]),
      el("dl", { class: "grab__datos" }, [
        el("dt", { text: "Tamaño" }), el("dd", { id: "grab-peso", text: "primer trozo a los 5 s…" }),
        el("dt", { text: "Sonido" }), el("dd", null, [vuEl]),
        el("dt", { text: "Tu micro" }), el("dd", { id: "grab-mic", text: "…" }),
        el("dt", { text: "Archivo" }), el("dd", { class: "grab__nombre", text: G.nombre })
      ]),
      avisos,
      leer,
      boton("■ Detener y guardar", "btn--danger btn--block", clicDetener, { id: "grab-parar" }),
      el("p", { class: "field__hint", text: G.memoria
        ? "No cierres esta pestaña." : "No cierres esta pestaña. Se guarda una copia cada 5 segundos." })
    ]);
    ajustarPuerta();
    if (!G.micStream) aviso("mic", alerta("warn", "Tu voz no quedará en la grabación", "No hay acceso al micrófono. El resto de la reunión sí se graba."));
    if (G.sinSonido) aviso("sin", alerta("error", "Grabando SIN sonido", "Elegiste grabar sin sonido. La grabación no tendrá voz."));
    else if (G.audioBajo) aviso("bajo", alerta("warn", "El sonido llega muy bajo", "Revisa el volumen de la pestaña y de Chrome."));
    if (G.recorteFallo) aviso("recorte", alerta("info", "Se grabará también el panel lateral", "Este Chrome no pudo recortar la grabación a la reunión."));
    if (G.memoria) aviso("mem", alerta("warn", "Sin copia de seguridad", "Si Chrome se cierra se perderá la grabación. Actualiza Chrome para tener copia automática."));
  }

  /** Avisos persistentes por clave dentro de la tarjeta (null = quitar). */
  function aviso(k, nodo) {
    var c = $("grab-avisos");
    if (!c) return;
    var prev = c.querySelector('[data-aviso="' + k + '"]');
    if (prev) prev.remove();
    if (nodo) { nodo.setAttribute("data-aviso", k); c.appendChild(nodo); }
  }

  function tic() {
    if (estado !== "grabando") return;
    var ahora = Date.now();
    var t = $("grab-tiempo"); if (t) t.textContent = fmtReloj(ahora - G.inicio);
    var p = $("grab-peso");
    if (p && G.bytes) {
      var txt = fmtBytes(G.bytes);
      var r = ritmo();
      if (r) txt += " · ≈ " + fmtBytes(r * 3600) + "/hora";
      p.textContent = txt;
    }
    // Atasco: sin trozos nuevos (deberia llegar uno cada 5 s)
    if (ahora - G.ultimoTrozo > ATASCO_MS && !G.avisoAtasco) {
      G.avisoAtasco = true;
      log("más de " + ATASCO_MS / 1000 + " s sin datos del grabador");
      aviso("atasco", alerta("error", "La grabación no está recibiendo datos.",
        "Vuelve a esta pestaña y comprueba que la reunión se ve en pantalla. Si sigue así, detén y vuelve a grabar."));
    }
    // Silencio prolongado (§3.6)
    if (!G.sinSonido) {
      if (ahora - G.ultimoSonido > SILENCIO_MS) {
        if (!G.avisoSilencio) {
          G.avisoSilencio = true;
          aviso("silencio", alerta("warn", "Hace 10 min que no se graba sonido.", "¿Está hablando alguien? Comprueba que la pestaña no esté silenciada."));
          log("10 min sin sonido en la grabación");
        }
      } else if (G.avisoSilencio) { G.avisoSilencio = false; aviso("silencio", null); }
    }
    // Hora de fin prevista (§7 R6). Sin limite duro: solo recordatorios.
    var fin = parseInt(tarjeta().getAttribute("data-fin") || "0", 10);
    if (fin && ahora >= fin && ahora >= G.proximoAvisoFin && !G.avisoFinVisible) {
      G.avisoFinVisible = true;
      aviso("fin", alerta("info", "La reunión debía terminar a las " + (tarjeta().getAttribute("data-fin-txt") || "") + ". ¿Sigues grabando?", null, [
        boton("Detener", "btn--danger btn--sm", clicDetener),
        boton("Seguir grabando", "btn--secondary btn--sm", function () {
          G.avisoFinVisible = false; G.proximoAvisoFin = Date.now() + REPETIR_FIN_MS; aviso("fin", null);
        })
      ]));
    }
  }

  /** Bytes por segundo de los ultimos 5 min (peso REAL escrito, no estimado). */
  function ritmo() {
    var m = G.muestras;
    if (!m || m.length < 2) return 0;
    var fin = m[m.length - 1], ini = m[0];
    for (var i = m.length - 1; i >= 0; i--) { if (fin[0] - m[i][0] > 5 * 60 * 1000) break; ini = m[i]; }
    var dt = (fin[0] - ini[0]) / 1000;
    return dt > 0 ? (fin[1] - ini[1]) / dt : 0;
  }

  function medir() {
    if (estado !== "grabando" || !G.analizador) return;
    if (!G.bufVu) G.bufVu = new Float32Array(G.analizador.fftSize);
    var d = dB(rms(G.analizador, G.bufVu));
    vu("grab-vu", d);
    if (d >= SILENCIO_DB) G.ultimoSonido = Date.now();
  }

  async function comprobarEspacio() {
    if (estado !== "grabando" || G.memoria) return;
    var libre = await espacioLibre();
    var r = ritmo() || BYTES_HORA / 3600;
    if (libre === null) return;
    var min = libre / r / 60;
    if (min < 30) {
      aviso("espacio", alerta("warn", "Queda espacio para ≈ " + fmtDur(min * 60000) + " de grabación.",
        "Libera espacio en el disco o detén la grabación. Si se llena, la grabación se detendrá y se guardará sola."));
    } else aviso("espacio", null);
  }

  async function vigilarMicro() {
    if (estado !== "grabando" || !api) return;
    var id = await idMicroJitsi();
    if (!id || id === G.idMicro) return;
    log("cambio de micrófono en Jitsi: se reconecta");
    var nuevo = await abrirMicro(id);
    if (estado !== "grabando") { pararPistas(nuevo); return; }
    pararPistas(G.micStream);
    G.micStream = nuevo; G.idMicro = nuevo ? id : "";
    conectarMicro(nuevo);
    aviso("mic", nuevo ? null : alerta("warn", "Tu voz no quedará en la grabación", "No hay acceso al nuevo micrófono."));
  }

  // Riesgo R9, comprobado en Chromium: con el recorte (cropTo) sobre una zona
  // que NO esta en pantalla, Chrome deja de entregar fotogramas y el WebM no
  // escribe NADA, ni siquiera el audio. Por eso, si la zona deja de verse
  // entera ZONA_ESPERA_MS, se quita el recorte (se graba la pestana completa,
  // panel lateral incluido) y se vuelve a recortar cuando reaparece.
  // Perder el audio es peor que grabar el panel.
  var ZONA_MIN = 0.98, ZONA_ESPERA_MS = 2000, ATASCO_MS = 15000;

  async function recortar(si) {
    var v = G.pantalla && G.pantalla.getVideoTracks()[0];
    if (!v || !v.cropTo || G.recorteFallo || estado !== "grabando" || G.recortado === si) return;
    try {
      await v.cropTo(si ? await CropTarget.fromElement($("grab-zona")) : null);
      G.recortado = si;
      log(si ? "zona visible: se vuelve a recortar a la reunión" : "zona fuera de la vista: se graba la pestaña completa");
    } catch (e) { log("cropTo(" + (si ? "zona" : "null") + "): " + e.name + " " + e.message); }
  }

  function vigilarZona() {
    G.recortado = !G.recorteFallo;
    if (!window.IntersectionObserver) return;
    var timer = null;
    G.io = new IntersectionObserver(function (es) {
      var visible = es[es.length - 1].intersectionRatio >= ZONA_MIN;
      clearTimeout(timer);
      if (visible) { aviso("zona", null); recortar(true); return; }
      timer = setTimeout(function () {
        if (estado !== "grabando") return;
        recortar(false);
        aviso("zona", alerta("warn", "La reunión no está entera a la vista.",
          "Mientras tanto se graba la pestaña completa, incluido este panel. Sube en la página para volver a grabar solo la reunión."));
      }, ZONA_ESPERA_MS);
    }, { threshold: [0, 0.5, ZONA_MIN, 1] });
    G.io.observe($("grab-zona"));
  }

  function alSalir(e) { e.preventDefault(); e.returnValue = ""; return ""; }

  async function pedirWakeLock() {
    if (!navigator.wakeLock || estado !== "grabando") return;
    try { G.wake = await navigator.wakeLock.request("screen"); }
    catch (e) { log("Wake Lock: " + e.name); }
  }
  function alCambiarVisibilidad() { if (document.visibilityState === "visible") pedirWakeLock(); }

  // ---------------------------------------------------------------------
  // 8. Detener, guardar y descargar (§3.7, §4.7)
  // ---------------------------------------------------------------------
  function clicDetener() {
    confirmar("¿Detener la grabación?", "Se guardará el archivo en Descargas.", "Detener", true)
      .then(function (si) { if (si) detener("usuario"); });
  }

  function detener(motivo) {
    if (estado !== "grabando") return;
    estado = "guardando";
    G.motivo = motivo;
    G.finMs = Date.now();
    log("deteniendo (" + motivo + ")");
    pintar([el("p", { class: "grab__intro", text: "Guardando la grabación…" })]);
    try {
      if (G.rec && G.rec.state !== "inactive") G.rec.stop();   // -> ultimo dataavailable -> onstop -> finalizar()
      else finalizar();
    } catch (e) { finalizar(); }
  }

  async function finalizar() {
    // onerror + onstop pueden llegar los dos: solo cuenta el primero
    if (estado !== "guardando" || G.finalizado) return;
    G.finalizado = true;
    var duracion = (G.finMs || Date.now()) - G.inicio;
    var archivo = null;
    if (G.worker) {
      try { await conTiempo(rpc("cerrar", { meta: { duracionMs: duracion } }), 15000); }
      catch (e) { log("cerrar archivo: " + e.message); }
      G.worker.terminate(); G.worker = null;
      try { archivo = await leerCopia(G.nombre); } catch (e) { log("leer copia: " + e.message); }
    }
    if (!archivo && G.memoria) archivo = new Blob(G.memoria, { type: G.mime });
    var nombre = G.nombre, bytes = archivo ? archivo.size : G.bytes, motivo = G.motivo;
    limpiar();
    if (archivo) descargar(archivo, nombre);
    try { localStorage.setItem(K_OK, "1"); } catch (e) { /* idem */ }
    log("guardada " + nombre + " · " + fmtDur(duracion) + " · " + fmtBytes(bytes));
    pintarGuardado(nombre, duracion, bytes, motivo, archivo);
    listarCopias();
  }

  /** Suelta todo: pistas, grafo, temporizadores, avisos de la sala. */
  function limpiar() {
    ["ivReloj", "ivVu", "ivEspacio", "ivMicro"].forEach(function (k) { clearInterval(G[k]); });
    alColgar = null;
    window.removeEventListener("beforeunload", alSalir);
    document.removeEventListener("visibilitychange", alCambiarVisibilidad);
    if (G.wake) { G.wake.release().catch(function () {}); }
    if (G.io) G.io.disconnect();
    pararPistas(G.pantalla); pararPistas(G.micStream);
    ["tabSrc", "micSrc", "puerta", "mezcla", "analizador", "cero"].forEach(function (k) {
      if (G[k]) { try { G[k].disconnect(); } catch (e) { /* idem */ } }
    });
    if (G.soltarCerrojo) G.soltarCerrojo();
    if (G.worker) { G.worker.terminate(); }
    var a = $("grab-aviso"); if (a) a.hidden = true;
    var s = document.querySelector(".sala"); if (s) s.classList.remove("sala--grabando");
    var r = $("grab-rec"); if (r) r.hidden = true;
    var ey = document.querySelector(".salahead__live .eyebrow");
    if (ey && G.eyebrowTxt) ey.textContent = G.eyebrowTxt;
    if (estado === "guardando") {
      jitsi("subject", titulo());
      jitsi("sendChatMessage", "La grabación de la reunión ha terminado.");
    }
    var ctx = G.ctx;
    G = { ctx: ctx };
  }

  function descargar(blob, nombre) {
    var url = URL.createObjectURL(blob);
    var a = el("a", { href: url, download: nombre, hidden: true });
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 60000);
  }

  var MOTIVOS = {
    compartir: "La grabación se detuvo porque dejaste de compartir la pestaña.",
    colgar: "La grabación se detuvo porque saliste de la reunión en Jitsi.",
    disco: "No se pudo seguir guardando en el disco (¿disco lleno?). Se guardó lo grabado hasta ese momento.",
    error: "Chrome detuvo la grabación por un error. Se guardó lo grabado hasta ese momento."
  };

  function pintarGuardado(nombre, duracion, bytes, motivo, archivo) {
    estado = "guardado";
    var ok = !!archivo;
    pintar([
      MOTIVOS[motivo] ? alerta(motivo === "disco" || motivo === "error" ? "warn" : "info", MOTIVOS[motivo], null) : null,
      ok ? alerta("success", "Grabación guardada en Descargas", null, null, [
        el("p", { class: "grab__nombre", text: nombre }),
        el("p", { text: fmtDur(duracion) + " · " + fmtBytes(bytes) })
      ]) : alerta("error", "No se pudo recuperar el archivo de la grabación.", "Mira en «Copias en este computador» más abajo."),
      ok ? el("div", { class: "grab__acciones" }, [
        boton("Volver a descargar", "btn--secondary btn--sm", function () {
          leerCopia(nombre).then(function (f) { descargar(f, nombre); }, function () { if (archivo) descargar(archivo, nombre); });
        }),
        boton("Ya lo tengo guardado, borrar copia", "btn--secondary btn--sm btn--text-danger", function () {
          borrarCopiaConfirmada(nombre).then(function (si) { if (si) pintarListo(); });
        })
      ]) : null,
      el("p", { class: "field__hint", text: "¿Necesitas MP4? Usa el conversor de la guía del administrador (docs/GRABACION-ADMIN.md) o HandBrake." }),
      boton("● Grabar otra vez", "btn--primary btn--block", function () { pintarListo(); })
    ]);
  }

  // ---------------------------------------------------------------------
  // 9. Copias internas: recuperacion y limpieza a los 7 dias (§4.6)
  // ---------------------------------------------------------------------
  var copias = [];

  async function dirCopias(crear) {
    var root = await navigator.storage.getDirectory();
    return root.getDirectoryHandle(DIR, { create: !!crear });
  }

  async function leerCopia(nombre) {
    var dir = await dirCopias(false);
    return (await dir.getFileHandle(nombre)).getFile();
  }

  async function borrarCopia(nombre) {
    var dir = await dirCopias(false);
    try { await dir.removeEntry(nombre); } catch (e) { log("borrar " + nombre + ": " + e.name); }
    try { await dir.removeEntry(nombre + ".json"); } catch (e) { /* sin json */ }
  }

  function borrarCopiaConfirmada(nombre) {
    return confirmar("¿Borrar la copia interna?", "Asegúrate de tener el archivo «" + nombre + "» guardado. Esta copia no se puede recuperar después.",
      "Borrar copia", true).then(function (si) {
      if (!si) return false;
      return borrarCopia(nombre).then(function () { log("copia borrada: " + nombre); return listarCopias(); }).then(function () { return true; });
    });
  }

  async function listarCopias() {
    copias = [];
    if (!hayOPFS()) { pintarCopias(); return; }
    try {
      var dir = await dirCopias(false);
      var vivas = {};
      if (navigator.locks && navigator.locks.query) {
        try { ((await navigator.locks.query()).held || []).forEach(function (l) { vivas[l.name] = true; }); } catch (e) { /* idem */ }
      }
      var nombres = [];
      for await (var par of dir.entries()) nombres.push(par);
      var datos = {};
      nombres.forEach(function (p) { if (p[1].kind === "file" && !/\.json$/.test(p[0])) datos[p[0]] = p[1]; });
      for (var i = 0; i < nombres.length; i++) {
        var n = nombres[i][0];
        if (/\.json$/.test(n) && !datos[n.replace(/\.json$/, "")]) { try { await dir.removeEntry(n); } catch (e) { /* idem */ } }
      }
      var ahora = Date.now();
      for (var nombre in datos) {
        if (nombre === G.nombre) continue;   // la grabacion en curso en esta pestana
        var activa = !!vivas[LOCK + nombre], meta = null, f = null;
        try { meta = JSON.parse(await (await (await dir.getFileHandle(nombre + ".json")).getFile()).text()); } catch (e) { meta = null; }
        try { f = await datos[nombre].getFile(); } catch (e) { activa = true; }
        var ref = (meta && (meta.fin || meta.ultimoTrozo || meta.inicio)) || (f && f.lastModified) || ahora;
        if (!activa && ahora - ref > DIAS_COPIA * 86400000) {
          await borrarCopia(nombre);
          log("copia de más de " + DIAS_COPIA + " días borrada: " + nombre);
          continue;
        }
        copias.push({
          nombre: nombre, bytes: f ? f.size : (meta && meta.bytes) || 0, meta: meta, activa: activa, ref: ref,
          incompleta: !meta || meta.estado !== "completa",
          duracion: meta ? ((meta.duracionMs) || ((meta.ultimoTrozo || 0) - (meta.inicio || 0))) : 0
        });
      }
    } catch (e) {
      if (e.name !== "NotFoundError") log("copias internas: " + e.name + " " + e.message);
    }
    copias.sort(function (a, b) { return b.ref - a.ref; });
    pintarCopias();
    if (estado === "listo") pintarListo();   // aviso de recuperacion arriba
  }

  function nombreRecuperada(n) { return n.replace(/\.webm$/, "") + "-recuperada.webm"; }

  function descargarCopia(c) {
    leerCopia(c.nombre).then(function (f) {
      descargar(f, c.incompleta ? nombreRecuperada(c.nombre) : c.nombre);
      log("copia descargada: " + c.nombre);
    }, function (e) { log("no se pudo leer la copia " + c.nombre + ": " + e.name); });
  }

  function caduca(c) { return fmtFecha(c.ref + DIAS_COPIA * 86400000); }

  /** Aviso M1d en el estado "listo": la grabacion sin terminar mas reciente. */
  function recuperacionPendiente() {
    var c = copias.filter(function (x) { return x.incompleta && !x.activa; })[0];
    if (!c) return null;
    return alerta("warn", "Hay una grabación que no se guardó", "Chrome se cerró mientras grababa. Se puede reproducir hasta el corte.", [
      boton("Descargar", "btn--primary btn--sm", function () { descargarCopia(c); }),
      boton("Descartar", "btn--secondary btn--sm", function () { borrarCopiaConfirmada(c.nombre); })
    ], [
      el("p", { class: "grab__nombre", text: c.nombre }),
      el("p", { text: fmtDur(c.duracion) + " · " + fmtBytes(c.bytes) + " · se borra sola el " + caduca(c) })
    ]);
  }

  function pintarCopias() {
    var box = $("grab-copias"), ul = $("grab-copias-lista");
    if (!box || !ul) return;
    ul.textContent = "";
    box.hidden = !copias.length;
    $("grab-copias-n").textContent = copias.length ? String(copias.length) : "";
    var total = 0;
    copias.forEach(function (c) {
      total += c.bytes;
      var estadoTxt = c.activa ? "Grabándose en otra pestaña" : c.incompleta ? "Sin terminar (Chrome se cerró)" : "Completa";
      ul.appendChild(el("li", { "data-incompleta": c.incompleta && !c.activa ? "" : null }, [
        el("span", { class: "grab__nombre", text: c.nombre }),
        el("span", { text: estadoTxt + " · " + (c.duracion ? fmtDur(c.duracion) + " · " : "") + fmtBytes(c.bytes) }),
        el("span", { class: "field__hint", text: "Se borra sola el " + caduca(c) }),
        c.activa ? null : el("div", { class: "grab__acciones" }, [
          boton("Descargar", "btn--secondary btn--sm", function () { descargarCopia(c); }),
          boton("Borrar", "btn--secondary btn--sm btn--text-danger", function () { borrarCopiaConfirmada(c.nombre); })
        ])
      ]));
    });
    var s = box.querySelector("summary");
    if (s) s.setAttribute("title", "Ocupan " + fmtBytes(total));
    if (copias.some(function (c) { return c.incompleta && !c.activa; })) box.open = true;
  }

  // ---------------------------------------------------------------------
  // 10. Arranque
  // ---------------------------------------------------------------------
  function arrancar() {
    if (!$("grab")) return;
    deteccion = detectar();
    log("detección: " + deteccion + (deteccion === "ok" ? " (" + elegirFormato() + ")" : ""));
    prepararDialogo();
    pintarListo();
    if (deteccion !== "movil") listarCopias();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", arrancar);
  else arrancar();
})();
