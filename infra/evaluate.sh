#!/usr/bin/env bash
# =============================================================================
# Score an image, then bake the score into it.
#
#     make evaluate                      # scores poc-bert:dev
#     IMAGE=…/sentiment:abc1234 infra/evaluate.sh
#
# Four steps, in this order for a reason:
#
#   1. run the image                 the artifact, not the source tree
#   2. score it with run_eval.py     the same 200 examples, the same harness
#   3. gate the result               absolute floors from models.yaml
#   4. rebuild as `evaluated`        the same image, plus the report
#
# Step 4 is what makes the deployed service able to answer "what did I score?".
# CI reads that from production and refuses any candidate meaningfully worse —
# see `/metadata` in app/main.py. Without it the regression check has no
# baseline and skips silently, which is indistinguishable from passing.
#
# The image is scored by *running* it rather than by importing the code, because
# the whole premise of this project is that those are different things. A test
# suite that imports `app.model` proves the code is right; this proves the thing
# you are about to deploy is right.
#
# Both `ci.yml` and `cd.yml` call this. Two copies of a four-step sequence is
# how the two paths quietly stop agreeing about what "evaluated" means.
# =============================================================================
set -euo pipefail

IMAGE="${IMAGE:-poc-bert:dev}"
REPORT="${REPORT:-eval_report.json}"
PORT="${PORT:-}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-180}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Ask the OS for a port nobody is using. Hard-coding 8080 makes this fail when
# `make run-container` is already up, which is exactly when you want to run it.
if [[ -z "${PORT}" ]]; then
  PORT="$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
fi

CID=""
cleanup() { [[ -n "${CID}" ]] && docker rm -f "${CID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

say "starting ${IMAGE} on :${PORT}"
CID="$(docker run -d -p "${PORT}:8080" "${IMAGE}")"

# Generous: a cold container loads 268MB of weights from a freshly-mounted
# layer. tests/test_container.py allows the same for the same reason.
say "waiting for /readyz"
for _ in $(seq 1 "${STARTUP_TIMEOUT}"); do
  if body="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/readyz" 2>/dev/null)"; then
    printf '  %s\n' "${body}"
    break
  fi
  if ! docker ps -q --no-trunc | grep -q "${CID}"; then
    docker logs "${CID}" 2>&1 | tail -30
    die "the container exited before it became ready."
  fi
  sleep 1
done

curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/readyz" >/dev/null 2>&1 \
  || die "${IMAGE} never answered /readyz within ${STARTUP_TIMEOUT}s."

say "scoring against the golden set"
uv run python -m eval.run_eval --url "http://127.0.0.1:${PORT}"

[[ -s "${REPORT}" ]] || die "run_eval produced no ${REPORT}."

cleanup
CID=""

# --- bake it in ---------------------------------------------------------------
# `--target evaluated` layers ${REPORT} onto the image just measured. Every
# layer below is already built and cached, so this is a file copy, not a build.
#
# PLATFORM must match whatever built `runtime`, or Docker rebuilds the whole
# thing for the other architecture and the report gets attached to an image that
# was never scored.
say "baking the report into ${IMAGE}"
build_args=(--target evaluated -t "${IMAGE}")
[[ -n "${PLATFORM:-}" ]] && build_args+=(--platform "${PLATFORM}")
docker build "${build_args[@]}" . >/dev/null

say "evaluated"
python3 - "${REPORT}" <<'PY'
import json, sys
r = json.loads(open(sys.argv[1]).read())
print(f"  accuracy   {r['accuracy']:.4f}")
print(f"  macro F1   {r['macro_f1']:.4f}")
print(f"  p95        {r['p95_latency_ms']:.1f} ms   (where this ran — not a baseline)")
print(f"  model      {r['model_version']}")
PY
