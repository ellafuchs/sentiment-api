.DEFAULT_GOAL := help
SHELL := /bin/bash

# Local commands mirror what CI runs. If `make test` passes here and fails in
# CI, that divergence is itself the bug — keep these in sync with .github/workflows.

.PHONY: help
help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install:  ## Sync the virtualenv from uv.lock
	uv sync --all-groups

.PHONY: lint
lint:  ## Ruff check + format check
	uv run ruff check .
	uv run ruff format --check .

.PHONY: fmt
fmt:  ## Auto-format
	uv run ruff format .
	uv run ruff check --fix .

.PHONY: fetch
fetch:  ## Download model weights into .model_cache/ (per models.yaml)
	uv run python -m app.fetch

.PHONY: test
test:  ## Fast tests: unit + contract, no model download
	uv run pytest -m "not container and not model"

.PHONY: test-model
test-model:  ## Slow tests: load the real model and predict (needs `make fetch`)
	uv run pytest -m model

.PHONY: run
run:  ## Serve locally on :8080 with autoreload
	uv run uvicorn app.main:app --host 0.0.0.0 --port 8080 --reload

# --- scoring a model -------------------------------------------------------
# `eval` talks to a RUNNING service over HTTP, the same way a real caller would.
# Start `make run` in another terminal first.

.PHONY: eval
eval:  ## Score the running service against the 200-example golden set
	uv run python -m eval.run_eval --url http://localhost:8080

.PHONY: gate
gate:  ## Judge eval_report.json against the thresholds in models.yaml
	uv run python -m eval.gate

.PHONY: score
score: eval gate  ## eval + gate in one go (needs `make run` in another terminal)

# --- the container ---------------------------------------------------------
# The image is the artifact that actually ships. Weights are baked in at build
# time, so `build` is slow the first time and cached afterwards.

IMAGE ?= poc-bert:dev

.PHONY: build
build:  ## Build the container image (first run downloads torch + weights, ~10 min)
	docker build -t $(IMAGE) .
	@docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' $(IMAGE)

.PHONY: test-container
test-container:  ## Run the tests that drive the built image over HTTP
	uv run pytest -m container

.PHONY: run-container
run-container:  ## Serve from the image on :8080, the way Cloud Run will
	docker run --rm -p 8080:8080 $(IMAGE)
