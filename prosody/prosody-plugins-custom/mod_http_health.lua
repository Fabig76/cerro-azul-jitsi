-- mod_http_health.lua
--
-- Modulo que expone un endpoint HTTP /health en Prosody.
--
-- POR QUE EXISTE:
-- El servicio `70-register-setup` de la imagen jitsi/prosody espera a que
-- Prosody responda en http://127.0.0.1:5280/health antes de registrar las
-- cuentas de los componentes (focus@, jvb@). Si ese endpoint no existe,
-- el script agota los 60 intentos y hace `exit 1` SIN registrar las cuentas.
-- Como consecuencia, Jicofo y JVB no pueden autenticarse contra Prosody
-- (SASLError not-authorized) y el bridge queda con 0 bridges: las reuniones
-- no transmiten audio ni video.
--
-- El modulo `mod_http_health` viene en el paquete Debian `prosody-modules`,
-- que NO esta instalado en la imagen de Jitsi (verificado: el error es
-- "Unable to load module 'http_health': .../mod_http_health/mod_http_health.lua:
-- No such file or directory"), y tampoco viene en el paquete
-- `jitsi-meet-prosody` (verificado: 85 modulos .lua, ninguno de health).
--
-- Este archivo es una implementacion minima y equivalente, escrita para el
-- repo de Cerro Azul. Va en /prosody-plugins-custom, que la propia imagen
-- soporta (ver /etc/cont-init.d/10-config: chown de /prosody-plugins-custom).
--
-- Nota: el modulo es de solo lectura y no expone datos sensibles: devuelve
-- un 200 con el texto "OK". Solo escucha en las interfaces HTTP internas.

module:depends("http");

module:provides("http", {
	default_path = "health";
	route = {
		GET = function (event)
			return 200, { ["Content-Type"] = "text/plain; charset=utf-8" }, "OK\n";
		end;
	};
});
