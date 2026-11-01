#!/bin/bash
# =====================================================================
# convertir-mp4.command - Convierte grabaciones .webm del panel a MP4 (macOS)
#
# Doble clic en Finder. La primera vez macOS lo bloquea (Gatekeeper):
# clic derecho -> Abrir -> Abrir. Si dice "permiso denegado", en Terminal:
#   chmod +x ~/Downloads/convertir-mp4.command
#
# - Sin archivos: pregunta cual convertir (arrastra el .webm a la ventana y
#   pulsa Enter) o, con Enter vacio, convierte TODOS los Asamblea-*.webm de
#   Descargas que aun no tengan su .mp4.
# - Resultado: MP4 H.264 + AAC con +faststart, junto al original. El .webm
#   no se toca ni se borra.
# - Necesita ffmpeg. Si no esta, explica como instalarlo y no hace nada mas.
# =====================================================================
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # Finder no carga el PATH de Homebrew

fin() { echo; read -r -p "Pulsa Enter para cerrar esta ventana. " _; exit "${1:-0}"; }

echo "== Convertir grabaciones a MP4 =="
echo

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "No está instalado ffmpeg, que es el programa que hace la conversión."
    echo
    echo "Opción 1 (con Homebrew, recomendado):"
    if command -v brew >/dev/null 2>&1; then
        echo "  Abre la app Terminal y escribe:   brew install ffmpeg"
    else
        echo "  1. Instala Homebrew siguiendo https://brew.sh (copiar una línea en Terminal)."
        echo "  2. Después, en Terminal:   brew install ffmpeg"
    fi
    echo "  Luego vuelve a abrir este archivo."
    echo
    echo "Opción 2 (sin Terminal): instala HandBrake (https://handbrake.fr), abre el .webm,"
    echo "  elige el ajuste «Fast 720p30» y pulsa «Start». Ver docs/GRABACION-ADMIN.md."
    fin 1
fi

convertir() {
    local in="$1"
    if [ ! -f "$in" ]; then echo "No existe: $in"; return 1; fi
    local out="${in%.*}.mp4"
    if [ -e "$out" ]; then echo "Ya existe, no se toca: $out"; return 0; fi
    echo "Convirtiendo: $(basename "$in")"
    # yuv420p + dimensiones pares: lo que exigen QuickTime y libx264.
    if ffmpeg -hide_banner -loglevel error -stats -i "$in" \
        -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -preset veryfast -crf 26 -r 15 -pix_fmt yuv420p \
        -c:a aac -b:a 96k -movflags +faststart "$out"; then
        echo "Listo: $out"
    else
        echo "ERROR al convertir $(basename "$in"). El original sigue intacto."
        rm -f "$out"
        return 1
    fi
}

errores=0
if [ "$#" -gt 0 ]; then
    for f in "$@"; do convertir "$f" || errores=1; done
else
    echo "Arrastra aquí el archivo .webm y pulsa Enter."
    read -r -p "(Enter sin nada = todas las grabaciones de Descargas): " ruta
    # Al arrastrar, Terminal escapa los espacios ("\ ") o pone comillas.
    ruta="${ruta%"${ruta##*[![:space:]]}"}"
    ruta="${ruta#\'}"; ruta="${ruta%\'}"; ruta="${ruta#\"}"; ruta="${ruta%\"}"
    ruta="${ruta//\\ / }"
    if [ -n "$ruta" ]; then
        convertir "$ruta" || errores=1
    else
        shopt -s nullglob
        lista=("$HOME/Downloads"/Asamblea-*.webm)
        if [ "${#lista[@]}" -eq 0 ]; then echo "No hay archivos Asamblea-*.webm en Descargas."; fi
        for f in "${lista[@]}"; do convertir "$f" || errores=1; done
    fi
fi
fin "$errores"
