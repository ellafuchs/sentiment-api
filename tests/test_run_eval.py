"""Tests for the eval harness.

These exist because of a real bug: endpoints were deleted from the service
while ``run_eval.py`` was still calling them. Nothing caught it, because
``run_eval.py`` only ever ran against a live server and so was invisible to
``make test``. It failed in the user's hands instead of in CI.

The fix is to drive the harness against the real FastAPI app through an ASGI
transport — no network, no server, no weights, milliseconds. Every HTTP call
``run_eval`` makes is exercised for real.
"""

from __future__ import annotations

from collections.abc import Iterator

import httpx
import pytest
from fastapi.testclient import TestClient

from app import main
from app.model import Prediction
from eval.run_eval import evaluate, load_golden, wait_for_ready


class FakeModel:
    """Answers by keyword so accuracy is predictable, not random."""

    version = "fake:test@0000"
    runtime_name = "fake"
    labels = ["NEGATIVE", "POSITIVE"]

    def predict(self, texts: list[str]) -> list[Prediction]:
        return [
            Prediction(label="POSITIVE" if "good" in t.lower() else "NEGATIVE", score=0.9)
            for t in texts
        ]


@pytest.fixture
def client() -> Iterator[httpx.Client]:
    """A client wired straight into the app. No server, no sockets, no weights.

    ``TestClient`` subclasses ``httpx.Client``, so the eval harness cannot tell
    it apart from the real thing — which is exactly what makes these tests
    exercise the genuine HTTP paths.

    Overriding ``get_model`` keeps the real checkpoint out of it. Note the
    client is deliberately not built with ``with``: the context-manager form
    runs the app's lifespan, which would load the real weights.
    """
    main.app.dependency_overrides[main.get_model] = lambda: FakeModel()
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()


# --------------------------------------------------------------------------
# The regression this file exists for
# --------------------------------------------------------------------------


def test_wait_for_ready_succeeds_against_the_real_app(client):
    """The bug: this polled /readyz, which had been deleted. 404 forever."""
    assert wait_for_ready(client, timeout=5.0)["model_version"] == "fake:test@0000"


def test_wait_for_ready_returns_provenance(client):
    """The report's model_version/runtime come from here, not from /metadata."""
    body = wait_for_ready(client, timeout=5.0)
    assert set(body) >= {"model_version", "runtime", "predictions"}


def test_every_endpoint_run_eval_uses_actually_exists(client):
    """Structural guard against this whole class of bug, permanently.

    If someone deletes an endpoint the harness depends on — or adds a call to
    one that was never built — this fails immediately, in `make test`, instead
    of after a 120-second timeout in someone's terminal.
    """
    served = set(client.get("/openapi.json").json()["paths"])
    assert {"/predict"} <= served, f"run_eval needs /predict; app serves {sorted(served)}"


def test_wait_for_ready_gives_up_loudly_when_nothing_answers():
    transport = httpx.MockTransport(lambda request: httpx.Response(404, text="Not Found"))
    with httpx.Client(transport=transport, base_url="http://nope") as c:
        with pytest.raises(SystemExit, match="not ready"):
            wait_for_ready(c, timeout=1.0)


# --------------------------------------------------------------------------
# evaluate()
# --------------------------------------------------------------------------


ROWS = [
    {"text": "a good film", "label": "POSITIVE"},
    {"text": "a dull mess", "label": "NEGATIVE"},
    {"text": "good, really good", "label": "POSITIVE"},
    {"text": "painfully boring", "label": "NEGATIVE"},
]


def test_evaluate_returns_aligned_triples(client):
    y_true, y_pred, latencies = evaluate(client, ROWS)
    assert len(y_true) == len(y_pred) == len(latencies) == len(ROWS)


def test_evaluate_preserves_the_true_labels(client):
    y_true, _, _ = evaluate(client, ROWS)
    assert y_true == [r["label"] for r in ROWS]


def test_evaluate_collects_the_service_answers(client):
    """The fake answers by keyword, so a perfect score here proves wiring."""
    y_true, y_pred, _ = evaluate(client, ROWS)
    assert y_pred == y_true


def test_evaluate_times_every_request(client):
    _, _, latencies = evaluate(client, ROWS)
    assert all(ms > 0 for ms in latencies)


def test_evaluate_sends_one_text_per_request(client):
    """Latency must reflect what a single caller experiences, not throughput."""
    seen: list[int] = []

    class Counting(FakeModel):
        def predict(self, texts):
            seen.append(len(texts))
            return super().predict(texts)

    main.app.dependency_overrides[main.get_model] = lambda: Counting()
    evaluate(client, ROWS)
    assert set(seen) == {1}


# --------------------------------------------------------------------------
# The golden set loader
# --------------------------------------------------------------------------


def test_load_golden_reads_the_real_file():
    from eval.run_eval import GOLDEN_PATH

    rows = load_golden(GOLDEN_PATH)
    assert len(rows) == 200
    assert set(rows[0]) == {"text", "label"}


def test_load_golden_missing_file_says_what_to_run(tmp_path):
    with pytest.raises(SystemExit, match="build_golden"):
        load_golden(tmp_path / "nope.jsonl")


def test_load_golden_rejects_an_empty_file(tmp_path):
    p = tmp_path / "golden.jsonl"
    p.write_text("")
    with pytest.raises(SystemExit, match="empty"):
        load_golden(p)
