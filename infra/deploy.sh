#!/usr/bin/env bash
# =============================================================================
# Deploy one image to Cloud Run — WITHOUT releasing it.
#
#     make candidate              # deploy the image tagged with the current SHA
#     TAG=abc1234 make candidate  # deploy a specific one
#
# **Deploying is not releasing.** This script creates a revision, waits for it
# to actually serve, and hands back its name and its own private URL. It sends
# it no user traffic at all. `infra/release.sh` is what does that, and the fact
# that they are two files is the point: the moment a new version starts running
# and the moment it starts mattering are different decisions, and every safe
# rollout strategy is built on being able to put a smoke test between them.
#
# Concretely: `--no-traffic --tag=candidate` gives the revision a stable URL of
# its own — https://candidate---sentiment-….run.app — reachable while the
# service keeps answering from the old revision. So the new one can be tested in
# production, on production hardware, with production config, before a single
# real request touches it.
#
# Three rules this enforces rather than documents:
#
#   1. The tag is a git SHA and the tree must be clean. A running revision that
#      maps to no commit is a revision nobody can reproduce or reason about.
#
#   2. It deploys a DIGEST, never a tag. Tags move; digests do not. Asking
#      "which image is revision 7 running?" must have exactly one answer, and
#      `latest` makes that question unanswerable.
#
#   3. It records the revision that is serving *now*, before touching anything.
#      That name is what rollback needs, and the moment to capture it is before
#      you have changed anything — not after something has gone wrong.
#
# The flags live here rather than in the Makefile or in cd.yml so that CI runs
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

describe() {
  gcloud run services describe "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" "$@"
}

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

# --- who is serving right now -------------------------------------------------
# Captured before the deploy, because this is the rollback target and the time
# to write down the way back is while everything still works.
#
# Selected by "has traffic", not by position. Once a candidate tag exists the
# traffic list holds more than one entry — the tagged revision sits in it at 0%
# — so `status.traffic[0]` can name a revision serving nobody, and the recorded
# way back would point at the thing being replaced.
PREVIOUS="$(describe --flatten='status.traffic[]' \
  --filter='status.traffic.percent>0' \
  --format='value(status.traffic.revisionName)' 2>/dev/null | head -1 || true)"

say "resolving ${IMAGE}:${TAG}"

# Tag -> digest. Fails loudly if the tag was never pushed, which is a far better
# error than Cloud Run reporting a manifest it cannot pull three minutes later.
DIGEST="$(gcloud artifacts docker images describe "${IMAGE}:${TAG}" \
  --project="${PROJECT}" --format='value(image_summary.digest)' 2>/dev/null)" \
  || die "no image ${IMAGE}:${TAG} in the registry — run \`make push\` first."

printf '  tag      %s\n  digest   %s\n  serving  %s\n' \
  "${TAG}" "${DIGEST}" "${PREVIOUS:-<nothing yet>}"

# --- deploy, but do not release ------------------------------------------------
# --no-traffic             the whole point: running, addressable, serving 0%
# --tag=candidate          gives it a stable private URL to smoke test
# --cpu 2 / --memory 2Gi   the model is 268MB of weights; loading peaks above idle
# --min-instances 0        scales to zero, so an idle service is free
# --max-instances 3        the cost ceiling on a public endpoint
# --concurrency 8          `predict` is sync and runs in a thread pool with torch
#                          threads underneath; the default of 80 is thread thrash
# --cpu-boost              the entire cold start is model load
# --timeout 60             a prediction is ~50ms; the 300s default just holds sockets
# --service-account        least privilege: logs only, NOT the default compute SA
say "deploying ${SERVICE} to ${REGION} (no traffic)"
gcloud run deploy "${SERVICE}" \
  --image="${IMAGE}@${DIGEST}" \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --platform=managed \
  --no-traffic \
  --tag=candidate \
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

REVISION="$(describe --format='value(status.latestCreatedRevisionName)')"

# The tagged URL, dug out of the traffic list. `--flatten` turns the list into
# one record per entry so `--filter` can pick the tagged one by name; without it
# the filter matches the whole list or nothing.
CANDIDATE_URL="$(describe \
  --flatten='status.traffic[]' \
  --filter='status.traffic.tag=candidate' \
  --format='value(status.traffic.url)')"

[[ -n "${CANDIDATE_URL}" ]] || die "deployed ${REVISION} but it has no candidate URL."

# --- prove it actually serves --------------------------------------------------
# Cloud Run reporting a revision Ready means the container started and held the
# port. It does not mean the model loaded. /readyz is the difference.
#
# A --no-traffic revision is not kept warm, so this request is the one paying
# the cold start: image pull plus 268MB of weights.
say "waiting for ${CANDIDATE_URL}/readyz"
READY=""
for _ in $(seq 1 60); do
  if body="$(curl -fsS --max-time 15 "${CANDIDATE_URL}/readyz" 2>/dev/null)"; then
    printf '  %s\n' "${body}"
    READY=1
    break
  fi
  sleep 5
done

[[ -n "${READY}" ]] || die "deployed ${REVISION} but ${CANDIDATE_URL}/readyz never answered 200.
    Check:  gcloud run services logs read ${SERVICE} --region ${REGION}"

say "deployed, serving no traffic"
printf '  revision   %s\n  digest     %s\n  candidate  %s\n  previous   %s\n' \
  "${REVISION}" "${DIGEST}" "${CANDIDATE_URL}" "${PREVIOUS:-<none>}"
printf '\n  Not released. Next:  DEPLOY_URL=%s uv run pytest -m deploy\n' "${CANDIDATE_URL}"
printf '                 then:  make release\n'

# Hand the values to the next step when running under Actions. Writing to
# $GITHUB_OUTPUT rather than re-deriving them downstream keeps one source of
# truth for "which revision did we just create".
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "revision=${REVISION}"
    echo "candidate_url=${CANDIDATE_URL}"
    echo "previous=${PREVIOUS}"
    echo "digest=${DIGEST}"
  } >>"${GITHUB_OUTPUT}"
fi
