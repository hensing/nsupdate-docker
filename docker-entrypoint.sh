#!/bin/bash
set -e

# --- Root Initialization Phase ---
# This block runs only if the container is started as root.
if [ "$(id -u)" = '0' ]; then
    echo "Running as root, performing initial setup..."

    # 1. Apply database migrations.
    echo "Applying database migrations..."
    django-admin migrate

    # 2. Create a superuser on the first run if it doesn't exist.
    echo "Checking for superuser..."
    django-admin shell <<EOF
from django.contrib.auth import get_user_model
import sys
User = get_user_model()
if not User.objects.filter(username='${DJANGO_SUPERUSER_USERNAME}').exists():
    print("Superuser not found, creating one...")
    password = '${DJANGO_SUPERUSER_PASSWORD}'
    if not password:
        print("Error: DJANGO_SUPERUSER_PASSWORD is not set.", file=sys.stderr)
        sys.exit(1)
    else:
        User.objects.create_superuser('${DJANGO_SUPERUSER_USERNAME}', '${DJANGO_SUPERUSER_EMAIL}', password)
        print("Superuser created.")
EOF

    # 3. Ensure correct permissions for the application directory.
    echo "Ensuring correct ownership..."
    chown -R www-data:www-data /app

    # 4. Start cron daemon as root.
    echo "Starting cron daemon..."
    cron -f &

    # 5. Drop privileges and execute the main command (CMD) as www-data.
    echo "Dropping privileges to www-data and starting application..."
    cd /app/src
    exec gosu www-data "$@"

# --- Non-Root Execution ---
# If the container is not started as root, just execute the command.
else
    exec "$@"
fi
