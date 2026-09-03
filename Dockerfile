# syntax=docker/dockerfile:1
#
# zorkpbx-docker — the smallest practical image that runs ZorkPBX
# (https://github.com/aejx00/zorkpbx): Alpine + Asterisk + dfrotz + espeak
# + sox + whisper.cpp + Zork I/II/III.
#
# Build:
#   docker build -t zorkpbx-docker .
#
# Smaller still (no voice input):
#   docker build --build-arg WITH_WHISPER=0 -t zorkpbx-docker:mini .

ARG ALPINE_VERSION=3.20
ARG ZORKPBX_REF=c899cf1c022f28e5138fc11f3a9123ec6628bf0f
ARG FROTZ_REF=2.55
ARG WHISPER_CPP_REF=v1.9.2
ARG WHISPER_MODEL=tiny
ARG WITH_WHISPER=1

# Zork I/II/III were open-sourced by Microsoft/Activision (Nov 2025, MIT
# license) at github.com/historicalsource/zork{1,2,3}.
ARG WITH_BUNDLED_ZORK=1
ARG ZORK1_REF=97b7b3d68c075dd9af7da499c3e9690ada3471fd
ARG ZORK2_REF=3da9661098809788a99cef00f00c865c6c204f96
ARG ZORK3_REF=3ec9ed412b5f3cafe65d83c727d07db1fe4a86a8

# TTS is espeak. Piper used to be built in here, but nothing ever selected it:
# the engine was written to /opt/zorkpbx/.env, which zorkpbx.py never reads (it
# reads os.environ only), so every call fell through to espeak while the image
# carried piper, a voice model and a whole glibc-on-musl compatibility layer —
# roughly 110 MB — for nothing. Removing it also makes arm64 a first-class
# platform, since that shim was x86_64-only.


# ═══════════════════════════════════════════════════════════════════════════
# Stage 1: builder — compile dfrotz and whisper.cpp. None of this stage's
# toolchain (gcc, cmake, git, ...) reaches the final image.
# ═══════════════════════════════════════════════════════════════════════════
FROM alpine:${ALPINE_VERSION} AS builder

ARG ZORKPBX_REF
ARG FROTZ_REF
ARG WHISPER_CPP_REF
ARG WHISPER_MODEL
ARG WITH_WHISPER

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache build-base cmake git curl bash

# --- ZorkPBX source ---------------------------------------------------------
# `clone --branch <sha>` doesn't work against GitHub (branch/tag names only) —
# `fetch <sha>` does; GitHub explicitly supports shallow-fetching an arbitrary
# reachable commit that way. The .git dir is dropped so it never ships.
RUN mkdir -p /out/zorkpbx && cd /out/zorkpbx \
    && git init -q \
    && git remote add origin https://github.com/aejx00/zorkpbx.git \
    && git fetch -q --depth 1 origin "${ZORKPBX_REF}" \
    && git checkout -q FETCH_HEAD \
    && rm -rf /out/zorkpbx/.git

# --- Upstream bug fix: save/restore filename mismatch -----------------------
# dfrotz built with Quetzal support (the default for `make dumb`, see below)
# silently appends ".qzl" to whatever save filename it's given — writing
# "6001_zork1.sav" actually creates "6001_zork1.sav.qzl" on disk. zorkpbx.py
# constructs save paths ending in plain ".sav" and later does
# os.path.exists(save_path) to decide whether to restore — checking a
# filename that never gets created, so restore always silently falls through
# to "start fresh". Fix: make the script's own filenames end in ".sav.qzl"
# from the start (dfrotz leaves an already-recognized extension alone), so
# every downstream exists()/save/restore call lines up with the real file.
# The final grep aborts the build loudly if a future ZORKPBX_REF changes this
# code and the patch silently stops applying.
RUN sed -i \
      -e 's/{game_name\.lower()}\.sav")/{game_name.lower()}.sav.qzl")/' \
      -e 's/{safe_id}_{game_name}\.sav")/{safe_id}_{game_name}.sav.qzl")/' \
      -e 's/{safe_id}\.sav")/{safe_id}.sav.qzl")/' \
      /out/zorkpbx/agi/zorkpbx.py \
    && [ "$(grep -c '\.sav\.qzl")' /out/zorkpbx/agi/zorkpbx.py)" = "3" ]

# --- dfrotz: Z-machine interpreter, dumb (non-curses) interface ------------
# `make dumb` only needs a C compiler; it skips ncurses/SDL/X11 entirely.
RUN git clone -q --depth 1 --branch "${FROTZ_REF}" \
      https://gitlab.com/DavidGriffith/frotz.git /src/frotz \
    && make -C /src/frotz dumb \
    && install -Dm755 /src/frotz/dfrotz /out/bin/dfrotz

# --- whisper.cpp: local speech-to-text for the "press 1 to speak" path -----
# GGML_NATIVE=OFF is load-bearing for anything published. ggml defaults it to
# ON, which compiles with -march=native and bakes the *build* machine's
# instruction set into the binary. That is fine when you build on the machine
# you run on, and fatal for a registry image: a CI runner with AVX-512 yields a
# whisper-cli that dies with SIGILL ("Illegal instruction", surfacing as rc=-4)
# on any CPU without it, so every spoken command fails while the rest of the
# image looks perfectly healthy. Off, it targets a fixed
# sse4.2/f16c/fma/bmi2/avx/avx2 baseline instead. Verified to produce
# byte-identical transcriptions to a native build.
RUN mkdir -p /out/bin /out/whisper-models \
    && touch /out/whisper-models/.keep \
    && if [ "${WITH_WHISPER}" = "1" ]; then \
         git clone -q --depth 1 --branch "${WHISPER_CPP_REF}" \
           https://github.com/ggerganov/whisper.cpp.git /src/whisper.cpp \
         && cmake -S /src/whisper.cpp -B /src/whisper.cpp/build \
              -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
         && cmake --build /src/whisper.cpp/build --config Release -j"$(nproc)" \
         && install -Dm755 /src/whisper.cpp/build/bin/whisper-cli /out/bin/whisper-cli \
         && sh /src/whisper.cpp/models/download-ggml-model.sh "${WHISPER_MODEL}" /out/whisper-models ; \
       fi

# --- Bundled game files: Zork I/II/III (MIT-licensed, see ARG block above) --
# Build WITH_BUNDLED_ZORK=0 to go back to bind-mount-your-own (e.g. for a
# different release or localization).
ARG WITH_BUNDLED_ZORK
ARG ZORK1_REF
ARG ZORK2_REF
ARG ZORK3_REF
RUN mkdir -p /out/games \
    && touch /out/games/.keep \
    && if [ "${WITH_BUNDLED_ZORK}" = "1" ]; then \
         for n in 1 2 3; do \
           eval "ref=\${ZORK${n}_REF}" ; \
           curl -fsSL -o "/out/games/ZORK${n}.DAT" \
             "https://raw.githubusercontent.com/historicalsource/zork${n}/${ref}/zork${n}.zip" \
           && curl -fsSL -o "/out/games/LICENSE-zork${n}.txt" \
             "https://raw.githubusercontent.com/historicalsource/zork${n}/${ref}/LICENSE" \
           && v="$(head -c 1 "/out/games/ZORK${n}.DAT" | od -An -tu1 | tr -d ' ')" \
           && { [ "$v" = "3" ] || { echo "FATAL: ZORK${n}.DAT is not a Z-machine v3 story file (byte0=$v)" >&2; exit 1; } ; } ; \
         done ; \
       fi


# ═══════════════════════════════════════════════════════════════════════════
# Stage 2: final image
# ═══════════════════════════════════════════════════════════════════════════
FROM alpine:${ALPINE_VERSION}

LABEL org.opencontainers.image.title="zorkpbx-docker" \
      org.opencontainers.image.description="Zork I/II/III over a phone line: Asterisk + ZorkPBX + dfrotz + espeak + whisper.cpp on Alpine" \
      org.opencontainers.image.source="https://github.com/gschmidl/zorkpbx-docker" \
      org.opencontainers.image.licenses="MIT"

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# --- Base runtime packages ---------------------------------------------------
# asterisk                the PBX itself (PJSIP channel driver is built in)
# asterisk-sample-config  baseline asterisk.conf/modules.conf/etc.
# asterisk-sounds-en      stock prompt/tone files, notably "beep" — without it
#                         RECORD FILE's BEEP option aborts the whole recording
#                         rather than just skipping the tone, and every voice
#                         command fails instantly.
# libstdc++/libgcc        res_pjsip.so is linked against these; without them
#                         chan_pjsip never loads.
# sox                     audio format conversion (TTS/STT pipeline glue)
# espeak                  the TTS engine
# python3/py3-pip         AGI script runtime (deps live in a venv)
# bash                    entrypoint.sh
# tzdata/ca-certificates  sane call timestamps; TLS roots for optional gTTS
# dfrotz and whisper-cli are built from source in stage 1, not from apk.
RUN apk add --no-cache \
      asterisk asterisk-sample-config asterisk-sounds-en \
      libstdc++ libgcc \
      sox espeak \
      python3 py3-pip \
      bash tzdata ca-certificates

# --- dfrotz / whisper-cli / whisper model / games from the builder stage ---
COPY --from=builder /out/bin/ /usr/local/bin/
COPY --from=builder /out/whisper-models/ /usr/local/share/whisper-models/
COPY --from=builder /out/games/ /opt/zorkpbx/games/

# --- ZorkPBX itself ----------------------------------------------------------
COPY --from=builder /out/zorkpbx/ /opt/zorkpbx/
RUN python3 -m venv /opt/zorkpbx/.venv \
    && /opt/zorkpbx/.venv/bin/pip install --quiet --no-cache-dir --upgrade pip \
    && /opt/zorkpbx/.venv/bin/pip install --quiet --no-cache-dir -r /opt/zorkpbx/requirements.txt \
    && mkdir -p /opt/zorkpbx/saves /opt/zorkpbx/audio /var/lib/asterisk/agi-bin \
    && install -m 755 /opt/zorkpbx/agi/zorkpbx.py /var/lib/asterisk/agi-bin/zorkpbx.py \
    && sed -i "1c#!/opt/zorkpbx/.venv/bin/python" /var/lib/asterisk/agi-bin/zorkpbx.py \
    && /opt/zorkpbx/.venv/bin/python -m py_compile /var/lib/asterisk/agi-bin/zorkpbx.py

# No /opt/zorkpbx/.env is written on purpose. Asterisk fork/execs the AGI
# script (res_agi.c: setenv() then execv()), so it inherits this process's
# environment and never parses that file. zorkpbx.py's own defaults already
# point at the paths used here, and anything you do want to change is a plain
# `docker run -e ZORKPBX_...=...`.

# --- Asterisk config ---------------------------------------------------------
# Promote whatever asterisk-sample-config dropped (commonly *.sample) to real
# config files (asterisk.conf, modules.conf, etc. — paths/autoload as shipped
# by the package), then overlay only what we need to change: logging (so
# `docker logs` works) and SIP/dialplan (so a phone can actually reach it).
RUN for f in /etc/asterisk/*.sample; do [ -f "$f" ] && cp "$f" "${f%.sample}"; done; true
COPY asterisk/logger.conf /etc/asterisk/logger.conf
COPY asterisk/extensions.conf /etc/asterisk/extensions.conf
COPY asterisk/pjsip.conf.template /etc/asterisk/pjsip.conf.template
COPY asterisk/rtp.conf /etc/asterisk/rtp.conf
RUN cp /opt/zorkpbx/asterisk/extensions_zorkpbx.conf /etc/asterisk/extensions_zorkpbx.conf

RUN id asterisk >/dev/null 2>&1 || adduser -D -H -s /sbin/nologin asterisk

# --- Prompt sounds: keep <astdatadir>/sounds authoritative -----------------
# Alpine 3.20 installs the packaged prompts to /var/lib/asterisk/sounds, which
# is where asterisk.conf's astdatadir points. Alpine 3.21+ moved them to
# /usr/share/asterisk/sounds without changing astdatadir, so Asterisk stops
# finding "beep" — and because the AGI passes the BEEP option to RECORD FILE,
# a missing beep aborts the entire recording rather than just skipping the
# tone, making every spoken command answer "Sorry, I didn't catch that".
#
# /var/lib/asterisk/sounds must also stay a real, writable directory: the AGI
# records its temporary wav straight into it. Real dir, owned by asterisk, with
# any packaged per-language prompt dirs symlinked in — correct under either
# layout. The assertion fails the build loudly if this ever moves again.
RUN set -e; \
    mkdir -p /var/lib/asterisk/sounds; \
    for d in /usr/share/asterisk/sounds/*/; do \
      [ -d "$d" ] && ln -sfn "${d%/}" "/var/lib/asterisk/sounds/$(basename "${d%/}")"; \
    done; \
    true; \
    chown asterisk:asterisk /var/lib/asterisk/sounds; \
    if [ ! -e /var/lib/asterisk/sounds/en/beep.gsm ]; then \
      echo "FATAL: no beep prompt under /var/lib/asterisk/sounds/en (astdatadir)." >&2; \
      echo "       RECORD FILE would abort every voice command. Prompts found at:" >&2; \
      { find / -name 'beep.gsm' -not -path '/proc/*' 2>/dev/null; } >&2; \
      exit 1; \
    fi

RUN mkdir -p /var/log/asterisk /var/spool/asterisk /var/run/asterisk \
    && chown -R asterisk:asterisk \
         /var/log/asterisk /var/spool/asterisk /var/run/asterisk \
         /opt/zorkpbx/saves /opt/zorkpbx/audio /opt/zorkpbx/games \
         /var/lib/asterisk/agi-bin/zorkpbx.py

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# No VOLUME instructions on purpose: they would make every `docker run` create
# anonymous volumes for the bundled games and the audio cache, which then
# shadow image updates and pile up as dangling volumes. Mount what you want to
# persist explicitly — see docker-compose.yml.
EXPOSE 5060/udp 10000-10020/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD asterisk -rx 'core show uptime' >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
