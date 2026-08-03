"""Config validation tests.

These are the cheapest tests in the repo and they guard the most common real
mistake: a hand-edited ``models.yaml`` that is subtly wrong. Every case here
represents a way a model swap could go wrong.
"""

from __future__ import annotations

import textwrap

import pytest
from pydantic import ValidationError

from app.config import ModelSource, RuntimeKind, load_config

VALID = """
model:
  source: hf
  id: distilbert-base-uncased-finetuned-sst-2-english
  revision: 714eb0fa89d2f80546fda750413ed43d93601a13
runtime:
  kind: pytorch
gate:
  min_accuracy: 0.88
  min_macro_f1: 0.87
  max_p95_latency_ms: 300
  max_accuracy_regression: 0.02
"""


def write(tmp_path, body: str):
    p = tmp_path / "models.yaml"
    p.write_text(textwrap.dedent(body))
    return p


def test_loads_valid_config(tmp_path):
    cfg = load_config(write(tmp_path, VALID))
    assert cfg.model.source is ModelSource.HF
    assert cfg.runtime.kind is RuntimeKind.PYTORCH
    assert cfg.gate.min_accuracy == 0.88


def test_repo_default_config_is_valid():
    """The real models.yaml must always load. Guards against a bad commit."""
    assert load_config().model.version.startswith("hf:")


def test_model_version_is_traceable():
    """The version string must name the model and pin it to a specific commit.

    Derived from the config rather than hard-coded: the point is that `version`
    stays traceable to whatever is configured, and a hard-coded string fails on
    every legitimate model swap instead — a test that cries wolf on correct
    changes gets edited to shut it up, which is how it stops being a check.
    """
    cfg = load_config()
    assert cfg.model.version == f"hf:{cfg.model.id}@{cfg.model.revision[:12]}"
    assert len(cfg.model.revision) == 40


def test_runtime_defaults_to_pytorch(tmp_path):
    body = VALID.replace("runtime:\n  kind: pytorch\n", "")
    assert load_config(write(tmp_path, body)).runtime.kind is RuntimeKind.PYTORCH


# --- the ways a swap goes wrong -------------------------------------------


def test_id_is_required(tmp_path):
    body = VALID.replace("  id: distilbert-base-uncased-finetuned-sst-2-english\n", "")
    with pytest.raises(ValidationError, match="id"):
        load_config(write(tmp_path, body))


def test_revision_is_required(tmp_path):
    body = VALID.replace("  revision: 714eb0fa89d2f80546fda750413ed43d93601a13\n", "")
    with pytest.raises(ValidationError, match="revision"):
        load_config(write(tmp_path, body))


def test_branch_name_as_revision_is_rejected(tmp_path):
    """A branch can move underneath you; that breaks reproducibility."""
    body = VALID.replace("714eb0fa89d2f80546fda750413ed43d93601a13", "main")
    with pytest.raises(ValidationError, match="40-character commit SHA"):
        load_config(write(tmp_path, body))


def test_short_sha_as_revision_is_rejected(tmp_path):
    body = VALID.replace("714eb0fa89d2f80546fda750413ed43d93601a13", "714eb0f")
    with pytest.raises(ValidationError, match="40-character commit SHA"):
        load_config(write(tmp_path, body))


def test_typo_in_key_is_rejected_not_ignored(tmp_path):
    """A silently-ignored threshold typo would leave the gate weaker than believed."""
    with pytest.raises(ValidationError):
        load_config(write(tmp_path, VALID.replace("min_accuracy:", "min_accuarcy:")))


def test_out_of_range_threshold_is_rejected(tmp_path):
    with pytest.raises(ValidationError):
        load_config(write(tmp_path, VALID.replace("min_accuracy: 0.88", "min_accuracy: 1.5")))


def test_unknown_runtime_kind_is_rejected(tmp_path):
    with pytest.raises(ValidationError):
        load_config(write(tmp_path, VALID.replace("kind: pytorch", "kind: tensorrt")))


def test_unknown_source_is_rejected(tmp_path):
    """`gcs` arrives in Phase 8 — until then it must fail, not half-work."""
    with pytest.raises(ValidationError):
        load_config(write(tmp_path, VALID.replace("source: hf", "source: gcs")))


# --- labels: the trap that would break the Phase 6 demo swap ---------------


def test_explicit_labels_are_accepted(tmp_path):
    body = VALID.replace(
        "  source: hf\n", "  source: hf\n  labels:\n    0: NEGATIVE\n    1: POSITIVE\n"
    )
    assert load_config(write(tmp_path, body)).model.labels == {0: "NEGATIVE", 1: "POSITIVE"}


def test_labels_must_cover_both_indices(tmp_path):
    body = VALID.replace("  source: hf\n", "  source: hf\n  labels:\n    0: NEGATIVE\n")
    with pytest.raises(ValidationError, match="must map exactly the indices"):
        load_config(write(tmp_path, body))


def test_labels_must_be_the_canonical_pair(tmp_path):
    body = VALID.replace("  source: hf\n", "  source: hf\n  labels:\n    0: BAD\n    1: GOOD\n")
    with pytest.raises(ValidationError, match="values must be exactly"):
        load_config(write(tmp_path, body))


# --- loading ---------------------------------------------------------------


def test_missing_file_raises_clearly(tmp_path):
    with pytest.raises(FileNotFoundError, match="config file not found"):
        load_config(tmp_path / "nope.yaml")


def test_env_var_overrides_default_path(tmp_path, monkeypatch):
    p = write(tmp_path, VALID.replace("min_accuracy: 0.88", "min_accuracy: 0.5"))
    monkeypatch.setenv("MODELS_CONFIG_PATH", str(p))
    assert load_config().gate.min_accuracy == 0.5


def test_config_is_immutable():
    with pytest.raises(ValidationError):
        load_config().gate.min_accuracy = 0.1  # type: ignore[misc]


def test_rejects_non_mapping(tmp_path):
    p = tmp_path / "models.yaml"
    p.write_text("- just\n- a\n- list\n")
    with pytest.raises(ValueError, match="must contain a YAML mapping"):
        load_config(p)


def test_gate_config_is_required(tmp_path):
    """No gate section means no thresholds — that must not be loadable."""
    with pytest.raises(ValidationError, match="gate"):
        load_config(write(tmp_path, VALID[: VALID.index("gate:")]))


def test_gate_section_cannot_be_partially_specified(tmp_path):
    """Half a gate is worse than no gate: it looks configured but isn't."""
    body = VALID.replace("  max_accuracy_regression: 0.02\n", "")
    with pytest.raises(ValidationError, match="max_accuracy_regression"):
        load_config(write(tmp_path, body))
