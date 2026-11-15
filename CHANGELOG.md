# Changelog

## Unreleased

### Images

- **Two image variants are now published.** `stable` is built from the latest
  nsupdate release on PyPI and is also tagged with that release version (e.g.
  `0.13.0`); `dev` is built from upstream GitHub `master`, as the only image
  was before, and is also tagged `dev-<upstream short sha>`.
- **`latest` is unchanged**: it remains the upstream-`master` build and is now
  the same image as `dev` (`main` is a further alias). Nothing changes for
  existing deployments; opt in to released code by switching to `stable` or a
  version tag.
- New build arg `NSUPDATE_SOURCE` (`git` | `pypi`, default `git`).
- The stable release is pinned in `requirements/stable.txt` and the extras
  (`gunicorn`, `whitenoise`, `django-xff`) moved from the Dockerfile to
  `requirements/extras.txt`. Dependabot now watches both files: it opens a PR
  for a new nsupdate release and for new minor/major versions of the extras.
- Images carry the `org.opencontainers.image.version` label (`<version>` or
  `dev-<sha>`). The Readme documents all tags and how to pin them by digest
  with Renovate.
- CI smoke-tests each variant (container must become healthy) before pushing,
  and the weekly security scan covers both `stable` and `dev`.

### Fixed

- **CI was red since 2026-08-16, so no image had been published since
  2026-08-09** (and GitHub then disabled the scheduled workflows for
  inactivity). The cause was an upstream test (`test_ddns_client.py`) that
  talks to the live public nsupdate.info service; it is now skipped, as in
  upstream's own tox configuration.
- Removed the nightly `cleanoldsessions` cron job. That command exists neither
  in Django nor in nsupdate.info, so the job failed every night. Expired
  sessions are already removed by the existing `clearsessions` job.

### Security

- **Disabled the nightly `testuser` cron job.** It (re)created an account
  `test` with the password `test` every night -- intended for upstream's public
  demo service, but a publicly known login on a private installation. If your
  database already contains that account, delete the `test` user once via the
  Django admin.

### Performance

- **Lowered the default gunicorn worker count from 2 to 1** (dropping
  `--preload`, which only benefits multi-worker copy-on-write sharing), and
  tightened `compose.yaml`'s `mem_limit` from `384m` to `256m` accordingly.
  Real-world `docker stats` measurements at the target scale (max 2
  simultaneous users) showed a second worker process wasn't earning its RAM;
  a single sync worker serializes requests, which is imperceptible at this
  scale. Override the command with `--workers=2 --preload` if you need more
  concurrency headroom.

### CI

- Bumped GitHub Actions pins to their latest majors (`actions/checkout@v7`,
  `actions/upload-artifact@v7`, `docker/login-action@v4`,
  `docker/metadata-action@v6`, `docker/build-push-action@v7`,
  `anchore/scan-action@v7`, `github/codeql-action/upload-sarif@v4`). All of
  these now run natively on Node 24, so the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`
  workaround is no longer needed and has been removed.

## 2026.07.01

### Security

- **Fully rootless container**: every process (gunicorn *and* the scheduler) now
  runs as the non-root user `65532`, with no root startup phase at all. Migrations,
  superuser creation, and job scheduling all run unprivileged; file ownership is
  baked in at build time so no runtime `chown` is required.
- **Rebased onto Wolfi**: the base image moved from `python:3.14-slim-trixie`
  (Debian) to `cgr.dev/chainguard/wolfi-base`, which carries near-zero CVEs and
  is patched continuously. The Go-stdlib CVE workaround (purging Debian's Go
  packages) is no longer needed and has been removed.
- **Removed an unsafe `SECRET_KEY` fallback**: `local_settings.py.default`
  previously defaulted to the publicly-known string `S3CR3T` if `SECRET_KEY` was
  unset. The app now refuses to start without an explicit `SECRET_KEY`.
  **This is a breaking change** — set `SECRET_KEY` in `.env` before upgrading.
- **Fixed a command/shell injection vector** in the entrypoint's superuser
  creation: credentials were previously interpolated as unquoted strings into a
  Python heredoc. Superuser creation now uses Django's native, environment-based
  `createsuperuser --noinput`, which cannot be broken by special characters in
  the password.
- **Hardened default reverse-proxy trust**: `GUNICORN_FORWARDED_ALLOW_IPS`
  no longer defaults to `*` (which allowed any client to spoof its IP via
  `X-Forwarded-For`); the example now uses a documented proxy-network CIDR.
- Added secure-cookie / TLS-proxy settings (`SECURE_PROXY_SSL_HEADER`,
  `SESSION_COOKIE_SECURE`, `CSRF_COOKIE_SECURE`) to `local_settings.py.default`.
- Hardened `compose.yaml`: `cap_drop: ALL`, `security_opt: no-new-privileges`,
  `read_only` root filesystem with a `tmpfs` for `/tmp`, `pids_limit`, `mem_limit`,
  and a read-only mount for `local_settings.py`.
- CI: the weekly/publish grype scans now report `high`-and-above findings to the
  Security tab (previously `critical`-only), while still failing the build only
  on `critical` — a deliberate compromise so a transient `high` CVE in a
  fast-moving Wolfi base package (with no fix yet available) doesn't block every
  push; the weekly rebuild still picks up the fix automatically once published.

### Changed

- Dependency management switched from `pip` to [`uv`](https://github.com/astral-sh/uv)
  with a dedicated virtualenv (`/app/.venv`), for faster, more reproducible builds.
- Scheduling switched from root `cron` (`/etc/cron.d`) to
  [`supercronic`](https://github.com/aptible/supercronic), which runs as the
  non-root application user. `nsupdate-cron` was renamed to `nsupdate-crontab`
  (supercronic's format has no per-line user column).
- The upstream `nsupdate.info` source is now cloned via a pinnable
  `NSUPDATE_REF` build arg (defaults to `master`, since upstream's tagged
  releases are infrequent and lag well behind `master`).
- Pinned `gunicorn`, `whitenoise`, and `django-xff` at the minor version
  (`~=26.0.0`, `~=6.12.0`, `~=1.5.0`) — patch/bugfix releases are picked up
  automatically, while minor/major upgrades remain a deliberate, reviewed change.
- Reduced gunicorn to `--workers=2 --preload` with `--max-requests` worker
  recycling, tuned for small installations (1-2 concurrent users) to minimize
  RAM usage.
- Added a container `HEALTHCHECK`.
- Removed the old `grype-results*.sarif` files that had been committed to the
  repository (they are build artifacts and are `.gitignore`d).

### Documentation

- `Readme.md`: documented the rootless setup (including the required
  `chown 65532:65532 ./database` step), secrets handling, and added a
  "Recommendations for small installations" section.
