#!/usr/bin/env python3
"""
Mide el consumo REAL de subida del VPS con N receptores y una fuente de video.

Sirve para responder con datos: "cuantas personas aguanta este servidor?".

Que mide:
  1. Los contadores de bytes de subida del host (físicas, sin veth).
  2. La diferencia durante T segundos, con N clientes reales dentro de la sala
     y uno publicando su camara (pista de video real que el JVB retransmite).
  3. El consumo por receptor y la extrapolacion a 500.

En headless no se puede compartir pantalla (getDisplayMedia falla), asi que
la fuente es la camara falsa de Chromium. Las constraints de video son las
mismas para camara y pantalla, asi que el numero sirve de referencia para
las dos.

Uso:
    python3 loadtest/medir-bitrate.py [N_RECEPTORES] [SEGUNDOS]

Aviso: crea una reunion de prueba en la BD de produccion y la borra al
terminar. No toca la configuracion ni reinicia nada.
"""
import http.cookiejar
import subprocess
import sys
import time
import urllib.parse
import urllib.request

from playwright.sync_api import sync_playwright

HOST = "chatbotph"
BASE = "https://meet.bytracking.net"
REPO_SALA = "asamblea"

N_REC = int(sys.argv[1]) if len(sys.argv) > 1 else 6
T = int(sys.argv[2]) if len(sys.argv) > 2 else 40

# Ancho de banda de subida medido del VPS (Contabo, chatbotph).
# Es el limite real: si la extrapolacion lo pasa, no cabe.
SUBIDA_VPS_MBITS = 220


def ssh(cmd, t=90):
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=20", HOST, cmd],
                       capture_output=True, text=True, timeout=t)
    return (r.stdout + r.stderr).strip()


def bytes_subida():
    """Bytes de subida acumulados en las interfaces fisicas del host."""
    txt = ssh("cat /proc/net/dev")
    tot = 0
    for ln in txt.splitlines()[2:]:
        if ":" not in ln:
            continue
        nom, _, resto = ln.partition(":")
        if nom.strip() in ("lo", "docker0") or "veth" in nom:
            continue
        c = resto.split()
        if len(c) >= 9:
            tot += int(c[8])          # columna "bytes enviados"
    return tot


def crear_sala():
    out = ssh(
        "docker exec jitsi-admin python3 -c \""
        "import sqlite3,datetime,secrets;"
        "c=sqlite3.connect('/app/instance/reuniones.db');"
        "h=datetime.datetime.now(datetime.timezone.utc);"
        "f=h.strftime('%Y-%m-%d')+' 23:00';"
        "s=secrets.token_hex(5)[:10];a='med-'+secrets.token_hex(3);"
        "c.execute('INSERT INTO reuniones (slug,titulo,descripcion,fecha_utc,"
        "duracion_min,sala_jitsi,creador,creado_en,activo) "
        "VALUES (?,?,?,?,?,?,?,?,1)',"
        "(s,'Medicion de bitrate','',f,120,a,'medicion',h.isoformat()));"
        "c.commit();print(s)\""
    )
    return out.strip().split("|")[-1].strip()


def borrar_sala(slug):
    ssh("docker exec jitsi-admin python3 -c \""
        "import sqlite3;c=sqlite3.connect('/app/instance/reuniones.db');"
        "c.execute(\\\"DELETE FROM reuniones WHERE slug=?\\\",('%s',));c.commit()\"" % slug)


def url_para(slug, nombre):
    cj = http.cookiejar.CookieJar()
    ctx = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    d = urllib.parse.urlencode({"slug": slug, "nombre": nombre, "apto": "1"}).encode()
    r = ctx.open(urllib.request.Request(
        BASE + "/unirse", data=d, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"}), timeout=25)
    return r.url


slug = crear_sala()
print("  sala de prueba:", slug)
print("  %d receptores, %d s de medida" % (N_REC, T))

try:
    with sync_playwright() as p:
        br = p.chromium.launch(args=[
            "--use-fake-ui-for-media-stream",
            "--use-fake-device-for-media-stream",
            "--autoplay-policy=no-user-gesture-required",
        ])

        emisor = br.new_page(viewport={"width": 1280, "height": 800})
        emisor.goto(url_para(slug, "Emisor"), timeout=40000,
                    wait_until="domcontentloaded")
        emisor.wait_for_timeout(9000)
        emisor.evaluate("""() => {
            try { window.APP.store.dispatch({type: 'TOGGLE_LOCAL_VIDEO'}); }
            catch (e) {}
        }""")
        emisor.wait_for_timeout(4000)

        for i in range(N_REC):
            pg = br.new_page(viewport={"width": 1280, "height": 800})
            pg.goto(url_para(slug, "Receptor%d" % i), timeout=40000,
                    wait_until="domcontentloaded")
            pg.wait_for_timeout(5000)

        time.sleep(6)
        c0 = bytes_subida()
        t0 = time.time()
        time.sleep(T)
        c1 = bytes_subida()
        dt = time.time() - t0

        up = c1 - c0
        mbits = up * 8 / dt / 1e6
        por_receptor = mbits / N_REC

        print()
        print("  subida real del host: %.2f MB en %.0f s = %.2f Mbit/s"
              % (up / 1e6, dt, mbits))
        print("  por receptor:        %.3f Mbit/s" % por_receptor)
        print()
        print("  === extrapolacion ===")
        for n in (100, 300, 500):
            tot = por_receptor * n
            print("   %3d personas -> %5.0f Mbit/s   %s"
                  % (n, tot, "OK" if tot < SUBIDA_VPS_MBITS else "EXCEDE"))

        br.close()
finally:
    borrar_sala(slug)
    print("  sala de prueba borrada")
