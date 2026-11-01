#!/usr/bin/env python3
"""
probar-grabacion-headless.py - Prueba automatica de grabacion.js en Chromium (Linux).

NO sustituye la prueba en los PCs reales (docs/GRABACION-PASO0.md): aqui no hay
dialogo de compartir (se auto-acepta con --auto-accept-this-tab-capture), ni
macOS, ni Windows, ni Chrome de marca. Sirve para comprobar la LOGICA de punta a
punta con las API reales de Chromium: captura de la propia pestana, Capture
Handle, cropTo, bip de prueba, mezcla con el micro (dispositivo falso de
Chromium), MediaRecorder, escritura en OPFS desde el worker, descarga,
recuperacion tras cerrar la pestana de golpe y los casos de error.

La API de Jitsi se sustituye por un simulador (se intercepta external_api.js)
que pinta un iframe y reproduce un tono continuo como "participante remoto".
Todas las demas peticiones a Jitsi se bloquean.

Uso (contra el contenedor que deja `scripts/verificar-panel-local.py --keep`):
  scripts/grabacion/probar-grabacion-headless.py --base http://127.0.0.1:18090 --out /tmp/grab
Salida: resumen en stdout, archivos .webm, capturas PNG. Codigo 1 si algo falla.
"""
import argparse
import json
import os
import subprocess
import sys
import time

from playwright.sync_api import sync_playwright

USER = "Hguaza76"
PASSWORD = "prueba-local-123"
FALLOS = []

MOCK_API = r"""
window.__cmds = [];
window.__muted = true;
(function () {
  function Api(domain, o) {
    var self = this; this._l = {}; window.__api = this;
    var f = document.createElement('iframe');
    f.setAttribute('height', o.height || 560);
    f.srcdoc = '<body style="margin:0;background:#1d2b3a;color:#fff;font:28px sans-serif;display:grid;place-items:center;height:100vh">' +
      '<div>Jitsi simulado<br><span id=t></span></div><script>' +
      'setInterval(function(){t.textContent=new Date().toLocaleTimeString()},250);' +
      // "participante remoto": tono de 440 Hz a -26 dBFS, 1 s si / 1 s no
      'var c=new AudioContext(),o=c.createOscillator(),g=c.createGain();o.frequency.value=440;g.gain.value=0;' +
      'o.connect(g);g.connect(c.destination);o.start();var on=0;setInterval(function(){on=!on;g.gain.value=on?0.05:0},1000);' +
      '<\/script></body>';
    o.parentNode.appendChild(f);
    setTimeout(function () { self._emit('videoConferenceJoined', { id: 'yo', displayName: 'Admin' }); }, 300);
  }
  Api.prototype.addListener = function (e, fn) { (this._l[e] = this._l[e] || []).push(fn); };
  Api.prototype._emit = function (e, d) { (this._l[e] || []).forEach(function (fn) { fn(d); }); };
  Api.prototype.executeCommand = function () { window.__cmds.push(Array.prototype.slice.call(arguments)); };
  Api.prototype.isAudioMuted = function () { return Promise.resolve(window.__muted); };
  Api.prototype.getCurrentDevices = function () { return Promise.resolve({ audioInput: { deviceId: 'default' } }); };
  Api.prototype.isModerationOn = function () { return Promise.resolve(true); };
  Api.prototype.getRoomsInfo = function () { return Promise.resolve({ rooms: [{ isMainRoom: true, participants: [] }] }); };
  window.JitsiMeetExternalAPI = Api;
})();
"""

# Ganchos para provocar los casos negativos sin el dialogo real de Chrome.
INIT = r"""
(function () {
  var md = navigator.mediaDevices;
  if (!md || !md.getDisplayMedia) return;
  var orig = md.getDisplayMedia.bind(md);
  md.getDisplayMedia = async function (o) {
    var modo = sessionStorage.getItem('__modo') || '';
    if (modo === 'cancelar') throw new DOMException('Permission denied', 'NotAllowedError');
    var s = await orig(o);
    if (modo === 'sin-audio') s.getAudioTracks().forEach(function (t) { t.stop(); s.removeTrack(t); });
    if (modo === 'mudo') {
      s.getAudioTracks().forEach(function (t) { t.stop(); s.removeTrack(t); });
      var c = new AudioContext(), d = c.createMediaStreamDestination();
      s.addTrack(d.stream.getAudioTracks()[0]);
    }
    if (modo === 'otra') {
      var v = s.getVideoTracks()[0];
      v.getCaptureHandle = function () { return { handle: 'otra-pestana', origin: location.origin }; };
    }
    return s;
  };
})();
"""


def fallo(msg):
    FALLOS.append(msg)
    print("  FALLO: " + msg)


def ok(msg):
    print("  ok: " + msg)


def ffprobe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,codec_name,width,height",
                        "-of", "json", path], capture_output=True, text=True)
    streams = json.loads(r.stdout or "{}").get("streams", [])
    dec = subprocess.run(["ffmpeg", "-v", "info", "-i", path, "-af", "volumedetect", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    dur = None
    for line in dec.splitlines():
        if "time=" in line:
            t = line.split("time=")[-1].split()[0]
            try:
                h, m, s = t.split(":")
                dur = int(h) * 3600 + int(m) * 60 + float(s)
            except ValueError:
                pass
    maxv = [l.split("max_volume:")[1].strip() for l in dec.splitlines() if "max_volume:" in l]
    meanv = [l.split("mean_volume:")[1].strip() for l in dec.splitlines() if "mean_volume:" in l]
    return streams, dur, (maxv[-1] if maxv else None), (meanv[-1] if meanv else None)


def login(page, base):
    page.goto(base + "/admin/login")
    page.fill("#f-user", USER)
    page.fill("#f-password", PASSWORD)
    page.click("button[type=submit]")
    page.wait_for_url(base + "/admin")


def sala_id(page, base):
    page.goto(base + "/admin")
    href = page.locator("a[href*='/sala']").first.get_attribute("href")
    return href


def abrir_sala(ctx, base, href, modo="", w=1280, h=900):
    page = ctx.new_page()
    page.set_viewport_size({"width": w, "height": h})
    page.goto(base + "/admin/login")  # mismo origen para sessionStorage
    page.evaluate("m => sessionStorage.setItem('__modo', m)", modo)
    page.goto(base + href)
    page.wait_for_selector("#grab-cuerpo button, #grab-cuerpo .alert", timeout=15000)
    return page


def empezar(page, dialogo=True):
    page.click("#grab-btn")
    if dialogo and page.locator("#grab-dlg[open]").count():
        page.click("#grab-dlg-ok")


def esperar_texto(page, sel, texto, ms=15000):
    page.wait_for_function("([s, t]) => { var e = document.querySelector(s); return e && e.textContent.indexOf(t) >= 0; }",
                           arg=[sel, texto], timeout=ms)


def log_sala(page):
    return page.locator("#log").text_content() or ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:18090")
    ap.add_argument("--out", default="/tmp/grab-headless")
    ap.add_argument("--segundos", type=int, default=20)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    base = args.base.rstrip("/")

    with sync_playwright() as p:
        br = p.chromium.launch(channel="chromium", headless=True, args=[
            "--auto-accept-this-tab-capture",
            "--use-fake-ui-for-media-stream",
            "--use-fake-device-for-media-stream",
            "--autoplay-policy=no-user-gesture-required",
        ])
        ctx = br.new_context(accept_downloads=True, locale="es-CO")
        ctx.add_init_script(INIT)

        def ruta(route):
            u = route.request.url
            if u.endswith("/external_api.js"):
                return route.fulfill(status=200, content_type="text/javascript", body=MOCK_API)
            if u.startswith(base):
                return route.continue_()
            return route.abort()
        ctx.route("**/*", ruta)

        pg = ctx.new_page()
        login(pg, base)
        href = sala_id(pg, base)
        pg.close()
        print("sala: " + href)

        # ---------------- A. Grabacion normal ----------------
        print("\n=== A. Grabación normal (%d s) ===" % args.segundos)
        page = abrir_sala(ctx, base, href)
        det = log_sala(page)
        print("  detección: " + [l for l in det.splitlines() if "detección" in l][0].split("[grabación] ")[1])
        page.screenshot(path=os.path.join(args.out, "1280-listo.png"))
        page.click("#grab-btn")
        page.wait_for_selector("#grab-dlg[open]")
        time.sleep(0.5)  # fin de la animacion "pop"
        page.screenshot(path=os.path.join(args.out, "1280-dialogo.png"))
        page.click("#grab-dlg-ok")
        try:
            esperar_texto(page, "#grab-cuerpo", "Detener y guardar", 20000)
            ok("comprobaciones superadas y grabando")
        except Exception:
            fallo("no llegó a grabar: " + (page.locator("#grab-cuerpo").text_content() or "")[:300])
            print(log_sala(page))
            br.close()
            return
        for l in log_sala(page).splitlines()[::-1]:
            if "[grabación]" in l:
                print("    " + l.split("[grabación] ")[1])
        zona_rec = page.evaluate("(() => { var r = document.getElementById('grab-zona').getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)]; })()")
        aviso_visible = page.locator("#grab-aviso").is_visible()
        (ok if aviso_visible else fallo)("franja legal visible: %s" % aviso_visible)
        time.sleep(4)
        # el admin abre el micro en Jitsi a mitad de la grabacion
        page.evaluate("window.__muted = false; window.__api._emit('audioMuteStatusChanged', {muted: false})")
        mic = page.locator("#grab-mic").text_content()
        (ok if "en la grabación" in mic else fallo)("puerta del micro al abrir en Jitsi: " + mic)
        page.screenshot(path=os.path.join(args.out, "1280-grabando.png"))
        page.set_viewport_size({"width": 390, "height": 844})
        time.sleep(0.5)
        page.screenshot(path=os.path.join(args.out, "390-grabando.png"), full_page=True)
        page.set_viewport_size({"width": 1280, "height": 900})
        time.sleep(max(1, args.segundos - 5))
        # Recordatorio de la hora de fin (sin limite duro): se adelanta el fin
        page.evaluate("document.getElementById('grab').setAttribute('data-fin', String(Date.now() - 1000))")
        try:
            esperar_texto(page, "#grab-avisos", "debía terminar", 4000)
            ok("recordatorio de hora de fin")
            page.locator("#grab-avisos button", has_text="Seguir grabando").click()
            time.sleep(1.5)
            (ok if "debía terminar" not in (page.locator("#grab-avisos").text_content() or "") else fallo)(
                "«Seguir grabando» lo oculta (vuelve a los 15 min) y la grabación sigue")
        except Exception:
            fallo("no aparece el recordatorio de fin")
        peso = page.locator("#grab-peso").text_content()
        print("  peso mostrado: " + peso)
        cmds = page.evaluate("window.__cmds")
        subj = [c for c in cmds if c[0] == "subject"]
        chat = [c for c in cmds if c[0] == "sendChatMessage"]
        (ok if subj and "GRABANDO" in subj[0][1] else fallo)("subject: %s" % (subj[0][1] if subj else None))
        (ok if chat and "Responsable" in chat[0][1] else fallo)("chat: %s" % (chat[0][1] if chat else None))
        page.click("#grab-parar")
        page.wait_for_selector("#grab-conf[open]")
        time.sleep(0.5)
        page.screenshot(path=os.path.join(args.out, "1280-confirmar.png"))
        with page.expect_download(timeout=30000) as dl:
            page.click("#grab-conf-si")
        d = dl.value
        dest = os.path.join(args.out, d.suggested_filename)
        d.save_as(dest)
        esperar_texto(page, "#grab-cuerpo", "Grabación guardada")
        page.screenshot(path=os.path.join(args.out, "1280-guardado.png"))
        page.set_viewport_size({"width": 390, "height": 844})
        time.sleep(0.3)
        page.screenshot(path=os.path.join(args.out, "390-guardado.png"), full_page=True)
        cmds = page.evaluate("window.__cmds")
        print("  archivo: %s (%d bytes)" % (d.suggested_filename, os.path.getsize(dest)))
        streams, dur, maxv, meanv = ffprobe(dest)
        print("  ffprobe: %s  duración≈%s s  max_volume=%s mean_volume=%s" % (streams, dur, maxv, meanv))
        tipos = sorted(s["codec_type"] + ":" + s["codec_name"] for s in streams)
        (ok if tipos == ["audio:opus", "video:vp8"] else fallo)("pistas %s" % tipos)
        v = [s for s in streams if s["codec_type"] == "video"]
        if v and (v[0]["width"] > 1280 or v[0]["height"] > 720):
            fallo("vídeo mayor de 1280x720: %sx%s" % (v[0]["width"], v[0]["height"]))
        elif v:
            ok("vídeo %sx%s (recortado a la zona)" % (v[0]["width"], v[0]["height"]))
            # La cabecera debe tener ya el tamano CON la franja legal (zona completa)
            zona = zona_rec
            if abs(v[0]["height"] - zona[1]) > 4:
                fallo("cabecera del WebM %s px de alto; la zona con franja mide %s (¿franja después del 1.er fotograma?)" % (v[0]["height"], zona[1]))
            else:
                ok("primer fotograma ya con la franja (zona %sx%s)" % tuple(zona))
        if dur is None or abs(dur - args.segundos) > 4:
            fallo("duración %s s (esperado ≈ %d)" % (dur, args.segundos))
        else:
            ok("duración %.1f s" % dur)
        try:
            mv = float(maxv.split()[0])
            (ok if mv > -30 else fallo)("audio con señal (max %.1f dB)" % mv)
        except Exception:
            fallo("sin volumedetect")
        frame = os.path.join(args.out, "fotograma-5s.png")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "5", "-i", dest, "-frames:v", "1", frame])
        print("  fotograma: " + frame)
        fin = [c for c in cmds if c[0] == "sendChatMessage" and "terminado" in c[1]]
        (ok if fin else fallo)("mensaje de fin en el chat")
        restaurado = [c for c in cmds if c[0] == "subject"][-1][1]
        (ok if "GRABANDO" not in restaurado else fallo)("subject restaurado: " + restaurado)
        page.close()

        # ---------------- B. Recuperacion tras cierre brusco ----------------
        print("\n=== B. Cierre brusco y recuperación ===")
        page = abrir_sala(ctx, base, href)
        empezar(page)
        esperar_texto(page, "#grab-cuerpo", "Detener y guardar", 20000)
        time.sleep(13)
        page.close(run_before_unload=False)
        page = abrir_sala(ctx, base, href)
        try:
            esperar_texto(page, "#grab-cuerpo", "no se guardó", 10000)
            ok("aviso de recuperación al volver")
        except Exception:
            fallo("no aparece el aviso de recuperación")
        page.screenshot(path=os.path.join(args.out, "1280-recuperacion.png"))
        page.set_viewport_size({"width": 390, "height": 844})
        time.sleep(0.3)
        page.screenshot(path=os.path.join(args.out, "390-recuperacion.png"), full_page=True)
        page.set_viewport_size({"width": 1280, "height": 900})
        with page.expect_download(timeout=20000) as dl:
            page.locator("#grab-cuerpo .alert button", has_text="Descargar").click()
        d = dl.value
        dest = os.path.join(args.out, d.suggested_filename)
        d.save_as(dest)
        streams, dur, maxv, _ = ffprobe(dest)
        print("  recuperada: %s %d bytes, duración≈%s s, pistas=%d" % (d.suggested_filename, os.path.getsize(dest), dur, len(streams)))
        (ok if d.suggested_filename.endswith("-recuperada.webm") else fallo)("nombre de la recuperada")
        (ok if dur and dur >= 8 else fallo)("la recuperada se reproduce hasta el corte (%s s, esperado ≈ 10-13)" % dur)
        page.close()

        # ---------------- B2. Zona fuera de pantalla (riesgo R9) ----------------
        print("\n=== B2. Zona de la reunión fuera de la pantalla ===")
        page = abrir_sala(ctx, base, href)
        empezar(page)
        esperar_texto(page, "#grab-cuerpo", "Detener y guardar", 20000)
        time.sleep(6)
        # Se anula el sticky y se baja la pagina hasta que la zona no se ve
        page.evaluate("""() => { document.getElementById('grab-zona').style.position = 'static';
            var e = document.createElement('div'); e.style.height = '4000px'; document.querySelector('.sala').after(e);
            window.scrollTo(0, 3000); }""")
        b0 = page.evaluate("document.getElementById('grab-peso').textContent")
        time.sleep(14)
        b1 = page.evaluate("document.getElementById('grab-peso').textContent")
        avisos = page.locator("#grab-avisos").text_content() or ""
        (ok if "no está entera" in avisos else fallo)("aviso de zona fuera de la vista")
        (ok if "pestaña completa" in log_sala(page) else fallo)("sin recorte mientras no se ve")
        (ok if "no está recibiendo datos" not in avisos else fallo)("sin atasco (siguen llegando trozos): %s → %s" % (b0, b1))
        page.evaluate("window.scrollTo(0, 0)")
        time.sleep(6)
        (ok if "se vuelve a recortar" in log_sala(page) else fallo)("vuelve a recortar al reaparecer la zona")
        page.click("#grab-parar")
        with page.expect_download(timeout=30000) as dl:
            page.click("#grab-conf-si")
        dest = os.path.join(args.out, "zona-fuera-" + dl.value.suggested_filename)
        dl.value.save_as(dest)
        streams, dur, maxv, _ = ffprobe(dest)
        print("  archivo: duración≈%s s, max_volume=%s" % (dur, maxv))
        (ok if dur and dur >= 24 else fallo)("la grabación cubre todo el tramo, también sin la zona a la vista (%s s, esperado ≈ 26)" % dur)
        page.close()

        # ---------------- C. Casos negativos ----------------
        print("\n=== C. Casos negativos ===")
        for modo, esperado in [("sin-audio", "No marcaste"), ("mudo", "no capta el sonido"),
                               ("otra", "otra ventana o pestaña"), ("cancelar", "No se compartió nada")]:
            page = abrir_sala(ctx, base, href, modo=modo)
            empezar(page)
            try:
                esperar_texto(page, "#grab-cuerpo", esperado, 15000)
                grabando = "Detener y guardar" in (page.locator("#grab-cuerpo").text_content() or "")
                (ok if not grabando else fallo)("%s → «%s», sin grabar" % (modo, esperado))
            except Exception:
                fallo("%s: no salió «%s»: %s" % (modo, esperado, (page.locator("#grab-cuerpo").text_content() or "")[:200]))
            if modo in ("sin-audio", "mudo"):
                page.screenshot(path=os.path.join(args.out, "1280-error-%s.png" % modo))
            if modo == "mudo":
                page.click("text=Grabar sin sonido")
                page.wait_for_selector("#grab-conf[open]")
                page.click("#grab-conf-si")
                try:
                    esperar_texto(page, "#grab-cuerpo", "SIN sonido", 15000)
                    ok("mudo → «Grabar sin sonido» con confirmación graba con aviso rojo")
                    page.click("#grab-parar"); page.click("#grab-conf-si")
                    esperar_texto(page, "#grab-cuerpo", "Grabación guardada", 20000)
                except Exception:
                    fallo("grabar sin sonido")
            page.close()

        # Navegador sin Region Capture (Safari/Firefox) y movil
        page = ctx.new_page()
        page.add_init_script("delete window.CropTarget")
        page.goto(base + href)
        esperar_texto(page, "#grab-cuerpo", "Google Chrome", 10000)
        ok("sin CropTarget → «abre esta página en Google Chrome»")
        page.close()
        mctx = br.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True, locale="es-CO")
        mctx.route("**/*", ruta)
        mp = mctx.new_page()
        login(mp, base)
        mp.goto(base + href)
        esperar_texto(mp, "#grab-cuerpo", "NO se está grabando", 10000)
        ok("móvil → «La reunión NO se está grabando» y botón deshabilitado")
        mp.screenshot(path=os.path.join(args.out, "390-movil.png"), full_page=True)
        mctx.close()

        # Copia de hace 8 dias: se borra sola al abrir la sala (7 dias, Q6)
        page = abrir_sala(ctx, base, href)
        page.evaluate("""async () => {
            const d = await (await navigator.storage.getDirectory()).getDirectoryHandle('grabaciones', {create: true});
            const ant = Date.now() - 8 * 86400000;
            for (const [n, txt] of [['Asamblea-vieja-2020-01-01-0900.webm', 'x'],
                                    ['Asamblea-vieja-2020-01-01-0900.webm.json', JSON.stringify({estado: 'completa', inicio: ant, fin: ant})]]) {
                const w = await (await d.getFileHandle(n, {create: true})).createWritable(); await w.write(txt); await w.close();
            }}""")
        page.close()
        page = abrir_sala(ctx, base, href)
        time.sleep(1.5)
        quedan = page.evaluate("""async () => { const d = await (await navigator.storage.getDirectory()).getDirectoryHandle('grabaciones');
            const r = []; for await (const [k] of d.entries()) r.push(k); return r; }""")
        (ok if not any("vieja" in k for k in quedan) else fallo)("copia de hace 8 días borrada sola")
        page.screenshot(path=os.path.join(args.out, "1280-copias.png"))
        page.locator("#grab-copias summary").click()
        time.sleep(0.3)
        page.locator("#grab-copias").screenshot(path=os.path.join(args.out, "1280-copias-lista.png"))
        page.close()

        # Limpieza: las copias de esta prueba
        page = abrir_sala(ctx, base, href)
        n = page.evaluate("""async () => { const d = await (await navigator.storage.getDirectory()).getDirectoryHandle('grabaciones');
            let n = 0; for await (const [k] of d.entries()) n++; return n; }""")
        print("\n  entradas en OPFS al final de la prueba: %d" % n)
        br.close()

    print("\n=== RESULTADO: %s ===" % ("OK" if not FALLOS else "%d FALLO(S)" % len(FALLOS)))
    for f in FALLOS:
        print("  - " + f)
    sys.exit(1 if FALLOS else 0)


if __name__ == "__main__":
    main()
