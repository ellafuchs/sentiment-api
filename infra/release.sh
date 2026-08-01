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
# WHAT THIS MEASURES, AND AGAINST WHAT
#
# The first version of this compared the canary's p95 to `max_p95_latency_ms`
# in models.yaml and rolled back a healthy revision on its first real run. Three
# things were wrong with the measurement, and all three are worth naming because
# each is easy to write again:
#
#   * That ceiling was established by `make score` from a client sitting next to
#     me-west1. This runs from a GitHub runner on another continent and opens a
#     new TLS connection per request. docs/architecture.md already warns about
#     comparing these figures — "three quantities wearing the same unit". A
#     fixed millisecond number is not portable across measurement locations.
#
#   * At a 90/10 split, probing the public URL means ~9 of every 10 samples
#     measure the revision being REPLACED. The old revision's numbers were
#     deciding the new revision's fate.
#
#   * The 10s timeout was below the 16.55s cold start this project has recorded.
#     Both revisions scale to zero, so the first request to an idle one could
#     not succeed — and a single failure aborts a release.
#
# So now: wake both revisions first, time the CURRENT one for BASELINE_SECONDS
# before any traffic moves, then time the candidate on its own hostname during
# the split and require it to be no worse than the baseline by more than a
# margin. Distance, handshake cost and runner speed are in both numbers and
# cancel. The absolute ceiling that remains is a catastrophe backstop, not a
# performance target — `make score` still owns that question, measured properly.
# ---------------------------------------------------------------------------
# =============================================================================
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CANARY_PERCENT="${CANARY_PERCENT:-10}"
CANARY_SECONDS="${CANARY_SECONDS:-60}"

# How long to time the CURRENT revision before shifting anything. This is the
# number the candidate is judged against — see "what this measures" above.
BASELINE_SECONDS="${BASELINE_SECONDS:-20}"

# How much slower than the baseline the candidate may be. BOTH must be exceeded
# before it is refused, so a fast baseline does not trip on noise: 80ms -> 130ms
# is +62% but only +50ms, and nobody can feel it.
LATENCY_TOLERANCE="${LATENCY_TOLERANCE:-150}"  # percent of baseline
LATENCY_FLOOR_MS="${LATENCY_FLOOR_MS:-100}"    # and at least this much worse

# Not a performance target — a catastrophe backstop. If one prediction takes
# five seconds, something is broken in a way no comparison needs to establish.
ABSOLUTE_CEILING_MS="${ABSOLUTE_CEILING_MS:-5000}"

# Above the 16.55s cold start recorded in docs/architecture.md, so a request
# that wakes a scaled-to-zero instance is recorded as SLOW rather than counted
# as FAILED. tests/test_deploy.py uses 60s for the same reason; the 10s this
# used to use was below the cold start, so the first request to an idle
# revision could not succeed, and one failure aborts a release.
PROBE_TIMEOUT="${PROBE_TIMEOUT:-30}"
WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-90}"

# --- probing ------------------------------------------------------------------
# One prediction, timed. Prints "<http_code> <milliseconds>".
#
# The status code is captured rather than discarded. The previous version ran
# `curl -fsS … >/dev/null 2>&1`, which meant a rollback could report that
# something failed but never what — leaving the logs of two revisions to read
# through to find out whether it was a 503, a timeout or a DNS blip.
probe() {
  local url="$1" timeout="${2:-${PROBE_TIMEOUT}}" start code
  start="$(date +%s%N)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${timeout}" \
    -X POST "${url}/predict" \
    -H 'content-type: application/json' \
    -d '{"texts":["I love this."]}' 2>/dev/null || true)"
  [[ -n "${code}" ]] || code="000"
  printf '%s %s\n' "${code}" "$((($(date +%s%N) - start) / 1000000))"
}

# p95 by sorting and indexing. No numpy in a shell script, and for a few dozen
# samples the nearest-rank definition is the honest one anyway.
p95_of() {
  local file="$1" n idx
  [[ -s "${file}" ]] || { echo 0; return; }
  n="$(wc -l <"${file}")"
  idx=$(((n * 95 + 99) / 100))
  ((idx < 1)) && idx=1
  sort -n "${file}" | sed -n "${idx}p"
}

# Pay the cold start before the stopwatch starts.
#
# Both revisions run --min-instances 0, so an idle one has no instance at all
# and its first request waits ~16.5s for 268MB of weights to load. That is not
# a fault, and counting it as one is how a healthy release gets rolled back.
warm() {
  local label="$1" url="$2" code ms
  read -r code ms < <(probe "${url}" "${WARMUP_TIMEOUT}")
  [[ "${code}" == "200" ]] || die "${label} did not answer during warm-up — HTTP ${code} after ${ms}ms.
    ${url}/predict
    Nothing was released and no traffic moved."
  printf '  %-12s %6sms   (cold start paid here, not counted)\n' "${label}" "${ms}"
}

roll_back() {
  say "rolling back"
  gcloud run services update-traffic "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" \
    --to-revisions="${PREVIOUS}=100" --quiet >/dev/null
}

# --- what are we releasing, and over what -------------------------------------
REVISION="${REVISION:-$(candidate_revision)}"

[[ -n "${REVISION}" ]] || die "no candidate revision — run \`make candidate\` first."

PREVIOUS="$(serving_revision)"

if [[ "${REVISION}" == "${PREVIOUS}" ]]; then
  say "${REVISION} is already serving 100% — nothing to release"
  exit 0
fi

URL="$(describe --format='value(status.url)')"

# First ever release: there is no previous revision to split against, so a
# canary has nothing to compare to and 100% is the only reachable state.
if [[ -z "${PREVIOUS}" ]]; then
  say "no previous revision — going straight to 100%"
  gcloud run services update-traffic "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" \
    --to-revisions="${REVISION}=100" --quiet >/dev/null
  say "released"
  exit 0
fi

# The candidate's own hostname, which is what makes the latency attributable.
# `REVISION=… make release` can name a revision that is not the tagged
# candidate; then there is no private URL for it and the canary falls back to
# judging the public mixture, which is weaker. Said out loud rather than
# silently degraded.
CANDIDATE_URL="$(candidate_url)"
if [[ "$(candidate_revision)" != "${REVISION}" ]]; then
  CANDIDATE_URL=""
fi

say "releasing ${REVISION}"
printf '  over      %s\n  url       %s\n  canary    %s%% for %ss\n' \
  "${PREVIOUS}" "${URL}" "${CANARY_PERCENT}" "${CANARY_SECONDS}"
[[ -n "${CANDIDATE_URL}" ]] \
  && printf '  candidate %s\n' "${CANDIDATE_URL}" \
  || printf '  candidate <untagged — latency will be judged on the public mixture>\n'

# --- step 0: wake both, then time the one being replaced ----------------------
# The baseline is measured here, from this machine, over this network, seconds
# before the candidate is measured the same way. That is the whole trick: the
# ceiling in models.yaml was established by `make score` from a client next to
# me-west1, while this runs from a GitHub runner on another continent and pays a
# fresh TLS handshake per request. Comparing a number from here against a number
# from there is comparing two different quantities — which docs/architecture.md
# already warns about for the p95 figures it records.
#
# Comparing the candidate against the revision it replaces, both measured from
# the same place in the same minute, cancels all of that: distance, handshake,
# runner speed and time of day appear in both numbers.
say "warming up"
warm "previous" "${URL}"
[[ -n "${CANDIDATE_URL}" ]] && warm "candidate" "${CANDIDATE_URL}"

say "timing ${PREVIOUS} for ${BASELINE_SECONDS}s (100% traffic, before the split)"

BASELINE_LAT="$(mktemp)"
PUBLIC_LAT="$(mktemp)"
CANDIDATE_LAT="$(mktemp)"
trap 'rm -f "${BASELINE_LAT}" "${PUBLIC_LAT}" "${CANDIDATE_LAT}"' EXIT

BASELINE_FAILURES=0
deadline=$((SECONDS + BASELINE_SECONDS))
while ((SECONDS < deadline)); do
  read -r code ms < <(probe "${URL}")
  if [[ "${code}" == "200" ]]; then
    echo "${ms}" >>"${BASELINE_LAT}"
  else
    BASELINE_FAILURES=$((BASELINE_FAILURES + 1))
    printf '  \033[31m✗\033[0m HTTP %s after %sms\n' "${code}" "${ms}"
  fi
  sleep 1
done

BASELINE_P95="$(p95_of "${BASELINE_LAT}")"
printf '  baseline p95  %sms  (%s samples, %s failures)\n' \
  "${BASELINE_P95}" "$(wc -l <"${BASELINE_LAT}" | tr -d ' ')" "${BASELINE_FAILURES}"

# The thing being replaced is already failing. Releasing on top of that is not
# obviously wrong, but doing it silently is — the canary would then measure the
# candidate against a broken yardstick and could roll back onto a revision that
# is worse than what it rejected.
((BASELINE_FAILURES == 0)) || die "${PREVIOUS} failed ${BASELINE_FAILURES} of its own requests before any traffic moved.
    That is the revision currently serving users, and it is also the one a
    rollback would return to. Nothing has been released.
    Check:  gcloud run services logs read ${SERVICE} --region ${REGION}"

# --- step 1: a tenth ----------------------------------------------------------
# Both sides are named explicitly. `--to-revisions=NEW=10` alone would let
# gcloud decide where the other 90% goes, and "the tool picked something
# reasonable" is not a property you want in the step that decides who sees what.
say "shifting ${CANARY_PERCENT}% to ${REVISION}"
gcloud run services update-traffic "${SERVICE}" \
  --project="${PROJECT}" --region="${REGION}" \
  --to-revisions="${REVISION}=${CANARY_PERCENT},${PREVIOUS}=$((100 - CANARY_PERCENT))" \
  --quiet >/dev/null

# --- step 2: watch ------------------------------------------------------------
# Two targets, counted separately, because they answer different questions.
#
#   public URL      does the split route correctly and is anything erroring?
#                   This is the check the candidate's own hostname cannot make:
#                   the public name, the traffic split, the load balancer
#                   choosing between two revisions. Routing bugs live here.
#
#   candidate URL   how fast and how healthy is the revision under test?
#                   Every sample is attributable to it.
#
# Judging the candidate on public-URL samples alone was the old bug: at a 90/10
# split roughly nine in ten of them measure the revision being REPLACED, so the
# old revision's latency and the old revision's cold start decided the fate of
# the new one.
say "watching for ${CANARY_SECONDS}s"

PUBLIC_FAILURES=0
PUBLIC_REQUESTS=0
CANDIDATE_FAILURES=0
CANDIDATE_REQUESTS=0
FIRST_FAILURE=""

note_failure() {
  local target="$1" code="$2" ms="$3"
  printf '  \033[31m✗\033[0m %-9s HTTP %s after %sms\n' "${target}" "${code}" "${ms}"
  [[ -n "${FIRST_FAILURE}" ]] || FIRST_FAILURE="${target} answered HTTP ${code} after ${ms}ms"
}

deadline=$((SECONDS + CANARY_SECONDS))
while ((SECONDS < deadline)); do
  read -r code ms < <(probe "${URL}")
  PUBLIC_REQUESTS=$((PUBLIC_REQUESTS + 1))
  if [[ "${code}" == "200" ]]; then
    echo "${ms}" >>"${PUBLIC_LAT}"
  else
    PUBLIC_FAILURES=$((PUBLIC_FAILURES + 1))
    note_failure "public" "${code}" "${ms}"
  fi

  if [[ -n "${CANDIDATE_URL}" ]]; then
    read -r code ms < <(probe "${CANDIDATE_URL}")
    CANDIDATE_REQUESTS=$((CANDIDATE_REQUESTS + 1))
    if [[ "${code}" == "200" ]]; then
      echo "${ms}" >>"${CANDIDATE_LAT}"
    else
      CANDIDATE_FAILURES=$((CANDIDATE_FAILURES + 1))
      note_failure "candidate" "${code}" "${ms}"
    fi
  fi

  sleep 1
done

PUBLIC_P95="$(p95_of "${PUBLIC_LAT}")"
CANDIDATE_P95="$(p95_of "${CANDIDATE_LAT}")"

# What the verdict is actually taken on. The candidate's own p95 when there is
# one; otherwise the public mixture, which is weaker and is labelled as such.
if [[ -n "${CANDIDATE_URL}" ]]; then
  JUDGED_P95="${CANDIDATE_P95}"
  JUDGED_ON="${REVISION}"
else
  JUDGED_P95="${PUBLIC_P95}"
  JUDGED_ON="the public mixture"
fi

# What the candidate is allowed to be. Computed here rather than inside the
# verdict so the number is on screen next to the ones it judges, whichever way
# the verdict goes.
ALLOWED=0
if ((BASELINE_P95 > 0)); then
  ALLOWED_PCT=$((BASELINE_P95 * LATENCY_TOLERANCE / 100))
  ALLOWED_ABS=$((BASELINE_P95 + LATENCY_FLOOR_MS))
  ALLOWED=$((ALLOWED_PCT > ALLOWED_ABS ? ALLOWED_PCT : ALLOWED_ABS))
fi

# A p95 of 0 means no sample survived, which is not a fast revision.
show_ms() { (($1 > 0)) && printf '%6s ms' "$1" || printf '%9s' "—"; }

printf '\n  %-18s %s   %s\n' "baseline p95" "$(show_ms "${BASELINE_P95}")" "${PREVIOUS}"
if [[ -n "${CANDIDATE_URL}" ]]; then
  printf '  %-18s %s   %s\n' "candidate p95" "$(show_ms "${CANDIDATE_P95}")" "${REVISION}"
fi
printf '  %-18s %s   %s%%/%s%% mixture\n' "public p95" "$(show_ms "${PUBLIC_P95}")" \
  "${CANARY_PERCENT}" "$((100 - CANARY_PERCENT))"
((ALLOWED > 0)) && printf '  %-18s %s   ceiling for this run\n' "allowed" "$(show_ms "${ALLOWED}")"
printf '  %-18s %6s ok / %s failed\n' "public requests" \
  "$((PUBLIC_REQUESTS - PUBLIC_FAILURES))" "${PUBLIC_FAILURES}"
if [[ -n "${CANDIDATE_URL}" ]]; then
  printf '  %-18s %6s ok / %s failed\n' "candidate requests" \
    "$((CANDIDATE_REQUESTS - CANDIDATE_FAILURES))" "${CANDIDATE_FAILURES}"
fi

# --- step 3: decide -----------------------------------------------------------
# Any failure aborts. Not a rate, not a threshold: this endpoint answered every
# one of 200 golden examples and 21 container tests, so a single 5xx during a
# 60-second window is a change in kind, not degree.
#
# Aborting is the conservative act even when the failure came from the public
# mixture rather than the candidate — not promoting is always safe. What the
# message must not do is blame the wrong revision, which is why the target and
# the status code are in it.
if ((PUBLIC_FAILURES > 0 || CANDIDATE_FAILURES > 0)); then
  roll_back
  die "the canary saw ${PUBLIC_FAILURES} public and ${CANDIDATE_FAILURES} candidate failures.
    First: ${FIRST_FAILURE}
    Traffic returned to ${PREVIOUS}. ${REVISION} is still deployed and
    inspectable at its candidate URL — it just is not serving anyone.
    Both revisions were warmed before this window, so a cold start is not
    the explanation."
fi

if ((JUDGED_P95 > ABSOLUTE_CEILING_MS)); then
  roll_back
  die "p95 ${JUDGED_P95}ms on ${JUDGED_ON} is past the ${ABSOLUTE_CEILING_MS}ms backstop.
    That is not a regression, that is something broken.
    Traffic returned to ${PREVIOUS}."
fi

# The relative verdict. Both conditions must hold: proportionally worse AND
# worse by an amount anyone could notice. See the tolerance definitions above
# for why an absolute ceiling is the wrong instrument here.
if ((ALLOWED > 0 && JUDGED_P95 > ALLOWED)); then
  roll_back
  die "p95 ${JUDGED_P95}ms on ${JUDGED_ON}, against a ${BASELINE_P95}ms baseline on ${PREVIOUS}.
    That is worse by more than ${LATENCY_TOLERANCE}% of baseline AND by more than
    ${LATENCY_FLOOR_MS}ms — both, measured from this machine minutes apart, so
    network distance and TLS cost are in both numbers and cancel.
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
