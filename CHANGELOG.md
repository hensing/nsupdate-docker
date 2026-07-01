# Changelog

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
