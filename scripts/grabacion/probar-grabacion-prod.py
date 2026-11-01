#!/usr/bin/env python3
"""
probar-grabacion-prod.py - Grabacion corta en PRODUCCION con la Jitsi real.

Complementa probar-grabacion-headless.py (que usa una Jitsi simulada): aqui
la sala, el iframe y la API son los de produccion. Chromium headless en Linux
con la captura de pestana auto-aceptada, asi que NO prueba el dialogo de
Chrome ni macOS/Windows (ver docs/GRABACION-PASO0.md).

A = administrador en la sala (cookie de sesion firmada, como
    scripts/probar-sala-prod.py). B = residente por el enlace publico.
Comprueba: comprobaciones superadas, subject "● GRABANDO" y aviso en el chat
vistos por B, puerta del micro con el evento real audioMuteStatusChanged,
archivo descargado (vp8 + opus) y que la moderacion sigue respondiendo.
Crea una reunion de prueba "en curso" y la borra al final.

Uso: scripts/grabacion/probar-grabacion-prod.py [--out DIR]
"""
import argparse
import importlib.util
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

from playwright.sync_api import sync_playwright

AQUI = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("psp", os.path.join(AQUI, "..", "probar-sala-prod.py"))
psp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(psp)
vpp, BASE, DOM, ok, esperar = psp.vpp, psp.BASE, psp.DOM, psp.ok, psp.esperar

ESTADO_B = """(() => { const s = APP.store.getState();
  return { subject: (s['features/base/conference'] || {}).subject || '',
           chat: ((s['features/chat'] || {}).messages || []).map(m => m.message) }; })()"""


def frame_jitsi(page):
    for f in page.frames:
        if f != page.main_frame and DOM in (f.url or ""):
            return f
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/grab-prod")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    cookie = vpp.cookie_sesion()
    rid = None
    with sync_playwright() as pw:
        b = pw.chromium.launch(channel="chromium", headless=True, args=[
            "--auto-accept-this-tab-capture", "--use-fake-ui-for-media-stream",
            "--use-fake-device-for-media-stream", "--autoplay-policy=no-user-gesture-required"])
        ca = b.new_context(viewport={"width": 1280, "height": 900}, permissions=["camera", "microphone"],
                           accept_downloads=True)
        ca.add_cookies([{"name": "session", "value": cookie, "domain": DOM, "path": "/", "secure": True, "httpOnly": True}])
        a = ca.new_page()
        a.goto(BASE + "/admin")
        col = datetime.now(timezone.utc) - timedelta(hours=5) - timedelta(minutes=5)
        a.fill("[name=titulo]", "PRUEBA grabacion (se borra sola)")
        a.fill("[name=fecha]", col.strftime("%Y-%m-%d"))
        a.fill("[name=hora]", col.strftime("%H:%M"))
        a.fill("[name=duracion]", "30")
        with a.expect_navigation():
            a.eval_on_selector("form[action='/admin/reunion']", "f => f.submit()")
        m = re.search(r"/admin/qr/(\d+)", a.url)
        if not ok(bool(m), "crear reunion de prueba (%s)" % a.url.replace(BASE, "")):
            return 1
        rid = m.group(1)
        slug = re.search(r"/reunion/([a-z0-9-]{6,})", a.content()).group(1)
        try:
            a.goto(BASE + "/admin/reunion/%s/sala" % rid)
            ok(esperar(lambda: a.inner_text("#st-audio") == "ACTIVA", 60), "A unido como moderador (moderacion ACTIVA)")
            cb = b.new_context(viewport={"width": 900, "height": 700}, permissions=["camera", "microphone"])
            bp = cb.new_page()
            bp.goto(BASE + "/reunion/" + slug)
            bp.fill("[name=nombre]", "Residente B")
            bp.click("button[type=submit]")
            ok(esperar(lambda: bp.evaluate("APP.conference.isJoined()"), 60), "B unido")

            print("[grabar]")
            a.click("#grab-btn")
            if a.locator("#grab-dlg[open]").count():
                a.click("#grab-dlg-ok")
            if not ok(esperar(lambda: "Detener y guardar" in a.inner_text("#grab-cuerpo"), 30), "comprobaciones superadas, grabando"):
                print(a.inner_text("#grab-cuerpo")[:400]); print(a.inner_text("#log")[:1500])
                return 1
            log = a.inner_text("#log")
            for l in log.splitlines()[::-1]:
                if "[grabación]" in l:
                    print("    " + l.split("[grabación] ")[1][:200])
            st = esperar(lambda: (lambda e: e if "GRABANDO" in e["subject"] else None)(bp.evaluate(ESTADO_B)), 20)
            ok(st is not None, "B ve el subject: %s" % (st["subject"] if st else None))
            st = esperar(lambda: (lambda e: e if any("grabando" in x for x in e["chat"]) else None)(bp.evaluate(ESTADO_B)), 20)
            ok(st is not None, "B recibe el aviso en el chat: %s" % ([x for x in st["chat"] if "grabando" in x][0] if st else None))
            ok("silenciado" in a.inner_text("#grab-mic"), "micro del admin silenciado en Jitsi -> 'no se graba'")
            fj = frame_jitsi(a)
            fj.evaluate("APP.conference.muteAudio(false)")
            ok(esperar(lambda: a.inner_text("#grab-mic") == "en la grabación", 15),
               "abrir el micro en Jitsi (evento real audioMuteStatusChanged) -> 'en la grabación'")
            a.screenshot(path=os.path.join(args.out, "prod-grabando-1280.png"))
            time.sleep(12)
            fj.evaluate("APP.conference.muteAudio(true)")
            ok(esperar(lambda: "silenciado" in a.inner_text("#grab-mic"), 15), "volver a silenciar -> 'no se graba'")
            a.click(".gl button[data-cmd='dar-palabra-todos']")
            ok(esperar(lambda: a.inner_text("#st-audio") == "apagada", 15), "la moderacion sigue respondiendo mientras graba")
            a.click(".gl button[data-cmd='quitar-palabra-todos']")
            time.sleep(4)
            a.click("#grab-parar")
            with a.expect_download(timeout=60000) as dl:
                a.click("#grab-conf-si")
            dest = os.path.join(args.out, dl.value.suggested_filename)
            dl.value.save_as(dest)
            ok(esperar(lambda: "Grabación guardada" in a.inner_text("#grab-cuerpo"), 20), "guardada: " + os.path.basename(dest))
            r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,codec_name,width,height",
                                "-of", "compact", dest], capture_output=True, text=True).stdout.strip()
            print("    ffprobe: " + r.replace("\n", " | "))
            ok("vp8" in r and "opus" in r, "archivo con vp8 + opus (%d bytes)" % os.path.getsize(dest))
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "8", "-i", dest, "-frames:v", "1",
                            os.path.join(args.out, "prod-fotograma.png")])
            st = esperar(lambda: (lambda e: e if "GRABANDO" not in e["subject"] and any("terminado" in x for x in e["chat"]) else None)(bp.evaluate(ESTADO_B)), 20)
            ok(st is not None, "B ve el subject restaurado y el mensaje de fin")
            # La copia interna de la prueba se borra (no tiene sentido dejarla 7 dias)
            a.locator("#grab-cuerpo button", has_text="borrar copia").click()
            a.click("#grab-conf-si")
            cb.close()
        finally:
            a = ca.new_page()
            a.goto(BASE + "/admin")
            f = a.locator("form[action='/admin/reunion/%s/eliminar']" % rid)
            if f.count():
                with a.expect_navigation():
                    f.evaluate("f => f.submit()")
            a.goto(BASE + "/admin")
            ok("/admin/qr/%s\"" % rid not in a.content(), "reunion de prueba %s eliminada" % rid)
            b.close()
    print("=== %s ===" % ("OK" if not psp.FALLOS else "%d FALLO(S)" % len(psp.FALLOS)))
    return 1 if psp.FALLOS else 0


if __name__ == "__main__":
    sys.exit(main())
