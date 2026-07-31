"""Behavioral tests, driven by eval/behavioral.yaml.

These load the real model (marked ``model``, so ``make test`` skips them) and
in CI they run against the container over HTTP via the same YAML file.

The point of separating the cases into YAML: adding a behavioral test should be
a data change any reviewer can read in a PR, not a code change. When someone
finds a case the model gets wrong in production, the fix is four lines of YAML.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from app.config import load_config
from app.model import SentimentModel, _is_complete, default_model_dir

BEHAVIORAL_PATH = Path(__file__).resolve().parent.parent / "eval" / "behavioral.yaml"

SUITE = yaml.safe_load(BEHAVIORAL_PATH.read_text())


@pytest.fixture(scope="module")
def model() -> SentimentModel:
    model_dir = default_model_dir()
    if not _is_complete(model_dir):
        pytest.skip(f"no weights at {model_dir} — run `make fetch`")
    return SentimentModel.load(load_config(), model_dir)


def label_of(model: SentimentModel, text: str) -> str:
    return model.predict([text])[0].label


# --------------------------------------------------------------------------
# Minimum functionality
# --------------------------------------------------------------------------


@pytest.mark.model
@pytest.mark.parametrize(
    "case",
    SUITE["minimum_functionality"]["cases"],
    ids=lambda c: c["text"][:40],
)
def test_minimum_functionality(model, case):
    """Unambiguous sentiment. A failure here means the model is broken."""
    assert label_of(model, case["text"]) == case["expect"]


# --------------------------------------------------------------------------
# Invariance
# --------------------------------------------------------------------------


@pytest.mark.model
@pytest.mark.parametrize("case", SUITE["invariance"]["cases"], ids=lambda c: c["name"])
def test_invariance(model, case):
    """Cosmetic edits must not change the label."""
    labels = {v: label_of(model, v) for v in case["variants"]}
    distinct = set(labels.values())
    assert len(distinct) == 1, (
        f"{case['name']}: cosmetic edit changed the label — {labels}. "
        "The model is keying on something other than sentiment."
    )


# --------------------------------------------------------------------------
# Directional
# --------------------------------------------------------------------------


@pytest.mark.model
@pytest.mark.parametrize("case", SUITE["directional"]["cases"], ids=lambda c: c["name"])
def test_directional(model, case):
    """Meaning-changing edits MUST change the label. Negation is the classic trap."""
    original = label_of(model, case["text"])
    flipped = label_of(model, case["flipped"])

    assert original == case["expect"], f"{case['name']}: base case wrong ({original})"
    assert flipped == case["expect_flipped"], (
        f"{case['name']}: expected {case['expect_flipped']} for {case['flipped']!r}, "
        f"got {flipped}. The model is not handling negation."
    )


# --------------------------------------------------------------------------
# Robustness
# --------------------------------------------------------------------------


@pytest.mark.model
@pytest.mark.parametrize("case", SUITE["robustness"]["cases"], ids=lambda c: c["text"][:40])
def test_robustness(model, case):
    """Typos and informal writing should degrade the score, not invert the answer."""
    assert label_of(model, case["text"]) == case["expect"]


# --------------------------------------------------------------------------
# The suite file itself
# --------------------------------------------------------------------------


def test_suite_covers_all_four_categories():
    """Guards against someone quietly deleting a whole category of check."""
    assert set(SUITE) == {
        "minimum_functionality",
        "invariance",
        "directional",
        "robustness",
    }


def test_suite_expectations_use_canonical_labels():
    from app.config import CANONICAL_LABELS

    expected = set(CANONICAL_LABELS)
    for case in SUITE["minimum_functionality"]["cases"] + SUITE["robustness"]["cases"]:
        assert case["expect"] in expected
    for case in SUITE["directional"]["cases"]:
        assert case["expect"] in expected
        assert case["expect_flipped"] in expected
        assert case["expect"] != case["expect_flipped"], "a directional case must flip"


def test_invariance_cases_have_at_least_two_variants():
    for case in SUITE["invariance"]["cases"]:
        assert len(case["variants"]) >= 2, f"{case['name']} needs something to compare"
