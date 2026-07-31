#!/usr/bin/env bash
# =============================================================================
# Deploy one image to Cloud Run.
#
#     make deploy              # deploys the image tagged with the current SHA
#     TAG=abc1234 make deploy  # deploys a specific one (this is how you roll back)
#
# Two rules this script enforces rather than documents:
#
#   1. The tag is a git SHA, and the tree must be clean. A running revision that
#      maps to no commit is a revision nobody can reproduce or reason about.
#
#   2. It deploys a DIGEST, never a tag. Tags move; digests do not. Asking
#      "which image is revision 7 running?" must have exactly one answer, and
#      `latest` makes that question unanswerable.
#
# The flags live here rather than in the Makefile so that Phase 4's cd.yml runs
# this identical path instead of a second, subtly different copy of it.
# =============================================================================
set -euo pipefail

PROJECT="${PROJECT:-poc-bert-mlops-460289b}"
REGION="${REGION:-me-west1}"
REPO="${REPO:-poc-bert}"
SERVICE="${SERVICE:-sentiment}"
SA_EMAIL="${SA_EMAIL:-sentiment-run@${PROJECT}.iam.gserviceaccount.com}"
TAG="${TAG:-$(git rev-parse --short HEAD)}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/sentiment"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# --- the tag must mean something ---------------------------------------------
# Refresh the index first. `git diff-index` compares stat data before content,
# so a fresh clone — every CI checkout — can report files as modified purely
# because their mtimes are new. Without this the guard below fails a pipeline
# whose tree is provably clean, which is the worst kind of false positive: it
# looks like the safety check working.
git update-index -q --refresh 2>/dev/null || true

if [[ -z "${ALLOW_DIRTY:-}" ]] && ! git diff-index --quiet HEAD -- 2>/dev/null; then
  die "working tree is dirty — commit first, or set ALLOW_DIRTY=1.
    The image tag is a git SHA. Deploying uncommitted code produces a live
    revision that maps to no commit, which is unreproducible by construction."
fi

say "resolving ${IMAGE}:${TAG}"

# Tag -> digest. Fails loudly if the tag was never pushed, which is a far better
# error than Cloud Run reporting a manifest it cannot pull three minutes later.
DIGEST="$(gcloud artifacts docker images describe "${IMAGE}:${TAG}" \
  --project="${PROJECT}" --format='value(image_summary.digest)' 2>/dev/null)" \
  || die "no image ${IMAGE}:${TAG} in the registry — run \`make push\` first."

printf '  tag    %s\n  digest %s\n' "${TAG}" "${DIGEST}"

# --- deploy -------------------------------------------------------------------
# --cpu 2 / --memory 2Gi   the model is 268MB of weights; loading peaks well above idle
# --min-instances 0        scales to zero, so an idle service is free
# --max-instances 3        the cost ceiling on a public endpoint
# --concurrency 8          `predict` is sync and runs in a thread pool with torch
#                          threads underneath; the default of 80 is thread thrash
# --cpu-boost              the entire cold start is model load
# --timeout 60             a prediction is ~50ms; the 300s default just holds sockets
# --service-account        least privilege: logs only, NOT the default compute SA
say "deploying ${SERVICE} to ${REGION}"
gcloud run deploy "${SERVICE}" \
  --image="${IMAGE}@${DIGEST}" \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --platform=managed \
  --memory=2Gi \
  --cpu=2 \
  --min-instances=0 \
  --max-instances=3 \
  --concurrency=8 \
  --cpu-boost \
  --timeout=60 \
  --allow-unauthenticated \
  --service-account="${SA_EMAIL}" \
  --set-env-vars=OMP_NUM_THREADS=2 \
  --labels="git-sha=${TAG}" \
  --quiet

URL="$(gcloud run services describe "${SERVICE}" \
  --project="${PROJECT}" --region="${REGION}" --format='value(status.url)')"
REVISION="$(gcloud run services describe "${SERVICE}" \
  --project="${PROJECT}" --region="${REGION}" --format='value(status.latestReadyRevisionName)')"

# --- prove it actually serves -------------------------------------------------
# Cloud Run reporting a revision Ready means the container started and held the
# port. It does not mean the model loaded. /readyz is the difference.
say "waiting for ${URL}/readyz"
for _ in $(seq 1 60); do
  if body="$(curl -fsS --max-time 10 "${URL}/readyz" 2>/dev/null)"; then
    printf '  %s\n' "${body}"
    say "live"
    printf '  url       %s\n  revision  %s\n  digest    %s\n' "${URL}" "${REVISION}" "${DIGEST}"
    exit 0
  fi
  sleep 5
done

die "deployed ${REVISION} but ${URL}/readyz never answered 200.
    Check:  gcloud run services logs read ${SERVICE} --region ${REGION}"
