@echo off
setlocal enabledelayedexpansion

rem ─────────────────────────────────────────────────────────────────────────
rem  Start zorkpbx on Windows with Podman or Docker, whichever is installed.
rem
rem  Config: edit .env (copy .env.example first), or set the variables in
rem  your shell before running this.
rem ─────────────────────────────────────────────────────────────────────────

set "IMAGE=ghcr.io/gschmidl/zorkpbx-docker:latest"
set "NAME=zorkpbx"

cd /d "%~dp0"

rem ── Pick a container engine ──────────────────────────────────────────────
set "ENGINE="
where podman >nul 2>&1 && set "ENGINE=podman"
if not defined ENGINE where docker >nul 2>&1 && set "ENGINE=docker"
if not defined ENGINE (
  echo Neither podman nor docker was found on PATH.
  echo   winget install -e --id RedHat.Podman
  exit /b 1
)
echo Using %ENGINE%.

rem ── Load .env if present (KEY=VALUE, ignoring blanks and # comments) ─────
if exist ".env" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in (".env") do (
    if not "%%~A"=="" set "%%~A=%%~B"
  )
)
if not defined SIP_USER set "SIP_USER=6001"
if not defined SIP_PASSWORD set "SIP_PASSWORD=infocom"

if not exist "saves" mkdir "saves"

rem ── Pull unless the image is already local ───────────────────────────────
%ENGINE% image exists %IMAGE% >nul 2>&1
if errorlevel 1 (
  echo Pulling %IMAGE% ...
  %ENGINE% pull %IMAGE%
  if errorlevel 1 (
    echo.
    echo Could not pull the image. To build it locally instead:
    echo   %ENGINE% build -t %IMAGE% .
    exit /b 1
  )
)

echo Stopping any existing %NAME% container...
%ENGINE% rm -f %NAME% >nul 2>&1

rem ── Only pass the optional vars that are actually set ────────────────────
set "ENVARGS=-e SIP_USER=%SIP_USER%"
if defined SIP_PASSWORD      set "ENVARGS=!ENVARGS! -e SIP_PASSWORD=%SIP_PASSWORD%"
if defined SIP_EXTERNAL_IP   set "ENVARGS=!ENVARGS! -e SIP_EXTERNAL_IP=%SIP_EXTERNAL_IP%"
if defined SIP_LOCAL_NET     set "ENVARGS=!ENVARGS! -e SIP_LOCAL_NET=%SIP_LOCAL_NET%"
if defined ZORKPBX_TTS_ENGINE set "ENVARGS=!ENVARGS! -e ZORKPBX_TTS_ENGINE=%ZORKPBX_TTS_ENGINE%"

echo Starting %NAME%...
%ENGINE% run -d --name %NAME% ^
  -p 5060:5060/udp -p 10000-10020:10000-10020/udp ^
  -v "%cd%\saves:/opt/zorkpbx/saves" ^
  -v zorkpbx-audio:/opt/zorkpbx/audio ^
  !ENVARGS! ^
  %IMAGE%

if errorlevel 1 (
  echo.
  echo Failed to start the container.
  exit /b 1
)

echo.
echo zorkpbx is up. Waiting for it to report its SIP credentials...
timeout /t 4 /nobreak >nul
%ENGINE% logs %NAME% 2>&1 | findstr /c:"[zorkpbx]"

echo.
echo Register a softphone to udp://^<this-host^>:5060 and dial 5001.
echo Logs:  %ENGINE% logs -f %NAME%
echo Stop:  %ENGINE% rm -f %NAME%

endlocal
