# Sentiment API

A small web service that reads a sentence and says whether it's **positive** or **negative**.

The point of the project isn't the answer — it's everything around it: which AI model answers is a
setting in a file, and changing that setting is meant to be safe, tested, and reversible.

---

## Run it

You need two terminals.

### Terminal 1 — start the service

```bash
make run
```

It prints a few lines and then **sits there doing nothing**. That's correct — it's waiting for
requests. You'll know it's up when you see `Uvicorn running on http://0.0.0.0:8080`.

Leave this terminal alone. Press `Ctrl+C` when you're done.

### Terminal 2 — ask it something

```bash
uv run python examples/client.py "the ending ruined it for me"
```

```
  NEGATIVE 0.9998  the ending ruined it for me
```

Put any sentence you like in the quotes. Sarcasm and mixed opinions ("great acting, terrible plot")
are where it struggles.

### Or use the browser

Open **http://localhost:8080/docs**

Click the green **POST /predict** bar → **Try it out** → edit the box → **Execute**. The answer
appears below under *Response body*.

That page is generated automatically from the code — nobody wrote any HTML.

---

## Score the model

With the service running in terminal 1:

```bash
make score
```

This sends 200 sentences whose correct answers are already known, then reports how many the model
got right and whether that's good enough to ship.

```
  accuracy       0.9000        90% correct
  macro F1       0.8997        balanced accuracy across both labels
  p95 latency    20.8 ms       95% of requests finished faster than this

✅ Gate passed
```

If a score falls below the limits in `models.yaml`, it says **Gate failed** and names which one.

---

## Run it in a container

A container is a box holding the service, its Python, its libraries **and** the 268 MB model — one
artifact that runs the same anywhere. Cloud Run accepts nothing else.

```bash
make build
```

First time takes about 10 minutes: it downloads torch and the model *inside* the box. After that
it's cached and takes seconds. The image is roughly **1.4 GB** — mostly torch.

```bash
make run-container
```

Same as `make run`, except nothing on your laptop is involved except Docker. Predictions come back
identical — `make score` gives the same 0.9000 accuracy either way.

```bash
make test-container
```

21 checks against the built image, over real HTTP: does it predict correctly, does it reject bad
input, does it honour `$PORT`, **does it still work with no internet at all**, is it running as
root, did any test-only packages sneak in.

That last group is the point. The tests in `tests/` check your *code*. These check the *box* — and
a perfect codebase still ships broken if the weights weren't copied in.

Recorded numbers are in [docs/architecture.md](docs/architecture.md).

---

## Put it on the internet

It already is:

```bash
curl -sS -X POST https://sentiment-y3vui2lbqq-zf.a.run.app/predict -H 'content-type: application/json' -d '{"texts":["the ending ruined it for me"]}'
```

```
{"predictions":[{"label":"NEGATIVE","score":0.9998}],"model_version":"hf:distilbert-...@714eb0fa89d2","runtime":"pytorch"}
```

That is the same container from `make build`, running in Google's Tel Aviv region, scaled to zero
when nobody is asking. It costs nothing while idle.

To deploy your own copy:

```bash
bash infra/setup.sh
```

Creates the project's registry, a cleanup policy, and a service account that can write logs and
nothing else. Idempotent — run it as often as you like.

```bash
make push
```

```bash
make deploy
```

`push` builds for `linux/amd64` (Cloud Run refuses the arm64 image your laptop builds by default) and
tags it with the current git SHA. `deploy` looks that tag up, resolves it to a **digest**, and
deploys the digest — so the question "which image is this revision running?" has exactly one answer.
It refuses to run on a dirty working tree, because a live revision that maps to no commit cannot be
reproduced.

Then grade the deployed service with the same harness that graded your laptop:

```bash
make score URL=$(make -s url)
```

```
  accuracy       0.9000
  macro F1       0.8997
  p95 latency    156.6 ms

✅ Gate passed
```

**Identical accuracy on all three** — laptop, container, cloud. Same weights, same tokenizer, same
answers. That is what baking the model into the image buys you.

---

## It deploys itself

You don't run any of those commands any more. Push to `main` and GitHub does it:

```
build  →  deploy serving 0%  →  smoke test  →  10% for 60s  →  100%
```

Roughly four minutes. The middle three steps are the interesting ones, because each can say no:

| Step | What it does | If it fails |
|---|---|---|
| **deploy** | Creates the revision on real Cloud Run hardware with its own private URL, serving nobody | Nothing changed. The old revision never stopped |
| **smoke** | `pytest -m deploy` against that private URL | Nobody ever saw it |
| **release** | 10% of traffic for 60 seconds, then all of it | Traffic goes back automatically |

The old revision stays built and configured the whole time, which is why going back is fast:

```bash
make rollback
```

That's a traffic change, not a rebuild — seconds, not the ten minutes a redeploy would take. Run it
on a good day. A rollback path you've never used is a belief, not a plan.

It's also on **Actions → Rollback → Run workflow**, which is two taps in the GitHub mobile app. Same
script, second trigger — because an emergency control that needs your laptop has a precondition
nobody checks until the emergency.

**No password is stored anywhere for this.** GitHub proves who it is with a signed token that expires
in an hour, and Google is configured to trust it — but only from this repository, only on `main`. The
usual approach is to paste a Google service-account key into a GitHub secret; that key works from
anywhere, forever, for anyone who reads it. Here there's no key to leak.

---

## It grades the model before you merge

Open a pull request and it gets scored automatically — the built image, against the same 200
sentences, judged and posted back as a comment:

```
## Gate

✅ **Gate passed**

| check | value | threshold | margin | |
|---|---:|---:|---:|:-:|
| accuracy | 0.9 | min 0.88 | +0.02 | ✅ |
| macro_f1 | 0.8997 | min 0.87 | +0.02975 | ✅ |
| p95_latency_ms | 48.3 | max 300 | +251.7 | ✅ |
| accuracy vs live | 0.9 | min 0.88 | +0.02 | ✅ |
```

The last row is the one that's easy to miss and the whole reason this exists.

Fixed limits alone aren't enough. `min_accuracy` is 0.88, so a model scoring **0.885** passes — while
being worse than the **0.900** already serving your users. Do that three times and every single PR
was "acceptable" and the model is now noticeably worse. Nobody did anything wrong; the limit just
never noticed.

So the gate also asks the **live service** what it scored, and compares. That's what
`accuracy vs live` is. The deployed container carries its own report card:

```bash
curl -s https://sentiment-y3vui2lbqq-zf.a.run.app/metadata
```

If production can't be reached, the comment says so **in bold** rather than quietly checking less.
"No baseline" and "beat the baseline" both produce a green tick, and they are not the same thing.

**The gate reports; it doesn't block.** `main` still takes direct pushes — no pull request required
for a one-line fix. That's a deliberate choice for a one-person project, written down in
[docs/architecture.md](docs/architecture.md) along with the single command that turns enforcement on
if someone else ever pushes here.

---

## The files

| File | What it does | When it runs |
|---|---|---|
| `models.yaml` | Says which AI to use, and the scores it must beat | read at startup |
| `app/fetch.py` | Downloads the AI (255 MB) | once, ever |
| `app/config.py` | Reads `models.yaml` and rejects it if it's wrong | at startup |
| `app/model.py` | Runs the AI: sentence in, label out | startup + every request |
| `app/schemas.py` | Checks requests are valid before the AI sees them | every request |
| `app/main.py` | The web part — receives requests, sends answers | every request |
| `eval/run_eval.py` | Sends the 200 test sentences, records the scores | `make score` |
| `eval/gate.py` | Reads the scores, says pass or fail | `make score` |
| `tests/` | 120 automated checks | `make test` |
| `infra/setup.sh` | Creates the Google Cloud pieces, once | by hand, rarely |
| `infra/deploy.sh` | Puts a new version there, serving nobody | every push to main |
| `infra/release.sh` | Gives it traffic, gradually | every push to main |
| `infra/rollback.sh` | Takes the traffic back | when something's wrong |
| `.github/workflows/cd.yml` | Runs those three in order | every push to main |

The AI itself lives in `.model_cache/` and is **not** in git — 255 MB of numbers doesn't belong in
version control. Git stores the *reference* to the model; the reference is three lines in
`models.yaml`.

---

## Change the model

Edit these lines in `models.yaml`:

```yaml
model:
  source: hf
  id: distilbert-base-uncased-finetuned-sst-2-english
  revision: 714eb0fa89d2f80546fda750413ed43d93601a13
```

Then:

```bash
make fetch
```

```bash
make run
```

`revision` must be the full 40-character commit id, not a branch name. A branch can change under
you; a commit can't. That's what makes "this config" always mean "these exact weights".

Some models name their answers `LABEL_0` and `LABEL_1` instead of `NEGATIVE` and `POSITIVE`. When
that happens the service refuses to start and tells you to add:

```yaml
  labels:
    0: NEGATIVE
    1: POSITIVE
```

Better a clear error at startup than confident nonsense in every answer.

---

## All commands

```bash
make help
```

| | |
|---|---|
| `make install` | Set up the Python environment |
| `make fetch` | Download the AI |
| `make run` | Start the service |
| `make test` | Run the fast tests (~3 seconds) |
| `make test-model` | Run the slow tests that load the real AI |
| `make score` | Grade the model and give a verdict |
| `make lint` | Check code style |
| `make build` | Build the container image |
| `make test-container` | Test the built image over HTTP |
| `make evaluate` | Score the built image and bake the report into it |
| `make run-container` | Serve from the image, like the cloud will |
| `make push` | Build for amd64 and push it, tagged with the git SHA |
| `make candidate` | Deploy to Cloud Run serving **no** traffic, and smoke test it |
| `make smoke` | Drive a deployed revision over HTTP (needs `DEPLOY_URL`) |
| `make release` | Give the candidate 10% of traffic, watch, then 100% |
| `make rollback` | Send traffic back to the previous revision (also: Actions → Rollback) |
| `make deploy` | `candidate` + `release` in one go |
| `make url` | Print the live service address |
| `make candidate-url` | Print the candidate revision's own address |
| `make score URL=…` | Grade whatever is listening at that address |

---

## Where things stand

| | | Phase |
|---|---|---|
| [x] | The service runs on your laptop | 0 |
| [x] | 200 test sentences and a pass/fail gate | 1 |
| [x] | Package it into a container | 2 |
| [x] | Put it on Google Cloud so it has a real web address | 3 |
| [x] | Make changing the model deploy itself automatically | 4 |
| [x] | **Make it refuse to deploy a worse model** | **5** |
| [ ] | Make it faster with a different inference engine | 7 |
| [ ] | Train your own model and run it through the same checks | 8 |

The phase numbers are the ones used in commits and `docs/`. They skip around because two phases
(0.5, 1.5) were corrections that never got a box here, and phase 6 — proving the gate *blocks* — is
a demonstration rather than a feature.

**A push to main ships it, and a pull request gets graded before it can.**

---

## Two known problems

### The model is wrong about one sentence

The model answers **POSITIVE** to *"I would not recommend this to a friend."*

It's wrong, and it's left in on purpose. One of the 25 behaviour checks fails because of it, and
deleting the check to make the tests green would hide a real weakness.

It's also the clearest illustration of why this project exists: the service returns `200 OK` with
99% confidence and is simply wrong. No error, no crash, nothing to alert on. Only a test that
already knows the right answer can catch it.

### `/healthz` doesn't work, and can't

The liveness endpoint is at **`/livez`**, not the conventional `/healthz`. That isn't a preference.

Google's edge intercepts the exact path `/healthz` on `*.run.app` and answers its own 404 before the
request reaches Cloud Run at all. Same host, same service: `/nonexistent` comes back as this app's own
JSON 404, `/healthz` comes back as a Google HTML page with no `server: Google Frontend` header and no
trace id. `/livez`, `/health`, `/live`, `/status` and `/readyz` all arrive fine.

So the endpoint passed 119 unit tests and 21 container tests while being reachable by nothing outside
the container. It was found by the deploy smoke test — the first test in this project that talks to
the *deployed* service — on the first run of that test, which is the entire argument for having one.

There's a test asserting `/healthz` stays a 404, because the natural instinct on reading `/livez` is
to correct it back, and nothing else in the suite would object.
