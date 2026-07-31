"""Build the golden eval set. Run once; its output is committed to git.

    uv run python -m eval.build_golden

Why the output is committed rather than downloaded in CI:

  * **Hermetic** — CI never depends on a dataset host being up.
  * **Versioned** — the eval set gets a git history. When someone asks "did the
    model improve, or did the test set change?", `git log` answers it. That
    question is unanswerable if the data is fetched fresh each run.
  * **Reviewable** — changing what you measure shows up as a diff in a PR,
    which is exactly the scrutiny a change to your yardstick deserves.

The build is deterministic: fixed seed, fixed sort order, balanced classes. Two
runs on different machines produce a byte-identical file, so a spurious diff
here means something real changed.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

# SST-2: the Stanford Sentiment Treebank, single-sentence movie-review snippets.
# We use the *validation* split (872 examples) — held out from training — and
# sample a balanced subset for speed.
DATASET = ("nyu-mll/glue", "sst2")
SPLIT = "validation"
N_PER_CLASS = 100
SEED = 20260731

# SST-2 encodes 0 = negative, 1 = positive. This mapping is the dataset's, and
# is independent of whatever a given checkpoint calls its own output classes —
# reconciling those two is exactly what models.yaml `labels` exists for.
DATASET_LABELS = {0: "NEGATIVE", 1: "POSITIVE"}

OUTPUT = Path(__file__).resolve().parent / "data" / "golden.jsonl"


def main() -> int:
    from datasets import load_dataset

    print(f"loading {'/'.join(DATASET)} [{SPLIT}] ...")
    rows = list(load_dataset(*DATASET, split=SPLIT))

    by_class: dict[int, list[dict]] = {0: [], 1: []}
    for row in rows:
        text = row["sentence"].strip()
        # Drop fragments too short to carry sentiment; they add label noise
        # without testing anything, and noise in the gate is worse than a
        # smaller gate.
        if len(text) >= 10:
            by_class[row["label"]].append({"text": text, "label": DATASET_LABELS[row["label"]]})

    rng = random.Random(SEED)
    selected: list[dict] = []
    for label, items in sorted(by_class.items()):
        if len(items) < N_PER_CLASS:
            raise SystemExit(f"only {len(items)} examples for class {label}, need {N_PER_CLASS}")
        selected.extend(rng.sample(items, N_PER_CLASS))

    # Sort by text so the file has a stable order regardless of sampling.
    # Without this, re-running produces a huge meaningless diff.
    selected.sort(key=lambda r: r["text"])

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w") as fh:
        for row in selected:
            fh.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")

    counts = {lbl: sum(r["label"] == lbl for r in selected) for lbl in DATASET_LABELS.values()}
    print(f"wrote {len(selected)} examples to {OUTPUT}")
    print(f"  class balance: {counts}")
    print(f"  mean length:   {sum(len(r['text']) for r in selected) / len(selected):.0f} chars")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
