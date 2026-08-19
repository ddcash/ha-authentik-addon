# The add-on is built on top of the official authentik server image, which
# already contains the authentik server, worker and embedded outpost.
# We add PostgreSQL and Redis so the whole stack runs in a single container,
# as required for a Home Assistant add-on.
ARG BUILD_FROM=ghcr.io/goauthentik/server:2026.8.0
FROM ${BUILD_FROM}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql \
        redis-server \
        jq \
        openssl \
        curl \
    && rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
COPY dump-db.sh /dump-db.sh
RUN chmod a+x /run.sh /dump-db.sh

# CRITICAL: replace the base image's HEALTHCHECK. Its `ak healthcheck` runs as
# root (this add-on stays root for its supervisor script), and authentik's `ak`
# entrypoint, when root, does `chown -R authentik:authentik /data` — ripping
# the PostgreSQL data directory (also under /data) away from the postgres user
# ~30s after every boot. This plain curl probe against authentik's liveness
# endpoint is side-effect free, drives the add-on's Starting → Running state in
# the Home Assistant UI, and works regardless of how the host port is remapped.
# The generous start period covers first-boot database migrations.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD curl -fsS http://127.0.0.1:9000/-/health/live/ || exit 1

# Replace authentik's entrypoint with our supervisor script; Home Assistant's
# docker --init (tini) acts as PID 1.
ENTRYPOINT []
CMD ["/run.sh"]
