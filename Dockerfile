#
# nsupdate.info Dockerfile (Wolfi, multi-stage, rootless)
#
# https://github.com/nsupdate-info/nsupdate.info
# Docker image maintained by Henning Dickten (@hensing)
#
# Rationale: Wolfi (Chainguard's container-native "undistro") ships near-zero
# CVEs with continuous updates and runs non-root by default. Dependencies are
# installed with `uv` into a self-contained venv that is copied into a minimal
# runtime stage. No process runs as root at runtime.
#

ARG BUILD_TARGET=prod
ARG PYTHON_VERSION=3.14

# The upstream application ref to build. Defaults to "master": nsupdate.info
# cuts tagged releases rarely and they lag well behind master (e.g. the latest
# tag "0.13.0" is ~60 commits and several bugfixes behind), so tracking master
# is the safer default here. For a fully reproducible/supply-chain-pinned build,
# override with a specific commit sha, e.g. --build-arg NSUPDATE_REF=<sha>.
ARG NSUPDATE_REF=master

# --- Builder Stage ---------------------------------------------------------
# Full Wolfi toolchain: git + build-base + uv, used to resolve/compile the app
# and its dependencies into /app/.venv.
FROM cgr.dev/chainguard/wolfi-base AS builder

ARG BUILD_TARGET
ARG PYTHON_VERSION
ARG NSUPDATE_REF

# Build dependencies (psycopg needs a C toolchain + libpq headers).
RUN apk add --no-cache \
        python-${PYTHON_VERSION} \
        python-${PYTHON_VERSION}-dev \
        uv \
        git \
        build-base \
        posix-libc-utils \
        postgresql-dev \
        ca-certificates-bundle

# Clone the pinned application revision.
RUN git clone --depth 1 --branch "${NSUPDATE_REF}" \
        https://github.com/nsupdate-info/nsupdate.info.git /app \
    || git clone https://github.com/nsupdate-info/nsupdate.info.git /app \
       && git -C /app checkout "${NSUPDATE_REF}"

WORKDIR /app

# Create a self-contained virtualenv and install dependencies with uv.
# Extras are pinned at the minor version (major.minor.0) but float on bugfix
# releases (~=X.Y.0 allows X.Y.1, X.Y.2, ... but not X.(Y+1).0) -- this picks up
# patch-level security fixes automatically while keeping upgrades deliberate.
# The upstream prod.txt carries its own pins.
ENV VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:$PATH"
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv "$VIRTUAL_ENV" --python "python${PYTHON_VERSION}" \
    && uv pip install \
        -r requirements.d/prod.txt \
        "gunicorn~=26.0.0" \
        "whitenoise~=6.12.0" \
        "django-xff~=1.5.0" \
    && if [ "$BUILD_TARGET" = "test" ]; then \
        echo ">>> Installing development requirements..." && \
        uv pip install -r requirements.d/dev.txt; \
    fi

# Install the application itself and prepare migrations + static files at build
# time (a throwaway SECRET_KEY is fine here; the real one is required at runtime).
COPY local_settings.py.default /app/src/local_settings.py
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install -e . \
    && SECRET_KEY=build-only PYTHONPATH=/app/src DJANGO_SETTINGS_MODULE=nsupdate.settings.prod \
        django-admin makemigrations main \
    && SECRET_KEY=build-only PYTHONPATH=/app/src DJANGO_SETTINGS_MODULE=local_settings STATIC_ROOT=/app/static \
        django-admin collectstatic --noinput \
    && rm -rf /app/.git

# --- Runtime Stage ---------------------------------------------------------
# Minimal Wolfi runtime: python + bash (entrypoint) + supercronic + libpq.
FROM cgr.dev/chainguard/wolfi-base

LABEL maintainer="Henning Dickten (@hensing)"

ARG PYTHON_VERSION
# uid/gid the container runs as. 65532 = Chainguard "nonroot" convention.
ARG APP_UID=65532
ARG APP_GID=65532

# supercronic replaces the root cron daemon (runs jobs as the non-root user).
RUN apk add --no-cache \
        python-${PYTHON_VERSION} \
        bash \
        tzdata \
        libpq \
        supercronic \
        ca-certificates-bundle

ENV BUILD=prod \
    DATABASE_URL="sqlite:////app/database/nsupdate.sqlite" \
    DJANGO_SETTINGS_MODULE=local_settings \
    DJANGO_SUPERUSER_EMAIL="admin@localhost.localdomain" \
    DJANGO_SUPERUSER_USERNAME="admin" \
    DOCKER_CONTAINER=1 \
    UWSGI_INI=/app/uwsgi.ini \
    PYTHONPATH="/app/src" \
    STATIC_ROOT="/app/static" \
    # Proxy-only default; override with your reverse-proxy CIDR (do not use "*").
    GUNICORN_FORWARDED_ALLOW_IPS="127.0.0.1" \
    # Non-root + read-only rootfs friendliness:
    VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:$PATH" \
    HOME=/tmp \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Copy the built application (incl. venv, static, migrations).
COPY --from=builder /app /app

# Copy configuration and entrypoint scripts.
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY nsupdate-crontab /app/nsupdate-crontab

# Bake ownership so no runtime chown (and thus no root) is required.
RUN chmod +x /docker-entrypoint.sh \
    && mkdir -p /app/database /app/static \
    && chown -R ${APP_UID}:${APP_GID} /app

WORKDIR /app

EXPOSE 8000
VOLUME ["/app/database"]

# Drop to the non-root user for the entire runtime.
USER ${APP_UID}:${APP_GID}

# Fail the health check if the app stops answering HTTP (Host: localhost is in
# ALLOWED_HOSTS). Uses stdlib only — no curl needed in the minimal image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/')" || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]

# RAM-conscious defaults for small installations (1-2 concurrent users):
# --preload shares memory across workers (copy-on-write), --max-requests recycles
# workers to bound memory growth. Lowest-RAM alternative: --workers=1 --threads=4.
CMD ["/bin/sh", "-c", "exec gunicorn --workers=2 --preload --max-requests=1000 --max-requests-jitter=100 --worker-tmp-dir /dev/shm --log-level=info --forwarded-allow-ips=\"$GUNICORN_FORWARDED_ALLOW_IPS\" --bind 0.0.0.0:8000 nsupdate.wsgi"]
