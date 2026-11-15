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

# Where the upstream application comes from:
#   git  -> clone nsupdate.info from GitHub at NSUPDATE_REF   (image tags:
#           dev, latest, dev-<sha>)
#   pypi -> install the released "nsupdate" package from PyPI (image tags:
#           stable, <version>)
ARG NSUPDATE_SOURCE=git

# NSUPDATE_SOURCE=git: the upstream git ref to build. Defaults to "master":
# nsupdate.info cuts tagged releases rarely and they lag well behind master
# (e.g. the tag "0.13.0" is ~60 commits and several bugfixes behind). For a
# fully reproducible/supply-chain-pinned build, override with a specific commit
# sha, e.g. --build-arg NSUPDATE_REF=<sha>.
ARG NSUPDATE_REF=master

# NSUPDATE_SOURCE=pypi: the release is pinned in requirements/stable.txt
# (kept current by Dependabot); CI tags the image with that version.

# --- Builder Stage ---------------------------------------------------------
# Full Wolfi toolchain: git + build-base + uv, used to resolve/compile the app
# and its dependencies into /app/.venv.
FROM cgr.dev/chainguard/wolfi-base AS builder

ARG BUILD_TARGET
ARG PYTHON_VERSION
ARG NSUPDATE_SOURCE
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

# git: clone the requested application revision into /app (sources in /app/src).
# pypi: only create /app/src, which then holds nothing but local_settings.py --
#       the application itself is installed into the venv's site-packages.
RUN case "$NSUPDATE_SOURCE" in \
      git) \
        { git clone --depth 1 --branch "${NSUPDATE_REF}" \
              https://github.com/nsupdate-info/nsupdate.info.git /app \
          || git clone https://github.com/nsupdate-info/nsupdate.info.git /app; } \
        && git -C /app checkout "${NSUPDATE_REF}" ;; \
      pypi) \
        mkdir -p /app/src ;; \
      *) \
        echo "NSUPDATE_SOURCE must be 'git' or 'pypi' (got '$NSUPDATE_SOURCE')" >&2; exit 1 ;; \
    esac

WORKDIR /app

# Create a self-contained virtualenv and install dependencies with uv.
# git:  the upstream requirements.d/prod.txt carries the app's dependencies.
# pypi: requirements/stable.txt pins the nsupdate release (plus the runtime
#       packages upstream lists only in its requirements files).
# Both: requirements/extras.txt adds gunicorn, whitenoise and django-xff,
#       pinned at the minor version and floating on bugfix releases.
COPY requirements/ /requirements/
ENV VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:$PATH"
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv "$VIRTUAL_ENV" --python "python${PYTHON_VERSION}" \
    && if [ "$NSUPDATE_SOURCE" = "pypi" ]; then \
        if [ "$BUILD_TARGET" = "test" ]; then \
            echo "BUILD_TARGET=test needs NSUPDATE_SOURCE=git (the PyPI release ships no dev requirements)" >&2; exit 1; \
        fi; \
        set -- -r /requirements/stable.txt; \
    else \
        set -- -r requirements.d/prod.txt; \
    fi \
    && uv pip install "$@" -r /requirements/extras.txt \
    && if [ "$BUILD_TARGET" = "test" ]; then \
        echo ">>> Installing development requirements..." && \
        uv pip install -r requirements.d/dev.txt; \
    fi

# Install the application itself (git only -- the pypi variant already has it)
# and prepare migrations + static files at build time (a throwaway SECRET_KEY
# is fine here; the real one is required at runtime).
COPY local_settings.py.default /app/src/local_settings.py
RUN --mount=type=cache,target=/root/.cache/uv \
    if [ "$NSUPDATE_SOURCE" = "git" ]; then uv pip install -e .; fi \
    && uv pip show nsupdate | grep -E '^(Name|Version):' \
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

# RAM-conscious default for small installations (1-2 concurrent users): a
# single sync worker is the lowest-RAM option -- requests serialize instead of
# running in parallel, which is imperceptible at this scale. --max-requests
# recycles the worker periodically to bound memory growth. For more headroom
# (more concurrent users), override the command with e.g. --workers=2 --preload.
CMD ["/bin/sh", "-c", "exec gunicorn --workers=1 --max-requests=1000 --max-requests-jitter=100 --worker-tmp-dir /dev/shm --log-level=info --forwarded-allow-ips=\"$GUNICORN_FORWARDED_ALLOW_IPS\" --bind 0.0.0.0:8000 nsupdate.wsgi"]
