#!/bin/bash
set -euo pipefail

# --- runtime dirs / permissions (bind mounts land here as root:root) ------
mkdir -p /opt/zorkpbx/games /opt/zorkpbx/saves /opt/zorkpbx/audio
chown -R asterisk:asterisk /opt/zorkpbx/games /opt/zorkpbx/saves /opt/zorkpbx/audio 2>/dev/null || true

if ! ls /opt/zorkpbx/games/*.DAT >/dev/null 2>&1 && ! ls /opt/zorkpbx/games/*.z[0-9] >/dev/null 2>&1; then
  echo "[zorkpbx] WARNING: no game files in /opt/zorkpbx/games — bind-mount your own" >&2
  echo "[zorkpbx]          ZORK1.DAT (etc.) there, e.g. -v \$PWD/games:/opt/zorkpbx/games" >&2
fi

# --- SIP credentials: env override, else generate once and persist --------
SIP_USER="${SIP_USER:-6001}"
# Lives under saves/ so it survives container recreation when that dir is
# a mounted volume (see docker-compose.yml).
CRED_FILE=/opt/zorkpbx/saves/.sip_password
if [ -n "${SIP_PASSWORD:-}" ]; then
  : # explicit password wins, every start
elif [ -f "$CRED_FILE" ]; then
  SIP_PASSWORD="$(cat "$CRED_FILE")"
else
  # `|| true` absorbs tr's SIGPIPE (from head closing early) so pipefail
  # doesn't kill the script under set -e.
  SIP_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 || true)"
  echo "$SIP_PASSWORD" > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
fi

sed -e "s/__SIP_USER__/${SIP_USER}/g" -e "s/__SIP_PASSWORD__/${SIP_PASSWORD}/g" \
  /etc/asterisk/pjsip.conf.template > /etc/asterisk/pjsip.conf

echo "[zorkpbx] SIP extension ${SIP_USER} / password ${SIP_PASSWORD}"
echo "[zorkpbx] Register a softphone to udp://<this-host>:5060, then dial 5001."

# --- logging: stream the asterisk log into `docker logs` ------------------
mkdir -p /var/log/asterisk /var/spool/asterisk /var/run/asterisk
touch /var/log/asterisk/full
chown -R asterisk:asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk 2>/dev/null || true
tail -F /var/log/asterisk/full &

exec asterisk -f -U asterisk -G asterisk
