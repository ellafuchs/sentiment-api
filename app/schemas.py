"""The API contract.

This is a separate artifact from the model. Callers depend on *these shapes*;
the weights behind them are free to change with every merge. That separation is
the whole point of the project — a model swap must be invisible here.

Two guarantees worth stating explicitly:

  * ``label`` is always exactly "POSITIVE" or "NEGATIVE", whatever the
    underlying checkpoint calls its classes internally.
  * Every response carries ``model_version``, so any logged prediction can be
    traced back to the exact weights that produced it.
"""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field

# Batch cap. One request must not be able to monopolise a single-vCPU instance:
# 64 short texts is ~1s of CPU, which is a bounded amount of head-of-line
# blocking for everyone else. Requests above this get a 422, not a timeout.
MAX_BATCH_SIZE = 64

# Per-text cap, in characters. The model truncates at 512 *tokens* anyway, so
# anything past this is guaranteed-discarded input we would pay to tokenise.
MAX_TEXT_LENGTH = 10_000

Label = Literal["NEGATIVE", "POSITIVE"]


class PredictRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    texts: Annotated[
        list[Annotated[str, Field(max_length=MAX_TEXT_LENGTH)]],
        Field(min_length=1, max_length=MAX_BATCH_SIZE),
    ]


class PredictionOut(BaseModel):
    label: Label
    score: Annotated[float, Field(ge=0.0, le=1.0, description="Probability of the chosen label")]


class PredictResponse(BaseModel):
    predictions: list[PredictionOut]
    model_version: str
    runtime: str
