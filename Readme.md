# nsupdate.info Docker Image

[![Docker CI](https://github.com/hensing/nsupdate-docker/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/hensing/nsupdate-docker/actions/workflows/docker-publish.yml)
[![Weekly Security Scan](https://github.com/hensing/nsupdate-docker/actions/workflows/security-scan.yml/badge.svg)](https://github.com/hensing/nsupdate-docker/actions/workflows/security-scan.yml)
[![Known Vulnerabilities](https://snyk.io/test/github/hensing/nsupdate-docker/badge.svg)](https://snyk.io/test/github/hensing/nsupdate-docker)
[![GHCR](https://img.shields.io/badge/ghcr.io-hensing%2Fnsupdate--docker-blue?logo=docker)](https://github.com/hensing/nsupdate-docker/pkgs/container/nsupdate-docker)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A hardened, rootless Docker image for [nsupdate.info](https://github.com/nsupdate-info/nsupdate.info), a dynamic DNS service.

The original project was created by [Thomas Waldmann (@ThomasWaldmann)](https://github.com/ThomasWaldmann).
This Docker image is maintained by [Dr. Henning Dickten (@hensing)](https://github.com/hensing).

## Table of Contents

- [Features](#features)
- [Getting Started](#getting-started)
- [Configuration](#configuration)
- [Data Persistence](#data-persistence)
- [Automated Maintenance](#automated-maintenance)
- [Recommendations for Small Installations](#recommendations-for-small-installations)
- [Security Details](#security-details)
- [Vulnerability Scanning](#vulnerability-scanning)
- [Building for Development and Testing](#building-for-development-and-testing)
- [Changelog](#changelog)
- [License](#license)

## Features

-   **Near-zero CVEs**: Built on the [Wolfi](https://github.com/wolfi-dev) base image (Chainguard's container-native distro) with continuous CVE patching, instead of a Debian/Alpine base.
-   **Fully rootless**: Every process — `gunicorn` *and* the scheduler — runs as the non-root user (UID/GID `65532`), with no root phase at all, not even at container startup.
-   **Hardened by default**: `compose.yaml` ships with `cap_drop: ALL`, `no-new-privileges`, a read-only root filesystem, and resource limits.
-   **Reproducible builds**: Multi-stage build with [`uv`](https://github.com/astral-sh/uv); dependencies are pinned at the minor version (floating on bugfix releases); the upstream app is tracked via the `NSUPDATE_REF` build arg.
-   **Production-ready**: Uses `gunicorn` as the WSGI server, with a container `HEALTHCHECK`.
-   **Automated maintenance**: Uses [`supercronic`](https://github.com/aptible/supercronic) — a container-native, non-root cron — for periodic tasks.
-   **Simple configuration**: Configure via a `.env` file and an optional `local_settings.py`.
-   **Persistent storage**: Bind-mounts `./database` for the SQLite database.

## Getting Started

The recommended way to run this service is with Docker Compose (v2).

### 1. Prepare the Configuration

First, create the necessary configuration files.

```bash
# Create the persistent database directory and give it to the container's
# non-root user (UID/GID 65532). This is required because the bind-mount keeps
# the host's ownership, and the rootless container must be able to write the DB.
mkdir -p database
sudo chown -R 65532:65532 database

# Copy the environment variable template
cp .env.example .env

# (Optional) Copy the advanced settings template for customization
cp local_settings.py.default local_settings.py
```

> **Note:** If you override the UID/GID via the `APP_UID`/`APP_GID` build args,
> `chown` the `database` directory to the same values.

### 2. Edit `.env`

Open the `.env` file and set **at least** the following variables:

-   `SECRET_KEY`: **Required** — a long, random string. There is no insecure fallback; the app refuses to start without it.
-   `DJANGO_SUPERUSER_PASSWORD`: A secure password for the admin account (only needed on first run — see below).
-   `GUNICORN_FORWARDED_ALLOW_IPS`: Set to your reverse-proxy network CIDR, **not** `*` (see [Reverse Proxy Configuration](#reverse-proxy-configuration)).

You can generate a secure `SECRET_KEY` with:
```bash
python -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'
```

> **Security tip:** `DJANGO_SUPERUSER_PASSWORD` is only used to create the admin
> account on the very first start. Remove it from `.env` afterwards so it no
> longer lingers in the container environment.

### 3. Start the Service

Use the provided `compose.yaml` to build and start the service.

```bash
docker compose up --build -d
```

The service listens on port `8000` inside the `proxy` Docker network (not published to the host). Run it behind a reverse proxy such as Traefik, Caddy, or Nginx that terminates TLS and forwards to `nsupdate:8000`.

## Configuration

### Environment Variables (`.env` file)

The container is configured primarily through an `.env` file. See [`.env.example`](.env.example) for all available options.

| Variable                    | Description                                                                                              | Default                                    |
| --------------------------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| `SECRET_KEY`                | **Required.** Django's secret key for cryptographic signing. No fallback — the app will not start without it. | _(none)_                              |
| `DJANGO_SUPERUSER_USERNAME` | The username for the administrative superuser.                                                           | `admin`                                    |
| `DJANGO_SUPERUSER_EMAIL`    | The email address for the superuser.                                                                     | `admin@localhost.localdomain`              |
| `DJANGO_SUPERUSER_PASSWORD` | **Required on first run only.** The password for the superuser. Remove afterwards.                       | _(none)_                                   |
| `DATABASE_URL`              | Optional. The database connection string for external databases like PostgreSQL.                         | `sqlite:////app/database/nsupdate.sqlite`  |
| `GUNICORN_FORWARDED_ALLOW_IPS` | **Recommended.** Trusted sources for `X-Forwarded-*`. Do **not** use `*` (enables IP spoofing).       | `127.0.0.1`                                |

### Build Arguments

Set these under `build.args` in `compose.yaml` (or via `--build-arg` on the CLI) if you need to customize the image itself.

| Build Arg       | Description                                                                                  | Default  |
| --------------- | ---------------------------------------------------------------------------------------------- | -------- |
| `BUILD_TARGET`  | `prod` or `test` (installs dev/test dependencies too). See [Building for Development and Testing](#building-for-development-and-testing). | `prod`   |
| `NSUPDATE_REF`  | The upstream `nsupdate.info` git ref (branch, tag, or commit SHA) to build. Defaults to `master`, since upstream's tagged releases are infrequent and lag behind master. Pin to a commit SHA for a fully reproducible build. | `master` |
| `PYTHON_VERSION` | Python version to install from Wolfi.                                                          | `3.14`   |
| `APP_UID` / `APP_GID` | UID/GID the container runs as. Match this with the ownership of your `database` bind mount. | `65532`  |

### Reverse Proxy Configuration

When running behind a reverse proxy (like Traefik or Nginx), you should restrict `GUNICORN_FORWARDED_ALLOW_IPS` to the IP address range of your proxy network for security.

You can find the correct IP range for your proxy's Docker network with the following command (replace `proxy` with the actual name of your network if different):

```bash
docker network inspect proxy --format '{{(index .IPAM.Config 0).Subnet}}'
```

Set the resulting subnet (e.g., `172.18.0.0/16`) in your `.env` file:

```env
GUNICORN_FORWARDED_ALLOW_IPS="172.18.0.0/16"
```

### Advanced Configuration (`local_settings.py`)

For advanced customization (e.g., setting up email, social authentication, or changing `ALLOWED_HOSTS`), you can create and mount a `local_settings.py` file. The provided `compose.yaml` does this automatically if the file exists.

## Data Persistence

The container bind-mounts `./database` to `/app/database` to store the SQLite database. This ensures that your data is safe across container restarts and upgrades. Because the container is rootless, this directory must be owned by UID/GID `65532` on the host (see [Getting Started](#1-prepare-the-configuration)).

## Automated Maintenance

The image runs [`supercronic`](https://github.com/aptible/supercronic) — a container-native cron that runs as the **non-root** user — to execute essential Django management commands (session cleanup, fault counters, nameserver checks, etc.). The jobs are defined in [`nsupdate-crontab`](nsupdate-crontab).

## Recommendations for Small Installations

This image is tuned for small, self-hosted setups (roughly 1–2 concurrent users):

-   **Workers**: The default is `--workers=2 --preload` — plenty for a handful of users, with copy-on-write memory sharing. For the lowest possible RAM footprint, override the command to `--workers=1 --threads=4`.
-   **Database**: The default **SQLite** is entirely sufficient. You only need `DATABASE_URL` (PostgreSQL) for larger, high-concurrency deployments.
-   **Memory**: The provided `compose.yaml` sets `mem_limit: 384m` and `pids_limit: 200` as safe, lean defaults. You can try `256m` if you want it tighter.
-   **Security first**: The hardening in `compose.yaml` (see [Security Details](#security-details)) is already suitable for small setups — no tuning required.
-   **Upkeep**: The Wolfi base has near-zero CVEs and is rebuilt weekly, so you stay patched with minimal effort.

## Security Details

-   **Wolfi base**: Near-zero CVEs, continuously patched; the final image contains only the necessary runtime dependencies.
-   **Fully rootless**: All processes (`gunicorn` and `supercronic`) run as UID/GID `65532`. There is **no root startup phase** — migrations, superuser creation, and scheduling all run unprivileged. File ownership is baked in at build time, so no runtime `chown` is needed.
-   **Container hardening** (in `compose.yaml`): `cap_drop: ALL`, `security_opt: no-new-privileges`, a `read_only: true` root filesystem (with a `tmpfs` for `/tmp`), and `pids_limit`/`mem_limit`.
-   **No injection surface**: The superuser is created via Django's native `createsuperuser --noinput` reading credentials from the environment, so special characters in the password cannot break out into shell/Python.
-   **Pinned, minor-tracked dependencies**: `gunicorn`, `whitenoise`, and `django-xff` are pinned at the minor version (e.g. `~=26.0.0`) — bugfix releases are picked up automatically, minor/major upgrades require a deliberate change.

### Binding Privileged Ports Without Root

`gunicorn` listens on the high port `8000`, so no extra privilege is needed. If you ever want to bind a port below 1024 directly (without root), add **one** of the following to the `nsupdate` service in `compose.yaml`:

```yaml
    cap_add: ["NET_BIND_SERVICE"]
    # or:
    sysctls: ["net.ipv4.ip_unprivileged_port_start=80"]
```

## Vulnerability Scanning

This project is continuously monitored for security vulnerabilities using [Anchore grype](https://github.com/anchore/grype).

-   **CI/CD Scans**: Every push to the `main` branch is automatically scanned. `High` and `Critical` findings are reported to the [Security tab](https://github.com/hensing/nsupdate-docker/security/code-scanning); the build fails only on `Critical`. (A transient `High` in the Wolfi base is typically picked up automatically by the weekly rebuild once an upstream patch lands.)
-   **Weekly Scans**: The `latest` Docker image is re-scanned weekly to catch newly disclosed vulnerabilities in existing dependencies, and automatically triggers a rebuild if any are found.

### Vulnerability Disclosure

If you discover a security vulnerability, please report it privately via [GitHub Security Advisories](https://github.com/hensing/nsupdate-docker/security/advisories/new) rather than opening a public issue.

## Building for Development and Testing

To build an image that includes development dependencies (like `pytest`), set the `BUILD_TARGET` build argument to `test`.

### With Docker Compose

You can create a `compose.override.yaml` file to easily switch to a test build:

```yaml
# compose.override.yaml
services:
  nsupdate:
    build:
      args:
        - BUILD_TARGET=test
```

Then, build and run with `docker compose up --build`.

### With Docker CLI

```bash
docker build --build-arg BUILD_TARGET=test -t nsupdate-test .
```

This is used by the CI/CD pipeline to run the Django test suite.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a history of notable changes to this image.

## License

This project is licensed under the [MIT License](LICENSE).
