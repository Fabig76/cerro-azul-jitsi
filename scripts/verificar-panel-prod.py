#!/usr/bin/env python3
"""
verificar-panel-prod.py - Verificacion con sesion contra PRODUCCION.

No usa la contrasena del administrador: firma una cookie de sesion con la
clave del propio panel (dentro del contenedor jitsi-admin, via ssh) y recorre
el flujo: panel, crear reunion de prueba, QR (+PNG), pagina publica, 404,
/unirse, sala, moderador.json, eliminar la reunion de prueba, API sin key.
Imprime el contrato de cada pagina con el mismo formato que
verificar-panel-local.py.

Ademas, si se pasa --login-imagen, arranca la imagen desplegada en un
contenedor temporal del VPS con una contrasena de prueba y comprueba el
login REAL (POST con usuario/contrasena -> 302, error visible con contrasena
mala) a traves de un tunel ssh. No toca el contenedor de produccion.

Con --estado-botones ademas ejecuta scripts/probar-estado-botones-prod.py:
admin + dos residentes reales en una sala de prueba propia; comprueba que los
botones de la sala muestran el estado real (texto, clase, aria-pressed).

Uso: scripts/verificar-panel-prod.py [--login-imagen] [--estado-botones]
"""
import argparse
import importlib.util
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

HOST = os.environ.get("DEPLOY_HOST", "chatbotph")
BASE = "https://meet.bytracking.net"
AQUI = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("vpl", os.path.join(AQUI, "verificar-panel-local.py"))
vpl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vpl)
# En produccion el nombre del conjunto viene de admin.env (puede ser el real).
vpl.PROHIBIR_MARCA_VIEJA = False

FIRMAR = r'''
import sys, logging
logging.disable(logging.CRITICAL)
sys.path.insert(0, "/app")
from app import app, ADMIN_USER
s = app.session_interface.get_signing_serializer(app)
print(s.dumps({"user": ADMIN_USER, "csrf": "x", "_permanent": True}))
'''


def ssh(cmd, inp=None):
    return subprocess.run(["ssh", HOST, cmd], input=inp, capture_output=True, text=True)


def cookie_sesion():
    r = ssh("sudo docker exec -i jitsi-admin python3 -", FIRMAR)
    v = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if not v:
        sys.exit("no se pudo firmar la cookie: " + r.stderr[-300:])
    return v


def flujo_sesion():
    c = vpl.Cliente(BASE)
    c.op.addheaders = [("Cookie", "session=" + cookie_sesion())]

    def actualizar(h):
        # Flask reenvia la cookie cuando cambia la sesion (csrf nuevo)
        sc = h.get("Set-Cookie", "")
        m = re.search(r"session=([^;]+)", sc)
        if m:
            c.op.addheaders = [("Cookie", "session=" + m.group(1))]

    print("=== PRODUCCION: flujo con sesion ===")
    st, h, raw = c.get("/admin")
    actualizar(h)
    a = vpl.contrato("panel", st, raw)
    csrf = vpl.csrf_de(a, "/admin/reunion")
    manana = (datetime.now(timezone.utc) - timedelta(hours=5) + timedelta(days=1)).strftime("%Y-%m-%d")
    st, h, _ = c.post("/admin/reunion", {"csrf": csrf or "", "titulo": "PRUEBA rediseño (se borra sola)",
                                          "descripcion": "Verificación automática", "fecha": manana,
                                          "hora": "19:00", "duracion": "60"})
    loc = h.get("Location", "")
    print("  crear reunion de prueba -> %s %s" % (st, loc.replace(BASE, "")))
    m = re.search(r"/admin/qr/(\d+)", loc)
    if st != 302 or not m:
        vpl.fallo("crear reunion en produccion")
        return
    rid = m.group(1)
    try:
        st, h, raw = c.get("/admin/qr/" + rid)
        vpl.contrato("qr", st, raw)
        slug = re.search(r"/reunion/([a-z0-9-]{6,})", raw.decode()).group(1)
        st, h, raw = c.get("/admin/qr/" + rid + "?format=png")
        print("  qr png -> %s %s\n" % (st, h.get("Content-Type")))
        pub = vpl.Cliente(BASE)
        st, h, raw = pub.get("/reunion/" + slug)
        vpl.contrato("reunion publica", st, raw)
        st, h, raw = pub.get("/reunion/noexiste-verif")
        vpl.contrato("reunion no encontrada", st, raw, esperado_st=404)
        st, h, _ = pub.post("/unirse", {"slug": slug, "apto": "", "nombre": "Verificador"})
        ok = st == 302 and "?jwt=" in h.get("Location", "")  # query desde 4535fd9
        print("  /unirse -> %s %s" % (st, "jitsi?jwt OK" if ok else "?"))
        if not ok:
            vpl.fallo("/unirse en produccion")
        st, h, raw = c.get("/admin/reunion/" + rid + "/sala")
        vpl.contrato("sala", st, raw, sala=True)
        st, h, raw = c.get("/admin/reunion/" + rid + "/moderador.json")
        print("  moderador.json -> %s" % st)
    finally:
        st, h, raw = c.get("/admin")
        actualizar(h)
        csrf_del = vpl.csrf_de(vpl.parse(raw), "/admin/reunion/%s/eliminar" % rid)
        st, h, _ = c.post("/admin/reunion/%s/eliminar" % rid, {"csrf": csrf_del or ""})
        print("  eliminar reunion de prueba %s -> %s %s" % (rid, st, h.get("Location", "").replace(BASE, "")))
        if st != 302:
            vpl.fallo("eliminar reunion de prueba %s (borrarla a mano)" % rid)
        st, h, raw = c.get("/admin")
        print("  sigue en el panel: %s" % ("SI" if "/admin/qr/%s\"" % rid in raw.decode() else "no"))
    st, h, _ = c.post("/api/reuniones/1/token", b"{}", {"Content-Type": "application/json"})
    print("  api token sin auth -> %s\n" % st)


def login_imagen():
    """Login real (usuario+contrasena+redireccion) con la imagen desplegada."""
    print("=== PRODUCCION: login real con la imagen desplegada (contenedor temporal) ===")
    pw = "verif-" + os.urandom(6).hex()
    script = r'''
set -e
D=$(mktemp -d); H=$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)
printf 'JITSI_ADMIN_PASSWORD_HASH=%s\nFLASK_SECRET_KEY=%s\n' "$H" "$(openssl rand -hex 32)" > $D/admin.env
chmod 777 $D
sudo docker rm -f admin-verif-login >/dev/null 2>&1 || true
sudo docker run -d --name admin-verif-login -p 127.0.0.1:18091:8081 -v $D:/app/instance \
  -e JITSI_ENV_FILE=/nonexistent jitsi-admin:local >/dev/null
echo $D
'''
    r = ssh("bash -s -- " + pw, script)
    tmpdir = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    tun = subprocess.Popen(["ssh", "-N", "-L", "18091:127.0.0.1:18091", HOST])
    try:
        for _ in range(40):
            try:
                import urllib.request
                urllib.request.urlopen("http://127.0.0.1:18091/healthz", timeout=2)
                break
            except Exception:
                time.sleep(0.5)
        c = vpl.Cliente("http://127.0.0.1:18091")
        st, h, raw = c.get("/admin/login")
        vpl.contrato("login (imagen desplegada)", st, raw)
        st, h, raw = c.post("/admin/login", {"user": "Hguaza76", "password": "mala"})
        print("  login con contrasena mala -> %s, error visible: %s" % (
            st, "si" if "incorrect" in raw.decode() else "NO"))
        st, h, _ = c.post("/admin/login?next=/admin", {"user": "Hguaza76", "password": pw})
        print("  login correcto con ?next=/admin -> %s %s" % (st, h.get("Location", "")[-6:]))
        if st != 302:
            vpl.fallo("login real con la imagen desplegada")
        st, h, raw = c.get("/admin")
        a = vpl.parse(raw)
        csrf = vpl.csrf_de(a, "/admin/reunion")
        st2, h2, _ = c.post("/admin/reunion", {"csrf": csrf or "", "titulo": "t", "fecha": "2030-01-01",
                                                "hora": "10:00", "duracion": "60"})
        print("  panel tras login -> %s; crear con CSRF -> %s %s\n" % (st, st2, h2.get("Location", "")[-12:]))
        if st2 != 302:
            vpl.fallo("crear con CSRF tras login real")
    finally:
        tun.terminate()
        ssh("sudo docker rm -f admin-verif-login >/dev/null; sudo rm -rf " + tmpdir)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--login-imagen", action="store_true")
    ap.add_argument("--estado-botones", action="store_true",
                    help="prueba real con dos residentes (scripts/probar-estado-botones-prod.py)")
    args = ap.parse_args()
    for f in ("theme.css", "sala-estado.js", "bajar-manos.js"):
        st, h, raw = vpl.Cliente(BASE).get("/admin/static/" + f)
        print("/admin/static/%s -> %s %s" % (f, st, h.get("Content-Type")))
        if st != 200:
            vpl.fallo("/admin/static/%s -> %s" % (f, st))
        elif f == "sala-estado.js" and b"SalaEstado" not in raw:
            vpl.fallo("sala-estado.js servido no es el esperado")
    st, h, raw = vpl.Cliente(BASE).get("/admin/login")
    vpl.contrato("login", st, raw)
    flujo_sesion()
    if args.login_imagen:
        login_imagen()
    if args.estado_botones:
        print("=== PRODUCCION: estado de los botones con dos residentes reales ===")
        r = subprocess.run([sys.executable, os.path.join(AQUI, "probar-estado-botones-prod.py")])
        if r.returncode:
            vpl.fallo("estado de los botones (probar-estado-botones-prod.py)")
    print("=== RESULTADO: %s ===" % ("OK" if not vpl.FALLOS else "%d FALLO(S)" % len(vpl.FALLOS)))
    for f in vpl.FALLOS:
        print("  - " + f)
    sys.exit(1 if vpl.FALLOS else 0)


if __name__ == "__main__":
    main()
