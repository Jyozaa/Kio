from companion_agent.candidates import normalize
from companion_agent.driver import normalize_window
from companion_agent.objectives import clauses, current_objective


def test_quoted_commas_and_then_are_not_split():
    assert clauses('Enter "hi, choose me then smile" into Message field, then choose option B') == [
        'Enter "hi, choose me then smile" into Message field',
        "choose option B",
    ]


def test_completed_literal_advances_without_rewriting():
    obs = normalize(
        normalize_window(
            {
                "elements": [
                    {
                        "element_index": 1,
                        "role": "AXTextField",
                        "label": "Message",
                        "value": "hello world",
                        "visible": True,
                    }
                ]
            },
            1,
            2,
        )
    )
    goal = 'Enter "hello world" into Message field, choose option B, then reach success'
    assert current_objective(goal, obs) == "choose option B"


def test_explicit_click_progress_requires_action_and_changed_control():
    from companion_agent.candidates import Element, Observation
    from companion_agent.objectives import current_objective

    obs = Observation("s", 1, 2, (Element("e", "s", "Continue", "AXButton", "", True, True, "AX"),))
    goal = "Click Start, then click Continue, then reach Success"
    assert current_objective(goal, obs, []) == "Click Start"
    assert current_objective(goal, obs, ["CLICK: Start (AXButton; value=)"]) == "click Continue"
