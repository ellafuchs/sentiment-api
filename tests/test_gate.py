"""Gate tests.

This is the code that blocks a deploy, so it gets tested harder than anything
else in the repo. Every branch runs in microseconds — no model, no network — so
there is no excuse for leaving one uncovered.

The cases that matter most are the ones where the gate must say NO.
"""

from __future__ import annotations

import json

import pytest

from app.config import GateConfig
from eval.gate import Check, load_report, main, run_gate

GATE = GateConfig(
    min_accuracy=0.88,
    min_macro_f1=0.87,
    max_p95_latency_ms=300.0,
    max_accuracy_regression=0.02,
)


def report(accuracy=0.90, macro_f1=0.90, p95=25.0) -> dict:
    return {"accuracy": accuracy, "macro_f1": macro_f1, "p95_latency_ms": p95}


# --------------------------------------------------------------------------
# Check — the single-threshold primitive
# --------------------------------------------------------------------------


def test_higher_is_better_passes_at_and_above_threshold():
    assert Check("acc", 0.90, 0.88, higher_is_better=True).passed
    assert Check("acc", 0.88, 0.88, higher_is_better=True).passed  # exactly on the line
    assert not Check("acc", 0.87, 0.88, higher_is_better=True).passed


def test_lower_is_better_passes_at_and_below_threshold():
    assert Check("p95", 250.0, 300.0, higher_is_better=False).passed
    assert Check("p95", 300.0, 300.0, higher_is_better=False).passed
    assert not Check("p95", 301.0, 300.0, higher_is_better=False).passed


def test_margin_is_positive_when_passing():
    assert Check("acc", 0.90, 0.88, higher_is_better=True).margin == pytest.approx(0.02)
    assert Check("p95", 250.0, 300.0, higher_is_better=False).margin == pytest.approx(50.0)


def test_margin_is_negative_when_failing():
    assert Check("acc", 0.85, 0.88, higher_is_better=True).margin == pytest.approx(-0.03)
    assert Check("p95", 350.0, 300.0, higher_is_better=False).margin == pytest.approx(-50.0)


# --------------------------------------------------------------------------
# The absolute floors
# --------------------------------------------------------------------------


def test_good_model_passes():
    assert run_gate(report(), GATE).passed


def test_low_accuracy_blocks():
    v = run_gate(report(accuracy=0.60), GATE)
    assert not v.passed
    assert [c.name for c in v.failures] == ["accuracy"]


def test_low_macro_f1_blocks():
    v = run_gate(report(macro_f1=0.50), GATE)
    assert not v.passed
    assert "macro_f1" in [c.name for c in v.failures]


def test_slow_model_blocks_even_when_accurate():
    """Accuracy is not the only thing that can make a model unshippable."""
    v = run_gate(report(accuracy=0.99, macro_f1=0.99, p95=5000.0), GATE)
    assert not v.passed
    assert [c.name for c in v.failures] == ["p95_latency_ms"]


def test_untrained_model_fails_everything():
    """A randomly-initialised classifier scores near chance. This is Phase 6's PR B."""
    v = run_gate(report(accuracy=0.51, macro_f1=0.34), GATE)
    assert not v.passed
    assert len(v.failures) == 2


def test_all_three_floors_are_checked_without_a_baseline():
    assert len(run_gate(report(), GATE).checks) == 3


# --------------------------------------------------------------------------
# The regression check — the reason floors alone are not enough
# --------------------------------------------------------------------------


def test_regression_check_is_skipped_when_nothing_is_deployed():
    v = run_gate(report(), GATE, baseline=None)
    assert "accuracy vs live" not in [c.name for c in v.checks]
    assert v.passed


def test_quiet_degradation_is_blocked():
    """THE case this whole check exists for.

    0.885 clears min_accuracy (0.88) but is meaningfully worse than the 0.92
    currently serving traffic. Absolute floors alone would wave it through, and
    quality would erode one acceptable-looking PR at a time.
    """
    v = run_gate(report(accuracy=0.885), GATE, baseline=report(accuracy=0.92))

    accuracy_check = next(c for c in v.checks if c.name == "accuracy")
    assert accuracy_check.passed, "the absolute floor is happy — that is the trap"

    assert not v.passed
    assert [c.name for c in v.failures] == ["accuracy vs live"]


def test_small_dip_within_tolerance_is_allowed():
    """Noise must not block every deploy. 0.01 < the 0.02 tolerance."""
    assert run_gate(report(accuracy=0.91), GATE, baseline=report(accuracy=0.92)).passed


def test_dip_exactly_at_tolerance_is_allowed():
    assert run_gate(report(accuracy=0.90), GATE, baseline=report(accuracy=0.92)).passed


def test_improvement_over_live_passes():
    assert run_gate(report(accuracy=0.95), GATE, baseline=report(accuracy=0.90)).passed


def test_baseline_without_accuracy_is_ignored_not_crashed():
    """A live service that never recorded metrics must not break the gate."""
    v = run_gate(report(), GATE, baseline={"model_version": "old"})
    assert v.passed
    assert len(v.checks) == 3


# --------------------------------------------------------------------------
# The report a human reads
# --------------------------------------------------------------------------


def test_markdown_says_passed():
    assert "Gate passed" in run_gate(report(), GATE).to_markdown()


def test_markdown_says_failed_and_names_the_metric():
    """A red X alone is useless — the reviewer must see which metric and by how much."""
    md = run_gate(report(accuracy=0.60), GATE).to_markdown()
    assert "Gate failed" in md
    assert "Blocked by: **accuracy**" in md
    assert "0.6" in md and "0.88" in md


def test_markdown_lists_every_check():
    md = run_gate(report(), GATE, baseline=report()).to_markdown()
    for name in ("accuracy", "macro_f1", "p95_latency_ms", "accuracy vs live"):
        assert name in md


def test_markdown_names_all_failures():
    md = run_gate(report(accuracy=0.5, macro_f1=0.4), GATE).to_markdown()
    assert "accuracy" in md and "macro_f1" in md


# --------------------------------------------------------------------------
# Loading, and the CLI contract CI depends on
# --------------------------------------------------------------------------


def test_missing_report_fails_with_advice(tmp_path):
    with pytest.raises(SystemExit, match="run `make eval`"):
        load_report(tmp_path / "nope.json")


def test_incomplete_report_is_rejected(tmp_path):
    """Half a report would silently gate on the metrics that happen to be there."""
    p = tmp_path / "eval_report.json"
    p.write_text(json.dumps({"accuracy": 0.9}))
    with pytest.raises(SystemExit, match="missing"):
        load_report(p)


def test_exit_code_zero_when_passing(tmp_path):
    """CI reads the exit code and nothing else. 0 means ship."""
    p = tmp_path / "eval_report.json"
    p.write_text(json.dumps(report()))
    assert main(["--report", str(p)]) == 0


def test_exit_code_one_when_failing(tmp_path):
    p = tmp_path / "eval_report.json"
    p.write_text(json.dumps(report(accuracy=0.4)))
    assert main(["--report", str(p)]) == 1


def test_markdown_can_be_written_to_a_file(tmp_path):
    """CI posts this file as the PR comment."""
    p = tmp_path / "eval_report.json"
    p.write_text(json.dumps(report()))
    out = tmp_path / "gate.md"
    main(["--report", str(p), "--markdown", str(out)])
    assert "Gate passed" in out.read_text()
