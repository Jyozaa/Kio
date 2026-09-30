import asyncio
import hashlib
import json

import pytest

from companion_agent.candidates import Operation
from companion_agent.chooser import MockChooser
from companion_agent.driver import DriverError
from companion_agent.loop import AgentLoop
from companion_agent.trajectories import (
    TrajectoryRecorder,
    correct,
    export,
    load,
    replay,
    sanitize,
    split_for,
)


def record_fixture(root, run_id="fixture", task_id=None):
    from test_loop import WorkflowDriver

    recorder = TrajectoryRecorder("Reach Success", root, run_id=run_id, task_id=task_id)
    result = asyncio.run(
        AgentLoop(
            WorkflowDriver(["Start", "Success"]),
            MockChooser([(Operation.CLICK, "Start", 0.99)]),
            recorder=recorder,
        ).run("Reach Success", 1, 2, asyncio.Event())
    )
    assert result.status == "completed"
    return root / (run_id + ".json")


def test_roundtrip_replay_zero_execution_and_immutable_correction(tmp_path, monkeypatch):
    from companion_agent.driver import CuaDriver

    path = record_fixture(tmp_path)
    original = path.read_bytes()
    data = load(path)
    assert data["steps"][0]["state_changed"] is True
    assert data["outcome"]["verification"]["status"] == "VERIFIED"
    monkeypatch.setattr(
        CuaDriver, "execute", lambda *a, **k: pytest.fail("execution during replay")
    )
    monkeypatch.setattr(
        CuaDriver, "connect", lambda *a, **k: pytest.fail("connection during replay")
    )
    assert replay(data, MockChooser([(Operation.CLICK, "Start", 0.9)]))[0]["same"]
    candidate = data["steps"][0]["decision"]["candidate_id"]
    correct(path, 0, candidate, tmp_path / "corrections")
    assert path.read_bytes() == original
    correction = json.loads(next((tmp_path / "corrections").glob("*.json")).read_text())
    assert correction["trajectory_sha256"] == hashlib.sha256(original).hexdigest()
    with pytest.raises(DriverError, match="unknown_candidate"):
        correct(path, 0, "foreign", tmp_path / "corrections")


def test_version_and_duplicate_candidate_rejected(tmp_path):
    path = record_fixture(tmp_path)
    data = json.loads(path.read_text())
    data["trajectory_schema_version"] = 2
    path.write_text(json.dumps(data))
    with pytest.raises(ValueError, match="version"):
        load(path)
    data["trajectory_schema_version"] = 1
    data["steps"][0]["candidates"].append(data["steps"][0]["candidates"][0])
    path.write_text(json.dumps(data))
    with pytest.raises(DriverError, match="duplicate_candidate"):
        load(path)


def test_sanitization_and_no_executable_payload(tmp_path):
    raw = {
        "goal": 'Enter "hunter2" in password field',
        "api_key": "private",
        "image": "pixels",
        "user": "person@example.com",
        "path": "/Users/joe/private/file",
        "value": "sk-12345678901234567890",
    }
    clean = json.dumps(sanitize(raw))
    for forbidden in ["hunter2", "private", "pixels", "person@example.com", "/Users/joe", "sk-"]:
        assert forbidden not in clean
    data = load(record_fixture(tmp_path))
    assert "element_token" not in json.dumps(data) and "payload" not in json.dumps(data)
    assert "image" not in data["steps"][0]


def test_task_group_split_and_export_normalizes_ids(tmp_path):
    trajectories = tmp_path / "runs"
    paths = [
        record_fixture(trajectories, "run-a", "one-task"),
        record_fixture(trajectories, "run-b", "one-task"),
    ]
    corrections = tmp_path / "corrections"
    for path in paths:
        data = load(path)
        correct(path, 0, data["steps"][0]["decision"]["candidate_id"], corrections)
    counts = export(paths, corrections, tmp_path / "export", seed=13)
    assert sum(counts.values()) == 4 and sorted(counts.values()) == [0, 0, 4]
    rows = [
        json.loads(line)
        for p in (tmp_path / "export").glob("*.jsonl")
        for line in p.read_text().splitlines()
    ]
    assert len({r["task_group"] for r in rows}) == 1
    assert {r["schema_version"] for r in rows} == {"kio-decision-v1"}
    assert {r["decision_family"] for r in rows} == {"NEXT_OPERATION", "TARGET"}
    assert all(r["expected"]["TARGET"] == "c_0" for r in rows if r["decision_family"] == "TARGET")
    assert {split_for(str(i), 42) for i in range(100)} == {"train", "validation", "test"}
    assert split_for("one-task", 13) == split_for("one-task", 13)
