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

# URL is the one knob: `make score` grades whatever is listening there. Pointing
# it at Cloud Run is how the deployed service gets scored by the *same* harness
# that scored the laptop and the container — unmodified.
URL ?= http://localhost:8080

.PHONY: eval
eval:  ## Score the running service against the 200-example golden set
	uv run python -m eval.run_eval --url $(URL)

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

# --- the cloud -------------------------------------------------------------
# The image tag is always a git SHA. Never `latest`: rollback has to be able to
# name an exact revision, and `latest` makes "which image was that?" a question
# with no answer.

PROJECT ?= poc-bert-mlops-460289b
REGION  ?= me-west1
REPO    ?= poc-bert
SERVICE ?= sentiment
GIT_SHA ?= $(shell git rev-parse --short HEAD)
REMOTE  ?= $(REGION)-docker.pkg.dev/$(PROJECT)/$(REPO)/sentiment

.PHONY: build-amd64
build-amd64:  ## Build for Cloud Run's architecture (this laptop is arm64)
	docker build --platform linux/amd64 -t $(REMOTE):$(GIT_SHA) .

.PHONY: push
push: build-amd64  ## Build amd64 and push it, tagged with the current git SHA
	docker push $(REMOTE):$(GIT_SHA)

.PHONY: deploy
deploy:  ## Deploy that image to Cloud Run (resolves the tag to a digest first)
	infra/deploy.sh

.PHONY: url
url:  ## Print the live service URL
	@gcloud run services describe $(SERVICE) --project=$(PROJECT) \
		--region=$(REGION) --format='value(status.url)'
