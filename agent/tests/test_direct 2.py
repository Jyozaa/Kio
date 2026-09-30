import pytest

from companion_agent.direct import normalize_url, parse_direct, resolve_app


@pytest.mark.parametrize(
    "value",
    [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "https://user:secret@example.com",
        "https://example.com:99999",
        "https://exa mple.com",
        "https://evil\\example.com",
        "-a Terminal",
        "https://-bad.example",
        "data:text/html,hello",
    ],
)
def test_reject_urls(value):
    assert normalize_url(value) is None


def test_url_and_search():
    assert parse_direct("go to github.com").value == "https://github.com/"
    assert normalize_url("http://localhost:8000") == "http://localhost:8000/"
    assert parse_direct("search Google for Norbert Wiener").value.endswith("q=Norbert+Wiener")
    assert parse_direct("search Google for cats & dogs").value.endswith("cats+%26+dogs")
    chosen = parse_direct("Search Google for Norbert Wiener in Chrome")
    assert chosen.value.endswith("q=Norbert+Wiener")
    assert chosen.application_name == "Chrome"
    chosen = parse_direct("Open https://example.com in Safari")
    assert chosen.value == "https://example.com/"
    assert chosen.application_name == "Safari"
    assert parse_direct("Open Notes").kind == "app"
    spoken_app = parse_direct("Open Calculator.")
    assert spoken_app.kind == "app" and spoken_app.value == "Calculator"
    spoken_search = parse_direct("Open Safari and search for Norbert Wiener.")
    assert spoken_search.kind == "url"
    assert spoken_search.value.endswith("q=Norbert+Wiener")
    assert spoken_search.application_name == "Safari"
    assert parse_direct("cancel").kind == "cancel"
    assert parse_direct("please write an essay") is None
    assert parse_direct("open $(bad)") is None


def test_app_must_be_unique_and_locally_discovered():
    apps = [
        {
            "name": "Notes",
            "bundle_id": "com.apple.Notes",
            "launch_path": "/System/Applications/Notes.app",
        }
    ]
    assert resolve_app("notes", apps)["bundle_id"] == "com.apple.Notes"
    assert (
        resolve_app(
            "Chrome",
            [{"name": "Google Chrome", "bundle_id": "com.google.Chrome", "running": True}],
        )["bundle_id"]
        == "com.google.Chrome"
    )
    assert resolve_app("invented", apps) is None
    assert resolve_app("Notes", apps + [{**apps[0], "bundle_id": "other"}]) is None


def test_duplicate_process_entries_choose_only_active_instance():
    entries = [
        {"name": "Safari", "bundle_id": "com.apple.Safari", "pid": 10, "running": True},
        {
            "name": "Safari",
            "bundle_id": "com.apple.Safari",
            "pid": 20,
            "running": True,
            "active": True,
        },
        {"name": "Safari", "bundle_id": "com.apple.Safari", "pid": 30, "running": True},
    ]
    assert resolve_app("Safari", entries)["pid"] == 20
    assert resolve_app("Safari", [entries[0], entries[2]]) is None


def test_direct_url_needs_independent_destination(monkeypatch):
    import asyncio

    from companion_agent.direct import execute_direct

    async def opened(_):
        pass

    monkeypatch.setattr("companion_agent.direct.open_url", opened)

    class Driver:
        observed = None

        async def observed_url(self, expected, *, pid=None):
            return self.observed

    async def scenario():
        driver = Driver()
        command = parse_direct("open https://example.com")
        assert (await execute_direct(command, driver, asyncio.Event()))["status"] == "needs_user"
        driver.observed = "https://example.com/"
        result = await execute_direct(command, driver, asyncio.Event())
        assert result["status"] == "completed" and result["gemini_calls"] == 0

    asyncio.run(scenario())


def test_explicit_browser_is_used_and_verified_on_that_process(monkeypatch):
    import asyncio

    from companion_agent.direct import execute_direct

    opened = []

    async def open_selected(url, *, application):
        opened.append((url, application["bundle_id"]))

    monkeypatch.setattr("companion_agent.direct.open_url", open_selected)

    class Driver:
        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Google Chrome",
                        "bundle_id": "com.google.Chrome",
                        "running": True,
                        "pid": 42,
                    }
                ]
            }

        async def observed_url(self, expected, *, pid=None):
            return expected if pid == 42 else None

    async def scenario():
        driver = Driver()
        command = parse_direct("Open https://example.com in Chrome")
        result = await execute_direct(command, driver, asyncio.Event())
        assert result["status"] == "completed"
        assert opened == [("https://example.com/", "com.google.Chrome")]

    asyncio.run(scenario())


def test_explicit_browser_uses_structured_route_without_duplicate_open(monkeypatch):
    import asyncio

    from companion_agent.direct import execute_direct

    opened = []

    async def open_selected(*args, **kwargs):
        opened.append((args, kwargs))

    monkeypatch.setattr("companion_agent.direct.open_url", open_selected)

    class Driver:
        def __init__(self):
            self.states = [
                {"target_id": "target", "tab_id": "tab", "url": "about:blank"},
                {"target_id": "target", "tab_id": "tab", "url": "https://example.com/"},
            ]
            self.navigations = 0

        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Google Chrome",
                        "bundle_id": "com.google.Chrome",
                        "running": True,
                        "pid": 42,
                    }
                ]
            }

        async def windows(self, pid):
            return {
                "windows": [
                    {
                        "window_id": 71,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "layer": 0,
                        "bounds": {"width": 900, "height": 700},
                    }
                ]
            }

        async def bring_to_front(self, pid, window_id):
            return {"status": "activated", "verified": True}

        async def browser_state(self, pid=None, window_id=None, *, target_id=None, tab_id=None):
            return self.states[0] if target_id is None else self.states[1]

        async def browser_prepare(self, pid, window_id):
            raise AssertionError("already-authorized browser must not prepare again")

        async def browser_navigate(self, target_id, tab_id, url):
            self.navigations += 1
            assert (target_id, tab_id, url) == ("target", "tab", "https://example.com/")
            return {"status": "ok"}

        async def observed_url(self, expected, *, pid=None):
            raise AssertionError("structured verification must avoid AX URL reread")

    async def scenario():
        driver = Driver()
        result = await execute_direct(
            parse_direct("Open https://example.com in Chrome"), driver, asyncio.Event()
        )
        assert result["status"] == "completed"
        assert result["path"] == "direct_structured_browser"
        assert driver.navigations == 1
        assert opened == []

    asyncio.run(scenario())


def test_unavailable_explicit_browser_never_falls_back_to_default(monkeypatch):
    import asyncio

    from companion_agent.direct import execute_direct

    async def should_not_open(*args, **kwargs):
        pytest.fail("explicit browser selection must not fall back")

    monkeypatch.setattr("companion_agent.direct.open_url", should_not_open)

    class Driver:
        async def apps(self):
            return {"apps": [{"name": "Safari", "bundle_id": "com.apple.Safari", "running": True}]}

    async def scenario():
        result = await execute_direct(
            parse_direct("Open https://example.com in Firefox"), Driver(), asyncio.Event()
        )
        assert result["status"] == "needs_user"

    asyncio.run(scenario())


def test_direct_app_rechecks_running_state():
    import asyncio

    from companion_agent.direct import execute_direct

    class Driver:
        running = False

        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Calculator",
                        "bundle_id": "com.apple.calculator",
                        "launch_path": "/System/Applications/Calculator.app",
                        "running": self.running,
                        "pid": 1 if self.running else None,
                    }
                ]
            }

        async def launch_app(self, _):
            return {"pid": 1, "launch_state": {"process_running": True}}

    async def scenario():
        driver = Driver()
        assert (await execute_direct(parse_direct("Open Calculator"), driver, asyncio.Event()))[
            "status"
        ] == "needs_user"
        driver.running = True
        assert (await execute_direct(parse_direct("Open Calculator"), driver, asyncio.Event()))[
            "status"
        ] == "completed"

    asyncio.run(scenario())


def test_ensure_app_reuses_existing_window_and_verifies_foreground():
    import asyncio

    from companion_agent.direct import ensure_app_ready

    class Driver:
        def __init__(self):
            self.brought = []

        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Notes",
                        "bundle_id": "notes",
                        "running": True,
                        "pid": 42,
                    }
                ]
            }

        async def windows(self, pid):
            return {
                "windows": [
                    {
                        "window_id": 9,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 800, "height": 500},
                    }
                ]
            }

        async def bring_to_front(self, pid, window_id):
            self.brought.append((pid, window_id))
            return {"status": "activated", "verified": True}

        async def launch_app(self, bundle_id):
            raise AssertionError("existing app should be reused")

    async def scenario():
        driver = Driver()
        result = await ensure_app_ready(
            {"name": "Notes", "bundle_id": "notes", "running": True, "pid": 42},
            driver,
            asyncio.Event(),
        )
        assert result["status"] == "completed" and result["reused"]
        assert driver.brought == [(42, 9)]

    asyncio.run(scenario())


def test_ensure_app_activates_running_process_without_an_ordinary_window():
    from companion_agent.direct import ensure_app_ready

    class Driver:
        def __init__(self):
            self.window_ready = False
            self.brought = []
            self.launches = 0

        async def apps(self):
            return {"apps": [{"bundle_id": "x", "running": True, "pid": 4}]}

        async def windows(self, pid):
            return {
                "windows": [
                    {
                        "window_id": 9,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 800, "height": 600},
                    }
                ]
                if self.window_ready
                else []
            }

        async def bring_to_front(self, pid, window_id):
            self.brought.append((pid, window_id))
            self.window_ready = True
            return {"status": "activated"}

        async def launch_app(self, bundle_id):
            self.launches += 1
            raise AssertionError("running process must be reused")

    async def scenario():
        driver = Driver()
        result = await ensure_app_ready({"bundle_id": "x", "pid": 4}, driver, asyncio.Event())
        assert result["status"] == "completed" and result["window_id"] == 9
        assert driver.brought == [(4, None)]
        assert driver.launches == 0

    asyncio.run(scenario())


def test_ensure_app_reobserves_after_activation_resolves_multiple_windows():
    from companion_agent.direct import ensure_app_ready

    class Driver:
        def __init__(self):
            self.activated = False

        async def apps(self):
            return {"apps": [{"bundle_id": "x", "running": True, "pid": 4}]}

        async def windows(self, pid):
            return {
                "windows": [
                    {
                        "window_id": 9,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 800, "height": 600},
                        **({"is_key": True, "active": True} if self.activated else {}),
                    },
                    {
                        "window_id": 10,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 800, "height": 600},
                    },
                ]
            }

        async def bring_to_front(self, pid, window_id):
            if window_id is None:
                self.activated = True
            return {"status": "activated"}

    async def scenario():
        result = await ensure_app_ready({"bundle_id": "x", "pid": 4}, Driver(), asyncio.Event())
        assert result["status"] == "completed" and result["window_id"] == 9

    asyncio.run(scenario())


def test_ensure_app_polls_until_delayed_window_appears_after_one_activation():
    from companion_agent.direct import ensure_app_ready

    class Driver:
        def __init__(self):
            self.window_queries = 0
            self.brought = []

        async def apps(self):
            return {"apps": [{"bundle_id": "x", "running": True, "pid": 4}]}

        async def windows(self, pid):
            self.window_queries += 1
            windows = []
            if self.window_queries >= 4:
                windows = [
                    {
                        "window_id": 12,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 800, "height": 600},
                    }
                ]
            return {"windows": windows}

        async def bring_to_front(self, pid, window_id):
            self.brought.append((pid, window_id))
            return {"status": "activated"}

    async def scenario():
        driver = Driver()
        result = await ensure_app_ready(
            {"bundle_id": "x", "pid": 4}, driver, asyncio.Event(), timeout=2.0
        )
        assert result["status"] == "completed" and result["window_id"] == 12
        assert driver.window_queries >= 4
        assert driver.brought == [(4, None)]

    asyncio.run(scenario())


def test_ensure_app_recovers_from_non_transport_activation_error_and_keeps_polling(monkeypatch):
    import asyncio

    from companion_agent import direct
    from companion_agent.direct import ensure_app_ready
    from companion_agent.driver import DriverError

    class Driver:
        def __init__(self):
            self.window_queries = 0
            self.brought = []
            self.launches = 0

        async def apps(self):
            return {"apps": [{"bundle_id": "x", "running": True, "pid": 4}]}

        async def windows(self, pid):
            self.window_queries += 1
            windows = []
            if self.window_queries >= 4:
                windows = [
                    {
                        "window_id": 12,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 800, "height": 600},
                    }
                ]
            return {"windows": windows}

        async def bring_to_front(self, pid, window_id):
            self.brought.append((pid, window_id))
            raise DriverError("driver_unavailable")

        async def launch_app(self, bundle_id):
            self.launches += 1
            raise AssertionError("a running app must not be launched again")

    async def scenario():
        driver = Driver()
        activations = []

        async def launch_services(bundle_id):
            activations.append(bundle_id)

        monkeypatch.setattr(direct, "activate_app_via_launch_services", launch_services)
        result = await ensure_app_ready(
            {"bundle_id": "x", "pid": 4}, driver, asyncio.Event(), timeout=2.0
        )
        assert result["status"] == "completed" and result["window_id"] == 12
        assert driver.window_queries >= 4
        assert driver.brought == [(4, None)]
        assert activations == ["x"]
        assert driver.launches == 0

    asyncio.run(scenario())


def test_ensure_app_does_not_swallow_activation_transport_loss(monkeypatch):
    import asyncio

    from companion_agent import direct
    from companion_agent.direct import ensure_app_ready
    from companion_agent.driver import DriverError

    class Driver:
        async def apps(self):
            return {"apps": [{"bundle_id": "x", "running": True, "pid": 4}]}

        async def windows(self, pid):
            return {"windows": []}

        async def bring_to_front(self, pid, window_id):
            raise DriverError("driver_unavailable", transport_failure=True)

    async def scenario():
        activations = []

        async def launch_services(bundle_id):
            activations.append(bundle_id)

        monkeypatch.setattr(direct, "activate_app_via_launch_services", launch_services)
        with pytest.raises(DriverError, match="driver_unavailable") as error:
            await ensure_app_ready({"bundle_id": "x", "pid": 4}, Driver(), asyncio.Event())
        assert error.value.transport_failure
        assert activations == []

    asyncio.run(scenario())


def test_ensure_app_waits_for_delayed_key_window_selection():
    from companion_agent.direct import ensure_app_ready

    class Driver:
        def __init__(self):
            self.window_queries = 0
            self.brought = []

        async def apps(self):
            return {"apps": [{"bundle_id": "x", "running": True, "pid": 4}]}

        async def windows(self, pid):
            self.window_queries += 1
            key_ready = self.window_queries >= 4
            return {
                "windows": [
                    {
                        "window_id": 20,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 800, "height": 600},
                        **({"is_key": True, "active": True} if key_ready else {}),
                    },
                    {
                        "window_id": 21,
                        "is_on_screen": True,
                        "on_current_space": True,
                        "bounds": {"width": 800, "height": 600},
                    },
                ]
            }

        async def bring_to_front(self, pid, window_id):
            self.brought.append((pid, window_id))
            return {"status": "activated"}

    async def scenario():
        driver = Driver()
        result = await ensure_app_ready(
            {"bundle_id": "x", "pid": 4}, driver, asyncio.Event(), timeout=2.0
        )
        assert result["status"] == "completed" and result["window_id"] == 20
        assert driver.window_queries >= 4
        assert driver.brought == [(4, None)]

    asyncio.run(scenario())


def test_ensure_app_restores_a_minimized_window_before_launching_another():
    from companion_agent.direct import ensure_app_ready

    class Driver:
        def __init__(self):
            self.brought = []
            self.launched = 0
            self.window = {
                "window_id": 9,
                "is_on_screen": False,
                "is_minimized": True,
                "bounds": {"width": 800, "height": 600},
            }

        async def apps(self):
            return {"apps": [{"bundle_id": "x", "running": True, "pid": 4}]}

        async def windows(self, pid):
            return {"windows": [self.window]}

        async def bring_to_front(self, pid, window_id):
            self.brought.append((pid, window_id))
            self.window = {
                "window_id": 9,
                "is_on_screen": True,
                "is_minimized": False,
                "on_current_space": True,
                "bounds": {"width": 800, "height": 600},
            }
            return {"verified": True}

        async def launch_app(self, bundle_id):
            self.launched += 1
            return {}

    async def scenario():
        driver = Driver()
        result = await ensure_app_ready({"bundle_id": "x", "pid": 4}, driver, asyncio.Event())
        assert result["status"] == "completed" and result["reused"]
        assert driver.brought == [(4, 9)] and driver.launched == 0

    asyncio.run(scenario())


def test_ensure_app_uses_launch_services_for_an_existing_off_space_window(monkeypatch):
    import asyncio

    from companion_agent import direct

    class Driver:
        def __init__(self):
            self.launches = 0
            self.window = {
                "window_id": 81,
                "is_on_screen": False,
                "on_current_space": False,
                "bounds": {"width": 900, "height": 700},
            }

        async def apps(self):
            return {
                "apps": [
                    {
                        "name": "Example",
                        "bundle_id": "com.example.app",
                        "running": True,
                        "pid": 17,
                    }
                ]
            }

        async def windows(self, pid):
            return {"windows": [self.window]}

        async def bring_to_front(self, pid, window_id):
            return {"status": "activated"}

        async def launch_app(self, bundle_id):
            self.launches += 1
            return {}

    async def scenario():
        driver = Driver()
        activations = []
        window_queries = []

        async def launch_services(bundle_id):
            activations.append(bundle_id)

            def delayed_transition():
                if len(window_queries) >= 4:
                    driver.window = {
                        **driver.window,
                        "is_on_screen": True,
                        "on_current_space": True,
                    }

            driver.transition = delayed_transition

        old_windows = driver.windows

        async def delayed_windows(pid):
            window_queries.append(pid)
            if hasattr(driver, "transition"):
                driver.transition()
            return await old_windows(pid)

        driver.windows = delayed_windows

        monkeypatch.setattr(direct, "activate_app_via_launch_services", launch_services)
        result = await direct.ensure_app_ready(
            {"name": "Example", "bundle_id": "com.example.app", "pid": 17},
            driver,
            asyncio.Event(),
        )
        assert result == {
            "status": "completed",
            "pid": 17,
            "window_id": 81,
            "reused": True,
        }
        assert activations == ["com.example.app"]
        assert driver.launches == 0
        assert len(window_queries) >= 4

    asyncio.run(scenario())


def test_google_display_alias_still_requires_exact_destination():
    from companion_agent.direct import destination_matches

    assert destination_matches(
        "https://www.google.com/search?q=Norbert+Wiener",
        "https://google.com/search?q=Norbert+Wiener",
    )
    assert not destination_matches(
        "https://www.google.com/search?q=Norbert+Wiener", "https://google.com/search?q=someone"
    )
    assert not destination_matches(
        "https://www.google.com/search?q=x", "https://google.com.attacker.test/search?q=x"
    )
    assert not destination_matches("https://www.example.com/", "https://example.com/")
    assert destination_matches("http://127.0.0.1:8765/index.html", "127.0.0.1:8765/index.html")


import asyncio
