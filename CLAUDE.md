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
adds on top of upstream's `requirements.d/prod.txt` (`gunicorn`, `whitenoise`,
`django-xff`) are pinned **at the minor version, floating on bugfix/patch**,
e.g. `gunicorn~=26.0.0`. This means `26.0.1`, `26.0.2`, ... are picked up
automatically (so patch-level security fixes land without a Dockerfile change),
while `26.1.0` or `27.0.0` require a deliberate, reviewed pin bump.

### Upstream nsupdate.info ref: tracks `master`, not a release tag

The `NSUPDATE_REF` build arg defaults to `master`, **not** a tagged release.
This is deliberate: nsupdate.info cuts tagged releases rarely and they lag
significantly behind master (as of writing, the latest tag `0.13.0` was ~60
commits and several real bugfixes behind `master`). Tracking master is the
better security/correctness trade-off for this particular upstream. Override
`NSUPDATE_REF` with a specific commit SHA if you need a fully pinned,
reproducible build instead.

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
