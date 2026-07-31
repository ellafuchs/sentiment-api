from __future__ import annotations

import os
from enum import StrEnum
from pathlib import Path
from typing import Self

import yaml
from pydantic import BaseModel, ConfigDict, Field, model_validator

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parent.parent / "models.yaml"

# The API contract promises exactly these two labels, forever. Models are free
# to disagree internally — plenty of SST-2 checkpoints emit LABEL_0/LABEL_1 —
# but that disagreement gets resolved here, at config load, not leaked to
# callers. See ModelConfig.labels.
CANONICAL_LABELS = ("NEGATIVE", "POSITIVE")


class ModelSource(StrEnum):
    HF = "hf"
    # GCS arrives in Phase 8, when you serve a model you trained yourself.


class RuntimeKind(StrEnum):
    PYTORCH = "pytorch"
    ONNX = "onnx"

class _Strict(BaseModel):
    """Reject unknown keys.

    A silently-ignored typo like ``min_accuarcy: 0.95`` would leave the gate
    running on its default threshold while the author believes it was tightened.
    Failing loudly on unknown keys is the whole point.
    """

    model_config = ConfigDict(extra="forbid", frozen=True)


class ModelConfig(_Strict):
    """Which weights to serve."""

    source: ModelSource
    id: str
    revision: str

    # Maps the model's output index -> canonical label. Optional: when the
    # checkpoint's own config.json already says NEGATIVE/POSITIVE we use that.
    # Required when it says something useless like LABEL_0/LABEL_1, which is
    # common. Getting this wrong inverts every prediction while the service
    # still returns 200s — so it is config, checked at startup, not a guess.
    labels: dict[int, str] | None = None

    @model_validator(mode="after")
    def _check_labels(self) -> Self:
        if self.labels is None:
            return self

        expected_indices = set(range(len(CANONICAL_LABELS)))
        if set(self.labels) != expected_indices:
            raise ValueError(
                f"`labels` must map exactly the indices {sorted(expected_indices)}, "
                f"got {sorted(self.labels)}."
            )
        if sorted(v.upper() for v in self.labels.values()) != sorted(CANONICAL_LABELS):
            raise ValueError(
                f"`labels` values must be exactly {set(CANONICAL_LABELS)} "
                f"(case-insensitive), got {set(self.labels.values())}."
            )
        return self

    @model_validator(mode="after")
    def _check_revision_is_pinned(self) -> Self:
        """A commit SHA, not a branch name.

        A branch can move underneath you, which quietly breaks the promise that
        one git commit always means one exact set of weights.
        """
        if len(self.revision) < 40 or not all(c in "0123456789abcdef" for c in self.revision):
            raise ValueError(
                f"`revision` must be a full 40-character commit SHA, got {self.revision!r}. "
                "Branch names and short SHAs are not reproducible."
            )
        return self

    @property
    def version(self) -> str:
        """Stable human-readable identifier, echoed in every API response.

        Any logged prediction can be traced back to exact weights through this.
        """
        return f"hf:{self.id}@{self.revision[:12]}"


class RuntimeConfig(_Strict):
    """Which inference engine executes the model."""

    kind: RuntimeKind = RuntimeKind.PYTORCH
    # `quantize` arrives with ONNX in Phase 7.


class GateConfig(_Strict):
    """Thresholds a candidate must clear before it can reach production."""

    min_accuracy: float = Field(ge=0.0, le=1.0)
    min_macro_f1: float = Field(ge=0.0, le=1.0)
    max_p95_latency_ms: float = Field(gt=0.0)
    max_accuracy_regression: float = Field(ge=0.0, le=1.0)


class AppConfig(_Strict):
    model: ModelConfig
    runtime: RuntimeConfig = Field(default_factory=RuntimeConfig)
    gate: GateConfig


def load_config(path: str | os.PathLike[str] | None = None) -> AppConfig:
    """Load and validate ``models.yaml``.

    Resolution order: explicit argument, then ``$MODELS_CONFIG_PATH``, then the
    repo-root default. The env var is what lets tests and the container point
    at a different file without touching code.
    """
    resolved = Path(path or os.environ.get("MODELS_CONFIG_PATH") or DEFAULT_CONFIG_PATH)
    if not resolved.is_file():
        raise FileNotFoundError(f"config file not found: {resolved}")

    raw = yaml.safe_load(resolved.read_text())
    if not isinstance(raw, dict):
        raise ValueError(f"{resolved} must contain a YAML mapping, got {type(raw).__name__}")

    return AppConfig.model_validate(raw)
