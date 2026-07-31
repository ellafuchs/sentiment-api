"""Measure a running service against the golden set.

    uv run python -m eval.run_eval --url http://localhost:8080

Writes ``eval_report.json``: accuracy, macro-F1, p50/p95 latency, per-class
breakdown and a confusion matrix.

Two design points:

**It talks HTTP, not Python.** This harness imports nothing from ``app``. It
measures the *service*, exactly as a caller would — which means it catches
packaging faults, wrong ports, missing files in the image and startup ordering
bugs that an in-process test structurally cannot see. In CI it runs against the
real container.

**Metrics are a file, not console output.** A human reading numbers off a
terminal cannot gate a deploy; a JSON artifact can. ``gate.py`` consumes this
file.
"""

from __future__ import annotations

import argparse
import json
import time
from dataclasses import asdict
from pathlib import Path

import httpx

from eval.metrics import compute_metrics, percentile

GOLDEN_PATH = Path(__file__).resolve().parent / "data" / "golden.jsonl"
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "eval_report.json"

# Discarded before timing starts. The first few requests pay for lazily
# allocated buffers and cold caches; including them would inflate p95 with
# startup cost rather than steady-state latency.
WARMUP_REQUESTS = 5


def load_golden(path: Path) -> list[dict]:
    if not path.is_file():
        raise SystemExit(
            f"golden set not found at {path} — run `uv run python -m eval.build_golden`"
        )
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        raise SystemExit(f"{path} is empty")
    return rows


def wait_for_ready(client: httpx.Client, timeout: float) -> dict:
    """Block until the service reports it can serve, and return what it said.

    Probes ``/readyz``, which answers 200 only once the weights are loaded. The
    cheaper alternative would be a liveness check, which reports the process is
    alive while it is still several seconds from being able to answer anything;
    the more expensive one is a real prediction, which proves the same thing at
    the cost of a forward pass and conflates "not ready yet" with "inference is
    broken".

    The response carries ``model_version`` and ``runtime``, which is where the
    report's provenance comes from.
    """
    deadline = time.monotonic() + timeout
    last = "no response"
    while time.monotonic() < deadline:
        try:
            r = client.get("/readyz", timeout=60.0)
            if r.status_code == 200:
                return r.json()
            last = f"HTTP {r.status_code}: {r.text[:200]}"
        except httpx.HTTPError as exc:
            last = f"{type(exc).__name__}: {exc}"
        time.sleep(0.5)
    raise SystemExit(f"service not ready after {timeout:.0f}s — last: {last}")


def evaluate(client: httpx.Client, rows: list[dict]) -> tuple[list[str], list[str], list[float]]:
    """One request per example, timed individually.

    Deliberately not batched. A batch would measure throughput; the gate cares
    about what a single caller experiences, so we measure exactly that.
    """
    for row in rows[:WARMUP_REQUESTS]:
        client.post("/predict", json={"texts": [row["text"]]}, timeout=60.0)

    y_true: list[str] = []
    y_pred: list[str] = []
    latencies: list[float] = []

    for i, row in enumerate(rows, 1):
        start = time.perf_counter()
        response = client.post("/predict", json={"texts": [row["text"]]}, timeout=60.0)
        elapsed_ms = (time.perf_counter() - start) * 1000

        response.raise_for_status()
        body = response.json()

        y_true.append(row["label"])
        y_pred.append(body["predictions"][0]["label"])
        latencies.append(elapsed_ms)

        if i % 50 == 0:
            print(f"  {i}/{len(rows)} ...")

    return y_true, y_pred, latencies


def build_report(provenance: dict, y_true, y_pred, latencies, labels: list[str]) -> dict:
    """``provenance`` is any prediction response — it carries model_version and runtime."""
    m = compute_metrics(y_true, y_pred, labels)
    return {
        # The four numbers the gate reads.
        "accuracy": round(m.accuracy, 6),
        "macro_f1": round(m.macro_f1, 6),
        "p50_latency_ms": round(percentile(latencies, 50), 3),
        "p95_latency_ms": round(percentile(latencies, 95), 3),
        "n_examples": m.n_examples,
        # Provenance: which artifact produced these numbers. Without this a
        # report is unattributable and therefore useless for comparison.
        "model_version": provenance.get("model_version"),
        "runtime": provenance.get("runtime"),
        # Detail for humans reading the PR comment.
        "per_class": {k: asdict(v) for k, v in m.per_class.items()},
        "confusion": m.confusion,
        "mean_latency_ms": round(sum(latencies) / len(latencies), 3),
        "max_latency_ms": round(max(latencies), 3),
    }


def print_summary(report: dict) -> None:
    print(f"\n  model    {report['model_version']}  (runtime: {report['runtime']})")
    print(f"  examples {report['n_examples']}\n")
    print(f"  accuracy       {report['accuracy']:.4f}")
    print(f"  macro F1       {report['macro_f1']:.4f}")
    print(f"  p50 latency    {report['p50_latency_ms']:.1f} ms")
    print(f"  p95 latency    {report['p95_latency_ms']:.1f} ms")

    print("\n  per class:")
    print(f"    {'label':<10} {'precision':>10} {'recall':>8} {'f1':>8} {'n':>5}")
    for label, s in sorted(report["per_class"].items()):
        print(
            f"    {label:<10} {s['precision']:>10.4f} {s['recall']:>8.4f} "
            f"{s['f1']:>8.4f} {s['support']:>5}"
        )

    print("\n  confusion (rows = true, cols = predicted):")
    labels = sorted(report["confusion"])
    print(f"    {'':<10} " + " ".join(f"{c:>10}" for c in labels))
    for true_label in labels:
        cells = " ".join(f"{report['confusion'][true_label][c]:>10}" for c in labels)
        print(f"    {true_label:<10} {cells}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://localhost:8080", help="base URL of the service")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--golden", type=Path, default=GOLDEN_PATH)
    parser.add_argument("--ready-timeout", type=float, default=120.0)
    args = parser.parse_args(argv)

    rows = load_golden(args.golden)
    print(f"evaluating {args.url} against {len(rows)} examples from {args.golden.name}")

    # The golden set defines the label universe. Deliberately not asked of the
    # service: this file stays a black-box HTTP client with no knowledge of how
    # the thing it measures is built.
    labels = sorted({r["label"] for r in rows})

    with httpx.Client(base_url=args.url.rstrip("/")) as client:
        provenance = wait_for_ready(client, args.ready_timeout)
        y_true, y_pred, latencies = evaluate(client, rows)

    # A model emitting a label the golden set has never heard of would score 0
    # and look like a quality problem. It is a configuration problem, and saying
    # so here saves an hour of confusion.
    if unknown := sorted(set(y_pred) - set(labels)):
        raise SystemExit(
            f"the service returned labels {unknown}, which are not in the golden set "
            f"({labels}). These must match — check `labels` in models.yaml."
        )

    report = build_report(provenance, y_true, y_pred, latencies, labels)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    print_summary(report)
    print(f"\n  wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
