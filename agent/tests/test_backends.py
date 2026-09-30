import json
import threading
from types import SimpleNamespace

import pytest

from companion_agent.backends import (
    MLXLayaBackend,
    TorchLayaBackend,
    default_backend_name,
    normalize_prediction,
    validate_checkpoint_manifest,
)
from companion_agent.chooser import LayaChooser
from companion_agent.decision_protocol import CANDIDATE_SCHEMA, STATE_SCHEMA


class ResultModel:
    def predict(self, state, questions):
        question_id, question = next(iter(questions.items()))
        choice = next(iter(question["criteria"]))
        return {
            "answers": {
                question_id: {
                    "choice": choice,
                    "probabilities": {
                        choice: 0.9,
                        **{key: 0.1 for key in question["criteria"] if key != choice},
                    },
                    "confidence": 0.67,
                }
            }
        }


def test_backend_response_normalization_preserves_entropy_and_top_probability():
    question = {
        "button": {
            "type": "choice",
            "instructions": "Choose",
            "criteria": {"c_0": "button", "c_1": "link"},
        }
    }
    result = normalize_prediction(ResultModel().predict("state", question))
    answer = result["answers"]["button"]
    assert answer["answer_confidence"] == 0.9
    assert answer["backend_confidence"] == 0.67


def test_mlx_backend_loads_float16_and_normalizes_upstream_response(monkeypatch):
    called = {}
    model = ResultModel()

    def load(path, **kwargs):
        called.update(path=path, **kwargs)
        return model

    monkeypatch.setattr(MLXLayaBackend, "supported_host", staticmethod(lambda: True))
    monkeypatch.setitem(__import__("sys").modules, "laya_mlx", SimpleNamespace(load=load))
    backend = MLXLayaBackend.load("/model")
    result = backend.predict(
        "state",
        {
            "operation": {
                "type": "choice",
                "instructions": "Choose",
                "criteria": {"CLICK": "click", "WAIT": "wait"},
            }
        },
    )
    assert called["dtype"] == "float16"
    assert called["batch_size"] == 8
    assert called["compile"] is False
    assert result["answers"]["operation"]["answer_confidence"] == 0.9


def test_chooser_falls_back_to_torch_if_mlx_runtime_fails(monkeypatch):
    class BrokenMlx:
        name = "mlx"
        model = object()

        def predict(self, *_):
            raise RuntimeError("metal unavailable")

    torch_model = ResultModel()
    torch = SimpleNamespace(
        name="torch",
        model=torch_model,
        predict=torch_model.predict,
        device="cpu",
        model_path="model",
    )
    chooser = LayaChooser.__new__(LayaChooser)
    chooser._lock = threading.Lock()
    chooser._backend = BrokenMlx()
    chooser._model = chooser._backend.model
    chooser.device = "gpu"
    chooser.model_path = "model"
    monkeypatch.setattr(TorchLayaBackend, "load", classmethod(lambda cls, path, device=None: torch))
    result = chooser._predict(
        "state",
        {
            "operation": {
                "type": "choice",
                "instructions": "Choose",
                "criteria": {"CLICK": "click", "WAIT": "wait"},
            }
        },
    )
    assert chooser._backend is torch
    assert result["answers"]["operation"]["choice"] == "CLICK"


def test_kio_checkpoint_manifest_checks_schema_and_weight_hash(tmp_path):
    import hashlib

    weights = tmp_path / "model.safetensors"
    weights.write_bytes(b"fixture-weights")
    manifest = {
        "decision_state_schema": STATE_SCHEMA,
        "candidate_format_schema": CANDIDATE_SCHEMA,
        "weights_sha256": hashlib.sha256(weights.read_bytes()).hexdigest(),
    }
    (tmp_path / "kio_model.json").write_text(json.dumps(manifest))
    assert validate_checkpoint_manifest(tmp_path) == manifest
    manifest["candidate_format_schema"] = "old-format"
    (tmp_path / "kio_model.json").write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match="incompatible_decision_schema"):
        validate_checkpoint_manifest(tmp_path)


def test_explicit_torch_cpu_request_beats_automatic_mlx_default(monkeypatch):
    monkeypatch.setattr(MLXLayaBackend, "supported_host", staticmethod(lambda: True))
    assert default_backend_name() == "mlx"
    assert default_backend_name("cpu") == "torch"
