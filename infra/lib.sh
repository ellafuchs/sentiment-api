# shellcheck shell=bash
# =============================================================================
# Shared by deploy.sh, release.sh and rollback.sh. Not executable on its own.
#
# It exists because all three need the same two questions answered — "which
# revision is serving?" and "where is the candidate?" — and the first attempt
# wrote that query three times. One of those copies was wrong, so all three
# were, and the pipeline failed in CI on a query that had never been run
# locally. Asking a question in exactly one place is the fix.
# =============================================================================

PROJECT="${PROJECT:-poc-bert-mlops-460289b}"
REGION="${REGION:-me-west1}"
REPO="${REPO:-poc-bert}"
SERVICE="${SERVICE:-sentiment}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

describe() {
  gcloud run services describe "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" "$@"
}

# -----------------------------------------------------------------------------
# Reading the traffic list.
#
# `gcloud run services describe` accepts --format and --flatten but NOT --filter
# — it describes one resource, so gcloud considers filtering meaningless, and
# rejects the flag outright rather than ignoring it:
#
#     ERROR: unrecognized arguments: --filter=status.traffic.tag=candidate
#
# The trap is that --flatten IS accepted, so `--flatten ... --filter ...` reads
# like a working idiom (it is one, on `list`) and fails only at runtime. Parsing
# the JSON is duller and does not depend on remembering which gcloud verbs take
# which flags.
# -----------------------------------------------------------------------------
_traffic_field() {
  # $1: python expression over `t`, selecting matching entries
  # $2: field to print
  describe --format=json 2>/dev/null | python3 -c "
import sys, json
try:
    traffic = json.load(sys.stdin).get('status', {}).get('traffic', [])
except (json.JSONDecodeError, ValueError):
    traffic = []
for t in traffic:
    if ${1}:
        v = t.get('${2}')
        if v:
            print(v)
            break
"
}

# The revision actually answering users. Selected by percent, never by position:
# once a candidate tag exists the traffic list holds more than one entry and the
# tagged one sits in it at 0%, so traffic[0] can name a revision serving nobody.
serving_revision() { _traffic_field "t.get('percent', 0) > 0" revisionName; }

# The candidate's own hostname — https://candidate---<service>-<hash>.run.app —
# reachable while the service keeps answering from the old revision.
candidate_url() { _traffic_field "t.get('tag') == 'candidate'" url; }
candidate_revision() { _traffic_field "t.get('tag') == 'candidate'" revisionName; }
