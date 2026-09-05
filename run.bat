@echo off
setlocal

set "SIP_USER=6001"
set "SIP_PASSWORD=infocom"

set "IMAGE=ghcr.io/gschmidl/zorkpbx-docker:latest"
set "NAME=zorkpbx"

cd /d "%~dp0"

set "ENGINE="
where podman >nul 2>&1 && set "ENGINE=podman"
if not defined ENGINE where docker >nul 2>&1 && set "ENGINE=docker"
if not defined ENGINE (
  echo Neither podman nor docker was found on PATH.
  echo   winget install -e --id RedHat.Podman
  pause
  exit /b 1
)
echo Using %ENGINE%.

%ENGINE% info >nul 2>&1
if errorlevel 1 (
  echo.
  echo %ENGINE% is installed but not responding.
  if /i "%ENGINE%"=="podman" (
    echo Run these once, then start this script again:
    echo   podman machine init
    echo   podman machine start
  ) else (
    echo Start Docker Desktop and wait for it to report "running", then try again.
  )
  pause
  exit /b 1
)

if not exist "saves" mkdir "saves"

if defined SKIP_PULL (
  echo Skipping pull ^(SKIP_PULL is set^).
) else (
  echo Pulling %IMAGE% ...
  %ENGINE% pull %IMAGE%
  if errorlevel 1 (
    %ENGINE% image inspect %IMAGE% >nul 2>&1
    if errorlevel 1 (
      echo.
      echo Could not pull %IMAGE%, and there is no local copy.
      echo To build it locally instead:
      echo   %ENGINE% build -t %IMAGE% .
      pause
      exit /b 1
    )
    echo Pull failed - falling back to the local copy.    
  )
)

echo Stopping any existing %NAME% container...
%ENGINE% rm -f %NAME% >nul 2>&1

echo Starting %NAME%...
%ENGINE% run -d --name %NAME% ^
  -p 5060:5060/udp -p 10000-10020:10000-10020/udp ^
  -v "%cd%\saves:/opt/zorkpbx/saves" ^
  -v zorkpbx-audio:/opt/zorkpbx/audio ^
  -e SIP_USER=%SIP_USER% ^
  -e SIP_PASSWORD=%SIP_PASSWORD% ^
  %IMAGE%

if errorlevel 1 (
  echo.
  echo Failed to start the container.
  pause
  exit /b 1
)

ping -n 6 127.0.0.1 >nul 2>&1

set "HOSTIP="
set "HOSTHINT="
if /i "%ENGINE%"=="podman" (
  set "HOSTHINT=wsl -d podman-machine-default hostname -I"
  for /f "tokens=4" %%i in ('wsl -d podman-machine-default ip -4 -o addr show eth0 2^>nul') do set "HOSTIP=%%i"
  if not defined HOSTIP for /f "tokens=1" %%i in ('wsl -d podman-machine-default hostname -I 2^>nul') do set "HOSTIP=%%i"
) else (
  set "HOSTHINT=ipconfig"
  set "HOSTIP=localhost"
)

if defined HOSTIP for /f "delims=/ " %%i in ("%HOSTIP%") do set "HOSTIP=%%i"
if defined HOSTIP (
  echo %HOSTIP%| findstr /r /c:"^localhost$" /c:"^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul
  if errorlevel 1 set "HOSTIP="
)

if defined HOSTIP (
  echo Register a softphone to udp://%HOSTIP%:5060 as %SIP_USER% / %SIP_PASSWORD%, then dial 5001.
  if /i "%ENGINE%"=="podman" echo That address belongs to the podman machine and changes when it restarts.
) else (
  echo Register a softphone to udp://[host-address]:5060 as %SIP_USER% / %SIP_PASSWORD%, then dial 5001.
  echo Could not read the host address automatically. Get it with:
  echo   %HOSTHINT%
)
echo Logs:  %ENGINE% logs -f %NAME%
echo Stop:  %ENGINE% rm -f %NAME%
pause

endlocal
