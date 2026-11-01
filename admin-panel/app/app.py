#!/usr/bin/env python3
"""Panel admin Jitsi - Cerro Azul"""
import os
import io
import json
import sqlite3
import hashlib
import secrets
import logging
from datetime import datetime, timezone, timedelta
from functools import wraps
from flask import (
    Flask, request, session, redirect, url_for,
    render_template_string, send_file, jsonify, abort
)
import jwt as pyjwt
import qrcode
from PIL import Image

# Rutas configurables por variable de entorno (ver Dockerfile).
# Los defaults son los paths dentro del contenedor.
ENV_FILE = os.environ.get("JITSI_ENV_FILE", "/opt/jitsi-meet/.env")
ADMIN_ENV_FILE = os.environ.get("ADMIN_ENV_FILE", "/app/instance/admin.env")
DB_PATH = os.environ.get("DB_PATH", "/app/instance/reuniones.db")
LOG_FILE = os.environ.get("LOG_FILE", "/app/instance/app.log")
TPL_DIR = os.environ.get("TPL_DIR", "/app")

def load_kv(path):
    env = {}
    if not os.path.exists(path):
        return env
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env

E = load_kv(ENV_FILE)
A = load_kv(ADMIN_ENV_FILE)

SK = E.get("APP_SECRET") or secrets.token_hex(32)
KID = E.get("JWT_APP_ID") or "jitsi-admin-panel"
KSEC = E.get("JWT_APP_SECRET") or SK
PUB = E.get("PUBLIC_URL") or "meet.urbcerroazul.com"

def csv_list(v):
    return [x.strip() for x in (v or "").split(",") if x.strip()]

# --- JWT (Fase 2) -------------------------------------------------------
# Prosody valida 'iss' contra asap_accepted_issuers (JWT_ACCEPTED_ISSUERS)
# y 'aud' contra asap_accepted_audiences (JWT_ACCEPTED_AUDIENCES). Si el
# panel firma con otro valor, Jitsi rechaza el token: es el fallo clasico.
# Por eso iss/aud se derivan de esas MISMAS variables del .env de Jitsi.
# Si no estan (stack de Fase 1), Prosody acepta iss == app_id y cualquier
# aud, asi que el fallback es KID (compatibilidad con el comportamiento previo).
ACCEPTED_ISS = csv_list(E.get("JWT_ACCEPTED_ISSUERS"))
ACCEPTED_AUD = csv_list(E.get("JWT_ACCEPTED_AUDIENCES"))
JWT_ISS = A.get("JWT_ISSUER") or (ACCEPTED_ISS[0] if ACCEPTED_ISS else KID)
JWT_AUD = A.get("JWT_AUDIENCE") or (ACCEPTED_AUD[0] if ACCEPTED_AUD else KID)
# Margen de 'nbf' hacia atras: tolera relojes desfasados entre panel y Prosody.
JWT_NBF_SKEW = 60
# El token vence al fin previsto de la reunion + este margen.
JWT_EXP_MARGIN_MIN = int(A.get("JWT_EXP_MARGIN_MIN") or "30")
# Prefijo de las salas nuevas (el resto son 16 hex aleatorios).
SALA_PREFIX = A.get("SALA_PREFIX") or "asamblea-"

def jwt_config_problems():
    """Lista de incoherencias panel <-> Prosody que harian fallar los tokens."""
    probs = []
    # Lo que Prosody acepta realmente (defaults de token/util.lib.lua).
    pros_iss = ACCEPTED_ISS or [KID]
    pros_aud = ACCEPTED_AUD or ["*"]
    if JWT_ISS not in pros_iss:
        probs.append("iss='" + JWT_ISS + "' no esta en JWT_ACCEPTED_ISSUERS=" + ",".join(pros_iss))
    if JWT_AUD not in pros_aud and "*" not in pros_aud:
        probs.append("aud='" + JWT_AUD + "' no esta en JWT_ACCEPTED_AUDIENCES=" + ",".join(pros_aud))
    if not E.get("JWT_APP_SECRET"):
        probs.append("JWT_APP_SECRET no esta en " + ENV_FILE + ": los tokens se firman con una clave que Prosody no conoce")
    # Prosody decide con PROSODY_AUTH_TYPE; AUTH_TYPE es solo su fallback.
    auth_type = E.get("PROSODY_AUTH_TYPE") or E.get("AUTH_TYPE") or ""
    if E.get("ENABLE_AUTH", "0") not in ("1", "true") or auth_type != "jwt":
        probs.append("Jitsi no exige JWT (ENABLE_AUTH=" + E.get("ENABLE_AUTH", "") +
                     ", PROSODY_AUTH_TYPE efectivo=" + auth_type + "): las salas estan abiertas")
    return probs

app = Flask(__name__)
app.secret_key = A.get("FLASK_SECRET_KEY") or SK
app.permanent_session_lifetime = timedelta(hours=4)

ADMIN_USER = os.environ.get("ADMIN_USER", "Hguaza76")
ADMIN_PWD_HASH = A.get("JITSI_ADMIN_PASSWORD_HASH")

logging.basicConfig(level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ])
log = logging.getLogger("jitsi-admin")

JWT_PROBLEMS = jwt_config_problems()
for _p in JWT_PROBLEMS:
    log.error("CONFIG JWT: " + _p)
log.info("JWT iss=" + JWT_ISS + " aud=" + JWT_AUD + " app_id=" + KID)

def db():
    c = sqlite3.connect(DB_PATH)
    c.row_factory = sqlite3.Row
    return c

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS reuniones (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            slug TEXT UNIQUE NOT NULL,
            titulo TEXT NOT NULL,
            descripcion TEXT,
            fecha_utc TEXT NOT NULL,
            duracion_min INTEGER DEFAULT 60,
            sala_jitsi TEXT UNIQUE NOT NULL,
            creador TEXT NOT NULL,
            creado_en TEXT NOT NULL,
            activo INTEGER DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_fecha ON reuniones(fecha_utc);
        """)

def login_required(f):
    @wraps(f)
    def w(*a, **kw):
        if not session.get("user"):
            return redirect(url_for("login", next=request.path))
        return f(*a, **kw)
    return w

def new_csrf():
    t = secrets.token_urlsafe(24)
    session["csrf"] = t
    return t

def check_csrf():
    if request.form.get("csrf", "") != session.get("csrf", ""):
        abort(403, "CSRF invalido")

_attempts = {}
def rate_login(ip, mx=5, mn=15):
    now = datetime.now(timezone.utc)
    a = [t for t in _attempts.get(ip, []) if (now - t).total_seconds() < mn * 60]
    if len(a) >= mx:
        return False
    a.append(now)
    _attempts[ip] = a
    return True

def fin_reunion(r):
    """Fin previsto (UTC aware) = fecha_utc + duracion_min."""
    dur = int(r["duracion_min"] or 60)
    try:
        ini = datetime.strptime(r["fecha_utc"], "%Y-%m-%d %H:%M UTC").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        # Fila con fecha ilegible: se asume que empieza ahora.
        ini = datetime.now(timezone.utc)
    return ini + timedelta(minutes=dur)

def exp_reunion(r):
    """Vencimiento del token: fin previsto + JWT_EXP_MARGIN_MIN."""
    return fin_reunion(r) + timedelta(minutes=JWT_EXP_MARGIN_MIN)

def sign_jwt(room, user, mod=False, exp=None, pid=None):
    """Firma el JWT de UNA persona para UNA sala.

    - room: nombre exacto de la sala (nunca '*': un '*' abriria todas).
    - pid:  id unico del participante. Va en 'sub' y en context.user.id;
            si dos personas compartieran id, Jitsi las trataria como la misma.
    - mod:  context.user.moderator. token_affiliation (Prosody) lo convierte
            en affiliation owner => rol moderador. Nadie mas es moderador.
    - exp:  datetime UTC; por defecto 2 h.
    """
    if not room or room == "*":
        raise ValueError("room invalido para JWT")
    now = datetime.now(timezone.utc)
    if pid is None:
        pid = secrets.token_hex(8)
    if exp is None:
        exp = now + timedelta(hours=2)
    p = {
        "iss": JWT_ISS,
        "aud": JWT_AUD,
        # Con JWT_ENABLE_DOMAIN_VERIFICATION=0 Prosody no compara 'sub' con el
        # dominio; se usa como id unico del participante.
        "sub": pid + "@" + PUB,
        "room": room,
        "context": {"user": {"id": pid, "name": user, "moderator": bool(mod)}},
        "nbf": int(now.timestamp()) - JWT_NBF_SKEW,
        "exp": int(exp.timestamp()),
        "iat": int(now.timestamp()),
    }
    return pyjwt.encode(p, KSEC, algorithm="HS256")

def nueva_sala():
    """Nombre de sala no predecible: prefijo + 16 hex (64 bits).

    Hex en minusculas a proposito: Prosody compara el claim 'room' en
    minusculas y Jitsi normaliza el nombre de sala; sin mayusculas ni
    '_' no hay sorpresas de normalizacion.
    """
    return SALA_PREFIX + secrets.token_hex(8)

# Barra de herramientas segun el rol (Fase 3.3).
# El admin ve la barra completa; el asistente, una reducida. Es solo
# presentacion: quien manda sobre el audio/video es la moderacion A/V y el
# JWT (Fase 2).
TOOLBAR_ADMIN = ["microphone", "camera", "desktop", "participants-pane",
                 "raisehand", "chat", "tileview", "settings", "hangup"]
TOOLBAR_ASISTENTE = ["microphone", "raisehand", "chat", "settings", "hangup"]


def jitsi_url(sala, token, moderator=False):
    # JWT en el fragmento (#jwt=...): no viaja al servidor en la peticion
    # HTTP ni queda en logs de Caddy/nginx ni en el Referer.
    url = ("https://" + PUB + "/" + sala
           + "#jwt=" + token
           + "&config.prejoinPage.enabled=false"
           + "&config.deeplinking.disabled=true")
    # La barra se pasa como config.toolbarButtons en el fragmento. El
    # cliente la lee de config.toolbarButtons (no de interfaceConfig, que
    # esta obsoleto en stable-11031). El valor es un array JSON.
    botones = TOOLBAR_ADMIN if moderator else TOOLBAR_ASISTENTE
    url += "&config.toolbarButtons=" + json.dumps(botones, separators=(",", ":"))
    return url

def get_reunion(rid):
    with db() as c:
        return c.execute("SELECT * FROM reuniones WHERE id=? AND activo=1", (rid,)).fetchone()

def token_moderador(r):
    """Token de administrador (moderator: true) para la reunion r."""
    pid = "admin-" + secrets.token_hex(6)
    nombre = A.get("ADMIN_DISPLAY_NAME") or "Administracion"
    exp = exp_reunion(r)
    return sign_jwt(r["sala_jitsi"], nombre, mod=True, exp=exp, pid=pid), pid, exp

def escape_html(s):
    if s is None:
        return ""
    q = chr(34)  # comilla doble, sin escapar
    return (str(s).replace("&", "&amp;")
                  .replace("<", "&lt;")
                  .replace(">", "&gt;")
                  .replace(q, "&quot;"))

# RUTAS

@app.route("/healthz")
def healthz():
    # Siempre 200 (el healthcheck del contenedor depende de esto); el estado
    # de la config JWT va aparte para poder vigilarlo sin tumbar el panel.
    return jsonify({"status":"ok","service":"jitsi-admin",
                    "jwt_config_ok": not JWT_PROBLEMS})

@app.route("/admin/login", methods=["GET", "POST"])
def login():
    err = None
    if request.method == "POST":
        ip = request.remote_addr or "0.0.0.0"
        if not rate_login(ip):
            err = "Demasiados intentos. Espera 15 minutos."
        else:
            u = request.form.get("user","").strip()
            p = request.form.get("password","")
            pwd_h = hashlib.sha256(p.encode()).hexdigest()
            if ADMIN_PWD_HASH and u == ADMIN_USER and pwd_h == ADMIN_PWD_HASH:
                session.permanent = True
                session["user"] = u
                new_csrf()
                log.info("login OK user=" + u + " ip=" + ip)
                nxt = request.args.get("next") or url_for("panel")
                return redirect(nxt)
            else:
                log.warning("login FAIL user=" + u + " ip=" + ip)
                err = "Usuario o contrasena incorrectos."
    body = open(os.path.join(TPL_DIR, "page_login.html")).read()
    if err:
        body = body.replace("<!--ERR-->", '<div class="e">' + err + "</div>")
    else:
        body = body.replace("<!--ERR-->", "")
    return render_template_string(open(os.path.join(TPL_DIR, "tpl.html")).read(), t="Login", body=body)

@app.route("/admin/logout", methods=["POST"])
@login_required
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/admin", methods=["GET"])
@login_required
def panel():
    new_csrf()
    csrf = session["csrf"]
    body = open(os.path.join(TPL_DIR, "page_panel.html")).read()
    body = body.replace("{{csrf}}", csrf)
    body = body.replace("{{user}}", session.get("user",""))
    body = body.replace("<!--LISTA-->", listar_reuniones(csrf))
    aviso = ""
    if JWT_PROBLEMS:
        aviso = ('<div class="e"><b>Configuracion JWT incoherente</b> - Jitsi rechazara los tokens o no los exigira:<br>'
                 + "<br>".join(escape_html(x) for x in JWT_PROBLEMS) + "</div>")
    body = body.replace("<!--AVISO_JWT-->", aviso)
    return render_template_string(open(os.path.join(TPL_DIR, "tpl.html")).read(), t="Panel", body=body)

def listar_reuniones(csrf):
    with db() as c:
        rows = c.execute("SELECT * FROM reuniones WHERE activo=1 ORDER BY fecha_utc DESC LIMIT 50").fetchall()
    if not rows:
        return "<h2>Reuniones</h2><p class=m>No hay reuniones creadas.</p>"
    out = ["<h2>Reuniones programadas</h2>"]
    for r in rows:
        slug = r["slug"]
        sala = r["sala_jitsi"]
        link_publico = "https://" + PUB + "/reunion/" + slug
        link_qr = "/admin/qr/" + str(r["id"])
        # Fase 2: el token de moderador SOLO sale de rutas con login.
        # (Antes era '?presenter=1' en la pagina publica: cualquiera que
        # editara la URL entraba como moderador.)
        link_sala = "/admin/reunion/" + str(r["id"]) + "/sala"
        link_entrar = "/admin/reunion/" + str(r["id"]) + "/entrar"
        out.append('<div class="r">')
        out.append("  <h3>" + escape_html(r["titulo"]) + "</h3>")
        out.append("  <div class=mt><b>" + escape_html(r["fecha_utc"]) + " UTC</b> - duracion " + str(r["duracion_min"]) + " min - sala <code>" + escape_html(sala) + "</code></div>")
        out.append("  <small>Link publico: <code>" + link_publico + "</code></small>")
        out.append('  <div class="ac">')
        out.append('    <a href="' + link_qr + '" target=_blank>Ver QR</a>')
        out.append('    <a href="' + link_publico + '" target=_blank>Pagina publica</a>')
        out.append('    <a href="' + link_sala + '" target=_blank>Sala de moderacion</a>')
        out.append('    <a href="' + link_entrar + '" target=_blank>Entrar como administrador</a>')
        out.append('    <form method="post" action="/admin/reunion/' + str(r['id']) + '/eliminar" style="display:inline">')
        out.append("      <input type=hidden name=csrf value=" + csrf + ">")
        out.append('      <button class="d" onclick="return confirm(\'Eliminar esta reunion?\')">Eliminar</button>')
        out.append("    </form>")
        out.append("  </div>")
        out.append("</div>")
    return chr(10).join(out)

@app.route("/admin/reunion", methods=["POST"])
@login_required
def crear_reunion():
    check_csrf()
    titulo = request.form.get("titulo","").strip()
    descripcion = request.form.get("descripcion","").strip()
    fecha = request.form.get("fecha","").strip()
    hora = request.form.get("hora","").strip()
    duracion = int(request.form.get("duracion","60") or "60")
    if not titulo or not fecha or not hora:
        return "Titulo, fecha y hora son obligatorios", 400
    try:
        local = datetime.strptime(fecha + " " + hora, "%Y-%m-%d %H:%M")
        utc = local + timedelta(hours=5)
        fecha_utc = utc.strftime("%Y-%m-%d %H:%M UTC")
    except ValueError:
        return "Formato de fecha u hora invalido", 400
    slug = secrets.token_urlsafe(8).replace("_","-").lower()
    # Fase 2: sala aleatoria e independiente del slug publico. Antes era
    # "cerroazul-" + slug, es decir, deducible del link publico/QR.
    sala = nueva_sala()
    with db() as c:
        c.execute("INSERT INTO reuniones (slug, titulo, descripcion, fecha_utc, duracion_min, sala_jitsi, creador, creado_en, activo) VALUES (?,?,?,?,?,?,?,?,1)",
            (slug, titulo, descripcion, fecha_utc, duracion, sala, session.get("user","?"), datetime.now(timezone.utc).isoformat()))
        rid = c.execute("SELECT last_insert_rowid() as id").fetchone()["id"]
    log.info("reunion creada id=" + str(rid) + " titulo=" + titulo)
    return redirect("/admin/qr/" + str(rid))

@app.route("/admin/reunion/<int:rid>/eliminar", methods=["POST"])
@login_required
def eliminar_reunion(rid):
    check_csrf()
    with db() as c:
        c.execute("UPDATE reuniones SET activo=0 WHERE id=?", (rid,))
    log.info("reunion eliminada id=" + str(rid))
    return redirect(url_for("panel"))

@app.route("/admin/qr/<int:rid>")
@login_required
def qr_view(rid):
    with db() as c:
        row = c.execute("""SELECT slug, titulo, fecha_utc, duracion_min, sala_jitsi
                           FROM reuniones WHERE id=? AND activo=1""", (rid,)).fetchone()
    if not row:
        abort(404)
    slug = row["slug"]
    link_publico = "https://" + PUB + "/reunion/" + slug
    if request.args.get("format") == "png":
        img = qrcode.make(link_publico)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        buf.seek(0)
        return send_file(buf, mimetype="image/png", download_name="reunion-" + slug + ".png")
    body = open(os.path.join(TPL_DIR, "page_qr_view.html")).read()
    body = body.replace("{{titulo}}", escape_html(row["titulo"]))
    body = body.replace("{{fecha_utc}}", escape_html(row["fecha_utc"]))
    body = body.replace("{{duracion}}", str(row["duracion_min"]))
    body = body.replace("{{sala}}", escape_html(row["sala_jitsi"]))
    body = body.replace("{{link_publico}}", link_publico)
    body = body.replace("{{qr_url}}", "/admin/qr/" + str(rid) + "?format=png")
    return render_template_string(open(os.path.join(TPL_DIR, "tpl.html")).read(), t="Reunion creada", body=body)

@app.route("/reunion/<slug>")
def reunion_publica(slug):
    with db() as c:
        r = c.execute("SELECT * FROM reuniones WHERE slug=? AND activo=1", (slug,)).fetchone()
    if not r:
        body = "<h1>Reunion no encontrada</h1><p class=m>Verifica el link o contacta al administrador.</p>"
        return render_template_string(open(os.path.join(TPL_DIR, "tpl.html")).read(), t="No encontrada", body=body), 404
    # La pagina publica SIEMPRE emite tokens de asistente (moderator: false).
    # '?presenter=1' ya no tiene efecto; el admin entra por /admin/reunion/<id>/sala.
    body = open(os.path.join(TPL_DIR, "page_reunion.html")).read()
    body = body.replace("{{titulo}}", escape_html(r["titulo"]))
    body = body.replace("{{rol}}", "Asistente")
    body = body.replace("{{fecha_utc}}", escape_html(r["fecha_utc"]))
    body = body.replace("{{duracion}}", str(r["duracion_min"]))
    body = body.replace("{{descripcion}}", escape_html(r["descripcion"] or ""))
    body = body.replace("{{slug}}", escape_html(slug))
    return render_template_string(open(os.path.join(TPL_DIR, "tpl.html")).read(), t=r["titulo"], body=body)

def pagina_finalizada(r):
    body = ("<h1>Reunion finalizada</h1><p class=m>El acceso a <b>" + escape_html(r["titulo"])
            + "</b> se cerro " + str(JWT_EXP_MARGIN_MIN)
            + " minutos despues del fin previsto. Contacta a la administracion.</p>")
    return render_template_string(open(os.path.join(TPL_DIR, "tpl.html")).read(), t="Reunion finalizada", body=body), 410

@app.route("/unirse", methods=["POST"])
def unirse():
    slug = request.form.get("slug","").strip()
    nombre = request.form.get("nombre","").strip()[:50]
    apto = request.form.get("apto","").strip()[:20]
    if not slug or not nombre:
        return "Faltan datos", 400
    with db() as c:
        r = c.execute("SELECT * FROM reuniones WHERE slug=? AND activo=1", (slug,)).fetchone()
    if not r:
        abort(404)
    exp = exp_reunion(r)
    if exp <= datetime.now(timezone.utc):
        # No emitir un token que Prosody rechazaria por vencido.
        return pagina_finalizada(r)
    visible = ("Apto " + apto + " - " + nombre) if apto else nombre
    # Un token por persona y por reunion: pid nuevo en cada /unirse.
    # NUNCA moderador desde la pagina publica (se ignora cualquier 'rol'
    # que venga en el formulario).
    pid = secrets.token_hex(8)
    token = sign_jwt(r["sala_jitsi"], visible, mod=False, exp=exp, pid=pid)
    log.info("unirse slug=" + slug + " user=" + visible + " mod=False pid=" + pid)
    # El asistente entra con la barra restringida (Fase 3.3).
    return redirect(jitsi_url(r["sala_jitsi"], token, moderator=False))

# --- Moderacion A/V (Fase 2) -------------------------------------------
# Las acciones de moderacion (toggleModeration, askToUnmute, approveVideo,
# muteEveryone...) las ejecuta el NAVEGADOR del moderador via el iframe API
# de Jitsi: el servidor del panel no habla XMPP con la sala. Por eso el
# panel expone:
#   /admin/reunion/<id>/sala           pagina con Jitsi embebido + botones
#   /admin/reunion/<id>/moderador.json token de moderador para que OTRO
#                                      cliente embeba Jitsi (ver README)
#   /admin/reunion/<id>/entrar         entrada directa como moderador

@app.route("/admin/reunion/<int:rid>/sala")
@login_required
def sala_moderacion(rid):
    r = get_reunion(rid)
    if not r:
        abort(404)
    token, pid, exp = token_moderador(r)
    if exp <= datetime.now(timezone.utc):
        return pagina_finalizada(r)
    cfg = {"domain": PUB, "roomName": r["sala_jitsi"], "jwt": token}
    # json.dumps + escapar '<' evita cerrar el <script> con datos de la DB.
    cfg_js = json.dumps(cfg).replace("<", "\\u003c")
    body = open(os.path.join(TPL_DIR, "page_sala.html")).read()
    body = body.replace("{{titulo}}", escape_html(r["titulo"]))
    body = body.replace("{{sala}}", escape_html(r["sala_jitsi"]))
    body = body.replace("{{domain}}", escape_html(PUB))
    body = body.replace("{{cfg_json}}", cfg_js)
    log.info("sala moderacion id=" + str(rid) + " user=" + session.get("user","") + " pid=" + pid)
    return render_template_string(open(os.path.join(TPL_DIR, "tpl.html")).read(), t="Moderacion - " + r["titulo"], body=body)

@app.route("/admin/reunion/<int:rid>/moderador.json")
@login_required
def moderador_json(rid):
    r = get_reunion(rid)
    if not r:
        abort(404)
    token, pid, exp = token_moderador(r)
    log.info("token moderador json id=" + str(rid) + " user=" + session.get("user","") + " pid=" + pid)
    resp = jsonify({
        "domain": PUB,
        "roomName": r["sala_jitsi"],
        "jwt": token,
        "participantId": pid,
        "exp": int(exp.timestamp()),
        "expired": exp <= datetime.now(timezone.utc),
    })
    resp.headers["Cache-Control"] = "no-store"
    return resp

@app.route("/admin/reunion/<int:rid>/entrar")
@login_required
def entrar_moderador(rid):
    r = get_reunion(rid)
    if not r:
        abort(404)
    token, pid, exp = token_moderador(r)
    if exp <= datetime.now(timezone.utc):
        return pagina_finalizada(r)
    log.info("entrar moderador id=" + str(rid) + " user=" + session.get("user","") + " pid=" + pid)
    # El administrador entra con la barra completa (Fase 3.3).
    return redirect(jitsi_url(r["sala_jitsi"], token, moderator=True))

# Crear el esquema al IMPORTAR el modulo, no solo con __main__.
# Gunicorn importa 'app:app' en un proceso workers: si init_db() solo
# estuviera bajo __main__, la tabla 'reuniones' nunca se crearia y el
# panel fallaria en todas las consultas de un despliegue limpio.
init_db()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8081, debug=False)
