#!/usr/bin/env python3
# =====================================================================
# summarize.py - Resumen de una prueba de carga en formato tabla
#
# Lo llama loadtest/run.sh al terminar (y se puede llamar a mano sobre un
# directorio de resultados antiguo). Solo stdlib.
#
# Entrada (en el directorio de resultados):
#   params.env       parametros de la prueba (PARTICIPANTS=..., etc.)
#   malleus.log      salida de Malleus/Maven
#   samples.csv      muestras tomadas durante la prueba por run.sh:
#                    ts,participants,conferences,stress_level,loss_pct,
#                    bitrate_up_kbps,jvb_cpu_pct,prosody_cpu_pct,host_cpus
#   prosody.log      log de prosody durante la prueba
#
# Criterios (Fase 7.3 del plan + objetivos medibles). Cada umbral se
# puede cambiar por variable de entorno (ver THRESHOLDS).
# Salida: tabla Markdown en stdout (y run.sh la guarda en summary.md).
# Codigo de salida: 0 si todos los criterios automaticos pasan, 1 si no.
# =====================================================================
import csv
import os
import re
import sys

THRESHOLDS = {
    # % de clientes que llegan a estar conectados a la vez (pico JVB)
    "MIN_CONNECTED_PCT": float(os.environ.get("MIN_CONNECTED_PCT", "95")),
    # stress_level del JVB: ~1.0 = saturado (lo calcula el propio JVB)
    "MAX_STRESS": float(os.environ.get("MAX_STRESS", "0.7")),
    # CPU del contenedor JVB, en % del total de la maquina
    "MAX_JVB_CPU_PCT": float(os.environ.get("MAX_JVB_CPU_PCT", "70")),
    # CPU de prosody en % de UN nucleo (prosody es de un solo hilo:
    # 100% de un nucleo = saturado aunque la maquina tenga 16)
    "MAX_PROSODY_CPU_PCT": float(os.environ.get("MAX_PROSODY_CPU_PCT", "70")),
    # perdida de paquetes agregada del JVB (%)
    "MAX_LOSS_PCT": float(os.environ.get("MAX_LOSS_PCT", "2")),
    # salida del JVB en % del puerto (PORT_MBPS, default 1000)
    "MAX_NET_PCT": float(os.environ.get("MAX_NET_PCT", "70")),
}

# Mensajes reales de los modulos del repo (prosody/prosody-plugins):
#   mod_rate_limit.lua: "Limiting <ip> due to login/join rate exceeded."
#                       "Enabling throttle (...)"
#   mod_auth_token.lua: "Error verifying token ...", "user is banned"
# No se busca "rate_limit" a secas: el modulo escribe su configuracion
# al cargar ("Loaded configuration") y daria falsos positivos.
PROSODY_PATTERNS = {
    "rate limit": re.compile(r"rate exceeded|Enabling throttle|too many", re.I),
    "autenticacion": re.compile(
        r"Error verifying token|user is banned|not-authorized|not.?allowed|"
        r"SASL.*fail", re.I),
    "error": re.compile(r"\berror\b", re.I),
}


def read_params(path):
    params = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if "=" in line:
                k, v = line.strip().split("=", 1)
                params[k] = v
    return params


def read_samples(path):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            parsed = {}
            for k, v in row.items():
                try:
                    parsed[k] = float(v)
                except (TypeError, ValueError):
                    parsed[k] = None
            rows.append(parsed)
    return rows


def peak(rows, key):
    vals = [r[key] for r in rows if r.get(key) is not None]
    return max(vals) if vals else None


def malleus_result(path):
    """Ultima linea 'Tests run: N, Failures: F, Errors: E, Skipped: S'."""
    if not os.path.exists(path):
        return None
    last = None
    pat = re.compile(r"Tests run:\s*(\d+),\s*Failures:\s*(\d+),\s*Errors:\s*(\d+),\s*Skipped:\s*(\d+)")
    for line in open(path, encoding="utf-8", errors="replace"):
        m = pat.search(line)
        if m:
            last = tuple(int(x) for x in m.groups())
    return last


def count_prosody(path):
    counts = {k: 0 for k in PROSODY_PATTERNS}
    if not os.path.exists(path):
        return None
    for line in open(path, encoding="utf-8", errors="replace"):
        for k, pat in PROSODY_PATTERNS.items():
            if pat.search(line):
                counts[k] += 1
    return counts


def fmt(v, suffix="", nd=1):
    return "—" if v is None else ("%.*f%s" % (nd, v, suffix))


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    params = read_params(os.path.join(d, "params.env"))
    rows = read_samples(os.path.join(d, "samples.csv"))
    n = int(params.get("PARTICIPANTS", "0") or 0)
    port_mbps = float(params.get("PORT_MBPS", "1000") or 1000)
    t = THRESHOLDS

    results = []  # (criterio, umbral, medido, estado)

    def add(name, threshold, measured, ok):
        state = "SIN DATOS" if ok is None else ("PASA" if ok else "FALLA")
        results.append((name, threshold, measured, state))

    mr = malleus_result(os.path.join(d, "malleus.log"))
    if mr:
        bad = mr[1] + mr[2]
        add("Malleus sin fallos ni errores", "0", "%d de %d" % (bad, mr[0]), bad == 0)
    else:
        add("Malleus sin fallos ni errores", "0", "—", None)

    p = peak(rows, "participants")
    pct = (100.0 * p / n) if (p is not None and n) else None
    add("Clientes conectados (pico en el JVB)", ">= %.0f%% de %d" % (t["MIN_CONNECTED_PCT"], n),
        "%s (%s)" % (fmt(p, "", 0), fmt(pct, "%")),
        None if pct is None else pct >= t["MIN_CONNECTED_PCT"])

    s = peak(rows, "stress_level")
    add("stress_level del JVB (pico)", "< %.2f" % t["MAX_STRESS"], fmt(s, "", 2),
        None if s is None else s < t["MAX_STRESS"])

    # docker stats da % de UN nucleo; se normaliza al total de la maquina.
    cpus = peak(rows, "host_cpus") or 1
    jc = peak(rows, "jvb_cpu_pct")
    jc_host = jc / cpus if jc is not None else None
    add("CPU del JVB (pico, % de la maquina)", "< %.0f%%" % t["MAX_JVB_CPU_PCT"], fmt(jc_host, "%"),
        None if jc_host is None else jc_host < t["MAX_JVB_CPU_PCT"])

    pc = peak(rows, "prosody_cpu_pct")
    add("CPU de Prosody (pico, % de 1 nucleo)", "< %.0f%%" % t["MAX_PROSODY_CPU_PCT"], fmt(pc, "%"),
        None if pc is None else pc < t["MAX_PROSODY_CPU_PCT"])

    lo = peak(rows, "loss_pct")
    add("Perdida de paquetes del JVB (pico)", "< %.1f%%" % t["MAX_LOSS_PCT"], fmt(lo, "%", 2),
        None if lo is None else lo < t["MAX_LOSS_PCT"])

    up = peak(rows, "bitrate_up_kbps")
    net_pct = (up / 1000.0 / port_mbps * 100.0) if up is not None else None
    add("Salida de red del JVB (pico, %% de %.0f Mbit/s)" % port_mbps, "< %.0f%%" % t["MAX_NET_PCT"],
        "%s Mbit/s (%s)" % (fmt(up / 1000.0 if up is not None else None, "", 0), fmt(net_pct, "%")),
        None if net_pct is None else net_pct < t["MAX_NET_PCT"])

    pros = count_prosody(os.path.join(d, "prosody.log"))
    for k in ("rate limit", "autenticacion"):
        v = None if pros is None else pros[k]
        add("Log de Prosody: lineas de %s" % k, "0", fmt(v, "", 0), None if v is None else v == 0)
    if pros is not None:
        results.append(("Log de Prosody: lineas con 'error' (informativo)", "revisar",
                        str(pros["error"]), "INFO"))

    results.append(("Audio sin cortes en 3 dispositivos reales", "si", "comprobar a mano", "MANUAL"))
    results.append(("Ninguna desconexion masiva (curva de participantes)", "sin caidas bruscas",
                    "ver samples.csv", "MANUAL"))

    print("## Resultado de la prueba de carga")
    print()
    print("Directorio: `%s`  " % os.path.abspath(d))
    print("Parametros: " + ", ".join("%s=%s" % kv for kv in sorted(params.items())
                                     if kv[0] not in ("JWT",)))
    print("Muestras: %d" % len(rows))
    print()
    print("| Criterio | Umbral | Medido | Estado |")
    print("|---|---|---|---|")
    for r in results:
        print("| %s | %s | %s | **%s** |" % r)
    auto = [r for r in results if r[3] in ("PASA", "FALLA", "SIN DATOS")]
    failed = [r for r in auto if r[3] != "PASA"]
    print()
    if failed:
        print("**VEREDICTO: NO APROBADA** (%d criterio(s) automaticos sin pasar). "
              "Los MANUAL tambien deben cumplirse." % len(failed))
        return 1
    print("**VEREDICTO: criterios automaticos APROBADOS.** Falta confirmar los MANUAL "
          "(3 dispositivos reales y curva sin caidas) para dar la prueba por aprobada.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
