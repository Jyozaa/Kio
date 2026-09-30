import hashlib
import json

import pytest

from companion_agent.benchmark import ece
from companion_agent.training import assert_disjoint, fit_temperature, read_rows


def test_dataset_validation_and_leakage(tmp_path):
    row = {
        "state": "fixture",
        "questions": {"operation": {"type": "choice", "criteria": {"CLICK": "click"}}},
        "expected": {"operation": "CLICK"},
        "task_group": "one",
    }
    path = tmp_path / "data.jsonl"
    path.write_text(json.dumps(row) + "\n")
    assert read_rows(path) == [row]
    with pytest.raises(ValueError, match="leakage"):
        assert_disjoint([row], [row])
    assert_disjoint([row], [{**row, "task_group": "two"}])
    row["expected"]["operation"] = "UNKNOWN"
    path.write_text(json.dumps(row))
    with pytest.raises(ValueError, match="label"):
        read_rows(path)


def test_calibration_limits_and_metrics():
    fitted = fit_temperature([([9.0, 0.0], 1), ([9.0, 0.0], 0)])
    assert 0.5 <= fitted <= 5 and fitted > 1
    assert ece([{"confidence": 1.0, "correct": False}]) == 1
    assert ece([{"confidence": 1.0, "correct": True}]) == 0


def test_typed_dataset_requires_matching_schema_and_sanitized_fields(tmp_path):
    from companion_agent.decision_protocol import DecisionFamily, training_row

    row = training_row(
        DecisionFamily.TARGET.value,
        '{"schema":"KioDecisionStateV1"}',
        {"type": "choice", "instructions": "Select", "criteria": {"c_0": "Save | button"}},
        "c_0",
        task_group="task-a",
    )
    path = tmp_path / "typed.jsonl"
    path.write_text(json.dumps(row) + "\n")
    assert read_rows(path) == [row]
    incompatible = {**row, "candidate_format_schema": "old-format"}
    path.write_text(json.dumps(incompatible) + "\n")
    with pytest.raises(ValueError, match="incompatible_training_schema"):
        read_rows(path)
    sensitive = {**row, "screenshot": "image bytes"}
    path.write_text(json.dumps(sensitive) + "\n")
    with pytest.raises(ValueError, match="unsanitized_training_field"):
        read_rows(path)


def test_frozen_splits_separate_from_real_training_corpus():
    from pathlib import Path

    root = Path(__file__).resolve().parents[2]
    train = read_rows(root / "fixtures/trajectories/autonomy-export/train.jsonl")
    validation = read_rows(root / "fixtures/calibration/validation.jsonl")
    test = read_rows(root / "fixtures/calibration/test.jsonl")
    assert_disjoint(train, validation, test)
    assert len(validation) == len(test) == 14


def test_specialized_loader_missing_and_corrupt_fall_back(tmp_path, monkeypatch):
    import huggingface_hub
    import laya

    from companion_agent.chooser import LayaChooser
    from companion_agent.decision_protocol import CANDIDATE_SCHEMA, STATE_SCHEMA

    monkeypatch.delenv("KIO_LAYA_MODEL_PATH", raising=False)
    monkeypatch.setattr(huggingface_hub, "snapshot_download", lambda *a, **k: "generic")
    loaded = []

    def load(path, **kwargs):
        loaded.append(path)
        if path != "generic":
            raise ValueError("corrupt checkpoint")
        return object()

    monkeypatch.setattr(laya, "load", load)
    chooser = LayaChooser(device="cpu", model_path=tmp_path / "missing")
    assert not chooser.specialized and loaded == ["generic"]
    weights = b"corrupt"
    (tmp_path / "model.safetensors").write_bytes(weights)
    (tmp_path / "rl_agent_config.json").write_text("{}")
    (tmp_path / "kio_model.json").write_text(
        json.dumps(
            {
                "decision_state_schema": STATE_SCHEMA,
                "candidate_format_schema": CANDIDATE_SCHEMA,
                "weights_sha256": hashlib.sha256(weights).hexdigest(),
            }
        )
    )
    chooser = LayaChooser(device="cpu", model_path=tmp_path)
    assert not chooser.specialized and loaded[-2:] == [str(tmp_path), "generic"]
