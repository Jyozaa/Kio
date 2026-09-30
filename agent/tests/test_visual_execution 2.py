import asyncio
from dataclasses import replace
from types import SimpleNamespace

import pytest

from companion_agent.candidates import Element, Observation, Operation, build_candidates
from companion_agent.capabilities import DriverCapabilities
from companion_agent.chooser import MockChooser
from companion_agent.driver import CuaDriver, DriverError
from companion_agent.loop import AgentLoop
from companion_agent.perception import BBox, PerceptionFrame, PerceptionResult
from companion_agent.semantic_planner import SemanticTaskPlanner


def make_visual(label="Option B", *, capture=True, confidence=0.9, x=60):
    frame = PerceptionFrame.create(
        b"png bytes",
        "obs-1",
        7,
        9,
        400,
        200,
        BBox(10, 20, 200, 100),
        native_capture_id="native-cap-1" if capture else None,
    )
    element = Element(
        "r_0",
        "obs-1",
        label,
        "AXStaticText",
        label,
        True,
        True,
        "OCR",
        native={"frame": {"x": x, "y": 45, "w": 40, "h": 10}},
        sources=("OCR",),
        confidence=confidence,
        interactive=False,
        capture_id=frame.capture_id,
    )
    return Observation("obs-1", 7, 9, (element,), "Canvas"), frame


def test_visual_candidates_are_goal_grounded_bounded_and_model_has_no_coordinates():
    observation, frame = make_visual()
    table = build_candidates(observation, "Click Option B", visual_frame=frame)
    visual = [a for a in table.actions.values() if a.payload.get("visual")]
    assert len(visual) == 1
    action = visual[0]
    assert action.operation == Operation.CLICK
    assert action.payload["capture_id"] == "native-cap-1"
    assert action.payload["goal_target"] == "option"
    assert (action.payload["x"], action.payload["y"]) == (140, 60)
    public = table.public_choices(Operation.CLICK)
    assert "Option B" in next(iter(public.values()))
    assert '"x"' not in repr(public) and "native-cap-1" not in repr(public)
    assert not build_candidates(observation, "Click Settings", visual_frame=frame).public_choices(
        Operation.CLICK
    )


@pytest.mark.parametrize(
    ("utterance", "label"),
    [
        ("Press the mute button", "Mute"),
        ("Search the current site for Minecraft", "Search videos"),
    ],
)
def test_semantic_activation_and_search_can_focus_a_fresh_visual_target(utterance, label):
    observation, frame = make_visual(label)
    step = SemanticTaskPlanner().plan(utterance).steps[0]
    table = build_candidates(
        observation,
        utterance,
        visual_frame=frame,
        allowed_operations={Operation.CLICK},
        semantic_step=step,
    )
    visual = [action for action in table.actions.values() if action.payload.get("visual")]
    assert len(visual) == 1
    assert visual[0].operation == Operation.CLICK
    assert visual[0].payload["capture_id"] == frame.native_capture_id


@pytest.mark.parametrize("kwargs", [{"capture": False}, {"confidence": 0.49}, {"x": 1}])
def test_unbound_low_confidence_or_clipped_regions_never_become_visual_actions(kwargs):
    observation, frame = make_visual(**kwargs)
    table = build_candidates(observation, "Click Option B", visual_frame=frame)
    assert not [a for a in table.actions.values() if a.payload.get("visual")]


def test_duplicate_visual_labels_remain_distinct_candidates():
    observation, frame = make_visual()
    repeated = Element(
        "r_1",
        "obs-1",
        "Option B",
        "AXStaticText",
        "Option B",
        True,
        True,
        "OCR",
        native={"frame": {"x": 150, "y": 45, "w": 40, "h": 10}},
        confidence=0.9,
        capture_id=frame.capture_id,
    )
    table = build_candidates(
        Observation("obs-1", 7, 9, (observation.elements[0], repeated), "Canvas"),
        "Click Option B",
        visual_frame=frame,
    )
    choices = [a for a in table.actions.values() if a.payload.get("visual")]
    assert len(choices) == 2
    assert len({a.payload["x"] for a in choices}) == 2


def test_visual_candidate_can_use_ocr_provenance_when_ax_text_is_noninteractive():
    observation, frame = make_visual()
    element = observation.elements[0]
    ax_text = Element(
        element.id,
        element.snapshot_id,
        element.label,
        "AXStaticText",
        element.value,
        True,
        True,
        "AX",
        native=element.native,
        sources=("AX", "OCR"),
        confidence=element.confidence,
        capture_id=element.capture_id,
    )
    table = build_candidates(
        Observation("obs-1", 7, 9, (ax_text,), "Canvas"),
        "Click Option B",
        visual_frame=frame,
    )
    assert any(action.payload.get("visual") for action in table.actions.values())


def test_ax_and_visual_authorities_coexist_for_one_semantic_control():
    _, frame = make_visual("Continue")
    control = Element(
        "ax-continue",
        "obs-1",
        "Continue",
        "AXButton",
        "",
        True,
        True,
        "AX",
        native={
            "element_token": "fresh-ax-token",
            "element_index": 5,
            "frame": {"x": 60, "y": 45, "w": 40, "h": 10},
        },
        sources=("AX", "VISUAL"),
        capture_id=frame.capture_id,
    )
    table = build_candidates(
        Observation("obs-1", 7, 9, (control,), "Canvas"),
        "Press Continue",
        visual_frame=frame,
    )
    candidates = [
        action
        for action in table.actions.values()
        if action.operation == Operation.CLICK and action.element_id
    ]
    assert {action.payload["authority"] for action in candidates} == {"ACCESSIBILITY", "VISUAL"}
    assert any(action.payload.get("element_token") == "fresh-ax-token" for action in candidates)
    assert any(action.payload.get("capture_id") == "native-cap-1" for action in candidates)


def test_visual_target_matching_tolerates_one_ocr_character_error():
    observation, frame = make_visual("Settcngs")
    table = build_candidates(observation, "Click Settings", visual_frame=frame)
    action = next(action for action in table.actions.values() if action.payload.get("visual"))
    assert action.payload["goal_target"] == "settings"


def test_cua_visual_source_is_candidate_eligible_but_model_sees_no_coordinates():
    observation, frame = make_visual()
    element = observation.elements[0]
    visual = Element(
        element.id,
        element.snapshot_id,
        element.label,
        element.role,
        element.value,
        element.enabled,
        element.visible,
        "VISUAL",
        native=element.native,
        sources=("VISUAL",),
        confidence=element.confidence,
        interactive=False,
        capture_id=element.capture_id,
    )
    table = build_candidates(
        Observation("obs-1", 7, 9, (visual,), "Canvas"), "Click Option B", visual_frame=frame
    )
    action = next(item for item in table.actions.values() if item.payload.get("visual"))
    assert action.operation == Operation.CLICK
    assert "native-cap-1" not in repr(table.public_choices(Operation.CLICK))


def test_visual_progress_uses_canonical_goal_target_despite_ocr_spelling():
    from companion_agent.candidates import Element, Observation
    from companion_agent.objectives import current_objective

    observation = Observation(
        "s2", 1, 2, (Element("e2", "s2", "Continue", "AXStaticText", "", True, True, "OCR"),)
    )
    goal = "Click Settings, then click Continue, then reach Success"
    history = ["CLICK: Settings (visual OCR target)"]
    assert current_objective(goal, observation, history) == "click Continue"


def test_visual_execution_uses_only_exact_capture_and_never_retries_unbound():
    class Session:
        def __init__(self, error=False):
            self.calls = []
            self.error = error

        async def call_tool(self, name, arguments):
            self.calls.append((name, arguments))
            return SimpleNamespace(
                isError=self.error,
                structuredContent={"error": "capture_generation_mismatch"}
                if self.error
                else {"status": "ok"},
                content=[SimpleNamespace(text="capture_generation_mismatch")] if self.error else [],
            )

    async def scenario(error=False):
        observation, frame = make_visual()
        action = next(
            item
            for item in build_candidates(
                observation, "Click Option B", visual_frame=frame
            ).actions.values()
            if item.payload.get("visual")
        )
        session = Session(error)
        driver = CuaDriver(session)
        driver.capabilities = DriverCapabilities(capture_bound_pixels=True)
        if error:
            with pytest.raises(DriverError, match="stale_state"):
                await driver.execute(action)
        else:
            await driver.execute(action)
        return session.calls

    calls = asyncio.run(scenario())
    assert len(calls) == 1 and calls[0][0] == "click"
    args = calls[0][1]
    assert args["capture_id"] == "native-cap-1"
    assert (args["x"], args["y"]) == (140, 60)
    assert "element_token" not in args
    error_calls = asyncio.run(scenario(error=True))
    assert len(error_calls) == 1 and "capture_id" in error_calls[0][1]


def test_loop_refreshes_visual_capture_and_rebinds_target_after_unrelated_pixel_changes():
    class Provider:
        def __init__(self, changed=False):
            self.changed = changed
            self.calls = 0

        async def perceive(self, context):
            self.calls += 1
            if self.calls <= 2:
                observation, frame = make_visual("Continue")
                if self.calls == 2 and self.changed:
                    frame = PerceptionFrame.create(
                        b"different pixels",
                        "obs-1",
                        7,
                        9,
                        400,
                        200,
                        BBox(10, 20, 200, 100),
                        native_capture_id="native-cap-2",
                    )
                else:
                    frame = PerceptionFrame.create(
                        b"png bytes",
                        "obs-1",
                        7,
                        9,
                        400,
                        200,
                        BBox(10, 20, 200, 100),
                        native_capture_id=f"native-cap-{self.calls}",
                    )
                observation = replace(
                    observation,
                    elements=tuple(
                        replace(element, capture_id=frame.capture_id)
                        for element in observation.elements
                    ),
                )
                return PerceptionResult(observation, frame=frame, used_visual=True)
            success = Observation(
                "obs-success",
                7,
                9,
                (
                    Element(
                        "success",
                        "obs-success",
                        "Success",
                        "AXStaticText",
                        "Success",
                        True,
                        True,
                        "AX",
                    ),
                ),
                "Canvas",
            )
            return PerceptionResult(success)

    class Driver:
        capabilities = DriverCapabilities(capture_bound_pixels=True)

        def __init__(self):
            self.actions = []

        async def execute(self, action, *, text=None):
            self.actions.append(action)
            return {"status": "ok"}

    async def scenario(changed):
        provider, driver = Provider(changed), Driver()
        result = await AgentLoop(
            driver,
            MockChooser([(Operation.CLICK, "Continue", 0.99)]),
            perception=provider,
        ).run("Click Continue then reach Success", 7, 9, asyncio.Event())
        return result, provider, driver

    result, provider, driver = asyncio.run(scenario(False))
    assert result.status == "completed" and result.steps == 1
    assert provider.calls == 3
    assert driver.actions[0].payload["capture_id"] == "native-cap-2"
    result, _, driver = asyncio.run(scenario(True))
    assert result.status == "completed" and result.steps == 1
    assert driver.actions[0].payload["capture_id"] == "native-cap-2"


def test_current_site_visual_focus_requires_fresh_ax_authority_before_typing():
    class Provider:
        def __init__(self, driver):
            self.driver = driver
            self.calls = 0

        async def perceive(self, context):
            self.calls += 1
            if self.driver.stage == "visual":
                observation, _ = make_visual("Search videos")
                frame = PerceptionFrame.create(
                    f"visual capture {self.calls}".encode(),
                    observation.snapshot_id,
                    7,
                    9,
                    400,
                    200,
                    BBox(10, 20, 200, 100),
                    native_capture_id=f"search-cap-{self.calls}",
                )
                observation = replace(
                    observation,
                    title="Browser|kio_tab_id=tab-1|kio_url=https://youtube.com/",
                    elements=tuple(
                        replace(element, capture_id=frame.capture_id)
                        for element in observation.elements
                    ),
                )
                return PerceptionResult(observation, frame=frame, used_visual=True)
            if self.driver.stage in {"field", "query"}:
                query = "Minecraft" if self.driver.stage == "query" else ""
                elements = [
                    Element(
                        "field",
                        "search-page",
                        "Search videos",
                        "AXSearchField",
                        query,
                        True,
                        True,
                        "AX",
                        native={
                            "element_token": "fresh-search-field",
                            "in_web_content": True,
                            "frame": {"x": 80, "y": 80, "w": 200, "h": 30},
                        },
                    ),
                    Element(
                        "submit",
                        "search-page",
                        "Search",
                        "AXButton",
                        None,
                        True,
                        True,
                        "AX",
                        native={
                            "element_token": "fresh-search-submit",
                            "in_web_content": True,
                            "frame": {"x": 300, "y": 80, "w": 40, "h": 30},
                        },
                    ),
                ]
                title = "Browser|kio_tab_id=tab-1|kio_url=https://youtube.com/"
                return PerceptionResult(Observation("search-page", 7, 9, tuple(elements), title))
            result = Observation(
                "search-results",
                7,
                9,
                (
                    Element(
                        "result",
                        "search-results",
                        "Minecraft videos",
                        "AXLink",
                        None,
                        True,
                        True,
                        "AX",
                    ),
                ),
                "Browser|kio_tab_id=tab-1|kio_url=https://youtube.com/results?search_query=Minecraft",
            )
            return PerceptionResult(result)

    class Driver:
        capabilities = DriverCapabilities(capture_bound_pixels=True)

        def __init__(self):
            self.stage = "visual"
            self.actions = []

        async def execute(self, action, *, text=None):
            self.actions.append((action.operation, action.payload, text))
            if action.payload.get("visual") is True:
                self.stage = "field"
            elif action.operation == Operation.TYPE_TEXT:
                self.stage = "query"
            elif action.operation == Operation.CLICK:
                self.stage = "results"
            return {"status": "ok"}

    async def scenario():
        driver = Driver()
        provider = Provider(driver)
        step = SemanticTaskPlanner().plan("Search the current site for Minecraft").steps[0]
        result = await AgentLoop(
            driver,
            MockChooser(
                [
                    (Operation.CLICK, "Search videos", 0.99),
                    (Operation.TYPE_TEXT, "Search videos", 0.99),
                    (Operation.CLICK, "Search", 0.99),
                ]
            ),
            perception=provider,
        ).run(
            "Search for Minecraft on the current page",
            7,
            9,
            asyncio.Event(),
            semantic_step=step,
        )
        assert result.status == "completed" and result.steps == 3
        assert [operation for operation, _, _ in driver.actions] == [
            Operation.CLICK,
            Operation.TYPE_TEXT,
            Operation.CLICK,
        ]
        assert driver.actions[0][1].get("visual") is True
        assert driver.actions[1][2] == "Minecraft"
        assert driver.actions[1][1].get("element_token") == "fresh-search-field"

    asyncio.run(scenario())
