@echo off
setlocal

rem ── Config — edit these if you want different values ────────────────────
set SIP_USER=6001
set SIP_PASSWORD=infocom

cd /d "%~dp0"

echo Stopping any existing zorkpbx container...
podman rm -f zorkpbx >nul 2>&1

echo Starting zorkpbx...
podman run -d --name zorkpbx ^
  -p 5060:5060/udp -p 10000-10020:10000-10020/udp ^
  -v "%cd%\saves:/opt/zorkpbx/saves" ^
  -v zorkpbx-audio:/opt/zorkpbx/audio ^
  -e SIP_USER=%SIP_USER% ^
  -e SIP_PASSWORD=%SIP_PASSWORD% ^
  zorkpbx-docker

if errorlevel 1 (
  echo.
  echo Failed to start the container. Is the image built?
  echo   podman build -t zorkpbx-docker .
  exit /b 1
)

timeout /t 2 /nobreak >nul

echo.
echo zorkpbx is up. SIP extension %SIP_USER%, password %SIP_PASSWORD%.

endlocal
