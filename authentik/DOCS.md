# authentik Home Assistant Add-on

[authentik](https://goauthentik.io) is a self-hosted identity provider (IdP).
This add-on runs the complete authentik stack — server, worker, PostgreSQL and
Redis — in a single container so you can provide single sign-on (SSO) to every
app you host, whether it runs on this Home Assistant machine or elsewhere.

It works in every access scenario: behind a Cloudflare tunnel, behind your own
reverse proxy, or plain LAN-only access with no tunnel at all.

## Storage layout

| Location | Contents |
| --- | --- |
| Add-on data (`/data`) | PostgreSQL database (internal mode), generated secrets. Managed automatically; included in Home Assistant backups. |
| `/addon_configs/<slug>_authentik` | Everything you may want to inspect, back up or edit by hand. Reachable via the Samba/SSH add-ons. |

Inside the addon_config folder:

```
media/             uploaded icons, flow backgrounds, application logos
certs/             drop certificates here — authentik auto-imports them
custom-templates/  custom email templates
blueprints/        custom authentik blueprints (YAML), applied automatically
geoip/             optional GeoLite2-City.mmdb / GeoLite2-ASN.mmdb
backups/           authentik-latest.sql (fresh SQL dump) + secrets.env
restore/           drop files here to restore/import — see below
authentik.env      optional AUTHENTIK_*=value lines, applied at startup
```

The add-on keeps `backups/` up to date automatically: a consistent SQL dump is
written to `backups/authentik-latest.sql` a few minutes after every start,
once a day, on every shutdown, and right before every Home Assistant backup.
`backups/secrets.env` holds the authentik secret key. Together with the rest
of this folder (media, certs, templates, blueprints), that is **everything
needed to rebuild this instance on another machine** — see below.

## First start

1. (Recommended) Before first start, set **bootstrap_password** (and optionally
   **bootstrap_email**) in the add-on configuration. These set the password for
   the built-in `akadmin` admin account on first boot. They are ignored once
   the account exists.
2. Start the add-on. The first start takes a few minutes: the database is
   initialized and authentik runs all its migrations. Watch the log until you
   see the server listening.
3. Open the Web UI (port 9000) and sign in as `akadmin`.
   - If you did **not** set a bootstrap password, go to
     `http://<your-ha-ip>:9000/if/flow/initial-setup/` to create the admin
     password (only available until initial setup is completed).

## Database and Redis: internal or external

By default the add-on is fully self-contained: it runs its own PostgreSQL and
Redis inside the container (`postgresql_mode: internal`, `redis_mode:
internal`) with zero setup. Each can independently be switched to an external
server — another machine, a Docker container elsewhere, or another Home
Assistant add-on.

### External PostgreSQL

```yaml
postgresql_mode: external
postgresql_host: 192.168.1.50      # hostname or IP
postgresql_port: 5432
postgresql_name: authentik
postgresql_user: authentik
postgresql_password: "…"
postgresql_sslmode: prefer          # disable/allow/prefer/require/verify-ca/verify-full
```

The database and user must already exist (authentik creates and migrates its
own schema). On the external server:

```sql
CREATE USER authentik WITH PASSWORD '…';
CREATE DATABASE authentik OWNER authentik;
```

PostgreSQL 14 or newer is required. Make sure the server accepts remote
connections (`listen_addresses`, `pg_hba.conf`) from the Home Assistant host.

### External Redis

```yaml
redis_mode: external
redis_host: 192.168.1.50
redis_port: 6379
redis_password: ""                  # only if the server requires AUTH
redis_db: 0
redis_tls: false
```

authentik uses Redis as a cache only, so no persistence configuration is
needed on the external server.

### Using other Home Assistant add-ons as the database/Redis

Add-ons on the same Home Assistant machine reach each other by container
hostname — shown as **Hostname** on the other add-on's *Info* tab (e.g.
`77b2833f-timescaledb` for the community TimescaleDB add-on, which is a full
PostgreSQL server). Use that hostname as `postgresql_host`/`redis_host`; no
port needs to be exposed on the host for add-on-to-add-on traffic. Create the
database and user first (TimescaleDB bundles pgAdmin/adminer for this, or use
`psql` from its terminal).

Notes for external mode:

- The add-on checks reachability at startup and logs a clear error if the
  server can't be reached, instead of crash-looping silently.
- The pre-backup SQL dump still runs against external databases (best effort —
  if the external server is a much newer PostgreSQL major version than the
  bundled `pg_dump`, the dump is skipped with a warning; back up that server
  directly in that case).
- Switching an existing install between internal and external does **not**
  migrate your data. To move, dump the old database and restore it into the
  new one while the add-on is stopped, then flip the mode.

## Configuration options

| Option | Description |
| --- | --- |
| `log_level` | authentik log level (`trace`/`debug`/`info`/`warning`/`error`). |
| `postgresql_mode` / `postgresql_*` | Internal (bundled) or external PostgreSQL — see the section above. |
| `redis_mode` / `redis_*` | Internal (bundled) or external Redis — see the section above. |
| `bootstrap_email` / `bootstrap_password` / `bootstrap_token` | akadmin credentials and optional API token, applied on the very first start only. |
| `cookie_domain` | Parent domain (e.g. `example.com`) to share authentik's session cookie across subdomains. Usually not required. |
| `trusted_proxy_cidrs` | Comma-separated CIDRs allowed to set `X-Forwarded-*` headers. Empty = authentik's default (all private ranges), which covers a local `cloudflared` or reverse proxy. |
| `error_reporting`, `disable_update_check`, `disable_startup_analytics` | Privacy/telemetry toggles. Defaults keep everything off/local. |
| `avatars` | Avatar sources, e.g. `gravatar,initials` or just `initials` for fully offline operation. |
| `default_user_change_name` / `_email` / `_username` | What users may edit on their own profile. |
| `gdpr_compliance` | Anonymise event IPs when a user is deleted. |
| `impersonation` | Allow admins to impersonate users. |
| `footer_links` | List of `name`/`href` pairs shown on login pages. |
| `web_workers` / `web_threads` | Gunicorn sizing; `0` = authentik default. Lower `web_workers` to `1` on small SBCs. |
| `email_*` | SMTP settings so authentik can send recovery/verification emails. Enable with `email_enabled: true`. |
| `env_vars` | Name/value pairs for any other [authentik setting](https://docs.goauthentik.io/docs/install-config/configuration/) (names must start with `AUTHENTIK_`). |

Two escape hatches cover the rest of authentik's configuration surface:
`env_vars` in the options UI, and the `authentik.env` file in the addon_config
folder (loaded last, wins over options). Database/Redis connection settings and
`AUTHENTIK_SECRET_KEY` are managed by the add-on and cannot be overridden —
everything else can.

## Access scenarios

### A. Behind a Cloudflare tunnel

The add-on serves plain HTTP on port 9000, which is exactly what `cloudflared`
wants as an origin.

1. In [Cloudflare Zero Trust](https://one.dash.cloudflare.com) →
   **Networks → Tunnels**, open your tunnel and add a **Public Hostname**:
   - Subdomain: `auth` (→ `auth.example.com`)
   - Service: `http://<your-ha-ip>:9000`
     (If `cloudflared` runs as a Home Assistant add-on on the same machine,
     the host IP works fine.)
2. No extra header configuration is needed. Cloudflare and `cloudflared` set
   `X-Forwarded-For`/`X-Forwarded-Proto`, and authentik trusts them from
   private-network proxies by default. WebSockets (used by authentik outposts)
   work through Cloudflare tunnels out of the box.
3. Do **not** put Cloudflare Access in front of `auth.example.com` — the IdP
   itself must be reachable for login redirects from all your apps.
4. Sign in at `https://auth.example.com`. authentik uses the request's `Host`
   header, so issued OIDC/SAML URLs automatically use your public domain.

> **Tip:** always configure applications against the public URL
> (`https://auth.example.com`), not the LAN URL. OIDC issuers and redirect
> URLs must match exactly, and the public URL works from everywhere.

### B. No tunnel — LAN only

Nothing to configure. Use `http://<your-ha-ip>:9000` (or HTTPS on 9443 — see
below). All SSO flows work as long as every app and browser uses the same
hostname/IP for authentik consistently. If you use both an IP and a hostname,
pick one and stick to it: OIDC redirect URIs are exact-match.

### C. Your own reverse proxy (Nginx Proxy Manager, Caddy, Traefik, …)

Point the proxy at `http://<your-ha-ip>:9000` and enable WebSocket support.
The proxy must send `X-Forwarded-Proto` and `X-Forwarded-For` (all the usual
presets do). Nothing else is required; if your proxy is *not* on a private
address, add its IP range to `trusted_proxy_cidrs`.

### D. Direct HTTPS on port 9443

Port 9443 serves TLS with a self-signed certificate by default. To use a real
certificate: drop the cert + key into the addon_config `certs/` folder —
authentik imports them automatically within minutes (or trigger the import
under **System → Certificates**) — then select it as **Web Certificate** in
**System → Brands**. This gives you proper HTTPS with no tunnel and no proxy.

## Using authentik for SSO across your apps

These patterns work the same whether your apps are behind Cloudflare tunnels
on other hosts, behind one shared tunnel, or on the plain LAN — the only rule
is that the browser must be able to reach both the app and authentik.

### Apps with native OIDC support (preferred)

Grafana, Portainer, Immich, Paperless-ngx, Nextcloud, Jellyfin (via plugin),
MeshCentral, and many others support OpenID Connect directly:

1. In authentik: **Applications → Providers → Create → OAuth2/OpenID Provider**.
   Set the redirect URI to the app's callback URL, e.g.
   `https://grafana.example.com/login/generic_oauth`.
2. Create an **Application** linked to that provider; the application "slug"
   determines the issuer URL:
   `https://auth.example.com/application/o/<slug>/`
3. In the app, configure OIDC with that issuer plus the client ID/secret from
   the provider. Scopes are typically `openid profile email`.

### Apps with no built-in authentication

authentik's **Proxy Provider** puts a login wall in front of any app. Since
`cloudflared` cannot do forward-auth itself, run an outpost *in front of* the
app and point the tunnel (or your proxy) at the outpost:

```yaml
# docker-compose.yml on the host that runs the unprotected app
services:
  authentik-proxy:
    image: ghcr.io/goauthentik/proxy:2026.5.5
    restart: unless-stopped
    ports:
      - "9000:9000"
    environment:
      AUTHENTIK_HOST: https://auth.example.com
      AUTHENTIK_TOKEN: <outpost-token-from-authentik>
```

In authentik create a Proxy Provider in **Proxy** mode (external host
`https://app.example.com`, upstream `http://app:port`), assign it to a new
outpost, and copy the outpost token into the compose file. Then point that
app's tunnel hostname at `http://<host>:9000` (the outpost) instead of the app.

If you use Nginx Proxy Manager/Traefik/Caddy instead of tunnels, you can use
the **Forward auth** mode of the same Proxy Provider with the embedded outpost
that already runs inside this add-on — see the authentik forward-auth docs.

### Alternative: authentik as IdP for Cloudflare Access

You can also add authentik as a generic OIDC identity provider in Cloudflare
Zero Trust (**Settings → Authentication → Login methods → Add new → OpenID
Connect**). Then any Access application in front of your tunnel hostnames
authenticates through authentik. This protects apps at the Cloudflare edge
without touching the app hosts at all.

### Home Assistant itself

Home Assistant Core does not support OIDC natively. Options: keep HA's own
login, use a community OIDC integration (e.g. `hass-oidc-auth` via HACS), or
put Cloudflare Access (backed by authentik, see above) in front of your HA
hostname as an extra layer.

## GeoIP (optional)

Download the free MaxMind GeoLite2 databases and drop
`GeoLite2-City.mmdb` (and optionally `GeoLite2-ASN.mmdb`) into the
addon_config `geoip/` folder, then restart the add-on. Login events will then
include location data, and you can use GeoIP policies in flows.

## Backups, restores and moving between machines

**Easiest path — Home Assistant backups.** HA backups cover both the database
(`/data`) and the addon_config folder. Restoring that backup on the same or a
new Home Assistant machine restores authentik completely; nothing else needed.

**Manual migration / disaster recovery** using the addon_config folder
(`/addon_configs/…_authentik`, reachable via Samba/SSH):

1. On the source machine, grab the whole folder. For the freshest possible
   database dump, stop the add-on first (a dump is written on shutdown).
2. On the target machine, install the add-on and start it once so the folder
   structure exists (a brand-new, empty authentik comes up).
3. Copy `media/`, `certs/`, `custom-templates/`, `blueprints/` and `geoip/`
   from the source into the target's addon_config folder.
4. Put the source's `backups/authentik-latest.sql` into the target's
   `restore/` folder **renamed to `authentik.sql`**, and copy the source's
   `backups/secrets.env` into `restore/` as well.
5. Restart the add-on. It replaces its database with the imported dump and
   adopts the imported secret key (watch the log for `RESTORE:` lines), then
   renames the restore files to `*.imported-<timestamp>`.

> **Warning:** anything in `restore/` replaces the add-on's current database
> on the next start. Don't leave files there casually.

The SQL dump is a standard `pg_dump`, so it also works for migrating *away*
from this add-on — e.g. into the official authentik docker-compose stack
(import the dump into its PostgreSQL and set `AUTHENTIK_SECRET_KEY` from
`secrets.env`).

## Updates

Add-on updates ship new authentik versions. authentik migrates its database
automatically on start. **Take a backup before updating** — authentik does
not support downgrades.

## Resource usage

Expect roughly 1 GB of RAM for the full stack. On low-memory machines set
`web_workers: 1`.

## Troubleshooting

- **First start seems stuck** — migrations on first boot can take several
  minutes on slow hardware/SD cards. Check the add-on log.
- **Redirect/CSRF errors when logging in** — make sure you access authentik
  via one consistent hostname; set `cookie_domain` if you use multiple
  subdomains of one parent domain.
- **`Connection refused` from cloudflared/proxy** — confirm the add-on is
  running and the origin uses the HA host IP and port 9000 (not 127.0.0.1 from
  inside the cloudflared container).
- **Wrong client IPs in authentik events** — your proxy isn't in a trusted
  range; add its CIDR to `trusted_proxy_cidrs`.
