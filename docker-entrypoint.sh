#!/bin/bash
set -e

# Always apply database migrations
echo "Applying database migrations..."
python3 /nsupdate/manage.py migrate

# If a command is passed to the container, execute it.
# Otherwise, start the web server.
if [ -n "$1" ]; then
    echo "Executing command: $@"
    exec "$@"
else
    # Start the cron daemon in the background
    echo "Starting cron daemon..."
    cron

    # Create a superuser on the first run, if it doesn't exist
    echo "Checking for superuser..."
    python3 /nsupdate/manage.py shell <<EOF
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(username='${DJANGO_SUPERUSER_USERNAME}').exists():
    print("Superuser not found, creating one...")
    if [ -z "${DJANGO_SUPERUSER_PASSWORD}" ]; then
        echo "Error: DJANGO_SUPERUSER_PASSWORD environment variable is not set." >&2
        echo "Please set this variable to create the superuser on the first run." >&2
        exit 1
    else
        User.objects.create_superuser('${DJANGO_SUPERUSER_USERNAME}', '${DJANGO_SUPERUSER_EMAIL}', '${DJANGO_SUPERUSER_PASSWORD}')
        print("Superuser created.")
fi
EOF

    # Start the Gunicorn server
    echo "Starting Gunicorn server..."
    cd /nsupdate/src
    exec gunicorn --workers=4 --log-level=info --forwarded-allow-ips='*' --bind 0.0.0.0:8000 nsupdate.wsgi
fi
