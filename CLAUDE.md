# CLAUDE.md

Guidance for Claude Code (and future maintainers) working in this repository.

## What this repo is

A Docker packaging project for [nsupdate.info](https://github.com/nsupdate-info/nsupdate.info),
a dynamic DNS service. **This repo owns the Dockerfile, compose file, entrypoint,
and CI workflows — nsupdate.info upstream does not ship any of these.** There is
no official Docker image or rootless guidance upstream to sync with; this
packaging is fully independent.

## Priorities (in order)

1. **Security first.** When a choice trades off security against convenience or
   performance, prefer the more secure option.
2. **Low RAM footprint second.** This is a small, self-hosted deployment
   (typically 1-2 concurrent users) — not a high-throughput service. Do not
   over-provision workers, threads, or memory limits for concurrency that
   doesn't exist here.

## Key architectural decisions

### Base image: Wolfi, not Debian slim

The image is built on `cgr.dev/chainguard/wolfi-base` rather than
`python:*-slim`. Wolfi carries near-zero CVEs and is patched continuously,
whereas Debian-based images (including "distroless") accumulate distro-package
CVEs that sit for weeks before a point release. This eliminated the recurring
"critical vulnerability" CI failures the Debian-based image used to produce,
and made the earlier Go-stdlib-CVE workaround (purging Debian's Go packages)
obsolete — it has been removed.

Multi-stage build: a full Wolfi builder stage (git, build-base, uv) produces a
self-contained venv at `/app/.venv`, which is copied into a minimal runtime
stage that only has what's needed to run the app (python, bash, libpq,
supercronic).

### Fully rootless at runtime

Every process — gunicorn *and* the scheduler — runs as the non-root user
`65532` (Chainguard's "nonroot" convention). There is **no root phase at all**,
not even at container startup:

- File ownership (`/app`, `/app/database`, `/app/static`) is baked in at
  **build time**, so no runtime `chown` is needed.
- The old root `cron` daemon was replaced with
  [`supercronic`](https://github.com/aptible/supercronic), which runs the same
  job schedule (`nsupdate-crontab`) as the non-root user.
- The entrypoint (`docker-entrypoint.sh`) has no `id -u == 0` branch, no
  `setpriv`/privilege-drop step — it never runs as root in the first place.

This is why `docker top` on this container shows no uid-0 processes, and why
host-level "is this container running as root" scanners are satisfied without
needing user-namespace remapping.

### Dependency management: `uv`, minor-pinned extras

Application dependencies are installed with [`uv`](https://github.com/astral-sh/uv)
into a dedicated venv for fast, reproducible builds. The three extras this repo
adds on top of upstream (`gunicorn`, `whitenoise`, `django-xff`) live in
`requirements/extras.txt` and are pinned **at the minor version, floating on
bugfix/patch**, e.g. `gunicorn~=26.0.0`. This means `26.0.1`, `26.0.2`, ... are
picked up automatically (so patch-level security fixes land without a change),
while `26.1.0` or `27.0.0` require a deliberate, reviewed pin bump.

The pins live in `requirements/*.txt` rather than inline in the Dockerfile so
that Dependabot (pip ecosystem, `versioning-strategy: increase-if-necessary`)
can see them: it opens a PR only when a release falls outside the pin, i.e. a
new minor/major of an extra or a new `nsupdate` release.

The Wolfi base image is intentionally **not** pinned to a digest, so
Dependabot's `docker` entry has nothing to propose for it. Pinning would stop
the weekly rebuild (and the rebuild triggered by the security scan) from
picking up base-image fixes until someone merges a PR.

### Two image variants: `stable` (PyPI release) and `dev` (upstream master)

The `NSUPDATE_SOURCE` build arg selects where the application comes from, and
CI publishes one image per value:

- `pypi` → tags `stable`, `latest` and the release version (e.g. `0.13.0`).
  Installs the `nsupdate` release pinned in `requirements/stable.txt`; CI
  reads the version tag from that same pin, so tag and content always match.
  A new upstream release reaches `stable` by merging Dependabot's PR for that
  file. `psycopg2` and `argon2-cffi` are listed there too because upstream
  names them only in `requirements.d/`, not in the package metadata.
  `/app/src` then contains only `local_settings.py`; the app lives in the
  venv's site-packages.
- `git` → tags `dev`, `main` and `dev-<upstream short sha>`. CI resolves
  upstream `master` to a commit and passes it as `NSUPDATE_REF` (the Dockerfile
  default is `master`). This is the Dockerfile default source and the only
  variant that supports `BUILD_TARGET=test` (the upstream test suite needs the
  source tree).

Version tags are plain `major.minor.patch` so that Renovate users can track
them; all tags are rebuilt weekly, so consumers who want immutability pin the
digest (documented in the Readme's "Image Tags" section).

`latest` deliberately points at `stable`: the maintainer asked for more stable
builds (2026-11). The trade-off is known: nsupdate.info cuts releases rarely
and they lag behind master (`0.13.0` was ~60 commits behind as of 2026-11), so
a fix that only exists on master needs the `dev` image. Both variants are
rebuilt weekly, so base-image and dependency patches land in `stable` too.

### Cron jobs: upstream's list, minus `testuser`

`nsupdate-crontab` mirrors the "Regular jobs" section of upstream's
`docs/admin.rst`. The `testuser` job is commented out on purpose: it recreates
an account `test` / password `test` nightly (meant for upstream's public demo).
Do not re-enable it. Upstream's `--stale-check` commands (hosts/users/domains)
delete data and are not in upstream's recommended crontab either; `illegal` is
interactive and cannot run from cron.

### Scheduler: supercronic, not cron

`supercronic` was chosen over `cron`/`busybox crond` specifically because it
runs as a normal (non-root) process and reads a plain crontab file
(`nsupdate-crontab`) with no per-line user column — it doesn't require the
`/etc/cron.d` root-owned-file model that traditional cron needs.

### Data persistence: bind mount, not a named volume

`./database` is bind-mounted into the container (not a named Docker volume).
This keeps the SQLite database directly accessible on the host for backups,
but means the **host directory must be owned by uid/gid `65532`** before first
start (`chown -R 65532:65532 ./database`) — a bind mount keeps host ownership,
and the rootless container needs write access to it.

### CI vulnerability gating: report `high`, fail on `critical`

The grype scans (`docker-publish.yml`, `security-scan.yml`) report `high` and
`critical` findings to the GitHub Security tab, but only **fail the build** on
`critical`. This was a deliberate adjustment after observing that even Wolfi
occasionally carries a transient `high` in a fast-moving base package (e.g. the
Python interpreter itself) for which no fix is available yet — failing on
`high` would block every push for something not actionable. The weekly
scheduled rebuild picks up the fix automatically once Wolfi publishes it.

### Container hardening in `compose.yaml`

`cap_drop: ALL`, `security_opt: no-new-privileges:true`, `read_only: true` root
filesystem (with a `tmpfs` for `/tmp`), `pids_limit`, and a small `mem_limit`
are all applied by default — they are cheap to satisfy given the rootless,
Wolfi-based image and are appropriate even for small installations.

To bind a privileged port (<1024) without root, use **either**
`cap_add: ["NET_BIND_SERVICE"]` **or**
`sysctls: ["net.ipv4.ip_unprivileged_port_start=80"]` — not currently needed
since gunicorn binds the high port 8000.

## Out of scope

Other containers on the same host (postfix, netbird-*, caddy, cadvisor,
zitadel-db, dockge, etc.) are unrelated third-party images and are not part of
this repository.
