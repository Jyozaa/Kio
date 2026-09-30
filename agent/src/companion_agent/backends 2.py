"""Inference backend boundary for Laya implementations."""

import hashlib
import json
import platform
import sys
from pathlib import Path
from typing import Protocol

from .decision_protocol import CANDIDATE_SCHEMA, STATE_SCHEMA


class DecisionBackend(Protocol):
    name: str
    model: object
    model_path: str

    def predict(self, state: str, questions: dict) -> dict: ...


def normalize_prediction(result):
    """Normalize upstream Torch and MLX response differences into Kio's shape."""
    if not isinstance(result, dict) or not isinstance(result.get("answers"), dict):
        return result
    answers = {}
    for key, answer in result["answers"].items():
        if not isinstance(answer, dict):
            answers[key] = answer
            continue
        normalized = dict(answer)
        if "answer_confidence" not in normalized and "confidence" in normalized:
            # Upstream Torch's compatibility field is top-choice probability;
            # MLX's `confidence` is entropy confidence. Keep both explicit.
            normalized["backend_confidence"] = normalized["confidence"]
            probabilities = normalized.get("probabilities")
            choice = normalized.get("choice")
            if isinstance(probabilities, dict) and choice in probabilities:
                normalized["answer_confidence"] = probabilities[choice]
            else:
                normalized["answer_confidence"] = normalized["confidence"]
        answers[key] = normalized
    return {**result, "answers": answers}


class TorchLayaBackend:
    name = "torch"

    def __init__(self, model, model_path, device):
        self.model = model
        self.model_path = str(model_path)
        self.device = device

    @classmethod
    def load(cls, model_path, *, device=None):
        import laya
        import torch

        selected = device or ("mps" if torch.backends.mps.is_available() else "cpu")
        if selected not in {"cpu", "mps", "cuda"}:
            raise ValueError("Unsupported LAYA_DEVICE")
        try:
            model = laya.load(str(model_path), device=selected)
        except (RuntimeError, NotImplementedError):
            if selected == "cpu":
                raise
            selected = "cpu"
            model = laya.load(str(model_path), device=selected)
        return cls(model, model_path, selected)

    def predict(self, state, questions):
        return normalize_prediction(self.model.predict(state, questions))


class MLXLayaBackend:
    name = "mlx"

    def __init__(self, model, model_path):
        self.model = model
        self.model_path = str(model_path)
        self.device = "gpu"

    @classmethod
    def supported_host(cls):
        return sys.platform == "darwin" and platform.machine() == "arm64"

    @classmethod
    def load(cls, model_path, **options):
        if not cls.supported_host():
            raise RuntimeError("laya_mlx_requires_apple_silicon")
        import laya_mlx

        model = laya_mlx.load(
            str(model_path),
            device="gpu",
            dtype=options.pop("dtype", "float16"),
            batch_size=options.pop("batch_size", 8),
            compile=options.pop("compile", False),
            cache_prompts=options.pop("cache_prompts", False),
            **options,
        )
        return cls(model, model_path)

    def predict(self, state, questions):
        return normalize_prediction(self.model.predict(state, questions))


def default_backend_name(device=None):
    """Prefer the validated Apple backend only on the platform it supports."""
    return "mlx" if device != "cpu" and MLXLayaBackend.supported_host() else "torch"


def validate_checkpoint_manifest(model_path):
    """Reject a Kio checkpoint trained against a different model-facing schema."""
    root = Path(model_path)
    manifest_path = root / "kio_model.json"
    if not manifest_path.is_file():
        raise ValueError("specialized_checkpoint_manifest_missing")
    manifest = json.loads(manifest_path.read_text())
    if (
        manifest.get("decision_state_schema") != STATE_SCHEMA
        or manifest.get("candidate_format_schema") != CANDIDATE_SCHEMA
    ):
        raise ValueError("incompatible_decision_schema")
    weights = root / "model.safetensors"
    digest = hashlib.sha256(weights.read_bytes()).hexdigest()
    if manifest.get("weights_sha256") != digest:
        raise ValueError("checkpoint_weights_hash_mismatch")
    return manifest
