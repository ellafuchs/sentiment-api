"""The sentiment service.
One endpoint: POST /predict. Send texts, get labels back.
"""

from __future__ import annotations

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
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


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness: this process is running. Deliberately touches nothing else.

    Kept separate from ``/readyz`` because the two answer different questions,
    and an orchestrator acts differently on each: liveness failing means
    *restart me*, readiness failing means *don't send me traffic yet*.
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
