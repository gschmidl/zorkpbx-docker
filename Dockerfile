# syntax=docker/dockerfile:1
#
# zorkpbx-docker — the smallest practical image that runs ZorkPBX
# (https://github.com/aejx00/zorkpbx): Alpine + Asterisk + dfrotz + espeak
# + sox + piper + whisper.cpp + Zork I/II/III.
#
# Build (native arch):
#   docker build -t zorkpbx-docker .
#
# Shrink it (drop piper/whisper, espeak-only TTS, no voice input):
#   docker build --build-arg WITH_PIPER=0 --build-arg WITH_WHISPER=0 \
#                -t zorkpbx-docker:mini .
#
# Platforms: linux/amd64 (full) and linux/arm64 (no piper — see WITH_PIPER).

ARG ALPINE_VERSION=3.23
ARG ZORKPBX_REF=c899cf1c022f28e5138fc11f3a9123ec6628bf0f
ARG FROTZ_REF=2.55
ARG WHISPER_CPP_REF=v1.9.2
ARG WHISPER_MODEL=tiny
ARG PIPER_VERSION=2023.11.14-2
ARG PIPER_VOICE=en_US-norman-medium
ARG GLIBC_VERSION=2.35-r1

# WITH_PIPER=auto|1|0. Piper ships glibc-linked binaries, and the only
# maintained glibc-on-musl shim (sgerrand/alpine-pkg-glibc) publishes
# x86_64 packages *only*. So "auto" means: piper on amd64, espeak
# everywhere else. Forcing WITH_PIPER=1 on arm64 fails the build loudly
# rather than shipping a piper that cannot exec.
ARG WITH_PIPER=auto
ARG WITH_WHISPER=1

# Real glibc-ABI libstdc++/libgcc_s for piper, pulled straight from Ubuntu's
# archive. Alpine's own libstdc++/libgcc apks are musl-linked and cannot
# satisfy a glibc binary's dependency on libstdc++.so.6 (mixing the two
# produces "libc.musl-x86_64.so.1: cannot open shared object file" — musl's
# libstdc++ pulls in musl's libc, which glibc's loader has no concept of).
ARG UBUNTU_GCC_POOL=http://archive.ubuntu.com/ubuntu/pool/main/g/gcc-12
ARG LIBSTDCXX_DEB=libstdc++6_12-20220319-1ubuntu1_amd64.deb
ARG LIBGCC_DEB=libgcc-s1_12-20220319-1ubuntu1_amd64.deb

# Zork I/II/III were open-sourced by Microsoft/Activision (Nov 2025, MIT
# license) at github.com/historicalsource/zork{1,2,3}.
ARG WITH_BUNDLED_ZORK=1
ARG ZORK1_REF=97b7b3d68c075dd9af7da499c3e9690ada3471fd
ARG ZORK2_REF=3da9661098809788a99cef00f00c865c6c204f96
ARG ZORK3_REF=3ec9ed412b5f3cafe65d83c727d07db1fe4a86a8


# ═══════════════════════════════════════════════════════════════════════════
# Stage 1: builder — compile dfrotz + whisper.cpp and stage every downloaded
# artifact under /out. Nothing from this stage's toolchain (gcc, cmake, git,
# curl, ...) ships in the final image.
# ═══════════════════════════════════════════════════════════════════════════
FROM alpine:${ALPINE_VERSION} AS builder

ARG TARGETARCH
ARG ZORKPBX_REF
ARG FROTZ_REF
ARG WHISPER_CPP_REF
ARG WHISPER_MODEL
ARG WITH_WHISPER
ARG WITH_PIPER
ARG PIPER_VERSION
ARG PIPER_VOICE
ARG GLIBC_VERSION
ARG UBUNTU_GCC_POOL
ARG LIBSTDCXX_DEB
ARG LIBGCC_DEB
ARG WITH_BUNDLED_ZORK
ARG ZORK1_REF
ARG ZORK2_REF
ARG ZORK3_REF

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache build-base cmake git curl bash binutils zstd tar

# --- Resolve WITH_PIPER=auto once, for every later stage to read -----------
# Written to a file because an ARG cannot be mutated and carried between RUN
# layers. The final stage COPYs this same file, so the two stages can never
# disagree about whether piper is in the image.
RUN mkdir -p /out \
    && case "${WITH_PIPER}" in \
         auto) if [ "${TARGETARCH}" = "amd64" ]; then echo 1 > /out/with_piper; else echo 0 > /out/with_piper; fi ;; \
         1)    if [ "${TARGETARCH}" != "amd64" ]; then \
                 echo "FATAL: WITH_PIPER=1 is unsupported on ${TARGETARCH}: piper needs glibc," >&2 ; \
                 echo "       and alpine-pkg-glibc is x86_64-only. Use WITH_PIPER=0 or auto." >&2 ; \
                 exit 1 ; \
               fi ; \
               echo 1 > /out/with_piper ;; \
         0)    echo 0 > /out/with_piper ;; \
         *)    echo "FATAL: WITH_PIPER must be auto, 1 or 0 (got '${WITH_PIPER}')" >&2 ; exit 1 ;; \
       esac \
    && echo "[build] TARGETARCH=${TARGETARCH} piper=$(cat /out/with_piper) whisper=${WITH_WHISPER}"

# --- glibc runtime for piper (amd64 only) ----------------------------------
# .deb files are ar archives containing a zstd-compressed data.tar; unpack
# with binutils' `ar` + `tar --zstd`, then flatten out just the .so files
# regardless of which subdirectory each package puts them in
# (usr/lib/x86_64-linux-gnu/ vs. lib/x86_64-linux-gnu/ differ between these
# two packages). The glibc apk itself is staged here too, so the final image
# never needs curl or wget.
RUN mkdir -p /out/glibc-libs /out/glibc-pkg \
    && touch /out/glibc-libs/.keep /out/glibc-pkg/.keep \
    && if [ "$(cat /out/with_piper)" = "1" ]; then \
         mkdir -p /tmp/glibc-src && cd /tmp/glibc-src \
         && for deb in "${LIBSTDCXX_DEB}" "${LIBGCC_DEB}"; do \
              curl -fsSL -o pkg.deb "${UBUNTU_GCC_POOL}/${deb}" \
              && ar x pkg.deb data.tar.zst \
              && tar --zstd -xf data.tar.zst \
              && find . -name '*.so*' -not -type d -exec cp -P {} /out/glibc-libs/ \; \
              && rm -rf pkg.deb data.tar.zst usr lib ; \
            done \
         && curl -fsSL -o /out/glibc-pkg/sgerrand.rsa.pub \
              https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub \
         && curl -fsSL -o /out/glibc-pkg/glibc.apk \
              "https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC_VERSION}/glibc-${GLIBC_VERSION}.apk" ; \
       fi

# --- Piper: neural TTS binary + voice model (amd64 only) -------------------
RUN mkdir -p /out/piper /out/voices \
    && touch /out/piper/.keep /out/voices/.keep \
    && if [ "$(cat /out/with_piper)" = "1" ]; then \
         curl -fsSL -o /tmp/piper.tar.gz \
           "https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_linux_x86_64.tar.gz" \
         && tar xzf /tmp/piper.tar.gz -C /out/piper --strip-components=1 \
         && rm -f /tmp/piper.tar.gz \
         && voice_name="$(echo "${PIPER_VOICE}" | cut -d- -f2)" \
         && voice_quality="$(echo "${PIPER_VOICE}" | cut -d- -f3)" \
         && base="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/${voice_name}/${voice_quality}/${PIPER_VOICE}" \
         && curl -fsSL -o "/out/voices/${PIPER_VOICE}.onnx"      "${base}.onnx" \
         && curl -fsSL -o "/out/voices/${PIPER_VOICE}.onnx.json" "${base}.onnx.json" ; \
       fi

# --- ZorkPBX source ---------------------------------------------------------
# `clone --branch <sha>` doesn't work against GitHub (branch/tag names
# only) — `fetch <sha>` does; GitHub explicitly supports shallow-fetching an
# arbitrary reachable commit that way. The .git dir is dropped afterwards so
# it never reaches the runtime image.
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
RUN mkdir -p /out/bin /out/whisper-models \
    && touch /out/whisper-models/.keep \
    && if [ "${WITH_WHISPER}" = "1" ]; then \
         git clone -q --depth 1 --branch "${WHISPER_CPP_REF}" \
           https://github.com/ggerganov/whisper.cpp.git /src/whisper.cpp \
         && cmake -S /src/whisper.cpp -B /src/whisper.cpp/build \
              -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
         && cmake --build /src/whisper.cpp/build --config Release -j"$(nproc)" \
         && install -Dm755 /src/whisper.cpp/build/bin/whisper-cli /out/bin/whisper-cli \
         && sh /src/whisper.cpp/models/download-ggml-model.sh "${WHISPER_MODEL}" /out/whisper-models ; \
       fi

# --- Bundled game files: Zork I/II/III (MIT-licensed, see ARG block above) --
# Build WITH_BUNDLED_ZORK=0 to go back to bind-mount-your-own (e.g. for a
# different release or localization).
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

ARG PIPER_VOICE
ARG WHISPER_MODEL

LABEL org.opencontainers.image.title="zorkpbx-docker" \
      org.opencontainers.image.description="Zork I/II/III over a phone line: Asterisk + ZorkPBX + dfrotz + piper/espeak TTS + whisper.cpp STT on Alpine" \
      org.opencontainers.image.source="https://github.com/gschmidl/zorkpbx-docker" \
      org.opencontainers.image.licenses="MIT"

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# --- Base runtime packages ---------------------------------------------------
# asterisk                the PBX itself (PJSIP channel driver is built in)
# asterisk-sample-config  baseline asterisk.conf/modules.conf/etc.
# asterisk-sounds-en      stock prompt/tone files (e.g. "beep") — without
#                         this, RECORD FILE's BEEP option fails to play and
#                         the whole recording aborts instead of just skipping
#                         the tone.
# libstdc++/libgcc        musl builds — res_pjsip.so itself is linked against
#                         these. Nothing to do with piper; without them
#                         chan_pjsip never loads.
# sox                     audio format conversion (TTS/STT pipeline glue)
# espeak                  always-available, zero-extra-weight TTS fallback
# python3/py3-pip         AGI script runtime (deps live in a venv)
# bash                    entrypoint.sh
# tzdata/ca-certificates  sane call timestamps; TLS roots for the optional
#                         gTTS engine
# dfrotz and whisper-cli are built from source in stage 1, not from apk.
RUN apk add --no-cache \
      asterisk asterisk-sample-config asterisk-sounds-en \
      libstdc++ libgcc \
      sox espeak \
      python3 py3-pip \
      bash tzdata ca-certificates

# Single source of truth for "is piper in this image", produced in stage 1.
COPY --from=builder /out/with_piper /etc/zorkpbx/with_piper

# --- Optional: glibc compatibility layer, needed only for piper ------------
# Adds a real glibc (not just a syscall shim) alongside musl so the unmodified
# upstream piper binary runs. ~20MB. Skipped entirely on arm64 / WITH_PIPER=0.
#
# NOTE: don't also install `gcompat` here — it ships its own
# /lib/ld-linux-x86-64.so.2 shim and collides with glibc's real one (apk
# refuses to let one package overwrite a file owned by another). They're
# alternative fixes for the same problem, not complementary.
#
# NOTE: piper needs its OWN, separate, glibc-ABI libstdc++.so.6/libgcc_s.so.1
# — Alpine's musl-built libstdc++ apk (installed above, for Asterisk) is not
# ABI-compatible with a glibc binary. Extracted from real Ubuntu packages in
# the builder stage, they go into glibc's own lib dir (the same place its
# loader already finds libc.so.6/ld-linux). Critically, this must NOT go on a
# container-wide LD_LIBRARY_PATH: musl's loader honors that env var too, and
# if glibc's libstdc++.so.6 is on it, musl binaries (like Asterisk's own
# res_pjsip.so, which needs its OWN musl libstdc++.so.6) find the wrong one by
# matching filename and fail. See the piper wrapper script below instead.
COPY --from=builder /out/glibc-pkg/ /tmp/glibc-pkg/
COPY --from=builder /out/glibc-libs/ /usr/glibc-compat/lib/
RUN if [ "$(cat /etc/zorkpbx/with_piper)" = "1" ]; then \
      cp /tmp/glibc-pkg/sgerrand.rsa.pub /etc/apk/keys/sgerrand.rsa.pub \
      && apk add --no-cache /tmp/glibc-pkg/glibc.apk \
      && mkdir -p /lib64 \
      && ln -sf /lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2 ; \
    fi \
    && rm -rf /tmp/glibc-pkg

# --- Piper: neural TTS (amd64 only) ----------------------------------------
COPY --from=builder /out/piper/ /opt/piper/
COPY --from=builder /out/voices/ /opt/zorkpbx/voices/
RUN if [ "$(cat /etc/zorkpbx/with_piper)" = "1" ]; then \
      printf '%s\n' \
        '#!/bin/sh' \
        '# Wrapper, not a symlink: scopes glibc paths to piper alone so they' \
        "# never leak into Asterisk's (musl) process tree via a container-wide" \
        '# LD_LIBRARY_PATH. See the NOTE above the glibc-compat install step.' \
        'export LD_LIBRARY_PATH="/opt/piper:/usr/glibc-compat/lib"' \
        'exec /opt/piper/piper "$@"' \
        > /usr/local/bin/piper \
      && chmod +x /usr/local/bin/piper ; \
    fi

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

# --- ZorkPBX runtime configuration -------------------------------------------
# These MUST be real environment variables, not the upstream .env file: in
# local-AGI mode Asterisk fork/execs the script (res_agi.c does setenv() then
# execv()), so the AGI process inherits Asterisk's environment and nothing
# ever parses .env. Anything set here is therefore live, and `docker run -e`
# overrides it. ZORKPBX_TTS_ENGINE is deliberately absent — entrypoint.sh
# picks piper or espeak based on what this image actually contains.
ENV ZORKPBX_GAME_FILE=/opt/zorkpbx/games/ZORK1.DAT \
    ZORKPBX_SAVE_DIR=/opt/zorkpbx/saves/ \
    ZORKPBX_AUDIO_DIR=/opt/zorkpbx/audio/ \
    ZORKPBX_COMMANDS_YAML=/opt/zorkpbx/config/commands.yaml \
    ZORKPBX_PIPER_MODEL=/opt/zorkpbx/voices/${PIPER_VOICE}.onnx \
    ZORKPBX_WHISPER_MODEL=${WHISPER_MODEL} \
    ZORKPBX_WHISPER_MODEL_DIR=/usr/local/share/whisper-models \
    ZORKPBX_LOG_LEVEL=INFO

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
