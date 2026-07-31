"""The sentiment service.
One endpoint: POST /predict. Send texts, get labels back.
"""

from __future__ import annotations

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, Request

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
