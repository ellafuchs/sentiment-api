#!/usr/bin/env bash
# =============================================================================
# Send 100% of traffic back to the previous revision.
#
#     make rollback                              # to the one before the current
#     TO=sentiment-00003-abc make rollback       # to a specific one
#
# **Practise this before you need it.** An untested rollback path is not a
# rollback path — it is a belief about one, and incidents are a poor time to
# discover the difference. This script is run deliberately, on a working day, on
# a healthy service, so that the version used at 3am is one that has run before.
#
# Why this is fast: rolling back is a traffic change, not a deploy. The old
# revision was never deleted — it is still there, still built, still configured,
# just receiving nothing. So recovery is repointing a router, not rebuilding an
# image, and it takes seconds instead of the ten minutes a rebuild-and-redeploy
# would. That is the entire reason revisions are immutable and kept around, and
# the reason `deploy.sh` refuses to reuse a tag.
#
# What this does NOT do is revert the commit. The repository still says the bad
# version is what main wants, so the next push to main will deploy it again.
# Rolling back buys time to fix or revert the code; it is not the fix.
# =============================================================================
set -euo pipefail

PROJECT="${PROJECT:-poc-bert-mlops-460289b}"
REGION="${REGION:-me-west1}"
SERVICE="${SERVICE:-sentiment}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

describe() {
  gcloud run services describe "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" "$@"
}

CURRENT="$(describe --flatten='status.traffic[]' \
  --filter='status.traffic.percent>0' \
  --format='value(status.traffic.revisionName)' | head -1)"

[[ -n "${CURRENT}" ]] || die "no revision is serving traffic — nothing to roll back from."

# The target: newest first, skip whatever is serving now, take the next one.
# Ready-only, because rolling back onto a revision that never started is how a
# small incident becomes a large one.
if [[ -z "${TO:-}" ]]; then
  TO="$(gcloud run revisions list \
    --service="${SERVICE}" --project="${PROJECT}" --region="${REGION}" \
    --filter="status.conditions.type=Ready AND status.conditions.status=True" \
    --sort-by='~metadata.creationTimestamp' \
    --format='value(metadata.name)' | grep -v "^${CURRENT}$" | head -1)"
fi

[[ -n "${TO}" ]] || die "no earlier ready revision to roll back to.
    ${CURRENT} is the only one. There is nowhere to go — fix forward."

if [[ "${TO}" == "${CURRENT}" ]]; then
  say "${CURRENT} is already serving — nothing to do"
  exit 0
fi

SHA="$(gcloud run revisions describe "${TO}" \
  --project="${PROJECT}" --region="${REGION}" \
  --format='value(metadata.labels.git-sha)' 2>/dev/null || true)"

say "rolling back ${SERVICE}"
printf '  from  %s\n  to    %s  (%s)\n' "${CURRENT}" "${TO}" "${SHA:-no git-sha label}"

start="$(date +%s)"
gcloud run services update-traffic "${SERVICE}" \
  --project="${PROJECT}" --region="${REGION}" \
  --to-revisions="${TO}=100" --quiet >/dev/null

URL="$(describe --format='value(status.url)')"

# Prove it, rather than trusting that the traffic change took effect. The whole
# value of a rollback is that the service is answering again.
say "verifying ${URL}/readyz"
for _ in $(seq 1 24); do
  if body="$(curl -fsS --max-time 10 "${URL}/readyz" 2>/dev/null)"; then
    printf '  %s\n' "${body}"
    say "rolled back in $(($(date +%s) - start))s"
    printf '  serving  %s\n' "${TO}"
    printf '\n  The repo still points at the bad version. Revert the commit,\n'
    printf '  or the next push to main deploys it again.\n'
    exit 0
  fi
  sleep 5
done

die "traffic moved to ${TO} but ${URL}/readyz never answered.
    Check:  gcloud run services logs read ${SERVICE} --region ${REGION}"
