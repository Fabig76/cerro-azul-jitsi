#!/usr/bin/env python3
"""
verificar-bajar-manos.py - Verificacion local del boton "Bajar todas las manos"
de la sala de moderacion (admin-panel/app/static/bajar-manos.js).

Pasos:
  1. Estaticos: node --check de bajar-manos.js y del script congelado de la
     sala (extraido de page_sala.html con los marcadores sustituidos);
     py_compile de app.py; contrato JS de la sala comparado con un ref de git
     (ids, botones .gl con data-cmd y script congelado identico).
  2. docker build de admin-panel/ y contenedor local con un admin.env de
     prueba (contrasena conocida, nada de secretos reales).
  3. HTTP: /healthz, /admin/login, /admin/static/theme.css, bajar-manos.js.
  4. Navegador (Playwright): login real, crear una reunion EN CURSO, comprobar
     que sale en la lista, abrir /admin/reunion/<id>/sala y probar el boton.

Por que un origen ficticio (https://sala.prueba): en produccion el panel y
Jitsi comparten origen y el boton depende de ello (lee APP.conference del
iframe). Para reproducirlo sin tocar produccion, Playwright sirve todo
https://sala.prueba: /admin* y /healthz se reenvian al contenedor local,
/external_api.js es el de la imagen jitsi/web:stable-11031 y la pagina del
iframe es un Jitsi SIMULADO que solo expone APP.conference.sendEndpointMessage
y APP.store (y anota las llamadas). Las manos levantadas se simulan
insertando en #lista lo mismo que pinta el script congelado (div.p > div.n >
span.mano): no hay participantes reales. Lo que NO valida: que la mano de
otra persona baje de verdad (eso exige dos clientes reales).

Escenarios del iframe simulado:
  ok          -> sendEndpointMessage existe: se envia el mensaje correcto
  sin-metodo  -> APP.conference sin el metodo: aviso claro, sala intacta
  tarde       -> APP aparece a los 1,2 s: el boton reintenta una vez y envia
  no-moderador-> rol "participant": no se envia y se avisa

Uso: scripts/verificar-bajar-manos.py [--ref HEAD] [--keep]
Codigo 0 si todo OK, 1 si hay algun FALLO.
"""
import argparse
import hashlib
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SALA_HTML = "admin-panel/app/page_sala.html"
JS = "admin-panel/app/static/bajar-manos.js"
TAG = "test-admin-bajar-manos"
NOMBRE = "test-admin-bajar-manos"
PUERTO = 18097
ORIGEN = "https://sala.prueba"
USER = "Hguaza76"
PASSWORD = "prueba-local-" + secrets.token_hex(4)
TZ_COL = timezone(timedelta(hours=-5))

# Contrato del script congelado (no puede cambiar) y clases que crea el JS.
IDS_CONTRATO = ["jitsi", "lista", "cnt", "log", "st-audio", "st-video"]
CLASES_JS = {"p", "n", "mano", "m", "ok2", "d"}

FALLOS = []


def ok(cond, msg):
    print(("  OK     " if cond else "  FALLO  ") + msg)
    if not cond:
        FALLOS.append(msg)
    return cond


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# --------------------------------------------------------------------------
# 1. Estaticos
# --------------------------------------------------------------------------
def script_congelado(html):
    s = re.findall(r"<script>\n(.*?)</script>", html, re.S)
    return s[0] if s else ""


def contrato(html):
    ids = re.findall(r'\bid="([^"]+)"', html)
    gl = re.search(r'<section class="[^"]*\bgl\b[^"]*".*?</section>', html, re.S)
    gl_btn = re.findall(r"<button\b[^>]*>", gl.group(0)) if gl else []
    gl_cmd = [re.search(r'data-cmd="([^"]*)"', b).group(1) if 'data-cmd="' in b else None for b in gl_btn]
    return ids, gl_cmd


def estaticos(ref):
    print("=== 1. Estaticos ===")
    r = sh(["node", "--check", os.path.join(REPO, JS)])
    ok(r.returncode == 0, "node --check bajar-manos.js " + r.stderr.strip())
    html = open(os.path.join(REPO, SALA_HTML)).read()
    js = script_congelado(html).replace("{{cfg_json}}", '{"domain":"x","roomName":"y","jwt":"z"}')
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(js)
    r = sh(["node", "--check", f.name])
    ok(r.returncode == 0 and len(js) > 1000, "node --check script congelado de la sala (%d bytes) %s"
       % (len(js), r.stderr.strip()))
    os.unlink(f.name)
    r = sh([sys.executable, "-m", "py_compile", os.path.join(REPO, "admin-panel/app/app.py")])
    ok(r.returncode == 0, "py_compile app.py " + r.stderr.strip())

    antes = sh(["git", "-C", REPO, "show", ref + ":" + SALA_HTML]).stdout
    ok(bool(antes), "page_sala.html en " + ref)
    ok(script_congelado(antes) == script_congelado(html), "script congelado IDENTICO a " + ref)
    ids_a, gl_a = contrato(antes)
    ids_d, gl_d = contrato(html)
    print("  ids antes  : " + " ".join(ids_a))
    print("  ids despues: " + " ".join(ids_d))
    print("  .gl data-cmd antes  : %s" % gl_a)
    print("  .gl data-cmd despues: %s" % gl_d)
    for i in IDS_CONTRATO:
        ok(ids_d.count(i) == 1, "id de contrato #%s presente una vez" % i)
    nuevos = [i for i in ids_d if i not in ids_a]
    ok(set(ids_a) <= set(ids_d), "no desaparece ningun id")
    ok(all(i.startswith("manos-") for i in nuevos), "ids nuevos con prefijo manos-: %s" % nuevos)
    ok(gl_a == gl_d and None not in gl_d, ".gl: mismos botones data-cmd y ninguno sin data-cmd")
    bloque = re.search(r'<div class="manos-barra">.*?</div>', html, re.S)
    clases = set(re.findall(r'class="([^"]*)"', bloque.group(0))[0].split()) if bloque else set()
    for c in re.findall(r'class="([^"]*)"', bloque.group(0) if bloque else ""):
        clases |= set(c.split())
    ok(bloque is not None and not (clases & CLASES_JS),
       "el bloque nuevo no usa clases del JS congelado (usa: %s)" % " ".join(sorted(clases)))
    print()


# --------------------------------------------------------------------------
# 2. Contenedor local
# --------------------------------------------------------------------------
def arrancar():
    print("=== 2. Imagen y contenedor ===")
    t = time.time()
    r = sh(["docker", "build", "-q", "-t", TAG, os.path.join(REPO, "admin-panel")])
    if not ok(r.returncode == 0, "docker build -t %s admin-panel/ (%.0f s) %s"
              % (TAG, time.time() - t, r.stdout.strip()[:19] or r.stderr[-300:])):
        sys.exit(1)
    inst = tempfile.mkdtemp(prefix="vbm-inst-")
    with open(os.path.join(inst, "admin.env"), "w") as f:
        f.write("JITSI_ADMIN_PASSWORD_HASH=" + hashlib.sha256(PASSWORD.encode()).hexdigest() + "\n")
        f.write("FLASK_SECRET_KEY=" + secrets.token_hex(32) + "\n")
        f.write("JITSI_API_KEY=" + secrets.token_hex(20) + "\n")
    # .env de prueba: solo el dominio publico, para que la sala apunte al
    # origen ficticio y el iframe sea del mismo origen que el panel.
    with open(os.path.join(inst, "jitsi.env"), "w") as f:
        f.write("PUBLIC_URL=" + ORIGEN.split("//")[1] + "\n")
        f.write("JWT_APP_SECRET=" + secrets.token_hex(16) + "\n")
    os.chmod(inst, 0o777)
    sh(["docker", "rm", "-f", NOMBRE])
    r = sh(["docker", "run", "-d", "--name", NOMBRE, "-p", "127.0.0.1:%d:8081" % PUERTO,
            "-v", inst + ":/app/instance", "-e", "JITSI_ENV_FILE=/app/instance/jitsi.env", TAG])
    ok(r.returncode == 0, "docker run " + r.stderr.strip())
    base = "http://127.0.0.1:%d" % PUERTO
    for _ in range(60):
        try:
            urllib.request.urlopen(base + "/healthz", timeout=2)
            break
        except Exception:
            time.sleep(0.5)
    print()
    return base


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def http(base, method, path, headers=None, body=None):
    req = urllib.request.Request(base + path, data=body, method=method, headers=headers or {})
    try:
        r = OPENER.open(req, timeout=15)
        return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def http_basico(base):
    print("=== 3. HTTP ===")
    for p, tipo in (("/healthz", ""), ("/admin/login", "text/html"), ("/admin/static/theme.css", "text/css"),
                    ("/admin/static/bajar-manos.js", "javascript")):
        st, h, _ = http(base, "GET", p)
        ok(st == 200 and tipo in h.get("Content-Type", ""), "%s -> %s %s" % (p, st, h.get("Content-Type", "")))
    print()


# --------------------------------------------------------------------------
# 4. Navegador
# --------------------------------------------------------------------------
STUB = """<!doctype html><meta charset="utf-8"><title>Jitsi simulado</title><body>Jitsi simulado (%(modo)s)
<script>
window.__enviados = [];
var modo = %(modo_js)s;
function montar() {
  var conference = {};
  if (modo !== "sin-metodo") {
    conference.sendEndpointMessage = function (to, payload) { window.__enviados.push([to, payload]); };
  }
  var rol = modo === "no-moderador" ? "participant" : "moderator";
  window.APP = { conference: conference,
                 store: { getState: function () { return { "features/base/participants": { local: { role: rol } } }; } } };
}
if (modo === "tarde") setTimeout(montar, 1200); else montar();
</script>"""


def external_api():
    r = subprocess.run(["docker", "run", "--rm", "--entrypoint", "cat", "jitsi/web:stable-11031",
                        "/usr/share/jitsi-meet/libs/external_api.min.js"], capture_output=True)
    if r.returncode != 0 or len(r.stdout) < 10000:
        sys.exit("no se pudo sacar external_api.min.js de jitsi/web:stable-11031")
    return r.stdout


def navegador(base):
    from playwright.sync_api import sync_playwright
    print("=== 4. Navegador (origen %s) ===" % ORIGEN)
    ext = external_api()
    estado = {"modo": "ok", "fuera": []}

    def ruta(route, request):
        try:
            _ruta(route, request)
        except Exception as e:   # sin esto Playwright deja pasar la peticion a la red
            print("  [ruta] %s %s -> %r" % (request.method, request.url, e))
            route.abort()

    def _ruta(route, request):
        url = request.url
        path = url[len(ORIGEN):] or "/"
        if path.startswith("/admin") or path.startswith("/healthz"):
            hdr = {k: v for k, v in request.headers.items() if k.lower() not in ("host", "content-length")}
            hdr["Host"] = ORIGEN.split("//")[1]
            hdr["X-Forwarded-Proto"] = "https"
            st, h, body = http(base, request.method, path, hdr, request.post_data_buffer)
            out = {}
            for k, v in h.items():
                if k.lower() in ("content-length", "transfer-encoding", "connection", "set-cookie"):
                    continue
                if k.lower() == "location":
                    v = v.replace(base, ORIGEN)
                out[k] = v
            sc = h.get_all("Set-Cookie") or []
            if sc:
                out["set-cookie"] = "\n".join(sc)
            loc = out.pop("Location", None) or out.pop("location", None)
            if 300 <= st < 400 and loc and request.resource_type == "document":
                # Chromium no vuelve a pasar por page.route la peticion de una
                # redireccion servida con fulfill (sale a la red: DNS falla).
                # Se sustituye por una pagina que navega al destino.
                out["Content-Type"] = "text/html"
                body = ('<meta http-equiv="refresh" content="0;url=%s">' % loc).encode()
                st = 200
            elif loc:
                out["Location"] = loc
            route.fulfill(status=st, headers=out, body=body)
        elif path.startswith("/external_api.js"):
            route.fulfill(status=200, content_type="application/javascript", body=ext)
        elif request.resource_type == "document":
            m = estado["modo"]
            route.fulfill(status=200, content_type="text/html",
                          body=STUB % {"modo": m, "modo_js": '"%s"' % m})
        else:
            route.fulfill(status=404, body="")

    with sync_playwright() as pw:
        b = pw.chromium.launch()
        ctx = b.new_context(ignore_https_errors=True)
        # Cualquier peticion fuera del origen ficticio se bloquea y se anota:
        # la prueba no debe tocar produccion ni Internet.
        ctx.route(re.compile(r"^(?!" + re.escape(ORIGEN) + r")https?://.*"),
                  lambda r, q: (estado["fuera"].append(q.url), r.abort()))
        ctx.route(ORIGEN + "/**", ruta)
        page = ctx.new_page()
        errores = []
        page.on("console", lambda m: m.type == "error" and errores.append(m.text))
        page.on("pageerror", lambda e: errores.append("pageerror: " + str(e)))

        # Login real
        page.goto(ORIGEN + "/admin/login")
        page.fill("input[name=user]", USER)
        page.fill("input[name=password]", PASSWORD)
        page.click("form button[type=submit], form input[type=submit]")
        page.wait_for_url(re.compile(r".*/admin/?$"), timeout=10000)
        r = page.goto(ORIGEN + "/admin")
        ok(r.status == 200 and "/admin/login" not in page.url, "login real -> /admin %s" % r.status)

        # Reunion EN CURSO (si no, la sala muestra "finalizada")
        ahora = datetime.now(TZ_COL) - timedelta(minutes=5)
        titulo = "Prueba bajar manos " + secrets.token_hex(2)
        res = page.evaluate("""async (d) => {
            const f = document.querySelector('form[action="/admin/reunion"] input[name=csrf]');
            const body = new URLSearchParams({csrf: f ? f.value : "", titulo: d.titulo, fecha: d.fecha,
                                              hora: d.hora, duracion: "120"});
            const r = await fetch("/admin/reunion", {method: "POST", body, redirect: "manual"});
            return r.type === "opaqueredirect" ? 302 : r.status;
        }""", {"titulo": titulo, "fecha": ahora.strftime("%Y-%m-%d"), "hora": ahora.strftime("%H:%M")})
        ok(res in (200, 302), "crear reunion en curso -> %s" % res)
        page.goto(ORIGEN + "/admin")
        html = page.content()
        ok(titulo in html, "la lista muestra la reunion creada")
        m = re.findall(r"/admin/reunion/(\d+)/sala", html)
        if not ok(bool(m), "enlace a la sala en el panel"):
            b.close()
            return
        sala = ORIGEN + "/admin/reunion/%s/sala" % m[0]

        def abrir(modo):
            estado["modo"] = modo
            errores.clear()
            r = page.goto(sala)
            page.wait_for_selector("#jitsi iframe", timeout=10000)
            page.wait_for_timeout(500)
            return r.status

        def simular_manos(n):
            page.evaluate("""(n) => {
                const l = document.getElementById("lista"); l.textContent = "";
                for (let i = 0; i < n; i++) {
                  const d = document.createElement("div"); d.className = "p";
                  const nn = document.createElement("div"); nn.className = "n";
                  const s = document.createElement("span"); s.className = "mano"; s.textContent = "[mano] ";
                  nn.appendChild(s); nn.appendChild(document.createTextNode("Vecino " + i));
                  d.appendChild(nn); l.appendChild(d);
                }}""", n)
            page.wait_for_timeout(100)

        def enviados():
            return page.frame_locator("#jitsi iframe").locator("body").evaluate("() => window.__enviados || null")

        log = lambda: page.inner_text("#log") if page.is_visible("#log") else page.eval_on_selector("#log", "e => e.textContent")
        aviso = lambda: page.inner_text("#manos-estado")

        # --- ok ---
        print("  -- escenario ok --")
        st = abrir("ok")
        ok(st == 200, "sala -> %s" % st)
        ok(page.is_visible("h2#sala-pa-t") and page.is_visible("#lista"), "el panel de moderacion carga")
        bt = page.locator("#manos-bajar")
        ok(bt.is_visible() and bt.inner_text().strip() == "Bajar todas las manos", "el boton aparece: '%s'" % bt.inner_text().strip())
        ok(bt.is_disabled(), "sin manos el boton esta deshabilitado ('%s')" % aviso())
        dentro_lista = page.evaluate("() => !!document.querySelector('#lista #manos-bajar, .gl #manos-bajar')")
        ok(not dentro_lista, "el boton esta fuera de #lista y de .gl")
        simular_manos(3)
        ok(bt.is_enabled() and aviso() == "3 manos levantadas.", "con 3 manos: habilitado ('%s')" % aviso())
        bt.click()
        page.wait_for_timeout(400)
        env = enviados()
        ok(env == [["", {"name": "lower-hand-message"}]], "iframe recibio sendEndpointMessage%s" % env)
        ok("enviado lower-hand-message" in log(), "el #log registra el envio")
        ok(aviso() == "Orden enviada.", "aviso tras enviar: '%s'" % aviso())
        simular_manos(0)   # lo que haria el script congelado al llegar raiseHandUpdated
        page.wait_for_timeout(5200)
        ok("ya no queda ninguna mano" in log(), "comprobacion a los 5 s en el #log")
        ok(bt.is_disabled(), "sin manos vuelve a deshabilitarse")
        ok(not errores, "consola sin errores %s" % errores)
        print("  #log:\n" + "\n".join("     | " + l for l in log().strip().splitlines()))

        # --- sin-metodo ---
        print("  -- escenario sin-metodo --")
        abrir("sin-metodo")
        simular_manos(1)
        page.locator("#manos-bajar").click()
        page.wait_for_timeout(2600)   # incluye el reintento
        ok("esta versión de Jitsi no lo permite" in aviso(), "aviso: '%s'" % aviso())
        ok("ERROR bajar todas las manos" in log(), "el #log registra el error")
        ok(page.locator("#manos-bajar").is_enabled(), "el boton sigue usable tras el fallo")
        ok(page.is_visible("#jitsi iframe") and page.locator(".gl button[data-cmd]").count() == 6,
           "la sala sigue intacta (iframe y 6 botones .gl)")
        ok(not errores, "consola sin errores %s" % errores)

        # --- tarde ---
        print("  -- escenario tarde (iframe aun cargando) --")
        estado["modo"] = "tarde"
        errores.clear()
        page.goto(sala)
        page.wait_for_selector("#jitsi iframe")
        simular_manos(2)
        page.locator("#manos-bajar").click()
        page.wait_for_timeout(2800)
        ok("reintento en 2 s" in log() and "al reintentar" in log(), "reintenta una vez y envia")
        ok(enviados() == [["", {"name": "lower-hand-message"}]], "enviado tras el reintento %s" % enviados())
        ok(not errores, "consola sin errores %s" % errores)

        # --- no-moderador ---
        print("  -- escenario no-moderador --")
        abrir("no-moderador")
        simular_manos(1)
        page.locator("#manos-bajar").click()
        page.wait_for_timeout(400)
        ok("no eres moderador" in aviso() and enviados() == [], "no envia y avisa: '%s'" % aviso())
        ok(not errores, "consola sin errores %s" % errores)

        ok(not estado["fuera"], "ninguna peticion fuera del origen de prueba %s" % estado["fuera"][:3])
        b.close()
    print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default="HEAD", help="ref de git con el que comparar el contrato")
    ap.add_argument("--keep", action="store_true", help="no borrar el contenedor al acabar")
    a = ap.parse_args()
    estaticos(a.ref)
    base = arrancar()
    try:
        http_basico(base)
        navegador(base)
    finally:
        if not a.keep:
            sh(["docker", "rm", "-f", NOMBRE])
    print("RESULTADO: " + ("OK" if not FALLOS else "%d FALLO(S)" % len(FALLOS)))
    for f in FALLOS:
        print("  - " + f)
    sys.exit(1 if FALLOS else 0)


if __name__ == "__main__":
    main()
