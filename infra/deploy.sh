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

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SA_EMAIL="${SA_EMAIL:-sentiment-run@${PROJECT}.iam.gserviceaccount.com}"
TAG="${TAG:-$(git rev-parse --short HEAD)}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/sentiment"

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
PREVIOUS="$(serving_revision)"

# --- is there a service at all? ----------------------------------------------
# `--no-traffic` cannot create a service. Its semantics are "give the traffic
# currently on LATEST to whichever revision LATEST pointed at before this
# deploy" — on a brand-new service there is no such revision, so gcloud rejects
# it outright:
#
#     ERROR: (gcloud.run.deploy) --no-traffic not supported when creating a new service.
#
# So the deploy/release split cannot bootstrap itself: the first revision of a
# new service necessarily serves traffic, because there is nothing else to serve
# it. That is the same reality release.sh:168 already handles ("no previous
# revision — going straight to 100%"), one script later.
#
# This is safe precisely when it happens: a service that does not exist yet has
# no users, and setup.sh has not yet made it public. It is still worth saying
# out loud rather than quietly deploying to 100% under a script whose entire
# promise is that deploying is not releasing.
#
# Found by the Phase 3.5 rebuild drill. Production's first deploy was done by
# hand, so this path had never once been executed.
FIRST_DEPLOY=""
if ! describe >/dev/null 2>&1; then
  FIRST_DEPLOY=1
fi

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
#
# NOT --allow-unauthenticated, deliberately. Public access is a property of the
# *service*, not of a revision — the IAM binding outlives every deploy, so
# re-asserting it on each one is at best a no-op. Setting it requires
# run.services.setIamPolicy, which `roles/run.developer` does not grant, so CI
# logged "Setting IAM policy failed" on every deploy: a warning that is noise
# here and would be the only warning worth reading somewhere else.
#
# Granting CI that permission would have fixed the message by making the deploy
# identity able to expose a private service to the internet. That is a strictly
# worse trade. `infra/setup.sh` owns the binding, where a human runs it.
TRAFFIC_FLAGS=(--no-traffic --tag=candidate)
if [[ -n "${FIRST_DEPLOY}" ]]; then
  TRAFFIC_FLAGS=(--tag=candidate)
  say "creating ${SERVICE} in ${REGION} — FIRST revision, so it takes traffic"
  printf '  --no-traffic cannot create a service: there is no previous revision\n'
  printf '  to hand the traffic back to. Nothing is public yet (setup.sh owns\n'
  printf '  that binding), so this revision serves nobody until you release it.\n'
else
  say "deploying ${SERVICE} to ${REGION} (no traffic)"
fi

gcloud run deploy "${SERVICE}" \
  --image="${IMAGE}@${DIGEST}" \
  --project="${PROJECT}" \
  --region="${REGION}" \
  --platform=managed \
  "${TRAFFIC_FLAGS[@]}" \
  --memory=2Gi \
  --cpu=2 \
  --min-instances=0 \
  --max-instances=3 \
  --concurrency=8 \
  --cpu-boost \
  --timeout=60 \
  --service-account="${SA_EMAIL}" \
  --set-env-vars=OMP_NUM_THREADS=2 \
  --labels="git-sha=${TAG}" \
  --quiet

REVISION="$(describe --format='value(status.latestCreatedRevisionName)')"

CANDIDATE_URL="$(candidate_url)"

# On a first deploy the tag and the whole service point at the same revision, so
# if the tagged URL has not materialised yet the service's own URL addresses the
# identical thing. Falling back beats dying on a distinction that does not exist
# when there is only one revision.
if [[ -z "${CANDIDATE_URL}" && -n "${FIRST_DEPLOY}" ]]; then
  CANDIDATE_URL="$(describe --format='value(status.url)')"
fi

[[ -n "${CANDIDATE_URL}" ]] || die "deployed ${REVISION} but it has no candidate URL."

# --- prove it actually serves --------------------------------------------------
# Cloud Run reporting a revision Ready means the container started and held the
# port. It does not mean the model loaded. /readyz is the difference.
#
# A --no-traffic revision is not kept warm, so this request is the one paying
# the cold start: image pull plus 268MB of weights.
say "waiting for ${CANDIDATE_URL}/readyz"
READY=""
LAST_CODE=""
for _ in $(seq 1 60); do
  LAST_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${CANDIDATE_URL}/readyz" || true)"
  if [[ "${LAST_CODE}" == "200" ]]; then
    printf '  %s\n' "$(curl -fsS --max-time 15 "${CANDIDATE_URL}/readyz")"
    READY=1
    break
  fi
  # 403 is not slow-to-start, it is a permission answer, and it will still be
  # 403 in five minutes. Fail now with the actual cause instead of timing out
  # and pointing at the logs, where there will be nothing — the request never
  # reached the container.
  if [[ "${LAST_CODE}" == "403" ]]; then
    die "${CANDIDATE_URL}/readyz returned 403 — the service is not public.
    Public access is a service-level IAM binding this script deliberately does
    not set. Run:  bash infra/setup.sh"
  fi
  sleep 5
done

[[ -n "${READY}" ]] || die "deployed ${REVISION} but ${CANDIDATE_URL}/readyz never answered 200 (last: ${LAST_CODE}).
    Check:  gcloud run services logs read ${SERVICE} --region ${REGION}"

if [[ -n "${FIRST_DEPLOY}" ]]; then
  say "created, and serving 100% — there was no other revision"
else
  say "deployed, serving no traffic"
fi
printf '  revision   %s\n  digest     %s\n  candidate  %s\n  previous   %s\n' \
  "${REVISION}" "${DIGEST}" "${CANDIDATE_URL}" "${PREVIOUS:-<none>}"
if [[ -n "${FIRST_DEPLOY}" ]]; then
  # Do not claim "not released" here. It would be false, and the whole point of
  # this script is that the claim is true.
  printf '\n  Smoke test it:       DEPLOY_URL=%s uv run pytest -m deploy\n' "${CANDIDATE_URL}"
  printf '  Then `make release` is a formality — it will report that this\n'
  printf '  revision already serves 100%% and exit without moving anything.\n'
else
  printf '\n  Not released. Next:  DEPLOY_URL=%s uv run pytest -m deploy\n' "${CANDIDATE_URL}"
  printf '                 then:  make release\n'
fi

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
