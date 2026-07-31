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
