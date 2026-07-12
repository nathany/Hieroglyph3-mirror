@echo off
rem Build and run one of the sample apps:
rem   run basic_window
rem Extra odin flags pass through:
rem   run basic_window -o:speed
rem Drop -subsystem:windows below if you want a console for debug prints.
setlocal
if "%~1"=="" (
    echo usage: run ^<app_name^> [extra odin flags]
    echo apps:
    for /d %%d in (apps\*) do echo   %%~nd
    exit /b 1
)
set APP=%~1
shift
if not exist bin mkdir bin
odin run apps\%APP% -collection:glyph=glyph -out:bin\%APP%.exe -subsystem:windows -debug %1 %2 %3 %4 %5
