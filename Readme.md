# nsupdate.info Docker Image

This repository provides a secure, production-ready Docker image for [nsupdate.info](https://github.com/nsupdate-info/nsupdate.info), a dynamic DNS service.

The original project was created by [Thomas Waldmann (@ThomasWaldmann)](https://github.com/ThomasWaldmann).
This Docker image is maintained by [Dr. Henning Dickten (@hensing)](https://github.com/hensing).

## Features

-   **Secure by Design**: Uses a multi-stage build to create a minimal final image without build tools.
-   **Unprivileged Execution**: The application runs as the non-root `www-data` user.
-   **Production-Ready**: Uses `gunicorn` as the WSGI server.
-   **Automated Maintenance**: Includes a cron daemon for running periodic maintenance tasks.
-   **Simple Configuration**: Configure via a `.env` file and an optional `local_settings.py`.
-   **Persistent Storage**: Uses a named volume for the database to ensure data persistence.

## Getting Started

The recommended way to run this service is with Docker Compose.

### 1. Prepare the Configuration

First, create the necessary configuration files.

```bash
# Create a directory for the persistent database
mkdir -p database

# Copy the environment variable template
cp .env.example .env

# (Optional) Copy the advanced settings template for customization
cp local_settings.py.default local_settings.py
```

### 2. Edit `.env`

Open the `.env` file and set **at least** the following variables:

-   `SECRET_KEY`: A long, random string for security.
-   `DJANGO_SUPERUSER_PASSWORD`: A secure password for the admin account.

You can generate a secure `SECRET_KEY` with:
```bash
python -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'
```

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
| `SECRET_KEY`                | **Required.** Django's secret key for cryptographic signing.                                             | `""`                                       |
| `DJANGO_SUPERUSER_USERNAME` | The username for the administrative superuser.                                                           | `admin`                                    |
| `DJANGO_SUPERUSER_EMAIL`    | The email address for the superuser.                                                                     | `admin@localhost.localdomain`              |
| `DJANGO_SUPERUSER_PASSWORD` | **Required on first run.** The password for the superuser.                                               | `""`                                       |
| `DATABASE_URL`              | Optional. The database connection string for external databases like PostgreSQL.                         | `sqlite:////app/database/nsupdate.sqlite`  |
| `GUNICORN_FORWARDED_ALLOW_IPS` | Optional. A comma-separated list of trusted proxy IP addresses. Defaults to `*`.                         | `*`                                        |

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

The container uses a volume mounted at `/app/database` to store the SQLite database. This ensures that your data is safe across container restarts and upgrades.

## Automated Maintenance

The image includes a cron service that automatically runs essential Django management commands. The jobs are defined in `nsupdate-cron` and run as the `www-data` user.

## Security

-   **Multi-Stage Build**: The final image contains only the necessary runtime dependencies, minimizing the attack surface.
-   **Non-Root User**: The main application process runs as the unprivileged `www-data` user (UID/GID 33).
-   **Privilege Separation**: The entrypoint script performs initial setup (like database migrations) as `root` before dropping privileges to `www-data` to start the application.

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
