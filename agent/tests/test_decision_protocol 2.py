import json
import threading
from pathlib import Path

import pytest

from companion_agent.candidates import Element, Observation, Operation, build_candidates
from companion_agent.chooser import LayaChooser, format_state, operation_question
from companion_agent.decision_protocol import (
    CANDIDATE_SCHEMA,
    STATE_SCHEMA,
    DecisionFamily,
    KioCandidateFormatV1,
    render_candidate_options,
    training_row,
)
from companion_agent.video_parity import evaluate


class SequentialModel:
    def __init__(self, *, operation="CLICK", target="c_0", confidence=0.91):
        self.operation = operation
        self.target = target
        self.confidence = confidence
        self.requests = []

    def predict(self, state, questions):
        self.requests.append((state, questions))
        question_id, definition = next(iter(questions.items()))
        choices = definition["criteria"]
        selected = self.operation if question_id == "operation" else self.target
        assert selected in choices
        probabilities = {key: 0.0 for key in choices}
        probabilities[selected] = 1.0 if len(choices) == 1 else self.confidence
        if len(choices) > 1 and probabilities[selected] < 1:
            other = next(key for key in choices if key != selected)
            probabilities[other] = 1 - probabilities[selected]
        return {
            "answers": {
                question_id: {
                    "choice": selected,
                    "probabilities": probabilities,
                    "answer_confidence": probabilities[selected],
                }
            }
        }


class TypedModel:
    def __init__(self, choice):
        self.choice = choice
        self.questions = []

    def predict(self, state, questions):
        self.questions.append(questions)
        question_id, definition = next(iter(questions.items()))
        choices = definition["criteria"]
        probabilities = {key: 0.0 for key in choices}
        probabilities[self.choice] = 1.0
        return {
            "answers": {
                question_id: {
                    "choice": self.choice,
                    "probabilities": probabilities,
                    "answer_confidence": 1.0,
                }
            }
        }


def table():
    obs = Observation(
        "snapshot",
        1,
        2,
        (
            Element(
                "target",
                "snapshot",
                "Review report",
                "AXButton",
                None,
                True,
                True,
                "AX",
                native={
                    "element_token": "PRIVATE-CUA-TOKEN",
                    "frame": {"x": 17, "y": 23, "w": 100, "h": 30},
                    "parent_label": "Reports toolbar",
                    "region_label": "main pane",
                    "nearby_labels": ["Help", "Refresh"],
                },
            ),
            Element("heading", "snapshot", "Report list", "AXHeading", None, True, True, "AX"),
        ),
        "Example App",
    )
    return build_candidates(obs, "Click Review report")


def test_compact_state_and_candidate_options_are_versioned_and_authority_free():
    candidates = table()
    state = format_state("Click Review report", candidates, [])
    payload = json.loads(state)
    assert payload["schema"] == STATE_SCHEMA
    assert payload["ui_state"]["goal_relevant_text"] == ["Report list"]
    options, reverse = render_candidate_options(candidates, Operation.CLICK)
    serialized = json.dumps({"state": payload, "options": options})
    assert CANDIDATE_SCHEMA == "KioCandidateFormatV1"
    assert KioCandidateFormatV1(options).schema == CANDIDATE_SCHEMA
    with pytest.raises(ValueError, match="invalid_candidate_format"):
        KioCandidateFormatV1({"raw-control-id": "button"})
    assert list(options) == ["c_0"]
    assert "Review report | button" in options["c_0"]
    assert "parent: Reports toolbar" in options["c_0"]
    assert reverse["c_0"] in candidates.actions
    for forbidden in ("PRIVATE-CUA-TOKEN", "element_token", '"x"', '"y"', "visible_state"):
        assert forbidden not in serialized
    assert payload["application"]["window_title"] == "Example App"


def test_generic_chooser_asks_operation_then_target_with_opaque_ids_only():
    candidates = table()
    model = SequentialModel()
    chooser = LayaChooser.__new__(LayaChooser)
    chooser._lock = threading.Lock()
    chooser._model = model
    chooser.device = "cpu"
    decision = chooser.choose("Click Review report", candidates, [])
    assert decision.operation == Operation.CLICK
    assert candidates.actions[decision.candidate_id].description.startswith("Review report")
    assert [list(question) for _, question in model.requests] == [["operation"], ["click_target"]]
    assert list(model.requests[1][1]["click_target"]["criteria"]) == ["c_0"]
    assert "PRIVATE-CUA-TOKEN" not in json.dumps(model.requests)


def test_operation_question_excludes_done_after_verifier_has_not_proven_completion():
    question = operation_question(table())["operation"]
    assert "DONE" not in question["criteria"]
    assert "CLICK" in question["criteria"]
    assert "Review report" in question["criteria"]["CLICK"]


def test_goal_state_and_recovery_are_typed_hints_only():
    candidates = table()
    chooser = LayaChooser.__new__(LayaChooser)
    chooser._lock = threading.Lock()
    chooser._model = TypedModel("NOT_SATISFIED")
    chooser.device = "cpu"
    assert (
        chooser.choose_goal_state("Click Review report", candidates, [], "UNKNOWN")[0]
        == "NOT_SATISFIED"
    )
    assert list(chooser._model.questions[-1]) == ["goal_state"]

    chooser._model = TypedModel("WAIT_FOR_TRANSITION")
    assert chooser.choose_recovery(
        "Click Review report", candidates.observation, [], "pending"
    ) == ("WAIT_FOR_TRANSITION", 1.0)
    assert list(chooser._model.questions[-1]) == ["recovery"]


def test_typed_training_row_validation_and_video_parity_fixtures():
    row = training_row(
        DecisionFamily.TARGET.value,
        '{"schema":"KioDecisionStateV1"}',
        {
            "type": "choice",
            "instructions": "Select a control",
            "criteria": {"c_0": "New Note | button"},
        },
        "c_0",
        task_group="task-a",
        trajectory_id="trajectory-a",
        step_index=3,
    )
    assert row["schema_version"] == "kio-decision-v1"
    assert row["decision_family"] == "TARGET"
    assert row["step_index"] == 3
    assert row["trajectory_id"] == "trajectory-a"
    result = evaluate(
        Path("fixtures/video_parity/canonical.json"),
        Path("fixtures/video_parity/variants.json"),
    )
    assert (result["canonical_passed"], result["canonical_total"]) == (9, 9)
    assert (result["variant_passed"], result["variant_total"]) == (16, 16)
    assert result["live_actions"] == 0


def test_training_row_rejects_unknown_family_and_unlisted_label():
    with pytest.raises(ValueError, match="family"):
        training_row(
            "EXECUTE", "state", {"type": "choice", "criteria": {"x": "x"}}, "x", task_group="x"
        )
    with pytest.raises(ValueError, match="label"):
        training_row(
            "TARGET", "state", {"type": "choice", "criteria": {"c_0": "x"}}, "c_1", task_group="x"
        )
