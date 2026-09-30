import copy

import pytest

from companion_agent.candidates import Operation, build_candidates, normalize
from companion_agent.chooser import questions_for, validate_response
from companion_agent.driver import DriverError, normalize_window


def case():
    obs = normalize(
        normalize_window(
            {
                "elements": [
                    {"element_index": 1, "role": "AXButton", "label": "Search", "visible": True},
                    {
                        "element_index": 2,
                        "role": "AXTextField",
                        "label": "Message",
                        "visible": True,
                    },
                ]
            },
            1,
            2,
        )
    )
    table = build_candidates(obs, "Search")
    questions = questions_for(table)
    answers = {}
    for head, question in questions.items():
        choices = question["criteria"]
        selected = "CLICK" if head == "operation" else next(iter(choices))
        probs = {key: 0.0 for key in choices}
        probs[selected] = 1.0
        answers[head] = {"choice": selected, "probabilities": probs, "answer_confidence": 1.0}
    return table, questions, {"answers": answers}


def test_matching_head_only():
    table, questions, result = case()
    result["answers"]["type_target"] = {"choice": "untrusted unused speculative answer"}
    decision = validate_response(result, table, questions)
    assert decision.operation == Operation.CLICK
    assert table.actions[decision.candidate_id].description.startswith("Search")
    assert "select_target" not in questions


@pytest.mark.parametrize(
    "corruption",
    ["missing", "foreign", "nan", "negative", "sum", "mismatch", "boolean", "operation"],
)
def test_invalid_answer_rejected(corruption):
    table, questions, original = case()
    result = copy.deepcopy(original)
    answer = result["answers"]["click_target"]
    key = answer["choice"]
    if corruption == "missing":
        del result["answers"]["click_target"]
    elif corruption == "foreign":
        answer["choice"] = "c_foreign"
    elif corruption == "nan":
        answer["answer_confidence"] = float("nan")
    elif corruption == "negative":
        answer["probabilities"][key] = -1
    elif corruption == "sum":
        answer["probabilities"][key] = 0.3
        answer["answer_confidence"] = 0.3
    elif corruption == "mismatch":
        answer["answer_confidence"] = 0.5
    elif corruption == "boolean":
        answer["answer_confidence"] = True
    else:
        result["answers"]["operation"]["choice"] = "EXEC"
    with pytest.raises(DriverError, match="invalid_decision"):
        validate_response(result, table, questions)
