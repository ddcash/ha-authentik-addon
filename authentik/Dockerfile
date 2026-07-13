# The add-on is built on top of the official authentik server image, which
# already contains the authentik server, worker and embedded outpost.
# We add PostgreSQL and Redis so the whole stack runs in a single container,
# as required for a Home Assistant add-on.
ARG BUILD_FROM=ghcr.io/goauthentik/server:2026.5.4
FROM ${BUILD_FROM}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql \
        redis-server \
        jq \
        openssl \
    && rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
COPY dump-db.sh /dump-db.sh
RUN chmod a+x /run.sh /dump-db.sh

# CRITICAL: drop the base image's HEALTHCHECK. It runs `ak healthcheck` — as
# root, since this add-on stays root for its supervisor script — and authentik's
# `ak` entrypoint, when root, does `chown -R authentik:authentik /data`, which
# rips the PostgreSQL data directory (also under /data) away from the postgres
# user ~30s after every boot. The Home Assistant Supervisor watchdog
# (config.yaml) does the health checking instead.
HEALTHCHECK NONE

# Replace authentik's entrypoint with our supervisor script; Home Assistant's
# docker --init (tini) acts as PID 1.
ENTRYPOINT []
CMD ["/run.sh"]
