"""Metric arithmetic tests.

These numbers decide whether a deploy is blocked, so the arithmetic behind them
gets checked against cases worked out by hand rather than against whatever the
implementation happens to produce.
"""

from __future__ import annotations

import pytest

from eval.metrics import compute_metrics, percentile

LABELS = ["NEGATIVE", "POSITIVE"]


def test_perfect_predictions():
    m = compute_metrics(["POSITIVE", "NEGATIVE"], ["POSITIVE", "NEGATIVE"], LABELS)
    assert m.accuracy == 1.0
    assert m.macro_f1 == 1.0


def test_everything_wrong():
    m = compute_metrics(["POSITIVE", "NEGATIVE"], ["NEGATIVE", "POSITIVE"], LABELS)
    assert m.accuracy == 0.0
    assert m.macro_f1 == 0.0


def test_accuracy_is_fraction_correct():
    y_true = ["POSITIVE"] * 10
    y_pred = ["POSITIVE"] * 7 + ["NEGATIVE"] * 3
    assert compute_metrics(y_true, y_pred, LABELS).accuracy == 0.7


def test_worked_example_by_hand():
    """8 true POSITIVE (6 caught), 8 true NEGATIVE (7 caught).

    POSITIVE: tp=6 fp=1 fn=2 -> P=6/7=.857  R=6/8=.750  F1=.800
    NEGATIVE: tp=7 fp=2 fn=1 -> P=7/9=.778  R=7/8=.875  F1=.824
    macro F1 = (.800 + .824) / 2 = .812
    accuracy = 13/16 = .8125
    """
    y_true = ["POSITIVE"] * 8 + ["NEGATIVE"] * 8
    y_pred = ["POSITIVE"] * 6 + ["NEGATIVE"] * 2 + ["NEGATIVE"] * 7 + ["POSITIVE"] * 1

    m = compute_metrics(y_true, y_pred, LABELS)
    assert m.accuracy == pytest.approx(0.8125)
    assert m.per_class["POSITIVE"].precision == pytest.approx(6 / 7, abs=1e-4)
    assert m.per_class["POSITIVE"].recall == pytest.approx(0.75)
    assert m.per_class["POSITIVE"].f1 == pytest.approx(0.8, abs=1e-4)
    assert m.per_class["NEGATIVE"].f1 == pytest.approx(0.8235, abs=1e-4)
    assert m.macro_f1 == pytest.approx(0.8118, abs=1e-4)


def test_macro_f1_punishes_a_degenerate_model():
    """The reason macro-F1 is in the gate at all.

    A model that always answers POSITIVE on a 90/10 split scores 90% accuracy —
    which sounds fine — while being completely useless. Macro-F1 sees through it.
    """
    y_true = ["POSITIVE"] * 90 + ["NEGATIVE"] * 10
    y_pred = ["POSITIVE"] * 100

    m = compute_metrics(y_true, y_pred, LABELS)
    assert m.accuracy == 0.9
    assert m.macro_f1 < 0.5
    assert m.per_class["NEGATIVE"].recall == 0.0


def test_never_predicted_class_scores_zero_not_crash():
    """A class the model never emits has no precision. 0.0 is a verdict; a crash is not."""
    m = compute_metrics(["NEGATIVE", "NEGATIVE"], ["POSITIVE", "POSITIVE"], LABELS)
    assert m.per_class["POSITIVE"].precision == 0.0
    assert m.per_class["NEGATIVE"].recall == 0.0


def test_support_counts_true_examples():
    y_true = ["POSITIVE"] * 3 + ["NEGATIVE"] * 7
    m = compute_metrics(y_true, ["POSITIVE"] * 10, LABELS)
    assert m.per_class["POSITIVE"].support == 3
    assert m.per_class["NEGATIVE"].support == 7


def test_confusion_matrix_shape_and_totals():
    y_true = ["POSITIVE"] * 8 + ["NEGATIVE"] * 8
    y_pred = ["POSITIVE"] * 6 + ["NEGATIVE"] * 2 + ["NEGATIVE"] * 7 + ["POSITIVE"] * 1

    conf = compute_metrics(y_true, y_pred, LABELS).confusion
    assert conf["POSITIVE"]["POSITIVE"] == 6
    assert conf["POSITIVE"]["NEGATIVE"] == 2
    assert conf["NEGATIVE"]["NEGATIVE"] == 7
    assert conf["NEGATIVE"]["POSITIVE"] == 1
    assert sum(sum(r.values()) for r in conf.values()) == 16


def test_length_mismatch_is_rejected():
    with pytest.raises(ValueError, match="length mismatch"):
        compute_metrics(["POSITIVE"], ["POSITIVE", "NEGATIVE"], LABELS)


def test_empty_input_is_rejected():
    with pytest.raises(ValueError, match="empty set"):
        compute_metrics([], [], LABELS)


# --------------------------------------------------------------------------
# percentile
# --------------------------------------------------------------------------


def test_percentile_matches_numpy_default():
    """Cross-checked against numpy.percentile, which uses linear interpolation."""
    import numpy as np

    values = [12.0, 5.0, 88.0, 31.0, 7.0, 19.0, 44.0, 2.0, 63.0, 25.0]
    for pct in (0, 25, 50, 75, 90, 95, 99, 100):
        assert percentile(values, pct) == pytest.approx(float(np.percentile(values, pct)))


def test_percentile_of_single_value():
    assert percentile([42.0], 95) == 42.0


def test_percentile_bounds():
    values = [1.0, 2.0, 3.0]
    assert percentile(values, 0) == 1.0
    assert percentile(values, 100) == 3.0


def test_percentile_is_order_independent():
    assert percentile([3.0, 1.0, 2.0], 50) == percentile([1.0, 2.0, 3.0], 50)


def test_percentile_rejects_empty():
    with pytest.raises(ValueError, match="empty"):
        percentile([], 95)


def test_percentile_rejects_out_of_range():
    with pytest.raises(ValueError, match=r"\[0, 100\]"):
        percentile([1.0], 101)


# --------------------------------------------------------------------------
# The golden set itself is an artifact worth testing
# --------------------------------------------------------------------------


def test_golden_set_is_balanced_and_well_formed():
    from eval.run_eval import GOLDEN_PATH, load_golden

    rows = load_golden(GOLDEN_PATH)
    assert len(rows) == 200

    counts = {lbl: sum(r["label"] == lbl for r in rows) for lbl in LABELS}
    assert counts == {"NEGATIVE": 100, "POSITIVE": 100}
    assert all(r["text"].strip() for r in rows)
    assert set(rows[0]) == {"text", "label"}


def test_golden_set_has_no_duplicates():
    """A duplicated example silently double-weights whatever it tests."""
    from eval.run_eval import GOLDEN_PATH, load_golden

    texts = [r["text"] for r in load_golden(GOLDEN_PATH)]
    assert len(set(texts)) == len(texts)
