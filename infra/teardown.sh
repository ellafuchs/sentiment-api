#!/usr/bin/env bash
# =============================================================================
# Destroy a THROWAWAY project's resources. The only script here that deletes.
#
#     PROJECT=poc-bert-drill-20260803 bash infra/teardown.sh --dry-run
#     PROJECT=poc-bert-drill-20260803 bash infra/teardown.sh
#
# It exists for the Phase 3.5 rebuild drill (docs/bootstrap-drill.md): a second
# project is built from setup.sh alone, proved at parity with production, and
# then removed. Without a teardown the drill can only be run once, which makes
# it a story rather than a drill.
#
# Everything below is written for the person running it at speed, possibly
# nervous, possibly at the wrong hour. Five decisions are load-bearing, and each
# is the kind a future reader would tidy away:
#
# 1. IT DOES NOT SOURCE lib.sh, on purpose.
#    lib.sh:12 — like Makefile:94 and setup.sh:21 — defaults PROJECT to the
#    production project when it is unset. That fail-open default is a known
#    defect (predicted gap #4 in the drill guide). Inheriting it here would make
#    the "PROJECT must be set" check below unreachable, leaving an empty shell
#    to be caught only incidentally, and only while the deny-list literal still
#    happens to equal lib.sh's default. Two copies of the production id in two
#    files that must agree forever, where disagreement destroys production. The
#    four helpers are duplicated instead; evaluate.sh:35 already does the same.
#
# 2. IT GUARDS WITH `list --filter`, NOT `describe`.
#    `gcloud … describe` exits 1 for "absent", for "you have no permission" and
#    for "that API was never enabled" alike. A teardown that reads all three as
#    "already gone" prints four ticks and exits 0 — output identical to a clean
#    second run — when aimed at a typo'd project or run with dead credentials.
#    `list --filter` exits 0 with empty output, so "the query worked and the
#    answer is no" stops being indistinguishable from "the query failed".
#    setup.sh's guards fail toward doing the work; a teardown's fail toward
#    claiming success, so the same idiom is not safe in both directions.
#
# 3. THE ORDER IS SERVICE → REPO → BINDING → ACCOUNT.
#    Not because the service holds a lock on the images: Artifact Registry keeps
#    no lien, and deleting the repo under a live service succeeds. The reason is
#    that no intermediate state may be present-but-broken. Deleting the repo
#    first leaves a service that cannot pull — and with --min-instances 0
#    (deploy.sh:114) it is always cold, so every request 5xxs for as long as the
#    teardown takes, or forever if it dies halfway. Replace-never-repair, run
#    backwards.
#
# 4. THE IAM BINDING GOES BEFORE THE ACCOUNT.
#    Deleting a service account does not remove bindings that name it. The
#    member is rewritten to deleted:serviceAccount:…?uid=<numeric>, so
#    remove-iam-policy-binding by email then fails, the tombstone survives, and
#    the next run's guard finds nothing and prints a tick. The guard below
#    therefore passes the member string it actually found rather than rebuilding
#    it from SA_EMAIL, which makes it correct in both cases.
#
# 5. IT NEVER DELETES THE PROJECT, AND NEVER TOUCHES ~/.docker/config.json.
#    A project id is unrecoverable and globally unique forever; that stays a
#    human decision in the console. And setup.sh:113 configured a docker
#    credential helper for me-west1-docker.pkg.dev — the same host production
#    pushes to. "Undo everything setup.sh did" would break `make push` against
#    production from this laptop.
#
# What this does NOT do: delete the project, disable the four APIs, remove the
# docker credential helper, delete local images, or delete the CI/WIF half. That
# last one is detected and reported — deleting a workload identity pool
# soft-deletes it and reserves the id for 30 days, which should be something a
# person chooses, not a side effect.
# =============================================================================
set -euo pipefail

# No default for PROJECT. On purpose — see note 1 in the header.
PROJECT_RAW="${PROJECT-}"

# The rest default exactly as setup.sh:22-25, so the names match what it made.
# Note these are identical in production and in a drill project: PROJECT is the
# only variable that separates a safe run from an unsafe one, which is why it
# alone is treated this way. A wrong REGION cannot destroy the wrong thing — it
# produces a no-op, made visible by the banner and by the verify pass.
REGION="${REGION:-me-west1}"
REPO="${REPO:-poc-bert}"
SERVICE="${SERVICE:-sentiment}"
SA_NAME="${SA_NAME:-sentiment-run}"

# Exact ids that may never be torn down by this script. An array so a second
# one can be added without touching the logic.
DENY_LIST=(poc-bert-mlops-460289b)

DRY_RUN=""
ALLOW_PRODUCTION=""

# IAM is eventually consistent: a just-deleted account can still be listed for a
# few seconds. Flat 5s, unlike setup.sh's escalating n*15 — that one waits for an
# API to become usable, which takes far longer than a policy read catching up.
VERIFY_ATTEMPTS=6
VERIFY_DELAY=5

# Same vocabulary as setup.sh:39-41, so a teardown log reads like a setup log —
# except `+` (creating) becomes `-` (removing). A yellow `+` while deleting is
# actively misleading in the one log somebody reads while worried.
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
del() { printf '  \033[33m-\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  printf 'Destroy a throwaway project'"'"'s resources.\n\n'
  printf '  PROJECT=<id> bash infra/teardown.sh [--dry-run]\n\n'
  printf 'Removes, in this order: the Cloud Run service, the Artifact Registry\n'
  printf 'repo, the logging.logWriter binding, and the runtime service account.\n'
  printf 'Never deletes the project itself.\n\n'
  printf '  --dry-run                     print what would be deleted, delete nothing\n'
  printf '  --i-know-this-is-production   override the deny-list; needs a terminal\n'
  printf '                                and a typed confirmation\n'
  printf '  -h, --help                    this\n'
}

# --- arguments, fail-closed ---------------------------------------------------
# An unrecognised argument is fatal rather than ignored. `--dry-runn` must never
# silently mean "really delete".
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --i-know-this-is-production) ALLOW_PRODUCTION=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1
    Nothing was done. Run with --help.
    Note there is no --force: the deny-list override is spelled out in full." ;;
  esac
  shift
done

# --- gate 1: PROJECT is set, and is a project id -----------------------------
# Whitespace is stripped rather than trimmed, which covers a trailing \r from a
# pasted line and the newline left by PROJECT="$(cat something)". Pure bash: no
# external command runs before the gates, which is what lets them be tested
# with PATH emptied.
PROJECT="${PROJECT_RAW//[[:space:]]/}"

if [[ -z "${PROJECT}" ]]; then
  die "PROJECT is not set.
    This script has no default, deliberately: every other entry point in this
    repo falls back to the live project when PROJECT is unset, and a teardown
    must never do that.

    Set it:  export PROJECT=poc-bert-drill-YYYYMMDD"
fi

# Catches PROJECT=$(command-that-failed) leaving an error string, and any value
# starting with `-`, which gcloud would read as a flag.
if [[ ! "${PROJECT}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
  die "PROJECT=${PROJECT} is not a project id.
    Expected 6-30 characters: lowercase letter first, then letters, digits or
    hyphens, not ending in a hyphen. Nothing was done."
fi

# --- gate 2: the deny-list ---------------------------------------------------
# Case-insensitive so the list does not depend on GCP happening to reject
# uppercase ids. `shopt` is a builtin, so this still works with PATH emptied.
DENIED=""
shopt -s nocasematch
for _denied in "${DENY_LIST[@]}"; do
  if [[ "${PROJECT}" == "${_denied}" ]]; then
    DENIED=1
  fi
done
shopt -u nocasematch

if [[ -n "${DENIED}" ]]; then
  if [[ -z "${ALLOW_PRODUCTION}" ]]; then
    die "refusing to tear down ${PROJECT} — it is on the deny-list.
    This is the live project. Nothing was done, and no query was even sent.

    If you genuinely mean it, the flag is spelled out in full and requires a
    typed confirmation at a terminal."
  fi

  # A flag alone is one copy-paste away from being used by accident, and works
  # fine unattended. Requiring a TTY means this can never happen from CI, from a
  # pipeline, or from `< /dev/null` — exactly where nobody would be watching.
  if [[ ! -t 0 ]]; then
    die "--i-know-this-is-production needs an interactive terminal.
    stdin is not a TTY, so the confirmation cannot be given, and silence is not
    consent. Nothing was done."
  fi

  printf '\n\033[31m%s\033[0m\n' "About to destroy resources in ${PROJECT}, which is on the deny-list."
  printf '  service        %s (%s)\n' "${SERVICE}" "${REGION}"
  printf '  repository     %s\n' "${REPO}"
  printf '  iam binding    roles/logging.logWriter\n'
  printf '  account        %s@%s.iam.gserviceaccount.com\n' "${SA_NAME}" "${PROJECT}"
  printf '\nType the project id to confirm: '
  read -r CONFIRM
  if [[ "${CONFIRM}" != "${PROJECT}" ]]; then
    die "that did not match — nothing was done."
  fi
fi

SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
DEPLOYER="deployer@${PROJECT}.iam.gserviceaccount.com"

# --- helpers that talk to gcloud ---------------------------------------------

# Ask a read-only question and keep the answer in QUERY_OUT.
#
# Three outcomes, not two, which is the whole point (see note 2):
#   0 — the query succeeded. QUERY_OUT may legitimately be empty.
#   2 — the API is not enabled here, so the resource cannot exist.
#   die — anything else. A query that failed is never evidence of absence.
#
# stderr is discarded on the way in so gcloud's warnings cannot end up inside a
# value we compare; on failure the command is re-run to read stderr and classify.
QUERY_OUT=""
query() {
  local st err
  QUERY_OUT=""
  set +e
  QUERY_OUT="$("$@" 2>/dev/null)"
  st=$?
  set -e
  if ((st == 0)); then
    return 0
  fi

  err="$("$@" 2>&1 >/dev/null || true)"
  case "${err}" in
    *SERVICE_DISABLED* | *"has not been used in project"* | *"is not enabled"*)
      return 2
      ;;
  esac

  die "a read-only query failed, so absence cannot be assumed:
    $*

    ${err}"
}

# Everything that changes anything goes through here, and this is the only place
# --dry-run branches. So a dry run is not a simulation of the decisions — it is
# a report of the real ones. stdout is dropped because our own `-` line already
# said what is happening, and remove-iam-policy-binding echoes the entire policy;
# stderr is left alone so real failures are visible.
run() {
  if [[ -n "${DRY_RUN}" ]]; then
    printf '  \033[33m~\033[0m would run: %s\n' "$*"
    return 0
  fi
  "$@" >/dev/null
}

# Is one of the lines exactly this string? Line-by-line and exact, never a
# substring or a glob.
has_line() {
  local haystack="$1" needle="$2" line
  while IFS= read -r line; do
    if [[ "${line}" == "${needle}" ]]; then
      return 0
    fi
  done <<<"${haystack}"
  return 1
}

# Same, comparing only the last path segment. Artifact Registry returns
# projects/…/locations/…/repositories/poc-bert.
has_basename() {
  local haystack="$1" needle="$2" line
  while IFS= read -r line; do
    if [[ "${line##*/}" == "${needle}" ]]; then
      return 0
    fi
  done <<<"${haystack}"
  return 1
}

# --- what is about to happen -------------------------------------------------
say "tearing down ${PROJECT}, region ${REGION}"
if [[ -n "${DRY_RUN}" ]]; then
  printf '  \033[33mDRY RUN — nothing will be deleted\033[0m\n'
fi
printf '  will remove    service %s, repo %s, roles/logging.logWriter, %s\n' \
  "${SERVICE}" "${REPO}" "${SA_EMAIL}"
printf '  will NOT       delete the project, disable APIs, or touch ~/.docker\n'

# --- preflight ---------------------------------------------------------------
# Fatal, not skippable. Without this, an unreachable project sends every guard
# down its "absent" branch and the run ends in four ticks and exit 0 — which is
# indistinguishable from having already cleaned up.
say "preflight"

ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
if [[ -z "${ACCOUNT}" ]]; then
  die "no active gcloud credentials.
    Run:  gcloud auth login"
fi
ok "${ACCOUNT}"

PROJECT_INFO="$(gcloud projects describe "${PROJECT}" \
  --format='value(projectId,lifecycleState)' 2>/dev/null)" || PROJECT_INFO=""

if [[ -z "${PROJECT_INFO}" ]]; then
  die "cannot see project ${PROJECT}.
    It does not exist, or ${ACCOUNT} has no access to it — gcloud cannot tell
    these apart, so neither can this script. Nothing was done.

    Check:  gcloud projects list --filter=\"projectId:${PROJECT}\"
            gcloud config get-value account"
fi

FOUND_ID="${PROJECT_INFO%%$'\t'*}"
STATE="${PROJECT_INFO##*$'\t'}"

if [[ "${FOUND_ID}" != "${PROJECT}" ]]; then
  die "asked about ${PROJECT} and gcloud described ${FOUND_ID}. Refusing to
    act on a project this script did not name. Nothing was done."
fi

if [[ "${STATE}" == "DELETE_REQUESTED" ]]; then
  say "${PROJECT} is already pending deletion — nothing to tear down"
  exit 0
fi
ok "project ${PROJECT} (${STATE})"

# --- 1: the Cloud Run service ------------------------------------------------
# First, so no state exists where the service is present but cannot pull.
say "cloud run service"
if query gcloud run services list \
  --project="${PROJECT}" --region="${REGION}" \
  --filter="metadata.name=${SERVICE}" --format='value(metadata.name)'; then
  if has_line "${QUERY_OUT}" "${SERVICE}"; then
    del "${SERVICE}"
    run gcloud run services delete "${SERVICE}" \
      --project="${PROJECT}" --region="${REGION}" --quiet
  else
    ok "${SERVICE} — already gone"
  fi
else
  # query returned 2: the API was never enabled, so a service cannot exist.
  ok "${SERVICE} — Cloud Run API not enabled here, nothing to delete"
fi

# --- 2: the Artifact Registry repo -------------------------------------------
# Takes the cleanup policy and every image version with it.
say "artifact registry"
if query gcloud artifacts repositories list \
  --project="${PROJECT}" --location="${REGION}" --format='value(name)'; then
  if has_basename "${QUERY_OUT}" "${REPO}"; then
    del "${REGION}/${REPO}"
    run gcloud artifacts repositories delete "${REPO}" \
      --project="${PROJECT}" --location="${REGION}" --quiet
  else
    ok "${REGION}/${REPO} — already gone"
  fi
else
  ok "${REGION}/${REPO} — Artifact Registry API not enabled here, nothing to delete"
fi

# --- 3: the IAM binding, then 4: the account ---------------------------------
# This order matters, and note 4 in the header says why. The filter matches
# members by substring, so it finds the tombstone form too, and the exact string
# it found is what gets removed.
say "iam"
if query gcloud projects get-iam-policy "${PROJECT}" \
  --flatten='bindings[].members' \
  --filter="bindings.role=roles/logging.logWriter AND bindings.members:${SA_EMAIL}" \
  --format='value(bindings.members)'; then
  MEMBER="${QUERY_OUT%%$'\n'*}"
  if [[ -n "${MEMBER}" ]]; then
    del "roles/logging.logWriter  (${MEMBER})"
    run gcloud projects remove-iam-policy-binding "${PROJECT}" \
      --member="${MEMBER}" --role=roles/logging.logWriter --condition=None
  else
    ok "roles/logging.logWriter — already gone"
  fi
else
  ok "roles/logging.logWriter — IAM API not enabled here, nothing to delete"
fi

if query gcloud iam service-accounts list \
  --project="${PROJECT}" --filter="email=${SA_EMAIL}" --format='value(email)'; then
  if has_line "${QUERY_OUT}" "${SA_EMAIL}"; then
    del "${SA_EMAIL}"
    run gcloud iam service-accounts delete "${SA_EMAIL}" \
      --project="${PROJECT}" --quiet
  else
    ok "${SA_EMAIL} — already gone"
  fi
else
  ok "${SA_EMAIL} — IAM API not enabled here, nothing to delete"
fi

# --- the CI half: detected, reported, not deleted ----------------------------
# setup.sh only creates these when GITHUB_REPO is set, which the drill leaves
# unset — which is precisely why they would go unnoticed in a project nobody
# looks at again. An abandoned deployer account plus a WIF provider trusting a
# GitHub repo is a standing credential path into that project.
say "ci half"
LEFTOVERS=""

if query gcloud iam service-accounts list \
  --project="${PROJECT}" --filter="email=${DEPLOYER}" --format='value(email)'; then
  if has_line "${QUERY_OUT}" "${DEPLOYER}"; then
    warn "${DEPLOYER} still exists, with run.developer, artifactregistry.writer"
    warn "  and iam.serviceAccountUser. Not deleted by this script."
    LEFTOVERS=1
  fi
fi

if query gcloud iam workload-identity-pools list \
  --project="${PROJECT}" --location=global --format='value(name)'; then
  if [[ -n "${QUERY_OUT}" ]]; then
    warn "a workload identity pool still exists:"
    printf '%s\n' "${QUERY_OUT}" | while IFS= read -r _p; do
      [[ -n "${_p}" ]] && printf '      %s\n' "${_p}"
    done
    warn "  Deleting a pool reserves its id for 30 days — do it deliberately:"
    warn "  gcloud iam workload-identity-pools delete github --location=global --project=${PROJECT}"
    LEFTOVERS=1
  fi
fi

if [[ -z "${LEFTOVERS}" ]]; then
  ok "none — GITHUB_REPO was never set against this project"
fi

# --- prove it ----------------------------------------------------------------
# rollback.sh:66 does not trust update-traffic's exit code; it re-reads the
# service and polls until the outcome is real. Same idea, opposite polarity:
# re-ask all four questions independently of what the guards above concluded.
# This runs on every invocation, including a second one that deleted nothing —
# otherwise "we skipped everything" and "we are pointed at the wrong project"
# produce the same output.
if [[ -n "${DRY_RUN}" ]]; then
  say "dry run — nothing was deleted, so there is nothing to verify"
  exit 0
fi

SURVIVORS=""

check_absent() {
  SURVIVORS=""

  if query gcloud run services list \
    --project="${PROJECT}" --region="${REGION}" --format='value(metadata.name)'; then
    if has_line "${QUERY_OUT}" "${SERVICE}"; then
      SURVIVORS="${SURVIVORS} service/${SERVICE}"
    fi
  fi

  if query gcloud artifacts repositories list \
    --project="${PROJECT}" --location="${REGION}" --format='value(name)'; then
    if has_basename "${QUERY_OUT}" "${REPO}"; then
      SURVIVORS="${SURVIVORS} repository/${REPO}"
    fi
  fi

  # Every role, not just logWriter: this is where a deleted:serviceAccount
  # tombstone shows up, and where a grant nobody remembers making shows up.
  if query gcloud projects get-iam-policy "${PROJECT}" \
    --flatten='bindings[].members' \
    --filter="bindings.members:${SA_EMAIL}" \
    --format='value(bindings.role)'; then
    if [[ -n "${QUERY_OUT}" ]]; then
      SURVIVORS="${SURVIVORS} iam-binding(${QUERY_OUT%%$'\n'*})"
    fi
  fi

  if query gcloud iam service-accounts list \
    --project="${PROJECT}" --filter="email=${SA_EMAIL}" --format='value(email)'; then
    if has_line "${QUERY_OUT}" "${SA_EMAIL}"; then
      SURVIVORS="${SURVIVORS} account/${SA_EMAIL}"
    fi
  fi

  [[ -z "${SURVIVORS}" ]]
}

say "verifying"
VERIFIED=""
for _attempt in $(seq 1 "${VERIFY_ATTEMPTS}"); do
  if check_absent; then
    VERIFIED=1
    break
  fi
  printf '  … still present:%s (attempt %s/%s), waiting %ss\n' \
    "${SURVIVORS}" "${_attempt}" "${VERIFY_ATTEMPTS}" "${VERIFY_DELAY}"
  sleep "${VERIFY_DELAY}"
done

if [[ -z "${VERIFIED}" ]]; then
  die "teardown did not fully take —${SURVIVORS} still there after
    ${VERIFY_ATTEMPTS} checks.

    Look:  gcloud run services list --project=${PROJECT} --region=${REGION}
           gcloud artifacts repositories list --project=${PROJECT} --location=${REGION}
           gcloud projects get-iam-policy ${PROJECT} --flatten='bindings[].members' \\
             --filter='bindings.members:${SA_EMAIL}'
           gcloud iam service-accounts list --project=${PROJECT}"
fi

ok "no service ${SERVICE} in ${REGION}"
ok "no repository ${REPO} in ${REGION}"
ok "no policy binding mentions ${SA_EMAIL}"
ok "no service account ${SA_EMAIL}"

say "torn down in ${SECONDS}s"
printf '  The project %s still exists, and its APIs are still enabled.\n' "${PROJECT}"
printf '  Deleting a project is a console decision: the id is unrecoverable and\n'
printf '  globally unique forever, and it counts against the trial quota either\n'
printf '  way. ~/.docker/config.json and your local images were not touched.\n'
