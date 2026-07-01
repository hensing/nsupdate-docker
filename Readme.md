# nsupdate.info Docker Image

This repository provides a secure, production-ready Docker image for [nsupdate.info](https://github.com/nsupdate-info/nsupdate.info), a dynamic DNS service.

The original project was created by [Thomas Waldmann (@ThomasWaldmann)](https://github.com/ThomasWaldmann).
This Docker image is maintained by [Dr. Henning Dickten (@hensing)](https://github.com/hensing).

## Features

-   **Near-zero CVEs**: Built on the [Wolfi](https://github.com/wolfi-dev) base image (Chainguard's container-native distro) with continuous CVE patching.
-   **Fully rootless**: Every process — `gunicorn` *and* the scheduler — runs as the non-root user (UID/GID `65532`). No process runs as root, not even at startup.
-   **Hardened**: Ships a `compose.yaml` with `cap_drop: ALL`, `no-new-privileges`, a read-only root filesystem, and resource limits.
-   **Reproducible builds**: Multi-stage build with [`uv`](https://github.com/astral-sh/uv); the upstream app is pinned via the `NSUPDATE_REF` build arg.
-   **Production-Ready**: Uses `gunicorn` as the WSGI server, with a `HEALTHCHECK`.
-   **Automated Maintenance**: Uses [`supercronic`](https://github.com/aptible/supercronic) (a container-native, non-root cron) for periodic tasks.
-   **Simple Configuration**: Configure via a `.env` file and an optional `local_settings.py`.
-   **Persistent Storage**: Bind-mounts `./database` for the SQLite database.

## Getting Started

The recommended way to run this service is with Docker Compose.

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

The service will be available on port 8000. It is recommended to run it behind a reverse proxy like Traefik or Nginx in a production environment.

## Configuration

### Environment Variables (`.env` file)

The container is configured primarily through an `.env` file. See `.env.example` for all available options.

| Variable                    | Description                                                                                              | Default                                    |
| --------------------------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| `SECRET_KEY`                | **Required.** Django's secret key for cryptographic signing. No fallback — the app will not start without it. | _(none)_                              |
| `DJANGO_SUPERUSER_USERNAME` | The username for the administrative superuser.                                                           | `admin`                                    |
| `DJANGO_SUPERUSER_EMAIL`    | The email address for the superuser.                                                                     | `admin@localhost.localdomain`              |
| `DJANGO_SUPERUSER_PASSWORD` | **Required on first run only.** The password for the superuser. Remove afterwards.                       | _(none)_                                   |
| `DATABASE_URL`              | Optional. The database connection string for external databases like PostgreSQL.                         | `sqlite:////app/database/nsupdate.sqlite`  |
| `GUNICORN_FORWARDED_ALLOW_IPS` | **Recommended.** Trusted sources for `X-Forwarded-*`. Do **not** use `*` (enables IP spoofing).       | `127.0.0.1`                                |

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

## Recommendations for small installations

This image is tuned for small, self-hosted setups (roughly 1–2 concurrent users):

-   **Workers**: The default is `--workers=2 --preload` — plenty for a handful of users, with copy-on-write memory sharing. For the lowest possible RAM footprint, override the command to `--workers=1 --threads=4`.
-   **Database**: The default **SQLite** is entirely sufficient. You only need `DATABASE_URL` (PostgreSQL) for larger, high-concurrency deployments.
-   **Memory**: The provided `compose.yaml` sets `mem_limit: 384m` and `pids_limit: 200` as safe, lean defaults. You can try `256m` if you want it tighter.
-   **Security first**: The hardening block below is already suitable for small setups — no tuning required.
-   **Upkeep**: The Wolfi base has near-zero CVEs and is rebuilt weekly, so you stay patched with minimal effort.

## Security Details

-   **Wolfi base**: Near-zero CVEs, continuously patched; the final image contains only the necessary runtime dependencies.
-   **Fully rootless**: All processes (gunicorn and supercronic) run as UID/GID `65532`. Unlike earlier versions, there is **no root startup phase** — migrations, superuser creation and scheduling all run unprivileged. File ownership is baked at build time, so no runtime `chown` is needed.
-   **Container hardening** (in `compose.yaml`): `cap_drop: ALL`, `security_opt: no-new-privileges`, `read_only: true` root filesystem (with a `tmpfs` for `/tmp`), and `pids_limit`/`mem_limit`.
-   **No injection surface**: The superuser is created via Django's native `createsuperuser --noinput` reading credentials from the environment, so special characters in the password cannot break out into shell/Python.

### Binding privileged ports without root

`gunicorn` listens on the high port `8000`, so no extra privilege is needed. If you ever want to bind a port below 1024 directly (without root), add **one** of the following to the `nsupdate` service in `compose.yaml`:

```yaml
    cap_add: ["NET_BIND_SERVICE"]
    # or:
    sysctls: ["net.ipv4.ip_unprivileged_port_start=80"]
```

## Vulnerability Scanning

[![Known Vulnerabilities](https://snyk.io/test/github/hensing/nsupdate-docker/badge.svg)](https://snyk.io/test/github/hensing/nsupdate-docker)

This project is continuously monitored for security vulnerabilities.

-   **CI/CD Scans**: Every push to the `main` branch is automatically scanned. `High` and `Critical` findings are reported to the Security tab; the build fails on `Critical`. (High findings in the Wolfi base are typically transient and picked up automatically by the weekly rebuild once upstream patches land.)
-   **Weekly Scans**: The `latest` Docker image is scanned weekly to detect newly disclosed vulnerabilities in existing dependencies. Results are available in the [Security tab](https://github.com/hensing/nsupdate-docker/security/code-scanning).

### Vulnerability Disclosure

If you discover a security vulnerability, please report it privately. Do not create a public GitHub issue. Contact information can be found in the `SECURITY.md` file.

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

## License

This project is licensed under the [MIT License](LICENSE).
