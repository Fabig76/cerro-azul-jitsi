#!/usr/bin/env python3
# =====================================================================
# make-token.py - JWT para la sala de la prueba de carga (Fase 7.3)
#
# Se ejecuta EN EL SERVIDOR DE JITSI (donde esta el .env con
# JWT_APP_SECRET). Solo stdlib: HS256 es un HMAC-SHA256, no hace falta
# PyJWT. Escribe el token en un fichero con chmod 600 y NO lo imprime
# (es una credencial de entrada a la sala mientras no caduque).
#
# Por que no se usa un token del panel:
#   - Malleus nombra la sala <prefijo><indice> (p. ej. 'cargatest0'), y
#     los tokens del panel van atados a salas 'asamblea-<hex>'.
#   - Los 600 clientes simulados comparten UN token. El panel pone un
#     context.user.id unico por persona; si los 600 compartieran ese id,
#     Jitsi podria tratarlos como la misma persona. Este token NO lleva
#     context.user.id (VERIFICAR en la prueba de humo de 10 clientes que
#     aparecen 10 participantes distintos).
#   - moderator=false: los clientes de carga son asistentes. El
#     administrador real entra con su token del panel.
#
# Mismas reglas que sign_jwt() del panel (admin-panel/app/app.py):
# iss/aud = primer valor de JWT_ACCEPTED_ISSUERS/AUDIENCES, nunca room '*'.
#
# Uso:
#   python3 loadtest/make-token.py /opt/jitsi-meet/.env --room cargatest0 \
#       --hours 3 --out /root/cargatest0.jwt
# =====================================================================
import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import time


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def read_env(path):
    values = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip().strip('"').strip("'")
    return values


def first(csv_value):
    return csv_value.split(",")[0].strip() if csv_value else ""


def main():
    ap = argparse.ArgumentParser(description="JWT para la sala de la prueba de carga")
    ap.add_argument("env_file", help=".env de Jitsi (con JWT_APP_SECRET)")
    ap.add_argument("--room", required=True, help="sala exacta (Malleus: <prefijo>0)")
    ap.add_argument("--hours", type=float, default=3.0, help="validez (default 3 h)")
    ap.add_argument("--name", default="carga", help="nombre visible de los clientes")
    ap.add_argument("--out", required=True, help="fichero de salida (chmod 600)")
    args = ap.parse_args()

    # Mismas restricciones que el panel: minusculas/digitos/guion, nunca '*'.
    if args.room == "*" or not re.fullmatch(r"[a-z0-9-]{3,64}", args.room):
        sys.exit("ERROR: --room debe ser un nombre concreto en minusculas (sin '*')")

    env = read_env(args.env_file)
    secret = env.get("JWT_APP_SECRET", "")
    if not secret or secret.upper().startswith("CAMBIAR"):
        sys.exit("ERROR: JWT_APP_SECRET no esta definido en %s" % args.env_file)
    iss = first(env.get("JWT_ACCEPTED_ISSUERS")) or env.get("JWT_APP_ID", "")
    aud = first(env.get("JWT_ACCEPTED_AUDIENCES")) or env.get("JWT_APP_ID", "")
    pub = env.get("PUBLIC_URL", "meet.bytracking.net").replace("https://", "").rstrip("/")
    if not iss or not aud:
        sys.exit("ERROR: no se pudo deducir iss/aud del .env")

    now = int(time.time())
    payload = {
        "iss": iss,
        "aud": aud,
        "sub": pub,
        "room": args.room,
        "context": {"user": {"name": args.name, "moderator": False}},
        "nbf": now - 60,
        "iat": now,
        "exp": now + int(args.hours * 3600),
    }
    header = {"alg": "HS256", "typ": "JWT"}
    signing_input = b64url(json.dumps(header, separators=(",", ":")).encode()) + "." + \
        b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(secret.encode(), signing_input.encode(), hashlib.sha256).digest()
    token = signing_input + "." + b64url(sig)

    fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    os.chmod(args.out, 0o600)

    shown = dict(payload)
    print("token escrito en %s (chmod 600; NO se imprime)" % args.out)
    print("claims: %s" % json.dumps(shown, ensure_ascii=False))
    print("caduca: %s" % time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime(payload["exp"])))


if __name__ == "__main__":
    main()
