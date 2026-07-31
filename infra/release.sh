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

# -----------------------------------------------------------------------------
# WHY THIS COMPARES INSTEAD OF THRESHOLDING
#
# The first version failed the canary at "p95 337ms against the 300ms ceiling in
# models.yaml", and the revision was fine — 10/10 at ~125ms probed from a laptop
# in Israel minutes later. The 300ms number was measured from a laptop in
# Israel. The canary measured from a GitHub runner in the United States. Tel
# Aviv is a long way from Iowa, and most of that 337ms was the Atlantic.
#
# This project has now made the same mistake three times, in three phases:
#
#   Phase 2  46.2ms in the container was blamed on the model, and was Docker
#            Desktop's virtualised network
#   Phase 3  156.6ms in the cloud was compared to both, and was mostly the
#            internet between a laptop and me-west1
#   here     337ms was compared to a warm laptop-local ceiling, and was mostly
#            the distance between a CI runner and me-west1
#
# The pattern is not carelessness about numbers. It is that latency measured
# from somewhere is not a property of the service, and every fix that raises the
# ceiling just relocates the same bug. A CI runner's location is not knowable in
# advance and changes between runs.
#
# So the canary compares rather than thresholds. Both revisions are probed from
# the *same* runner in the *same* window: the candidate at its tagged URL, the
# baseline through the public one. Network distance, runner speed and regional
# weather hit both samples equally and divide out. What survives is the only
# question a canary can honestly answer — is the new one worse than the one it
# is replacing?
#
# The absolute backstop stays, set high enough to mean "broken" rather than
# "far away", because a ratio alone would happily promote a revision that is
# uniformly catastrophic on both sides.
# -----------------------------------------------------------------------------
CANARY_MAX_RATIO="${CANARY_MAX_RATIO:-150}"   # candidate p95 vs baseline, percent
CANARY_ABS_CEILING_MS="${CANARY_ABS_CEILING_MS:-3000}"

# A revision with min-instances 0 that has never taken traffic pays a cold start
# on its first request: image pull plus 16s of model load. That is a property of
# scaling to zero, not a defect in the code, and it is what produced the single
# timeout that failed the first canary. Warm it, then measure.
CANARY_WARMUP="${CANARY_WARMUP:-5}"

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
CAND_URL="$(candidate_url)"
[[ -n "${CAND_URL}" ]] || die "no candidate URL — cannot measure the new revision on its own."

abort() {
  say "canary failed — rolling back"
  gcloud run services update-traffic "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" \
    --to-revisions="${PREVIOUS}=100" --quiet >/dev/null
  die "$1
    Traffic returned to ${PREVIOUS}. ${REVISION} is still deployed and
    inspectable at ${CAND_URL} — it just is not serving anyone."
}

# One POST. Prints elapsed ms on success, nothing on failure.
probe() {
  local t
  t="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 \
    -X POST "$1/predict" -H 'content-type: application/json' \
    -d '{"texts":["I love this."]}' 2>/dev/null || true)"
  [[ "${t%% *}" == "200" ]] || return 1
  # curl reports seconds with decimals; awk rather than bash, which has no
  # floating point and would silently truncate 0.9s to 0.
  awk -v s="${t##* }" 'BEGIN { printf "%d", s * 1000 }'
}

say "warming ${REVISION} (${CANARY_WARMUP} requests, not measured)"
for _ in $(seq 1 "${CANARY_WARMUP}"); do probe "${CAND_URL}" >/dev/null || true; done

say "watching for ${CANARY_SECONDS}s"
printf '  candidate  %s\n  baseline   %s (90%% of traffic)\n' "${CAND_URL}" "${URL}"

CAND_FAILS=0
CAND_N=0
CAND_MS="$(mktemp)"
BASE_MS="$(mktemp)"
trap 'rm -f "${CAND_MS}" "${BASE_MS}"' EXIT

deadline=$((SECONDS + CANARY_SECONDS))
while ((SECONDS < deadline)); do
  if ms="$(probe "${CAND_URL}")"; then echo "${ms}" >>"${CAND_MS}"; else CAND_FAILS=$((CAND_FAILS + 1)); fi
  CAND_N=$((CAND_N + 1))
  if ms="$(probe "${URL}")"; then echo "${ms}" >>"${BASE_MS}"; fi
  sleep 1
done

# p95 by nearest rank. No numpy in a shell script, and for ~30 samples the
# nearest-rank definition is the honest one anyway.
p95() {
  [[ -s "$1" ]] || { echo 0; return; }
  local n idx
  n="$(wc -l <"$1")"
  idx=$(((n * 95 + 99) / 100))
  ((idx < 1)) && idx=1
  sort -n "$1" | sed -n "${idx}p"
}

CAND_P95="$(p95 "${CAND_MS}")"
BASE_P95="$(p95 "${BASE_MS}")"

printf '\n  candidate  %s requests, %s failed, p95 %s ms\n  baseline   %s requests, p95 %s ms\n' \
  "${CAND_N}" "${CAND_FAILS}" "${CAND_P95}" "$(wc -l <"${BASE_MS}" | tr -d ' ')" "${BASE_P95}"

# --- step 3: decide -----------------------------------------------------------
# Any failure aborts. Not a rate: this endpoint answered all 200 golden examples
# and 21 container tests, and the cold start that could legitimately time out
# was spent during warmup. A 5xx here is a change in kind, not degree.
((CAND_FAILS == 0)) || abort "${CAND_FAILS}/${CAND_N} requests to the candidate failed."

((CAND_N > 0)) || abort "the candidate was never successfully probed."

if ((BASE_P95 > 0)); then
  ALLOWED=$((BASE_P95 * CANARY_MAX_RATIO / 100))
  printf '  allowed    %s ms  (%s%% of baseline)\n' "${ALLOWED}" "${CANARY_MAX_RATIO}"
  ((CAND_P95 <= ALLOWED)) || abort \
    "candidate p95 ${CAND_P95}ms is more than ${CANARY_MAX_RATIO}% of the baseline's ${BASE_P95}ms.
    Both were measured from this machine in the same window, so the gap is the
    revision, not the network."
else
  printf '  baseline never answered — falling back to the absolute ceiling alone\n'
fi

((CAND_P95 <= CANARY_ABS_CEILING_MS)) || abort \
  "candidate p95 ${CAND_P95}ms exceeds the ${CANARY_ABS_CEILING_MS}ms backstop.
    This ceiling means 'broken', not 'far away' — a ratio alone would promote a
    revision that is uniformly catastrophic on both sides."

# --- step 4: all of it --------------------------------------------------------
say "promoting ${REVISION} to 100%"
gcloud run services update-traffic "${SERVICE}" \
  --project="${PROJECT}" --region="${REGION}" \
  --to-revisions="${REVISION}=100" --quiet >/dev/null

say "released"
printf '  serving   %s\n  url       %s\n  rollback  make rollback   (→ %s)\n' \
  "${REVISION}" "${URL}" "${PREVIOUS}"
