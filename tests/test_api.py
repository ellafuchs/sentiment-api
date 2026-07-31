"""API contract tests.

These run against a *fake* model, so the whole suite finishes in well under a
second and needs no weights on disk.

What they protect: the shapes callers depend on. Every assertion here should
still hold after any model swap — if a change to models.yaml breaks a test in
this file, the change broke the API, not just the model.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import main
from app.model import Prediction
from app.schemas import MAX_BATCH_SIZE, MAX_TEXT_LENGTH


class FakeModel:
    """Alternates POSITIVE/NEGATIVE. Deterministic, instant, no weights."""

    version = "fake:test@0000"
    runtime_name = "fake"
    labels = ["NEGATIVE", "POSITIVE"]

    def __init__(self) -> None:
        self.seen: list[list[str]] = []

    def predict(self, texts: list[str]) -> list[Prediction]:
        self.seen.append(texts)
        return [
            Prediction(label="POSITIVE" if i % 2 == 0 else "NEGATIVE", score=0.9)
            for i, _ in enumerate(texts)
        ]


@pytest.fixture
def fake(monkeypatch) -> FakeModel:
    """Swap the real model for a fake one.

    ``main.get_model()`` returns ``main.model`` if it is already set, so putting
    a fake there means the real 268MB checkpoint is never loaded. This is the
    only reason the suite runs in seconds.
    """
    stub = FakeModel()
    monkeypatch.setattr(main, "model", stub)
    return stub


@pytest.fixture
def client(fake: FakeModel) -> TestClient:
    return TestClient(main.app)


# --------------------------------------------------------------------------
# Happy path
# --------------------------------------------------------------------------


def test_predict_returns_one_prediction_per_text(client):
    r = client.post("/predict", json={"texts": ["a", "b", "c"]})
    assert r.status_code == 200
    assert len(r.json()["predictions"]) == 3


def test_predict_response_shape(client):
    body = client.post("/predict", json={"texts": ["hello"]}).json()
    assert set(body) == {"predictions", "model_version", "runtime"}
    assert set(body["predictions"][0]) == {"label", "score"}


def test_predict_echoes_model_version(client):
    """Traceability: a logged prediction must identify the weights behind it."""
    body = client.post("/predict", json={"texts": ["hello"]}).json()
    assert body["model_version"] == "fake:test@0000"
    assert body["runtime"] == "fake"


def test_predict_forwards_texts_verbatim(client, fake):
    client.post("/predict", json={"texts": ["  spaced  ", "ok"]})
    assert fake.seen == [["  spaced  ", "ok"]]


def test_predict_sends_one_batch(client, fake):
    """The API must not fan a batch out into N single-text calls."""
    client.post("/predict", json={"texts": ["a", "b", "c", "d"]})
    assert len(fake.seen) == 1


# --------------------------------------------------------------------------
# Input validation — the contract's edges
# --------------------------------------------------------------------------


def test_empty_batch_is_rejected(client):
    assert client.post("/predict", json={"texts": []}).status_code == 422


def test_missing_texts_field_is_rejected(client):
    assert client.post("/predict", json={}).status_code == 422


def test_unknown_field_is_rejected(client):
    """extra='forbid' means a client typo fails loudly instead of being ignored."""
    assert client.post("/predict", json={"texts": ["a"], "temperture": 0.5}).status_code == 422


def test_wrong_type_is_rejected(client):
    assert client.post("/predict", json={"texts": "not a list"}).status_code == 422
    assert client.post("/predict", json={"texts": [123]}).status_code == 422


def test_malformed_json_is_rejected(client):
    r = client.post("/predict", content=b"{not json", headers={"Content-Type": "application/json"})
    assert r.status_code == 422


def test_batch_at_the_cap_is_accepted(client):
    assert client.post("/predict", json={"texts": ["x"] * MAX_BATCH_SIZE}).status_code == 200


def test_batch_over_the_cap_is_rejected(client):
    """A 422 is a better answer than letting one request pin the CPU."""
    assert client.post("/predict", json={"texts": ["x"] * (MAX_BATCH_SIZE + 1)}).status_code == 422


def test_oversized_text_is_rejected(client):
    assert client.post("/predict", json={"texts": ["x" * (MAX_TEXT_LENGTH + 1)]}).status_code == 422


def test_unicode_and_emoji_pass_through(client, fake):
    texts = ["café ☕", "日本語のテキスト", "🎉🎉🎉", "naïve résumé"]
    assert client.post("/predict", json={"texts": texts}).status_code == 200
    assert fake.seen == [texts]


def test_whitespace_only_text_is_accepted(client):
    """Not our job to reject: the model can classify it, the contract allows it."""
    assert client.post("/predict", json={"texts": ["   "]}).status_code == 200


def test_get_on_predict_is_method_not_allowed(client):
    assert client.get("/predict").status_code == 405


def test_unknown_route_is_404(client):
    assert client.get("/nope").status_code == 404


def test_openapi_schema_is_served(client):
    """The contract is machine-readable, so consumers can generate clients."""
    assert "/predict" in client.get("/openapi.json").json()["paths"]
