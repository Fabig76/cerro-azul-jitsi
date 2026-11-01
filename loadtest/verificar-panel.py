#!/usr/bin/env python3
"""
Verificacion de que el rediseno del panel no rompe la funcionalidad.

Comprueba los elementos de los que depende la app (ids, names, formularios,
CSRF) y los endpoints criticos. Se ejecuta ANTES del rediseno para tener la
linea base, y DESPUES para comparar.

Uso:
  python3 verificar-panel.py > /tmp/panel-antes.txt
  # ... rediseno ...
  python3 verificar-panel.py > /tmp/panel-despues.txt
  diff /tmp/panel-antes.txt /tmp/panel-despues.txt
"""
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request

BASE = "https://meet.bytracking.net"
PAGES = [
    ("login", "/admin/login"),
    ("healthz", "/healthz"),
]

def get(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "verificador-panel"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, ""
    except Exception as e:
        return None, str(e)[:100]

def extraer(html):
    """Elementos de los que puede depender el JS o el servidor."""
    return {
        "ids": sorted(set(re.findall(r'id="([^"]+)"', html))),
        "names": sorted(set(re.findall(r'name="([^"]+)"', html))),
        "forms": len(re.findall(r"<form", html)),
        "inputs": len(re.findall(r"<input", html)),
        "buttons": len(re.findall(r"<button", html)),
        "csrf": sorted(set(re.findall(r'name="csrf"[^>]*value="([^"]*)"', html))),
        "scripts": len(re.findall(r"<script", html)),
        "forms_action": sorted(set(re.findall(r'<form[^>]*action="([^"]*)"', html))),
    }

print("=== VERIFICACION DEL PANEL ===")
print()

for nombre, ruta in PAGES:
    st, html = get(BASE + ruta)
    print("--- %s (%s) -> HTTP %s ---" % (nombre, ruta, st))
    if st == 200 and html:
        e = extraer(html)
        for k, v in e.items():
            if k == "csrf":
                # El token cambia en cada carga: solo interesa que exista
                print("  %-14s %s" % (k + ":", "presente" if v else "AUSENTE"))
            else:
                print("  %-14s %s" % (k + ":", v if not isinstance(v, list) else (v if len(v) <= 12 else v[:12] + ["..."])))
    print()

# Endpoints criticos de la API
print("--- API de tokens (sin auth debe dar 401) ---")
req = urllib.request.Request(BASE + "/api/reuniones/11/token", data=b"{}", method="POST",
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        print("  HTTP", r.status)
except urllib.error.HTTPError as e:
    print("  HTTP", e.code)

print()
print("--- pagina publica de reunion (residente) ---")
st, html = get(BASE + "/admin/login")
print("  login HTTP:", st)
