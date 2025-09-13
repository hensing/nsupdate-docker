# nsupdate.info Docker Image

This repository provides a Docker image for [nsupdate.info](https://github.com/nsupdate-info/nsupdate.info), a dynamic DNS service.

<<<<<<< HEAD
The original project was created by [Thomas Waldmann (@ThomasWaldmann)](https://github.com/ThomasWaldmann). This Docker image is maintained by [Henning Dickten (@hensing)](https://github.com/hensing).
=======
The original project was created by Thomas Waldmann (@ThomasWaldmann). This Docker image is maintained by Henning Dickten (@hensing).
>>>>>>> fec07ef4a6f7ba77f2e1df904a4259b46783a4d0

## Features

-   Based on the official `python:3.13-slim` image.
-   Uses `gunicorn` as the WSGI server.
-   Includes a cron daemon for running periodic maintenance tasks automatically.
-   Secure by default: forces the creation of a superuser with a user-defined password on the first run.
-   Supports configuration via environment variables and a `local_settings.py` file.
-   Persistent data storage using a Docker volume.

## Getting Started

### Using Docker Compose (Recommended)

The easiest way to run the service is with `docker compose`.

1.  **Create a `compose.yaml` file:**

    ```yaml
    services:
      nsupdate:
        image: ghcr.io/hensing/nsupdate-docker:latest
        container_name: nsupdate
        restart: unless-stopped
        ports:
          - "8000:8000"
        environment:
          # IMPORTANT: Set a secure password for the admin user on the first run.
          - DJANGO_SUPERUSER_PASSWORD=your-super-secret-password
          # - DJANGO_SUPERUSER_EMAIL=admin@your-domain.com
          # - SECRET_KEY=your-very-long-and-random-secret-key
        volumes:
          - ./config:/config
    ```

2.  **Start the container:**

    ```bash
    docker compose up -d
    ```

### Using `docker run`

You can also run the container directly with `docker`.

```bash
docker run -d \
  --name nsupdate \
  -p 8000:8000 \
  -e DJANGO_SUPERUSER_PASSWORD=your-super-secret-password \
  -v $(pwd)/config:/config \
  ghcr.io/hensing/nsupdate-docker:latest
```

## Configuration

### Environment Variables

<<<<<<< HEAD
The container can be configured using the following environment variables. A template is provided in the `.env.example` file, which you can copy to `.env` and customize.
=======
The container can be configured using the following environment variables:
>>>>>>> fec07ef4a6f7ba77f2e1df904a4259b46783a4d0

| Variable                      | Description                                                                                                | Default                               |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| `DJANGO_SUPERUSER_USERNAME`   | The username for the administrative superuser.                                                             | `admin`                               |
| `DJANGO_SUPERUSER_EMAIL`      | The email address for the superuser.                                                                       | `admin@localhost.localdomain`         |
| `DJANGO_SUPERUSER_PASSWORD`   | **Required on first run.** The password for the superuser. The container will exit if this is not set on the initial startup. | `""`                                  |
| `SECRET_KEY`                  | Django's secret key. It is **highly recommended** to set this to a long, random string in production.       | `S3CR3T` (in default settings)        |
| `DATABASE_URL`                | The database connection string.                                                                            | `sqlite:////config/nsupdate.sqlite`   |
| `DJANGO_SETTINGS_MODULE`      | The Django settings module to use.                                                                         | `local_settings`                      |

### Advanced Configuration (`local_settings.py`)

For more advanced customization (e.g., setting up email, social authentication, or changing `ALLOWED_HOSTS`), you can use a custom `local_settings.py` file.

1.  **Copy the template:**
    ```bash
    cp local_settings.py.default local_settings.py
    ```
2.  **Edit `local_settings.py`** to fit your needs.
3.  **Mount the file** into your container by adding it to your volumes:

    **`compose.yaml`:**
    ```yaml
    volumes:
      - ./config:/config
      - ./local_settings.py:/nsupdate/src/local_settings.py
    ```

    **`docker run`:**
    ```bash
    -v $(pwd)/local_settings.py:/nsupdate/src/local_settings.py
    ```

## Data Persistence

The container uses a volume mounted at `/config` to store persistent data, including the SQLite database (`nsupdate.sqlite`). This ensures that your data is safe across container restarts.

## Automated Maintenance

The following maintenance tasks are automatically run via cron inside the container. You do not need to set them up manually.

-   Reinitialize the test user.
-   Reset client fault counters.
-   Clear expired sessions from the database.
-   Clear outdated registrations.
-   Check that domain nameservers are reachable.

## License

This project is licensed under the [MIT License](LICENSE).
