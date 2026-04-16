# vim:set ft=dockerfile:
ARG DEBIAN_VERSION=bookworm
FROM debian:${DEBIAN_VERSION}

ARG DEBIAN_VERSION
ARG SIGNALWIRE_TOKEN
ARG FREESWITCH_UID=499
ARG FREESWITCH_GID=499

ARG FS_PACKAGES="freeswitch \
  freeswitch-mod-console \
  freeswitch-mod-logfile \
  freeswitch-mod-sofia \
  freeswitch-mod-commands \
  freeswitch-mod-db \
  freeswitch-mod-dptools \
  freeswitch-mod-hash \
  freeswitch-mod-dialplan-xml \
  freeswitch-mod-sndfile \
  freeswitch-mod-native-file \
  freeswitch-mod-tone-stream \
  freeswitch-mod-lua \
  freeswitch-mod-curl \
  freeswitch-mod-event-socket \
  freeswitch-mod-local-stream \
  freeswitch-mod-loopback"
# Note: no freeswitch-sounds-* packages — every prompt this IVR plays is a
# bespoke recording mounted in at /var/lib/freeswitch/sounds/retromusicbox/en/.

RUN groupadd -r freeswitch --gid=${FREESWITCH_GID} \
 && useradd -r -g freeswitch --uid=${FREESWITCH_UID} freeswitch

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      ca-certificates gnupg2 gosu locales wget curl \
 && localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.utf8

RUN wget --no-verbose --http-user=signalwire --http-password=${SIGNALWIRE_TOKEN} \
      -O /usr/share/keyrings/signalwire-freeswitch-repo.gpg \
      https://freeswitch.signalwire.com/repo/deb/debian-release/signalwire-freeswitch-repo.gpg \
 && echo "machine freeswitch.signalwire.com login signalwire password ${SIGNALWIRE_TOKEN}" > /etc/apt/auth.conf \
 && echo "deb [signed-by=/usr/share/keyrings/signalwire-freeswitch-repo.gpg] https://freeswitch.signalwire.com/repo/deb/debian-release/ ${DEBIAN_VERSION} main" > /etc/apt/sources.list.d/freeswitch.list \
 && apt-get -qq update \
 && apt-get install -y ${FS_PACKAGES} \
 && rm -f /etc/apt/auth.conf \
 && apt-get purge -y --auto-remove \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# The SignalWire bookworm package ships only the binaries — there is no
# vanilla config tree at /usr/share/freeswitch/conf/. Every config file in
# this image is hand-authored under conf/ in the repo. Copy the whole tree
# in at build time; runtime config is via env vars only.
COPY conf/ /etc/freeswitch/
COPY scripts/ /etc/freeswitch/scripts/

# Bake the bespoke IVR prompts into the image. scripts/config.lua references
# them as /var/lib/freeswitch/sounds/retromusicbox/en/<name>.wav and expects
# per-digit clips under a `digits/` subdir — which matches this layout.
# Shipping them in the image keeps the deployment a single artifact (no
# runtime volume mount required); for iterating on recordings locally you
# can still mount over this path in docker-compose.
COPY sounds/ /var/lib/freeswitch/sounds/retromusicbox/en/

RUN chown -R freeswitch:freeswitch /etc/freeswitch /var/lib/freeswitch /var/log/freeswitch /var/run/freeswitch 2>/dev/null || true

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 5060/udp 5060/tcp 5080/udp 5080/tcp
EXPOSE 16384-32768/udp

HEALTHCHECK --interval=15s --timeout=5s \
    CMD fs_cli -x status | grep -q ^UP || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["freeswitch"]
