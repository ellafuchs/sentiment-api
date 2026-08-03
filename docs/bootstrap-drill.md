# Phase 3.5 — Prove the bootstrap

**A rebuild drill.** You create a second, throwaway GCP project from `infra/setup.sh` alone, ship
the same image into it, prove it comes out the same, and destroy the copy. Production is never
touched.

**The output of this drill is not a working service. It is the list of manual steps you were forced
to take.** If the findings log at the bottom ends up empty, the drill was run wrong.

---

## Before you start

```bash
cd ~/drill                     # after step 1 creates it
```

Keep this guide open beside the terminal — `less docs/bootstrap-drill.md`, or in an editor. Every
step below gives you the command, **the output it should print**, and what failure looks like. If
something doesn't match, paste it into chat rather than improvising; a mismatch is a finding, and
finding them is the point.

You run every command yourself. Step 12 needs `infra/teardown.sh`, which does not exist yet — you
write it, from the requirements near the end of this guide.

### The rule this drill obeys

> **You never tear down production to test whether you can rebuild it.**
> You build a second environment from the same scripts, prove it comes out identical, and destroy
> **the copy**.

In production this discipline has names: **immutable infrastructure** (replace, never repair — this
project already does it at the app layer, where every Cloud Run revision is immutable and pinned by
digest), **ephemeral environments** (per-PR preview envs, destroyed nightly, so the *create* path
runs constantly and cannot rot), and **DR drills / game days** (Google's DiRT, AWS's GameDay).

The drill is not testing whether Google can create a Cloud Run service. It is testing whether
`infra/setup.sh` is honest, or whether there is tribal knowledge left in a shell history.

### What is not touched

- The GCP project `poc-bert-mlops-460289b` — not modified, not read from except one `curl` in step 10.
- The live service `sentiment-y3vui2lbqq-zf.a.run.app`.
- The GitHub repo, its branches, PR #2, or any GitHub `vars.*`.
- `~/prepare_work/poc_bert` — you work in a fresh clone at `~/drill`.

---

## The findings log

Fill this in **as you go**, not from memory afterwards.

| Step | Wall clock | Manual intervention needed | Evidence |
|---|---|---|---|
| 0 preflight | | | |
| 1 clone | | | |
| 2 env block | | | |
| 3 project + billing | | | |
| 4 `setup.sh` | | | |
| 5 `make push` | | | |
| 6 `make candidate` (fails) | | | |
| 7 `setup.sh` again, `make candidate` | | | |
| 8 deploy tests | | | |
| 9 `make release` | | | |
| 10 parity check | | | |
| 11 production untouched | | | |
| 12 teardown ×2 | | | |

### Predicted gaps — confirm or refute each with evidence

Do not take these on trust. Two are already confirmed by reading the code; the rest you find out.

| # | Predicted gap | Expected | Actual |
|---|---|---|---|
| 1 | `setup.sh` cannot create the project or link billing | confirmed at step 3 | |
| 2 | No teardown script exists | confirmed by reading — you write it | |
| 3 | `setup.sh` must run **twice**; nothing says so until a 403 | confirmed at step 6 | |
| 4 | **Defaults fail open** — an empty environment deploys to *production* ([Makefile:94](../Makefile#L94), [infra/lib.sh:12](../infra/lib.sh#L12), [infra/setup.sh:21](../infra/setup.sh#L21)) | confirmed by reading | |
| 5 | Eight GitHub `vars.*` were set by hand and are recorded in no file; `setup.sh` prints two of them | confirmed by reading | |
| 6 | The first-ever release has no incumbent to canary against | already handled ([infra/release.sh:168](../infra/release.sh#L168)) — confirm it | |
| 7 | The gate has no `/metadata` baseline in a fresh environment | already handled ([ci.yml](../.github/workflows/ci.yml)) — confirm it | |
| 8 | Image digests will **not** match production's | see step 10 — this is expected, not a defect | |

---

## 0 — Preflight

```bash
gcloud auth list
gcloud billing accounts list
docker info >/dev/null && echo "docker ok"
```

**Expect:** `ellapomela@gmail.com` marked `ACTIVE`; at least one billing account with `OPEN: True`
— **copy its `ACCOUNT_ID`**, you need it in step 3; and `docker ok`.

**If `gcloud billing accounts list` prints nothing:** the Cloud Billing API may need enabling on
your account, or you are authenticated as the wrong identity. Stop — without billing you cannot
link a project, and an unlinked project cannot enable the Run API.

Versions on this machine at time of writing: Google Cloud SDK 578.0.0, Docker 29.5, uv, git.

---

## 1 — A clean clone, outside the working tree

A drill run out of `~/prepare_work/poc_bert` inherits local state — a dirty tree, a stale
`eval_report.json`, an already-authenticated Docker config — and proves nothing.

```bash
git clone https://github.com/ellafuchs/sentiment-api.git ~/drill
cd ~/drill
git log --oneline -1
```

**Expect:** a clone of `main`, and the commit it prints is what every image tag in this drill will
be named after. Note it in the findings log — step 10 compares against production, and if
production is running a *different* commit the parity check needs that context.

**Note:** `main` on GitHub is currently `eda3d3f`. Anything committed locally but not pushed will
not be in this clone.

---

## 2 — The environment block

Paste this at the top of **every** shell you use for the drill. There will be more than one.

```bash
export PROJECT=poc-bert-drill-20260803
export REGION=me-west1
export REPO=poc-bert
export SERVICE=sentiment
echo "$PROJECT"
```

**Check `echo "$PROJECT"` before every destructive command.** If these are unset, the defaults in
[Makefile:94](../Makefile#L94) and [infra/lib.sh:12](../infra/lib.sh#L12) point at **production** —
that is predicted gap #4, and it is why this step is a step rather than a footnote.

A project id must be 6–30 characters, lowercase, and is **globally unique and never reusable** — if
you delete this project, that exact id is gone forever. Any date suffix works; the one above is
today's.

---

## 3 — Create the project and link billing — expected manual, finding #1

`setup.sh` cannot do this. It opens with `gcloud services list --enabled --project=…` and assumes
the project exists and pays for itself.

```bash
gcloud projects create "$PROJECT" --name="poc-bert drill"
gcloud billing projects link "$PROJECT" --billing-account=<ACCOUNT_ID>
```

**Expect:** a long-running `Create in progress…` that finishes with `Operation … finished
successfully`, then `billingEnabled: true`.

**If `projects create` is refused for quota:** you have hit the trial project limit. That is
finding #1 arriving early and harder than predicted — log it and stop; the rest of the drill needs
a project.

---

## 4 — Bootstrap the project

Leave `GITHUB_REPO` **unset**, so the WIF/CI half is skipped (out of scope — see the end).

```bash
bash infra/setup.sh
```

**Expect** roughly this, interleaved with gcloud's own `Operation … finished successfully` chatter.
`+` means "creating it now", `✓` means "already correct":

```
project poc-bert-drill-20260803, region me-west1

APIs
  + run.googleapis.com
  + artifactregistry.googleapis.com
  + logging.googleapis.com
  + iam.googleapis.com

artifact registry
  + me-west1/poc-bert

cleanup policy
  ✓ keep last 5, delete >30d  (cleanup-policy.json)
  ✓ docker credentials for me-west1-docker.pkg.dev

runtime service account
  + sentiment-run@poc-bert-drill-20260803.iam.gserviceaccount.com
  + roles/logging.logWriter

public access
  service does not exist yet — re-run after the first deploy

keyless CI auth — skipped
  Set GITHUB_REPO=owner/name to configure it. Phase 4 creates the repo.

done — next: make push && make deploy
```

**Expect it to pause and retry.** `gcloud services enable` returns as soon as the request is
accepted; the permission layer takes another 30–120s to agree. In between you will see:

```
  … not ready yet (attempt 1/8), retrying in 15s
```

That is [`retry()`](../infra/setup.sh#L55) doing its job, not a failure. It was written because
creating the registry two seconds after enabling the API failed with `IAM_PERMISSION_DENIED` — which
reads like a roles problem when nothing is wrong.

**The two lines to log:** `service does not exist yet` (this is why step 7 exists) and whether
anything needed more than 8 retry attempts.

**If it dies on the very first `gcloud services list`:** the project isn't ready or isn't linked to
billing. Re-run — `setup.sh` is idempotent by design, so a re-run is always safe.

---

## 5 — Build, score and push the image

Slow the first time: it downloads torch and the weights, builds for **amd64** (this Mac is arm64),
runs the image, scores it against the 200-example golden set over HTTP, then layers the report back
into the image so `/metadata` can answer. Budget ~10 minutes, more on a cold Docker cache.

```bash
make push
```

**Expect,** after the docker build output:

```
starting me-west1-docker.pkg.dev/poc-bert-drill-20260803/poc-bert/sentiment:<sha> on :<port>

waiting for /readyz
  {"ready":true,"model_version":"hf:distilbert-base-uncased-finetuned-sst-2-english@714eb0fa89d2","runtime":"pytorch"}

scoring against the golden set
  … eval output, ending in accuracy 0.9000 …

baking the report into …:<sha>

evaluated
```

then `docker push` layer output ending in a `sha256:…` digest.

**Two things about running an amd64 image on an arm64 Mac.** It runs under emulation, so it is
slow, and the `p95_latency_ms` in the resulting report will be inflated — possibly well past the
`max_p95_latency_ms: 300` in `models.yaml`. That does **not** block this drill: `evaluate.sh` scores
and bakes but does not gate ([infra/evaluate.sh:70](../infra/evaluate.sh#L70)), and only `accuracy`
is ever compared across deployments. Log the number anyway — if it is wild, it is worth knowing that
a locally-built image would fail its own gate in CI.

**If the container exits before becoming ready:** `evaluate.sh` dumps the last 30 log lines for you.
The usual cause is an architecture mismatch or an out-of-memory kill on a Docker Desktop with a low
memory ceiling.

---

## 6 — Deploy at zero traffic — this fails the first time, on purpose

```bash
make candidate
```

**Expect it to get most of the way and then die:**

```
resolving me-west1-docker.pkg.dev/poc-bert-drill-20260803/poc-bert/sentiment:<sha>
  tag      <sha>
  digest   sha256:…
  serving  <nothing yet>

deploying sentiment to me-west1 (no traffic)
  … gcloud deploy output …

waiting for https://candidate---sentiment-<hash>-zf.a.run.app/readyz

✗ https://candidate---sentiment-<hash>-zf.a.run.app/readyz returned 403 — the service is not public.
    Public access is a service-level IAM binding this script deliberately does
    not set. Run:  bash infra/setup.sh
```

**This is not a bug, it is the bootstrap ordering** — and it is finding #3. `deploy.sh` deliberately
does not set public access ([infra/deploy.sh:94](../infra/deploy.sh#L94)): the `allUsers` binding
belongs to the *service*, not a revision, and granting CI `run.services.setIamPolicy` would let the
deploy identity publish a private service to the internet. So the binding lives in `setup.sh` —
which skipped it in step 4, because the service did not exist yet.

**Log this:** two `setup.sh` runs are required, and nothing tells you so until a candidate returns
403. Note the wall-clock cost of learning that.

Note also what the script did *right*: it failed fast on the 403 instead of retrying for five
minutes, because a 403 will still be a 403 later.

---

## 7 — Re-run setup, then deploy again

```bash
bash infra/setup.sh
```

**Expect** every earlier line to now be a `✓`, and one new `+`:

```
public access
  + allUsers → roles/run.invoker
```

That is idempotency working — the second run changes exactly one thing.

```bash
make candidate
```

**Expect** it to reach `/readyz` and print the model's own answer, then:

```
waiting for https://candidate---sentiment-<hash>-zf.a.run.app/readyz
  {"ready":true,"model_version":"hf:distilbert-base-uncased-finetuned-sst-2-english@714eb0fa89d2","runtime":"pytorch"}

deployed, serving no traffic
  revision   sentiment-00002-xyz
  digest     sha256:…
  candidate  https://candidate---sentiment-<hash>-zf.a.run.app
  previous   <none>

  Not released. Next:  DEPLOY_URL=https://candidate---… uv run pytest -m deploy
                 then:  make release
```

**`previous <none>` is the important line.** Nothing was serving, so there is no rollback target —
which is what makes step 9 interesting.

The first request pays the cold start: image pull plus 268MB of weights, ~16s. `--no-traffic`
revisions are not kept warm.

---

## 8 — Smoke test the candidate, before any user sees it

```bash
DEPLOY_URL=$(make candidate-url) uv run pytest -m deploy
```

**Expect:** all deploy tests pass. `uv run` will sync the virtualenv first if the clone has never
had one — that is normal and adds a few seconds.

These tests exist for the four places where "the thing you tested" and "the thing that is serving"
can diverge. The one that justifies the file asserts that the deployed revision reports the
`model_version` that `models.yaml` names *in this commit* — a green pipeline that deployed the wrong
image would pass everything else.

**If `make candidate-url` prints nothing:** the candidate tag is missing, so step 7 did not finish.
Re-run `make candidate`.

---

## 9 — Release

A fresh project has no incumbent, so there is nothing to canary against.
[infra/release.sh:168](../infra/release.sh#L168) already handles this — **a predicted gap that turns
out to be handled. Confirm it, don't assume it.**

```bash
make release
```

**Expect exactly this, and nothing about a canary:**

```
no previous revision — going straight to 100%

released
```

**If instead** it starts warming up, timing a baseline and shifting 10% — then `serving_revision`
found something, which contradicts `previous <none>` in step 7. That is a real finding: log both
outputs.

---

## 10 — The parity check — this is what decides whether the drill passed

```bash
make url
curl -s "$(make url)/metadata"
```

```bash
curl -s https://sentiment-y3vui2lbqq-zf.a.run.app/metadata
```

**These must match exactly:**

| Field | Production value today |
|---|---|
| `accuracy` | `0.9` |
| `macro_f1` | `0.899749` |
| `model_version` | `hf:distilbert-base-uncased-finetuned-sst-2-english@714eb0fa89d2` |
| `n_examples` | `200` |
| `runtime` | `pytorch` |
| `evaluated` | `true` |

A rebuild that produces a *subtly different* system is exactly what this drill exists to catch. A
different `accuracy` or `model_version` from the same commit is the most valuable finding available
here — log it and stop rather than tearing down.

**These are expected to differ, and are not findings:**

- **All latency fields** (`p50/p95/max/mean_latency_ms`). Production's were measured on a CI runner;
  yours were measured on this laptop, under amd64 emulation. `/metadata` records them as provenance,
  not as a baseline, and the gate never compares them across deployments.
- **The image digest.** Correcting the original plan here: production's image was built by CI on a
  GitHub runner, yours by Docker Desktop minutes ago. The *weights* are pinned by a 40-character
  revision, but the build is not bit-reproducible — base-image resolution, wheel builds and
  timestamps all differ — so the digests will not match. Digest-level parity is a property called
  reproducible builds, which this project does not currently claim. If you want it as a goal, that
  is a new roadmap row, not a failed drill.

Also worth one `curl`:

```bash
curl -s "$(make url)/predict" -X POST -H 'content-type: application/json' \
  -d '{"text":"this is wonderful"}'
```

**Expect** `POSITIVE` with high confidence and the same `model_version`.

---

## 11 — Confirm production never moved

```bash
cd ~/prepare_work/poc_bert
unset PROJECT REGION REPO SERVICE
make drift
make url
```

**Expect** `make url` to print `https://sentiment-y3vui2lbqq-zf.a.run.app` — unchanged — and `make
drift` to name the live revision and the commit it was built from.

**Expect drift to also report undeployed and unpushed work**, because the local repo has commits
that production does not: at minimum the explainer page and the architecture page. Output like
`N commit(s) committed but NOT deployed` and `Also N commit(s) not pushed to GitHub` is **correct
and not a finding** — it is the visible cost of deploys being triggered rather than automatic.

**The one thing that would be a finding:** `make url` printing a URL that is not
`sentiment-y3vui2lbqq-zf.a.run.app`, or `drift` reporting that production moved to a revision you
did not deploy. Either means the drill leaked into production. Stop and say so.

---

## 12 — Teardown

Run the script you wrote (see the next section).

```bash
cd ~/drill
bash infra/teardown.sh
```

```bash
bash infra/teardown.sh
```

**Expect** the second run to print ticks, change nothing, and exit 0. Then confirm the copy is
really gone:

```bash
gcloud run services list --project="$PROJECT" --region="$REGION"
gcloud artifacts repositories list --project="$PROJECT" --location="$REGION"
```

**Expect** both to report nothing found.

The **project itself remains** — deliberately. Deleting it is a human decision made in the console,
because a project id is unrecoverable. An empty project with no service and no images costs nothing.

---

## `infra/teardown.sh` — you write this

There is no teardown in `infra/` today: the project can only ever go forwards. That is finding #2,
and this is the fix.

Requirements, not code. Copy the `say`/`ok`/`add`/`retry` helpers from `setup.sh` — and note that
every `gcloud … describe` guard in that script has a matching `delete` here.

**Deletes, in this order** (the service first — it holds the SA reference and the images):

```bash
gcloud run services delete "$SERVICE" --project="$PROJECT" --region="$REGION" --quiet

gcloud artifacts repositories delete "$REPO" --project="$PROJECT" --location="$REGION" --quiet

gcloud projects remove-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:sentiment-run@${PROJECT}.iam.gserviceaccount.com" \
  --role=roles/logging.logWriter --condition=None

gcloud iam service-accounts delete "sentiment-run@${PROJECT}.iam.gserviceaccount.com" \
  --project="$PROJECT" --quiet
```

**Two safety properties, because this is the only script in the repo that destroys things:**

1. **It refuses to run against `poc-bert-mlops-460289b`** — a hard deny-list, overridable only by a
   flag you have to type on purpose. Note the asymmetry with the rest of the repo: everywhere else,
   an unset `PROJECT` silently *means* production. Here that must be fatal.
2. **It never deletes the project itself.** A GCP project id is unrecoverable once deleted. That
   stays a human decision made in the console.

**Idempotent** — a second run prints ticks and changes nothing, exactly like `setup.sh`. Guard every
delete with the matching `describe`.

**How to test it, in this order:**

1. Point it at production and confirm it **refuses**. Do this first, before it has ever run
   successfully — a deny-list you test last is a deny-list you test after it could have hurt you.
2. Run it against the drill project. It should delete all four things.
3. Run it again. All ticks, exit 0, nothing changed.

---

## Afterwards — the fixes these findings imply

Write these down when the drill ends; they are the deliverable, not this guide.

- **Fail closed.** Require `PROJECT` explicitly and move the real values into a git-ignored
  `infra/env.sh` that the Makefile sources. An unset environment must refuse to deploy, not deploy
  to production.
- **Say the two-run thing out loud.** Either have `setup.sh` create the project and link billing, or
  state in its header comment why that is a human step — and that it must be run again after the
  first deploy.
- **Print all eight CI `vars.*`** as one copy-pasteable block, so the GitHub half of the bootstrap
  stops living in a shell history.
- **Add the Phase 3.5 rows** to the roadmap and the README, with the results. Not before the drill
  runs: a phase marked done before it is done makes every other row suspect.

## Out of scope

- **The WIF/CI half.** Proving CI can deploy into a fresh project needs a *second GitHub repo* — the
  WIF attribute condition pins one repo on one branch, and repointing this repo's `vars.*` would aim
  **real production CD** at a throwaway project. Later, with a throwaway repo. Never by repointing
  prod.
- **Deleting anything that exists today.**
- **Terraform.** A drill that proves `setup.sh` is complete is what makes a Terraform port
  mechanical later.

## Cost

Cloud Run scales to zero. One image is ~615MB against a 0.5GB free tier, so a second project holding
one image costs cents for a few hours, and step 12 removes it. A second project on the same billing
account is fine on the trial — if `projects create` is refused by quota, that is finding #1 arriving
early.

## Verification — the drill passed if

1. The drill service reported **`accuracy: 0.9` and the same `model_version`** as production, from
   the same commit.
2. `teardown.sh` ran twice: the second run printed only ticks and exited 0.
3. Production never moved — step 11's `make url` and `make drift` agree with what was live before
   you started.
4. The findings log has entries in it.
