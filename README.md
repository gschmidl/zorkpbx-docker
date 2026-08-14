# zorkpbx-docker

The smallest practical container that runs [ZorkPBX](https://github.com/aejx00/zorkpbx):
Alpine Linux + Asterisk (PJSIP) + `dfrotz` (built from source, no curses) +
espeak + sox + piper (neural TTS) + whisper.cpp (local speech-to-text) +
Zork I/II/III themselves, bundled. 

## Install Podman

```
winget install -e --id RedHat.Podman
podman machine init
podman machine start
```

## Build

```bash
docker build -t zorkpbx-docker .
```

## Run

`run.bat`

## Test

* Start MicroSIP.
* Make changes as below if it's not connecting.
* Dial **5001**.
* You should hear ZorkPBX answer and read the opening room description.
   Press `0` for the in-call help menu, `1` for voice input.

## Running on Windows with Podman Desktop

  ```
  wsl -l -v                                              # find the distro name
  wsl -d podman-machine-default ip -4 addr show          # find its IP (hostname may be missing)
  ```
  Use that IP for both **SIP Server** and **Domain** in the softphone.
