# Changelog

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
