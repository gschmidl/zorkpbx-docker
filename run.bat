@echo off
setlocal

rem ─────────────────────────────────────────────────────────────────────────
rem  Start zorkpbx on Windows with Podman or Docker, whichever is installed.
rem  Edit the two values below if you want different credentials.
rem ─────────────────────────────────────────────────────────────────────────

set "SIP_USER=6001"
set "SIP_PASSWORD=infocom"

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

rem ── Is the engine actually up? ───────────────────────────────────────────
rem A fresh Podman install has no virtual machine until `podman machine init`,
rem and Docker Desktop may simply not be running. Both fail every later step
rem with errors that read like a network or registry problem, so check once and
rem say what is actually wrong.
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
  exit /b 1
)

if not exist "saves" mkdir "saves"

rem ── Always pull ──────────────────────────────────────────────────────────
rem The tag is :latest, so "is it already local?" is the wrong question — a
rem stale local copy is exactly how you end up running an old image and
rem wondering why a fix did not land. Pulling an up-to-date image only costs a
rem manifest check. Set SKIP_PULL=1 to work offline.
rem
rem (`image inspect` rather than `image exists`: the latter is podman-only.)
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
  exit /b 1
)

rem `ping`, not `timeout`: timeout aborts with "input redirection is not
rem supported" whenever this script runs with stdin redirected (a pipe, a CI
rem step, or cmd /c from another shell).
ping -n 6 127.0.0.1 >nul 2>&1

echo.
%ENGINE% logs %NAME% 2>&1 | findstr /c:"[zorkpbx]"
echo.
echo Register a softphone to udp://^<this-host^>:5060 as %SIP_USER% / %SIP_PASSWORD%, then dial 5001.
echo Logs:  %ENGINE% logs -f %NAME%
echo Stop:  %ENGINE% rm -f %NAME%

endlocal
