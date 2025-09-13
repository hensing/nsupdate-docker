#
# nsupdate.info Dockerfile
#
# https://github.com/nsupdate-info/nsupdate.info
# Docker image maintained by Henning Dickten (@hensing)
#

FROM python:3.13-slim-trixie

LABEL maintainer="Henning Dickten (@hensing)"

# Set build-time arguments
ARG BUILD=prod
ARG uwsgi_uid=700
ARG uwsgi_gid=700

# Set environment variables
ENV BUILD=$BUILD \
    DATABASE_URL="sqlite:////config/nsupdate.sqlite" \
    DJANGO_SETTINGS_MODULE=local_settings \
    DJANGO_SUPERUSER_EMAIL="admin@localhost.localdomain" \
    DJANGO_SUPERUSER_USERNAME="admin" \
    DOCKER_CONTAINER=1 \
    UWSGI_INI=/nsupdate/uwsgi.ini \
    PYTHONPATH="/nsupdate/src"

# Create a directory for persistent data
RUN mkdir /config

# Install system dependencies, clone the application, install Python packages, and clean up in a single layer
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get install -y --no-install-recommends \
       cron \
       git \
       build-essential \
       python3-dev \
       libpq-dev \
    && git clone https://github.com/nsupdate-info/nsupdate.info.git /nsupdate \
    && cd /nsupdate/ \
    && pip install --no-cache-dir -r requirements.d/prod.txt \
    && pip install --no-cache-dir django-xff whitenoise \
    && pip install --no-cache-dir -e . \
    && apt-get purge -y --auto-remove git build-essential \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copy the default settings file
COPY local_settings.py.default /nsupdate/src/local_settings.py

# Run database migrations and collect static files
RUN django-admin migrate \
    && django-admin collectstatic --noinput

# Set up cron jobs
COPY nsupdate-cron /etc/cron.d/nsupdate-cron
RUN chmod 0644 /etc/cron.d/nsupdate-cron \
    && crontab /etc/cron.d/nsupdate-cron

# Expose the application port
EXPOSE 8000

# Copy and set permissions for the entrypoint script
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Mount a volume for persistent configuration and data
VOLUME ["/config"]

# Set the entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]
