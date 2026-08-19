# Home Assistant Add-on: authentik

[![Add repository to my Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fddcash%2Fha-authentik-addon)

Run [authentik](https://goauthentik.io) — a self-hosted identity provider —
as a Home Assistant add-on, and get single sign-on (SSO) via OIDC, SAML, LDAP
or proxy auth for every app you host.

The complete stack (authentik server, worker, PostgreSQL, Redis) runs in a
single container. All state lives in the add-on data volume, so it is covered
by Home Assistant backups and survives updates. Designed to sit behind a
Cloudflare tunnel and to integrate with apps that are themselves behind
Cloudflare tunnels on other hosts.

## Add-ons

| Add-on | Description |
| --- | --- |
| [authentik](./authentik) | Identity provider / SSO (authentik 2026.8.0) |

## Installation

### From this repository

1. Click the badge above, or go to **Settings → Add-ons → Add-on store →
   ⋮ → Repositories** and add `https://github.com/ddcash/ha-authentik-addon`.
2. Find **authentik** in the store and install it. The image is built on your
   machine on install; expect it to take a few minutes.
3. Read the add-on **Documentation** tab for first-start, Cloudflare tunnel and
   SSO setup.

### As a local add-on (for development)

See [DEVELOPMENT.md](DEVELOPMENT.md).

## License

MIT — see [LICENSE](LICENSE). authentik itself is licensed separately by its
authors.
