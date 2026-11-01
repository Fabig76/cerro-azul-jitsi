/* grabacion-worker.js - Escritura de la grabacion en OPFS (SPEC-GRABACION §4.6).

   createSyncAccessHandle() solo existe dentro de un Worker. Escribe EN EL
   SITIO (sin archivo temporal .crswap): tras un cuelgue de Chrome queda todo
   lo escrito hasta el ultimo trozo. Junto al .webm mantiene un .json con el
   estado ("grabando" / "completa") para la recuperacion.

   Mensajes (todos responden {id, ok, error?, bytes?}):
     {id, tipo:"abrir",  nombre, meta}   crea grabaciones/<nombre> y <nombre>.json
     {id, tipo:"trozo",  blob}           anade el trozo al final y hace flush
     {id, tipo:"cerrar", meta}           marca "completa" y suelta los handles
   Los mensajes se procesan EN ORDEN (cola): blob.arrayBuffer() es asincrono y
   sin cola dos trozos podrian escribirse cruzados.
   Nada sale del navegador: ni fetch ni red. */
"use strict";

var DIR = "grabaciones";
var datos = null, meta = null, info = null, offset = 0;
var cola = Promise.resolve();

function guardarMeta() {
  var b = new TextEncoder().encode(JSON.stringify(info));
  meta.truncate(0);
  meta.write(b, { at: 0 });
  meta.flush();
}

async function abrir(m) {
  var root = await navigator.storage.getDirectory();
  var dir = await root.getDirectoryHandle(DIR, { create: true });
  var fh = await dir.getFileHandle(m.nombre, { create: true });
  var mh = await dir.getFileHandle(m.nombre + ".json", { create: true });
  datos = await fh.createSyncAccessHandle();
  meta = await mh.createSyncAccessHandle();
  datos.truncate(0);
  offset = 0;
  info = Object.assign({}, m.meta, { estado: "grabando", bytes: 0, ultimoTrozo: Date.now() });
  guardarMeta();
  return {};
}

async function trozo(m) {
  if (!datos) throw new Error("archivo no abierto");
  var buf = new Uint8Array(await m.blob.arrayBuffer());
  var n = datos.write(buf, { at: offset });
  if (n !== buf.byteLength) throw new Error("escritura incompleta (" + n + " de " + buf.byteLength + " bytes): ¿disco lleno?");
  offset += n;
  datos.flush();
  info.bytes = offset;
  info.ultimoTrozo = Date.now();
  guardarMeta();
  return { bytes: offset };
}

async function cerrar(m) {
  if (!datos) return {};
  Object.assign(info, m.meta || {}, { estado: "completa", bytes: offset, fin: Date.now() });
  guardarMeta();
  datos.flush(); datos.close(); meta.close();
  datos = meta = null;
  return { bytes: offset };
}

var ACCION = { abrir: abrir, trozo: trozo, cerrar: cerrar };

self.onmessage = function (ev) {
  var m = ev.data || {};
  cola = cola.then(function () {
    var f = ACCION[m.tipo];
    if (!f) throw new Error("mensaje desconocido: " + m.tipo);
    return f(m);
  }).then(function (r) {
    self.postMessage(Object.assign({ id: m.id, ok: true }, r));
  }, function (e) {
    self.postMessage({ id: m.id, ok: false, error: (e && (e.name + ": " + e.message)) || String(e) });
  });
};
