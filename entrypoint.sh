#!/bin/bash
set -euo pipefail

log() { echo "[zorkpbx] $*"; }
die() { echo "[zorkpbx] FATAL: $*" >&2; exit 1; }

# ── Runtime dirs / permissions (bind mounts land here as root:root) ────────
mkdir -p /opt/zorkpbx/games /opt/zorkpbx/saves /opt/zorkpbx/audio \
         /var/log/asterisk /var/spool/asterisk /var/run/asterisk
chown -R asterisk:asterisk \
  /opt/zorkpbx/games /opt/zorkpbx/saves /opt/zorkpbx/audio \
  /var/log/asterisk /var/spool/asterisk /var/run/asterisk 2>/dev/null || true

if ! ls /opt/zorkpbx/games/*.DAT >/dev/null 2>&1 \
   && ! ls /opt/zorkpbx/games/*.z[0-9] >/dev/null 2>&1; then
  log "WARNING: no game files in /opt/zorkpbx/games — bind-mount your own"
  log "         ZORK1.DAT (etc.) there, e.g. -v \$PWD/games:/opt/zorkpbx/games"
fi

# ── TTS engine ─────────────────────────────────────────────────────────────
# piper (neural TTS) is the intended voice and is what amd64 images ship.
# espeak is the fallback for builds that have no piper: arm64, where the only
# maintained glibc-on-musl shim is x86_64-only, and WITH_PIPER=0 builds.
# An explicit ZORKPBX_TTS_ENGINE from the environment always wins.
#
# This MUST be exported rather than written to /opt/zorkpbx/.env: zorkpbx.py
# reads os.environ only, and Asterisk's res_agi fork/execs the AGI script, so
# the script inherits this process's environment. Nothing ever parses .env.
if [ -z "${ZORKPBX_TTS_ENGINE:-}" ]; then
  if [ -x /usr/local/bin/piper ] && [ -f "${ZORKPBX_PIPER_MODEL:-}" ]; then
    ZORKPBX_TTS_ENGINE=piper
  else
    ZORKPBX_TTS_ENGINE=espeak
    if [ -x /usr/local/bin/piper ]; then
      log "WARNING: piper is installed but its voice model is missing:"
      log "         ${ZORKPBX_PIPER_MODEL:-<unset>}"
      log "         Falling back to espeak."
    fi
  fi
fi
export ZORKPBX_TTS_ENGINE
log "TTS engine: ${ZORKPBX_TTS_ENGINE}"

# The TTS cache is keyed on a hash of the text alone — not the engine, not the
# voice. So a clip synthesised by espeak keeps replaying in espeak forever,
# even after switching to piper, and with the audio directory on a persistent
# volume that sounds like the voice changing at random from phrase to phrase.
# Give each engine (and each piper voice) its own subdirectory so two voices
# can never share a cache.
audio_tag="${ZORKPBX_TTS_ENGINE}"
if [ "${ZORKPBX_TTS_ENGINE}" = "piper" ] && [ -n "${ZORKPBX_PIPER_MODEL:-}" ]; then
  audio_tag="piper-$(basename "${ZORKPBX_PIPER_MODEL}" .onnx)"
fi
ZORKPBX_AUDIO_DIR="${ZORKPBX_AUDIO_DIR:-/opt/zorkpbx/audio}"
export ZORKPBX_AUDIO_DIR="${ZORKPBX_AUDIO_DIR%/}/${audio_tag}"
mkdir -p "$ZORKPBX_AUDIO_DIR"
chown asterisk:asterisk "$ZORKPBX_AUDIO_DIR" 2>/dev/null || true
log "TTS cache: ${ZORKPBX_AUDIO_DIR}"

if [ "${ZORKPBX_TTS_ENGINE}" = "piper" ]; then
  [ -x /usr/local/bin/piper ] \
    || die "ZORKPBX_TTS_ENGINE=piper but this image has no piper binary (arm64 or WITH_PIPER=0 build). Use espeak."
  [ -f "${ZORKPBX_PIPER_MODEL:-}" ] \
    || die "ZORKPBX_TTS_ENGINE=piper but the voice model is missing: ${ZORKPBX_PIPER_MODEL:-<unset>}"
fi

# ── Speech-to-text self-check ──────────────────────────────────────────────
# whisper-cli is compiled from source. If it was built for a wider instruction
# set than this CPU provides it dies with SIGILL, and that only shows up once a
# caller actually speaks — as "Sorry, I didn't catch that" on every command,
# with a bare rc=-4 in the log. Exercise it once here so the problem is
# obvious at startup instead. Non-fatal: the keypad still works.
if [ -x /usr/local/bin/whisper-cli ]; then
  whisper_model_file="${ZORKPBX_WHISPER_MODEL_DIR:-/usr/local/share/whisper-models}/ggml-${ZORKPBX_WHISPER_MODEL:-tiny}.bin"
  if [ ! -f "$whisper_model_file" ]; then
    log "WARNING: whisper model missing (${whisper_model_file}) — voice input will not work"
  else
    probe_dir="$(mktemp -d)"
    probe_rc=0
    sox -n -r 16000 -c 1 "${probe_dir}/probe.wav" trim 0.0 0.3 >/dev/null 2>&1 || probe_rc=$?
    if [ "$probe_rc" -eq 0 ]; then
      whisper-cli -m "$whisper_model_file" -f "${probe_dir}/probe.wav" \
        -l en --no-timestamps --no-prints >/dev/null 2>&1 || probe_rc=$?
    fi
    if [ "$probe_rc" -eq 0 ]; then
      log "voice input: ready (whisper ${ZORKPBX_WHISPER_MODEL:-tiny})"
    else
      log "WARNING: whisper-cli self-test failed (exit ${probe_rc}) — voice input"
      log "         will answer \"Sorry, I didn't catch that\" for every command."
      if [ "$probe_rc" -eq 132 ] || [ "$probe_rc" -eq 4 ]; then
        log "         SIGILL: this binary was built for a wider instruction set"
        log "         than this CPU provides. Rebuild with -DGGML_NATIVE=OFF."
      fi
    fi
    rm -rf "$probe_dir"
  fi
fi

# ── SIP credentials ────────────────────────────────────────────────────────
SIP_USER="${SIP_USER:-6001}"
case "${SIP_USER}" in
  *[!A-Za-z0-9_.-]* | "")
    die "SIP_USER must be non-empty and contain only A-Z a-z 0-9 . _ - (got '${SIP_USER}')" ;;
esac

# Fixed default so the credentials are the same on every machine and every
# restart — this is a LAN toy PBX you dial from a softphone, not a trunk.
# Override with SIP_PASSWORD for anything less private than your own network,
# and see the Security section of the README before exposing 5060/udp.
SIP_PASSWORD="${SIP_PASSWORD:-infocom}"
export SIP_USER SIP_PASSWORD
log "SIP extension ${SIP_USER} / password ${SIP_PASSWORD}"

# NAT: without these, Asterisk advertises its *container* IP in SDP and audio
# goes one-way for any phone that isn't on the container network. Set
# SIP_EXTERNAL_IP to the address the phone dials (the Docker/Podman host) and
# SIP_LOCAL_NET to the subnet that should be treated as local.
export SIP_EXTERNAL_IP="${SIP_EXTERNAL_IP:-}"
export SIP_LOCAL_NET="${SIP_LOCAL_NET:-}"
if [ -n "$SIP_EXTERNAL_IP" ]; then
  log "advertising external address ${SIP_EXTERNAL_IP} in SDP"
fi

# ── Render pjsip.conf ──────────────────────────────────────────────────────
# awk, not sed: substitution is literal, so a password containing / or & can
# neither break the config nor inject extra pjsip options. Lines prefixed
# "#IF:VAR#" are emitted only when $VAR is non-empty.
awk '
  function repl(s, tok, val,   out, p) {
    out = ""
    while ((p = index(s, tok)) > 0) {
      out = out substr(s, 1, p - 1) val
      s = substr(s, p + length(tok))
    }
    return out s
  }
  {
    line = $0
    if (substr(line, 1, 4) == "#IF:") {
      rest = substr(line, 5)
      hash = index(rest, "#")
      name = substr(rest, 1, hash - 1)
      if (ENVIRON[name] == "") next
      line = substr(rest, hash + 1)
    }
    line = repl(line, "__SIP_USER__",        ENVIRON["SIP_USER"])
    line = repl(line, "__SIP_PASSWORD__",    ENVIRON["SIP_PASSWORD"])
    line = repl(line, "__SIP_EXTERNAL_IP__", ENVIRON["SIP_EXTERNAL_IP"])
    line = repl(line, "__SIP_LOCAL_NET__",   ENVIRON["SIP_LOCAL_NET"])
    print line
  }
' /etc/asterisk/pjsip.conf.template > /etc/asterisk/pjsip.conf
chmod 640 /etc/asterisk/pjsip.conf
chown root:asterisk /etc/asterisk/pjsip.conf 2>/dev/null || true

log "Register a softphone to udp://<this-host>:5060, then dial 5001."

# ── Logging: stream the asterisk log into `docker logs` ────────────────────
touch /var/log/asterisk/full
chown asterisk:asterisk /var/log/asterisk/full 2>/dev/null || true
# (no trap/cleanup needed: `exec` replaces this shell, tail is reparented to
# asterisk as PID 1 and dies with the container.)
tail -F /var/log/asterisk/full &

exec asterisk -f -U asterisk -G asterisk
