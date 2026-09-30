import threading

import pytest

from companion_agent.candidates import Element, Observation, Operation, build_candidates
from companion_agent.chooser import LayaChooser
from companion_agent.driver import DriverError
from companion_agent.semantic_planner import (
    DesiredState,
    ObjectType,
    SemanticOperation,
    SemanticStep,
)


class Model:
    def __init__(self, choice=None, confidence=1.0):
        self.choice = choice
        self.confidence = confidence
        self.questions = None

    def predict(self, state, questions):
        self.questions = questions
        field = next(iter(questions))
        choices = questions[field]["criteria"]
        selected = self.choice or next(iter(choices))
        probabilities = {key: 0.0 for key in choices}
        probabilities[selected] = self.confidence
        if len(probabilities) > 1:
            remaining = 1 - self.confidence
            other = next(key for key in probabilities if key != selected)
            probabilities[other] = remaining
        else:
            probabilities[selected] = 1.0
        return {
            "answers": {
                field: {
                    "choice": selected,
                    "probabilities": probabilities,
                    "answer_confidence": probabilities[selected],
                }
            }
        }


def mute_observation():
    elements = (
        Element("mute", "obs", "Mute", "AXCheckBox", "0", True, True, "AX", checked=False),
        Element("deafen", "obs", "Deafen", "AXCheckBox", "0", True, True, "AX", checked=False),
        Element("settings", "obs", "Settings", "AXButton", None, True, True, "AX"),
        Element("search", "obs", "Search", "AXTextField", "", True, True, "AX"),
    )
    return Observation("obs", 7, 11, elements, "Discord")


def semantic_mute_step():
    return SemanticStep(
        SemanticOperation.SET_STATE,
        object_type=ObjectType.SETTING,
        object_label="microphone",
        desired_state=DesiredState.MUTED,
    )


def test_structured_mute_filters_controls_then_laya_selects_supplied_candidate():
    observation = mute_observation()
    table = build_candidates(
        observation,
        "Mute me in Discord",
        allowed_operations={Operation.CLICK},
        semantic_step=semantic_mute_step(),
    )
    choices = table.public_choices(Operation.CLICK)
    assert len(choices) == 1
    assert next(iter(choices.values())).startswith("Mute ")

    model = Model()
    chooser = LayaChooser.__new__(LayaChooser)
    chooser._lock = threading.Lock()
    chooser._model = model
    chooser.device = "cpu"
    decision = chooser.choose_structured("Mute me in Discord", table, [], "", semantic_mute_step())

    assert decision.operation == Operation.CLICK
    assert decision.candidate_id == next(iter(choices))
    assert decision.confidence == 1.0
    assert decision.operation_probability is None
    assert decision.target_probability == 1.0
    assert list(model.questions) == ["click_target"]
    assert set(model.questions["click_target"]["criteria"]) == {"c_0"}
    assert next(iter(choices)) not in model.questions["click_target"]["criteria"]
    assert next(iter(model.questions["click_target"]["criteria"].values())).startswith("Mute ")


def test_structured_chooser_preserves_low_confidence_for_loop_gate():
    base = mute_observation()
    observation = Observation(
        base.snapshot_id,
        base.pid,
        base.window_id,
        base.elements
        + (Element("microphone", "obs", "Microphone", "AXButton", None, True, True, "AX"),),
        base.title,
    )
    table = build_candidates(
        observation,
        "Mute me in Discord",
        allowed_operations={Operation.CLICK},
        semantic_step=semantic_mute_step(),
    )
    chooser = LayaChooser.__new__(LayaChooser)
    chooser._lock = threading.Lock()
    chooser._model = Model(confidence=0.4)
    chooser.device = "cpu"

    decision = chooser.choose_structured("Mute me in Discord", table, [], "", semantic_mute_step())

    # The chooser does not raise its own score; AgentLoop's existing 0.55 gate
    # remains responsible for preventing low-confidence execution.
    assert decision.confidence == 0.4


def test_structured_create_uses_candidate_head_not_generic_operation_head():
    from companion_agent.semantic_planner import SemanticOperation

    observation = Observation(
        "obs",
        7,
        11,
        (Element("compose", "obs", "New message", "AXButton", None, True, True, "AX"),),
        "Mail",
    )
    step = SemanticStep(
        SemanticOperation.CREATE,
        object_type=ObjectType.EMAIL_DRAFT,
        object_label="email draft",
        constraints=("do_not_send",),
    )
    table = build_candidates(
        observation,
        "Open a new email draft",
        allowed_operations={Operation.CLICK},
        semantic_step=step,
    )
    model = Model()
    chooser = LayaChooser.__new__(LayaChooser)
    chooser._lock = threading.Lock()
    chooser._model = model
    chooser.device = "cpu"

    decision = chooser.choose_structured("Open a new email draft", table, [], "", step)

    assert decision.operation == Operation.CLICK
    assert decision.candidate_id in table.public_choices(Operation.CLICK)
    assert decision.operation_probability is None
    assert list(model.questions) == ["click_target"]


def test_structured_chooser_rejects_candidate_outside_filtered_set():
    observation = mute_observation()
    table = build_candidates(
        observation,
        "Mute me in Discord",
        allowed_operations={Operation.CLICK},
        semantic_step=semantic_mute_step(),
    )
    chooser = LayaChooser.__new__(LayaChooser)
    chooser._lock = threading.Lock()
    chooser._model = Model(choice="c_invented")
    chooser.device = "cpu"

    with pytest.raises(DriverError, match="invalid_decision"):
        chooser.choose_structured("Mute me in Discord", table, [], "", semantic_mute_step())
