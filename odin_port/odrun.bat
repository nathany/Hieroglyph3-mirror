@echo off
rem Build and run one sample app.
rem   PowerShell:  .\odrun.bat rotating_cube   (needs .\ — cwd isn't searched)
rem   cmd:         odrun rotating_cube
rem The distinctive name avoids colliding with any other run.bat on PATH.
setlocal
cd /d "%~dp0"

if "%~1"=="" (
    echo usage: odrun ^<app_name^>
    echo apps:
    for /d %%d in (apps\*) do echo    %%~nd
    goto :eof
)

if not exist bin mkdir bin
odin run "apps\%~1" -collection:glyph=glyph -out:"bin\%~1.exe" -subsystem:windows -debug
