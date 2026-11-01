#!/usr/bin/env python3
"""
probar-interacciones.py - Pruebas de comportamiento del rediseno en un navegador.

Contra el contenedor local (scripts/verificar-panel-local.py --keep). Cada
prueba imprime OK/FALLO. Cubre: tema (persistencia, sin parpadeo, ciclo del
pie), menu (Esc devuelve el foco, clic fuera), skip link, foco visible,
tamanos minimos, dialogo de eliminar (Cancelar no borra, Esc, confirmar
borra), confirm() nativo sin JS, estado de carga y doble envio en /unirse,
contrato de la sala con JS de theme.js activo.

Uso: scripts/probar-interacciones.py [--base URL] [--solo grupo,grupo]
"""
import argparse
import re
import sys

from playwright.sync_api import sync_playwright

USER, PASSWORD = "Hguaza76", "prueba-local-123"
FALLOS = []


def ok(cond, msg):
    print(("  OK     " if cond else "  FALLO  ") + msg)
    if not cond:
        FALLOS.append(msg)


def login(page, base):
    page.goto(base + "/admin/login")
    page.fill("input[name=user]", USER)
    page.fill("input[name=password]", PASSWORD)
    page.click("button[type=submit]")
    page.wait_for_load_state()


def solo_local(ctx, base):
    ctx.route("**/*", lambda r: r.continue_() if r.request.url.startswith(base) else r.abort())


def tema(b, base, estado):
    print("[tema]")
    ctx = b.new_context(color_scheme="light", storage_state=estado)
    solo_local(ctx, base)
    p = ctx.new_page()
    p.goto(base + "/admin")
    bg = p.evaluate("getComputedStyle(document.body).backgroundColor")
    ok(bg == "rgb(245, 245, 247)", "auto + sistema claro -> fondo #F5F5F7 (%s)" % bg)
    p.click("summary.menu__trigger")
    p.click("[data-theme-set=dark]")
    ok(p.evaluate("localStorage.getItem('ca-tema')") == "dark", "Oscuro guarda ca-tema=dark")
    ok(p.evaluate("document.documentElement.dataset.theme") == "dark", "data-theme=dark aplicado")
    tc = p.evaluate("[...document.querySelectorAll('meta[name=theme-color]')].map(m=>m.content).join(',')")
    ok(tc == "#000000,#000000", "theme-color actualizado (%s)" % tc)
    # Sin parpadeo: data-theme ya esta puesto antes de que exista <body>
    p.add_init_script("""document.addEventListener('readystatechange',()=>{},{once:true});
      new MutationObserver((m,o)=>{ if(document.body){ window.__temaAlPintar=document.documentElement.dataset.theme; o.disconnect(); } })
        .observe(document,{childList:true,subtree:true});""")
    p.goto(base + "/admin/qr/1")
    ok(p.evaluate("window.__temaAlPintar") == "dark", "tema aplicado antes del <body> (sin parpadeo)")
    bg = p.evaluate("getComputedStyle(document.body).backgroundColor")
    ok(bg == "rgb(0, 0, 0)", "persiste entre paginas: fondo negro (%s)" % bg)
    pressed = p.evaluate("document.querySelector('[data-theme-set=dark]').getAttribute('aria-pressed')")
    ok(pressed == "true", "segmentado marca Oscuro (aria-pressed)")
    p.click("summary.menu__trigger")
    p.click("[data-theme-set=auto]")
    ok(p.evaluate("localStorage.getItem('ca-tema')") is None, "Auto borra ca-tema")
    # Ciclo del pie en pagina publica
    p.goto(base + "/admin/login")
    lab = lambda: p.inner_text(".theme-cycle [data-theme-label]")  # noqa: E731
    ok(lab() == "Automático", "pie: Automático")
    p.click(".theme-cycle")
    ok(lab() == "Claro" and p.evaluate("document.documentElement.dataset.theme") == "light", "pie: -> Claro")
    p.click(".theme-cycle")
    ok(lab() == "Oscuro", "pie: -> Oscuro")
    p.click(".theme-cycle")
    ok(lab() == "Automático" and p.evaluate("localStorage.getItem('ca-tema')") is None, "pie: -> Automático")
    al = p.get_attribute(".theme-cycle", "aria-label") or ""
    ok("automático" in al, "aria-label anuncia el estado (%s)" % al)
    # localStorage bloqueado: no rompe
    ctx2 = b.new_context(storage_state=estado)
    solo_local(ctx2, base)
    p2 = ctx2.new_page()
    p2.add_init_script("Object.defineProperty(window,'localStorage',{get(){throw new Error('bloqueado')}})")
    errores = []
    p2.on("pageerror", lambda e: errores.append(str(e)))
    p2.goto(base + "/admin")
    p2.click("summary.menu__trigger")
    p2.click("[data-theme-set=dark]")
    ok(not errores, "localStorage bloqueado: sin errores JS (%s)" % errores[:1])
    ctx2.close()
    ctx.close()


def menu(b, base, estado):
    print("[menu, foco, skip link]")
    ctx = b.new_context(storage_state=estado, viewport={"width": 1280, "height": 900})
    solo_local(ctx, base)
    p = ctx.new_page()
    p.goto(base + "/admin")
    p.keyboard.press("Tab")
    ok(p.evaluate("document.activeElement.className") == "skip-link", "primer Tab: skip link")
    vis = p.evaluate("document.activeElement.getBoundingClientRect().top >= 0")
    ok(vis, "skip link visible con foco")
    p.keyboard.press("Enter")
    ok(p.evaluate("location.hash") == "#contenido", "skip link lleva a #contenido")
    p.focus("summary.menu__trigger")
    p.keyboard.press("Enter")
    ok(p.evaluate("document.querySelector('header details.menu').open"), "menu se abre con Enter")
    p.keyboard.press("Escape")
    ok(not p.evaluate("document.querySelector('header details.menu').open"), "Esc cierra el menu")
    ok(p.evaluate("document.activeElement.matches('summary.menu__trigger')"), "Esc devuelve el foco al boton")
    p.click("summary.menu__trigger")
    p.mouse.click(5, 600)
    ok(not p.evaluate("document.querySelector('header details.menu').open"), "clic fuera cierra el menu")
    p.focus("summary.menu__trigger")
    oc = p.evaluate("getComputedStyle(document.activeElement).outlineStyle + ' ' + getComputedStyle(document.activeElement).outlineWidth")
    ok(oc.startswith("solid 3px"), "foco visible: anillo de 3px (%s)" % oc)
    ctx.close()


def tamanos(b, base, estado):
    print("[tamanos y desbordamiento]")
    rutas = ["/admin/login", "/admin", "/admin/qr/1", "/admin/reunion/1/sala"]
    for w in (360, 768, 1280):
        ctx = b.new_context(storage_state=estado, viewport={"width": w, "height": 800}, has_touch=(w == 360),
                            is_mobile=(w == 360))
        solo_local(ctx, base)
        p = ctx.new_page()
        pub = re.search(r"/reunion/([a-z0-9-]{6,})", (p.goto(base + "/admin") and p.content())).group(1)
        for r in rutas + ["/reunion/" + pub]:
            p.goto(base + r)
            sw = p.evaluate("document.documentElement.scrollWidth")
            ok(sw <= w, "%4dpx %-26s sin scroll horizontal (%d)" % (w, r[:26], sw))
            if w == 360:
                peq = p.evaluate("""[...document.querySelectorAll('body *')].filter(e=>e.offsetParent&&e.childNodes.length&&
                    [...e.childNodes].some(n=>n.nodeType===3&&n.textContent.trim())&&parseFloat(getComputedStyle(e).fontSize)<12)
                    .map(e=>e.tagName+'.'+e.className+':'+getComputedStyle(e).fontSize).slice(0,5)""")
                ok(not peq, "%s texto >= 12px %s" % (r[:26], peq))
                cam = p.evaluate("""[...document.querySelectorAll('input:not([type=hidden]),textarea,select')]
                    .filter(e=>parseFloat(getComputedStyle(e).fontSize)<16).map(e=>e.name)""")
                ok(not cam, "%s campos >= 16px (anti-zoom iOS) %s" % (r[:26], cam))
                bt = p.evaluate("""[...document.querySelectorAll('button,a.btn,summary.btn,input[type=submit]')]
                    .filter(e=>e.offsetParent && !e.closest('.skip-link') && e.offsetHeight < 44)
                    .map(e=>(e.textContent||'').trim().slice(0,20)+':'+e.offsetHeight)""")
                ok(not bt, "%s controles >= 44px en tactil %s" % (r[:26], bt[:4]))
        ctx.close()


def etiquetas(p, nombre):
    """Cada label[for] enfoca su campo al pulsarla; todos los campos visibles tienen label."""
    sin = p.evaluate("""[...document.querySelectorAll('input:not([type=hidden]),textarea,select')]
        .filter(e=>!e.labels||!e.labels.length).map(e=>e.name)""")
    ok(not sin, "%s: todos los campos tienen <label> asociada %s" % (nombre, sin))
    for f in p.evaluate("[...document.querySelectorAll('label[for]')].map(l=>l.htmlFor)"):
        p.click("label[for='%s']" % f)
        ok(p.evaluate("document.activeElement.id") == f, "%s: pulsar la etiqueta enfoca #%s" % (nombre, f))


def login_g(b, base, estado):
    print("[login]")
    ctx = b.new_context(viewport={"width": 360, "height": 740}, is_mobile=True, has_touch=True)
    solo_local(ctx, base)
    p = ctx.new_page()
    p.goto(base + "/admin/qr/1")
    ok("/admin/login?next=/admin/qr/1" in p.url, "sin sesion -> login con ?next (%s)" % p.url.replace(base, ""))
    ok(p.evaluate("document.querySelector('form').hasAttribute('action')") is False, "form de login sin action")
    ok(p.evaluate("document.activeElement.name") == "user", "autofocus en usuario")
    ac = p.evaluate("[...document.querySelectorAll('input')].map(i=>i.name+'='+i.autocomplete).join(' ')")
    ok(ac == "user=username password=current-password", "autocomplete (%s)" % ac)
    etiquetas(p, "login")
    p.fill("[name=user]", USER)
    p.fill("[name=password]", "mala")
    p.click("button[type=submit]")
    p.wait_for_load_state()
    al = p.query_selector(".alert--error[role=alert]")
    ok(al is not None and "contraseña incorrectos" in al.inner_text(), "error como alert--error role=alert")
    ok("next=/admin/qr/1" in p.url, "tras el error se conserva ?next")
    p.fill("[name=user]", USER)
    p.fill("[name=password]", PASSWORD)
    with p.expect_navigation():
        p.click("button[type=submit]")
    ok(p.url.endswith("/admin/qr/1"), "login correcto vuelve a ?next (%s)" % p.url.replace(base, ""))
    ctx.close()
    ctx = b.new_context()
    solo_local(ctx, base)
    p = ctx.new_page()
    p.goto(base + "/admin/login")
    # El listener de theme.js corre primero; este cancela la navegacion para poder mirar el boton.
    p.evaluate("document.querySelector('form').addEventListener('submit', e => e.preventDefault())")
    p.fill("[name=user]", "x")
    p.fill("[name=password]", "x")
    p.click("button[type=submit]")
    p.wait_for_timeout(200)
    st = p.evaluate("(b=>b.getAttribute('aria-busy')+'/'+b.disabled)(document.querySelector('[type=submit]'))")
    ok(st == "true/true", "al enviar: aria-busy y disabled (%s)" % st)
    ctx.close()


def slug_publico(b, base, estado, titulo="Asamblea ordinaria noviembre"):
    ctx = b.new_context(storage_state=estado)
    p = ctx.new_page()
    p.goto(base + "/admin")
    html = p.content()
    ctx.close()
    i = html.find(titulo)
    m = re.search(r"/reunion/([a-z0-9-]{6,})", html[i:] if i >= 0 else html)
    return m.group(1) if m else "x"


def publica(b, base, estado):
    print("[pagina publica del residente]")
    slug = slug_publico(b, base, estado)
    ctx = b.new_context(viewport={"width": 360, "height": 740}, is_mobile=True, has_touch=True)
    solo_local(ctx, base)
    p = ctx.new_page()
    p.goto(base + "/reunion/" + slug)
    txt = p.inner_text("main")
    ok("UTC" not in txt, "no se muestra 'UTC' al residente")
    ok(bool(re.search(r"(lun|mar|mié|jue|vie|sáb|dom) \d+ \w+ · \d+:\d\d\s[ap]\.\sm\.", txt)),
       "fecha en hora de Colombia (%s)" % re.findall(r"\w+ \d+ \w+ · [^\n]+", txt)[:1])
    etiquetas(p, "publica")
    h = p.evaluate("document.querySelector('button[type=submit]').offsetHeight")
    ok(h >= 52, "boton principal >= 52px (%s)" % h)
    w = p.evaluate("document.querySelector('button[type=submit]').offsetWidth / document.querySelector('form').offsetWidth")
    ok(w > 0.99, "boton a ancho completo")
    ac = p.evaluate("[...document.querySelectorAll('input:not([type=hidden])')].map(i=>i.name+'='+i.autocomplete+'/'+i.enterKeyHint).join(' ')")
    ok(ac == "apto=off/ nombre=name/go", "autocomplete y enterkeyhint (%s)" % ac)
    ok(p.query_selector(".alert--info") is not None, "aviso de micro/camara como alert--info")
    posts = []
    p.on("request", lambda r: posts.append(r.url) if r.method == "POST" and r.url.endswith("/unirse") else None)
    p.fill("[name=nombre]", "Ana")
    p.evaluate("""() => { var b=document.querySelector('[type=submit]'); b.click(); b.click(); b.click(); }""")
    p.wait_for_timeout(1500)
    ok(len(posts) == 1, "triple toque en 'Entrar' -> %d POST /unirse (debe ser 1)" % len(posts))
    ctx.close()
    ctx = b.new_context(viewport={"width": 360, "height": 740})
    p = ctx.new_page()
    r = p.goto(base + "/reunion/noexiste")
    ok(r.status == 404 and p.inner_text("h1") == "Reunión no encontrada", "404 con estado vacio y h1")
    ok(p.title() == "Reunión no encontrada · Cerro Azul", "titulo de pestana del 404 (%s)" % p.title())
    ctx.close()


def crear(p, base, titulo, fecha, hora, dur="60"):
    p.goto(base + "/admin")
    p.fill("[name=titulo]", titulo)
    p.fill("[name=fecha]", fecha)
    p.fill("[name=hora]", hora)
    p.fill("[name=duracion]", dur)
    with p.expect_navigation():
        p.click("form[action='/admin/reunion'] button[type=submit]")
    return p.url


def fila(p, titulo):
    return p.locator(".list__item", has=p.locator(".list__title", has_text=titulo))


def panel_g(b, base, estado):
    print("[panel, D3, menu por reunion, dialogo de eliminar]")
    from datetime import datetime, timedelta, timezone
    col = datetime.now(timezone.utc) - timedelta(hours=5)
    ctx = b.new_context(storage_state=estado, viewport={"width": 1280, "height": 900})
    solo_local(ctx, base)
    p = ctx.new_page()
    u = crear(p, base, "Prueba en curso", col.strftime("%Y-%m-%d"), (col - timedelta(minutes=5)).strftime("%H:%M"))
    ok("/admin/qr/" in u, "crear reunion desde el formulario -> QR (%s)" % u.replace(base, ""))
    crear(p, base, "Prueba pasada", "2021-03-04", "18:30")
    crear(p, base, "Prueba a borrar", "2031-01-02", "10:00")
    p.goto(base + "/admin")
    etiquetas(p, "panel")
    ok(fila(p, "Prueba en curso").locator(".badge--success").inner_text() == "En curso", "D3: En curso")
    ok(fila(p, "Prueba pasada").locator(".badge").inner_text() == "Finalizada", "D3: Finalizada")
    ok(fila(p, "Prueba a borrar").locator(".badge--info").inner_text() == "Próxima", "D3: Próxima")
    t = fila(p, "Prueba pasada")
    ok(t.locator(".datetile__month").inner_text().lower() == "mar" and t.locator(".datetile__day").inner_text() == "4",
       "baldosa de fecha MAR 4")
    ok("jue 4 mar · 6:30 p. m. · 60 min" in t.locator(".list__meta").inner_text().replace(chr(160), " "),
       "meta en hora de Colombia")
    ok(p.evaluate("getComputedStyle(document.querySelector('.panel__form')).position") == "sticky",
       "1280px: formulario fijo (sticky) a la derecha")
    ok(not p.is_visible(".panel__nueva"), "1280px: boton 'Nueva reunion' oculto")
    # Menu de la fila con teclado
    f = fila(p, "Prueba a borrar")
    f.locator("summary").focus()
    p.keyboard.press("Enter")
    ok(f.locator("details.menu").evaluate("d => d.open"), "menu de la fila se abre con Enter")
    hrefs = f.locator(".menu__item[href]").evaluate_all(r"as => as.map(a => a.getAttribute('href').replace(/reunion\/[a-z0-9-]{6,}$/, 'reunion/<slug>'))")
    ok(len(hrefs) == 2 and hrefs[0].endswith("/reunion/<slug>") and hrefs[1].endswith("/entrar"),
       "menu: Pagina publica y Entrar como administrador (%s)" % hrefs)
    p.keyboard.press("Escape")
    # Dialogo: Cancelar
    f.locator("summary").click()
    f.locator("button[data-confirm]").click()
    dlg = p.locator("dialog.dialog")
    ok(dlg.evaluate("d => d.open"), "Eliminar abre el dialogo (no confirm nativo)")
    ok(p.evaluate("document.activeElement.value") == "cancel", "foco inicial en Cancelar")
    ok("Prueba a borrar" in dlg.inner_text(), "el dialogo nombra la reunion")
    ok(not f.locator("details.menu").evaluate("d => d.open"), "el menu se cierra al abrir el dialogo")
    p.click("dialog button[value=cancel]")
    p.wait_for_timeout(300)
    ok(f.count() == 1 and not dlg.evaluate("d => d.open"), "Cancelar cierra y NO elimina")
    # Esc
    f.locator("summary").click()
    f.locator("button[data-confirm]").click()
    p.keyboard.press("Escape")
    p.wait_for_timeout(300)
    p.reload()
    ok(fila(p, "Prueba a borrar").count() == 1, "Esc cierra y NO elimina")
    # Confirmar
    f = fila(p, "Prueba a borrar")
    f.locator("summary").click()
    f.locator("button[data-confirm]").click()
    with p.expect_navigation():
        p.click("dialog button[value=ok]")
    ok(p.url.endswith("/admin") and fila(p, "Prueba a borrar").count() == 0, "Eliminar en el dialogo borra y vuelve al panel")
    ctx.close()
    # Respaldo: theme.js no carga -> confirm() nativo
    ctx = b.new_context(storage_state=estado)
    ctx.route("**/*", lambda r: r.abort() if ("theme.js" in r.request.url or not r.request.url.startswith(base)) else r.continue_())
    p = ctx.new_page()
    crear(p, base, "Prueba confirm nativo", "2031-02-03", "10:00")
    p.goto(base + "/admin")
    vistos = []
    p.once("dialog", lambda d: (vistos.append(d.message), d.dismiss()))
    f = fila(p, "Prueba confirm nativo")
    f.locator("summary").click()
    f.locator("button[data-confirm]").click()
    p.wait_for_timeout(300)
    p.reload()
    ok(vistos == ["¿Eliminar esta reunión?"] and fila(p, "Prueba confirm nativo").count() == 1,
       "sin theme.js: confirm() nativo; Cancelar no borra (%s)" % vistos)
    p.once("dialog", lambda d: d.accept())
    f = fila(p, "Prueba confirm nativo")
    f.locator("summary").click()
    with p.expect_navigation():
        f.locator("button[data-confirm]").click()
    ok(fila(p, "Prueba confirm nativo").count() == 0, "sin theme.js: Aceptar borra")
    ctx.close()
    # Movil: lista primero, boton ancla
    ctx = b.new_context(storage_state=estado, viewport={"width": 360, "height": 740}, is_mobile=True, has_touch=True)
    solo_local(ctx, base)
    p = ctx.new_page()
    p.goto(base + "/admin")
    y_lista = p.evaluate("document.querySelector('.panel__lista').getBoundingClientRect().top")
    y_form = p.evaluate("document.querySelector('#nueva').getBoundingClientRect().top")
    ok(y_lista < y_form, "360px: la lista va antes que el formulario")
    p.click(".panel__nueva")
    p.wait_for_timeout(300)
    ok(p.evaluate("location.hash") == "#nueva" and p.evaluate("document.querySelector('#nueva').getBoundingClientRect().top") < 200,
       "360px: 'Nueva reunion' lleva al formulario")
    ctx.close()


def qr_g(b, base, estado):
    print("[qr]")
    ctx = b.new_context(storage_state=estado, viewport={"width": 768, "height": 900}, color_scheme="dark")
    solo_local(ctx, base)
    p = ctx.new_page()
    p.goto(base + "/admin/qr/1")
    bg = p.evaluate("getComputedStyle(document.querySelector('.qrcard')).backgroundColor")
    ok(bg == "rgb(255, 255, 255)", "tarjeta del QR blanca tambien en oscuro (%s)" % bg)
    ok(p.evaluate("document.querySelector('.qrcard__img').naturalWidth") > 0, "imagen del QR cargada")
    ok(p.evaluate("getComputedStyle(document.querySelector('.qrcard__img')).imageRendering") == "pixelated", "QR nitido (pixelated)")
    cols = p.evaluate("getComputedStyle(document.querySelector('.qrview')).gridTemplateColumns.split(' ').length")
    ok(cols == 2, "768px: QR en dos columnas")
    p.click("#f-link")
    sel = p.evaluate("(e => e.value.substring(e.selectionStart, e.selectionEnd))(document.querySelector('#f-link'))")
    ok(sel.startswith("https://meet.urbcerroazul.com/reunion/"), "clic en el link lo selecciona")
    ok("UTC" not in p.inner_text("main"), "sin 'UTC' en la vista QR")
    ok(p.is_visible("button[data-copy]"), "boton Copiar visible (con JS)")
    ctx.grant_permissions(["clipboard-read", "clipboard-write"], origin=base)
    p.click("button[data-copy]")
    p.wait_for_timeout(200)
    clip = p.evaluate("navigator.clipboard.readText()")
    ok(clip == p.input_value("#f-link"), "Copiar pone el link en el portapapeles (%s)" % clip.replace(base, ""))
    ok(p.inner_text("[data-copy-label]") == "Copiado" and "copiado" in p.inner_text("[data-copy-status]"),
       "Copiar: confirma 'Copiado' y lo anuncia (aria-live)")
    p.wait_for_timeout(2200)
    ok(p.inner_text("[data-copy-label]") == "Copiar", "Copiar: vuelve al texto inicial")
    d = p.get_attribute("a[download]", "href")
    ok(d and d.endswith("?format=png") and ctx.request.get(base + d).headers["content-type"] == "image/png",
       "Descargar QR -> PNG")
    p.emulate_media(media="print")
    vis = p.evaluate("[...document.querySelectorAll('.appbar,.qrview__info,.footer')].every(e=>getComputedStyle(e).display==='none')")
    ok(vis and p.is_visible(".qrcard") and p.is_visible(".qrhead__fecha"), "impresion: solo titulo, fecha y QR")
    ctx.close()
    ctx = b.new_context(storage_state=estado, viewport={"width": 768, "height": 900}, java_script_enabled=False)
    solo_local(ctx, base)
    p = ctx.new_page()
    p.goto(base + "/admin/qr/1")
    ok(not p.is_visible("button[data-copy]"), "sin JS: Copiar oculto (queda seleccionar el link)")
    ctx.close()


# DOM que crea pintar() (mismas clases); Jitsi esta bloqueado en la prueba.
MOCK_LISTA = r"""
() => {
  function boton(t, c){ var b=document.createElement('button'); b.type='button'; b.textContent=t; if(c) b.className=c; return b; }
  var cont = document.getElementById('lista'); cont.textContent = '';
  [['Apto 302 - Ana', 1], ['Apto 504 - Luis', 0]].forEach(function(x){
    var d=document.createElement('div'); d.className='p';
    var n=document.createElement('div'); n.className='n';
    if (x[1]) { var m=document.createElement('span'); m.className='mano'; m.textContent='[mano] '; n.appendChild(m); }
    n.appendChild(document.createTextNode(x[0])); d.appendChild(n);
    d.appendChild(boton('Pedir la palabra','ok2')); d.appendChild(boton('Silenciar','d'));
    d.appendChild(boton('Habilitar camara','')); d.appendChild(boton('Apagar camara','d'));
    cont.appendChild(d);
  });
}
"""


def sala_g(b, base, estado):
    print("[sala: contrato JS y capa visual]")
    for w in (360, 1280):
        ctx = b.new_context(storage_state=estado, viewport={"width": w, "height": 900})
        solo_local(ctx, base)
        p = ctx.new_page()
        p.goto(base + "/admin/reunion/1/sala")
        ids = p.evaluate("['jitsi','lista','cnt','log','st-audio','st-video'].filter(i => !document.getElementById(i))")
        ok(not ids, "%dpx: ids del contrato presentes (faltan %s)" % (w, ids))
        cmds = p.evaluate("[...document.querySelectorAll('.gl button')].map(b => b.getAttribute('data-cmd'))")
        ok(sorted(cmds) == sorted(["mute-all-audio", "mute-all-video", "mod-on", "mod-off",
                                   "dar-palabra-todos", "quitar-palabra-todos"]),
           "%dpx: .gl contiene SOLO los 6 botones data-cmd" % w)
        ok(p.evaluate("[...document.querySelectorAll('.gl button')].every(b => b.getAttribute('aria-label'))"),
           "%dpx: botones globales con aria-label completo" % w)
        ok(p.locator("#lista .skeleton").count() == 3, "%dpx: esqueleto inicial en #lista" % w)
        ok(not p.evaluate("document.querySelector('.salahead details').open"), "%dpx: explicacion plegada" % w)
        cols = p.evaluate("getComputedStyle(document.querySelector('.sala')).gridTemplateColumns.split(' ').length")
        ok(cols == (2 if w >= 1024 else 1), "%dpx: %d columna(s) (video | panel)" % (w, cols))
        p.evaluate(MOCK_LISTA)
        bg = p.evaluate("[...document.querySelectorAll('#lista .p')].map(e => getComputedStyle(e).backgroundColor)")
        ok(bg[0] != bg[1], "%dpx: la fila con [mano] se destaca (%s)" % (w, bg))
        h = p.evaluate("Math.min(...[...document.querySelectorAll('#lista .p button, .gl button')].map(b => b.offsetHeight))")
        ok(h >= 32, "%dpx: botones de la sala >= 32px (%d)" % (w, h))
        sw = p.evaluate("document.documentElement.scrollWidth")
        ok(sw <= w, "%dpx: sin scroll horizontal con participantes (%d)" % (w, sw))
        ctx.close()


# Sustituto de external_api.js: registra executeCommand y permite emitir
# eventos. Asi el <script> REAL de la sala (sin tocar) se ejecuta contra el
# DOM rediseñado y se comprueba que cada boton sigue mandando su comando.
FAKE_API = r"""
window.__cmds = []; window.__mod = {audio: true, video: true};
window.JitsiMeetExternalAPI = function (domain, o) {
  window.__api = this; this.o = o; this.l = {};
  var f = document.createElement('iframe'); f.style.height = o.height + 'px'; f.style.width = o.width;
  o.parentNode.appendChild(f);
};
var P = JitsiMeetExternalAPI.prototype;
P.addListener = function (e, f) { (this.l[e] = this.l[e] || []).push(f); };
P.emit = function (e, d) { (this.l[e] || []).forEach(function (f) { f(d); }); };
P.executeCommand = function () { window.__cmds.push([].slice.call(arguments)); };
P.isModerationOn = function (m) { return Promise.resolve(!!window.__mod[m]); };
P.getRoomsInfo = function () { return Promise.resolve({rooms: [{isMainRoom: true, participants: [
  {id: 'yo1', displayName: 'Administracion'}, {id: 'b1', displayName: 'Apto 302 - Ana'}]}]}); };
"""


def sala_js_g(b, base, estado):
    print("[sala: el JS sin cambios funciona sobre el DOM nuevo (API de Jitsi simulado)]")
    ctx = b.new_context(storage_state=estado, viewport={"width": 1280, "height": 900})
    solo_local(ctx, base)
    ctx.route("**/external_api.js", lambda r: r.fulfill(status=200, content_type="application/javascript", body=FAKE_API))
    p = ctx.new_page()
    errores = []
    p.on("pageerror", lambda e: errores.append(str(e)))
    p.goto(base + "/admin/reunion/1/sala")
    ok(p.evaluate("!!window.__api"), "el script crea JitsiMeetExternalAPI")
    ok(p.evaluate("window.__api.o.parentNode.id") == "jitsi" and p.evaluate("window.__api.o.height") == 560,
       "parentNode #jitsi, height 560")
    ok(p.evaluate("document.querySelector('#jitsi iframe').offsetHeight") == 560, "iframe de 560px dentro de #jitsi")
    p.evaluate("window.__api.emit('videoConferenceJoined', {id: 'yo1', displayName: 'Administracion'})")
    p.wait_for_timeout(1800)
    c = p.evaluate("window.__cmds")
    ok(["toggleModeration", True, "audio"] in c and ["toggleModeration", True, "video"] in c,
       "al unirse activa la moderacion A/V")
    ok(p.inner_text("#st-audio") == "ACTIVA" and p.inner_text("#st-video") == "ACTIVA", "#st-audio/#st-video = ACTIVA")
    ok(p.locator("#lista .p").count() == 1 and "Apto 302 - Ana" in p.inner_text("#lista .p .n"),
       "#lista pinta al participante (div.p > div.n)")
    ok(p.inner_text("#cnt") == "(1)", "#cnt = (1)")
    p.evaluate("window.__api.emit('raiseHandUpdated', {id: 'b1', handRaised: 123})")
    ok(p.locator("#lista .p .mano").count() == 1 and p.inner_text("#lista .mano").startswith("[mano]"),
       "mano levantada: span.mano '[mano] '")
    bg = p.evaluate("getComputedStyle(document.querySelector('#lista .p')).backgroundColor")
    ok(bg != "rgba(0, 0, 0, 0)", "fila con mano destacada (%s)" % bg)
    esperado = {"Pedir la palabra": ["askToUnmute", "b1"], "Silenciar": ["muteRemoteParticipant", "b1", "audio"],
                "Habilitar camara": ["approveVideo", "b1"], "Apagar camara": ["muteRemoteParticipant", "b1", "video"]}
    for txt, cmd in esperado.items():
        p.evaluate("window.__cmds = []")
        p.locator("#lista .p button", has_text=txt).first.click()
        ok(p.evaluate("window.__cmds") == [cmd], "participante '%s' -> %s" % (txt, cmd))
    glob = {"mute-all-audio": [["muteEveryone", "audio"]], "mute-all-video": [["muteEveryone", "video"]],
            "mod-on": [["toggleModeration", True, "audio"], ["toggleModeration", True, "video"]],
            "mod-off": [["toggleModeration", False, "audio"], ["toggleModeration", False, "video"]],
            "dar-palabra-todos": [["toggleModeration", False, "audio"]],
            "quitar-palabra-todos": [["toggleModeration", True, "audio"]]}
    for dc, cmds in glob.items():
        p.evaluate("window.__cmds = []")
        p.click(".gl button[data-cmd='%s']" % dc)
        ok(p.evaluate("window.__cmds") == cmds, ".gl %s -> %s" % (dc, cmds))
    p.evaluate("window.__mod = {audio: false, video: true}")
    p.click(".gl button[data-cmd='dar-palabra-todos']")
    p.wait_for_timeout(1800)
    ok(p.inner_text("#st-audio") == "apagada", "tras 'Dar a todos' el estado de audio pasa a 'apagada'")
    ok("toggleModeration" in p.evaluate("document.getElementById('log').textContent"), "#log registra los comandos")
    p.evaluate("window.__api.emit('participantLeft', {id: 'b1'})")
    ok(p.inner_text("#lista > p.m") == "Nadie mas en la sala." and p.inner_text("#cnt") == "(0)",
       "sin participantes: p.m 'Nadie mas en la sala.'")
    ok(not errores, "sin errores de JS (%s)" % errores)
    ctx.close()


GRUPOS_EXTRA = {"login": login_g, "publica": publica, "panel": panel_g, "qr": qr_g, "sala": sala_g, "sala_js": sala_js_g}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:18090")
    ap.add_argument("--solo")
    args = ap.parse_args()
    grupos = {"tema": tema, "menu": menu, "tamanos": tamanos}
    extra = globals().get("GRUPOS_EXTRA", {})
    grupos.update(extra)
    sel = args.solo.split(",") if args.solo else list(grupos)
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        ctx = b.new_context()
        p = ctx.new_page()
        login(p, args.base)
        estado = ctx.storage_state()
        ctx.close()
        for g in sel:
            grupos[g](b, args.base, estado)
        b.close()
    print("=== %s ===" % ("OK" if not FALLOS else "%d FALLO(S)" % len(FALLOS)))
    sys.exit(1 if FALLOS else 0)


if __name__ == "__main__":
    main()
