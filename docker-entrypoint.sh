#!/bin/bash
set -e

# The container always runs as the non-root application user (see USER in the
# Dockerfile), so there is no privilege-drop step here.

# 1. Apply database migrations (writes only to the /app/database volume).
echo "Applying database migrations..."
django-admin migrate --noinput

# 2. Create the superuser on first run (idempotent).
#    Credentials come from DJANGO_SUPERUSER_{USERNAME,EMAIL,PASSWORD} and are read
#    natively by createsuperuser from the environment -- no string interpolation,
#    so special characters in the password cannot cause shell/Python injection.
echo "Ensuring superuser exists..."
if django-admin shell -c "import os, sys; from django.contrib.auth import get_user_model as G; sys.exit(0 if G().objects.filter(username=os.environ.get('DJANGO_SUPERUSER_USERNAME','')).exists() else 1)"; then
    echo "Superuser already present, skipping."
else
    echo "Creating superuser..."
    django-admin createsuperuser --noinput
fi

# 3. Start the scheduler (supercronic) as the non-root user, in the background.
echo "Starting supercronic..."
supercronic /app/nsupdate-crontab &

# 4. Execute the main command (gunicorn).
cd /app/src
exec "$@"
