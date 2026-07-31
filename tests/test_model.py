"""Loader and runtime-seam tests.

Split by cost. Everything above the ``model`` marker runs with fake weights in
milliseconds; only the handful at the bottom load the real 268MB checkpoint.
That split is deliberate — a test suite you avoid running because it's slow
stops protecting you.
"""

from __future__ import annotations

import json

import numpy as np
import pytest

from app.config import ModelConfig, ModelSource, RuntimeKind, load_config
from app.model import (
    Model,
    Prediction,
    SentimentModel,
    _is_complete,
    _softmax,
    build_runtime,
    default_model_dir,
    resolve_labels,
)

# Config validation requires a full 40-character commit SHA.
FAKE_SHA = "0" * 40

# --------------------------------------------------------------------------
# Fakes — the whole reason step 0.3 drew the seam where it did
# --------------------------------------------------------------------------


class FakeRuntime:
    """Returns canned logits. Knows nothing about text."""

    name = "fake"

    def __init__(self, logits: np.ndarray) -> None:
        self.logits = logits
        self.calls: list[tuple[int, int]] = []

    def infer(self, input_ids: np.ndarray, attention_mask: np.ndarray) -> np.ndarray:
        self.calls.append(input_ids.shape)
        return self.logits


class FakeTokenizer:
    """Encodes each text as its length. Enough to verify batching and shape."""

    def __call__(self, texts, padding=True, truncation=True, max_length=512, return_tensors="np"):
        width = max(len(t) for t in texts)
        return {
            "input_ids": np.ones((len(texts), width), dtype=np.int64),
            "attention_mask": np.ones((len(texts), width), dtype=np.int64),
        }


def make_model(logits: np.ndarray) -> SentimentModel:
    return SentimentModel(
        tokenizer=FakeTokenizer(),
        runtime=FakeRuntime(logits),
        id2label={0: "NEGATIVE", 1: "POSITIVE"},
        version="fake:v1",
    )


# --------------------------------------------------------------------------
# softmax
# --------------------------------------------------------------------------


def test_softmax_rows_sum_to_one():
    out = _softmax(np.array([[1.0, 2.0], [0.5, -3.0], [0.0, 0.0]]))
    np.testing.assert_allclose(out.sum(axis=1), [1.0, 1.0, 1.0], rtol=1e-6)


def test_softmax_is_stable_on_huge_logits():
    """Naive exp() would overflow to inf/nan here and silently poison scores."""
    out = _softmax(np.array([[1000.0, 999.0]]))
    assert np.isfinite(out).all()
    assert out[0, 0] > out[0, 1]


def test_softmax_equal_logits_gives_even_split():
    np.testing.assert_allclose(_softmax(np.array([[5.0, 5.0]])), [[0.5, 0.5]])


# --------------------------------------------------------------------------
# The runtime seam
# --------------------------------------------------------------------------


def test_onnx_runtime_not_implemented_yet():
    """The seam must be visibly unfilled, not silently missing."""
    with pytest.raises(NotImplementedError, match="Phase 7"):
        build_runtime(default_model_dir(), RuntimeKind.ONNX)


def test_fake_runtime_satisfies_the_protocol():
    """If a 12-line fake can implement Runtime, the interface is narrow enough."""
    from app.model import Runtime

    assert isinstance(FakeRuntime(np.zeros((1, 2))), Runtime)


def test_sentiment_model_satisfies_the_model_protocol():
    assert isinstance(make_model(np.zeros((1, 2))), Model)


# --------------------------------------------------------------------------
# predict() — composition, without any real weights
# --------------------------------------------------------------------------


def test_predict_maps_argmax_to_label():
    model = make_model(np.array([[5.0, 1.0], [1.0, 5.0]]))
    preds = model.predict(["a", "b"])
    assert [p.label for p in preds] == ["NEGATIVE", "POSITIVE"]


def test_predict_scores_are_probabilities():
    preds = make_model(np.array([[5.0, 1.0]])).predict(["a"])
    assert 0.0 <= preds[0].score <= 1.0
    assert preds[0].score == pytest.approx(0.982, abs=1e-3)


def test_predict_returns_one_prediction_per_input():
    logits = np.tile(np.array([[2.0, 1.0]]), (7, 1))
    assert len(make_model(logits).predict(["x"] * 7)) == 7


def test_predict_batches_into_a_single_forward_pass():
    """Three texts must cost one inference call, not three."""
    runtime = FakeRuntime(np.tile(np.array([[2.0, 1.0]]), (3, 1)))
    model = SentimentModel(FakeTokenizer(), runtime, {0: "NEGATIVE", 1: "POSITIVE"}, "v")
    model.predict(["a", "bb", "ccc"])
    assert len(runtime.calls) == 1
    assert runtime.calls[0][0] == 3


def test_predict_empty_list_does_no_inference():
    runtime = FakeRuntime(np.zeros((0, 2)))
    model = SentimentModel(FakeTokenizer(), runtime, {0: "NEGATIVE", 1: "POSITIVE"}, "v")
    assert model.predict([]) == []
    assert runtime.calls == []


def test_prediction_is_immutable():
    with pytest.raises(AttributeError):
        Prediction("POSITIVE", 0.9).label = "NEGATIVE"  # type: ignore[misc]


# --------------------------------------------------------------------------
# Label resolution — the trap that would break the Phase 6 demo swap
# --------------------------------------------------------------------------


def write_hf_config(tmp_path, id2label: dict[str, str]):
    (tmp_path / "config.json").write_text(
        json.dumps(
            {
                "model_type": "distilbert",
                "architectures": ["DistilBertForSequenceClassification"],
                "id2label": id2label,
            }
        )
    )
    return tmp_path


def test_explicit_labels_override_the_checkpoint(tmp_path):
    """models.yaml wins, so a LABEL_0/LABEL_1 checkpoint stays usable."""
    write_hf_config(tmp_path, {"0": "LABEL_0", "1": "LABEL_1"})
    cfg = ModelConfig(
        source=ModelSource.HF, id="x", revision=FAKE_SHA, labels={0: "NEGATIVE", 1: "POSITIVE"}
    )
    assert resolve_labels(tmp_path, cfg) == {0: "NEGATIVE", 1: "POSITIVE"}


def test_useless_checkpoint_labels_fail_loudly(tmp_path):
    """A model naming its classes LABEL_0/LABEL_1 must not reach production silently."""
    write_hf_config(tmp_path, {"0": "LABEL_0", "1": "LABEL_1"})
    cfg = ModelConfig(source=ModelSource.HF, id="x", revision=FAKE_SHA)
    with pytest.raises(ValueError, match="does not name its own classes usefully"):
        resolve_labels(tmp_path, cfg)


def test_labels_are_uppercased(tmp_path):
    cfg = ModelConfig(
        source=ModelSource.HF, id="x", revision=FAKE_SHA, labels={0: "negative", 1: "positive"}
    )
    assert resolve_labels(tmp_path, cfg) == {0: "NEGATIVE", 1: "POSITIVE"}


# --------------------------------------------------------------------------
# Incomplete-download detection
# --------------------------------------------------------------------------


def test_config_without_weights_is_incomplete(tmp_path):
    """An interrupted download leaves the JSON but no weights. Must not count as cached."""
    (tmp_path / "config.json").write_text("{}")
    assert not _is_complete(tmp_path)


def test_config_plus_weights_is_complete(tmp_path):
    (tmp_path / "config.json").write_text("{}")
    (tmp_path / "model.safetensors").write_bytes(b"\x00")
    assert _is_complete(tmp_path)


def test_weights_without_config_is_incomplete(tmp_path):
    (tmp_path / "model.safetensors").write_bytes(b"\x00")
    assert not _is_complete(tmp_path)


def test_empty_dir_is_incomplete(tmp_path):
    assert not _is_complete(tmp_path)


# --------------------------------------------------------------------------
# The real model. Slow — deselected by `make test`.
# --------------------------------------------------------------------------


@pytest.fixture(scope="module")
def real_model() -> SentimentModel:
    model_dir = default_model_dir()
    if not _is_complete(model_dir):
        pytest.skip(f"no weights at {model_dir} — run `make fetch`")
    return SentimentModel.load(load_config(), model_dir)


@pytest.mark.model
def test_real_model_loads_and_reports_version(real_model):
    assert real_model.version.startswith("hf:distilbert")
    assert real_model.runtime_name == "pytorch"


@pytest.mark.model
def test_real_model_classifies_obvious_sentiment(real_model):
    preds = real_model.predict(["I love this, it was fantastic!", "Terrible, a total waste."])
    assert [p.label for p in preds] == ["POSITIVE", "NEGATIVE"]
    assert all(p.score > 0.9 for p in preds)


@pytest.mark.model
def test_real_model_handles_negation(real_model):
    """Directional test: adding 'not' must flip the label."""
    preds = real_model.predict(["The food was great", "The food was not great"])
    assert [p.label for p in preds] == ["POSITIVE", "NEGATIVE"]


@pytest.mark.model
def test_real_model_truncates_instead_of_failing(real_model):
    """Input beyond 512 tokens must degrade, not 500."""
    preds = real_model.predict(["good " * 5000])
    assert len(preds) == 1
    assert preds[0].label in {"POSITIVE", "NEGATIVE"}


@pytest.mark.model
def test_real_model_is_deterministic(real_model):
    """Same input twice must give identical scores — proves eval() disabled dropout."""
    a = real_model.predict(["a nuanced and interesting film"])
    b = real_model.predict(["a nuanced and interesting film"])
    assert a[0].label == b[0].label
    assert a[0].score == b[0].score
