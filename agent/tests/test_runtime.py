import asyncio
from contextlib import asynccontextmanager

from companion_agent.runtime import Runtime


class Driver:
    async def health(self):
        return {"overall": "ok"}

    async def apps(self):
        return {
            "apps": [
                {
                    "name": "Safari",
                    "bundle_id": "com.apple.Safari",
                    "running": True,
                    "pid": 1,
                    "is_browser": True,
                }
            ]
        }

    async def windows(self, pid):
        return {
            "windows": [
                {"window_id": 1, "is_on_screen": True},
                {"window_id": 2, "is_on_screen": True},
            ]
        }


def test_ambiguous_target_and_no_target_never_load_model(monkeypatch):
    @asynccontextmanager
    async def connect():
        yield Driver()

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)

    async def scenario():
        runtime = Runtime()
        for target in ["", "Safari", "Invented"]:
            result = await runtime.run("Click Start", target, asyncio.Event(), lambda *args: None)
            assert result.status == "needs_user"
            assert runtime.chooser is None

    asyncio.run(scenario())


def test_cancel_before_any_connection(monkeypatch):
    async def scenario():
        result = await Runtime().run("cancel", "", asyncio.Event(), lambda *args: None)
        assert result.status == "cancelled"
        assert result.path == "direct"

    asyncio.run(scenario())


def test_runtime_reuses_and_closes_one_cua_connection(monkeypatch):
    counts = {"opened": 0, "closed": 0}

    @asynccontextmanager
    async def connect():
        counts["opened"] += 1
        try:
            yield Driver()
        finally:
            counts["closed"] += 1

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)

    async def scenario():
        runtime = Runtime()
        assert await runtime.health() == "ready"
        assert await runtime.health() == "ready"
        assert counts == {"opened": 1, "closed": 0}
        await runtime.close()
        assert counts == {"opened": 1, "closed": 1}
        assert await runtime.health() == "ready"
        assert counts == {"opened": 2, "closed": 1}
        await runtime.close()
        assert counts == {"opened": 2, "closed": 2}

    asyncio.run(scenario())


def test_ready_prewarm_does_not_block_a_direct_app_open(monkeypatch):
    import threading

    started = threading.Event()
    release = threading.Event()
    loaded = object()

    def slow_load():
        started.set()
        release.wait(timeout=2)
        return loaded

    class AppDriver(Driver):
        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Calculator",
                        "bundle_id": "com.apple.calculator",
                        "running": True,
                        "pid": 3,
                    }
                ]
            }

    @asynccontextmanager
    async def connect():
        yield AppDriver()

    async def execute(*args, **kwargs):
        return {"status": "completed", "pid": 3, "window_id": 5}

    monkeypatch.setenv("KIO_MODEL_MANIFEST", "/test/models/laya.json")
    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)
    monkeypatch.setattr("companion_agent.runtime.execute_direct", execute)
    monkeypatch.setattr("companion_agent.runtime.LayaChooser", slow_load)

    async def scenario():
        runtime = Runtime()
        assert await runtime.health() == "ready"
        assert await asyncio.to_thread(started.wait, 1)
        result = await runtime.run("Open Calculator", "", asyncio.Event(), lambda *args: None)
        assert result.status == "completed"
        assert runtime.chooser is None
        release.set()
        load_task = runtime._chooser_load
        assert load_task is not None
        await load_task
        await asyncio.sleep(0)
        assert runtime.chooser is loaded
        await runtime.close()

    asyncio.run(scenario())


def test_runtime_discards_broken_cua_transport_and_reconnects(monkeypatch):
    from companion_agent.driver import DriverError

    counts = {"opened": 0, "closed": 0, "failed": False}

    class FlakyDriver(Driver):
        async def health(self):
            if not counts["failed"]:
                counts["failed"] = True
                raise DriverError("driver_unavailable", transport_failure=True)
            return {"overall": "ok"}

    @asynccontextmanager
    async def connect():
        counts["opened"] += 1
        try:
            yield FlakyDriver()
        finally:
            counts["closed"] += 1

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)

    async def scenario():
        runtime = Runtime()
        assert await runtime.health() == "driver_unavailable"
        assert counts == {"opened": 1, "closed": 1, "failed": True}
        assert await runtime.health() == "ready"
        assert counts == {"opened": 2, "closed": 1, "failed": True}
        await runtime.close()
        assert counts == {"opened": 2, "closed": 2, "failed": True}

    asyncio.run(scenario())


def test_runtime_keeps_cua_connection_after_request_timeout(monkeypatch):
    from companion_agent.driver import DriverError

    counts = {"opened": 0, "closed": 0, "failed": False}

    class SlowDriver(Driver):
        async def health(self):
            if not counts["failed"]:
                counts["failed"] = True
                raise DriverError("request_timeout")
            return {"overall": "ok"}

    @asynccontextmanager
    async def connect():
        counts["opened"] += 1
        try:
            yield SlowDriver()
        finally:
            counts["closed"] += 1

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)

    async def scenario():
        runtime = Runtime()
        assert await runtime.health() == "request_timeout"
        assert await runtime.health() == "ready"
        assert counts == {"opened": 1, "closed": 0, "failed": True}
        await runtime.close()
        assert counts == {"opened": 1, "closed": 1, "failed": True}

    asyncio.run(scenario())


def test_unqualified_search_uses_only_a_recently_verified_browser_page():
    from companion_agent.runtime import _contextualize_generic_search
    from companion_agent.semantic_planner import SemanticTaskPlanner
    from companion_agent.session_context import RecentAppRef, RecentPageRef, SessionContext

    context = SessionContext(
        current_app="Google Chrome",
        current_bundle_id="com.google.Chrome",
        current_pid=8,
        current_window=12,
        current_page="https://youtube.com/",
    )
    app = RecentAppRef("Google Chrome", "com.google.Chrome", 8, 12, True)
    context.recent_app = app
    context.recent_page = RecentPageRef("https://youtube.com/", app, 12)
    planner = SemanticTaskPlanner()

    contextual = _contextualize_generic_search(planner.plan("Search Minecraft"), context)
    assert contextual.steps[0].parameters == {
        "query": "Minecraft",
        "search_scope": "CURRENT_SITE",
    }
    explicit_global = _contextualize_generic_search(
        planner.plan("Search Google for Minecraft"), context
    )
    assert explicit_global.steps[0].parameters["search_scope"] == "GLOBAL_WEB"

    context.recent_app = RecentAppRef("Notes", "com.apple.Notes", 2, 12, False)
    non_browser = _contextualize_generic_search(planner.plan("Search Minecraft"), context)
    assert non_browser.steps[0].parameters["search_scope"] == "GLOBAL_WEB"


def test_answer_only_calculation_never_connects_to_cua(monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError("answer-only request connected to CUA")

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", forbidden)

    async def scenario():
        runtime = Runtime()
        result = await runtime.run("What is 2 plus 2?", "", asyncio.Event(), lambda *args: None)
        assert result.status == "answered"
        assert result.answer.answer == "4"
        assert result.answer.confidence == 1.0
        assert runtime.chooser is None

    asyncio.run(scenario())


def test_read_only_ui_question_observes_without_mutating(monkeypatch):
    from companion_agent.driver import AccessibleControl, DriverObservation

    class ReadOnlyDriver:
        mutations = 0

        async def health(self):
            return {"overall": "ok"}

        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Discord",
                        "bundle_id": "com.example.discord",
                        "running": True,
                        "active": True,
                        "pid": 1,
                    }
                ]
            }

        async def windows(self, pid):
            return {
                "windows": [
                    {
                        "window_id": 3,
                        "title": "Discord",
                        "is_on_screen": True,
                        "on_current_space": True,
                        "layer": 0,
                        "bounds": {"x": 0, "y": 0, "width": 1000, "height": 800},
                    }
                ]
            }

        async def observe(self, pid, window_id):
            return DriverObservation(
                "snapshot-1",
                pid,
                window_id,
                (
                    AccessibleControl(
                        "e1",
                        "AXButton",
                        "Mute",
                        None,
                        native={
                            "frame": {"x": 24, "y": 720, "w": 48, "h": 40},
                            "enabled": True,
                            "visible": True,
                        },
                    ),
                    AccessibleControl(
                        "e2",
                        "AXButton",
                        "Deafen",
                        None,
                        native={
                            "frame": {"x": 82, "y": 720, "w": 50, "h": 40},
                            "enabled": True,
                            "visible": True,
                        },
                    ),
                ),
            )

    driver = ReadOnlyDriver()

    @asynccontextmanager
    async def connect():
        yield driver

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)

    async def scenario():
        result = await Runtime().run(
            "Where is the mute button in Discord?", "", asyncio.Event(), lambda *args: None
        )
        assert result.status == "answered"
        assert "bottom-left" in result.answer.answer
        assert "Deafen" in result.answer.answer
        assert driver.mutations == 0

    asyncio.run(scenario())


def test_transient_tooltip_not_a_second_task_window():
    from companion_agent.runtime import task_windows

    real = {
        "window_id": 1,
        "is_on_screen": True,
        "on_current_space": True,
        "layer": 0,
        "bounds": {"width": 1000, "height": 800},
    }
    tooltip = {**real, "window_id": 2, "bounds": {"width": 66, "height": 20}}
    assert task_windows([real, tooltip]) == [real]
    second = {**real, "window_id": 3}
    assert len(task_windows([real, second])) == 2
    assert task_windows([{**real, "layer": 10}, {**real, "is_on_screen": False}]) == []


def test_direct_path_never_loads_laya_or_calls_gemini(monkeypatch):
    from companion_agent.system2 import MockSystem2

    class AppDriver(Driver):
        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Calculator",
                        "bundle_id": "com.apple.calculator",
                        "running": True,
                        "pid": 3,
                    }
                ]
            }

    @asynccontextmanager
    async def connect():
        yield AppDriver()

    async def execute(*args):
        return {"status": "completed"}

    def forbidden(*args, **kwargs):
        raise AssertionError("Direct path loaded Laya")

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)
    monkeypatch.setattr("companion_agent.runtime.execute_direct", execute)
    monkeypatch.setattr("companion_agent.runtime.LayaChooser", forbidden)

    async def scenario():
        runtime = Runtime()
        runtime.system2 = MockSystem2()
        result = await runtime.run("Open Calculator", "", asyncio.Event(), lambda *args: None)
        assert result.status == "completed" and result.path == "sequential"
        assert runtime.chooser is None and runtime.system2.calls == 0

    asyncio.run(scenario())


def test_browser_decline_marker_forces_ax_fallback(monkeypatch):
    class BrowserDriver(Driver):
        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Chrome",
                        "bundle_id": "com.google.Chrome",
                        "running": True,
                        "active": True,
                        "pid": 9,
                        "is_browser": True,
                    }
                ]
            }

        async def windows(self, pid):
            return {
                "windows": [
                    {
                        "window_id": 4,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 900, "height": 700},
                    }
                ]
            }

    @asynccontextmanager
    async def connect():
        yield BrowserDriver()

    seen = []

    async def execute(command, driver, cancelled, **kwargs):
        seen.append(kwargs)
        return (
            {"status": "completed", "pid": 9, "window_id": 4}
            if command.kind == "app"
            else {"status": "needs_user", "url": command.value}
        )

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)
    monkeypatch.setattr("companion_agent.runtime.execute_direct", execute)

    async def scenario():
        result = await Runtime().run(
            "Open https://example.com in Chrome",
            "__kio_force_ax__",
            asyncio.Event(),
            lambda *args: None,
        )
        assert result.status == "needs_user"
        assert seen == [{}, {"allow_browser_prepare": False}]

    asyncio.run(scenario())


def test_targetless_browser_consent_survives_sequential_dispatch(monkeypatch):
    class BrowserDriver(Driver):
        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Chrome",
                        "bundle_id": "com.google.Chrome",
                        "running": True,
                        "active": True,
                        "pid": 9,
                        "is_browser": True,
                    }
                ]
            }

    @asynccontextmanager
    async def connect():
        yield BrowserDriver()

    async def execute(*args, **kwargs):
        return {"status": "browser_authorization_required"}

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)
    monkeypatch.setattr("companion_agent.runtime.execute_direct", execute)

    async def scenario():
        runtime = Runtime()
        result = await runtime.run("Search Norbert Wiener", target="")
        assert result.status == "needs_user"
        assert result.reason.startswith("[KIO_BROWSER_ACCESS_REQUIRED]")
        await runtime.close()

    asyncio.run(scenario())


def test_followup_search_uses_live_remembered_browser_without_model(monkeypatch):
    from companion_agent.system2 import MockSystem2

    @asynccontextmanager
    async def connect():
        yield Driver()

    calls = []

    async def execute(command, driver, cancelled, **kwargs):
        calls.append(command)
        return {"status": "completed", "url": command.value, "evidence": ("verified:url",)}

    def forbidden(*args, **kwargs):
        raise AssertionError("Contextual direct search loaded Laya")

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)
    monkeypatch.setattr("companion_agent.runtime.execute_direct", execute)
    monkeypatch.setattr("companion_agent.runtime.LayaChooser", forbidden)

    async def scenario():
        runtime = Runtime()
        runtime.system2 = MockSystem2()
        first = await runtime.run("Open Safari", "", asyncio.Event(), lambda *a: None)
        second = await runtime.run("Search Norbert Wiener", "", asyncio.Event(), lambda *a: None)
        assert first.status == second.status == "completed"
        assert len(calls) == 2
        assert calls[1].application_name == "Safari"
        assert calls[1].value.endswith("q=Norbert+Wiener")
        assert second.evidence == ("verified:url",)
        assert runtime.chooser is None and runtime.system2.calls == 0

    asyncio.run(scenario())


def test_loaded_model_and_runtime_cua_connection_are_reused(monkeypatch):
    from companion_agent.loop import LoopResult

    connections = []
    loads = []

    class SingleWindow(Driver):
        async def windows(self, pid):
            return {"windows": [{"window_id": 1, "is_on_screen": True}]}

    @asynccontextmanager
    async def connect():
        connections.append(1)
        yield SingleWindow()

    class Loop:
        def __init__(self, *args, **kwargs):
            pass

        async def run(self, *args, **kwargs):
            return LoopResult("completed", "test fixture", 1)

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)
    monkeypatch.setattr("companion_agent.runtime.LayaChooser", lambda: loads.append(1) or object())
    monkeypatch.setattr("companion_agent.runtime.AgentLoop", Loop)

    async def scenario():
        runtime = Runtime()
        assert (
            await runtime.run("Click Start", "Safari", asyncio.Event(), lambda *a: None)
        ).status == "completed"
        assert (
            await runtime.run("Click Start", "Safari", asyncio.Event(), lambda *a: None)
        ).status == "completed"
        assert len(loads) == 1 and len(connections) == 1
        await runtime.close()

    asyncio.run(scenario())


def test_compound_goal_compiles_app_prelude_then_reuses_target_for_ui_goal(monkeypatch):
    from companion_agent.loop import LoopResult

    @asynccontextmanager
    async def connect():
        yield type(
            "CompoundDriver",
            (),
            {
                "health": lambda self: _completed(),
                "apps": lambda self: _apps(),
                "windows": lambda self, pid: _windows(),
            },
        )()

    async def _completed():
        return {"overall": "ok"}

    async def _apps():
        return {
            "apps": [
                {
                    "name": "Calculator",
                    "bundle_id": "com.apple.calculator",
                    "running": True,
                    "pid": 42,
                }
            ]
        }

    async def _windows():
        return {"windows": [{"window_id": 7, "is_on_screen": True}]}

    direct_calls = []

    async def execute(command, driver, cancelled, **kwargs):
        direct_calls.append(command)
        return {"status": "completed", "pid": 42}

    class Loop:
        def __init__(self, *args, **kwargs):
            pass

        async def run(self, goal, pid, window, cancelled, **kwargs):
            assert "perform one plus one" in goal.casefold()
            assert (pid, window) == (42, 7)
            assert kwargs["semantic_step"].operation.value == "CUSTOM"
            return LoopResult("completed", "verified", 1)

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)
    monkeypatch.setattr("companion_agent.runtime.execute_direct", execute)
    monkeypatch.setattr("companion_agent.runtime.AgentLoop", Loop)
    monkeypatch.setattr("companion_agent.runtime.LayaChooser", lambda: object())

    async def scenario():
        result = await Runtime().run(
            "Hey Kio, open Calculator and perform one plus one",
            "",
            asyncio.Event(),
            lambda *a: None,
        )
        assert result.status == "completed"
        assert len(direct_calls) == 1 and direct_calls[0].value == "Calculator"

    asyncio.run(scenario())


def test_targetless_frontmost_action_keeps_semantics_through_agent_loop(monkeypatch):
    from companion_agent.loop import LoopResult

    class FrontmostDriver(Driver):
        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Discord",
                        "bundle_id": "com.example.discord",
                        "running": True,
                        "active": True,
                        "pid": 23,
                    }
                ]
            }

        async def windows(self, pid):
            return {
                "windows": [
                    {
                        "window_id": 55,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 900, "height": 700},
                    }
                ]
            }

    @asynccontextmanager
    async def connect():
        yield FrontmostDriver()

    calls = []

    class Loop:
        def __init__(self, *args, **kwargs):
            pass

        async def run(self, goal, pid, window, cancelled, **kwargs):
            calls.append((goal, pid, window, kwargs))
            return LoopResult("completed", "verified", 1)

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)
    monkeypatch.setattr("companion_agent.runtime.AgentLoop", Loop)
    monkeypatch.setattr("companion_agent.runtime.LayaChooser", lambda: object())

    async def scenario():
        result = await Runtime().run("Mute me", cancelled=asyncio.Event())
        assert result.status == "completed"
        assert len(calls) == 1
        goal, pid, window, kwargs = calls[0]
        assert goal == "Mute the microphone"
        assert (pid, window) == (23, 55)
        assert kwargs["semantic_step"].desired_state.value == "MUTED"
        assert kwargs["task_constraints"] == ()

    asyncio.run(scenario())


def test_opened_app_exact_pid_and_window_survive_later_process_activation(monkeypatch):
    from companion_agent.loop import LoopResult

    class MultiProcessMusicDriver(Driver):
        def __init__(self):
            self.window_pids = []

        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Spotify",
                        "bundle_id": "com.example.spotify",
                        "running": True,
                        "active": True,
                        "pid": 43,
                    },
                    {
                        "name": "Spotify",
                        "bundle_id": "com.example.spotify",
                        "running": True,
                        "active": False,
                        "pid": 42,
                    },
                ]
            }

        async def windows(self, pid):
            self.window_pids.append(pid)
            if pid != 42:
                raise AssertionError("runtime discarded the app process returned by open")
            return {
                "windows": [
                    {
                        "window_id": 7,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 900, "height": 700},
                    },
                    {
                        "window_id": 8,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 900, "height": 700},
                    },
                ]
            }

    driver = MultiProcessMusicDriver()

    @asynccontextmanager
    async def connect():
        yield driver

    direct = []
    loop_calls = []

    async def execute(command, driver, cancelled, **kwargs):
        direct.append(command)
        return {"status": "completed", "pid": 42, "window_id": 7}

    class Loop:
        def __init__(self, *args, **kwargs):
            pass

        async def run(self, goal, pid, window, cancelled, **kwargs):
            loop_calls.append((pid, window, kwargs["semantic_step"]))
            return LoopResult("completed", "verified", 1)

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)
    monkeypatch.setattr("companion_agent.runtime.execute_direct", execute)
    monkeypatch.setattr("companion_agent.runtime.AgentLoop", Loop)
    monkeypatch.setattr("companion_agent.runtime.LayaChooser", lambda: object())

    async def scenario():
        result = await Runtime().run("Open Spotify and play a song", cancelled=asyncio.Event())
        assert result.status == "completed"
        assert len(direct) == 1 and direct[0].value == "Spotify"
        assert driver.window_pids == [42]
        assert len(loop_calls) == 1
        pid, window, step = loop_calls[0]
        assert (pid, window) == (42, 7)
        assert step.desired_state.value == "PLAYING"

    asyncio.run(scenario())


def test_stale_window_recovery_reobserves_and_replans_once(monkeypatch):
    from companion_agent.loop import LoopResult

    class ChangingWindowDriver(Driver):
        def __init__(self):
            self.window_calls = []

        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Discord",
                        "bundle_id": "com.example.discord",
                        "running": True,
                        "active": True,
                        "pid": 9,
                    }
                ]
            }

        async def windows(self, pid):
            self.window_calls.append(pid)
            window_id = 7 if len(self.window_calls) == 1 else 8
            return {
                "windows": [
                    {
                        "window_id": window_id,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "layer": 0,
                        "bounds": {"width": 900, "height": 700},
                    }
                ]
            }

    driver = ChangingWindowDriver()

    @asynccontextmanager
    async def connect():
        yield driver

    loop_calls = []

    class Loop:
        def __init__(self, *args, **kwargs):
            pass

        async def run(self, goal, pid, window, cancelled, **kwargs):
            loop_calls.append((goal, pid, window, kwargs["semantic_step"]))
            if len(loop_calls) == 1:
                return LoopResult("error", "stale_state", 0)
            return LoopResult("completed", "verified", 1)

    monkeypatch.setattr("companion_agent.runtime.CuaDriver.connect", connect)
    monkeypatch.setattr("companion_agent.runtime.AgentLoop", Loop)
    monkeypatch.setattr("companion_agent.runtime.LayaChooser", lambda: object())

    async def scenario():
        runtime = Runtime()
        result = await runtime.run("Mute me", cancelled=asyncio.Event())
        assert result.status == "completed"
        assert driver.window_calls == [9, 9]
        assert [(pid, window) for _, pid, window, _ in loop_calls] == [(9, 7), (9, 8)]
        assert all(step.desired_state.value == "MUTED" for *_, step in loop_calls)
        await runtime.close()

    asyncio.run(scenario())
