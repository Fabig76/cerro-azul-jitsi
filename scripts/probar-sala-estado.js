#!/usr/bin/env node
/* probar-sala-estado.js - Prueba (sin navegador) de como se pinta cada boton
   de la sala segun el estado real: admin-panel/app/static/sala-estado.js.

   Uso: node scripts/probar-sala-estado.js [ruta/a/sala-estado.js]
   Lo llama scripts/verificar-panel-local.py. Codigo 0 si todo OK. */
"use strict";
var path = require("path");
var ruta = process.argv[2] || path.join(__dirname, "..", "admin-panel", "app", "static", "sala-estado.js");
require(path.resolve(ruta));
var SE = globalThis.SalaEstado;
var fallos = 0;

function g(o) {
  var b = { name: "Ana", hand: 0, mic: null, cam: null, pantalla: null, bloq: { audio: null, video: null } };
  Object.keys(o || {}).forEach(function (k) { b[k] = o[k]; });
  return b;
}
function caso(desc, r, esp) {
  var mal = Object.keys(esp).filter(function (k) { return r[k] !== esp[k]; });
  console.log((mal.length ? "  FALLO  " : "  OK     ") + desc +
    "  -> " + JSON.stringify({ texto: r.texto, clase: r.clase, pressed: r.pressed, disabled: r.disabled, accion: r.accion }));
  if (mal.length) { fallos++; mal.forEach(function (k) { console.log("         " + k + ": " + JSON.stringify(r[k]) + " != " + JSON.stringify(esp[k])); }); }
}

console.log("[botones por participante]");
caso("micro abierto -> Silenciar (.d, pressed)", SE.boton(g({ mic: true, bloq: { audio: false } }), "audio", true, null),
  { accion: "silenciar", texto: "Silenciar", clase: "d", pressed: "true", disabled: false });
caso("micro cerrado sin permiso -> Dar la palabra (.ok2)", SE.boton(g({ mic: false, bloq: { audio: true } }), "audio", true, null),
  { accion: "dar", texto: "Dar la palabra", clase: "ok2", pressed: "false" });
caso("idem con la mano levantada -> .pide y texto distinto", SE.boton(g({ mic: false, hand: 123, bloq: { audio: true } }), "audio", true, null),
  { accion: "dar", texto: "Dar la palabra (la pidió)", clase: "ok2 pide", pressed: "false" });
caso("cerrado con permiso -> Quitar la palabra (.d, pressed)", SE.boton(g({ mic: false, bloq: { audio: false } }), "audio", true, null),
  { accion: "quitar", texto: "Quitar la palabra", clase: "d", pressed: "true" });
caso("moderacion apagada y cerrado -> aria-disabled", SE.boton(g({ mic: false, bloq: { audio: false } }), "audio", false, null),
  { accion: null, texto: "Micro cerrado", disabled: true, pressed: "false" });
caso("sin datos de micro ni permiso -> neutro", SE.boton(g({}), "audio", true, null),
  { accion: "silenciar", texto: "Silenciar", clase: "", pressed: null });
caso("sin datos de micro, bloqueado -> Dar la palabra", SE.boton(g({ bloq: { audio: true } }), "audio", true, null),
  { accion: "dar", clase: "ok2" });
caso("moderacion sin datos, micro cerrado, permiso sin datos -> neutro", SE.boton(g({ mic: false }), "audio", null, null),
  { accion: "silenciar", clase: "", pressed: null });
caso("camara encendida -> Apagar cámara", SE.boton(g({ cam: true, bloq: { video: false } }), "video", true, null),
  { accion: "silenciar", texto: "Apagar cámara", clase: "d", pressed: "true" });
caso("camara apagada sin permiso -> Habilitar cámara", SE.boton(g({ cam: false, bloq: { video: true } }), "video", true, null),
  { accion: "dar", texto: "Habilitar cámara", clase: "ok2" });
caso("la mano no cambia el boton de camara", SE.boton(g({ cam: false, hand: 1, bloq: { video: true } }), "video", true, null),
  { texto: "Habilitar cámara", clase: "ok2" });
caso("orden pendiente -> Enviando… (busy, disabled)", SE.boton(g({ mic: true }), "audio", true, "silenciar"),
  { texto: "Enviando…", busy: true, disabled: true });
var r = SE.boton(g({ mic: true, name: "Ana" }), "audio", true, null);
caso("aria-label contiene el texto visible y el nombre", { texto: String(r.ayuda.indexOf("Silenciar") === 0 && r.ayuda.indexOf("Ana") > 0) }, { texto: "true" });

console.log("[chips]");
caso("chip abierto", SE.chip(g({ mic: true }), "audio"), { texto: "Micro abierto", clase: "badge badge--success" });
caso("chip sin datos", SE.chip(g({}), "video"), { texto: "Cámara: sin datos" });

console.log("[globales]");
var c0 = { mic: { on: 0, nul: 0 }, cam: { on: 0, nul: 0 } };
var e = SE.globales({ audio: true, video: true }, c0);
caso("moderacion A/V activa", { texto: [e.pressed["mod-on"], e.pressed["mod-off"], e.pressed["quitar-palabra-todos"], e.pressed["dar-palabra-todos"]].join() },
  { texto: "true,false,true,false" });
e = SE.globales({ audio: false, video: true }, c0);
caso("tras 'Dar a todos' (mixta): ningun A/V pulsado", { texto: [e.pressed["mod-on"], e.pressed["mod-off"], e.pressed["dar-palabra-todos"]].join() },
  { texto: ",,true" });
e = SE.globales({ audio: null, video: null }, c0);
caso("moderacion sin datos: nada pulsado", { texto: Object.keys(e.pressed).map(function (k) { return e.pressed[k]; }).join("") }, { texto: "" });
e = SE.globales({ audio: true, video: true }, { mic: { on: 2, nul: 1 }, cam: { on: 1, nul: 0 } });
caso("recuento de abiertos", { texto: e.silencio }, { texto: "Ahora: 2 micros abiertos (1 sin datos) · 1 cámara encendida." });

console.log("[pistas del store]");
var ifr = { contentWindow: { APP: { store: { getState: function () { return { "features/base/tracks": [
  { participantId: "aa", mediaType: "video", muted: true, videoType: "camera" },
  { participantId: "aa", mediaType: "video", muted: false, videoType: "desktop" },
  { participantId: "bb", mediaType: "audio", muted: false },
  { local: true, participantId: "aa", mediaType: "audio", muted: false }] }; } } } } };
caso("sin pista de audio = cerrado; la pantalla no cuenta como camara", { texto: JSON.stringify(SE.pistas(ifr, "aa")) },
  { texto: '{"audio":false,"video":false}' });
caso("pista de audio abierta", { texto: JSON.stringify(SE.pistas(ifr, "bb")) }, { texto: '{"audio":true,"video":false}' });
caso("store ilegible = sin datos", { texto: JSON.stringify(SE.pistas(null, "aa")) }, { texto: '{"audio":null,"video":null}' });

console.log("=== " + (fallos ? fallos + " FALLO(S)" : "OK") + " ===");
process.exit(fallos ? 1 : 0);
