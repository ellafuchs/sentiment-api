# =============================================================================
# The immutable artifact.
#
# Two stages. The builder installs dependencies and downloads the model; the
# runtime stage copies over only the two things worth keeping — the virtualenv
# and the weights — into a clean base. uv, pip caches and build tooling are
# needed to *make* the image and are dead weight *inside* it.
#
# The model is fetched at BUILD time, not at start time. That is what makes one
# image tag mean one exact set of weights forever, and lets the container start
# with no network access at all.
# =============================================================================

# --- stage 1: builder --------------------------------------------------------
FROM python:3.12-slim AS builder

ENV UV_PROJECT_ENVIRONMENT=/app/.venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NO_CACHE=1

WORKDIR /app

RUN pip install --no-cache-dir uv==0.11.8

# Dependencies first, project second. Editing app/ then invalidates only the
# last layer instead of forcing a torch reinstall on every code change.
#
# `--frozen` fails rather than silently updating uv.lock: a build that quietly
# resolves different versions than your laptop is exactly the reproducibility
# hole this project exists to close. `--no-dev` leaves pytest, ruff and datasets
# out of the image.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY app/ ./app/
COPY models.yaml ./
RUN uv sync --frozen --no-dev

# The download. Runs the same `app/fetch.py` you run locally, so the image and
# your laptop cannot drift on how weights are resolved.
RUN uv run --no-sync python -m app.fetch


# --- stage 2: runtime --------------------------------------------------------
FROM python:3.12-slim AS runtime

# Non-root. A container escape starting from uid 1000 is a much smaller problem
# than one starting from root, and Cloud Run has no reason to grant more.
RUN useradd --create-home --uid 1000 app

WORKDIR /app

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    MODEL_DIR=/app/.model_cache \
    MODELS_CONFIG_PATH=/app/models.yaml

COPY --from=builder --chown=app:app /app/.venv       /app/.venv
COPY --from=builder --chown=app:app /app/.model_cache /app/.model_cache
COPY --chown=app:app app/        ./app/
COPY --chown=app:app models.yaml ./

USER app

EXPOSE 8080

# Cloud Run injects $PORT and a container that ignores it never becomes ready.
# A shell is needed to expand the variable, so it is spelled out explicitly
# rather than left to Docker's shell form — and `exec` hands PID 1 to uvicorn so
# SIGTERM reaches it directly. Without that, every deploy ends in a 10-second
# kill instead of a graceful shutdown.
#
# One worker on purpose: each worker loads its own copy of the model, so two
# workers cost 268MB extra for no throughput gain on a single CPU.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080} --workers 1"]
