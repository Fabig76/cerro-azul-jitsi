@echo off
rem =====================================================================
rem convertir-mp4.bat - Convierte grabaciones .webm del panel a MP4 (Windows)
rem
rem - Arrastra uno o varios .webm ENCIMA de este archivo, o haz doble clic
rem   para convertir TODOS los Asamblea-*.webm de Descargas que aun no
rem   tengan su .mp4.
rem - Resultado: MP4 H.264 + AAC con +faststart, junto al original. El
rem   .webm no se toca ni se borra.
rem - Necesita ffmpeg. Si no esta, explica como instalarlo (winget).
rem - SmartScreen puede avisar la primera vez: "Mas informacion" -> "Ejecutar".
rem =====================================================================
setlocal EnableExtensions
chcp 65001 >nul
set "PATH=%PATH%;%LOCALAPPDATA%\Microsoft\WinGet\Links"
echo == Convertir grabaciones a MP4 ==
echo.

where ffmpeg >nul 2>&1
if errorlevel 1 goto :sin_ffmpeg

set "ERRORES=0"
if "%~1"=="" goto :todas
:args
if "%~1"=="" goto :fin
call :convertir "%~f1"
shift
goto :args

:todas
set "HAY=0"
for %%F in ("%USERPROFILE%\Downloads\Asamblea-*.webm") do (
  set "HAY=1"
  call :convertir "%%~fF"
)
if "%HAY%"=="0" echo No hay archivos Asamblea-*.webm en Descargas.
goto :fin

:convertir
if not exist "%~1" (echo No existe: %~1 & set "ERRORES=1" & exit /b 1)
if exist "%~dpn1.mp4" (echo Ya existe, no se toca: %~dpn1.mp4 & exit /b 0)
echo Convirtiendo: %~nx1
rem yuv420p + dimensiones pares: lo que exigen los reproductores y libx264.
ffmpeg -hide_banner -loglevel error -stats -i "%~1" -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -preset veryfast -crf 26 -r 15 -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart "%~dpn1.mp4"
if errorlevel 1 (
  echo ERROR al convertir %~nx1. El original sigue intacto.
  if exist "%~dpn1.mp4" del "%~dpn1.mp4"
  set "ERRORES=1"
  exit /b 1
)
echo Listo: %~dpn1.mp4
exit /b 0

:sin_ffmpeg
echo No está instalado ffmpeg, que es el programa que hace la conversión.
echo.
echo Opción 1 (recomendada): abre "Símbolo del sistema" o "Terminal" y escribe:
echo     winget install --id Gyan.FFmpeg -e
echo   Después cierra esta ventana y vuelve a abrir este archivo.
echo.
echo Opción 2 (sin comandos): instala HandBrake (https://handbrake.fr), abre el .webm,
echo   elige el ajuste "Fast 720p30" y pulsa "Start". Ver docs/GRABACION-ADMIN.md.
echo.
choice /C SN /M "¿Instalar ffmpeg ahora con winget"
if errorlevel 2 goto :fin_err
winget install --id Gyan.FFmpeg -e
echo.
echo Si la instalación terminó bien, cierra esta ventana y vuelve a abrir este archivo.
goto :fin_err

:fin
echo.
if "%ERRORES%"=="1" (echo Hubo errores. Revisa los mensajes de arriba.) else (echo Terminado.)
pause
endlocal
exit /b %ERRORES%

:fin_err
echo.
pause
endlocal
exit /b 1
