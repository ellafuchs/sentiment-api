"""Metric computation. Pure functions — no HTTP, no model, no files.

Written by hand rather than pulled from scikit-learn for two reasons: it keeps
~100MB out of the runtime image, and the arithmetic behind a number that can
block a deploy is worth being able to read.

Why macro-F1 alongside accuracy: accuracy is a single number over the whole
set, so a model that is excellent on one class and poor on the other can still
post a respectable score. Macro-F1 averages the per-class F1 scores, weighting
both classes equally regardless of how many examples each has — so one bad
class drags it down and the failure becomes visible.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ClassMetrics:
    precision: float
    recall: float
    f1: float
    support: int


@dataclass(frozen=True)
class Metrics:
    accuracy: float
    macro_f1: float
    per_class: dict[str, ClassMetrics]
    confusion: dict[str, dict[str, int]] = field(default_factory=dict)
    n_examples: int = 0


def _safe_div(numerator: float, denominator: float) -> float:
    """0.0 rather than ZeroDivisionError.

    A class the model never predicts has no precision to speak of. Defining it
    as 0 is the standard convention and, importantly, keeps a degenerate model
    (everything predicted POSITIVE) scoring badly instead of crashing the gate —
    a crash is ambiguous, a low score is a verdict.
    """
    return numerator / denominator if denominator else 0.0


def compute_metrics(y_true: list[str], y_pred: list[str], labels: list[str]) -> Metrics:
    """Accuracy, per-class precision/recall/F1, macro-F1, and a confusion matrix."""
    if len(y_true) != len(y_pred):
        raise ValueError(f"length mismatch: {len(y_true)} true vs {len(y_pred)} predicted")
    if not y_true:
        raise ValueError("cannot compute metrics over an empty set")

    pairs = Counter(zip(y_true, y_pred, strict=True))
    confusion = {t: {p: pairs.get((t, p), 0) for p in labels} for t in labels}

    correct = sum(pairs[(lbl, lbl)] for lbl in labels if (lbl, lbl) in pairs)
    accuracy = correct / len(y_true)

    per_class: dict[str, ClassMetrics] = {}
    for label in labels:
        tp = pairs.get((label, label), 0)
        fp = sum(pairs.get((other, label), 0) for other in labels if other != label)
        fn = sum(pairs.get((label, other), 0) for other in labels if other != label)

        precision = _safe_div(tp, tp + fp)
        recall = _safe_div(tp, tp + fn)
        f1 = _safe_div(2 * precision * recall, precision + recall)
        per_class[label] = ClassMetrics(precision, recall, f1, support=tp + fn)

    macro_f1 = sum(m.f1 for m in per_class.values()) / len(labels)

    return Metrics(
        accuracy=accuracy,
        macro_f1=macro_f1,
        per_class=per_class,
        confusion=confusion,
        n_examples=len(y_true),
    )


def percentile(values: list[float], pct: float) -> float:
    """Linear-interpolated percentile, matching numpy.percentile's default.

    Implemented here so the eval harness has no numpy dependency of its own and
    so the p95 in a deploy-blocking report is auditable.
    """
    if not values:
        raise ValueError("cannot take a percentile of an empty list")
    if not 0 <= pct <= 100:
        raise ValueError(f"percentile must be in [0, 100], got {pct}")

    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]

    rank = (pct / 100) * (len(ordered) - 1)
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    weight = rank - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight
