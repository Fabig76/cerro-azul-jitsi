#!/usr/bin/env python3
"""
probar-sala-prod.py - Moderacion en PRODUCCION con dos clientes reales.

A = administrador en /admin/reunion/<id>/sala (cookie de sesion firmada con
la clave del panel, igual que verificar-panel-prod.py; no usa la contrasena).
B = residente que entra por /reunion/<slug> -> /unirse -> Jitsi.

Comprueba que el JS de la sala (sin cambios) sigue moderando sobre el DOM
rediseñado: moderacion A/V activa al entrar, B aparece en #lista, mano
levantada de B -> span.mano, "Dar a todos" / "Quitar a todos" cambian la
moderacion de audio que ve B, y "Silenciar" por participante manda su
comando. Crea una reunion de prueba "en curso" y la borra al final.

Uso: scripts/probar-sala-prod.py [--out DIR_CAPTURAS]
"""
import argparse
import importlib.util
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone

from playwright.sync_api import sync_playwright

AQUI = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("vpp", os.path.join(AQUI, "verificar-panel-prod.py"))
vpp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vpp)
BASE = vpp.BASE
DOM = BASE.split("//")[1]
FALLOS = []
AVISOS = []


def ok(cond, msg):
    print(("  OK     " if cond else "  FALLO  ") + msg)
    if not cond:
        FALLOS.append(msg)
    return cond


def esperar(fn, seg=40, paso=0.5):
    fin = time.time() + seg
    while time.time() < fin:
        try:
            v = fn()
            if v:
                return v
        except Exception:
            pass
        time.sleep(paso)
    return None


AV_B = "(() => { try { return APP.store.getState()['features/av-moderation'].audioModerationEnabled; } catch (e) { return null; } })()"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="directorio para capturas de la sala real")
    args = ap.parse_args()
    cookie = vpp.cookie_sesion()
    rid = None
    with sync_playwright() as pw:
        b = pw.chromium.launch(args=["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream",
                                     "--autoplay-policy=no-user-gesture-required"])
        ca = b.new_context(viewport={"width": 1280, "height": 900}, permissions=["camera", "microphone"])
        ca.add_cookies([{"name": "session", "value": cookie, "domain": DOM, "path": "/",
                         "secure": True, "httpOnly": True}])
        a = ca.new_page()
        a.goto(BASE + "/admin")
        col = datetime.now(timezone.utc) - timedelta(hours=5) - timedelta(minutes=5)
        a.fill("[name=titulo]", "PRUEBA sala con dos clientes (se borra sola)")
        a.fill("[name=fecha]", col.strftime("%Y-%m-%d"))
        a.fill("[name=hora]", col.strftime("%H:%M"))
        a.fill("[name=duracion]", "30")
        with a.expect_navigation():
            a.eval_on_selector("form[action='/admin/reunion']", "f => f.submit()")
        m = re.search(r"/admin/qr/(\d+)", a.url)
        if not ok(bool(m), "crear reunion de prueba en curso (%s)" % a.url.replace(BASE, "")):
            return 1
        rid = m.group(1)
        slug = re.search(r"/reunion/([a-z0-9-]{6,})", a.content()).group(1)
        try:
            print("[A: administrador en la sala rediseñada]")
            a.goto(BASE + "/admin/reunion/%s/sala" % rid)
            ok(a.evaluate("document.querySelector('#jitsi iframe') && document.querySelector('#jitsi iframe').style.height") == "560px",
               "iframe de Jitsi dentro de #jitsi con height 560px")
            ok(esperar(lambda: a.inner_text("#st-audio") == "ACTIVA" and a.inner_text("#st-video") == "ACTIVA", 60),
               "A se une como moderador y activa la moderacion A/V (#st-audio/#st-video = ACTIVA)")
            ok(esperar(lambda: a.locator("#lista > p.m").count() == 1, 20), "sala vacia: 'Nadie mas en la sala.'")

            print("[B: residente entra por el link publico]")
            cb = b.new_context(viewport={"width": 900, "height": 700}, permissions=["camera", "microphone"])
            bp = cb.new_page()
            bp.goto(BASE + "/reunion/" + slug)
            bp.fill("[name=nombre]", "Residente B")
            bp.click("button[type=submit]")
            ok(esperar(lambda: "#jwt=" in bp.url, 20) is not None, "/unirse -> Jitsi con el JWT en el fragmento (#jwt=)")
            unido = esperar(lambda: bp.evaluate("APP.conference.isJoined()")
                            or "Se requiere autenticación" in bp.inner_text("body") and "auth", 60)
            if unido is not True:
                # Fallo PREVIO al rediseño (jitsi_url no cambió): stable-11031
                # solo lee el JWT de la query. Se avisa y, para poder probar la
                # moderacion, B usa el MISMO token en ?jwt=.
                print("  AVISO  con #jwt= Jitsi pide autenticacion (fallo previo, ver DISENO-AUDITORIA)")
                AVISOS.append("#jwt= rechazado")
                base_url, frag = bp.url.split("#", 1)
                tok = re.search(r"jwt=([^&]+)", frag).group(1)
                bp.goto(base_url + "?jwt=" + tok + "#" + re.sub(r"jwt=[^&]+&?", "", frag))
            if not ok(esperar(lambda: bp.evaluate("APP.conference.isJoined()"), 60), "B unido a la conferencia"):
                bp.screenshot(path="/tmp/b-no-unido.png")
                print("    texto visible de B:", bp.inner_text("body")[:400].replace("\n", " | "))
                return 1
            ok(esperar(lambda: "Residente B" in a.inner_text("#lista"), 30), "A ve a B en #lista (div.p > div.n)")
            ok(esperar(lambda: a.inner_text("#cnt") == "(1)", 10), "#cnt = (1)")
            ok(esperar(lambda: bp.evaluate(AV_B) is True, 20), "B tiene la moderacion de audio activa (no puede hablar)")

            print("[mano levantada]")
            # Atajo de teclado "R" de Jitsi; si no llega, el boton de la barra.
            bp.keyboard.press("r")
            if not esperar(lambda: a.locator("#lista .mano").count() == 1, 10):
                bt = bp.locator("[aria-label*='mano' i], [aria-label*='hand' i]").first
                if bt.count():
                    bt.click()
            ok(esperar(lambda: a.locator("#lista .mano").count() == 1, 20)
               and a.inner_text("#lista .mano").startswith("[mano]"), "A ve '[mano]' de B (span.mano)")
            if args.out:
                os.makedirs(args.out, exist_ok=True)
                for tema in ("light", "dark"):
                    a.emulate_media(color_scheme=tema)
                    a.wait_for_timeout(400)
                    a.screenshot(path=os.path.join(args.out, "prod-sala-dos-clientes-%s-1280.png" % tema), full_page=True)
                a.emulate_media(color_scheme="light")

            print("[controles globales y por participante]")
            a.click(".gl button[data-cmd='dar-palabra-todos']")
            ok(esperar(lambda: bp.evaluate(AV_B) is False, 20), "'Dar a todos' -> B ya no tiene moderacion de audio")
            ok(esperar(lambda: a.inner_text("#st-audio") == "apagada", 10), "#st-audio = apagada")
            a.click(".gl button[data-cmd='quitar-palabra-todos']")
            ok(esperar(lambda: bp.evaluate(AV_B) is True, 20), "'Quitar a todos' -> B vuelve a estar moderado")
            ok(esperar(lambda: a.inner_text("#st-audio") == "ACTIVA", 10), "#st-audio = ACTIVA")
            a.locator("#lista .p button.d", has_text="Silenciar").first.click()
            a.locator("#registro, .sala__registro summary").first.click()
            ok(esperar(lambda: "muteRemoteParticipant" in a.inner_text("#log"), 5), "'Silenciar' de B registrado en #log")
            a.click(".gl button[data-cmd='mod-off']")
            ok(esperar(lambda: a.inner_text("#st-audio") == "apagada" and a.inner_text("#st-video") == "apagada", 15),
               "'Desactivar' moderacion A/V -> ambos 'apagada'")
            a.click(".gl button[data-cmd='mod-on']")
            ok(esperar(lambda: a.inner_text("#st-audio") == "ACTIVA" and a.inner_text("#st-video") == "ACTIVA", 15),
               "'Activar' moderacion A/V -> ambos 'ACTIVA'")
            bp.evaluate("APP.conference.hangup()")
            ok(esperar(lambda: a.locator("#lista > p.m").count() == 1, 30), "B cuelga -> 'Nadie mas en la sala.'")
            cb.close()
        finally:
            # Pestaña nueva: la de la sala tiene el iframe de Jitsi (beforeunload).
            a = ca.new_page()
            a.goto(BASE + "/admin")
            f = a.locator("form[action='/admin/reunion/%s/eliminar']" % rid)
            if f.count():
                with a.expect_navigation():
                    f.evaluate("f => f.submit()")
            a.goto(BASE + "/admin")
            ok("/admin/qr/%s\"" % rid not in a.content(), "reunion de prueba %s eliminada" % rid)
            b.close()
    print("=== %s ===%s" % ("OK" if not FALLOS else "%d FALLO(S)" % len(FALLOS),
                            "  (avisos: %s)" % AVISOS if AVISOS else ""))
    return 1 if FALLOS else 0


if __name__ == "__main__":
    sys.exit(main())
