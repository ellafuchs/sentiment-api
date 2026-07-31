# Baseline — Phase 2

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
