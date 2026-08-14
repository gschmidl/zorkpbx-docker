# syntax=docker/dockerfile:1
#
# Tiniest practical distro that runs ZorkPBX (https://github.com/aejx00/zorkpbx):
# Alpine + Asterisk + dfrotz + espeak + sox + piper + whisper.
#
# Build:
#   docker build -t zorkpbx-docker .
#
# Shrink it (drop piper/whisper, espeak-only TTS, no voice input):
#   docker build --build-arg WITH_PIPER=0 --build-arg WITH_WHISPER=0 -t zorkpbx-docker:mini .

ARG ALPINE_VERSION=3.20
ARG ZORKPBX_REF=c899cf1c022f28e5138fc11f3a9123ec6628bf0f
ARG FROTZ_REF=2.55
ARG WHISPER_CPP_REF=v1.9.2
ARG WHISPER_MODEL=tiny
ARG PIPER_VERSION=2023.11.14-2
ARG PIPER_VOICE=en_US-norman-medium
ARG GLIBC_VERSION=2.35-r1
ARG WITH_PIPER=1
ARG WITH_WHISPER=1
# Real glibc-ABI libstdc++/libgcc_s for piper, pulled straight from Ubuntu's
# archive. Alpine's own libstdc++/libgcc apks are musl-linked and cannot
# satisfy a glibc binary's dependency on libstdc++.so.6 (mixing the two
# produces "libc.musl-x86_64.so.1: cannot open shared object file" - musl's
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

# Stage 1: builder - compile dfrotz (dumb interface) and whisper.cpp.
# Nothing from this stage's toolchain (gcc, cmake, git, ...) ships in the
# final image.
FROM alpine:${ALPINE_VERSION} AS builder
ARG ZORKPBX_REF
ARG FROTZ_REF
ARG WHISPER_CPP_REF
ARG WHISPER_MODEL
ARG WITH_WHISPER
ARG WITH_PIPER
ARG UBUNTU_GCC_POOL
ARG LIBSTDCXX_DEB
ARG LIBGCC_DEB

RUN apk add --no-cache build-base cmake git curl bash

# --- Real glibc-ABI libstdc++.so.6 / libgcc_s.so.1 for piper ---------------
# .deb files are ar archives containing a zstd-compressed data.tar; unpack
# with binutils' `ar` + `tar --zstd` (which shells out to the `zstd` apk),
# then flatten out just the .so files regardless of which subdirectory each
# package happens to put them in (usr/lib/x86_64-linux-gnu/ vs. lib/x86_64-
# linux-gnu/ differ between these two packages).
RUN if [ "$WITH_PIPER" = "1" ]; then \
      apk add --no-cache binutils zstd tar \
      && mkdir -p /tmp/glibc-libs-src /out/glibc-libs \
      && cd /tmp/glibc-libs-src \
      && for deb in "$LIBSTDCXX_DEB" "$LIBGCC_DEB"; do \
           curl -fL -o pkg.deb "${UBUNTU_GCC_POOL}/${deb}" \
           && ar x pkg.deb data.tar.zst \
           && tar --zstd -xf data.tar.zst \
           && find . -name '*.so*' -not -type d -exec cp -P {} /out/glibc-libs/ \; \
           && rm -f pkg.deb data.tar.zst \
           && rm -rf usr lib ; \
         done ; \
    else \
      mkdir -p /out/glibc-libs ; \
    fi

# --- ZorkPBX source ---------------------------------------------------------
# `clone --branch <sha>` doesn't work against GitHub (branch/tag names
# only) - `fetch <sha>` does, GitHub explicitly supports shallow-fetching
# an arbitrary reachable commit that way. Verified directly before relying
# on it here.
RUN mkdir -p /src/zorkpbx && cd /src/zorkpbx \
    && git init -q \
    && git remote add origin https://github.com/aejx00/zorkpbx.git \
    && git fetch --depth 1 origin "${ZORKPBX_REF}" \
    && git checkout -q FETCH_HEAD

# --- Upstream bug fix: save/restore filename mismatch -----------------------
# dfrotz built with Quetzal support (the default for `make dumb`, see below)
# silently appends ".qzl" to whatever save filename it's given - writing
# "6001_zork1.sav" actually creates "6001_zork1.sav.qzl" on disk. zorkpbx.py
# constructs save paths ending in plain ".sav" and later does
# os.path.exists(save_path) to decide whether to restore - checking a
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
      /src/zorkpbx/agi/zorkpbx.py \
    && [ "$(grep -c '\.sav\.qzl")' /src/zorkpbx/agi/zorkpbx.py)" = "3" ]

# --- dfrotz: Z-machine interpreter, dumb (non-curses) interface ------------
# `make dumb` only needs a C compiler; it skips ncurses/SDL/X11 entirely.
RUN git clone --depth 1 --branch "${FROTZ_REF}" \
      https://gitlab.com/DavidGriffith/frotz.git /src/frotz \
    && make -C /src/frotz dumb \
    && install -Dm755 /src/frotz/dfrotz /out/bin/dfrotz

# --- whisper.cpp: local speech-to-text for the "press 1 to speak" path ----
RUN if [ "$WITH_WHISPER" = "1" ]; then \
      git clone --depth 1 --branch "${WHISPER_CPP_REF}" \
        https://github.com/ggerganov/whisper.cpp.git /src/whisper.cpp \
      && cmake -S /src/whisper.cpp -B /src/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      && cmake --build /src/whisper.cpp/build --config Release -j"$(nproc)" \
      && install -Dm755 /src/whisper.cpp/build/bin/whisper-cli /out/bin/whisper-cli \
      && mkdir -p /out/share/whisper-models \
      && sh /src/whisper.cpp/models/download-ggml-model.sh "${WHISPER_MODEL}" /out/share/whisper-models ; \
    else \
      mkdir -p /out/bin /out/share/whisper-models ; \
    fi

# Stage 2: final image
FROM alpine:${ALPINE_VERSION}
ARG PIPER_VERSION
ARG PIPER_VOICE
ARG GLIBC_VERSION
ARG WITH_PIPER
ARG WITH_WHISPER
ARG WITH_BUNDLED_ZORK
ARG ZORK1_REF
ARG ZORK2_REF
ARG ZORK3_REF

# --- Base runtime packages ---------------------------------------------------
# asterisk           the PBX itself (PJSIP channel driver is built in)
# asterisk-sample-config  baseline logger.conf/modules.conf/etc.
# libstdc++/libgcc   musl builds - res_pjsip.so itself is linked against
#                    these (Asterisk's own PJSIP stack uses C++). Nothing
#                    to do with piper; without them chan_pjsip never loads.
# frotz's dfrotz is built from source (stage 1) - not from apk
# sox                audio format conversion (TTS/STT pipeline glue)
# espeak             always-available, zero-extra-weight TTS fallback
# asterisk-sounds-en  stock prompt/tone files (e.g. "beep") - without this,
#                     RECORD FILE's BEEP option fails to play and the whole
#                     recording aborts instead of just skipping the tone.
# python3/py3-pip/py3-yaml  AGI script runtime
# tzdata             sane call logs/timestamps
RUN apk add --no-cache \
      asterisk asterisk-sample-config asterisk-sounds-en \
      libstdc++ libgcc \
      sox espeak \
      python3 py3-pip py3-yaml \
      curl bash tzdata ca-certificates

# --- Optional: glibc compatibility layer, needed only for piper -----------
# Piper's official release binaries are glibc-linked. This adds a real glibc
# (not just a syscall shim) alongside musl so the unmodified upstream binary
# runs unmodified. ~20MB. Skip with --build-arg WITH_PIPER=0.
#
# NOTE: don't also install `gcompat` here - it ships its own
# /lib/ld-linux-x86-64.so.2 shim and collides with glibc's real one
# (apk refuses to let one package overwrite a file owned by another).
# They're alternative fixes for the same problem, not complementary.
#
# NOTE: piper needs its OWN, separate, glibc-ABI libstdc++.so.6/libgcc_s.so.1
# - Alpine's musl-built libstdc++ apk (installed above, for Asterisk) is not
# ABI-compatible with a glibc binary. Extracted from real Ubuntu packages in
# the builder stage, they get copied into glibc's own lib dir below (the same
# place its loader already finds libc.so.6/ld-linux). Critically, this must
# NOT go on a container-wide LD_LIBRARY_PATH: musl's loader honors that env
# var too, and if glibc's libstdc++.so.6 is on it, musl binaries (like
# Asterisk's own res_pjsip.so, which needs its OWN musl libstdc++.so.6) will
# find the wrong one by matching filename and fail. 
# See the piper wrapper script below instead.
RUN if [ "$WITH_PIPER" = "1" ]; then \
      wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub \
      && wget -q -O /tmp/glibc.apk \
           "https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC_VERSION}/glibc-${GLIBC_VERSION}.apk" \
      && apk add --no-cache --allow-untrusted /tmp/glibc.apk \
      && rm -f /tmp/glibc.apk \
      && mkdir -p /lib64 \
      && ln -sf /lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2 ; \
    fi
COPY --from=builder /out/glibc-libs/ /usr/glibc-compat/lib/

# --- Piper: neural TTS (optional) ------------------------------------------
RUN if [ "$WITH_PIPER" = "1" ]; then \
      mkdir -p /opt/piper /opt/zorkpbx/voices \
      && curl -fL "https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_linux_x86_64.tar.gz" \
           -o /tmp/piper.tar.gz \
      && tar xzf /tmp/piper.tar.gz -C /opt/piper --strip-components=1 \
      && rm -f /tmp/piper.tar.gz \
      && { \
           echo '#!/bin/sh' ; \
           echo '# Wrapper, not a symlink: scopes glibc paths to piper alone so they' ; \
           echo "# never leak into Asterisk's (musl) process tree via a container-wide" ; \
           echo '# LD_LIBRARY_PATH. See the NOTE above the glibc-compat install step.' ; \
           echo 'export LD_LIBRARY_PATH="/opt/piper:/usr/glibc-compat/lib"' ; \
           echo 'exec /opt/piper/piper "$@"' ; \
         } > /usr/local/bin/piper \
      && chmod +x /usr/local/bin/piper \
      && curl -fL -o "/opt/zorkpbx/voices/${PIPER_VOICE}.onnx" \
           "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/$(echo "${PIPER_VOICE}" | cut -d- -f2)/$(echo "${PIPER_VOICE}" | cut -d- -f3)/${PIPER_VOICE}.onnx" \
      && curl -fL -o "/opt/zorkpbx/voices/${PIPER_VOICE}.onnx.json" \
           "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/$(echo "${PIPER_VOICE}" | cut -d- -f2)/$(echo "${PIPER_VOICE}" | cut -d- -f3)/${PIPER_VOICE}.onnx.json" ; \
    fi

# --- Copy dfrotz / whisper-cli / whisper model from the builder stage -----
COPY --from=builder /out/bin/ /usr/local/bin/
COPY --from=builder /out/share/whisper-models/ /usr/local/share/whisper-models/

# --- ZorkPBX itself ----------------------------------------------------------
COPY --from=builder /src/zorkpbx /opt/zorkpbx
RUN python3 -m venv /opt/zorkpbx/.venv \
    && /opt/zorkpbx/.venv/bin/pip install --quiet --no-cache-dir --upgrade pip \
    && /opt/zorkpbx/.venv/bin/pip install --quiet --no-cache-dir -r /opt/zorkpbx/requirements.txt \
    && /opt/zorkpbx/.venv/bin/python -m py_compile /opt/zorkpbx/agi/zorkpbx.py \
    && mkdir -p /opt/zorkpbx/games /opt/zorkpbx/saves /opt/zorkpbx/audio \
    && [ -f /opt/zorkpbx/.env ] || cp /opt/zorkpbx/.env.example /opt/zorkpbx/.env \
    && if [ "$WITH_PIPER" = "1" ]; then \
         { echo "ZORKPBX_TTS_ENGINE=piper"; \
           echo "ZORKPBX_PIPER_MODEL=/opt/zorkpbx/voices/${PIPER_VOICE}.onnx"; \
         } >> /opt/zorkpbx/.env ; \
       fi \
    && if [ "$WITH_WHISPER" = "1" ]; then \
         echo "ZORKPBX_WHISPER_MODEL_DIR=/usr/local/share/whisper-models" >> /opt/zorkpbx/.env ; \
       fi \
    && mkdir -p /var/lib/asterisk/agi-bin \
    && cp /opt/zorkpbx/agi/zorkpbx.py /var/lib/asterisk/agi-bin/zorkpbx.py \
    && sed -i "1c#!/opt/zorkpbx/.venv/bin/python" /var/lib/asterisk/agi-bin/zorkpbx.py \
    && chmod +x /var/lib/asterisk/agi-bin/zorkpbx.py

# --- Bundled game files: Zork I/II/III (MIT-licensed, see ARG block above) -
# Skip with --build-arg WITH_BUNDLED_ZORK=0 to go back to bind-mount-your-own 
# (e.g. if you want a different release/localization).
RUN if [ "$WITH_BUNDLED_ZORK" = "1" ]; then \
      curl -fL -o /opt/zorkpbx/games/ZORK1.DAT \
        "https://raw.githubusercontent.com/historicalsource/zork1/${ZORK1_REF}/zork1.zip" \
      && curl -fL -o /opt/zorkpbx/games/ZORK2.DAT \
        "https://raw.githubusercontent.com/historicalsource/zork2/${ZORK2_REF}/zork2.zip" \
      && curl -fL -o /opt/zorkpbx/games/ZORK3.DAT \
        "https://raw.githubusercontent.com/historicalsource/zork3/${ZORK3_REF}/zork3.zip" \
      && curl -fL -o /opt/zorkpbx/games/LICENSE-zork1.txt \
        "https://raw.githubusercontent.com/historicalsource/zork1/${ZORK1_REF}/LICENSE" \
      && curl -fL -o /opt/zorkpbx/games/LICENSE-zork2.txt \
        "https://raw.githubusercontent.com/historicalsource/zork2/${ZORK2_REF}/LICENSE" \
      && curl -fL -o /opt/zorkpbx/games/LICENSE-zork3.txt \
        "https://raw.githubusercontent.com/historicalsource/zork3/${ZORK3_REF}/LICENSE" \
      && for f in ZORK1 ZORK2 ZORK3; do \
           v="$(dd if=/opt/zorkpbx/games/${f}.DAT bs=1 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')" ; \
           [ "$v" = "3" ] || { echo "FATAL: ${f}.DAT is not a valid Z-machine v3 file (byte0=$v)" >&2; exit 1; } ; \
         done \
    ; fi

# --- Asterisk config ---------------------------------------------------------
# Promote whatever asterisk-sample-config dropped (commonly *.sample) to real
# config files (asterisk.conf, modules.conf, etc. - paths/autoload as shipped
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

VOLUME ["/opt/zorkpbx/games", "/opt/zorkpbx/saves", "/opt/zorkpbx/audio"]
EXPOSE 5060/udp 10000-10020/udp

ENTRYPOINT ["/entrypoint.sh"]
