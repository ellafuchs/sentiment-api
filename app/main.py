"""The sentiment service.
One endpoint: POST /predict. Send texts, get labels back.
"""

from __future__ import annotations

import json
import os
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, Request, Response

from app.config import load_config
from app.model import Model, SentimentModel, default_model_dir
from app.schemas import PredictionOut, PredictRequest, PredictResponse


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Load the model once, at startup — before the first request arrives.

    Loading here rather than on first use is what makes a bad revision, missing
    weights or an unusable label mapping kill the process at boot, where an
    orchestrator can see it. Lazily, the same faults surface as a 500 to a real
    caller long after the deploy went green — and config.py already goes to
    trouble to fail early, which this would otherwise throw away.
    """
    app.state.model = SentimentModel.load(load_config(), default_model_dir())
    yield


app = FastAPI(title="Sentiment API", version="0.1.0", lifespan=lifespan)


def get_model(request: Request) -> Model:
    """The endpoint's only route to the model. Overridable in tests."""
    return request.app.state.model


def get_model_if_loaded(request: Request) -> Model | None:
    """Like ``get_model``, but tolerates the one state ``/readyz`` exists to report.

    A separate dependency rather than a bare ``app.state`` read, because the
    dependency is the seam tests override. Reading state directly would make
    ``/readyz`` invisible to every fake-model test in the suite.
    """
    return getattr(request.app.state, "model", None)


@app.get("/livez")
def livez() -> dict[str, str]:
    """Liveness: this process is running. Deliberately touches nothing else.

    Kept separate from ``/readyz`` because the two answer different questions,
    and an orchestrator acts differently on each: liveness failing means
    *restart me*, readiness failing means *don't send me traffic yet*.

    **Do not rename this to /healthz.** That is the conventional spelling and it
    is the one path here that does not work. Google's edge intercepts ``/healthz``
    on ``*.run.app`` before it reaches Cloud Run at all: the reply is a Google
    HTML 404 carrying neither ``server: Google Frontend`` nor a trace header,
    while ``/nonexistent`` on the same host returns this app's own JSON 404.
    Measured on revision ``sentiment-00002-nfs``; ``/livez``, ``/health``,
    ``/live``, ``/status`` and ``/readyz`` all reach the app normally.

    Nothing in this repo depended on it — Cloud Run's startup probe is TCP — so
    the endpoint was simply unreachable in production while passing every test,
    which is the failure mode this project exists to make visible. It was the
    deploy smoke test that caught it, on its first run.
    """
    return {"status": "ok"}


@app.get("/readyz")
def readyz(
    m: Annotated[Model | None, Depends(get_model_if_loaded)],
    response: Response,
) -> dict[str, object]:
    """Readiness: this instance holds weights and can answer.

    What earns its keep is not the 503 — ``lifespan`` loads the model before
    uvicorn binds the port, and a failed load kills the process, so a caller
    can never actually observe ``ready: false`` here. It is that this is a
    *cheap* proof the model is loaded: the eval harness waits on it without
    burning a forward pass, and the answer carries the provenance every report
    is attributed with.
    """
    if m is None:
        response.status_code = 503
        return {"ready": False, "reason": "model not loaded"}
    return {"ready": True, "model_version": m.version, "runtime": m.runtime_name}


def eval_report_path() -> Path:
    """Where this build's own eval report lives.

    Overridable so tests can point it somewhere real, and so a container can be
    told a different path without a rebuild.
    """
    return Path(os.environ.get("EVAL_REPORT_PATH", "eval_report.json"))


@app.get("/metadata")
def metadata(response: Response) -> dict[str, object]:
    """The scores this exact image earned, baked in at build time.

    **The artifact reports its own quality.** The image is built, evaluated
    while running, and then a thin final layer copies the resulting
    ``eval_report.json`` into it. So "how good is the thing currently serving
    production?" is a question you ask the thing currently serving production,
    rather than one you answer from a spreadsheet, a wiki page, or the CI logs
    of whichever run you think deployed it.

    That matters because it is what makes the regression check possible. CI
    fetches this from the live service and passes it to ``gate.py --baseline``,
    so a candidate is judged not only against the absolute floors in
    ``models.yaml`` but against what is actually deployed right now.

    **Only ``accuracy`` is safe to compare across deployments, and the gate uses
    only ``accuracy``.** The latency figures here were measured wherever this
    image happened to be evaluated — a CI runner, on that day, over that
    network. Comparing them to a candidate's latency measured somewhere else is
    the mistake Phases 2, 3 and 4 each made in turn, and there is no reason to
    make it a fourth time. They are recorded as provenance, not as a baseline.
    See ``docs/architecture.md``.

    404 when the report is absent, which is the honest answer for an image that
    was never evaluated — a local ``make build``, or any build before this
    phase existed. CI treats a 404 as "no baseline" and says so out loud rather
    than silently skipping the check.
    """
    path = eval_report_path()
    if not path.is_file():
        response.status_code = 404
        return {"evaluated": False, "reason": f"no eval report at {path}"}

    try:
        report = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        response.status_code = 500
        return {"evaluated": False, "reason": f"unreadable eval report: {exc}"}

    return {"evaluated": True, **report}


@app.post("/predict", response_model=PredictResponse)
def predict(
    payload: PredictRequest,
    m: Annotated[Model, Depends(get_model)],
) -> PredictResponse:
    """Classify a batch of texts. One forward pass for the whole list."""
    predictions = m.predict(payload.texts)
    return PredictResponse(
        predictions=[PredictionOut(label=p.label, score=p.score) for p in predictions],
        model_version=m.version,
        runtime=m.runtime_name,
    )
