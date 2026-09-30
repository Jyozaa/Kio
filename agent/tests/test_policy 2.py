import asyncio

import pytest

from companion_agent.candidates import CandidateAction, Element, Observation, Operation
from companion_agent.policy import ActionPolicy, Disposition, PolicyContext


def context(label, goal="", role="AXButton", operation=Operation.CLICK, **native):
    element = Element("e", "s", label, role, "", True, True, "AX", native=native)
    action = CandidateAction("c", "s", operation, label, "e", {"role": role})
    return PolicyContext(
        goal,
        action,
        Observation("s", 1, 2, (element,)),
        app="Fixture",
        url="https://example.invalid",
    )


@pytest.mark.parametrize(
    "label,goal,role,operation,expected",
    [
        ("Buy now", "don't buy this", "AXButton", Operation.CLICK, Disposition.BLOCK),
        ("Buy now", "find the Buy button", "AXButton", Operation.WAIT, Disposition.ALLOW),
        ("Article about delete", "read article", "AXStaticText", Operation.DONE, Disposition.ALLOW),
        ("Delete Account", "delete account", "AXButton", Operation.CLICK, Disposition.ALLOW),
        ("Message", "draft a message", "AXTextField", Operation.TYPE_TEXT, Disposition.ALLOW),
        ("Send", "send draft", "AXButton", Operation.CLICK, Disposition.ALLOW),
        ("Checkout", "view checkout", "AXLink", Operation.CLICK, Disposition.ALLOW),
        ("Pay", "complete checkout", "AXButton", Operation.CLICK, Disposition.BLOCK),
        ("Password", 'type "private"', "AXTextField", Operation.TYPE_TEXT, Disposition.BLOCK),
        ("Code", "enter 2FA", "AXTextField", Operation.TYPE_TEXT, Disposition.BLOCK),
        ("Login", "sign in", "AXSecureTextField", Operation.TYPE_TEXT, Disposition.BLOCK),
        ("Upload", "attach file", "AXButton", Operation.CLICK, Disposition.ALLOW),
        ("Cancel subscription", "unsubscribe", "AXButton", Operation.CLICK, Disposition.ALLOW),
        ("Privacy", "change privacy", "AXButton", Operation.CLICK, Disposition.ALLOW),
        ("Continue", "transfer money", "AXButton", Operation.CLICK, Disposition.ALLOW),
    ],
)
def test_policy_contexts(label, goal, role, operation, expected):
    assert ActionPolicy().evaluate(context(label, goal, role, operation)).disposition == expected


def test_structured_field_and_form_metadata():
    assert (
        ActionPolicy()
        .evaluate(
            context("Field", role="textbox", operation=Operation.TYPE_TEXT, input_type="password")
        )
        .disposition
        == Disposition.BLOCK
    )
    assert ActionPolicy().evaluate(context("Go", form_submit=True)).disposition == Disposition.ALLOW
    assert (
        ActionPolicy().evaluate(context("Switch", security_sensitive=True)).disposition
        == Disposition.BLOCK
    )


def test_ambiguous_target_and_out_of_scope_send():
    from dataclasses import replace

    c = context("Delete", "Delete a file")
    c = replace(
        c,
        observation=replace(
            c.observation,
            elements=(c.observation.elements[0], replace(c.observation.elements[0], id="other")),
        ),
    )
    assert ActionPolicy().evaluate(c).disposition == Disposition.BLOCK
    assert (
        ActionPolicy().evaluate(context("Send", "draft a message")).disposition == Disposition.BLOCK
    )


def test_duplicate_labels_with_distinct_semantic_context_are_not_ambiguous():
    from dataclasses import replace

    selected = Element(
        "selected",
        "s",
        "Play",
        "AXButton",
        "",
        True,
        True,
        "AX",
        native={"region_label": "Now Playing transport controls"},
    )
    row = replace(selected, id="row", native={"row_label": "Album Row 1"})
    action = CandidateAction("c", "s", Operation.CLICK, "Play", "selected", {"role": "AXButton"})
    policy_context = PolicyContext("Play the song", action, Observation("s", 1, 2, (selected, row)))
    assert ActionPolicy().evaluate(policy_context).disposition == Disposition.ALLOW


def test_clipped_duplicate_menu_item_does_not_make_full_item_ambiguous():
    from dataclasses import replace

    full = Element(
        "full",
        "s",
        "Option B",
        "AXMenuItem",
        "",
        True,
        True,
        "AX",
        native={"frame": {"x": 0, "y": 20, "w": 100, "h": 24}},
    )
    clipped = replace(
        full,
        id="clipped",
        native={"frame": {"x": 0, "y": 0, "w": 100, "h": 6}},
    )
    action = CandidateAction("c", "s", Operation.SELECT, "Option B", "full", {"role": "AXMenuItem"})
    policy_context = PolicyContext(
        "Choose Option B", action, Observation("s", 1, 2, (full, clipped))
    )
    assert ActionPolicy().evaluate(policy_context).disposition == Disposition.ALLOW


def test_ordinary_actions_multi_step_send_submit_and_stop():
    from test_loop import WorkflowDriver

    from companion_agent.chooser import MockChooser
    from companion_agent.loop import AgentLoop

    async def scenario():
        driver = WorkflowDriver(["Start", "Continue", "Send", "Submit", "Success"])
        events = []
        chooser = MockChooser(
            [(Operation.CLICK, label, 0.99) for label in ["Start", "Continue", "Send", "Submit"]]
        )
        result = await AgentLoop(driver, chooser, emit=lambda *args: events.append(args)).run(
            "Send the fixture message and submit the fixture form to reach Success",
            1,
            2,
            asyncio.Event(),
        )
        assert result.status == "completed" and len(driver.actions) == 4
        assert all(event[0] != "confirmation_required" for event in events)
        cancelled = asyncio.Event()

        class StopDriver(WorkflowDriver):
            async def execute(self, *args, **kwargs):
                await super().execute(*args, **kwargs)
                cancelled.set()

        driver = StopDriver(["Start", "Continue", "Success"])
        result = await AgentLoop(driver, MockChooser([(Operation.CLICK, "Start", 0.99)])).run(
            "Reach Success", 1, 2, cancelled
        )
        assert result.status == "cancelled" and len(driver.actions) == 1

    asyncio.run(scenario())


@pytest.mark.parametrize("recovery", [False, True])
def test_models_cannot_override_block(recovery):
    from test_loop import WorkflowDriver

    from companion_agent.chooser import MockChooser
    from companion_agent.loop import AgentLoop
    from companion_agent.system2 import MockSystem2

    async def scenario():
        driver = WorkflowDriver(["Buy now"])
        system2 = MockSystem2(focus="Buy now is the next step.")
        choices = ([(Operation.CLICK, "Buy now", 0.1)] if recovery else []) + [
            (Operation.CLICK, "Buy now", 0.99)
        ]
        result = await AgentLoop(driver, MockChooser(choices), system2=system2).run(
            "Buy now", 1, 2, asyncio.Event()
        )
        assert result.status == "needs_user" and not driver.actions
        assert system2.calls == int(recovery)

    asyncio.run(scenario())


def test_secret_entry_never_executes():
    from test_system2 import FieldDriver

    from companion_agent.chooser import MockChooser
    from companion_agent.loop import AgentLoop

    async def scenario():
        driver = FieldDriver()
        driver.snapshots[0]["elements"][0]["label"] = "API key"
        result = await AgentLoop(driver, MockChooser([(Operation.TYPE_TEXT, "API key", 0.99)])).run(
            'Enter "test-secret" into API key field', 1, 2, asyncio.Event()
        )
        assert result.status == "needs_user" and not driver.actions

    asyncio.run(scenario())
