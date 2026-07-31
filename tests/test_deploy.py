"""Tests that drive a *deployed revision*, before it takes real traffic.

    DEPLOY_URL=https://candidate---sentiment-….a.run.app uv run pytest -m deploy

The other suites in this repo each check something these cannot:

    tests/           the code, in-process
    test_container   the image, over HTTP to a local container
    this file        one Cloud Run revision, over the internet

The gap this closes is narrow and worth naming exactly. `test_container` proves
the image is good. It cannot prove that the image now serving at a URL *is that
image*. Between the two sit a registry push, a digest resolution, a Cloud Run
deploy and a traffic assignment — four places where the thing you tested and the
thing that answers can come apart, none of them visible to a test that never
leaves the laptop.

So the assertion that earns this file its place is `test_serving_this_commit`:
the URL reports the model version that *this checkout's* models.yaml asks for.
Everything else here is a fast sanity pass.

Deliberately NOT the accuracy gate. Scoring 200 examples against a candidate is
Phase 5's job and takes an order of magnitude longer; this runs between a deploy
and a canary, where the question is "is it alive and is it the right thing", not
"is it good". Answering the second question here would make every deploy slow in
order to duplicate a check the pipeline already runs elsewhere.

Skipped entirely when DEPLOY_URL is unset, so `make test` is unaffected.
"""

from __future__ import annotations

import os
from pathlib import Path

import httpx
import pytest
import yaml

from app.config import load_config

pytestmark = pytest.mark.deploy

BEHAVIORAL_PATH = Path(__file__).resolve().parent.parent / "eval" / "behavioral.yaml"

# A cold revision loads 268MB of weights. Cloud Run reports a revision Ready as
# soon as the port is held, and `--no-traffic` revisions are not kept warm.
TIMEOUT = 60.0


@pytest.fixture(scope="module")
def url() -> str:
    target = os.environ.get("DEPLOY_URL", "").rstrip("/")
    if not target:
        pytest.skip("DEPLOY_URL is not set — nothing deployed to test")
    return target


@pytest.fixture(scope="module")
def client(url: str) -> httpx.Client:
    with httpx.Client(base_url=url, timeout=TIMEOUT) as c:
        yield c


def _minimum_functionality() -> list[tuple[str, str]]:
    spec = yaml.safe_load(BEHAVIORAL_PATH.read_text())
    return [(c["text"], c["expect"]) for c in spec["minimum_functionality"]["cases"]]


# --------------------------------------------------------------------------
# Is it there, and is it the right one
# --------------------------------------------------------------------------


def test_livez(client: httpx.Client) -> None:
    """Liveness, over the real network rather than in-process.

    This is the assertion that found the ``/healthz`` interception: it passed
    in-process, passed against the container, and 404'd against the deployed
    URL. Which is precisely the gap this file was added to cover.
    """
    r = client.get("/livez")
    assert r.status_code == 200, r.text
    assert r.json() == {"status": "ok"}


def test_readyz(client: httpx.Client) -> None:
    r = client.get("/readyz")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["ready"] is True, body


def test_serving_this_commit(client: httpx.Client) -> None:
    """The revision reports the model this checkout asks for.

    The check that justifies the file. A green pipeline that deployed the wrong
    image, or shifted traffic to the wrong revision, passes every other test
    here — the service is up, it predicts, the contract holds. It just answers
    with different weights than the commit says. That failure is silent by
    construction, because a wrong-but-working model returns 200.
    """
    expected = load_config().model.version
    actual = client.get("/readyz").json()["model_version"]
    assert actual == expected, (
        f"deployed revision serves {actual!r}, but models.yaml in this commit "
        f"asks for {expected!r} — the URL is not running this commit's image"
    )


# --------------------------------------------------------------------------
# Does it still work
# --------------------------------------------------------------------------


@pytest.mark.parametrize(("text", "expect"), _minimum_functionality())
def test_unambiguous_sentiment(client: httpx.Client, text: str, expect: str) -> None:
    """The cases from behavioral.yaml that are too obvious to fail.

    Not a quality measurement — a liveness one. A revision that gets "I love
    this." wrong is broken in a way no threshold needs to adjudicate.
    """
    r = client.post("/predict", json={"texts": [text]})
    assert r.status_code == 200, r.text
    assert r.json()["predictions"][0]["label"] == expect, f"{text!r} → {r.json()}"


def test_batch(client: httpx.Client) -> None:
    texts = ["I love this.", "I hate this."]
    r = client.post("/predict", json={"texts": texts})
    assert r.status_code == 200, r.text
    preds = r.json()["predictions"]
    assert len(preds) == len(texts)
    assert [p["label"] for p in preds] == ["POSITIVE", "NEGATIVE"]


def test_rejects_empty_batch(client: httpx.Client) -> None:
    """The validation contract survives the trip to production.

    Input validation is the part most likely to be quietly disabled by an
    environment difference, and the failure mode is a 500 where a 422 belongs.
    """
    r = client.post("/predict", json={"texts": []})
    assert r.status_code == 422, r.text
