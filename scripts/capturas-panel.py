#!/usr/bin/env python3
"""
capturas-panel.py - Capturas del panel a 360/768/1280 px en claro y oscuro.

Se usa contra el contenedor local que deja vivo
`scripts/verificar-panel-local.py --keep` (o cualquier panel con la
contrasena de prueba). Crea las reuniones de muestra que falten, bloquea
TODA peticion que no vaya al propio panel (asi se comprueba tambien que no
hay dependencias externas: se listan las bloqueadas) y genera, por pagina y
tema, un montaje con los tres anchos lado a lado.

Uso:
  scripts/capturas-panel.py --base http://127.0.0.1:18090 --out /tmp/capturas/paso1
"""
import argparse
import os
import re
import sys
from datetime import datetime, timedelta, timezone

from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright

USER = "Hguaza76"
PASSWORD = "prueba-local-123"
ANCHOS = [360, 768, 1280]
TEMAS = ["light", "dark"]

# DOM igual al que crea pintar() en page_sala.html (mismas clases y orden).
# Solo para la captura: el JS real no se toca ni se ejecuta (Jitsi bloqueado).
MOCK_SALA = r"""
() => {
  function boton(t, c){ var b=document.createElement('button'); b.type='button'; b.textContent=t; if(c) b.className=c; return b; }
  var cont = document.getElementById('lista'); cont.textContent = '';
  document.getElementById('cnt').textContent = '(3)';
  document.getElementById('st-audio').textContent = 'ACTIVA';
  document.getElementById('st-video').textContent = 'apagada';
  [['Apto 302 - Ana María Rodríguez Peñaloza', 1], ['Apto 504 - Luis', 0], ['Carlos', 0]].forEach(function(x){
    var d=document.createElement('div'); d.className='p';
    var n=document.createElement('div'); n.className='n';
    if (x[1]) { var m=document.createElement('span'); m.className='mano'; m.textContent='[mano] '; n.appendChild(m); }
    n.appendChild(document.createTextNode(x[0])); d.appendChild(n);
    d.appendChild(boton('Pedir la palabra','ok2')); d.appendChild(boton('Silenciar','d'));
    d.appendChild(boton('Habilitar camara','')); d.appendChild(boton('Apagar camara','d'));
    cont.appendChild(d);
  });
  var log = document.getElementById('log');
  log.textContent = '10:41:02  toggleModeration(true, "audio")\n10:41:01  unido como Administracion (ab12cd)\n';
}
"""


def login(page, base):
    page.goto(base + "/admin/login")
    page.fill("input[name=user]", USER)
    page.fill("input[name=password]", PASSWORD)
    page.click("button[type=submit]")
    page.wait_for_load_state()


def asegurar_reuniones(page, base):
    """Crea 3 reuniones de muestra si no existen (proxima, en curso, pasada)."""
    page.goto(base + "/admin")
    html = page.content()
    if "Asamblea ordinaria noviembre" in html and "Consejo en curso" in html:
        return
    col = datetime.now(timezone.utc) - timedelta(hours=5)
    muestras = [
        ("Asamblea ordinaria noviembre", "Orden del día: 1. Verificación del quórum. 2. Lectura del acta anterior. "
         "3. Informe de administración. 4. Proposiciones y varios.", "2030-11-05", "19:00", "60"),
        ("Consejo en curso", "", col.strftime("%Y-%m-%d"), (col - timedelta(minutes=10)).strftime("%H:%M"), "90"),
        ("Reunión del comité de convivencia con un título muy largo para probar el recorte", "",
         "2026-10-28", "18:30", "90"),
    ]
    for t, d, f, h, dur in muestras:
        page.goto(base + "/admin")
        page.fill("[name=titulo]", t)
        page.fill("[name=descripcion]", d)
        page.fill("[name=fecha]", f)
        page.fill("[name=hora]", h)
        page.fill("[name=duracion]", dur)
        page.eval_on_selector("form[action='/admin/reunion']", "f => f.submit()")
        page.wait_for_load_state()


def ids_y_slugs(page, base):
    page.goto(base + "/admin")
    html = page.content()
    qr = re.findall(r"/admin/qr/(\d+)", html)
    slugs = []
    for s in re.findall(r"/reunion/([a-z0-9-]{6,})", html):
        if s not in slugs:
            slugs.append(s)
    return (qr[0] if qr else "1"), (slugs[0] if slugs else "x")


def montaje(rutas, destino, etiqueta):
    imgs = [Image.open(r) for r in rutas]
    alto = max(i.height for i in imgs)
    ancho = sum(i.width for i in imgs) + 40 * (len(imgs) - 1)
    m = Image.new("RGB", (ancho, alto + 30), (128, 128, 128))
    x = 0
    for i in imgs:
        m.paste(i, (x, 30))
        x += i.width + 40
    ImageDraw.Draw(m).text((8, 8), etiqueta, fill=(255, 255, 255))
    # Limitar a un tamano razonable para revisarlo
    maxh = 4000
    if m.height > maxh:
        m = m.crop((0, 0, m.width, maxh))
    m.save(destino)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:18090")
    ap.add_argument("--out", required=True)
    ap.add_argument("--solo", help="lista de paginas separadas por coma")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    base = args.base
    bloqueadas = set()

    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx0 = b.new_context()
        pg = ctx0.new_page()
        login(pg, base)
        asegurar_reuniones(pg, base)
        rid, slug = ids_y_slugs(pg, base)
        estado = ctx0.storage_state()
        ctx0.close()

        paginas = [
            ("login", "/admin/login", False, None),
            ("login-error", "/admin/login", False, "error"),
            ("panel", "/admin", True, None),
            ("panel-menu", "/admin", True, "menu"),
            ("panel-dialogo", "/admin", True, "dialogo"),
            ("qr", "/admin/qr/" + rid, True, None),
            ("publica", "/reunion/" + slug, False, None),
            ("noencontrada", "/reunion/noexiste", False, None),
            ("finalizada", "/reunion/" + slug, False, "finalizada"),
            ("sala-cargando", "/admin/reunion/" + rid + "/sala", True, None),
            ("sala", "/admin/reunion/" + rid + "/sala", True, "mock"),
        ]
        if args.solo:
            paginas = [x for x in paginas if x[0] in args.solo.split(",")]

        for nombre, ruta, con_sesion, accion in paginas:
            for tema in TEMAS:
                rutas = []
                for w in ANCHOS:
                    ctx = b.new_context(viewport={"width": w, "height": 900}, color_scheme=tema,
                                        storage_state=estado if con_sesion else None,
                                        device_scale_factor=1)

                    def filtro(route):
                        u = route.request.url
                        if u.startswith(base):
                            route.continue_()
                        else:
                            bloqueadas.add(u.split("?")[0])
                            route.abort()
                    ctx.route("**/*", filtro)
                    page = ctx.new_page()
                    if accion == "error":
                        page.goto(base + ruta)
                        page.fill("input[name=user]", "x")
                        page.fill("input[name=password]", "x")
                        page.click("button[type=submit]")
                        page.wait_for_load_state()
                    elif accion == "finalizada":
                        # 410: /unirse con el slug de una reunion pasada real
                        page.goto(base + ruta)
                        page.fill("[name=nombre]", "Ana")
                        page.evaluate("""(s) => { document.querySelector("[name=slug]").value = s; }""",
                                      args_pasada(base, estado, b))
                        page.eval_on_selector("form[action='/unirse']", "f => f.submit()")
                        page.wait_for_load_state()
                    else:
                        page.goto(base + ruta)
                        page.wait_for_load_state()
                    if accion == "menu":
                        page.evaluate("""() => { var d=document.querySelector('details.menu'); if (d) d.open = true; }""")
                    if accion == "dialogo":
                        el = page.query_selector("button[data-confirm]")
                        if el:
                            page.evaluate("""() => { var d=document.querySelector('.list details.menu'); if (d) d.open=true; }""")
                            el.click()
                    if accion == "mock":
                        page.evaluate(MOCK_SALA)
                    page.wait_for_timeout(250)
                    # Desbordamiento horizontal
                    sw = page.evaluate("document.documentElement.scrollWidth")
                    if sw > w:
                        print("AVISO scroll horizontal: %s %s %dpx -> scrollWidth %d" % (nombre, tema, w, sw))
                    r = os.path.join(args.out, "%s-%s-%d.png" % (nombre, tema, w))
                    page.screenshot(path=r, full_page=True)
                    rutas.append(r)
                    ctx.close()
                montaje(rutas, os.path.join(args.out, "M-%s-%s.png" % (nombre, tema)),
                        "%s / %s / 360 768 1280" % (nombre, tema))
                print("ok", nombre, tema)
        b.close()
    print("peticiones externas bloqueadas:", sorted(bloqueadas) or "ninguna")


_PASADA = {}


def args_pasada(base, estado, b):
    """Slug de una reunion pasada (la crea si hace falta), para la pagina 410."""
    if "slug" in _PASADA:
        return _PASADA["slug"]
    ctx = b.new_context(storage_state=estado)
    pg = ctx.new_page()
    pg.goto(base + "/admin")
    html = pg.content()
    m = re.search(r"Reuni[oó]n pasada para 410.*?/reunion/([a-z0-9-]{6,})", html, re.S)
    if not m:
        pg.fill("[name=titulo]", "Reunión pasada para 410")
        pg.fill("[name=fecha]", "2020-01-01")
        pg.fill("[name=hora]", "08:00")
        pg.eval_on_selector("form[action='/admin/reunion']", "f => f.submit()")
        pg.wait_for_load_state()
        pg.goto(base + "/admin")
        html = pg.content()
        m = re.search(r"Reuni[oó]n pasada para 410.*?/reunion/([a-z0-9-]{6,})", html, re.S)
    ctx.close()
    _PASADA["slug"] = m.group(1) if m else "x"
    return _PASADA["slug"]


if __name__ == "__main__":
    sys.exit(main())
