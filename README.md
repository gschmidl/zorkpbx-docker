# zorkpbx-docker

Zork I, II and III over a phone line, in one container.

The smallest practical image that runs [ZorkPBX](https://github.com/aejx00/zorkpbx):
Alpine Linux + Asterisk (PJSIP) + `dfrotz` (built from source, no curses) +
espeak + sox + whisper.cpp (local speech-to-text), with Zork I/II/III bundled.
Register a softphone, dial **5001**, and play by keypad — or press `1` and say
what you want to do.

Nothing phones home: speech synthesis and recognition both run locally in the
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
creates `saves\`, pulls the current image, and prints the credentials once the
container is up.

```
winget install -e --id RedHat.Podman
podman machine init
podman machine start
run.bat
```

Edit the two `set` lines at the top of `run.bat` to change the credentials.

### Docker Compose (any platform)

```bash
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

Every setting is an environment variable — pass them as `-e NAME=value`, or put
them under `environment:` in `docker-compose.yml`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SIP_USER` | `6001` | Extension the softphone registers as |
| `SIP_PASSWORD` | `infocom` | Fixed, so credentials are identical on every machine and restart. Change it for anything less private than your own LAN |
| `ZORKPBX_TTS_ENGINE` | `espeak` | `espeak`, or `gtts` for Google's cloud voice (needs outbound internet) |
| `ZORKPBX_WHISPER_MODEL` | `tiny` | Must match a `ggml-<name>.bin` present in the model directory |
| `ZORKPBX_LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARNING`, `ERROR` |

The full set of `ZORKPBX_*` knobs (call limits, audio cache size, recording
length) is documented in
[upstream's `.env.example`](https://github.com/aejx00/zorkpbx/blob/main/.env.example).
They all work here as plain container environment variables — Asterisk
fork/execs the AGI script, so it inherits the container's environment. Note
that the `.env` *file* upstream describes is only read by their systemd unit,
never in local-AGI mode, so this image does not ship one.

Mount points worth knowing:

| Path | Contents |
| --- | --- |
| `/opt/zorkpbx/saves` | Game saves, one per caller ID. Mount this to keep progress |
| `/opt/zorkpbx/audio` | TTS cache, in a per-engine subdirectory. Regenerable — a named volume is ideal |
| `/opt/zorkpbx/games` | Zork I/II/III, already baked in. Mount only to substitute your own `.DAT`/`.z5` files |
| `/usr/local/share/whisper-models` | The bundled `ggml-*.bin`. Mount to supply a different model, then set `ZORKPBX_WHISPER_MODEL` |

## Platform support

Published for **linux/amd64** and **linux/arm64**, with identical features on
both — Apple Silicon and Raspberry Pi included.

## Building it yourself

```bash
docker build -t zorkpbx-docker .
```

Useful build arguments:

| Argument | Default | Effect |
| --- | --- | --- |
| `WITH_WHISPER` | `1` | `0` drops whisper.cpp and its model — no voice input |
| `WITH_BUNDLED_ZORK` | `1` | `0` ships no game files; mount your own into `/opt/zorkpbx/games` |
| `WHISPER_MODEL` | `tiny` | `tiny` (~75 MB), `base` (~148 MB) or `small` (~466 MB). Bigger is markedly more accurate on 8 kHz telephone audio, and slower |
| `ALPINE_VERSION` | `3.20` | Base image tag |

Smallest useful build:

```bash
docker build --build-arg WITH_WHISPER=0 -t zorkpbx-docker:mini .
```

Everything the build downloads — ZorkPBX, frotz, whisper.cpp, the Zork story
files — is pinned to an exact commit or tag, so a rebuild produces the same
thing months later.

Two notes if you change `ALPINE_VERSION`. Alpine 3.20 is past end-of-life, so it
no longer receives security updates; it is pinned because it is the version this
image is known-good on. And from 3.21 onwards Alpine moved the packaged Asterisk
prompts out of `astdatadir`, which silently breaks voice input — the build
asserts that `beep` is still resolvable and fails loudly rather than shipping
that, so a bump will tell you if it needs attention.

## Troubleshooting

**The softphone will not register.** The container must be reachable on
UDP 5060. On Podman under WSL the container is not on your LAN, so find the VM's
address and use it as both *SIP Server* and *Domain*:

```
wsl -l -v                                       # find the distro name
wsl -d podman-machine-default ip -4 addr show   # find its IP
```

**The call connects but there is no audio, or audio only one way.** Check that
the RTP range `10000-10020/udp` is published — it is easy to forget when writing
a `docker run` by hand. If the phone is not on the container's network, Asterisk
may also be advertising its private container address for the media stream.

**Spoken commands come back as confident nonsense.** The default `tiny` model is
working from 8 kHz telephone audio, which is the narrowest input whisper ever
sees, and it will return fluent, wrong English rather than nothing. Rebuild with
`--build-arg WHISPER_MODEL=small` (or mount a bigger `ggml-*.bin` and point
`ZORKPBX_WHISPER_MODEL` at it). The app reads the transcript back to you as
confirmation, so what you hear spoken is exactly what it understood.

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
  Asterisk (GPL-2.0), espeak (GPL-3.0).

The packaging in this repository is MIT licensed — see [LICENSE](LICENSE).
