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
	uv run pytest -m "not container and not model and not deploy"

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

# `--target runtime` explicitly: the last stage in the Dockerfile is `evaluated`,
# which copies in eval_report.json — a file that does not exist until an image
# has been built and scored. Building it by default would make `make build`
# depend on the output of `make build`.
.PHONY: build
build:  ## Build the container image (first run downloads torch + weights, ~10 min)
	docker build --target runtime -t $(IMAGE) .
	@docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' $(IMAGE)

.PHONY: evaluate
evaluate:  ## Score the built image, then bake the report into it (/metadata)
	IMAGE=$(IMAGE) infra/evaluate.sh

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
	docker build --platform linux/amd64 --target runtime -t $(REMOTE):$(GIT_SHA) .

# Scores the amd64 image and layers the report in, so the revision that reaches
# Cloud Run can answer /metadata. That answer is the baseline CI compares the
# next candidate against — an unevaluated production image makes the regression
# check skip silently.
.PHONY: evaluate-amd64
evaluate-amd64: build-amd64  ## Build amd64, score it, bake the report in
	IMAGE=$(REMOTE):$(GIT_SHA) PLATFORM=linux/amd64 infra/evaluate.sh

.PHONY: push
push: evaluate-amd64  ## Build amd64, score it, and push it tagged with the git SHA
	docker push $(REMOTE):$(GIT_SHA)

# Deploying and releasing are separate on purpose — see infra/deploy.sh. The
# three targets below are the three decisions: put it there, let it serve, take
# it back.

.PHONY: candidate
candidate:  ## Deploy to Cloud Run serving NO traffic, and smoke test it
	infra/deploy.sh

.PHONY: release
release:  ## Send the candidate 10% of traffic, watch, then 100%
	infra/release.sh

.PHONY: rollback
rollback:  ## Send 100% of traffic back to the previous revision
	infra/rollback.sh

.PHONY: deploy
deploy: candidate release  ## candidate + release in one go

.PHONY: smoke
smoke:  ## Drive a deployed revision over HTTP (needs DEPLOY_URL)
	uv run pytest -m deploy

# --- shipping, on purpose --------------------------------------------------
# A push to main no longer deploys. These two are what replaced it: one says
# what is live, the other changes it.

.PHONY: drift
drift:  ## What production is running, versus what you have committed
	@infra/drift.sh

.PHONY: ship
ship:  ## Deploy the pushed main branch to Cloud Run (build + canary in CI)
	@git diff --quiet HEAD -- || { echo "working tree is dirty — commit first"; exit 1; }
	@test -z "$$(git log --oneline @{upstream}..HEAD 2>/dev/null)" \
		|| { echo "you have unpushed commits — \`git push\` first, or they will not ship"; exit 1; }
	gh workflow run cd.yml --ref $$(git rev-parse --abbrev-ref HEAD)
	@echo "  triggered. watch it with:  gh run watch \$$(gh run list --workflow=cd.yml --limit 1 --json databaseId --jq '.[0].databaseId')"

.PHONY: url
url:  ## Print the live service URL
	@gcloud run services describe $(SERVICE) --project=$(PROJECT) \
		--region=$(REGION) --format='value(status.url)'

.PHONY: candidate-url
candidate-url:  ## Print the candidate revision's own URL
	@bash -c 'source infra/lib.sh && candidate_url'
