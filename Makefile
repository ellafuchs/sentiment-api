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
