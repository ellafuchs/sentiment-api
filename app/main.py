"""The sentiment service.

One endpoint: POST /predict. Send texts, get labels back.

Health checks, readiness probes and a /metadata endpoint all belong here
eventually — but each one arrives in the phase that needs it (Phase 3 for the
cloud, Phase 5 for the gate), not before.
"""

from __future__ import annotations

from fastapi import FastAPI

from app.config import load_config
from app.model import SentimentModel, default_model_dir
from app.schemas import PredictionOut, PredictRequest, PredictResponse

app = FastAPI(title="Sentiment API", version="0.1.0")

# Loaded on first use, then reused forever. Loading takes ~2 seconds and a
# request takes ~20 milliseconds, so loading per-request would make every call
# a hundred times slower. Tests replace this with a fake.
model: SentimentModel | None = None


def get_model() -> SentimentModel:
    global model
    if model is None:
        model = SentimentModel.load(load_config(), default_model_dir())
    return model


@app.post("/predict", response_model=PredictResponse)
def predict(payload: PredictRequest) -> PredictResponse:
    """Classify a batch of texts. One forward pass for the whole list."""
    m = get_model()
    predictions = m.predict(payload.texts)
    return PredictResponse(
        predictions=[PredictionOut(label=p.label, score=p.score) for p in predictions],
        model_version=m.version,
        runtime=m.runtime_name,
    )
