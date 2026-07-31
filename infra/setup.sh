#!/usr/bin/env bash
# =============================================================================
# Project setup, written down.
#
# Every command in here has already been run by hand. That is the point: the
# script exists so the setup is reviewable and repeatable, not so it runs once.
# Clicking through a console leaves no diff, no history and nothing to hand to
# the next person — or to yourself, on the second project.
#
#     infra/setup.sh
#
# Idempotent. Every step checks before it acts, so a re-run prints ticks and
# changes nothing. Safe against a half-configured project, which is the normal
# case here.
#
# Terraform is the later upgrade. A shell script that mirrors the commands you
# actually typed is the honest first version.
# =============================================================================
set -euo pipefail

PROJECT="${PROJECT:-poc-bert-mlops-460289b}"
REGION="${REGION:-me-west1}"
REPO="${REPO:-poc-bert}"
SERVICE="${SERVICE:-sentiment}"
SA_NAME="${SA_NAME:-sentiment-run}"

SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
POLICY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cleanup-policy.json"

# run: serves the container. artifactregistry: stores it. logging: the service
# writes there. iam: needed to create the service account below.
REQUIRED_APIS=(
  run.googleapis.com
  artifactregistry.googleapis.com
  logging.googleapis.com
  iam.googleapis.com
)

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
add() { printf '  \033[33m+\033[0m %s\n' "$*"; }

# -----------------------------------------------------------------------------
# Retry anything that depends on an API having *become* usable.
#
# `gcloud services enable` returns as soon as the request is accepted. The
# permission layer takes another 30-120s to agree. In between, calls fail with
# IAM_PERMISSION_DENIED — which sends you reading about roles, where nothing is
# wrong, because your account already holds owner.
#
# This was hit for real: creating the registry two seconds after enabling the
# API failed exactly this way, and the identical command a minute later worked.
# Never treat `enable` as meaning ready.
# -----------------------------------------------------------------------------
retry() {
  local n=0 max=8 delay
  until "$@"; do
    n=$((n + 1))
    if ((n >= max)); then
      printf '  \033[31m✗\033[0m gave up after %d attempts: %s\n' "$max" "$*" >&2
      return 1
    fi
    delay=$((n * 15))
    printf '  … not ready yet (attempt %d/%d), retrying in %ds\n' "$n" "$max" "$delay"
    sleep "$delay"
  done
}

say "project ${PROJECT}, region ${REGION}"

# --- APIs --------------------------------------------------------------------
say "APIs"
enabled="$(gcloud services list --enabled --project="${PROJECT}" --format='value(config.name)')"
for api in "${REQUIRED_APIS[@]}"; do
  if grep -qx "${api}" <<<"${enabled}"; then
    ok "${api}"
  else
    add "${api}"
    gcloud services enable "${api}" --project="${PROJECT}"
  fi
done

# --- the registry ------------------------------------------------------------
# Same region as the service. A cross-region pull works, but it costs egress and
# adds seconds to a cold start — and cold start is the number this phase has to
# defend.
say "artifact registry"
if gcloud artifacts repositories describe "${REPO}" \
  --location="${REGION}" --project="${PROJECT}" >/dev/null 2>&1; then
  ok "${REGION}/${REPO}"
else
  add "${REGION}/${REPO}"
  retry gcloud artifacts repositories create "${REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --project="${PROJECT}" \
    --description="Sentiment service images, tagged by git SHA"
fi

# Storage is what breaks the *next* deploy. The free tier is 0.5GB and one image
# is ~615MB compressed, so the second image already exceeds it. Keep the five
# most recent versions; delete anything else older than 30 days.
say "cleanup policy"
gcloud artifacts repositories set-cleanup-policies "${REPO}" \
  --location="${REGION}" \
  --project="${PROJECT}" \
  --policy="${POLICY}" \
  --no-dry-run >/dev/null
ok "keep last 5, delete >30d  (${POLICY##*/})"

# Lets `docker push` authenticate to this registry as you. Rewrites
# ~/.docker/config.json; harmless to repeat.
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet 2>/dev/null
ok "docker credentials for ${REGION}-docker.pkg.dev"

# --- the runtime identity ----------------------------------------------------
# The service runs as this account, NOT the default compute service account.
#
# That default holds roles/editor: it can delete buckets, create VMs and read
# every secret in the project. A public inference endpoint has no business
# holding any of that, and "the code never calls those APIs" is a hope, not a
# control. This account gets logWriter and nothing else, because the container
# genuinely needs nothing else — the weights are baked into the image, so it
# reaches for no Google API at request time.
#
# Same argument as `USER app` in the Dockerfile, one layer further out.
say "runtime service account"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT}" >/dev/null 2>&1; then
  ok "${SA_EMAIL}"
else
  add "${SA_EMAIL}"
  retry gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT}" \
    --display-name="Sentiment service (Cloud Run runtime)" \
    --description="Runs the sentiment container. Least privilege: logs only."

  # The same propagation problem, one layer down: `create` returns before the
  # account is visible to the IAM policy API, and binding a role to it fails
  # with "Service account does not exist" — which reads like the create silently
  # failed. It didn't. Wait for it to be readable before binding.
  retry gcloud iam service-accounts describe "${SA_EMAIL}" \
    --project="${PROJECT}" >/dev/null 2>&1
fi

# Without logWriter the service still serves traffic — it just goes silent, and
# a silent service in production is its own kind of outage.
if gcloud projects get-iam-policy "${PROJECT}" \
  --flatten="bindings[].members" \
  --filter="bindings.role=roles/logging.logWriter AND bindings.members:${SA_EMAIL}" \
  --format='value(bindings.role)' 2>/dev/null | grep -q logWriter; then
  ok "roles/logging.logWriter"
else
  add "roles/logging.logWriter"
  retry gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/logging.logWriter" \
    --condition=None >/dev/null
fi

# --- public access -----------------------------------------------------------
# Anyone may call this service without credentials. That is a deliberate choice
# for a demo endpoint, bounded by --max-instances 3 in deploy.sh, and it lives
# here rather than in the deploy for two reasons.
#
# It is a property of the service, not of a revision: the binding outlives every
# deploy, so asserting it on each one is a no-op that still has to be permitted.
# And permitting it means granting CI run.services.setIamPolicy — the power to
# publish a private service to the internet — in order to re-set a flag that was
# already set. The deploy identity should not be able to change who may call the
# thing it deploys.
#
# Skipped before the service exists; re-run this script after the first deploy.
say "public access"
if gcloud run services describe "${SERVICE}" \
  --project="${PROJECT}" --region="${REGION}" >/dev/null 2>&1; then
  if gcloud run services get-iam-policy "${SERVICE}" \
    --project="${PROJECT}" --region="${REGION}" \
    --format='value(bindings.members)' 2>/dev/null | grep -q allUsers; then
    ok "allUsers → roles/run.invoker"
  else
    add "allUsers → roles/run.invoker"
    retry gcloud run services add-iam-policy-binding "${SERVICE}" \
      --project="${PROJECT}" --region="${REGION}" \
      --member=allUsers --role=roles/run.invoker >/dev/null
  fi
else
  printf '  service does not exist yet — re-run after the first deploy\n'
fi

# --- keyless CI auth ---------------------------------------------------------
# The deploy identity, for GitHub Actions. Separate from the runtime identity
# above and much more powerful, which is exactly why it must not be a key.
#
# The usual way to give CI access to GCP is to create a service-account JSON key
# and paste it into a secret. That key is a bearer credential with no expiry: it
# works from anywhere, forever, for anyone who reads it. Leaked SA keys are the
# most common serious GCP credential incident.
#
# Workload Identity Federation replaces it with nothing. GitHub already signs an
# OIDC token describing the workflow; GCP is configured to trust that issuer and
# exchange the token for a short-lived access token. There is no key to leak,
# because no key exists.
#
# The attribute condition is the part people skip. Without it, the pool trusts
# *any* GitHub repository — anyone's workflow could ask for a token and get one.
# The binding below restricts it to your repo alone.
#
# It restricts it to one *branch* of that repo too, and that part is because the
# repo is public. Repo-scoping alone would let a token be minted by any workflow
# in the repo, on any ref. GitHub already refuses `id-token: write` to pull
# requests from forks, so this is not the fork hole it looks like — but "deploy
# credentials exist only on main" is a much shorter sentence to verify than
# "GitHub's fork permission model is correct", and it costs one line.
#
# Consequence, so it isn't a surprise later: a workflow on a branch cannot
# deploy. Anything that needs to (a canary from a release branch, say) needs
# this condition widened deliberately, which is the point.
#
# Skipped until GITHUB_REPO is set, since the binding names the repo and the
# repo is created at the start of Phase 4.
if [[ -z "${GITHUB_REPO:-}" ]]; then
  say "keyless CI auth — skipped"
  printf '  Set GITHUB_REPO=owner/name to configure it. Phase 4 creates the repo.\n'
else
  say "keyless CI auth for ${GITHUB_REPO}"

  DEPLOYER="deployer@${PROJECT}.iam.gserviceaccount.com"
  POOL="${POOL:-github}"
  PROVIDER="${PROVIDER:-github-oidc}"
  DEPLOY_REF="${DEPLOY_REF:-refs/heads/main}"

  if gcloud iam service-accounts describe "${DEPLOYER}" --project="${PROJECT}" >/dev/null 2>&1; then
    ok "${DEPLOYER}"
  else
    add "${DEPLOYER}"
    retry gcloud iam service-accounts create deployer \
      --project="${PROJECT}" \
      --display-name="CI deployer (GitHub Actions via WIF)"
    retry gcloud iam service-accounts describe "${DEPLOYER}" --project="${PROJECT}" >/dev/null 2>&1
  fi

  # Exactly what a deploy needs and nothing else: update the service, push an
  # image, and act as the runtime account. Not roles/editor, not roles/owner.
  for role in roles/run.developer roles/artifactregistry.writer roles/iam.serviceAccountUser; do
    if gcloud projects get-iam-policy "${PROJECT}" \
      --flatten="bindings[].members" \
      --filter="bindings.role=${role} AND bindings.members:${DEPLOYER}" \
      --format='value(bindings.role)' 2>/dev/null | grep -q .; then
      ok "${role}"
    else
      add "${role}"
      retry gcloud projects add-iam-policy-binding "${PROJECT}" \
        --member="serviceAccount:${DEPLOYER}" \
        --role="${role}" --condition=None >/dev/null
    fi
  done

  if gcloud iam workload-identity-pools describe "${POOL}" \
    --project="${PROJECT}" --location=global >/dev/null 2>&1; then
    ok "pool ${POOL}"
  else
    add "pool ${POOL}"
    retry gcloud iam workload-identity-pools create "${POOL}" \
      --project="${PROJECT}" --location=global --display-name="GitHub Actions"
  fi

  CONDITION="assertion.repository == '${GITHUB_REPO}' && assertion.ref == '${DEPLOY_REF}'"
  MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref"

  if gcloud iam workload-identity-pools providers describe "${PROVIDER}" \
    --project="${PROJECT}" --location=global --workload-identity-pool="${POOL}" >/dev/null 2>&1; then
    # Exists — but the condition is the whole security control, so verify it
    # rather than assume. An earlier run of this script (or a hand-typed
    # command) may have left a weaker one, and a provider that trusts more than
    # you think looks exactly like one that doesn't.
    current="$(gcloud iam workload-identity-pools providers describe "${PROVIDER}" \
      --project="${PROJECT}" --location=global --workload-identity-pool="${POOL}" \
      --format='value(attributeCondition)')"
    if [[ "${current}" == "${CONDITION}" ]]; then
      ok "provider ${PROVIDER}"
    else
      add "provider ${PROVIDER} — tightening condition"
      printf '    was: %s\n    now: %s\n' "${current:-<none>}" "${CONDITION}"
      retry gcloud iam workload-identity-pools providers update-oidc "${PROVIDER}" \
        --project="${PROJECT}" --location=global \
        --workload-identity-pool="${POOL}" \
        --attribute-mapping="${MAPPING}" \
        --attribute-condition="${CONDITION}"
    fi
  else
    add "provider ${PROVIDER}"
    retry gcloud iam workload-identity-pools providers create-oidc "${PROVIDER}" \
      --project="${PROJECT}" --location=global \
      --workload-identity-pool="${POOL}" \
      --issuer-uri="https://token.actions.githubusercontent.com" \
      --attribute-mapping="${MAPPING}" \
      --attribute-condition="${CONDITION}"
  fi

  # Only this repository may impersonate the deployer.
  PROJECT_NUMBER="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')"
  PRINCIPAL="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${GITHUB_REPO}"

  retry gcloud iam service-accounts add-iam-policy-binding "${DEPLOYER}" \
    --project="${PROJECT}" \
    --member="${PRINCIPAL}" \
    --role="roles/iam.workloadIdentityUser" >/dev/null
  ok "only ${GITHUB_REPO} may impersonate ${DEPLOYER}"

  printf '\n  For cd.yml:\n'
  printf '    workload_identity_provider: projects/%s/locations/global/workloadIdentityPools/%s/providers/%s\n' \
    "${PROJECT_NUMBER}" "${POOL}" "${PROVIDER}"
  printf '    service_account: %s\n' "${DEPLOYER}"
fi

say "done — next: make push && make deploy"
