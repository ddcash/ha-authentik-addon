#!/usr/bin/env bash
# Supervisor script for the authentik Home Assistant add-on.
# Starts the authentik worker and server, plus PostgreSQL and Redis when they
# run in "internal" mode. Both can instead point at external servers (another
# machine, container, or Home Assistant add-on) via the add-on options.
#
# Storage layout:
#   /data    (add-on data)  — PostgreSQL cluster (internal mode), generated
#                             secrets. Managed by the add-on; not meant for
#                             manual edits.
#   /config  (addon_config) — everything a user may want to inspect, back up or
#                             modify by hand. Reachable on the host at
#                             /addon_configs/<slug>_authentik via Samba/SSH:
#                             media/, certs/, custom-templates/, blueprints/,
#                             geoip/, backups/, authentik.env
set -o pipefail

OPTIONS=/data/options.json

log() { echo "[authentik-addon] $*"; }

# NOTE: do not use jq's `//` here — it treats `false` as falsy, which turned
# boolean options set to false into empty strings (authentik's config loader
# rejects an empty string where a bool is expected).
opt() { jq -r "$1 | if . == null then empty else tostring end" "${OPTIONS}" 2>/dev/null; }

# opt with a fallback default for options that must never be empty.
opt_default() {
    local v
    v="$(opt "$1")"
    echo "${v:-$2}"
}

# Wait for a TCP endpoint to accept connections.
wait_for_tcp() {
    local host="$1" port="$2" timeout="${3:-60}" waited=0
    while ! (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; do
        waited=$((waited + 2))
        if [ "${waited}" -ge "${timeout}" ]; then
            return 1
        fi
        sleep 2
    done
    exec 3>&- 2>/dev/null
    return 0
}

DB_MODE="$(opt '.postgresql_mode')"
[ "${DB_MODE}" != "external" ] && DB_MODE="internal"
REDIS_MODE="$(opt '.redis_mode')"
[ "${REDIS_MODE}" != "external" ] && REDIS_MODE="internal"
log "PostgreSQL: ${DB_MODE} — Redis: ${REDIS_MODE}"

# ---------------------------------------------------------------------------
# Directories and fixed container paths
# ---------------------------------------------------------------------------
mkdir -p /data/redis /run/postgresql \
    /config/media /config/certs /config/custom-templates /config/blueprints \
    /config/geoip /config/backups
chown -R authentik:authentik /config/media /config/certs /config/custom-templates \
    /config/blueprints /config/geoip /data/redis

if [ ! -s /config/README.txt ]; then
    cat > /config/README.txt <<'EOF'
authentik add-on configuration folder
=====================================
media/             uploaded icons, flow backgrounds, application logos
certs/             drop certificates here; authentik auto-imports them
                   (select one as "Web Certificate" under Brands for port 9443)
custom-templates/  custom email templates
blueprints/        custom authentik blueprints (YAML), applied automatically
geoip/             optional GeoLite2-City.mmdb / GeoLite2-ASN.mmdb for GeoIP
backups/           authentik-latest.sql — consistent DB dump written before
                   every Home Assistant backup
authentik.env      optional; lines of AUTHENTIK_*=value applied at startup,
                   overriding add-on options (advanced use)

In the default "internal" mode the PostgreSQL database itself lives in the
add-on's /data volume and is included in Home Assistant backups automatically.
EOF
fi

# authentik expects fixed paths inside the container; point them at the
# user-accessible addon_config storage.
link_path() {
    local path="$1" target="$2"
    if [ ! -L "${path}" ]; then
        rm -rf "${path}"
        ln -s "${target}" "${path}"
    fi
}
link_path /media /config/media
link_path /certs /config/certs
link_path /templates /config/custom-templates
# built-in blueprints ship in /blueprints; custom ones are picked up from a
# subdirectory
link_path /blueprints/custom /config/blueprints

# ---------------------------------------------------------------------------
# Secrets (generated once, persisted in /data)
# ---------------------------------------------------------------------------
if [ ! -s /data/secret_key ]; then
    log "Generating authentik secret key"
    openssl rand -base64 60 | tr -d '\n' > /data/secret_key
fi
chmod 600 /data/secret_key
SECRET_KEY="$(cat /data/secret_key)"

# ---------------------------------------------------------------------------
# PostgreSQL — internal or external
# ---------------------------------------------------------------------------
if [ "${DB_MODE}" = "internal" ]; then
    if [ ! -s /data/postgres_password ]; then
        log "Generating PostgreSQL password"
        openssl rand -hex 32 | tr -d '\n' > /data/postgres_password
    fi
    chmod 600 /data/postgres_password

    AK_PG_HOST="127.0.0.1"
    AK_PG_PORT="5432"
    AK_PG_NAME="authentik"
    AK_PG_USER="authentik"
    AK_PG_PASSWORD="$(cat /data/postgres_password)"
    AK_PG_SSLMODE=""

    mkdir -p /data/postgresql
    chown -R postgres:postgres /data/postgresql /run/postgresql
    chmod 700 /data/postgresql

    PG_BIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -n 1)"
    if [ -z "${PG_BIN}" ]; then
        log "FATAL: PostgreSQL binaries not found"
        exit 1
    fi

    if [ ! -s /data/postgresql/PG_VERSION ]; then
        log "Initializing PostgreSQL cluster"
        runuser -u postgres -- "${PG_BIN}/initdb" -D /data/postgresql \
            -E UTF8 --locale=C.UTF-8 \
            --auth-local=peer --auth-host=scram-sha-256 || exit 1
    fi

    log "Starting PostgreSQL"
    runuser -u postgres -- "${PG_BIN}/pg_ctl" -D /data/postgresql -w -t 60 \
        -l /data/postgresql/pg_ctl.log \
        -o "-c listen_addresses=127.0.0.1 -c unix_socket_directories=/run/postgresql" \
        start
    if [ $? -ne 0 ]; then
        log "FATAL: PostgreSQL failed to start"
        tail -n 50 /data/postgresql/pg_ctl.log 2>/dev/null
        exit 1
    fi

    psql_su() {
        runuser -u postgres -- psql -h /run/postgresql -v ON_ERROR_STOP=1 -tAc "$1"
    }

    if [ "$(psql_su "SELECT 1 FROM pg_roles WHERE rolname='authentik'")" != "1" ]; then
        log "Creating database role 'authentik'"
        psql_su "CREATE ROLE authentik LOGIN PASSWORD '${AK_PG_PASSWORD}'" || exit 1
    else
        # keep role password in sync with the persisted secret
        psql_su "ALTER ROLE authentik WITH LOGIN PASSWORD '${AK_PG_PASSWORD}'" || exit 1
    fi
    if [ "$(psql_su "SELECT 1 FROM pg_database WHERE datname='authentik'")" != "1" ]; then
        log "Creating database 'authentik'"
        psql_su "CREATE DATABASE authentik OWNER authentik" || exit 1
    fi
else
    AK_PG_HOST="$(opt '.postgresql_host')"
    AK_PG_PORT="$(opt '.postgresql_port')"
    AK_PG_NAME="$(opt '.postgresql_name')"
    AK_PG_USER="$(opt '.postgresql_user')"
    AK_PG_PASSWORD="$(opt '.postgresql_password')"
    AK_PG_SSLMODE="$(opt '.postgresql_sslmode')"
    : "${AK_PG_PORT:=5432}" "${AK_PG_NAME:=authentik}" "${AK_PG_USER:=authentik}"

    if [ -z "${AK_PG_HOST}" ] || [ -z "${AK_PG_PASSWORD}" ]; then
        log "FATAL: postgresql_mode is 'external' but postgresql_host and/or postgresql_password are not set"
        exit 1
    fi

    log "Waiting for external PostgreSQL at ${AK_PG_HOST}:${AK_PG_PORT}"
    if ! wait_for_tcp "${AK_PG_HOST}" "${AK_PG_PORT}" 60; then
        log "FATAL: cannot reach external PostgreSQL at ${AK_PG_HOST}:${AK_PG_PORT}"
        log "Check host/port, and make sure the database server allows remote connections."
        exit 1
    fi
    log "External PostgreSQL is reachable. The database '${AK_PG_NAME}' and user '${AK_PG_USER}' must already exist — authentik manages the schema itself."
fi

# ---------------------------------------------------------------------------
# Redis — internal or external
# ---------------------------------------------------------------------------
if [ "${REDIS_MODE}" = "internal" ]; then
    AK_REDIS_HOST="127.0.0.1"
    AK_REDIS_PORT="6379"
    AK_REDIS_PASSWORD=""
    AK_REDIS_DB=""
    AK_REDIS_TLS=""

    log "Starting Redis (cache only — no persistence needed)"
    runuser -u authentik -- redis-server \
        --bind 127.0.0.1 --port 6379 \
        --save "" --appendonly no \
        --dir /data/redis &
    REDIS_PID=$!
else
    AK_REDIS_HOST="$(opt '.redis_host')"
    AK_REDIS_PORT="$(opt '.redis_port')"
    AK_REDIS_PASSWORD="$(opt '.redis_password')"
    AK_REDIS_DB="$(opt '.redis_db')"
    AK_REDIS_TLS="$(opt '.redis_tls')"
    : "${AK_REDIS_PORT:=6379}"

    if [ -z "${AK_REDIS_HOST}" ]; then
        log "FATAL: redis_mode is 'external' but redis_host is not set"
        exit 1
    fi

    log "Waiting for external Redis at ${AK_REDIS_HOST}:${AK_REDIS_PORT}"
    if ! wait_for_tcp "${AK_REDIS_HOST}" "${AK_REDIS_PORT}" 60; then
        log "FATAL: cannot reach external Redis at ${AK_REDIS_HOST}:${AK_REDIS_PORT}"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# authentik environment — managed connection settings
# ---------------------------------------------------------------------------
# Applied twice: once here and once after /config/authentik.env, so the env
# file can't break the managed database/redis/secret wiring (those are
# configured through the add-on options instead).
apply_managed_env() {
    export AUTHENTIK_SECRET_KEY="${SECRET_KEY}"
    export AUTHENTIK_POSTGRESQL__HOST="${AK_PG_HOST}"
    export AUTHENTIK_POSTGRESQL__PORT="${AK_PG_PORT}"
    export AUTHENTIK_POSTGRESQL__NAME="${AK_PG_NAME}"
    export AUTHENTIK_POSTGRESQL__USER="${AK_PG_USER}"
    export AUTHENTIK_POSTGRESQL__PASSWORD="${AK_PG_PASSWORD}"
    [ -n "${AK_PG_SSLMODE}" ] && export AUTHENTIK_POSTGRESQL__SSLMODE="${AK_PG_SSLMODE}"
    export AUTHENTIK_REDIS__HOST="${AK_REDIS_HOST}"
    export AUTHENTIK_REDIS__PORT="${AK_REDIS_PORT}"
    [ -n "${AK_REDIS_PASSWORD}" ] && export AUTHENTIK_REDIS__PASSWORD="${AK_REDIS_PASSWORD}"
    [ -n "${AK_REDIS_DB}" ] && export AUTHENTIK_REDIS__DB="${AK_REDIS_DB}"
    [ "${AK_REDIS_TLS}" = "true" ] && export AUTHENTIK_REDIS__TLS="true"
    return 0
}
apply_managed_env

# ---------------------------------------------------------------------------
# authentik environment — from add-on options
# ---------------------------------------------------------------------------
export AUTHENTIK_LOG_LEVEL="$(opt_default '.log_level' info)"
export AUTHENTIK_ERROR_REPORTING__ENABLED="$(opt_default '.error_reporting' false)"
export AUTHENTIK_DISABLE_UPDATE_CHECK="$(opt_default '.disable_update_check' true)"
export AUTHENTIK_DISABLE_STARTUP_ANALYTICS="$(opt_default '.disable_startup_analytics' true)"
export AUTHENTIK_AVATARS="$(opt_default '.avatars' 'gravatar,initials')"
export AUTHENTIK_DEFAULT_USER_CHANGE_NAME="$(opt_default '.default_user_change_name' true)"
export AUTHENTIK_DEFAULT_USER_CHANGE_EMAIL="$(opt_default '.default_user_change_email' false)"
export AUTHENTIK_DEFAULT_USER_CHANGE_USERNAME="$(opt_default '.default_user_change_username' false)"
export AUTHENTIK_GDPR_COMPLIANCE="$(opt_default '.gdpr_compliance' true)"
export AUTHENTIK_IMPERSONATION="$(opt_default '.impersonation' true)"

COOKIE_DOMAIN="$(opt '.cookie_domain')"
[ -n "${COOKIE_DOMAIN}" ] && export AUTHENTIK_COOKIE_DOMAIN="${COOKIE_DOMAIN}"

TRUSTED_PROXIES="$(opt '.trusted_proxy_cidrs')"
[ -n "${TRUSTED_PROXIES}" ] && export AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS="${TRUSTED_PROXIES}"

WEB_WORKERS="$(opt '.web_workers')"
[ -n "${WEB_WORKERS}" ] && [ "${WEB_WORKERS}" != "0" ] && export AUTHENTIK_WEB__WORKERS="${WEB_WORKERS}"
WEB_THREADS="$(opt '.web_threads')"
[ -n "${WEB_THREADS}" ] && [ "${WEB_THREADS}" != "0" ] && export AUTHENTIK_WEB__THREADS="${WEB_THREADS}"

FOOTER_LINKS="$(jq -c '[.footer_links[]? | {name: .name, href: .href}]' "${OPTIONS}" 2>/dev/null)"
[ -n "${FOOTER_LINKS}" ] && [ "${FOOTER_LINKS}" != "[]" ] && export AUTHENTIK_FOOTER_LINKS="${FOOTER_LINKS}"

# Bootstrap credentials for the default akadmin account (first start only;
# authentik ignores these once akadmin has a password).
BOOTSTRAP_PASSWORD="$(opt '.bootstrap_password')"
[ -n "${BOOTSTRAP_PASSWORD}" ] && export AUTHENTIK_BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD}"
BOOTSTRAP_EMAIL="$(opt '.bootstrap_email')"
[ -n "${BOOTSTRAP_EMAIL}" ] && export AUTHENTIK_BOOTSTRAP_EMAIL="${BOOTSTRAP_EMAIL}"
BOOTSTRAP_TOKEN="$(opt '.bootstrap_token')"
[ -n "${BOOTSTRAP_TOKEN}" ] && export AUTHENTIK_BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN}"

if [ "$(opt '.email_enabled')" = "true" ]; then
    export AUTHENTIK_EMAIL__HOST="$(opt '.email_host')"
    export AUTHENTIK_EMAIL__PORT="$(opt_default '.email_port' 587)"
    export AUTHENTIK_EMAIL__USERNAME="$(opt '.email_username')"
    export AUTHENTIK_EMAIL__PASSWORD="$(opt '.email_password')"
    export AUTHENTIK_EMAIL__USE_TLS="$(opt_default '.email_use_tls' true)"
    export AUTHENTIK_EMAIL__USE_SSL="$(opt_default '.email_use_ssl' false)"
    export AUTHENTIK_EMAIL__TIMEOUT="$(opt_default '.email_timeout' 10)"
    export AUTHENTIK_EMAIL__FROM="$(opt '.email_from')"
fi

# GeoIP databases dropped into /config/geoip are picked up automatically.
if [ -s /config/geoip/GeoLite2-City.mmdb ]; then
    export AUTHENTIK_EVENTS__CONTEXT_PROCESSORS__GEOIP="/config/geoip/GeoLite2-City.mmdb"
    log "GeoIP city database enabled"
fi
if [ -s /config/geoip/GeoLite2-ASN.mmdb ]; then
    export AUTHENTIK_EVENTS__CONTEXT_PROCESSORS__ASN="/config/geoip/GeoLite2-ASN.mmdb"
    log "GeoIP ASN database enabled"
fi

# Escape hatch 1: env_vars list from the add-on configuration.
while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    name="$(echo "${entry}" | jq -r '.name')"
    value="$(echo "${entry}" | jq -r '.value')"
    export "${name}=${value}"
    log "Set extra environment variable ${name}"
done < <(jq -c '.env_vars[]?' "${OPTIONS}" 2>/dev/null)

# Escape hatch 2: /config/authentik.env — loaded last, overrides everything
# except the managed connection settings.
if [ -s /config/authentik.env ]; then
    log "Applying /config/authentik.env"
    set -a
    # shellcheck disable=SC1091
    . /config/authentik.env
    set +a
    apply_managed_env
fi

# ---------------------------------------------------------------------------
# authentik server + worker
# ---------------------------------------------------------------------------
AK_CMD="$(command -v ak || true)"
[ -z "${AK_CMD}" ] && AK_CMD=/lifecycle/ak

cleanup() {
    log "Shutting down"
    [ -n "${SERVER_PID:-}" ] && kill -TERM "${SERVER_PID}" 2>/dev/null
    [ -n "${WORKER_PID:-}" ] && kill -TERM "${WORKER_PID}" 2>/dev/null
    wait "${SERVER_PID}" "${WORKER_PID}" 2>/dev/null
    [ -n "${REDIS_PID:-}" ] && kill -TERM "${REDIS_PID}" 2>/dev/null
    if [ "${DB_MODE}" = "internal" ]; then
        runuser -u postgres -- "${PG_BIN}/pg_ctl" -D /data/postgresql -m fast -w stop
    fi
}
on_term() {
    cleanup
    exit 0
}
trap on_term TERM INT

log "Starting authentik worker"
runuser -u authentik -- "${AK_CMD}" worker &
WORKER_PID=$!

log "Starting authentik server"
runuser -u authentik -- "${AK_CMD}" server &
SERVER_PID=$!

# If either process dies, stop everything so the Supervisor watchdog restarts
# the add-on cleanly.
wait -n "${WORKER_PID}" "${SERVER_PID}"
rc=$?
log "An authentik process exited unexpectedly (rc=${rc})"
cleanup
exit "${rc:-1}"
