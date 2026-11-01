#!/usr/bin/env python3
"""
verificar-panel-local.py - Verificacion con sesion del panel (SPEC-DISENO 6.4)

Construye la imagen del admin-panel (del arbol de trabajo o de un ref de git),
la arranca en un contenedor local con un admin.env de prueba (contrasena
conocida) y recorre TODO el flujo con sesion: login, crear reunion, panel, QR,
pagina publica, /unirse, sala, eliminar, logout. Por cada pagina extrae el
"contrato" (ids, forms con method/action/names, csrf, botones .gl, scripts,
marcadores sin sustituir, referencias externas) y lo imprime en texto estable
para comparar antes/despues con diff.

Uso:
  scripts/verificar-panel-local.py                  # arbol de trabajo
  scripts/verificar-panel-local.py --ref 0782429    # un commit (linea base)
  scripts/verificar-panel-local.py --keep           # deja el contenedor vivo
  scripts/verificar-panel-local.py --base http://127.0.0.1:18090  # ya arrancado

Salida: texto en stdout. Codigo 0 si no hay FALLO, 1 si lo hay.
"""
import argparse
import hashlib
import html.parser
import http.cookiejar
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSWORD = "prueba-local-123"
USER = "Hguaza76"
API_KEY = "k" * 40
PUB = "meet.urbcerroazul.com"
# Commit anterior al rediseno: referencia para el diff del <script> de la sala.
BASE_REF_SALA = "0782429"

FALLOS = []


def fallo(msg):
    FALLOS.append(msg)
    print("  FALLO: " + msg)


# --------------------------------------------------------------------------
# HTTP sin seguir redirecciones, con cookies
# --------------------------------------------------------------------------
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


class Cliente:
    def __init__(self, base):
        self.base = base.rstrip("/")
        self.jar = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(
            NoRedirect, urllib.request.HTTPCookieProcessor(self.jar))

    def req(self, method, path, data=None, headers=None):
        body = None
        h = {"User-Agent": "verificar-panel-local"}
        if headers:
            h.update(headers)
        if data is not None:
            if isinstance(data, dict):
                body = urllib.parse.urlencode(data).encode()
                h.setdefault("Content-Type", "application/x-www-form-urlencoded")
            else:
                body = data
        r = urllib.request.Request(self.base + path, data=body, method=method, headers=h)
        try:
            resp = self.op.open(r, timeout=20)
        except urllib.error.HTTPError as e:
            resp = e
        raw = resp.read()
        return resp.status if hasattr(resp, "status") else resp.code, dict(resp.headers), raw

    def get(self, path):
        return self.req("GET", path)

    def post(self, path, data, headers=None):
        return self.req("POST", path, data, headers)


# --------------------------------------------------------------------------
# Arbol HTML minimo (para ancestros: forms y .gl)
# --------------------------------------------------------------------------
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr"}


class Nodo:
    def __init__(self, tag, attrs, padre):
        self.tag = tag
        self.attrs = dict(attrs)
        self.padre = padre
        self.hijos = []
        self.texto = []

    def clases(self):
        return (self.attrs.get("class") or "").split()

    def ancestros(self):
        n = self.padre
        while n is not None:
            yield n
            n = n.padre

    def todos(self):
        yield self
        for h in self.hijos:
            yield from h.todos()

    def text(self):
        return "".join(self.texto) + "".join(h.text() for h in self.hijos)


class Arbol(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.raiz = Nodo("#root", [], None)
        self.cur = self.raiz
        self.scripts_inline = []
        self._en_script = False

    def handle_starttag(self, tag, attrs):
        n = Nodo(tag, attrs, self.cur)
        self.cur.hijos.append(n)
        if tag not in VOID:
            self.cur = n
        if tag == "script" and not n.attrs.get("src"):
            self._en_script = True
            self.scripts_inline.append("")

    def handle_startendtag(self, tag, attrs):
        n = Nodo(tag, attrs, self.cur)
        self.cur.hijos.append(n)

    def handle_endtag(self, tag):
        if tag == "script":
            self._en_script = False
        if tag in VOID:
            return
        n = self.cur
        while n is not None and n.tag != tag:
            n = n.padre
        if n is not None and n.padre is not None:
            self.cur = n.padre

    def handle_data(self, data):
        if self._en_script:
            self.scripts_inline[-1] += data
        self.cur.texto.append(data)


def parse(raw):
    a = Arbol()
    a.feed(raw.decode("utf-8", "replace"))
    return a


MARCADORES = ["<!--ERR-->", "<!--LISTA-->", "<!--AVISO_JWT-->", "<!--DESC-->"]
IDS_SALA = ["jitsi", "lista", "cnt", "log", "st-audio", "st-video"]


def contrato(nombre, st, raw, esperado_st=200, sala=False):
    """Imprime el contrato de una pagina en formato estable."""
    print("--- %s -> HTTP %s ---" % (nombre, st))
    if st != esperado_st:
        fallo("%s: HTTP %s (esperado %s)" % (nombre, st, esperado_st))
    txt = raw.decode("utf-8", "replace")
    a = parse(raw)
    nodos = list(a.raiz.todos())
    ids = sorted({n.attrs["id"] for n in nodos if n.attrs.get("id")})
    print("  ids:          %s" % ids)
    forms = [n for n in nodos if n.tag == "form"]
    print("  forms:        %d" % len(forms))
    for f in forms:
        names = sorted(m.attrs.get("name") for m in f.todos()
                       if m.tag in ("input", "textarea", "select", "button") and m.attrs.get("name"))
        csrf = [m for m in f.todos() if m.tag == "input" and m.attrs.get("name") == "csrf"]
        csrf_txt = ""
        if csrf:
            csrf_txt = " csrf=" + ("presente" if csrf[0].attrs.get("value") else "VACIO")
            if not csrf[0].attrs.get("value"):
                fallo("%s: csrf vacio en form %s" % (nombre, f.attrs.get("action")))
        act = f.attrs.get("action")
        act = re.sub(r"/reunion/\d+/", "/reunion/<id>/", act) if act else "(sin action)"
        print("    form method=%s action=%s names=%s%s" % (
            (f.attrs.get("method") or "get").lower(), act, names, csrf_txt))
        # Campos fuera del form que deberian estar dentro: no se detecta aqui,
        # pero los names por form lo reflejan.
    nbtn = len([n for n in nodos if n.tag == "button"])
    print("  buttons:      %d" % nbtn)
    ext = sorted({n.attrs["src"] for n in nodos if n.tag == "script" and n.attrs.get("src")})
    print("  scripts src:  %s" % ext)
    print("  scripts inl:  %d" % len(a.scripts_inline))
    css = sorted({n.attrs["href"].split("?")[0] for n in nodos
                  if n.tag == "link" and "stylesheet" in (n.attrs.get("rel") or "")})
    print("  stylesheets:  %s" % css)
    n_style = len([n for n in nodos if n.tag == "style"])
    n_style_attr = len([n for n in nodos if "style" in n.attrs])
    print("  <style>:      %d   style=\"\": %d" % (n_style, n_style_attr))
    # Marcadores sin sustituir
    resto = [m for m in MARCADORES if m in txt]
    llaves = re.findall(r"\{\{[^}]*\}\}", txt)
    print("  marcadores:   %s" % (resto + llaves if (resto or llaves) else "ninguno"))
    for m in resto + llaves:
        if m == "<!--DESC-->":
            continue  # bug H8 conocido hasta D2
        fallo("%s: marcador sin sustituir %s" % (nombre, m))
    # Referencias externas: src/href absolutos a otros dominios
    externos = set()
    for n in nodos:
        for at in ("src", "href", "action"):
            v = n.attrs.get(at) or ""
            if re.match(r"^(https?:)?//", v):
                host = urllib.parse.urlparse(v if not v.startswith("//") else "https:" + v).hostname
                if host != PUB:
                    externos.add(v)
    print("  externos:     %s" % (sorted(externos) or "ninguno"))
    for v in externos:
        fallo("%s: referencia externa %s" % (nombre, v))
    if sala:
        faltan = [i for i in IDS_SALA if i not in ids]
        print("  ids sala:     %s" % ("todos" if not faltan else "FALTAN " + str(faltan)))
        if faltan:
            fallo("sala: faltan ids " + str(faltan))
        gl = [n for n in nodos if "gl" in n.clases()]
        btns = [b for g in gl for b in g.todos() if b.tag == "button"]
        cmds = sorted(b.attrs.get("data-cmd") or "(SIN data-cmd)" for b in btns)
        print("  .gl buttons:  %d %s" % (len(btns), cmds))
        if len(gl) != 1 or len(btns) != 6 or "(SIN data-cmd)" in cmds:
            fallo("sala: .gl debe tener exactamente 6 botones con data-cmd")
        jitsi = [n for n in nodos if n.attrs.get("id") == "jitsi"]
        if jitsi and jitsi[0].hijos:
            fallo("sala: #jitsi no esta vacio")
    print()
    return a


# --------------------------------------------------------------------------
# Comprobaciones de ficheros (sin servidor)
# --------------------------------------------------------------------------
def script_sala(texto):
    """Ultimo bloque <script> en linea de page_sala.html (el de moderacion)."""
    bloques = re.findall(r"<script>\n(.*?)</script>", texto, re.S)
    return bloques[-1] if bloques else None


def comprobar_ficheros(app_dir):
    print("=== FICHEROS ===")
    sala = open(os.path.join(app_dir, "page_sala.html"), encoding="utf-8").read()
    try:
        base = subprocess.run(["git", "-C", REPO, "show", BASE_REF_SALA + ":admin-panel/app/page_sala.html"],
                              capture_output=True, text=True, check=True).stdout
        a, b = script_sala(base), script_sala(sala)
        igual = a is not None and a == b
        print("  script sala vs %s: %s" % (BASE_REF_SALA, "IDENTICO" if igual else "DISTINTO"))
        if not igual:
            fallo("el <script> de page_sala.html cambio respecto a " + BASE_REF_SALA)
    except subprocess.CalledProcessError:
        print("  script sala: no se pudo leer el ref base")
    css = os.path.join(app_dir, "static", "theme.css")
    if os.path.exists(css):
        c = open(css, encoding="utf-8").read()
        print("  theme.css:    %d bytes" % len(c))
        if re.search(r"url\(\s*['\"]?https?:", c) or "@import" in c:
            fallo("theme.css tiene url(http...) o @import")
        else:
            print("  theme.css sin url(http) ni @import: OK")
        bloques = re.findall(r"/\* SYNC-DARK:begin \*/(.*?)/\* SYNC-DARK:end \*/", c, re.S)
        decl = [dict(re.findall(r"(--[\w-]+)\s*:\s*([^;]+);", b)) for b in bloques]
        if len(decl) == 2 and decl[0] == decl[1] and decl[0]:
            print("  SYNC-DARK:    2 bloques identicos (%d tokens)" % len(decl[0]))
        else:
            fallo("SYNC-DARK: bloques ausentes o distintos (%d)" % len(decl))
        # Colores literales fuera del bloque de tokens (criterio 8)
        cuerpo = c.split("/* FIN-TOKENS */", 1)[-1] if "/* FIN-TOKENS */" in c else ""
        lit = sorted(set(re.findall(r"#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)", cuerpo)))
        print("  colores literales fuera de tokens: %s" % (lit or "ninguno"))
    else:
        print("  theme.css:    no existe")
    js = os.path.join(app_dir, "static", "theme.js")
    if os.path.exists(js):
        print("  theme.js:     %d bytes" % os.path.getsize(js))
    for f in sorted(os.listdir(app_dir)):
        if f.endswith(".html"):
            t = open(os.path.join(app_dir, f), encoding="utf-8").read()
            print("  %-18s <style>=%d style=\"\"=%d" % (f, t.count("<style"), len(re.findall(r"\sstyle=", t))))
    print()


# --------------------------------------------------------------------------
# Contenedor
# --------------------------------------------------------------------------
def preparar_contexto(ref):
    if not ref:
        return os.path.join(REPO, "admin-panel"), None
    tmp = tempfile.mkdtemp(prefix="vpl-")
    arch = subprocess.run(["git", "-C", REPO, "archive", ref, "admin-panel"], capture_output=True, check=True)
    subprocess.run(["tar", "-x", "-C", tmp], input=arch.stdout, check=True)
    return os.path.join(tmp, "admin-panel"), tmp


def arrancar(ctx, port, nombre):
    tag = "jitsi-admin:verif-local"
    subprocess.run(["docker", "build", "-q", "-t", tag, ctx], check=True, capture_output=True)
    inst = tempfile.mkdtemp(prefix="vpl-inst-")
    with open(os.path.join(inst, "admin.env"), "w") as f:
        f.write("JITSI_ADMIN_PASSWORD_HASH=" + hashlib.sha256(PASSWORD.encode()).hexdigest() + "\n")
        f.write("FLASK_SECRET_KEY=" + secrets.token_hex(32) + "\n")
        f.write("JITSI_API_KEY=" + API_KEY + "\n")
    os.chmod(inst, 0o777)
    subprocess.run(["docker", "rm", "-f", nombre], capture_output=True)
    subprocess.run(["docker", "run", "-d", "--name", nombre, "-p", "127.0.0.1:%d:8081" % port,
                    "-v", inst + ":/app/instance", "-e", "JITSI_ENV_FILE=/nonexistent", tag],
                   check=True, capture_output=True)
    base = "http://127.0.0.1:%d" % port
    for _ in range(40):
        try:
            urllib.request.urlopen(base + "/healthz", timeout=2)
            return base
        except Exception:
            time.sleep(0.5)
    raise SystemExit("el contenedor no responde")


# --------------------------------------------------------------------------
# Recorrido
# --------------------------------------------------------------------------
def csrf_de(a, action=None):
    for f in (n for n in a.raiz.todos() if n.tag == "form"):
        if action and f.attrs.get("action") != action:
            continue
        for m in f.todos():
            if m.tag == "input" and m.attrs.get("name") == "csrf":
                return m.attrs.get("value")
    return None


def recorrido(base, rate_limit=True):
    c = Cliente(base)
    print("=== HTTP ===")
    st, h, raw = c.get("/healthz")
    print("  /healthz -> %s %s" % (st, sorted(json.loads(raw).keys())))
    st, h, _ = c.get("/admin")
    print("  /admin sin sesion -> %s %s" % (st, h.get("Location", "").replace(base, "")))

    st, h, _ = c.get("/admin/static/theme.css")
    print("  /admin/static/theme.css -> %s %s" % (st, h.get("Content-Type", "")))
    st, h, _ = c.get("/admin/static/theme.js")
    print("  /admin/static/theme.js  -> %s %s" % (st, h.get("Content-Type", "")))
    print()

    st, h, raw = c.get("/admin/login")
    contrato("login", st, raw)
    st, h, raw = c.post("/admin/login", {"user": USER, "password": "mala"})
    a = contrato("login (error)", st, raw)
    err = "incorrect" in a.raiz.text()
    print("  error visible: %s\n" % ("si" if err else "NO"))
    if not err:
        fallo("login: no se ve el mensaje de error")

    st, h, _ = c.post("/admin/login?next=/admin", {"user": USER, "password": PASSWORD})
    print("  login OK con ?next=/admin -> %s %s" % (st, h.get("Location", "").replace(base, "")))
    if st != 302 or not h.get("Location", "").endswith("/admin"):
        fallo("login correcto no redirige a ?next")

    st, h, raw = c.get("/admin")
    a = contrato("panel (vacio)", st, raw)
    csrf = csrf_de(a, "/admin/reunion")
    st, h, _ = c.post("/admin/reunion", {"titulo": "x", "fecha": "2030-01-01", "hora": "19:00"})
    print("  crear sin csrf -> %s" % st)
    if st != 403:
        fallo("crear sin csrf no da 403")
    st, h, _ = c.post("/admin/reunion", {"csrf": csrf, "titulo": "", "fecha": "2030-01-01", "hora": "19:00"})
    print("  crear sin titulo -> %s" % st)
    if st != 400:
        fallo("crear sin titulo no da 400")
    st, h, _ = c.post("/admin/reunion", {
        "csrf": csrf, "titulo": "Asamblea <b>ordinaria</b> noviembre & \"cía\"",
        "descripcion": "Orden del día: 1. Verificación del quórum <script>x</script>",
        "fecha": "2030-11-05", "hora": "19:00", "duracion": "60"})
    print("  crear futura -> %s %s" % (st, h.get("Location", "").replace(base, "")))
    if st != 302:
        fallo("crear reunion futura")
    st, h, _ = c.post("/admin/reunion", {"csrf": csrf, "titulo": "Reunión pasada",
                                          "fecha": "2020-01-01", "hora": "08:00", "duracion": "30"})
    print("  crear pasada -> %s %s" % (st, h.get("Location", "").replace(base, "")))
    print()

    st, h, raw = c.get("/admin")
    a = contrato("panel (2 reuniones)", st, raw)
    txt = raw.decode()
    print("  'UTC UTC' en el panel: %s" % ("SI" if "UTC UTC" in txt else "no"))
    print("  <b> sin escapar en titulos: %s" % ("SI" if "<b>ordinaria</b>" in txt else "no"))
    if "<b>ordinaria</b>" in txt:
        fallo("XSS: titulo sin escapar en el panel")
    slugs = []
    for s in re.findall(r"/reunion/([a-z0-9-]{6,})", txt):
        if s not in slugs:
            slugs.append(s)
    print("  slugs en el panel: %d" % len(slugs))
    print()

    st, h, raw = c.get("/admin/qr/1")
    contrato("qr", st, raw)
    st, h, raw = c.get("/admin/qr/1?format=png")
    print("  qr png -> %s %s %s\n" % (st, h.get("Content-Type"), "PNG" if raw[:4] == b"\x89PNG" else "?"))

    # slugs[0] es la mas reciente por fecha (2030) = la futura
    slug_fut = slugs[0] if slugs else "x"
    slug_pas = slugs[1] if len(slugs) > 1 else "x"
    pub = Cliente(base)  # residente, sin sesion
    st, h, raw = pub.get("/reunion/" + slug_fut)
    a = contrato("reunion publica", st, raw)
    txt = raw.decode()
    print("  descripcion visible: %s" % ("si" if "Verificaci" in txt else "no"))
    print("  <script> de la descripcion sin escapar: %s\n" % ("SI" if "<script>x" in txt else "no"))
    if "<script>x" in txt:
        fallo("XSS: descripcion sin escapar")
    st, h, raw = pub.get("/reunion/noexiste")
    contrato("reunion no encontrada", st, raw, esperado_st=404)
    st, h, _ = pub.post("/unirse", {"slug": slug_fut, "apto": "302", "nombre": "Ana"})
    loc = h.get("Location", "")
    ok = st == 302 and loc.startswith("https://" + PUB + "/asamblea-") and "#jwt=" in loc
    print("  /unirse futura -> %s %s" % (st, "jitsi#jwt OK" if ok else loc[:60]))
    if not ok:
        fallo("/unirse no redirige a Jitsi con jwt")
    st, h, _ = pub.post("/unirse", {"slug": slug_fut, "apto": "", "nombre": ""})
    print("  /unirse sin nombre -> %s" % st)
    st, h, raw = pub.post("/unirse", {"slug": slug_pas, "apto": "", "nombre": "Ana"})
    contrato("reunion finalizada (/unirse)", st, raw, esperado_st=410)

    st, h, raw = c.get("/admin/reunion/1/sala")
    contrato("sala", st, raw, sala=True)
    st, h, raw = c.get("/admin/reunion/2/sala")
    print("  sala de reunion pasada -> %s" % st)
    st, h, _ = c.get("/admin/reunion/1/entrar")
    print("  entrar -> %s %s" % (st, "jitsi#jwt" if "#jwt=" in h.get("Location", "") else "?"))
    st, h, raw = c.get("/admin/reunion/1/moderador.json")
    print("  moderador.json -> %s %s" % (st, sorted(json.loads(raw).keys()) if st == 200 else ""))
    st, h, _ = c.post("/api/reuniones/1/token", b"{}", {"Content-Type": "application/json"})
    print("  api token sin auth -> %s" % st)
    print()

    st, h, raw = c.get("/admin")
    a = parse(raw)
    csrf_del = csrf_de(a, "/admin/reunion/2/eliminar")
    print("  csrf del form eliminar: %s" % ("presente" if csrf_del else "AUSENTE"))
    st, h, _ = c.post("/admin/reunion/2/eliminar", {"csrf": "malo"})
    print("  eliminar con csrf malo -> %s" % st)
    st, h, _ = c.post("/admin/reunion/2/eliminar", {"csrf": csrf_del or ""})
    print("  eliminar -> %s %s" % (st, h.get("Location", "").replace(base, "")))
    if st != 302:
        fallo("eliminar reunion")
    st, h, raw = c.get("/admin")
    print("  reunion 2 sigue en el panel: %s" % ("SI" if "/admin/qr/2" in raw.decode() else "no"))
    st, h, _ = c.post("/admin/logout", {})
    print("  logout -> %s %s" % (st, h.get("Location", "").replace(base, "")))
    st, h, _ = c.get("/admin")
    print("  /admin tras logout -> %s" % st)

    # Rate limit (la IP de este cliente ya lleva 1 fallo + 1 OK = 2 intentos).
    # Con --keep se omite: bloquearia 15 min el login de las capturas.
    if not rate_limit:
        print("  rate limit: omitido (--keep)\n")
        return
    ult = None
    for _ in range(5):
        st, h, raw = c.post("/admin/login", {"user": USER, "password": "mala"})
        ult = raw.decode()
    print("  rate limit tras 7 intentos: %s" % ("mensaje visible" if "Demasiados intentos" in ult else "NO"))
    print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", help="ref de git a construir (por defecto: arbol de trabajo)")
    ap.add_argument("--base", help="URL de un panel ya arrancado (no construye)")
    ap.add_argument("--port", type=int, default=18090)
    ap.add_argument("--keep", action="store_true", help="no borrar el contenedor al terminar")
    args = ap.parse_args()
    nombre = "jitsi-admin-verif"
    print("=== VERIFICACION LOCAL DEL PANEL (%s) ===\n" % (args.ref or args.base or "arbol de trabajo"))
    ctx, tmp = preparar_contexto(args.ref)
    comprobar_ficheros(os.path.join(ctx, "app"))
    base = args.base
    try:
        if not base:
            base = arrancar(ctx, args.port, nombre)
        recorrido(base, rate_limit=not args.keep)
    finally:
        if not args.base and not args.keep:
            subprocess.run(["docker", "rm", "-f", nombre], capture_output=True)
        if tmp:
            subprocess.run(["rm", "-rf", tmp])
    print("=== RESULTADO: %s ===" % ("OK" if not FALLOS else "%d FALLO(S)" % len(FALLOS)))
    for f in FALLOS:
        print("  - " + f)
    if args.keep and not args.base:
        print("contenedor '%s' vivo en %s (usuario %s / %s)" % (nombre, base, USER, PASSWORD))
    sys.exit(1 if FALLOS else 0)


if __name__ == "__main__":
    main()
