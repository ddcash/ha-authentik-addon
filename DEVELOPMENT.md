# Development

## Testing as a local add-on

1. Enable the **Samba** or **SSH** add-on on your Home Assistant machine so you
   can reach the `/addons` share.
2. Copy the `authentik/` folder of this repo to `/addons/authentik` on the HA
   machine (the folder must contain `config.yaml` at its top level):

   ```
   /addons/authentik/config.yaml
   /addons/authentik/Dockerfile
   /addons/authentik/build.yaml
   /addons/authentik/run.sh
   ...
   ```

3. In Home Assistant: **Settings → Add-ons → Add-on store → ⋮ → Check for
   updates** (or reload the page). The add-on appears under **Local add-ons**.
4. Install. The Supervisor builds the image locally from the Dockerfile — the
   first build downloads the ~1 GB authentik base image.
5. Iterate: after changing files, bump `version` in `config.yaml`, copy the
   folder again, and the add-on offers an update (or uninstall/reinstall).

Tip for fast iteration on `run.sh` only: it is copied into the image, so any
change requires a rebuild. Keep changes batched.

## Testing from your GitHub repo

Push to GitHub, then add the repo URL in the add-on store (⋮ → Repositories).
Repository installs also build the image on the HA machine because this add-on
intentionally ships no prebuilt `image:` — that keeps local and repo installs
identical.

### Optional: prebuilt images

To skip on-device builds, publish images with the
[home-assistant/builder](https://github.com/home-assistant/builder) action and
add to `authentik/config.yaml`:

```yaml
image: ghcr.io/ddcash/authentik-addon-{arch}
```

Then every release must have a matching pushed image tag (`:2026.5.4` etc.)
before users can install/update.

## Updating the authentik version

**This is automated.** The
[update-authentik workflow](.github/workflows/update-authentik.yaml) checks
authentik's official version endpoint (`version.goauthentik.io`) every day.
When a new stable release appears it:

1. verifies `ghcr.io/goauthentik/server` and `ghcr.io/goauthentik/proxy`
   images exist for that version on amd64 + arm64,
2. rewrites the pinned version in `config.yaml` (add-on version = authentik
   version), `build.yaml`, `Dockerfile`, `DOCS.md` and `README.md`,
3. prepends a `CHANGELOG.md` entry linking the official release notes,
4. lints the updated add-on, and
5. commits and pushes to `main`.

Installed add-ons then show the update in the Home Assistant UI. Trigger a
check manually via **Actions → Update authentik version → Run workflow**.

Notes:

- The add-on version always equals the bundled authentik version, so the two
  stay in sync by construction. Add-on-only fixes between authentik releases
  append a fourth number (e.g. `2026.5.4.1`); the workflow reads the real
  authentik pin from `build.yaml`, so hotfix suffixes don't confuse it and the
  next upstream release replaces them normally.
- If you enable branch protection on `main`, allow the built-in
  `GITHUB_TOKEN` to push (or convert the workflow's last step to open a PR).
- authentik migrates its database forward automatically but does not support
  downgrades — remind users (and yourself) to back up before updating.

Manual fallback: change the tag in `authentik/build.yaml` (both arches) and
the default `BUILD_FROM` in `authentik/Dockerfile`, set the matching `version`
in `authentik/config.yaml`, and add a `CHANGELOG.md` entry.

## Add-on structure notes

- Base image is the official `ghcr.io/goauthentik/server` image; the Dockerfile
  adds PostgreSQL, Redis, `jq` and `openssl` on top.
- `run.sh` replaces the image entrypoint: it prepares storage, starts
  PostgreSQL and Redis, exports the `AUTHENTIK_*` environment, then runs the
  authentik worker and server. If any process dies the script exits, and the
  Supervisor watchdog restarts the add-on.
- Storage is split: `/data` holds the PostgreSQL cluster and generated secrets
  (machine-managed), while `/config` (the `addon_config` mapping, visible on
  the host at `/addon_configs/<slug>_authentik`) holds everything a user might
  edit or back up by hand — media, certs, custom templates, blueprints, GeoIP
  databases, SQL dumps and the `authentik.env` override file. authentik's fixed
  container paths (`/media`, `/certs`, `/templates`, `/blueprints/custom`) are
  symlinked into `/config`.
- `dump-db.sh` is wired to `backup_pre` in `config.yaml`: the Supervisor runs
  it before each backup so a consistent SQL dump lands in `/config/backups`.
- Secrets (`AUTHENTIK_SECRET_KEY`, DB password) are generated on first start
  and persisted in `/data`. Deleting them logs everyone out / breaks stored
  credentials, so they are excluded from the options UI on purpose.
