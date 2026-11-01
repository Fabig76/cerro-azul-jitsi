/* theme.js - tema, menus, carga de formularios y dialogo de confirmacion.
   Mejora progresiva: sin este fichero todo sigue funcionando (tema del
   sistema, <details> nativo, confirm() nativo). No toca la sala (.gl, #lista). */
(function () {
  "use strict";
  var KEY = "ca-tema", root = document.documentElement;
  var COLOR = { light: "#F5F5F7", dark: "#000000" };
  var NOMBRE = { auto: "Automático", light: "Claro", dark: "Oscuro" };

  function leer() {
    try { var v = localStorage.getItem(KEY); return v === "light" || v === "dark" ? v : null; }
    catch (e) { return null; }
  }
  function aplicar(v) {
    if (v) root.setAttribute("data-theme", v); else root.removeAttribute("data-theme");
    var ms = document.querySelectorAll('meta[name="theme-color"]');
    for (var i = 0; i < ms.length; i++) {
      var m = ms[i];
      if (!m.hasAttribute("data-def")) m.setAttribute("data-def", m.getAttribute("content"));
      m.setAttribute("content", v ? COLOR[v] : m.getAttribute("data-def"));
    }
  }
  aplicar(leer());

  function controles(v) {
    var k = v || "auto", i;
    var seg = document.querySelectorAll("[data-theme-set]");
    for (i = 0; i < seg.length; i++) seg[i].setAttribute("aria-pressed", String(seg[i].getAttribute("data-theme-set") === k));
    var cyc = document.querySelectorAll(".theme-cycle");
    for (i = 0; i < cyc.length; i++) {
      var t = cyc[i].querySelector("[data-theme-label]");
      if (t) t.textContent = NOMBRE[k];
      cyc[i].setAttribute("aria-label", "Apariencia: " + NOMBRE[k].toLowerCase() + ". Pulsa para cambiar");
    }
  }
  function guardar(v) {
    try { if (v) localStorage.setItem(KEY, v); else localStorage.removeItem(KEY); } catch (e) { /* queda en auto */ }
    aplicar(v); controles(v);
  }

  function listo() {
    controles(leer());
    document.addEventListener("click", function (e) {
      var s = e.target.closest ? e.target.closest("[data-theme-set]") : null;
      if (s) { var x = s.getAttribute("data-theme-set"); guardar(x === "auto" ? null : x); return; }
      if (e.target.closest && e.target.closest(".theme-cycle")) {
        var a = leer(); guardar(a === null ? "light" : a === "light" ? "dark" : null); return;
      }
      // Cerrar menus al hacer clic fuera
      var ms = document.querySelectorAll("details.menu[open]");
      for (var i = 0; i < ms.length; i++) if (!ms[i].contains(e.target)) ms[i].open = false;
    });
    document.addEventListener("keydown", function (e) {
      if (e.key !== "Escape") return;
      var ms = document.querySelectorAll("details.menu[open]");
      for (var i = 0; i < ms.length; i++) { ms[i].open = false; ms[i].querySelector("summary").focus(); }
    });
    var menus = document.querySelectorAll("details.menu");
    for (var i = 0; i < menus.length; i++) {
      menus[i].addEventListener("toggle", function (ev) {
        if (!ev.target.open) return;
        for (var j = 0; j < menus.length; j++) if (menus[j] !== ev.target) menus[j].open = false;
      });
    }

    // Estado de carga: evita el doble envio (p. ej. dos tokens en /unirse)
    var fs = document.querySelectorAll("form[data-loading]");
    for (i = 0; i < fs.length; i++) {
      fs[i].addEventListener("submit", function (ev) {
        var b = ev.target.querySelector('[type="submit"]');
        if (b) { b.setAttribute("aria-busy", "true"); b.disabled = true; }
      });
    }
    window.addEventListener("pageshow", function (ev) {
      if (!ev.persisted) return;
      var bs = document.querySelectorAll('button[aria-busy="true"]');
      for (var k = 0; k < bs.length; k++) { bs[k].removeAttribute("aria-busy"); bs[k].disabled = false; }
    });

    // Dialogo de confirmacion (sustituye al confirm() de respaldo)
    if (typeof HTMLDialogElement !== "function") return;
    var dlg = null, pendiente = null;
    function crear() {
      dlg = document.createElement("dialog");
      dlg.className = "dialog";
      dlg.setAttribute("aria-labelledby", "dlg-t");
      dlg.setAttribute("aria-describedby", "dlg-d");
      dlg.innerHTML = '<form method="dialog"><h2 class="dialog__title" id="dlg-t"></h2>' +
        '<p class="dialog__text" id="dlg-d"></p><div class="dialog__actions">' +
        '<button class="btn btn--secondary" value="cancel">Cancelar</button>' +
        '<button class="btn btn--danger" value="ok">Eliminar</button></div></form>';
      document.body.appendChild(dlg);
      dlg.addEventListener("close", function () {
        if (dlg.returnValue === "ok" && pendiente) pendiente.submit();
        pendiente = null;
      });
    }
    var cs = document.querySelectorAll("button[data-confirm]");
    for (i = 0; i < cs.length; i++) {
      cs[i].onclick = null;
      cs[i].addEventListener("click", function (ev) {
        ev.preventDefault();
        var b = ev.currentTarget;
        if (!dlg) crear();
        dlg.querySelector("#dlg-t").textContent = b.getAttribute("data-confirm-title") || "¿Confirmar?";
        dlg.querySelector("#dlg-d").textContent = b.getAttribute("data-confirm");
        pendiente = b.form;
        var m = b.closest("details.menu"); if (m) m.open = false;
        dlg.returnValue = "";
        dlg.showModal();
        dlg.querySelector('[value="cancel"]').focus();
      });
    }
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", listo);
  else listo();
})();
