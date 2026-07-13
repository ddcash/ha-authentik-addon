#!/usr/bin/env bash
# Executed by the Supervisor before every Home Assistant backup (backup_pre).
# Writes a consistent SQL dump into the user-visible addon_config folder so a
# restore never has to rely on a binary copy of the running PostgreSQL data dir.
# Always exits 0 — a failed dump must not block the Home Assistant backup.

OPTIONS=/data/options.json
opt() { jq -r "$1 | if . == null then empty else tostring end" "${OPTIONS}" 2>/dev/null; }

mkdir -p /config/backups

DB_MODE="$(opt '.postgresql_mode')"
[ "${DB_MODE}" != "external" ] && DB_MODE="internal"

if [ "${DB_MODE}" = "internal" ]; then
    if runuser -u postgres -- pg_isready -h /run/postgresql -q 2>/dev/null; then
        echo "[authentik-addon] Writing database dump to /config/backups/authentik-latest.sql"
        runuser -u postgres -- pg_dump -h /run/postgresql -d authentik \
            > /config/backups/authentik-latest.sql \
            || echo "[authentik-addon] WARNING: database dump failed"
    else
        echo "[authentik-addon] PostgreSQL not running — skipping pre-backup dump"
    fi
else
    # Best effort for external databases: pg_dump refuses to dump servers
    # newer than itself, and backing up an external server is ultimately the
    # responsibility of whoever runs it.
    HOST="$(opt '.postgresql_host')"
    PORT="$(opt '.postgresql_port')"
    NAME="$(opt '.postgresql_name')"
    USER="$(opt '.postgresql_user')"
    : "${PORT:=5432}" "${NAME:=authentik}" "${USER:=authentik}"
    echo "[authentik-addon] Attempting dump of external database ${NAME} at ${HOST}:${PORT}"
    PGPASSWORD="$(opt '.postgresql_password')" pg_dump -h "${HOST}" -p "${PORT}" \
        -U "${USER}" -d "${NAME}" \
        > /config/backups/authentik-latest.sql \
        || echo "[authentik-addon] WARNING: external database dump failed (version mismatch or connectivity) — back up the external server directly"
fi
exit 0
