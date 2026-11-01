#!/usr/bin/env python3
# =====================================================================
# check_turn.py - Comprueba DESDE FUERA que el TURN de Cerro Azul responde
#
# Lo llama scripts/check-turn.sh (ver alli el uso). Solo stdlib de
# Python 3: el host del watchdog (Hermes) no tiene por que tener
# turnutils_uclient ni nada de coturn instalado.
#
# QUE COMPRUEBA (y por que cada cosa):
#   1. STUN Binding por UDP a TURN_HOST:TURN_PORT
#        -> el proceso coturn esta vivo y el UDP llega (firewall abierto).
#           Debe devolver XOR-MAPPED-ADDRESS (nuestra IP vista desde fuera).
#   2. TURN Allocate por UDP con credencial REST
#        -> el secreto compartido coincide (si TURN_CREDENTIALS de Jitsi y
#           static-auth-secret de coturn divergen, el STUN sigue
#           respondiendo pero NADIE consigue relay: es el fallo silencioso
#           que mas duele). Debe devolver XOR-RELAYED-ADDRESS.
#   3. STUN Binding sobre TLS en TURNS_PORT (443)
#        -> el certificado carga y coturn atiende TLS. No basta con que el
#           puerto acepte TCP: se habla STUN dentro del TLS para saber que
#           al otro lado esta coturn y no otro servicio.
#   4. TURN Allocate sobre TLS en TURNS_PORT
#        -> es EXACTAMENTE lo que hace un navegador en una red que bloquea
#           UDP (lo que motiva la Fase 4). Si esto falla, esos usuarios no
#           oyen nada aunque 1-3 esten bien.
#   Extra: aviso si al certificado TLS le quedan menos de --cert-min-days
#          dias (alerta "certificado con menos de 14 dias" de la Fase 7.1).
#
# CONTRATO DE WATCHDOG (igual que check-meet-jitsi.sh de Hermes):
#   - todo bien  -> NO imprime nada y sale con 0
#   - algo falla -> imprime el detalle y sale con 1
#   - error de uso/configuracion -> sale con 2
#
# El secreto TURN_CREDENTIALS NUNCA se imprime (ni siquiera con -v).
# =====================================================================
import argparse
import base64
import hashlib
import hmac
import os
import socket
import ssl
import struct
import sys
import tempfile
import time
from datetime import datetime, timezone

MAGIC_COOKIE = 0x2112A442

# Tipos de mensaje (RFC 5389 / RFC 5766)
BINDING_REQUEST = 0x0001
BINDING_SUCCESS = 0x0101
ALLOCATE_REQUEST = 0x0003
ALLOCATE_SUCCESS = 0x0103
ALLOCATE_ERROR = 0x0113
REFRESH_REQUEST = 0x0004

# Atributos
ATTR_MAPPED_ADDRESS = 0x0001
ATTR_USERNAME = 0x0006
ATTR_MESSAGE_INTEGRITY = 0x0008
ATTR_ERROR_CODE = 0x0009
ATTR_LIFETIME = 0x000D
ATTR_REALM = 0x0014
ATTR_NONCE = 0x0015
ATTR_XOR_RELAYED_ADDRESS = 0x0016
ATTR_REQUESTED_TRANSPORT = 0x0019
ATTR_XOR_MAPPED_ADDRESS = 0x0020

PROTO_UDP = 17


class CheckError(Exception):
    """Fallo de una comprobacion (se informa y se sigue con las demas)."""


# ---------------------------------------------------------------------
# Codificacion STUN
# ---------------------------------------------------------------------
def _attr(atype, value):
    pad = (4 - len(value) % 4) % 4
    return struct.pack("!HH", atype, len(value)) + value + b"\x00" * pad


def build_message(mtype, attrs, tid, integrity_key=None):
    """Construye un mensaje STUN. Si se da integrity_key, anade
    MESSAGE-INTEGRITY (HMAC-SHA1). La longitud de la cabecera debe
    incluir ya el atributo MESSAGE-INTEGRITY (24 bytes) cuando se calcula
    el HMAC: asi lo exige la RFC 5389 (seccion 15.4)."""
    body = b"".join(_attr(t, v) for t, v in attrs)
    if integrity_key is None:
        return struct.pack("!HHI", mtype, len(body), MAGIC_COOKIE) + tid + body
    hdr = struct.pack("!HHI", mtype, len(body) + 24, MAGIC_COOKIE) + tid
    mac = hmac.new(integrity_key, hdr + body, hashlib.sha1).digest()
    return hdr + body + _attr(ATTR_MESSAGE_INTEGRITY, mac)


def parse_message(data, tid):
    if len(data) < 20:
        raise CheckError("respuesta STUN demasiado corta (%d bytes)" % len(data))
    mtype, mlen, cookie = struct.unpack("!HHI", data[:8])
    if cookie != MAGIC_COOKIE:
        raise CheckError("la respuesta no es STUN (magic cookie incorrecta)")
    if data[8:20] != tid:
        raise CheckError("transaction-id de la respuesta no coincide")
    attrs = {}
    pos, end = 20, 20 + mlen
    while pos + 4 <= end and pos + 4 <= len(data):
        atype, alen = struct.unpack("!HH", data[pos:pos + 4])
        attrs.setdefault(atype, data[pos + 4:pos + 4 + alen])
        pos += 4 + alen + ((4 - alen % 4) % 4)
    return mtype, attrs


def decode_xor_address(value, tid):
    family = value[1]
    port = struct.unpack("!H", value[2:4])[0] ^ (MAGIC_COOKIE >> 16)
    if family == 0x01:
        raw = struct.unpack("!I", value[4:8])[0] ^ MAGIC_COOKIE
        return "%s:%d" % (socket.inet_ntoa(struct.pack("!I", raw)), port)
    if family == 0x02:
        key = struct.pack("!I", MAGIC_COOKIE) + tid
        raw = bytes(a ^ b for a, b in zip(value[4:20], key))
        return "[%s]:%d" % (socket.inet_ntop(socket.AF_INET6, raw), port)
    raise CheckError("familia de direccion desconocida: %d" % family)


def decode_error(attrs):
    v = attrs.get(ATTR_ERROR_CODE)
    if not v or len(v) < 4:
        return 0, ""
    code = v[2] * 100 + v[3]
    return code, v[4:].decode("utf-8", "replace")


# ---------------------------------------------------------------------
# Transportes: UDP (con reintentos) y TLS (STUN sobre flujo, RFC 5389 7.2.2)
# ---------------------------------------------------------------------
class UdpTransport:
    name = "UDP"

    def __init__(self, host, port, timeout):
        self.addr = (host, port)
        self.timeout = timeout
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def transact(self, msg, tid):
        # UDP puede perder paquetes: 3 intentos con espera creciente,
        # como hace cualquier cliente STUN (RFC 5389 7.2.1, simplificado).
        wait = self.timeout / 3.0
        for _ in range(3):
            self.sock.settimeout(wait)
            self.sock.sendto(msg, self.addr)
            deadline = time.monotonic() + wait
            while time.monotonic() < deadline:
                try:
                    data, _src = self.sock.recvfrom(4096)
                except socket.timeout:
                    break
                if len(data) >= 20 and data[8:20] == tid:
                    return data
            wait *= 1.5
        raise CheckError("sin respuesta por UDP de %s:%d" % self.addr)

    def close(self):
        self.sock.close()


class TlsTransport:
    name = "TLS"

    def __init__(self, host, port, timeout):
        # Sin verificar el certificado A PROPOSITO: hoy es autofirmado, y
        # los clientes WebRTC tampoco validan el cert del TURN (la
        # seguridad la da la credencial HMAC). La caducidad si se mira.
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        raw = socket.create_connection((host, port), timeout=timeout)
        try:
            self.sock = ctx.wrap_socket(raw, server_hostname=host)
        except (ssl.SSLError, OSError) as e:
            raw.close()
            raise CheckError("fallo el handshake TLS con %s:%d (%s)" % (host, port, e))
        self.sock.settimeout(timeout)

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise CheckError("el servidor cerro la conexion TLS")
            buf += chunk
        return buf

    def transact(self, msg, tid):
        try:
            self.sock.sendall(msg)
            hdr = self._recv_exact(20)
            mlen = struct.unpack("!H", hdr[2:4])[0]
            return hdr + self._recv_exact(mlen)
        except socket.timeout:
            raise CheckError("sin respuesta STUN dentro del TLS")

    def cert_days_left(self):
        """Dias que le quedan al certificado del servidor, o None si no se
        puede leer. Con CERT_NONE, getpeercert() devuelve {} y hay que
        decodificar el DER; se usa el decodificador interno de CPython
        (estable desde hace muchas versiones). Si no existe, se omite el
        aviso en vez de fallar."""
        der = self.sock.getpeercert(binary_form=True)
        decoder = getattr(getattr(ssl, "_ssl", None), "_test_decode_cert", None)
        if not der or decoder is None:
            return None
        with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as f:
            f.write(ssl.DER_cert_to_PEM_cert(der))
            path = f.name
        try:
            not_after = decoder(path).get("notAfter")
        except Exception:  # noqa: BLE001 - es solo un aviso extra
            return None
        finally:
            os.unlink(path)
        if not not_after:
            return None
        exp = datetime.fromtimestamp(ssl.cert_time_to_seconds(not_after), timezone.utc)
        return (exp - datetime.now(timezone.utc)).days

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# ---------------------------------------------------------------------
# Comprobaciones
# ---------------------------------------------------------------------
def stun_binding(transport):
    tid = os.urandom(12)
    data = transport.transact(build_message(BINDING_REQUEST, [], tid), tid)
    mtype, attrs = parse_message(data, tid)
    if mtype != BINDING_SUCCESS:
        code, reason = decode_error(attrs)
        raise CheckError("Binding devolvio 0x%04x (error %d %s)" % (mtype, code, reason))
    if ATTR_XOR_MAPPED_ADDRESS in attrs:
        return decode_xor_address(attrs[ATTR_XOR_MAPPED_ADDRESS], tid)
    raise CheckError("Binding sin XOR-MAPPED-ADDRESS")


def rest_credential(secret, name, ttl):
    """Credencial TURN REST (draft-uberti-behave-turn-rest), la misma que
    firma Prosody (mod_external_services) y que acepta coturn con
    use-auth-secret:
        usuario    = "<expiracion_unix>:<nombre>"
        contrasena = base64(HMAC-SHA1(secreto, usuario))
    """
    user = "%d:%s" % (int(time.time()) + ttl, name)
    pwd = base64.b64encode(hmac.new(secret.encode(), user.encode(), hashlib.sha1).digest())
    return user, pwd.decode()


def turn_allocate(transport, secret, name):
    """Allocate en dos pasos (RFC 5766 6.2): la primera peticion sin
    credencial recibe 401 con REALM y NONCE; la segunda va firmada. Al
    final se libera la asignacion (Refresh con LIFETIME=0) para no dejar
    puertos de relay ocupados hasta que caduquen."""
    req_transport = (ATTR_REQUESTED_TRANSPORT, struct.pack("!B3x", PROTO_UDP))

    tid = os.urandom(12)
    mtype, attrs = parse_message(
        transport.transact(build_message(ALLOCATE_REQUEST, [req_transport], tid), tid), tid)
    if mtype == ALLOCATE_SUCCESS:
        raise CheckError("el TURN asigna relay SIN credencial (falta use-auth-secret?)")
    code, reason = decode_error(attrs)
    if code != 401 or ATTR_REALM not in attrs or ATTR_NONCE not in attrs:
        raise CheckError("Allocate inicial: se esperaba 401 con realm/nonce, llego %d %s"
                         % (code, reason))
    realm, nonce = attrs[ATTR_REALM], attrs[ATTR_NONCE]

    user, pwd = rest_credential(secret, name, ttl=300)
    key = hashlib.md5(user.encode() + b":" + realm + b":" + pwd.encode()).digest()

    for _attempt in range(2):  # 2 por si llega 438 (nonce caducado)
        tid = os.urandom(12)
        msg = build_message(ALLOCATE_REQUEST, [
            req_transport,
            (ATTR_USERNAME, user.encode()),
            (ATTR_REALM, realm),
            (ATTR_NONCE, nonce),
        ], tid, integrity_key=key)
        mtype, attrs = parse_message(transport.transact(msg, tid), tid)
        if mtype == ALLOCATE_SUCCESS:
            break
        code, reason = decode_error(attrs)
        if code == 438 and ATTR_NONCE in attrs:
            nonce = attrs[ATTR_NONCE]
            continue
        if code == 401:
            raise CheckError("credencial rechazada (401): TURN_CREDENTIALS del .env "
                             "no coincide con static-auth-secret de coturn, o el reloj "
                             "de este host esta muy desfasado")
        raise CheckError("Allocate autenticado fallo: %d %s" % (code, reason))
    else:
        raise CheckError("Allocate: nonce rechazado dos veces (438)")

    if ATTR_XOR_RELAYED_ADDRESS not in attrs:
        raise CheckError("Allocate OK pero sin XOR-RELAYED-ADDRESS")
    relay = decode_xor_address(attrs[ATTR_XOR_RELAYED_ADDRESS], tid)

    # Liberar la asignacion. Si falla da igual: caduca sola en 10 min.
    try:
        tid = os.urandom(12)
        transport.transact(build_message(REFRESH_REQUEST, [
            (ATTR_LIFETIME, struct.pack("!I", 0)),
            (ATTR_USERNAME, user.encode()),
            (ATTR_REALM, realm),
            (ATTR_NONCE, nonce),
        ], tid, integrity_key=key), tid)
    except (CheckError, OSError):
        pass
    return relay


# ---------------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------------
def read_env(path):
    """Lee KEY=VALUE de un .env sin ejecutarlo (no se hace 'source': un
    .env con comillas o $ podria ejecutar cosas)."""
    values = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            values[k.strip()] = v.strip().strip('"').strip("'")
    return values


def main():
    ap = argparse.ArgumentParser(
        description="Comprueba que el TURN responde (silencioso si todo va bien).")
    ap.add_argument("env_file", nargs="?",
                    help=".env de Jitsi del que leer TURN_CREDENTIALS y TURN_*/TURNS_*")
    ap.add_argument("--host", help="host del TURN (default: TURN_HOST del .env)")
    ap.add_argument("--port", type=int, help="puerto STUN/TURN UDP (default: 3478)")
    ap.add_argument("--turns-port", type=int, help="puerto TURN sobre TLS (default: TURNS_PORT o 443)")
    ap.add_argument("--timeout", type=float, default=6.0, help="segundos por comprobacion")
    ap.add_argument("--cert-min-days", type=int, default=14,
                    help="fallar si al certificado TLS le quedan menos dias (0 = no mirar)")
    ap.add_argument("--no-allocate", action="store_true",
                    help="no probar Allocate (no hace falta el secreto)")
    ap.add_argument("--no-tls", action="store_true", help="no probar el puerto TLS")
    ap.add_argument("--user-name", default="cerroazul-healthcheck",
                    help="nombre en la credencial REST (aparece en el log de coturn)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="imprimir tambien lo que va bien (para pruebas a mano)")
    args = ap.parse_args()

    env = {}
    if args.env_file:
        try:
            env = read_env(args.env_file)
        except OSError as e:
            print("ERROR: no se pudo leer %s: %s" % (args.env_file, e.strerror))
            return 2

    def env_int(key, default):
        try:
            return int(env.get(key, default))
        except ValueError:
            return default

    host = args.host or env.get("TURN_HOST") or "turn.urbcerroazul.com"
    port = args.port or 3478
    turns_host = args.host or env.get("TURNS_HOST") or host
    turns_port = args.turns_port or env_int("TURNS_PORT", 443)
    # El secreto: del .env, o de la variable de entorno (util en cron).
    secret = env.get("TURN_CREDENTIALS") or os.environ.get("TURN_CREDENTIALS", "")
    if not args.no_allocate and (not secret or secret.upper().startswith("CAMBIAR")):
        print("ERROR: falta TURN_CREDENTIALS (pasa el .env como argumento, o usa --no-allocate)")
        return 2

    ok, failures = [], []

    def run(label, func):
        try:
            ok.append("%s: %s" % (label, func()))
        except CheckError as e:
            failures.append("%s: %s" % (label, e))
        except OSError as e:
            failures.append("%s: error de red (%s)" % (label, e.strerror or e))

    def with_transport(cls, h, p, action):
        def inner():
            t = cls(h, p, args.timeout)
            try:
                return action(t)
            finally:
                t.close()
        return inner

    run("STUN UDP %s:%d" % (host, port),
        with_transport(UdpTransport, host, port, stun_binding))
    if not args.no_allocate:
        run("Allocate UDP %s:%d" % (host, port),
            with_transport(UdpTransport, host, port,
                           lambda t: "relay " + turn_allocate(t, secret, args.user_name)))

    if not args.no_tls:
        def tls_binding(t):
            mapped = stun_binding(t)
            if args.cert_min_days > 0:
                days = t.cert_days_left()
                if days is not None and days < args.cert_min_days:
                    raise CheckError("al certificado TLS le quedan %d dias (minimo %d): "
                                     "renovar con scripts/turn-cert.sh"
                                     % (days, args.cert_min_days))
                if days is not None:
                    mapped += " (cert: %d dias)" % days
            return mapped

        run("STUN TLS %s:%d" % (turns_host, turns_port),
            with_transport(TlsTransport, turns_host, turns_port, tls_binding))
        if not args.no_allocate:
            run("Allocate TLS %s:%d" % (turns_host, turns_port),
                with_transport(TlsTransport, turns_host, turns_port,
                               lambda t: "relay " + turn_allocate(t, secret, args.user_name)))

    if args.verbose:
        for line in ok:
            print("  OK     " + line)
    if failures:
        print("🔴 ALERTA: el TURN de Cerro Azul no responde bien")
        for line in failures:
            print("  - " + line)
        print("Verificado %s" % datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z"))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
