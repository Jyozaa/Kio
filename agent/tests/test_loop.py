import asyncio
import threading

import pytest

from companion_agent.candidates import Operation
from companion_agent.chooser import Decision, MockChooser
from companion_agent.driver import FakeDriver
from companion_agent.loop import AgentLoop


def state(label):
    return {
        "elements": [
            {
                "element_index": 1,
                "element_token": "s12345678:1",
                "role": "AXButton",
                "label": label,
                "visible": True,
            }
        ]
    }


class WorkflowDriver(FakeDriver):
    def __init__(self, labels, *, stall=False):
        super().__init__([state(label) for label in labels])
        self.stage = 0
        self.actions = []
        self.stall = stall
        self.before_observe = None

    async def observe(self, pid, window_id):
        if self.before_observe:
            self.before_observe(self)
        self.observations = self.stage
        return await super().observe(pid, window_id)

    async def execute(self, action, *, text=None):
        self.actions.append(action)
        if not self.stall:
            self.stage = min(self.stage + 1, len(self.snapshots) - 1)
        return {"status": "ok"}


def run(driver, choices, goal="Reach Success", **kwargs):
    return asyncio.run(
        AgentLoop(driver, MockChooser(choices), **kwargs).run(goal, 1, 2, asyncio.Event())
    )


def test_full_loop_reobserves_and_uses_new_tables():
    driver = WorkflowDriver(["Start", "Continue", "Success"])
    result = run(driver, [(Operation.CLICK, "Start", 0.9), (Operation.CLICK, "Continue", 0.9)])
    assert result.status == "completed" and result.steps == 2, result
    assert len({a.snapshot_id for a in driver.actions}) == 2
    assert len({a.id for a in driver.actions}) == 2


def test_loop_follows_compact_native_dialog_then_returns_to_content_window():
    from companion_agent.driver import normalize_window

    class DialogDriver(FakeDriver):
        def __init__(self):
            super().__init__([])
            self.stage = 0
            self.actions = []

        async def windows(self, pid):
            windows = [
                {
                    "pid": pid,
                    "window_id": 2,
                    "title": "Fixture",
                    "bounds": {"x": 0, "y": 0, "width": 1200, "height": 800},
                    "is_on_screen": True,
                    "on_current_space": True,
                    "z_index": 1,
                }
            ]
            if self.stage == 1:
                windows.insert(
                    0,
                    {
                        "pid": pid,
                        "window_id": 3,
                        "title": "Fixture says",
                        "bounds": {"x": 200, "y": 200, "width": 448, "height": 144},
                        "is_on_screen": True,
                        "on_current_space": True,
                        "z_index": 10,
                    },
                )
            return {"windows": windows}

        async def observe(self, pid, window_id):
            if window_id == 3 and self.stage == 1:
                data = {
                    "elements": [
                        {
                            "element_index": 0,
                            "role": "AXWindow",
                            "label": "Fixture says",
                            "frame": {"x": 200, "y": 200, "w": 448, "h": 144},
                        },
                        {
                            "element_index": 1,
                            "role": "AXHeading",
                            "label": "Fixture says",
                            "parent_index": 0,
                            "frame": {"x": 220, "y": 220, "w": 400, "h": 24},
                        },
                        {
                            "element_index": 2,
                            "role": "AXStaticText",
                            "label": "Continue to the local success state?",
                            "parent_index": 0,
                            "frame": {"x": 220, "y": 250, "w": 400, "h": 20},
                        },
                        {
                            "element_index": 3,
                            "role": "AXButton",
                            "label": "OK",
                            "parent_index": 0,
                            "element_token": "s12345678:3",
                            "frame": {"x": 400, "y": 290, "w": 70, "h": 32},
                        },
                    ]
                }
            elif self.stage == 0:
                data = state("Continue")
            else:
                data = {
                    "elements": [
                        {
                            "element_index": 1,
                            "role": "AXStaticText",
                            "label": "Success",
                            "visible": True,
                            "frame": {"x": 10, "y": 10, "w": 100, "h": 20},
                        }
                    ]
                }
            return normalize_window(data, pid, window_id)

        async def execute(self, action, *, text=None):
            self.actions.append(action)
            self.stage += 1
            return {"status": "ok"}

    driver = DialogDriver()
    result = run(
        driver,
        [(Operation.CLICK, "Continue", 0.99), (Operation.CLICK, "OK", 0.99)],
        goal="Click Continue, then reach Success",
    )
    assert result.status == "completed" and result.steps == 2, result
    assert [action.payload["window_id"] for action in driver.actions] == [2, 3]
    assert driver.actions[1].payload["in_system_dialog"] is True


@pytest.mark.parametrize("timeout", [False, True])
def test_edge_triggered_activation_is_dispatched_once_when_verification_is_unknown(timeout):
    from companion_agent.driver import DriverError
    from companion_agent.semantic_planner import SemanticTaskPlanner

    class OneShotDriver(WorkflowDriver):
        async def execute(self, action, *, text=None):
            self.actions.append(action)
            if timeout:
                raise DriverError("request_timeout")

    async def scenario():
        driver = OneShotDriver(["Mute"], stall=True)
        step = SemanticTaskPlanner().plan("Press the mute button").steps[0]
        result = await AgentLoop(
            driver,
            MockChooser([(Operation.CLICK, "Mute", 0.99)]),
        ).run("Press the mute button", 1, 2, asyncio.Event(), semantic_step=step)
        assert len(driver.actions) == 1
        if timeout:
            assert result.status == "error" and result.reason == "request_timeout"
        else:
            assert result.status == "completed" and result.steps == 1

    asyncio.run(scenario())


@pytest.mark.parametrize("label", ["Buy now", "Pay now", "Transfer money"])
def test_final_financial_action_blocked(label):
    driver = WorkflowDriver([label])
    result = run(driver, [(Operation.CLICK, label, 0.99)], goal=f"Click {label}")
    assert result.status == "needs_user"
    assert not driver.actions


def test_low_confidence_never_executes():
    driver = WorkflowDriver(["Start"])
    assert (
        run(driver, [(Operation.CLICK, "Start", 0.3), (Operation.CLICK, "Start", 0.3)]).status
        == "needs_user"
    )
    assert not driver.actions


def test_low_confidence_reobserves_once_before_needs_user():
    class CountingDriver(WorkflowDriver):
        reads = 0

        async def observe(self, pid, window_id):
            self.reads += 1
            return await super().observe(pid, window_id)

    class LowConfidenceChooser:
        calls = 0

        def choose(self, goal, table, history, guidance=""):
            self.calls += 1
            candidate = next(
                item for item in table.actions.values() if item.operation == Operation.CLICK
            )
            return Decision(candidate.id, candidate.snapshot_id, Operation.CLICK, confidence=0.3)

    driver = CountingDriver(["Start"])
    chooser = LowConfidenceChooser()
    result = asyncio.run(AgentLoop(driver, chooser).run("Reach Success", 1, 2, asyncio.Event()))
    assert result.status == "needs_user"
    assert result.reason == "I couldn't reliably identify the right control after a fresh check."
    assert chooser.calls == driver.reads == 2
    assert not driver.actions


def test_explicit_photo_capture_uses_one_exact_accessibility_shutter_and_verifies():
    from companion_agent.semantic_planner import SemanticTaskPlanner

    driver = WorkflowDriver(["Take Photo", "Retake Photo"])
    semantic_step = SemanticTaskPlanner().plan("Take a picture").steps[0]
    result = asyncio.run(
        AgentLoop(driver, None).run(
            "Take a picture", 1, 2, asyncio.Event(), semantic_step=semantic_step
        )
    )
    assert result.status == "completed" and result.steps == 1, result
    assert driver.actions[0].payload["element_index"] == 1


def test_photo_capture_abstains_when_shutter_control_is_ambiguous():
    from companion_agent.semantic_planner import SemanticTaskPlanner

    driver = WorkflowDriver(["Take Photo"])
    driver.snapshots = [
        {
            "elements": [
                {
                    "element_index": index,
                    "element_token": f"s12345678:{index}",
                    "role": "AXButton",
                    "label": label,
                    "visible": True,
                    "enabled": True,
                }
                for index, label in enumerate(("Take Photo", "Capture Photo"), start=1)
            ]
        }
    ]
    semantic_step = SemanticTaskPlanner().plan("Take a picture").steps[0]
    result = asyncio.run(
        AgentLoop(driver, None).run(
            "Take a picture", 1, 2, asyncio.Event(), semantic_step=semantic_step
        )
    )
    assert result.status == "needs_user"
    assert not driver.actions


def test_unverified_photo_capture_is_never_repeated():
    from companion_agent.semantic_planner import SemanticTaskPlanner

    driver = WorkflowDriver(["Take Photo"])
    semantic_step = SemanticTaskPlanner().plan("Take a picture").steps[0]
    result = asyncio.run(
        AgentLoop(driver, None).run(
            "Take a picture", 1, 2, asyncio.Event(), semantic_step=semantic_step
        )
    )
    assert result.status == "needs_user" and result.steps == 1
    assert (
        result.reason
        == "The action was performed once, but its requested result could not be verified."
    )
    assert len(driver.actions) == 1


def test_explicit_control_press_is_dispatched_at_most_once_without_a_verifier():
    from companion_agent.semantic_planner import SemanticOperation, SemanticTaskPlanner

    step = SemanticTaskPlanner().plan("Press the mute button").steps[0]
    assert step.operation == SemanticOperation.ACTIVATE_CONTROL_ONCE
    driver = WorkflowDriver(["Mute"], stall=True)
    result = asyncio.run(
        AgentLoop(driver, MockChooser([(Operation.CLICK, "Mute", 0.99)] * 3)).run(
            "Press the mute button", 1, 2, asyncio.Event(), semantic_step=step
        )
    )
    assert result.status == "completed" and result.steps == 1
    assert "once" in result.reason and len(driver.actions) == 1


def test_stale_driver_refusal_releases_unaccepted_one_shot_claim():
    from companion_agent.driver import DriverError
    from companion_agent.semantic_planner import SemanticTaskPlanner

    class StaleOnceDriver(WorkflowDriver):
        def __init__(self):
            super().__init__(["Mute"], stall=True)
            self.calls = 0

        async def execute(self, action, *, text=None):
            self.calls += 1
            if self.calls == 1:
                raise DriverError("stale_state")
            return await super().execute(action, text=text)

    driver = StaleOnceDriver()
    step = SemanticTaskPlanner().plan("Press the mute button").steps[0]
    result = asyncio.run(
        AgentLoop(driver, MockChooser([(Operation.CLICK, "Mute", 0.99)] * 3)).run(
            "Press the mute button", 1, 2, asyncio.Event(), semantic_step=step
        )
    )
    assert result.status == "completed" and result.steps == 1
    assert driver.calls == 2 and len(driver.actions) == 1


def test_stall_is_bounded():
    driver = WorkflowDriver(["Start"], stall=True)
    result = run(driver, [(Operation.CLICK, "Start", 0.9)] * 4)
    assert result.status == "needs_user" and result.steps == 2


def test_changed_state_rejects_old_decision():
    driver = WorkflowDriver(["Start", "Continue", "Success"])
    calls = 0

    def change(d):
        nonlocal calls
        calls += 1
        if calls == 2:
            d.stage = 1

    driver.before_observe = change
    result = run(driver, [(Operation.CLICK, "Start", 0.9), (Operation.CLICK, "Continue", 0.9)])
    assert result.status == "completed"
    assert len(driver.actions) == 1
    assert driver.actions[0].description.startswith("Continue")


def test_cancel_during_inference_prevents_action():
    async def scenario():
        cancelled = asyncio.Event()
        driver = WorkflowDriver(["Start"])
        entered = threading.Event()
        release = threading.Event()

        class SlowChooser(MockChooser):
            def choose(self, *args):
                entered.set()
                release.wait(timeout=3)
                return super().choose(*args)

        chooser = SlowChooser([(Operation.CLICK, "Start", 0.99)])
        task = asyncio.create_task(AgentLoop(driver, chooser).run("click Start", 1, 2, cancelled))
        await asyncio.to_thread(entered.wait, 2)
        cancelled.set()
        release.set()
        result = await task
        assert result.status == "cancelled"
        assert not driver.actions

    asyncio.run(scenario())


def test_model_done_is_not_proof():
    driver = WorkflowDriver(["Start"])
    assert run(driver, [(Operation.DONE, "", 0.99)] * 3).status == "needs_user"


def test_success_marker_does_not_override_unmet_literal_goal():
    from companion_agent.candidates import normalize
    from companion_agent.driver import normalize_window
    from companion_agent.loop import success_proven

    obs = normalize(
        normalize_window(
            {
                "elements": [
                    {
                        "element_index": 0,
                        "role": "AXStaticText",
                        "label": "Success",
                        "visible": True,
                    },
                    {
                        "element_index": 1,
                        "role": "AXTextField",
                        "label": "Message",
                        "value": "wrong",
                        "visible": True,
                    },
                ]
            },
            1,
            2,
        )
    )
    assert not success_proven('Enter "hello" into Message field then reach Success', obs, "hello")


def test_false_done_reobserves_then_can_make_real_progress():
    driver = WorkflowDriver(["Start", "Success"])
    result = run(driver, [(Operation.DONE, "", 0.99), (Operation.CLICK, "Start", 0.99)])
    assert result.status == "completed" and result.steps == 1
    assert len(driver.actions) == 1 and driver.actions[0].operation == Operation.CLICK
    assert result.evidence and result.evidence[0].observed == "Success"


def test_verified_terminal_state_completes_without_action_capability():
    driver = FakeDriver(
        [
            {
                "elements": [
                    {
                        "element_index": 0,
                        "role": "AXStaticText",
                        "label": "Success",
                        "visible": True,
                    }
                ]
            }
        ]
    )
    result = run(driver, [], goal="Reach Success")
    assert result.status == "completed"
    assert result.steps == 0


def test_twenty_actions_have_fresh_authority_and_bounded_model_history():
    labels = [f"Stage {i}" for i in range(20)] + ["Success"]
    driver = WorkflowDriver(labels)

    class Chooser:
        def choose(self, goal, table, history, guidance=""):
            from companion_agent.chooser import Decision

            assert len(history) <= 6
            action = next(c for c in table.actions.values() if c.operation == Operation.CLICK)
            return Decision(action.id, table.observation.snapshot_id, action.operation, 0.99)

    result = asyncio.run(AgentLoop(driver, Chooser()).run("Reach Success", 1, 2, asyncio.Event()))
    assert result.status == "completed" and result.steps == 20
    assert len({a.id for a in driver.actions}) == len({a.snapshot_id for a in driver.actions}) == 20


def test_model_failure_executes_nothing_then_new_run_recovers():
    driver = WorkflowDriver(["Start", "Success"])

    class BrokenChooser:
        def choose(self, *args):
            raise RuntimeError("injected local model fault")

    with pytest.raises(RuntimeError):
        asyncio.run(AgentLoop(driver, BrokenChooser()).run("Reach Success", 1, 2, asyncio.Event()))
    assert driver.actions == []
    assert run(driver, [(Operation.CLICK, "Start", 0.99)]).status == "completed"


@pytest.mark.parametrize(
    "mutation", ["window_move", "window_change", "app_change", "modal", "disappear"]
)
def test_fresh_target_rebinding_rejects_surface_changes_but_allows_unrelated_changes(mutation):
    from dataclasses import replace

    from companion_agent.driver import AccessibleControl, DriverError

    class Interrupted(WorkflowDriver):
        reads = 0

        async def observe(self, pid, window_id):
            self.reads += 1
            result = await super().observe(pid, window_id)
            if self.reads != 2:
                return result
            if mutation == "disappear":
                raise DriverError("target_missing")
            if mutation == "window_change":
                return replace(result, window_id=window_id + 1)
            if mutation == "app_change":
                return replace(result, pid=pid + 1)
            if mutation == "modal":
                return replace(
                    result,
                    controls=result.controls
                    + (
                        AccessibleControl(
                            "modal", "AXButton", "Cancel", None, native={"visible": True}
                        ),
                    ),
                )
            first = result.controls[0]
            moved = replace(
                first, native={**first.native, "frame": {"x": 100, "y": 100, "w": 100, "h": 30}}
            )
            return replace(result, controls=(moved,))

    driver = Interrupted(["Start"])
    result = run(driver, [(Operation.CLICK, "Start", 0.99), (Operation.CLICK, "Start", 0.1)])
    assert result.status in {"needs_user", "error"}
    if mutation in {"window_change", "app_change", "disappear"}:
        assert driver.actions == []
    else:
        assert len(driver.actions) == 1


def test_cancel_during_observation_has_no_decision_or_action():
    cancelled = asyncio.Event()
    driver = WorkflowDriver(["Start"])
    driver.before_observe = lambda _: cancelled.set()
    chooser = MockChooser([])
    result = asyncio.run(AgentLoop(driver, chooser).run("Reach Success", 1, 2, cancelled))
    assert result.status == "cancelled" and chooser.calls == 0 and not driver.actions


def test_many_scrolls_keep_authority_fresh():
    driver = WorkflowDriver([f"Section {i}" for i in range(20)] + ["Success"])
    result = run(driver, [(Operation.SCROLL_DOWN, "", 0.99)] * 20)
    assert result.status == "completed" and result.steps == 20
    assert len({a.snapshot_id for a in driver.actions}) == 20
