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

ENV_FILE = "/opt/jitsi-meet/.env"
ADMIN_ENV_FILE = "/app/instance/admin.env"

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

app = Flask(__name__)
app.secret_key = A.get("FLASK_SECRET_KEY") or SK
app.permanent_session_lifetime = timedelta(hours=4)

ADMIN_USER = "Hguaza76"
ADMIN_PWD_HASH = A.get("JITSI_ADMIN_PASSWORD_HASH")

DB_PATH = "/app/instance/reuniones.db"

logging.basicConfig(level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler("/app/instance/app.log"),
        logging.StreamHandler()
    ])
log = logging.getLogger("jitsi-admin")

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

def sign_jwt(room, user, mod=False, ttl=7200, sub_id=None):
    now = datetime.now(timezone.utc)
    # sub debe ser UNICO por participante; si no, Jitsi pisa las sesiones
    if sub_id is None:
        sub_id = secrets.token_urlsafe(8)
    p = {
        "iss": KID,
        "sub": sub_id + "@" + PUB,
        "aud": KID,
        "room": room,
        "context": {"user": {"name": user, "moderator": mod}},
        "nbf": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=ttl)).timestamp()),
        "iat": int(now.timestamp()),
    }
    return pyjwt.encode(p, KSEC, algorithm="HS256")

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
    return jsonify({"status":"ok","service":"jitsi-admin"})

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
    body = open("/app/page_login.html").read()
    if err:
        body = body.replace("<!--ERR-->", '<div class="e">' + err + "</div>")
    else:
        body = body.replace("<!--ERR-->", "")
    return render_template_string(open("/app/tpl.html").read(), t="Login", body=body)

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
    body = open("/app/page_panel.html").read()
    body = body.replace("{{csrf}}", csrf)
    body = body.replace("{{user}}", session.get("user",""))
    body = body.replace("<!--LISTA-->", listar_reuniones(csrf))
    return render_template_string(open("/app/tpl.html").read(), t="Panel", body=body)

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
        link_jitsi = link_publico + "?presenter=1"
        out.append('<div class="r">')
        out.append("  <h3>" + escape_html(r["titulo"]) + "</h3>")
        out.append("  <div class=mt><b>" + escape_html(r["fecha_utc"]) + " UTC</b> - duracion " + str(r["duracion_min"]) + " min - sala <code>" + escape_html(sala) + "</code></div>")
        out.append("  <small>Link publico: <code>" + link_publico + "</code></small>")
        out.append('  <div class="ac">')
        out.append('    <a href="' + link_qr + '" target=_blank>Ver QR</a>')
        out.append('    <a href="' + link_publico + '" target=_blank>Pagina publica</a>')
        out.append('    <a href="' + link_jitsi + '" target=_blank>Entrar como presentador</a>')
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
    sala = "cerroazul-" + slug
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
    body = open("/app/page_qr_view.html").read()
    body = body.replace("{{titulo}}", escape_html(row["titulo"]))
    body = body.replace("{{fecha_utc}}", escape_html(row["fecha_utc"]))
    body = body.replace("{{duracion}}", str(row["duracion_min"]))
    body = body.replace("{{sala}}", escape_html(row["sala_jitsi"]))
    body = body.replace("{{link_publico}}", link_publico)
    body = body.replace("{{qr_url}}", "/admin/qr/" + str(rid) + "?format=png")
    return render_template_string(open("/app/tpl.html").read(), t="Reunion creada", body=body)

@app.route("/reunion/<slug>")
def reunion_publica(slug):
    with db() as c:
        r = c.execute("SELECT * FROM reuniones WHERE slug=? AND activo=1", (slug,)).fetchone()
    if not r:
        body = "<h1>Reunion no encontrada</h1><p class=m>Verifica el link o contacta al administrador.</p>"
        return render_template_string(open("/app/tpl.html").read(), t="No encontrada", body=body), 404
    is_presenter = request.args.get("presenter") == "1"
    rol = "Anfitrion / presentador" if is_presenter else "Asistente"
    body = open("/app/page_reunion.html").read()
    body = body.replace("{{titulo}}", escape_html(r["titulo"]))
    body = body.replace("{{rol}}", escape_html(rol))
    body = body.replace("{{fecha_utc}}", escape_html(r["fecha_utc"]))
    body = body.replace("{{duracion}}", str(r["duracion_min"]))
    body = body.replace("{{sala}}", escape_html(r["sala_jitsi"]))
    body = body.replace("{{descripcion}}", escape_html(r["descripcion"] or ""))
    body = body.replace("{{slug}}", escape_html(slug))
    return render_template_string(open("/app/tpl.html").read(), t=r["titulo"], body=body)

@app.route("/unirse", methods=["POST"])
def unirse():
    slug = request.form.get("slug","").strip()
    nombre = request.form.get("nombre","").strip()[:50]
    rol = request.form.get("rol","")
    if not slug or not nombre:
        return "Faltan datos", 400
    with db() as c:
        r = c.execute("SELECT sala_jitsi FROM reuniones WHERE slug=? AND activo=1", (slug,)).fetchone()
    if not r:
        abort(404)
    is_mod = "Anfitrion" in rol
    # JWT unico por participante (sub = session_id unico)
    # Jitsi requiere sub unico por usuario para que no se pisen las sesiones
    session_id = secrets.token_urlsafe(8)
    token = sign_jwt(r["sala_jitsi"], nombre, mod=is_mod, ttl=7200, sub_id=session_id)
    # JWT en fragment (#jwt=...) - Jitsi lo recomienda por seguridad
    jitsi_url = ("https://" + PUB + "/" + r["sala_jitsi"]
                 + "#jwt=" + token
                 + "&config.prejoinPage.enabled=false"
                 + "&config.deeplinking.disabled=true")
    log.info("unirse slug=" + slug + " user=" + nombre + " mod=" + str(is_mod) + " sid=" + session_id)
    return redirect(jitsi_url)

if __name__ == "__main__":
    init_db()
    app.run(host="127.0.0.1", port=8081, debug=False)
