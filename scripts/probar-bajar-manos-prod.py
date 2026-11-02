#!/usr/bin/env python3
"""
probar-bajar-manos-prod.py - "Bajar la mano" / "Bajar todas las manos" en
PRODUCCION con clientes reales (headless, sin personas).

A = administrador en /admin/reunion/<id>/sala (cookie firmada, como
probar-sala-prod.py). B1 y B2 = residentes por el link publico. Crea una
reunion de prueba "en curso" (sala propia, no toca otras) y la borra al final.

Pasos:
  1. B1 y B2 levantan la mano con la tecla "r" de Jitsi (mano REAL: el admin
     la ve por raiseHandUpdated -> span.mano en #lista).
  2. A pulsa "Bajar la mano" de B1: baja SOLO la de B1.
  3. B1 vuelve a levantarla; A pulsa "Bajar todas las manos": bajan las dos.
  4. Control: el mensaje por el videobridge (sendEndpointMessage, lo que
     hacia la version anterior) NO baja la mano (el JVB 2.3-295 lo reenvia
     sin msgPayload). Si algun dia empieza a bajarla, se avisa: el JVB se ha
     arreglado y este script lo detecta.

La mano se lee en el propio cliente del residente
(features/base/participants.local.raisedHandTimestamp), no solo en el panel.

Uso: scripts/probar-bajar-manos-prod.py
"""
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

MANO = "(() => APP.store.getState()['features/base/participants'].local.raisedHandTimestamp || 0)()"


def ok(cond, msg):
    print(("  OK     " if cond else "  FALLO  ") + msg)
    if not cond:
        FALLOS.append(msg)
    return cond


def esperar(fn, seg=20, paso=0.3):
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


def main():
    rid = None
    with sync_playwright() as pw:
        b = pw.chromium.launch(args=["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"])
        ca = b.new_context(viewport={"width": 1280, "height": 900}, permissions=["camera", "microphone"])
        ca.add_cookies([{"name": "session", "value": vpp.cookie_sesion(), "domain": DOM, "path": "/",
                         "secure": True, "httpOnly": True}])
        a = ca.new_page()
        a.goto(BASE + "/admin")
        col = datetime.now(timezone.utc) - timedelta(hours=5, minutes=5)
        a.fill("[name=titulo]", "PRUEBA bajar manos (se borra sola)")
        a.fill("[name=fecha]", col.strftime("%Y-%m-%d"))
        a.fill("[name=hora]", col.strftime("%H:%M"))
        a.fill("[name=duracion]", "30")
        with a.expect_navigation():
            a.eval_on_selector("form[action='/admin/reunion']", "f => f.submit()")
        m = re.search(r"/admin/qr/(\d+)", a.url)
        if not ok(bool(m), "crear reunion de prueba en curso"):
            return 1
        rid = m.group(1)
        slug = re.search(r"/reunion/([a-z0-9-]{6,})", a.content()).group(1)
        try:
            a.goto(BASE + "/admin/reunion/%s/sala" % rid)
            ok(esperar(lambda: a.inner_text("#st-audio") == "ACTIVA", 60), "A unido como moderador")
            marco = lambda: a.query_selector("#jitsi iframe").content_frame()
            B = {}
            for nom in ("Residente B1", "Residente B2"):
                c = b.new_context(viewport={"width": 900, "height": 700}, permissions=["camera", "microphone"])
                p = c.new_page()
                p.goto(BASE + "/reunion/" + slug)
                p.fill("[name=nombre]", nom)
                p.click("button[type=submit]")
                ok(esperar(lambda: p.evaluate("APP.conference.isJoined()"), 60), nom + " unido")
                B[nom] = p
            b1, b2 = B["Residente B1"], B["Residente B2"]
            ok(esperar(lambda: a.locator("#lista .p").count() == 2, 30), "A ve a B1 y B2 en #lista")
            mano = lambda p: p.evaluate(MANO)
            pnl = lambda: a.locator("#lista .mano").count()

            def levantar(*ps):
                for p in ps:
                    if not mano(p):
                        p.keyboard.press("r")
                return esperar(lambda: all(mano(p) for p in ps) and pnl() == 2, 20)

            print("[1. manos reales]")
            ok(levantar(b1, b2), "B1 y B2 con la mano levantada; A ve 2 span.mano")
            ok(esperar(lambda: a.locator("#manos-lista li").count() == 2), "lista individual con 2 personas")
            ok(a.locator("#manos-bajar").is_enabled(), "'Bajar todas las manos' habilitado")

            print("[2. control: via videobridge (version anterior)]")
            marco().evaluate("() => APP.conference.sendEndpointMessage('', {name: 'lower-hand-message'})")
            time.sleep(4)
            if mano(b1) or mano(b2):
                print("  info   sendEndpointMessage('') no baja ninguna mano (JVB sin msgPayload)")
            else:
                AVISOS.append("sendEndpointMessage('') HA BAJADO las manos: el JVB ya reenvia msgPayload")
                print("  AVISO  " + AVISOS[-1])
                levantar(b1, b2)

            print("[3. 'Bajar la mano' de B1]")
            a.get_by_role("button", name="Bajar la mano de Residente B1").click()
            ok(esperar(lambda: not mano(b1), 10), "la mano de B1 baja en el cliente de B1")
            time.sleep(1.5)
            ok(mano(b2) != 0, "la de B2 sigue levantada")
            ok(esperar(lambda: pnl() == 1, 10), "A ve 1 span.mano")
            # "Orden enviada…" es efimero: al bajar la mano #lista se repinta
            # y el aviso pasa a ser el recuento.
            ok(esperar(lambda: a.inner_text("#manos-estado") == "1 mano levantada.", 5),
               "aviso con el recuento: '%s'" % a.inner_text("#manos-estado"))

            print("[4. 'Bajar todas las manos']")
            ok(levantar(b1, b2), "B1 vuelve a levantarla: 2 manos")
            a.click("#manos-bajar")
            ok(esperar(lambda: not mano(b1) and not mano(b2), 10), "bajan las dos en los clientes de B1 y B2")
            ok(esperar(lambda: pnl() == 0, 10), "A ve 0 span.mano")
            ok(esperar(lambda: a.locator("#manos-bajar").is_disabled(), 5), "el boton vuelve a deshabilitarse")
            ok(esperar(lambda: "bajar todas las manos: todas las manos enviadas han bajado"
                       in a.eval_on_selector("#log", "e => e.textContent"), 8),
               "el #log confirma a los 5 s que bajaron")
            print("  #log:\n" + "\n".join("     | " + l for l in a.eval_on_selector("#log", "e => e.textContent")
                                         .strip().splitlines() if "mano" in l))
            for p in (b1, b2):
                p.evaluate("APP.conference.hangup()")
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
    print("=== %s ===%s" % ("OK" if not FALLOS else "%d FALLO(S)" % len(FALLOS),
                            "  (avisos: %s)" % AVISOS if AVISOS else ""))
    return 1 if FALLOS else 0


if __name__ == "__main__":
    sys.exit(main())
