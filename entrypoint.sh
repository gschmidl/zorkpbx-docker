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

# ── TTS cache scoping ──────────────────────────────────────────────────────
# The cache key is a hash of the spoken text alone — the engine is not part of
# it — so a clip rendered by one engine keeps replaying in that engine's voice
# forever once the audio directory is a persistent volume. Switching engines
# then makes the voice change from phrase to phrase depending on what happened
# to be cached. Give each engine its own subdirectory so two voices can never
# share a cache; changing engine simply starts a fresh one.
ZORKPBX_TTS_ENGINE="${ZORKPBX_TTS_ENGINE:-espeak}"
export ZORKPBX_TTS_ENGINE
audio_base="${ZORKPBX_AUDIO_DIR:-/opt/zorkpbx/audio}"
audio_base="${audio_base%/}"
export ZORKPBX_AUDIO_DIR="${audio_base}/${ZORKPBX_TTS_ENGINE}"
mkdir -p "$ZORKPBX_AUDIO_DIR"
chown asterisk:asterisk "$ZORKPBX_AUDIO_DIR" 2>/dev/null || true
log "TTS engine: ${ZORKPBX_TTS_ENGINE}  (cache: ${ZORKPBX_AUDIO_DIR})"

# Clips left at the volume root by an older layout are now unreachable. They
# are pure cache, so reclaim the space instead of carrying it forever.
stale_clips="$(find "$audio_base" -maxdepth 1 -name '*.ulaw' 2>/dev/null | wc -l)"
if [ "$stale_clips" -gt 0 ]; then
  find "$audio_base" -maxdepth 1 -name '*.ulaw' -delete 2>/dev/null || true
  log "removed ${stale_clips} unused clip(s) left in the audio volume root by an older cache layout"
fi

# ── SIP credentials ────────────────────────────────────────────────────────
SIP_USER="${SIP_USER:-6001}"
case "${SIP_USER}" in
  *[!A-Za-z0-9_.-]* | "")
    die "SIP_USER must be non-empty and contain only A-Z a-z 0-9 . _ - (got '${SIP_USER}')" ;;
esac

# Fixed default so the credentials are the same on every machine and every
# restart — this is a LAN toy PBX you dial from a softphone, not a trunk.
# Override with SIP_PASSWORD; see the Security section of the README before
# exposing 5060/udp anywhere.
SIP_PASSWORD="${SIP_PASSWORD:-infocom}"
export SIP_USER SIP_PASSWORD
log "SIP extension ${SIP_USER} / password ${SIP_PASSWORD}"

# ── Render pjsip.conf ──────────────────────────────────────────────────────
# awk, not sed: substitution is literal, so a password containing / or & can
# neither corrupt the config nor inject extra pjsip options.
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
    line = repl(line, "__SIP_USER__",     ENVIRON["SIP_USER"])
    line = repl(line, "__SIP_PASSWORD__", ENVIRON["SIP_PASSWORD"])
    print line
  }
' /etc/asterisk/pjsip.conf.template > /etc/asterisk/pjsip.conf
chmod 640 /etc/asterisk/pjsip.conf
chown root:asterisk /etc/asterisk/pjsip.conf 2>/dev/null || true

log "Ready: register a softphone to port 5060/udp on the machine hosting this container, then dial 5001."

# ── Logging: stream the asterisk log into `docker logs` ────────────────────
touch /var/log/asterisk/full
chown asterisk:asterisk /var/log/asterisk/full 2>/dev/null || true
# (no trap/cleanup needed: `exec` replaces this shell, tail is reparented to
# asterisk as PID 1 and dies with the container.)
tail -F /var/log/asterisk/full &

exec asterisk -f -U asterisk -G asterisk
