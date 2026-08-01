#!/usr/bin/env bash
# =============================================================================
# What is live, versus what you have committed.
#
#     make drift
#
# Deploys stopped being automatic, so `main` and production can now disagree.
# That is the whole cost of the trade, and this is what makes it visible instead
# of something you find out during an incident.
#
# It answers one question with evidence rather than memory: is the code running
# in Cloud Run the code you are looking at? Every revision is labelled with the
# git SHA it was built from, so this is a lookup, not an inference.
# =============================================================================
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REVISION="$(serving_revision)"
[[ -n "${REVISION}" ]] || die "nothing is serving traffic for ${SERVICE} in ${REGION}."

LIVE_SHA="$(gcloud run revisions describe "${REVISION}" \
  --project="${PROJECT}" --region="${REGION}" \
  --format='value(metadata.labels.git-sha)' 2>/dev/null || true)"

HEAD_SHA="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

say "live"
printf '  revision  %s\n  commit    %s\n' "${REVISION}" "${LIVE_SHA:-<unlabelled>}"

say "local"
printf '  branch    %s\n  commit    %s\n' "${BRANCH}" "${HEAD_SHA}"

# Unpushed work is a separate question from undeployed work, and conflating them
# is how "but I pushed it" happens.
UNPUSHED="$(git log --oneline "@{upstream}..HEAD" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"

say "drift"

if [[ -z "${LIVE_SHA}" ]]; then
  printf '  The live revision carries no git-sha label, so it cannot be traced to\n'
  printf '  a commit. It predates the label, or was deployed by hand.\n'
elif [[ "${LIVE_SHA}" == "${HEAD_SHA}" ]]; then
  ok "production is running this exact commit"
elif ! git cat-file -e "${LIVE_SHA}^{commit}" 2>/dev/null; then
  printf '  Production is running %s, which is not a commit in this repository.\n' "${LIVE_SHA}"
  printf '  Fetch, or check you are in the right clone.\n'
else
  AHEAD="$(git rev-list --count "${LIVE_SHA}..HEAD" 2>/dev/null || echo '?')"
  BEHIND="$(git rev-list --count "HEAD..${LIVE_SHA}" 2>/dev/null || echo '?')"

  if [[ "${AHEAD}" != "0" ]]; then
    printf '  \033[33m%s commit(s) committed but NOT deployed:\033[0m\n' "${AHEAD}"
    git log --oneline "${LIVE_SHA}..HEAD" | sed 's/^/    /'
  fi
  if [[ "${BEHIND}" != "0" ]]; then
    printf '  \033[33mProduction is %s commit(s) ahead of you\033[0m — someone deployed newer code.\n' \
      "${BEHIND}"
  fi
  printf '\n  Deploy what you have:  make ship\n'
fi

if [[ "${UNPUSHED}" != "0" ]]; then
  printf '\n  Also %s commit(s) not pushed to GitHub. `make ship` builds from the\n' "${UNPUSHED}"
  printf '  branch on GitHub, not your working copy, so push first or it will\n'
  printf '  deploy without them.\n'
fi
