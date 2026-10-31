# prosody-plugins-custom

Montado en `/prosody-plugins-custom` dentro del contenedor de Prosody.

La imagen oficial `jitsi/prosody` **no** incluye los módulos Lua propios de
Jitsi (`mod_auth_token`, `mod_room_metadata`, `mod_av_moderation`, ...).
Los plugins oficiales se instalan aparte con:

```bash
./scripts/install-prosody-plugins.sh
```

que los deja en `prosody/prosody-plugins/` (montado en `/prosody-plugins`).

Este directorio es para **plugins propios** del proyecto Cerro Azul, si alguna
vez hacen falta. La imagen de Jitsi incluye `include "custom-jitsi.lua"`-style
hooks; un `.lua` colocado aquí se carga sin tocar los archivos de la imagen.
