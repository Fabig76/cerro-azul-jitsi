/* =====================================================================
 * custom-interface_config.js - Fase 3: sala grande - Cerro Azul
 *
 * El entrypoint de jitsi/web copia /defaults/interface_config.js a
 * /config/interface_config.js y CONCATENA este fichero al final:
 *     cat /config/custom-interface_config.js >> /config/interface_config.js
 * Por eso se escribe `interfaceConfig.X = ...` (JS plano, sin export).
 *
 * interface_config.js esta OBSOLETO en stable-11031 (lo dice la propia
 * plantilla: "All options will eventually be moved to config.js"). Aqui
 * va SOLO lo que no tiene equivalente en config.js.
 *
 * La barra de herramientas NO va aqui: interfaceConfig.TOOLBAR_BUTTONS
 * solo se usa si config.toolbarButtons no es un array (verificado en
 * app.bundle.min.js). Esta en custom-config.js como config.toolbarButtons.
 *
 * Verificar: ./scripts/verify-custom-config.sh (comprueba tambien este
 * fichero contra /defaults/interface_config.js y el bundle).
 * ===================================================================== */

// El fondo difuminado del video grande es una segunda copia del video
// renderizada y desenfocada en cada cliente: CPU/GPU que los moviles
// modestos de los residentes no deberian gastar en una asamblea.
interfaceConfig.DISABLE_VIDEO_BACKGROUND = true;
