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

## Three things this phase found

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

**Those two blocks settle it.** Identical revisions, minutes apart. The absolute numbers move by
2.4×; the ratio between them barely moves at all — 6% from the laptop, 16% from the runner. Only one
of those quantities is a property of the software.

And look at the baseline row from CI: **334 ms**, for the revision that had been serving production
without complaint for hours. The original check would have failed a perfectly good deploy for being
indistinguishable from the thing already live — while reporting the number that had been serving all
along as a violation. A threshold that rejects the incumbent is not measuring the candidate.

An absolute backstop of 3000 ms stays, because a ratio alone would happily promote a revision that
is uniformly catastrophic on both sides. It means *broken*, not *far away*.

The warmup is the other half. A revision at `min-instances 0` that has never taken traffic pays a
cold start on its first request — image pull plus 16 s of model load — which is what produced the one
timeout that failed the first canary. Five unmeasured requests first, then measure.

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
here as long as it answered 200s at a reasonable speed. That is Phase 5.
