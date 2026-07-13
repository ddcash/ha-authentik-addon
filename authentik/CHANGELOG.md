# Changelog

## 2026.5.4.4

- Fix add-on showing "Starting" forever in Home Assistant: replaced the
  obsolete `watchdog` URL (which broke when the host port was remapped) with a
  safe Docker `HEALTHCHECK` — a plain curl against authentik's liveness
  endpoint inside the container. The add-on now transitions to "Running" once
  authentik is actually up, and the Supervisor watchdog toggle keys off this
  health state.
- Add official authentik icon and logo.
- Fix add-on config schema for the lint workflow: removed the invalid
  `data:rw` map entry (`/data` is always mounted) and the redundant
  `boot: auto` default; `addon_config` now uses the structured map format.
- Update GitHub Actions to `actions/checkout@v5` (Node 20 deprecation).

## 2026.5.4.3

- Fix blank web UI: `ak worker` and `ak server` both bind port 9000 when run
  in the same container — the worker's internal server won the bind and served
  empty responses while the real web server failed with "address already in
  use". The add-on now uses authentik's `allinone` mode, which runs the worker
  and web server as one coordinated process (the intended single-container
  deployment mode).

## 2026.5.4.2

- Fix PostgreSQL "Permission denied" crash ~30s after boot: the base image's
  Docker `HEALTHCHECK` runs `ak healthcheck` as root, and authentik's
  entrypoint chowns all of `/data` (including the bundled PostgreSQL data
  directory) to the authentik user when run as root. The inherited healthcheck
  is now disabled (`HEALTHCHECK NONE`) — health monitoring is done by the
  Supervisor watchdog. Startup re-chowns the database directory, so installs
  broken by this heal themselves on update.
- Store uploaded media via `AUTHENTIK_STORAGE__FILE__PATH=/config/media`
  (authentik 2026.x file-storage path) instead of the legacy `/media` symlink.

## 2026.5.4.1

- Fix startup crash on first boot: boolean add-on options set to `false`
  (e.g. `error_reporting`, `default_user_change_email`) were exported as empty
  strings, which authentik's config loader rejects with "provided string was
  not `true` or `false`".
- Harden all option parsing with explicit defaults.

## 2026.5.4

- Initial release.
- authentik 2026.5.4 (server + worker + embedded outpost).
- Bundled PostgreSQL and Redis; database and secrets persisted in `/data`.
- PostgreSQL and Redis can each independently run in `internal` mode (bundled,
  default) or `external` mode — pointing at another machine, container, or
  Home Assistant add-on (e.g. TimescaleDB) — configurable in the add-on
  options, with startup reachability checks and clear error messages.
- User-facing state (media, certs, custom templates, blueprints, GeoIP,
  DB dumps, `authentik.env` override file) lives in the addon_config folder
  (`/addon_configs/<slug>_authentik`) for easy backup and manual edits.
- Consistent SQL dump written to `backups/authentik-latest.sql` before every
  Home Assistant backup.
- Options for akadmin bootstrap credentials/token, SMTP, cookie domain,
  trusted proxies, telemetry toggles, avatars, user self-service permissions,
  GDPR/impersonation, footer links, web worker sizing, and arbitrary
  `AUTHENTIK_*` environment variables.
- Works behind a Cloudflare tunnel, behind any reverse proxy, or standalone on
  the LAN (HTTP 9000 / HTTPS 9443).
- Supervisor watchdog wired to authentik's health endpoint.
