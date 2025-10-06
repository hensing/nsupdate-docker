#
# nsupdate.info Dockerfile (Multi-Stage Build)
#
# https://github.com/nsupdate-info/nsupdate.info
# Docker image maintained by Henning Dickten (@hensing)
#

# --- Builder Stage ---
# This stage installs build dependencies, clones the repo, and installs Python packages.
ARG BUILD_TARGET=prod
FROM python:3.13-slim-trixie AS builder

ARG BUILD_TARGET

# Install build dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git \
       build-essential \
       python3-dev \
       libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Clone the application repository
RUN git clone https://github.com/nsupdate-info/nsupdate.info.git /app

# Install Python dependencies
WORKDIR /app
RUN pip install --no-cache-dir -r requirements.d/prod.txt \
    && if [ "$BUILD_TARGET" = "test" ] ; then \
        echo ">>> Installing additional development requirements..." && \
        pip install --no-cache-dir -r requirements.d/dev.txt; \
    fi \
    && pip install --no-cache-dir django-xff whitenoise \
    && pip install --no-cache-dir -e . \
    && PYTHONPATH=/app/src DJANGO_SETTINGS_MODULE=nsupdate.settings.prod django-admin makemigrations main \
    && rm -rf /app/.git

# --- Final Stage ---
# This stage builds the final, minimal production image.
FROM python:3.13-slim-trixie

LABEL maintainer="Henning Dickten (@hensing)"

# Set build-time arguments for user/group IDs
ARG APP_UID=33
ARG APP_GID=33

# Set environment variables
ENV BUILD=prod \
    DATABASE_URL="sqlite:////app/database/nsupdate.sqlite" \
    DJANGO_SETTINGS_MODULE=local_settings \
    DJANGO_SUPERUSER_EMAIL="admin@localhost.localdomain" \
    DJANGO_SUPERUSER_USERNAME="admin" \
    DOCKER_CONTAINER=1 \
    UWSGI_INI=/app/uwsgi.ini \
    PYTHONPATH="/app/src" \
    STATIC_ROOT="/app/static" \
    GUNICORN_FORWARDED_ALLOW_IPS="*"
    
# Install runtime dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       cron \
       gosu \
    && rm -rf /var/lib/apt/lists/*

# Modify existing www-data user and group to match given UID/GID
RUN groupmod -o -g ${APP_GID} www-data && \
    usermod -o -u ${APP_UID} -g www-data www-data

# Copy application code and installed packages from the builder stage
COPY --from=builder /app /app
COPY --from=builder /usr/local/lib/python3.13/site-packages/ /usr/local/lib/python3.13/site-packages/
COPY --from=builder /usr/local/bin/ /usr/local/bin/

# Copy configuration and entrypoint scripts
COPY local_settings.py.default /app/src/local_settings.py
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY nsupdate-cron /etc/cron.d/nsupdate-cron

# Set permissions
RUN chmod +x /docker-entrypoint.sh \
    && chmod 0644 /etc/cron.d/nsupdate-cron \
    && crontab /etc/cron.d/nsupdate-cron \
    && mkdir -p /app/database /app/static \
    && chown -R www-data:www-data /app

# Set working directory
WORKDIR /app

# Run initial setup as root
RUN django-admin collectstatic --noinput

# Expose the application port
EXPOSE 8000

# Mount a volume for persistent data
VOLUME ["/app/database"]

# Set the entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]

# Default command (will be run as www-data via entrypoint)
# We use a shell here to allow the GUNICORN_FORWARDED_ALLOW_IPS environment variable to be expanded.
CMD ["/bin/sh", "-c", "exec gunicorn --workers=4 --log-level=info --forwarded-allow-ips=\"$GUNICORN_FORWARDED_ALLOW_IPS\" --bind 0.0.0.0:8000 nsupdate.wsgi"]
