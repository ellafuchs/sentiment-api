"""Tests that drive the built image, not the source tree.

Every other test in this repo runs inside the same Python process as the code it
checks. That makes them fast, and structurally blind to an entire class of
failure: the image is a different operating system, a different Python, a
different filesystem layout and a different user. Code that is perfectly correct
still ships broken if the weights were not copied in, `$PORT` is ignored, a
system library is missing, or the non-root user cannot read its own files.

None of those are visible to an in-process test. All of them are visible here,
because these talk HTTP to a real container the way Cloud Run will.

    make build && make test-container

Marked ``container`` so ``make test`` stays fast and needs no Docker.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from collections.abc import Iterator
from pathlib import Path

import httpx
import pytest
import yaml

from eval.run_eval import wait_for_ready

pytestmark = pytest.mark.container

IMAGE = "poc-bert:dev"
BEHAVIORAL_PATH = Path(__file__).resolve().parent.parent / "eval" / "behavioral.yaml"

# Generous because it covers a cold container loading 268MB of weights from a
# freshly-mounted layer, not a warm process.
STARTUP_TIMEOUT = 120.0


# --------------------------------------------------------------------------
# Running containers
# --------------------------------------------------------------------------


def _free_port() -> int:
    """Ask the OS for a port nobody is using, then let go of it."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _missing() -> str | None:
    """Why these tests cannot run, or None if they can.

    Presence is checked with ``docker images -q`` rather than
    ``docker image inspect``. Under the containerd image store, ``inspect``
    reports "No such image" for a tag that resolves to a multi-platform index —
    which every buildx build produces — while the image is present and runnable.
    Trusting it made all 21 tests skip against an image that worked fine.
    """
    if subprocess.run(["docker", "info"], capture_output=True).returncode != 0:
        return "Docker is not running — start Docker Desktop"
    found = subprocess.run(["docker", "images", "-q", IMAGE], capture_output=True, text=True)
    if not found.stdout.strip():
        return f"no image {IMAGE} — run `make build`"
    return None


def _require_image() -> None:
    """Skip locally, fail in CI.

    A skipped suite and a passing suite look identical in a green checkmark. On
    a laptop that is correct — not everyone has built the image. In CI it is the
    whole point of the job, so ``REQUIRE_CONTAINER_TESTS=1`` turns the skip into
    a failure. Phase 5 sets it.
    """
    if (reason := _missing()) is None:
        return
    if os.environ.get("REQUIRE_CONTAINER_TESTS"):
        pytest.fail(f"REQUIRE_CONTAINER_TESTS is set but: {reason}")
    pytest.skip(reason)


class Container:
    """A running container, addressable over HTTP."""

    def __init__(self, container_id: str, port: int) -> None:
        self.id = container_id
        self.url = f"http://127.0.0.1:{port}"

    def logs(self) -> str:
        return subprocess.run(
            ["docker", "logs", self.id], capture_output=True, text=True
        ).stderr.strip()

    def remove(self) -> None:
        subprocess.run(["docker", "rm", "-f", self.id], capture_output=True)


def start_container(*, env: dict[str, str] | None = None, network: str | None = None) -> Container:
    """Start the image detached and return a handle to it.

    ``container_port`` follows ``$PORT`` when it is set, because that is exactly
    the behaviour under test — a container that ignores ``$PORT`` binds 8080
    while Cloud Run waits on something else, and never becomes ready.
    """
    env = env or {}
    host_port = _free_port()
    container_port = env.get("PORT", "8080")

    cmd = ["docker", "run", "-d", "-p", f"{host_port}:{container_port}"]
    for key, value in env.items():
        cmd += ["-e", f"{key}={value}"]
    if network:
        cmd += [f"--network={network}"]
    cmd.append(IMAGE)

    result = subprocess.run(cmd, capture_output=True, text=True)
    assert result.returncode == 0, f"docker run failed: {result.stderr}"
    return Container(result.stdout.strip(), host_port)


@pytest.fixture(scope="module")
def service() -> Iterator[str]:
    """One container for the whole module. Starting it costs seconds, not ms."""
    _require_image()
    container = start_container()
    try:
        with httpx.Client(base_url=container.url) as client:
            try:
                wait_for_ready(client, STARTUP_TIMEOUT)
            except SystemExit as exc:
                pytest.fail(f"{exc}\n\n--- container logs ---\n{container.logs()}")
        yield container.url
    finally:
        container.remove()


@pytest.fixture
def client(service: str) -> Iterator[httpx.Client]:
    with httpx.Client(base_url=service, timeout=60.0) as c:
        yield c


# --------------------------------------------------------------------------
# The contract, over real HTTP
# --------------------------------------------------------------------------


def test_predicts(client: httpx.Client) -> None:
    r = client.post("/predict", json={"texts": ["I loved every minute of it."]})
    assert r.status_code == 200
    assert r.json()["predictions"][0]["label"] == "POSITIVE"


def test_response_carries_provenance(client: httpx.Client) -> None:
    """Without this, a metric produced by the image is unattributable."""
    body = client.post("/predict", json={"texts": ["fine"]}).json()
    assert body["model_version"]
    assert body["runtime"] == "pytorch"


def test_batch_answers_are_ordered(client: httpx.Client) -> None:
    texts = ["A masterpiece.", "Dreadful, a waste of time."]
    labels = [
        p["label"] for p in client.post("/predict", json={"texts": texts}).json()["predictions"]
    ]
    assert labels == ["POSITIVE", "NEGATIVE"]


@pytest.mark.parametrize(
    "payload",
    [
        pytest.param({"texts": []}, id="empty-batch"),
        pytest.param({"texts": ["x"] * 65}, id="over-batch-limit"),
        pytest.param({"texts": "not a list"}, id="wrong-type"),
        pytest.param({"nope": ["x"]}, id="unknown-field"),
    ],
)
def test_bad_requests_are_rejected(client: httpx.Client, payload: dict) -> None:
    """422, not 500. A caller's mistake must not read as a service fault."""
    assert client.post("/predict", json=payload).status_code == 422


def test_openapi_matches_what_the_eval_harness_needs(client: httpx.Client) -> None:
    """The Phase 1.5 guard, repeated against the image.

    The in-process version of this proves the *code* serves /predict. This one
    proves the *artifact* does — they can differ, if the wrong files are copied.
    """
    served = set(client.get("/openapi.json").json()["paths"])
    needed = {"/predict", "/readyz", "/metadata"}
    assert needed <= served, f"run_eval needs {sorted(needed)}; image serves {sorted(served)}"


def test_metadata_reflects_whether_this_image_was_evaluated(client: httpx.Client) -> None:
    """Either the image carries its own scores, or it says it does not.

    Two legitimate answers, because two images are legitimate. ``make build``
    produces the `runtime` stage and has no report — 404. ``make evaluate``
    layers one on and it becomes the `evaluated` stage — 200 with the metrics.

    What must never happen is a 200 carrying invented numbers. CI passes this
    response to ``gate.py --baseline``, and a baseline of 0.0 accuracy would
    make every candidate look like an improvement.
    """
    response = client.get("/metadata")
    assert response.status_code in (200, 404), response.text
    body = response.json()

    if response.status_code == 404:
        assert body["evaluated"] is False
        return

    assert body["evaluated"] is True
    for key in ("accuracy", "macro_f1", "p95_latency_ms", "model_version"):
        assert key in body, f"/metadata is missing {key}"
    assert 0.0 < body["accuracy"] <= 1.0
    # The report inside the image must describe the image serving it.
    assert body["model_version"] == client.get("/readyz").json()["model_version"]


# --------------------------------------------------------------------------
# Properties of the artifact itself
# --------------------------------------------------------------------------


def test_honours_the_port_environment_variable() -> None:
    """Cloud Run injects $PORT and waits on it.

    A container that hard-codes 8080 fails to become ready, and the error you
    get back is about a failed health check — nothing that points at the cause.
    Catching it here costs 20 seconds; catching it in Phase 3 costs an evening.
    """
    _require_image()
    container = start_container(env={"PORT": "9999"})
    try:
        with httpx.Client(base_url=container.url) as client:
            try:
                wait_for_ready(client, STARTUP_TIMEOUT)
            except SystemExit as exc:
                pytest.fail(f"$PORT ignored: {exc}\n\n--- logs ---\n{container.logs()}")
    finally:
        container.remove()


def test_serves_with_no_network_at_all() -> None:
    """The point of fetching weights at build time.

    With ``--network=none`` the container cannot reach the HuggingFace Hub, or
    anything else. If it still answers, the weights are genuinely inside the
    image — not being downloaded on first use, which would make cold starts
    depend on someone else's uptime.

    Port publishing is impossible without a network, so this asks the question
    from inside the container instead.
    """
    _require_image()
    result = subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--network=none",
            "--entrypoint",
            "python",
            IMAGE,
            "-c",
            "from app.config import load_config; from app.model import SentimentModel, "
            "default_model_dir; m = SentimentModel.load(load_config(), default_model_dir()); "
            "print(m.predict(['I loved it'])[0].label)",
        ],
        capture_output=True,
        text=True,
        timeout=180,
    )
    assert result.returncode == 0, f"offline load failed:\n{result.stderr}"
    assert result.stdout.strip() == "POSITIVE"


def test_does_not_run_as_root() -> None:
    _require_image()
    result = subprocess.run(
        ["docker", "run", "--rm", "--entrypoint", "id", IMAGE, "-u"],
        capture_output=True,
        text=True,
    )
    assert result.stdout.strip() != "0", "container runs as root"


def test_ships_without_dev_dependencies() -> None:
    """``--no-dev`` in the Dockerfile, verified rather than assumed.

    pytest and ruff in a production image are dead weight and extra attack
    surface. `datasets` alone pulls in tens of megabytes.
    """
    _require_image()
    result = subprocess.run(
        [
            "docker",
            "run",
            "--rm",
            "--entrypoint",
            "python",
            IMAGE,
            "-c",
            "import importlib.util as u; "
            "print([n for n in ('pytest', 'ruff', 'datasets') if u.find_spec(n)])",
        ],
        capture_output=True,
        text=True,
    )
    assert result.stdout.strip() == "[]", f"dev packages present: {result.stdout.strip()}"


# --------------------------------------------------------------------------
# Behavioral smoke — is the image *right*, not just alive
# --------------------------------------------------------------------------


def _minimum_functionality_cases() -> list[tuple[str, str]]:
    """The unambiguous cases only.

    Deliberately not the whole suite: the negation cases include one the model
    genuinely fails, and that belongs in `make test-model` where it is a
    statement about the *model*. Here we are asking about the *image*.
    """
    suite = yaml.safe_load(BEHAVIORAL_PATH.read_text())
    return [(c["text"], c["expect"]) for c in suite["minimum_functionality"]["cases"]]


@pytest.mark.parametrize(("text", "expect"), _minimum_functionality_cases())
def test_obvious_sentiment_survives_containerization(
    client: httpx.Client, text: str, expect: str
) -> None:
    """A container that answers 200 but predicts nonsense is still broken.

    This is the failure mode that liveness checks cannot see: wrong weights
    copied, a truncated download, a mismatched tokenizer. The service is healthy
    and confidently wrong.
    """
    body = client.post("/predict", json={"texts": [text]}).json()
    assert body["predictions"][0]["label"] == expect, f"{text!r} → {json.dumps(body)}"


# --------------------------------------------------------------------------
# Cold start, recorded rather than asserted
# --------------------------------------------------------------------------


def test_cold_start_is_measured_and_reported() -> None:
    """Prints the number that Phase 7 will be compared against.

    Not asserted with a threshold: cold start on a laptop under Docker Desktop
    is not the number Cloud Run will show, so a pass/fail here would be a
    fiction. The measurement still matters — it goes in docs/architecture.md.
    """
    _require_image()
    container = start_container()
    start = time.perf_counter()
    try:
        with httpx.Client(base_url=container.url) as client:
            wait_for_ready(client, STARTUP_TIMEOUT)
        elapsed = time.perf_counter() - start
        print(f"\n  cold start: {elapsed:.1f}s  (container start → first prediction)")
    finally:
        container.remove()
