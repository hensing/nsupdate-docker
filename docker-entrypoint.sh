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
import sys
User = get_user_model()
if not User.objects.filter(username='${DJANGO_SUPERUSER_USERNAME}').exists():
    print("Superuser not found, creating one...")
    password = '${DJANGO_SUPERUSER_PASSWORD}'
    if not password:
        print("Error: DJANGO_SUPERUSER_PASSWORD environment variable is not set.", file=sys.stderr)
        print("Please set this variable to create the superuser on the first run.", file=sys.stderr)
        sys.exit(1)
    else:
        User.objects.create_superuser('${DJANGO_SUPERUSER_USERNAME}', '${DJANGO_SUPERUSER_EMAIL}', password)
        print("Superuser created.")
EOF

    # Start the Gunicorn server
    echo "Starting Gunicorn server..."
    cd /nsupdate/src
    exec gunicorn --workers=4 --log-level=info --forwarded-allow-ips='*' --bind 0.0.0.0:8000 nsupdate.wsgi
fi
