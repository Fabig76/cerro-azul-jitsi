#!/usr/bin/env python3
"""
probar-estado-botones-prod.py - Los botones de la sala de moderacion muestran
el estado REAL, en PRODUCCION, con clientes reales (headless, sin personas).

A = administrador en /admin/reunion/<id>/sala (cookie firmada, como
probar-bajar-manos-prod.py). B1 y B2 = residentes por el link publico. Crea
una reunion de prueba "en curso" (sala propia, no toca otras) y la borra al
final. Cada fila de #lista se localiza por div.p[data-id=<id del residente>]
y cada boton por button[data-accion=audio|video].

Pasos (lo que ve A se cruza con lo que pasa en el cliente del residente):
  1. Estado inicial: micro cerrado, sin permiso -> "Dar la palabra" (.ok2,
     aria-pressed=false); globales: "Activar" y "Quitar a todos" pulsados.
  2. B1 levanta la mano -> "Dar la palabra (la pidió)" (.pide).
  3. A da la palabra a B1 -> "Quitar la palabra" (B1 aun no abre el micro).
  4. B1 abre el micro -> A ve "Micro abierto" y "Silenciar".
  5. A silencia a B1 -> el micro de B1 se cierra y B1 YA NO PUEDE volver a
     abrirlo (mute + rejectParticipant): la moderacion es efectiva.
  6. Al reves: B2 con la palabra abre y CIERRA el micro el mismo -> el boton
     de A pasa de "Silenciar" a "Quitar la palabra" sin que A haga nada.
  7. Camara de B2: "Habilitar cámara" -> B2 la enciende -> "Apagar cámara"
     -> A la apaga y B2 no puede volver a encenderla.
  8. Globales: "Dar a todos" -> pulsado y "Activar" deja de estarlo (mixta);
     "Micrófonos" -> el recuento "Ahora" vuelve a 0; "Activar" -> todo vuelve.
  9. Errores: si executeCommand lanza, el #log lo anota y el boton NO cambia;
     si la orden no se confirma, "Enviando…" y a los 6 s vuelve al estado
     real con un AVISO en #log. (Se simulan solo en la pagina de A, enganchando
     la instancia de la API al servir grabacion.js en ESTA prueba.)

Uso: scripts/probar-estado-botones-prod.py [--capturas DIR]
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

# Solo en esta prueba: guarda la instancia de la API en window.__api para
# poder simular fallos de executeCommand (paso 9). No toca produccion.
ENGANCHE = r''';(function(){var O=window.JitsiMeetExternalAPI;
 window.JitsiMeetExternalAPI=function(d,o){var a=new O(d,o);window.__api=a;return a;};})();'''

AUDIO = "APP.conference.isLocalAudioMuted()"
VIDEO = "APP.conference.isLocalVideoMuted()"


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
    ap = argparse.ArgumentParser()
    ap.add_argument("--capturas", help="directorio donde guardar capturas del panel lateral")
    args = ap.parse_args()
    rid = None
    with sync_playwright() as pw:
        b = pw.chromium.launch(args=["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"])
        ca = b.new_context(viewport={"width": 1280, "height": 900}, permissions=["camera", "microphone"])
        ca.add_cookies([{"name": "session", "value": vpp.cookie_sesion(), "domain": DOM, "path": "/",
                         "secure": True, "httpOnly": True}])

        def enganchar(route):
            r = route.fetch()
            route.fulfill(response=r, body=r.text() + ENGANCHE)
        ca.route(re.compile(r".*/admin/static/grabacion\.js.*"), enganchar)
        a = ca.new_page()
        a.goto(BASE + "/admin")
        col = datetime.now(timezone.utc) - timedelta(hours=5, minutes=5)
        a.fill("[name=titulo]", "PRUEBA estado botones (se borra sola)")
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

        def captura(nombre):
            if args.capturas:
                os.makedirs(args.capturas, exist_ok=True)
                a.locator(".sala__lado").screenshot(path=os.path.join(args.capturas, nombre + ".png"))

        try:
            a.goto(BASE + "/admin/reunion/%s/sala" % rid)
            ok(esperar(lambda: a.inner_text("#st-audio") == "ACTIVA", 60), "A unido como moderador")
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
            id1, id2 = (p.evaluate("APP.conference.getMyUserId()") for p in (b1, b2))
            fila = lambda i: a.locator('#lista .p[data-id="%s"]' % i)
            bot = lambda i, t: fila(i).locator('button[data-accion="%s"]' % t)
            txt = lambda i, t: bot(i, t).inner_text()
            at = lambda i, t, n: bot(i, t).get_attribute(n)
            cls = lambda i, t: bot(i, t).get_attribute("class") or ""
            est = lambda i: fila(i).locator(".est").inner_text()
            glp = lambda c: a.get_attribute('.gl button[data-cmd="%s"]' % c, "aria-pressed")
            log = lambda: a.eval_on_selector("#log", "e => e.textContent")

            print("[1. estado inicial]")
            ok(esperar(lambda: fila(id1).count() == 1 and fila(id2).count() == 1, 30),
               "A ve a B1 y B2 por data-id (%s, %s)" % (id1, id2))
            ok(esperar(lambda: txt(id1, "audio") == "Dar la palabra", 15),
               "B1 audio: '%s' (esperado 'Dar la palabra')" % txt(id1, "audio"))
            ok(cls(id1, "audio") == "ok2" and at(id1, "audio", "aria-pressed") == "false",
               "  clase=%r aria-pressed=%r" % (cls(id1, "audio"), at(id1, "audio", "aria-pressed")))
            ok("Micro cerrado" in est(id1), "  chips de B1: %r" % est(id1).replace("\n", " | "))
            ok(txt(id1, "video") == "Habilitar cámara", "B1 video: '%s'" % txt(id1, "video"))
            ok(esperar(lambda: glp("mod-on") == "true" and glp("quitar-palabra-todos") == "true", 10),
               "globales: Activar=%r Quitar a todos=%r Desactivar=%r Dar a todos=%r" % (
                   glp("mod-on"), glp("quitar-palabra-todos"), glp("mod-off"), glp("dar-palabra-todos")))
            print("  gl: %r | %r" % (a.inner_text("#gl-est-palabra"), a.inner_text("#gl-est-silencio")))
            captura("1-inicial")

            print("[2. B1 levanta la mano]")
            b1.keyboard.press("r")
            ok(esperar(lambda: txt(id1, "audio") == "Dar la palabra (la pidió)", 15),
               "B1 audio: '%s'" % txt(id1, "audio"))
            ok("pide" in cls(id1, "audio"), "  clase=%r" % cls(id1, "audio"))
            captura("2-mano")

            print("[3. A da la palabra a B1]")
            bot(id1, "audio").click()
            ok(esperar(lambda: txt(id1, "audio") == "Quitar la palabra", 10),
               "B1 audio tras dar: '%s' aria-pressed=%r" % (txt(id1, "audio"), at(id1, "audio", "aria-pressed")))
            ok("dar la palabra confirmado" in log(), "  #log: confirmado")

            print("[4. B1 abre el micro]")
            b1.keyboard.press("m")
            ok(esperar(lambda: not b1.evaluate(AUDIO), 8), "  el micro de B1 esta abierto en su cliente")
            ok(esperar(lambda: txt(id1, "audio") == "Silenciar" and "Micro abierto" in est(id1), 10),
               "A ve 'Silenciar' y '%s'" % est(id1).replace("\n", " | "))
            ok(at(id1, "audio", "aria-pressed") == "true" and cls(id1, "audio") == "d",
               "  clase=%r aria-pressed=%r" % (cls(id1, "audio"), at(id1, "audio", "aria-pressed")))
            ok(esperar(lambda: "1 micro abierto" in a.inner_text("#gl-est-silencio"), 5),
               "  gl: %r" % a.inner_text("#gl-est-silencio"))
            captura("4-micro-abierto")

            print("[5. A silencia a B1: mute + rejectParticipant]")
            bot(id1, "audio").click()
            ok(esperar(lambda: b1.evaluate(AUDIO), 8), "el micro de B1 se cierra en su cliente")
            ok(esperar(lambda: txt(id1, "audio").startswith("Dar la palabra"), 10),
               "A ve '%s'" % txt(id1, "audio"))
            b1.keyboard.press("m")
            time.sleep(3)
            ok(b1.evaluate(AUDIO), "B1 intenta reabrir el micro y NO puede (permiso revocado)")
            ok(txt(id1, "audio").startswith("Dar la palabra") and "Micro cerrado" in est(id1),
               "A sigue viendo '%s' / %r" % (txt(id1, "audio"), est(id1).replace("\n", " | ")))
            ok("silenciar confirmado" in log(), "  #log: silenciar confirmado")

            print("[6. al reves: B2 abre y cierra su micro el mismo]")
            bot(id2, "audio").click()
            ok(esperar(lambda: txt(id2, "audio") == "Quitar la palabra", 10), "B2 con la palabra")
            b2.keyboard.press("m")
            ok(esperar(lambda: txt(id2, "audio") == "Silenciar", 10), "B2 abre: A ve 'Silenciar'")
            b2.keyboard.press("m")
            ok(esperar(lambda: b2.evaluate(AUDIO), 8), "  B2 cierra en su cliente")
            ok(esperar(lambda: txt(id2, "audio") == "Quitar la palabra" and "Micro cerrado" in est(id2), 10),
               "A ve '%s' sin hacer nada" % txt(id2, "audio"))

            print("[7. camara de B2]")
            bot(id2, "video").click()
            ok(esperar(lambda: txt(id2, "video") == "Quitar la cámara", 10), "habilitada: '%s'" % txt(id2, "video"))
            b2.keyboard.press("v")
            ok(esperar(lambda: not b2.evaluate(VIDEO), 10), "  B2 enciende la camara en su cliente")
            ok(esperar(lambda: txt(id2, "video") == "Apagar cámara" and "Cámara encendida" in est(id2), 10),
               "A ve '%s'" % txt(id2, "video"))
            bot(id2, "video").click()
            ok(esperar(lambda: b2.evaluate(VIDEO), 10), "la camara de B2 se apaga en su cliente")
            ok(esperar(lambda: txt(id2, "video") == "Habilitar cámara", 10), "A ve '%s'" % txt(id2, "video"))
            b2.keyboard.press("v")
            time.sleep(3)
            ok(b2.evaluate(VIDEO), "B2 no puede volver a encenderla")

            print("[8. globales]")
            a.click('.gl button[data-cmd="dar-palabra-todos"]')
            ok(esperar(lambda: glp("dar-palabra-todos") == "true" and glp("mod-on") is None, 10),
               "Dar a todos=%r Activar=%r (mixta) | %r" % (glp("dar-palabra-todos"), glp("mod-on"),
                                                           a.inner_text("#gl-est-mod")))
            ok(esperar(lambda: txt(id1, "audio") == "Micro cerrado" and at(id1, "audio", "aria-disabled") == "true", 10),
               "con moderacion de audio apagada B1: '%s' aria-disabled=%r" % (
                   txt(id1, "audio"), at(id1, "audio", "aria-disabled")))
            b1.keyboard.press("m")
            b2.keyboard.press("m")
            ok(esperar(lambda: "2 micros abiertos" in a.inner_text("#gl-est-silencio"), 10),
               "B1 y B2 abren: %r" % a.inner_text("#gl-est-silencio"))
            captura("8-dar-a-todos")
            a.click('.gl button[data-cmd="mute-all-audio"]')
            ok(esperar(lambda: b1.evaluate(AUDIO) and b2.evaluate(AUDIO), 10), "Micrófonos: B1 y B2 cerrados")
            ok(esperar(lambda: "ningún micro abierto" in a.inner_text("#gl-est-silencio"), 10),
               "  gl: %r" % a.inner_text("#gl-est-silencio"))
            a.click('.gl button[data-cmd="mod-on"]')
            ok(esperar(lambda: glp("mod-on") == "true" and glp("quitar-palabra-todos") == "true", 10),
               "Activar: Activar=%r Quitar a todos=%r" % (glp("mod-on"), glp("quitar-palabra-todos")))

            print("[9. errores: el boton no miente]")
            ok(esperar(lambda: txt(id1, "audio").startswith("Dar la palabra"), 10), "B1: '%s'" % txt(id1, "audio"))
            a.evaluate("() => { window.__orig = window.__api.executeCommand;"
                       " window.__api.executeCommand = function () { throw new Error('fallo simulado'); }; }")
            bot(id1, "audio").click()
            time.sleep(1)
            ok("ERROR askToUnmute: fallo simulado" in log(), "executeCommand lanza: ERROR en #log")
            ok(txt(id1, "audio").startswith("Dar la palabra") and at(id1, "audio", "aria-busy") is None,
               "  el boton sigue en su estado real: '%s'" % txt(id1, "audio"))
            a.evaluate("() => { window.__api.executeCommand = function () {}; }")
            bot(id1, "audio").click()
            ok(esperar(lambda: txt(id1, "audio") == "Enviando…" and at(id1, "audio", "aria-busy") == "true", 3),
               "orden sin respuesta: 'Enviando…' (aria-busy)")
            ok(esperar(lambda: txt(id1, "audio").startswith("Dar la palabra"), 9),
               "  a los 6 s vuelve al estado real: '%s'" % txt(id1, "audio"))
            ok("sin confirmar en 6 s" in log(), "  AVISO en #log")
            a.evaluate("() => { window.__api.executeCommand = window.__orig; }")
            captura("9-final")
            print("  #log (ultimas lineas):\n" + "\n".join("     | " + l for l in log().strip().splitlines()[:14]))
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
    print("=== %s ===" % ("OK" if not FALLOS else "%d FALLO(S)" % len(FALLOS)))
    for f in FALLOS:
        print("  - " + f)
    return 1 if FALLOS else 0


if __name__ == "__main__":
    sys.exit(main())
