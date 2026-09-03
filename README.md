# zorkpbx-docker

Zork I, II and III over a phone line, in one container.

The smallest practical image that runs [ZorkPBX](https://github.com/aejx00/zorkpbx):
Alpine Linux + Asterisk (PJSIP) + `dfrotz` (built from source, no curses) +
espeak + sox + piper (neural TTS) + whisper.cpp (local speech-to-text), with
Zork I/II/III bundled. Register a softphone, dial **5001**, and play by
keypad — or hold `1` and just say what you want to do.

Nothing phones home: TTS and speech recognition both run locally in the
container.

## Quick start

The image is published to GitHub Container Registry and needs no build:

```bash
docker run -d --name zorkpbx \
  -p 5060:5060/udp -p 10000-10020:10000-10020/udp \
  -v "$PWD/saves:/opt/zorkpbx/saves" \
  ghcr.io/gschmidl/zorkpbx-docker:latest
```

Point a softphone at `udp://<host>:5060`, register as **6001** with the
password **`infocom`**, and dial **5001**.

### Windows

`run.bat` does all of the above. It picks up Podman or Docker automatically,
creates `saves\`, pulls the image if it is not already local, and prints the
credentials when the container is up.

```
winget install -e --id RedHat.Podman
podman machine init
podman machine start
run.bat
```

Copy `.env.example` to `.env` first if you want to pin your own extension
number or password.

### Docker Compose (any platform)

```bash
cp .env.example .env      # optional — the defaults work
docker compose pull
docker compose up -d
```

## Playing

* Dial **5001**. ZorkPBX answers and reads the opening room description.
* Type commands on the keypad; press **0** for the in-call help menu.
* Press **1** to speak a command instead (whisper.cpp transcribes it locally).
* Saves are automatic and per-caller-ID, kept in `saves/`. Hang up and call
  back to resume.

## Configuration

Every setting is an environment variable. With Compose, put them in `.env`;
with `docker run`, pass them as `-e NAME=value`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SIP_USER` | `6001` | Extension the softphone registers as |
| `SIP_PASSWORD` | `infocom` | Fixed, so credentials are identical on every machine and restart. Change it for anything less private than your own LAN |
| `SIP_EXTERNAL_IP` | *(empty)* | Address the phone dials. Set this if audio is one-way — see below |
| `SIP_LOCAL_NET` | *(empty)* | Subnet to treat as local, e.g. `192.168.0.0/16` |
| `ZORKPBX_TTS_ENGINE` | `piper` | `espeak`, `piper` or `gtts`. Defaults to piper on amd64; arm64 images have no piper and use espeak |
| `ZORKPBX_LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARNING`, `ERROR` |

The full set of `ZORKPBX_*` knobs (call limits, audio cache size, recording
length, whisper model) is documented in
[upstream's `.env.example`](https://github.com/aejx00/zorkpbx/blob/main/.env.example);
all of them work here as plain container environment variables.

Mount points worth knowing:

| Path | Contents |
| --- | --- |
| `/opt/zorkpbx/saves` | Game saves, one per caller ID. Mount this to keep progress |
| `/opt/zorkpbx/audio` | TTS cache. Large and regenerable — a named volume is ideal |
| `/opt/zorkpbx/games` | Zork I/II/III, already baked in. Mount only to substitute your own `.DAT`/`.z5` files |

## Platform support

| Platform | TTS | Voice input | Notes |
| --- | --- | --- | --- |
| `linux/amd64` | piper (neural) | yes | Full image |
| `linux/arm64` | espeak | yes | Apple Silicon, Raspberry Pi 4/5 |

Piper ships glibc-linked binaries, and the only maintained glibc-on-musl shim
for Alpine ([`sgerrand/alpine-pkg-glibc`](https://github.com/sgerrand/alpine-pkg-glibc))
publishes x86_64 packages only. So arm64 builds use espeak, which is robotic
but perfectly intelligible — and arguably more in period. Everything else,
whisper.cpp voice input included, is identical. If you want the neural voice on
an Apple Silicon Mac, run the amd64 image under emulation with
`--platform linux/amd64`.

## Building it yourself

```bash
docker build -t zorkpbx-docker .
```

Useful build arguments:

| Argument | Default | Effect |
| --- | --- | --- |
| `WITH_PIPER` | `auto` | `auto` = piper on amd64 only. `0` drops piper, its voice model and the glibc layer (~110 MB smaller). `1` forces it and fails the build on non-amd64 |
| `WITH_WHISPER` | `1` | `0` drops whisper.cpp and the model — no voice input |
| `WITH_BUNDLED_ZORK` | `1` | `0` ships no game files; mount your own into `/opt/zorkpbx/games` |
| `ALPINE_VERSION` | `3.23` | Base image tag |
| `PIPER_VOICE` | `en_US-norman-medium` | Any voice from [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices) `en/en_US` |
| `WHISPER_MODEL` | `tiny` | `tiny`, `base` or `small` — bigger is more accurate and slower |

Smallest useful build:

```bash
docker build --build-arg WITH_PIPER=0 --build-arg WITH_WHISPER=0 \
             -t zorkpbx-docker:mini .
```

Everything the build downloads — ZorkPBX, frotz, whisper.cpp, the Zork story
files — is pinned to an exact commit or tag, so a rebuild produces the same
thing months later.

## Troubleshooting

**The softphone will not register.** The container must be reachable on
UDP 5060. On Podman under WSL the container is not on your LAN, so find the VM's
address and use it as both *SIP Server* and *Domain*:

```
wsl -l -v                                       # find the distro name
wsl -d podman-machine-default ip -4 addr show   # find its IP
```

**The call connects but there is no audio, or audio only one way.** Asterisk
only knows its private container IP and advertises that address for the media
stream, so RTP from your phone goes nowhere. Set `SIP_EXTERNAL_IP` to the
address your phone actually dials:

```bash
docker run ... -e SIP_EXTERNAL_IP=192.168.1.20 ghcr.io/gschmidl/zorkpbx-docker:latest
```

Also check that the RTP range `10000-10020/udp` is published — it is easy to
forget when writing a `docker run` by hand.

**`no matching manifest for linux/arm64/v8`.** An old, amd64-only build.
`docker pull ghcr.io/gschmidl/zorkpbx-docker:latest` now serves both amd64 and
arm64; re-pull to pick up the multi-platform manifest.

**`/entrypoint.sh: line 2: $'\r': command not found`.** A clone made on Windows
before this repository had a `.gitattributes` converted the shell scripts to
CRLF. Re-clone, or run `git rm --cached -r . && git reset --hard`.

**`unpacking failed (error: unexpected EOF)` when pulling a `...sig` tag.**
That tag is a [cosign](https://github.com/sigstore/cosign) signature, not an
image — GHCR lists it next to the real tags, but its layers are a signature
payload and no container runtime can unpack them. Pull `:latest` instead. To
check the signature rather than run it:

```bash
cosign verify ghcr.io/gschmidl/zorkpbx-docker:latest \
  --certificate-identity-regexp 'https://github\.com/gschmidl/zorkpbx-docker/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

**The voice sounds robotic.** That is espeak, the fallback. amd64 images use
piper; check `docker logs zorkpbx | grep "TTS engine"`. On arm64 there is no
piper (see Platform support), and `ZORKPBX_TTS_ENGINE=piper` will refuse to
start rather than pretend.

## Security

This is a toy PBX. It speaks plain UDP SIP with no TLS or SRTP, and it exists to
be dialled from a softphone on your own network. Do not expose 5060/udp to the
internet — an open SIP port is found and hammered within hours, and the default
password is published right here in this README. Keep it behind your firewall.

If you do need it reachable from somewhere less friendly, set `SIP_PASSWORD` to
something of your own. It is passed through literally, so `/`, `&` and other
punctuation are safe.

## Credits and licensing

* [ZorkPBX](https://github.com/aejx00/zorkpbx) by aejx00 — the AGI application
  this image packages.
* Zork I/II/III were released under the MIT license by Microsoft/Activision in
  November 2025; the story files come from the
  [historicalsource](https://github.com/historicalsource) repositories, and each
  one's `LICENSE` is copied next to it in `/opt/zorkpbx/games`.
* [Frotz](https://gitlab.com/DavidGriffith/frotz) (GPL-2.0),
  [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (MIT),
  [piper](https://github.com/rhasspy/piper) (MIT), Asterisk (GPL-2.0).

The packaging in this repository is MIT licensed — see [LICENSE](LICENSE).
