# Baseline — Phase 2 (container)

The "before" numbers. Phase 7 claims ONNX Runtime is roughly 2–3× faster and 4× smaller; that
claim is unfalsifiable without these, measured the same way.

Recorded 2026-07-31 against `poc-bert:dev`, built from `models.yaml` at
`distilbert-base-uncased-finetuned-sst-2-english@714eb0fa`, PyTorch runtime, on an Apple Silicon
Mac under Docker Desktop 29.5.

## The numbers

| | Value | How |
|---|---|---|
| Image layers | **1.4 GB** (arm64) · **1.5 GB** (amd64) | `docker history`, summed |
| Cold start | **~4 s** | container start → first successful `/predict` |
| Idle memory | **306 MB** | `docker stats` after startup, no traffic |
| Accuracy | **0.9000** | `run_eval` against the container |
| Macro F1 | **0.8997** | " |
| p95 latency | **46.2 ms** | " |

Gate verdict: **passed**, p95 at 46.2 ms against a 300 ms ceiling.

**Measured on an idle machine.** The first attempt at this table recorded 150.5 ms, taken while an
amd64 cross-build was saturating the CPU in another terminal. It was wrong by 3×, and nothing in the
output said so — a latency benchmark reports whatever the machine was doing at the time. Since the
entire purpose of this file is to be the number Phase 7 is measured against, close everything else
before re-running it.

## What the layers are made of

```
                        arm64 (this laptop)     amd64 (Cloud Run)
  .venv/                     1.1 GB                 1.23 GB
    └─ torch                   635 MB                 750 MB
    └─ transformers            109 MB
    └─ sympy + networkx         92 MB
  .model_cache/                268 MB                 268 MB
  python:3.12-slim             130 MB                 130 MB
```

`sympy` and `networkx` are `torch` dependencies for symbolic shape tracing, unused at inference.
They leave with `torch` in Phase 7.

**On reading image sizes.** `docker images` reports 2.11 GB for the arm64 image and 615 MB for the
amd64 one, and those are not the same measurement — the native image is unpacked on disk, the
cross-built one is still compressed. Layer sums from `docker history` are comparable; the table
above uses those. The compressed number is the one that matters for registry storage and pull time,
the uncompressed one for disk on the node.

## Two things worth knowing

### Accuracy is identical, latency is ~2× worse

Bare metal scored accuracy 0.900 / macro-F1 0.900 / **p95 ~21 ms**. The container scores the same
quality at **p95 46.2 ms**.

Identical accuracy is the reassuring half: same weights, same tokenizer, same arithmetic. The
container did not change what the model thinks — which is exactly what an immutable artifact is
supposed to guarantee.

The latency gap is not the model. Docker Desktop on macOS is a Linux VM, so every request crosses a
virtualised network boundary; on Cloud Run — Linux on Linux — that cost does not exist. **So this
p95 is not a Cloud Run prediction.** Re-measure there. What it *is* good for is comparing against
Phase 7's ONNX number on this same machine, which is the only reason it is recorded.

A second effect is latent rather than visible here: nothing bounds concurrency. FastAPI runs the
sync `predict` in a 40-thread pool and torch spawns its own threads underneath, which on one CPU is
thread thrash rather than parallelism. It does not show up in a sequential benchmark like this one —
it shows up under real concurrent traffic. See the concurrency note in the plan.

### The image is arm64, Cloud Run is amd64

Built on Apple Silicon, `docker build` produces `linux/arm64`. **Cloud Run runs `linux/amd64` and
will refuse this image.** Phase 3 must build with `--platform linux/amd64`.

Verified rather than assumed: `docker build --platform linux/amd64` succeeds, and the amd64 torch
comes out at **750 MB** — meaning the CPU-only index in `[tool.uv.sources]` did its job. The default
PyPI wheel bundles CUDA and would have added roughly 2.5 GB for GPU support this project will never
use.

That pin is a no-op on this laptop — arm64 torch has no CUDA build to avoid — and does all its work
in production. Which is exactly the kind of difference a container is supposed to surface before it
bites, and the reason to cross-build once in Phase 2 rather than discover it in a Cloud Run log.

## Reproducing

```bash
make build
make test-container
```

```bash
make run-container
```

then, in another terminal:

```bash
make score
```

---

# Phase 3 — on Cloud Run

Recorded 2026-07-31 against revision `sentiment-00001-pkc` in `me-west1`, image `sha256:d0f6590c`
built from `eb76720`, 2 vCPU / 2 GiB, concurrency 8, `min-instances 0`, served publicly at
`https://sentiment-y3vui2lbqq-zf.a.run.app`.

## The numbers

| | Value | How |
|---|---|---|
| Accuracy | **0.9000** | `make score URL=…` — the same harness, pointed at HTTPS |
| Macro F1 | **0.8997** | " |
| p50 latency | **75.9 ms** | " |
| p95 latency | **156.6 ms** | " |
| Model load | **16.55 s** | `Started server process` → `Application startup complete`, from the logs |
| Startup probe | **1 attempt** | `Default STARTUP TCP probe succeeded after 1 attempt` |

Gate verdict: **passed**, p95 at 156.6 ms against a 300 ms ceiling.

## Accuracy did not move, and that is the whole point

| | Bare metal | Container | Cloud Run |
|---|---|---|---|
| Accuracy | 0.9000 | 0.9000 | **0.9000** |
| Macro F1 | 0.8997 | 0.8997 | **0.8997** |

Three machines and two processor architectures — an Apple Silicon laptop, a Linux VM under Docker
Desktop, an amd64 Cloud Run instance in Tel Aviv — and not one of the 200 predictions differs.
Weights baked in at build time, a digest-pinned image, and a config naming a 40-character commit are
what buy that.

## The latency numbers are not comparable

The Phase 2 section above recorded p95 46.2 ms and argued it was inflated by Docker Desktop's
virtualised network rather than being a Cloud Run prediction. It said: re-measure there.

Re-measured: **156.6 ms**. That neither confirms nor refutes the claim, because this number was taken
**from a laptop in Israel over the public internet** and carries real network RTT that neither
earlier figure had. Bare metal timed a loopback socket; the container timed a VM boundary; this times
the internet. Three different quantities wearing the same unit.

Settling it needs a client inside `me-west1`. Until someone runs that, only the accuracy row is
comparable across environments — and it is the row that matters.

## Cold start, partially measured

**16.55 s is the model-load portion only** — process start to `Application startup complete`. A true
scale-to-zero cold start also includes pulling 615 MB of image, which happens before the first log
line exists to timestamp it. Measuring the whole thing means idling the service ~15 minutes and
timing the next request. Not done.

`--cpu-boost` is on, which is why 268 MB of weights load in 16 s on an instance billed at 2 vCPU.

## The default startup probe turns out to be the right one

Cloud Run's default startup probe is TCP — it waits for something to hold port 8080. The logs show
why that is sufficient here:

```
17:36:38.069  Started server process [1]
17:36:38.069  Waiting for application startup.
17:36:54.621  Application startup complete.
17:36:54.636  Uvicorn running on http://0.0.0.0:8080
17:36:54.636  Default STARTUP TCP probe succeeded after 1 attempt
```

Uvicorn binds the port **15 ms after** `lifespan` finishes loading the model, not before. So the port
opening already means "weights are in memory", and an instance still loading is invisible to the load
balancer rather than serving errors into a canary. An HTTP probe against `/readyz` would have needed
a YAML deploy path and bought nothing.

`/readyz` still earns its place: it is what `run_eval.wait_for_ready` polls, it carries the
`model_version` every report is attributed with, and it proves the model is loaded without paying for
a forward pass to find out.

## Cost

Scales to zero, so an idle service bills nothing. The Artifact Registry cleanup policy keeps the last
5 images — the free tier is 0.5 GB and one image is 615 MB, so storage is what breaks the *next*
deploy, not this one. A few cents a month against $300 of trial credit.

The service runs as `sentiment-run`, holding `roles/logging.logWriter` and nothing else — not the
default compute account, which carries Editor.

---

# Phase 4 — it deploys itself

Recorded 2026-07-31. `github.com/ellafuchs/sentiment-api` → push to `main` →
`build → deploy at 0% → smoke test → 10% canary → 100%`.

## The numbers

| | Value | How |
|---|---|---|
| Push to live | **~4 min** | 199s for the v1 pipeline; 272s with smoke test and canary |
| Build + push | **~110 s** | amd64 on an ubuntu-latest runner, no cache |
| Deploy to `/readyz` | **~70 s** | includes the candidate's cold start |
| Canary | **60 s** | 45 probes to each side |
| Rollback | **22 s** cold, **4 s** warm | `infra/rollback.sh`, measured both ways |
| Live gate | **0.9000 / 0.8997** | `make score URL=…`, p95 83.8 ms against 300 ms |

Accuracy is the same 0.9000 / 0.8997 as bare metal, the container and Phase 3. Four environments now.

## What this phase found

Each was invisible to a green test suite, which is the argument for the phase existing.

### `/healthz` never worked in production

Google's edge intercepts that exact path on `*.run.app` and answers its own 404 before the request
reaches Cloud Run. The evidence is in the headers:

```
/readyz       200  server: Google Frontend   x-cloud-trace-context: 3a6c…
/nonexistent  404  server: Google Frontend   x-cloud-trace-context: 90a9…   {"detail":"Not Found"}
/healthz      404  (no server header, no trace id)                          <Google HTML>
```

`/nonexistent` reaches the app and gets FastAPI's JSON. `/healthz` never arrives. Probing nine
candidate paths, exactly one is intercepted — `/livez`, `/health`, `/live`, `/healthcheck`,
`/_health`, `/status`, `/ready` and `/alive` all reach the app.

So the endpoint passed 119 unit tests and 21 container tests while being unreachable by anything
outside the container. Renamed `/livez`. There is now a test asserting `/healthz` stays 404, because
the instinct on reading `/livez` is to correct it back and nothing else in the suite would object.

**It was found by `tests/test_deploy.py` on that file's first run** — the first test in this project
that talks to the deployed service rather than to the code or the image.

### `gcloud run services describe` rejects `--filter`

It describes one resource, so gcloud treats filtering as meaningless and errors rather than ignoring
it. `--flatten` *is* accepted, so `--flatten … --filter …` reads like the working `list` idiom and
fails only at runtime. That query had been written three times and run zero times. It is now written
once, in `infra/lib.sh`, parsing JSON.

A quieter variant of the same bug survived one more commit: in `cd.yml`'s summary the query was
`… | head -1`, and the exit status of a pipeline is the *last* command's — so gcloud's failure was
swallowed and the step reported success while printing nothing.

### Latency measured from CI is not latency — the third time

The first canary failed at **p95 337 ms against the 300 ms ceiling in `models.yaml`**, and rolled
itself back. The revision was fine: probed directly minutes later it answered 10/10 at ~125 ms.

The 300 ms figure was measured from a laptop in Israel. The canary measured from a GitHub runner in
the United States. Most of that 337 ms was the Atlantic.

| Phase | Number | Blamed on | Actually |
|---|---|---|---|
| 2 | 46.2 ms | the container | Docker Desktop's virtualised network |
| 3 | 156.6 ms | the cloud | the internet between a laptop and me-west1 |
| 4 | 337 ms | the revision | the distance between a CI runner and me-west1 |

Three phases, one mistake. It is not carelessness about numbers: **latency measured from somewhere is
not a property of the service**, and every fix that raises the ceiling relocates the same bug. A CI
runner's location is not knowable in advance and changes between runs.

So the canary compares instead of thresholding. Both revisions are probed from the same runner in
the same window — the candidate at its tagged URL, the baseline through the public one. Distance,
runner speed and regional weather hit both samples equally and divide out:

```
  candidate  45 requests, 0 failed, p95 144 ms      ← run from a laptop in Israel
  baseline   45 requests,           p95 136 ms
  allowed    204 ms  (150% of baseline)
```

```
  candidate  38 requests, 0 failed, p95 388 ms      ← the same two revisions, from CI
  baseline   38 requests,           p95 334 ms
  allowed    501 ms  (150% of baseline)
```

And the merged version, run against real Cloud Run with the baseline timed before the split:

```
  baseline p95          245 ms   sentiment-00016-loq     ← timed at 100%, before any traffic moved
  candidate p95         244 ms   sentiment-00019-wuj
  public p95            234 ms   10%/90% mixture
  allowed               367 ms   ceiling for this run
  public requests        44 ok / 0 failed
  candidate requests     44 ok / 0 failed
```

**Those blocks settle it.** Identical revisions, minutes apart. The absolute numbers move by 2.4×;
the ratio between them barely moves at all — 6% from the laptop, 16% from the runner, and 0.4% in the
run above. Only one of those quantities is a property of the software.

And look at the baseline row from CI: **334 ms**, for the revision that had been serving production
without complaint for hours. The original check would have failed a perfectly good deploy for being
indistinguishable from the thing already live — while reporting the number that had been serving all
along as a violation. A threshold that rejects the incumbent is not measuring the candidate.

An absolute backstop of 5000 ms stays, because a ratio alone would happily promote a revision that
is uniformly catastrophic on both sides. It is a catastrophe backstop, not a performance target —
`make score` still owns the real latency question, measured where the answer means something.

The tolerance is `max(150% of baseline, baseline + 100 ms)`. **Both** must be exceeded before a
rollback. A percentage alone punishes a fast baseline for noise: 80 ms → 130 ms is +62% and nobody
can feel it.

### 90% of the samples measured the wrong revision

The first version probed only the public URL, where the split is 90/10 — so roughly 33 of those 37
requests went to the **old** revision. Its latency was deciding the new one's fate.

The window now probes both, counted separately, because they answer different questions. The public
URL is the only thing that exercises the hostname, the split, and the load balancer choosing between
two revisions; routing bugs live there and nowhere else. The candidate's tagged URL is where every
sample is attributable to the revision under test.

The baseline is now timed *before* any traffic moves, while the old revision still has 100%. Measured
during the split it would have been contaminated by the candidate — and biased in the dangerous
direction, since a slow candidate would inflate the very number it is judged against.

Failures are counted per target, and the rollback message names which one failed and with what status
code. The original `curl -fsS … >/dev/null 2>&1` could report *that* something failed but never
*what*, leaving two revisions' logs to read through to find out whether it was a 503, a timeout or a
DNS blip.

### The timeout was below the cold start

`--max-time 10`, against the **16.55 s** model load recorded in the Phase 3 section above, on
revisions running `--min-instances 0`. The old revision had been idle, so its first request in the
window *could not* have completed. That was the single failure — and one failure aborts a release.

`tests/test_deploy.py` already used 60 s with a comment naming this exact cold start. `release.sh`
was the outlier, in the same repository, contradicting a number this project had measured and written
down.

Both revisions are now warmed before timing starts — uncounted, on a 90 s timeout — so the cold start
is paid outside the measurement rather than recorded as an outage. Probes themselves get 30 s, above
the cold start, so a slow request is recorded as *slow* instead of counted as *failed*.

**Confirmed by measurement, not inference.** The first run of the rewritten script against real Cloud
Run printed this:

```
warming up
  previous      22094ms   (cold start paid here, not counted)
  candidate      1708ms   (cold start paid here, not counted)
```

**22 seconds** for the idle previous revision's first request — worse than the 16.55 s the diagnosis
was reasoned from, and more than twice the 10 s timeout that had been applied to it. Under the old
script that single request is a failure, and one failure aborts a release. The candidate answered in
1.7 s because `deploy.sh` had just probed its `/readyz`, so it still had an instance.

That is the whole bug in four lines: the same request, on the same service, is a 22-second cold start
or a 244 ms prediction depending only on whether something warmed it first.

A failing baseline now aborts before any traffic moves. Measuring a candidate against a broken
yardstick could otherwise roll back onto a revision worse than the one it rejected.

### The shape of all three

**Every one of them compared quantities that were not the same quantity.** A ceiling from a different
continent, a p95 from a different revision, a timeout from a warm service applied to a cold one.

None were visible to any test, because all three are properties of *where and when* the measurement
is taken — and no test suite takes a measurement anywhere but where it runs.

The gate blocking a bad model is Phase 5. This was the gate blocking a good one, which costs less and
teaches the same lesson: a threshold is only as meaningful as the thing it is compared against.

## What the split bought, on its first real failure

The `fe4ff52` run failed at the deploy step. Production did not move: `sentiment-00002` kept serving,
the broken candidate sat at 0%, and the only cost was four minutes of CI. The `8ed73a7` run failed at
the canary and returned traffic automatically.

Two pipeline failures, zero user-visible impact. That is the entire argument for deploying and
releasing being separate verbs.

## Keyless, and scoped tighter than the plan asked

No service-account key exists. GitHub signs an OIDC token describing the workflow; Google exchanges
it for a one-hour credential. The trust condition is:

```
assertion.repository == 'ellafuchs/sentiment-api' && assertion.ref == 'refs/heads/main'
```

The branch clause is not in the roadmap — it was added because the repo is public. GitHub already
withholds `id-token: write` from fork pull requests, so this is not the fork hole it looks like, but
"deploy credentials exist only on main" is a much shorter claim to verify than "GitHub's fork
permission model is correct", and it costs one line.

The deployer holds `run.developer`, `artifactregistry.writer` and `iam.serviceAccountUser` — not
`run.admin`. It deliberately **cannot** call `setIamPolicy`, so CI has no power to publish a private
service to the internet. `--allow-unauthenticated` moved out of the per-deploy path and into
`infra/setup.sh`, where a human runs it; it had been a no-op logging a warning on every deploy.

## Rollback is a traffic change

Exercised for real, four times, on a healthy service:

| Path | Time | |
|---|---|---|
| `make rollback` | **22 s** | cold target |
| `make rollback` | **4 s** | target still warm |
| Actions → Rollback | **24 s** | no laptop involved |
| Actions → Rollback, `revision=…` | **~20 s** | explicit target |

Against the ~4 minutes a rebuild-and-redeploy would take. The old revision was never deleted — still
built, still configured, receiving nothing — so recovery repoints a router. That is why revisions are
immutable and kept, and why `deploy.sh` refuses to reuse a tag.

The `workflow_dispatch` trigger is not a convenience. An emergency control that requires a laptop
with authenticated gcloud has a precondition nobody checks until the emergency, and "can you get to
your machine" is a bad first question during an incident. Same script, second trigger — `make
rollback` and the workflow both call `infra/rollback.sh`, so there is no second implementation to
drift.

What it does *not* do is revert the commit. `main` still wants the bad version and the next push
deploys it again. Rolling back buys time; it is not the fix.

## What this pipeline does not check

It proves the service **works**. It does not prove the model is any **good** — `run_eval.py` and
`gate.py` run nowhere in CI, so a commit that swapped in a worse model would sail through every step
here as long as it answered 200s at a reasonable speed. That is Phase 5, below.

---

# Phase 5 — the gate in CI

`cd.yml` answers *does it work*. `ci.yml` answers *is it still any good*, which is a different
question and the one this project exists to ask.

## Two jobs, because they fail differently

| Job | What it runs | On what | Time |
|---|---|---|---|
| `check` | lint + 124 unit and contract tests | the source | ~1 min |
| `gate` | build → `test-container` → score 200 examples → judge | the artifact | ~6 min |

They run in parallel and neither gates the other. A lint error and a regression are independent
problems, and a reviewer should learn about both in one pass rather than one per push.

## The artifact reports its own scores

The chain that makes the regression check possible:

```
build runtime image  →  run it  →  score it  →  layer the report in  →  push  →  deploy
                                                       │
                                                       └─ /metadata serves it
```

`infra/evaluate.sh` owns those four steps and **both** workflows call it — `ci.yml` to judge a
candidate, `cd.yml` so the revision that reaches Cloud Run knows what it scored. That second one is
easy to skip and fatal to skip: with an unevaluated image in production the regression check has no
baseline and skips forever, which in a green check looks exactly like passing.

Verified in production:

```
$ curl -s https://sentiment-y3vui2lbqq-zf.a.run.app/metadata
  evaluated     True
  accuracy      0.9
  macro_f1      0.899749
  model         hf:distilbert-base-uncased-finetuned-sst-2-english@714eb0fa89d2
```

So "how good is the thing serving production?" is a question you ask production, not one you answer
from a wiki page or from the CI logs of whichever run you believe deployed it.

### Only accuracy crosses deployments

The gate compares `accuracy` and nothing else against the baseline, deliberately. The latency inside
a report was measured wherever that image happened to be evaluated — a particular runner, on a
particular day. Comparing it to a candidate measured somewhere else is the mistake Phases 2, 3 and 4
each made in turn; there was no reason to make it a fourth time. Latency is still gated, but against
the absolute ceiling in `models.yaml`, which is a floor on sanity rather than a comparison.

### What the extra layer costs

The deployed artifact is not byte-identical to the evaluated one — it carries one more layer. That
layer is a 2 KB JSON file: no code, no weights, no configuration the service reads to decide
anything. `/metadata` is the only thing that opens it, and `/metadata` cannot change a prediction.
Every layer below reported `CACHED` on the rebuild, so the code and weights are the same bytes.

It is a real caveat and it is the smallest one available. The alternative is a service that cannot
say what it scored.

## Absolute floors are not enough on their own

`models.yaml` sets `min_accuracy: 0.88`. A model at **0.885** clears that while being meaningfully
worse than the **0.900** already serving traffic. Ship three of those and the floor still passes.

That is how quality erodes: not in one obviously-bad PR, but one individually-acceptable one at a
time. The baseline check is what catches it — `accuracy vs live` appears as a fourth row in the
verdict whenever production answered `/metadata`.

When it did not answer, the PR comment says so **in bold**. "No baseline" and "passed the baseline"
are different claims that produce the same green check, and the one thing a gate must never do is
look like it ran when it didn't.

## The verdict goes in the PR, not the logs

`gate.py --markdown` has existed since Phase 1 and had never been called. It writes the table that
`ci.yml` posts as a comment, updated in place rather than appended, so the PR shows the current
answer instead of a scroll-back of every push.

It posts on failure too. A red X tells a reviewer that something broke; it does not tell them
accuracy fell from 0.90 to 0.885, which is exactly what they need in order to decide whether to
override.

## Least privilege, again

`ci.yml` has no `id-token: write`. It runs on pull requests — unreviewed code — and has no business
being able to obtain a credential that can deploy. Reading `/metadata` needs none, because the
service is public.

That is the same argument as the runtime account holding only `logging.logWriter`, and as CI being
unable to call `setIamPolicy`, one layer further out.
