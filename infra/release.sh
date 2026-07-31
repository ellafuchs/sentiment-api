#!/usr/bin/env bash
# =============================================================================
# Release a deployed revision: 10% of traffic, watch, then 100%.
#
#     make release                      # release the candidate
#     REVISION=sentiment-00007-abc make release
#
# `infra/deploy.sh` created a revision serving nothing. This is the half that
# makes it matter, and it does so in two steps rather than one because the
# interesting failures are the ones that only appear under real traffic: a
# connection pool that exhausts, a memory ceiling reached at the 40th concurrent
# request, a dependency that is fine until two callers hit it at once. None of
# those are visible to a test suite, however good, because a test suite is not
# traffic.
#
# So: send it a tenth, wait, look, then commit. If the tenth misbehaves, 90% of
# callers never saw it.
#
# ---------------------------------------------------------------------------
# BE HONEST ABOUT WHAT THIS CANARY CAN SEE
#
# This service has no real users. The only traffic during the window is the
# probing this script does itself, and a 10% split means roughly a tenth of
# those probes reach the new revision — a handful of requests. That is a weak
# signal and calling it "validated in production" would be a lie.
#
# What is actually load-bearing here:
#
#   * The smoke test in `make candidate` hit the new revision directly, taking
#     100% of its own traffic. That is the strong check, and it already ran.
#   * This step adds the one thing the tagged URL cannot exercise: the real
#     serving path — the public hostname, the traffic split, the load balancer
#     picking between two revisions. Routing bugs live there and nowhere else.
#   * And it establishes the mechanism. A canary that is first attempted on the
#     day it is needed is not a canary. This one runs on every deploy, so the
#     day traffic exists it is already known to work.
#
# The moment real traffic exists, the check below should read Cloud Run's own
# request_count and latency metrics instead of these synthetic probes. That
# needs the Monitoring API, which is not enabled — a deliberate deferral, not
# an oversight.
# ---------------------------------------------------------------------------
# =============================================================================
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CANARY_PERCENT="${CANARY_PERCENT:-10}"
CANARY_SECONDS="${CANARY_SECONDS:-60}"
# The gate's own ceiling, from models.yaml. Not a second number to keep in sync.
MAX_P95_MS="${MAX_P95_MS:-300}"

# --- what are we releasing, and over what -------------------------------------
REVISION="${REVISION:-$(candidate_revision)}"

[[ -n "${REVISION}" ]] || die "no candidate revision — run \`make candidate\` first."

PREVIOUS="$(serving_revision)"

if [[ "${REVISION}" == "${PREVIOUS}" ]]; then
  say "${REVISION} is already serving 100% — nothing to release"
  exit 0
fi

URL="$(describe --format='value(status.url)')"

say "releasing ${REVISION}"
printf '  over      %s\n  url       %s\n  canary    %s%% for %ss\n' \
  "${PREVIOUS:-<nothing>}" "${URL}" "${CANARY_PERCENT}" "${CANARY_SECONDS}"

# --- step 1: a tenth ----------------------------------------------------------
# Both sides are named explicitly. `--to-revisions=NEW=10` alone would let
# gcloud decide where the other 90% goes, and "the tool picked something
# reasonable" is not a property you want in the step that decides who sees what.
say "shifting ${CANARY_PERCENT}% to ${REVISION}"
if [[ -n "${PREVIOUS}" ]]; then
  gcloud run services update-traffic "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" \
    --to-revisions="${REVISION}=${CANARY_PERCENT},${PREVIOUS}=$((100 - CANARY_PERCENT))" \
    --quiet >/dev/null
else
  # First ever release: there is no previous revision to split against, so a
  # canary has nothing to compare to and 100% is the only reachable state.
  say "no previous revision — going straight to 100%"
  gcloud run services update-traffic "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" \
    --to-revisions="${REVISION}=100" --quiet >/dev/null
  say "released"
  exit 0
fi

# --- step 2: watch ------------------------------------------------------------
say "watching for ${CANARY_SECONDS}s"

FAILURES=0
REQUESTS=0
LATENCIES="$(mktemp)"
trap 'rm -f "${LATENCIES}"' EXIT

deadline=$((SECONDS + CANARY_SECONDS))
while ((SECONDS < deadline)); do
  start="$(date +%s%N)"
  if curl -fsS --max-time 10 -X POST "${URL}/predict" \
    -H 'content-type: application/json' \
    -d '{"texts":["I love this."]}' >/dev/null 2>&1; then
    echo $(((  $(date +%s%N) - start ) / 1000000)) >>"${LATENCIES}"
  else
    FAILURES=$((FAILURES + 1))
  fi
  REQUESTS=$((REQUESTS + 1))
  sleep 1
done

# p95 by sorting and indexing. No numpy in a shell script, and for ~60 samples
# the nearest-rank definition is the honest one anyway.
P95=0
if [[ -s "${LATENCIES}" ]]; then
  n="$(wc -l <"${LATENCIES}")"
  idx=$(((n * 95 + 99) / 100))
  ((idx < 1)) && idx=1
  P95="$(sort -n "${LATENCIES}" | sed -n "${idx}p")"
fi

printf '  requests  %s\n  failures  %s\n  p95       %s ms (ceiling %s)\n' \
  "${REQUESTS}" "${FAILURES}" "${P95}" "${MAX_P95_MS}"

# --- step 3: decide -----------------------------------------------------------
# Any failure aborts. Not a rate, not a threshold: this endpoint answered every
# one of 200 golden examples and 21 container tests, so a single 5xx during a
# 60-second window is a change in kind, not degree.
if ((FAILURES > 0)); then
  say "canary failed — rolling back"
  gcloud run services update-traffic "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" \
    --to-revisions="${PREVIOUS}=100" --quiet >/dev/null
  die "${FAILURES}/${REQUESTS} requests failed during the canary.
    Traffic returned to ${PREVIOUS}. ${REVISION} is still deployed and
    inspectable at its candidate URL — it just is not serving anyone."
fi

if ((P95 > MAX_P95_MS)); then
  say "canary too slow — rolling back"
  gcloud run services update-traffic "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" \
    --to-revisions="${PREVIOUS}=100" --quiet >/dev/null
  die "p95 ${P95}ms exceeds the ${MAX_P95_MS}ms ceiling from models.yaml.
    Traffic returned to ${PREVIOUS}."
fi

# --- step 4: all of it --------------------------------------------------------
say "promoting ${REVISION} to 100%"
gcloud run services update-traffic "${SERVICE}" \
  --project="${PROJECT}" --region="${REGION}" \
  --to-revisions="${REVISION}=100" --quiet >/dev/null

say "released"
printf '  serving   %s\n  url       %s\n  rollback  make rollback   (→ %s)\n' \
  "${REVISION}" "${URL}" "${PREVIOUS}"
