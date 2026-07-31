"""Model loading and inference, split along the seam that matters.

Three separate concerns, deliberately kept apart:

  1. FETCHING   ``fetch_weights`` turns a ModelConfig into a local directory.
                Knows about the HuggingFace Hub. Knows nothing about inference.
                (Phase 8 adds a GCS source here, for models you train yourself.)

  2. EXECUTING  The ``Runtime`` protocol: token ids in, logits out. Pure
                numerics. ``PyTorchRuntime`` implements it today; ``OnnxRuntime``
                arrives in Phase 7 and nothing outside this file changes.

  3. COMPOSING  ``SentimentModel`` owns the tokenizer and the label mapping,
                calls a Runtime, and exposes ``predict(texts) -> [Prediction]``.

Why tokenization lives in (3) and not (2): both engines must tokenize
identically. If each Runtime owned its own tokenizer, an ONNX swap could
silently change preprocessing, and the resulting accuracy difference would be
blamed on the engine. Sharing it makes the comparison honest.

The test of whether this seam is drawn correctly: adding ONNX in Phase 7 should
require no edits to main.py, schemas.py, the tests, the eval harness, or the
gate. If it does, the boundary is in the wrong place.
"""

from __future__ import annotations

import logging
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Self, runtime_checkable

import numpy as np

from app.config import CANONICAL_LABELS, AppConfig, ModelConfig, RuntimeKind

logger = logging.getLogger(__name__)

# DistilBERT/BERT positional embeddings top out at 512 tokens. Longer input is
# truncated rather than rejected: a sentiment API should degrade, not 500.
MAX_SEQUENCE_LENGTH = 512


@dataclass(frozen=True, slots=True)
class Prediction:
    label: str
    score: float


# --------------------------------------------------------------------------
# 1. Fetching
# --------------------------------------------------------------------------


def fetch_weights(cfg: ModelConfig, dest: Path) -> Path:
    """Materialise the model's files into ``dest`` and return it.

    Called at *image build* time, not at request time. That is what makes the
    container deterministic and lets it run with no network access at all.
    """
    from huggingface_hub import HfApi, snapshot_download

    dest.mkdir(parents=True, exist_ok=True)

    # Most Hub repos ship the *same* weights in several formats
    # (model.safetensors, pytorch_model.bin, TF/Flax variants). Downloading all
    # of them doubles the image for nothing, so pick exactly one.
    repo_files = HfApi().list_repo_files(cfg.id, revision=cfg.revision)
    weights_pattern = (
        "*.safetensors" if any(f.endswith(".safetensors") for f in repo_files) else "*.bin"
    )

    logger.info(
        "fetching %s@%s from HuggingFace Hub (weights: %s)", cfg.id, cfg.revision, weights_pattern
    )
    snapshot_download(
        repo_id=cfg.id,
        revision=cfg.revision,
        local_dir=dest,
        allow_patterns=["*.json", "*.txt", "*.model", weights_pattern],
        # Keep the directory flat. Repos often carry subdirectories holding
        # alternate exports of the same model (onnx/, openvino/, coreml/);
        # we want exactly one model in here, unambiguously.
        ignore_patterns=["*/*"],
    )

    _assert_complete(dest)
    return dest


# Weight file extensions, in preference order. safetensors is the modern format;
# .bin is a pickle and older checkpoints still ship it.
WEIGHT_SUFFIXES = (".safetensors", ".bin")


def _is_complete(model_dir: Path) -> bool:
    """A model directory is usable only with *both* a config and real weights.

    Checking config.json alone is not enough, and the failure mode is nasty: an
    interrupted download leaves the small JSON files behind but no weights, and
    a naive presence check then treats that husk as a valid cached model.
    """
    if not (model_dir / "config.json").is_file():
        return False
    return any(f.suffix in WEIGHT_SUFFIXES for f in model_dir.rglob("*") if f.is_file())


def _assert_complete(model_dir: Path) -> None:
    if (model_dir / "config.json").is_file() and not _is_complete(model_dir):
        raise FileNotFoundError(
            f"{model_dir} has config.json but no weights file "
            f"({' or '.join(WEIGHT_SUFFIXES)}) — the download was interrupted. "
            "Re-run with --force to discard and refetch."
        )
    if not _is_complete(model_dir):
        raise FileNotFoundError(f"{model_dir} does not contain a usable model")


# --------------------------------------------------------------------------
# 2. Executing — the seam
# --------------------------------------------------------------------------


@runtime_checkable
class Runtime(Protocol):
    """Token ids in, raw logits out. No tokenizer, no labels, no softmax.

    Deliberately the narrowest interface that still describes inference. The
    narrower it is, the less a second implementation can accidentally change.
    """

    name: str

    def infer(self, input_ids: np.ndarray, attention_mask: np.ndarray) -> np.ndarray:
        """Return logits of shape (batch, num_labels)."""
        ...


class PyTorchRuntime:
    """Executes the model with PyTorch. The default engine."""

    name = "pytorch"

    def __init__(self, model_dir: Path) -> None:
        import torch
        from transformers import AutoModelForSequenceClassification

        self._torch = torch
        self._model = AutoModelForSequenceClassification.from_pretrained(model_dir)
        # eval() disables dropout. Forgetting it makes predictions nondeterministic
        # — a genuinely nasty bug, because the service still looks healthy.
        self._model.eval()

    def infer(self, input_ids: np.ndarray, attention_mask: np.ndarray) -> np.ndarray:
        torch = self._torch
        with torch.inference_mode():
            out = self._model(
                input_ids=torch.from_numpy(input_ids),
                attention_mask=torch.from_numpy(attention_mask),
            )
        return out.logits.numpy()


def build_runtime(model_dir: Path, kind: RuntimeKind) -> Runtime:
    """Pick an engine. The only place that branches on ``runtime.kind``."""
    if kind is RuntimeKind.PYTORCH:
        return PyTorchRuntime(model_dir)

    if kind is RuntimeKind.ONNX:
        raise NotImplementedError(
            "runtime.kind: onnx is not implemented yet — that lands in Phase 7. "
            "The seam it plugs into (the Runtime protocol) already exists, so "
            "adding it means writing one new class here and nothing else."
        )

    raise ValueError(f"unknown runtime kind: {kind}")  # pragma: no cover


# --------------------------------------------------------------------------
# 3. Composing
# --------------------------------------------------------------------------


def _softmax(logits: np.ndarray) -> np.ndarray:
    """Row-wise softmax, max-subtracted so large logits cannot overflow."""
    shifted = logits - logits.max(axis=-1, keepdims=True)
    exp = np.exp(shifted)
    return exp / exp.sum(axis=-1, keepdims=True)


def resolve_labels(model_dir: Path, cfg: ModelConfig) -> dict[int, str]:
    """Decide what this model's output indices actually mean.

    ``models.yaml`` wins when it specifies ``labels``; otherwise we trust the
    checkpoint's own ``config.json``. Either way the result must be exactly
    NEGATIVE/POSITIVE, because that is what the API contract promises.

    This check is why a model emitting LABEL_0/LABEL_1 fails loudly at startup
    instead of quietly returning nonsense labels to every caller.
    """
    if cfg.labels is not None:
        return {i: v.upper() for i, v in cfg.labels.items()}

    from transformers import AutoConfig

    id2label = {
        int(k): str(v).upper() for k, v in AutoConfig.from_pretrained(model_dir).id2label.items()
    }

    if sorted(id2label.values()) != sorted(CANONICAL_LABELS):
        raise ValueError(
            f"model reports labels {sorted(id2label.values())}, but the API contract "
            f"promises {sorted(CANONICAL_LABELS)}. This checkpoint does not name its "
            "own classes usefully — set an explicit mapping in models.yaml:\n\n"
            "  model:\n    labels:\n      0: NEGATIVE\n      1: POSITIVE\n\n"
            "Check which index is which before guessing; getting it backwards "
            "inverts every prediction while the service still returns 200s."
        )
    return id2label


@runtime_checkable
class Model(Protocol):
    """What the API layer depends on. Kept tiny so tests can fake it."""

    version: str
    runtime_name: str
    labels: list[str]

    def predict(self, texts: list[str]) -> list[Prediction]: ...


class SentimentModel:
    """Tokenizer + Runtime + label mapping, behind one ``predict`` call."""

    def __init__(self, tokenizer, runtime: Runtime, id2label: dict[int, str], version: str) -> None:
        self._tokenizer = tokenizer
        self._runtime = runtime
        self._id2label = id2label
        self.version = version
        self.runtime_name = runtime.name

    @property
    def labels(self) -> list[str]:
        """The labels this model can emit. Always the canonical pair."""
        return sorted(self._id2label.values())

    @classmethod
    def load(cls, config: AppConfig, model_dir: Path) -> Self:
        """Assemble the three pieces. Called once, at process startup."""
        from transformers import AutoTokenizer

        if not model_dir.is_dir():
            raise FileNotFoundError(
                f"model directory {model_dir} does not exist. Weights are baked in at "
                "image build time; run `make fetch` to populate it locally."
            )

        logger.info("loading model from %s (runtime=%s)", model_dir, config.runtime.kind.value)
        tokenizer = AutoTokenizer.from_pretrained(model_dir)
        id2label = resolve_labels(model_dir, config.model)
        runtime = build_runtime(model_dir, config.runtime.kind)
        return cls(tokenizer, runtime, id2label, config.model.version)

    def predict(self, texts: list[str]) -> list[Prediction]:
        """One batched forward pass for the whole list."""
        if not texts:
            return []

        encoded = self._tokenizer(
            texts,
            padding=True,
            truncation=True,
            max_length=MAX_SEQUENCE_LENGTH,
            return_tensors="np",
        )
        logits = self._runtime.infer(
            np.asarray(encoded["input_ids"], dtype=np.int64),
            np.asarray(encoded["attention_mask"], dtype=np.int64),
        )
        probs = _softmax(logits)
        best = probs.argmax(axis=-1)
        return [
            Prediction(label=self._id2label[int(i)], score=float(probs[row, i]))
            for row, i in enumerate(best)
        ]


def default_model_dir() -> Path:
    """Where baked-in weights live. Overridable for local development."""
    import os

    return Path(
        os.environ.get("MODEL_DIR", Path(__file__).resolve().parent.parent / ".model_cache")
    )


def ensure_weights(config: AppConfig, dest: Path | None = None, force: bool = False) -> Path:
    """Fetch weights if absent. Used by ``make fetch`` and the Docker build."""
    dest = dest or default_model_dir()
    if force and dest.exists():
        shutil.rmtree(dest)
    if _is_complete(dest):
        logger.info("weights already present at %s", dest)
        return dest
    if dest.exists() and any(dest.iterdir()):
        logger.warning("%s exists but is incomplete — discarding and refetching", dest)
        shutil.rmtree(dest)
    return fetch_weights(config.model, dest)
