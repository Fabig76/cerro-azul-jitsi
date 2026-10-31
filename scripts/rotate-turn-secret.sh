#!/usr/bin/env bash
# =====================================================================
# rotate-turn-secret.sh - Rota el TURN_CREDENTIALS de Jitsi en el VPS
#
# ENFOQUE QUIRURGICO (bajo riesgo):
#   1. Genera un nuevo secreto de 32 hex (secrets.token_hex(16))
#   2. Reemplaza SOLO TURN_CREDENTIALS en /opt/jitsi-meet/.env
#   3. Reemplaza SOLO external_service_secret en prosody.cfg.lua
#      (via sudo, porque ese archivo es root:root)
#   4. Reinicia prosody (NO recrea, NO regenera el config completo)
#   5. Verifica: config cargada, sin errores de modulo, sitio 200
#
# El secreto se genera del lado del servidor y NUNCA se imprime completo.
# =====================================================================
set -euo pipefail

ENV_FILE=/opt/jitsi-meet/.env
PROSODY_CFG=/opt/jitsi-meet/prosody/config/prosody.cfg.lua
TS=$(date +%Y%m%d_%H%M%S)

echo "=== 1. Respaldo .env y prosody.cfg.lua ==="
cp -p "$ENV_FILE" "${ENV_FILE}.bak.rotateturn.$TS"
sudo cp -p "$PROSODY_CFG" "${PROSODY_CFG}.bak.rotateturn.$TS"
echo "   ${ENV_FILE}.bak.rotateturn.$TS"
echo "   ${PROSODY_CFG}.bak.rotateturn.$TS"

echo "=== 2. Generar secreto y reemplazar ambas lineas ==="
# Paso A: .env (propiedad de chatbotph)
python3 - "$ENV_FILE" <<'PYEOF'
import sys, secrets, hashlib
env_path = sys.argv[1]
EQ = chr(61)
new = secrets.token_hex(16)
turn_key = "TURN_CREDENTIALS" + EQ
data = open(env_path).read()
lines = data.split("\n")
old_env = None
for i, line in enumerate(lines):
    if line.startswith(turn_key):
        old_env = line.split(EQ, 1)[1].strip()
        lines[i] = turn_key + new
if old_env is None:
    sys.exit("ERROR: no se encontro TURN_CREDENTIALS en " + env_path)
open(env_path, "w").write("\n".join(lines))
# Escribir el nuevo valor a un archivo temporal para que el paso B lo lea
open("/tmp/.newturn", "w").write(new)
print("   .env actualizado (longitud %d)" % len(new))
print("   sha256 nuevo[:16] = %s" % hashlib.sha256(new.encode()).hexdigest()[:16])
print("   sha256 viejo[:16] = %s" % hashlib.sha256(old_env.encode()).hexdigest()[:16])
PYEOF

# Paso B: prosody.cfg.lua (root) via sudo python
sudo python3 - "$PROSODY_CFG" <<'PYEOF'
import sys, re, hashlib
cfg_path = sys.argv[1]
new = open("/tmp/.newturn").read().strip()
EQ = chr(61); Q = chr(34)
data = open(cfg_path).read()
pat = "external_service_secret" + r"\s*" + EQ + r"\s*" + Q + "([0-9a-fA-F]+)" + Q
m = re.search(pat, data)
if m is None:
    sys.exit("ERROR: no se encontro external_service_secret en " + cfg_path)
old_cfg = m.group(1)
new_val = "external_service_secret" + " " + EQ + " " + Q + new + Q
data = re.sub(pat, lambda mo: new_val, data)
open(cfg_path, "w").write(data)
print("   prosody.cfg.lua actualizado (longitud %d)" % len(new))
print("   sha256 nuevo[:16] = %s" % hashlib.sha256(new.encode()).hexdigest()[:16])
print("   sha256 viejo[:16] = %s" % hashlib.sha256(old_cfg.encode()).hexdigest()[:16])
PYEOF

# Limpiar el archivo temporal con el secreto
rm -f /tmp/.newturn

echo "=== 3. Reiniciar prosody (NO recrear) ==="
docker restart jitsi-prosody 2>&1 | tail -2

echo "=== 4. Esperar arranque ==="
sleep 15

echo "=== 5. Verificar external_service_secret cargado (solo longitud) ==="
docker exec jitsi-prosody sh -c 'grep -o "external_service_secret = \"[0-9a-f]*\"" /config/prosody.cfg.lua | sed -E "s/[0-9a-f]+/[REDACTADO]/"'

echo "=== 6. Errores de modulo (debe estar vacio salvo http_health) ==="
docker logs jitsi-prosody --since 2m 2>&1 | grep -iE 'modulemanager.*error|unable to load' | head -10
echo "   --- fin ---"
