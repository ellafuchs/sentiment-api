"""Typed, validated configuration loaded from models.yaml."""

from __future__ import annotations

import os
from enum import StrEnum
from pathlib import Path
from typing import Self

import yaml
from pydantic import BaseModel, ConfigDict, Field, model_validator

DEFAULT_CONFIG_PATH = Path(__file__).resolve().parent.parent / "models.yaml"

CANONICAL_LABELS = ("NEGATIVE", "POSITIVE")


class ModelSource(StrEnum):
    HF = "hf"


class RuntimeKind(StrEnum):
    PYTORCH = "pytorch"
    ONNX = "onnx"


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class ModelConfig(_Strict):
    source: ModelSource
    id: str
    revision: str
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
        if len(self.revision) < 40 or not all(c in "0123456789abcdef" for c in self.revision):
            raise ValueError(
                f"`revision` must be a full 40-character commit SHA, got {self.revision!r}. "
                "Branch names and short SHAs are not reproducible."
            )
        return self

    @property
    def version(self) -> str:
        return f"hf:{self.id}@{self.revision[:12]}"


class RuntimeConfig(_Strict):
    kind: RuntimeKind = RuntimeKind.PYTORCH


class GateConfig(_Strict):
    min_accuracy: float = Field(ge=0.0, le=1.0)
    min_macro_f1: float = Field(ge=0.0, le=1.0)
    max_p95_latency_ms: float = Field(gt=0.0)
    max_accuracy_regression: float = Field(ge=0.0, le=1.0)


class AppConfig(_Strict):
    model: ModelConfig
    runtime: RuntimeConfig = Field(default_factory=RuntimeConfig)
    gate: GateConfig


def load_config(path: str | os.PathLike[str] | None = None) -> AppConfig:
    resolved = Path(path or os.environ.get("MODELS_CONFIG_PATH") or DEFAULT_CONFIG_PATH)
    if not resolved.is_file():
        raise FileNotFoundError(f"config file not found: {resolved}")

    raw = yaml.safe_load(resolved.read_text())
    if not isinstance(raw, dict):
        raise ValueError(f"{resolved} must contain a YAML mapping, got {type(raw).__name__}")

    return AppConfig.model_validate(raw)
