# =====================================================================
# turn/ - Servidor TURN de Cerro Azul (Fase 4)
#
# QUE ES ESTO
#   Un servidor TURN/STUN propio. Sin TURN, quien este en una red
#   corporativa o en un operador movil que bloquea UDP entra a la sala
#   pero NO OYE NADA: el cliente solo ve el candidato 'host' (UDP
#   directo) y no hay por donde sacar el audio. Con TURN, el medio se
#   relayiza: el cliente sale por TCP/TLS y el servidor le devuelve los
#   paquetes del JVB.
#
# POR QUE ESTA EN OTRO SERVIDOR
#   El TURN necesita el puerto 443 y en el servidor de Jitsi ese
#   puerto (TCP) lo usa Caddy. En el servidor del TURN el 443 esta
#   libre, asi que se puede ofrecer TURN sobre TLS en 443, que es la
#   variante que entra en las redes mas restrictivas.
#
# QUE HAY QUE CONFIGURAR EN JITSI (.env del servidor de Jitsi)
#   TURN_CREDENTIALS=<secreto>      # el MISMO que usa coturn
#   TURN_HOST=<IP o nombre del TURN>
#   TURN_PORT=3478
#   TURN_TRANSPORT=udp,tcp
#   TURNS_HOST=<IP o nombre del TURN>
#   TURNS_PORT=443
#   STUN_HOST=<IP o nombre del TURN>
#   STUN_PORT=3478
#
#   Prosody convierte esas variables en el bloque 'external_services'
#   (ver /defaults/prosody.cfg.lua de la imagen), que es lo que viaja
#   al cliente. Cada participante recibe una credencial TURN TEMPORAL
#   firmada por Prosody con TURN_CREDENTIALS: el secreto nunca sale del
#   servidor.
#
# DESPLEGUE
#   En el servidor del TURN:
#     mkdir -p /opt/coturn && cd /opt/coturn
#     # copiar turnserver.conf y docker-compose.turn.yml
#     # poner el secreto real en static-auth-secret
#     # (el fichero debe ser legible por el usuario del contenedor)
#     chown 65534:65534 turnserver.conf && chmod 600 turnserver.conf
#     docker compose -f docker-compose.turn.yml up -d
#
#   Reglas de firewall (ufw en el servidor del TURN):
#     ufw allow 3478/udp ; ufw allow 3478/tcp
#     ufw allow 443/udp
#     ufw allow 49160:49200/udp     # puertos de relay
#
# COMPROBAR QUE FUNCIONA
#   En el servidor del TURN (dentro del contenedor):
#     turnutils_uclient -v -t -y <IP_TURN> -r urbcerroazul.com \
#         -u "<timestamp>:jitsi-test" -W <secreto> -C : -p 3478 \
#         -e <IP_JVB>:10000 <IP_TURN>
#   Debe imprimir "success" y "Received relay addr: ...". La opcion -W
#   hace que el propio cliente calcule la credencial REST a partir del
#   secreto plano (mismo HMAC que usa Prosody).
#
# NOTAS IMPORTANTES
#   - coturn solo acepta UN 'listening-port'. Si se pone dos veces, el
#     segundo SOBREESCRIBE al primero y el primero deja de escuchar (asi
#     se comporto en la primera prueba: al anadir 443 desaparecio 3478).
#     Para mas de un puerto UDP esta 'alt-listening-port'.
#   - El contenedor corre como nobody (65534): el turnserver.conf (con
#     el secreto) y la clave privada del certificado deben ser de ese
#     usuario, o no los podra leer.
#   - El healthcheck mira /proc/net (la imagen no trae netstat ni ss).
# =====================================================================
