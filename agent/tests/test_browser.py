import asyncio
from types import SimpleNamespace

from companion_agent.browser import structured_navigate
from companion_agent.candidates import CandidateAction, Operation, build_candidates
from companion_agent.driver import BrowserConsentRequired, CuaDriver, FakeDriver
from companion_agent.perception import PerceptionContext, StructuredBrowserPerceptionProvider


class Session:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    async def call_tool(self, name, arguments):
        self.calls.append((name, arguments))
        response = self.responses.pop(0) if self.responses else {"status": "ok"}
        return SimpleNamespace(isError=False, structuredContent=response, content=[])


def refusal(code="browser_consent_required", detail=None):
    return {
        "status": "refused",
        "refusal": {"code": code, "detail": detail or {"next_action": "browser_prepare"}},
    }


def test_browser_consent_refusal_preserves_detail():
    async def scenario():
        session = Session([refusal(detail={"authorization_required": True})])
        try:
            await CuaDriver(session).browser_state(1, 2)
        except BrowserConsentRequired as error:
            assert error.detail["authorization_required"] is True
        else:
            raise AssertionError("consent refusal must be explicit")

    asyncio.run(scenario())


def test_authorized_browser_prepares_navigates_and_reobserves():
    async def scenario():
        session = Session(
            [
                {"status": "ok"},
                refusal(),
                {"status": "ok", "action": "attached_existing_profile"},
                {"target_id": "t1", "tab_id": "tab1", "url": "about:blank"},
                {"status": "ok"},
                {"target_id": "t1", "tab_id": "tab1", "url": "https://example.com/"},
            ]
        )
        result = await structured_navigate(CuaDriver(session), 1, 2, "https://example.com/")
        assert result.status == "structured"
        assert [name for name, _ in session.calls] == [
            "start_session",
            "get_browser_state",
            "browser_prepare",
            "get_browser_state",
            "browser_navigate",
            "get_browser_state",
            "end_session",
        ]
        assert session.calls[2][1]["strategy"] == {"kind": "existing_profile"}

    asyncio.run(scenario())


def test_consent_then_prepare_required_is_surfaced_to_host():
    async def scenario():
        session = Session([{"status": "ok"}, refusal(), refusal()])
        result = await structured_navigate(CuaDriver(session), 1, 2, "https://example.com/")
        assert result.status == "consent_required"
        assert [name for name, _ in session.calls] == [
            "start_session",
            "get_browser_state",
            "browser_prepare",
        ]

    asyncio.run(scenario())


def test_preparation_failure_falls_back_without_action():
    async def scenario():
        session = Session([{"status": "ok"}, refusal("unsupported")])
        result = await structured_navigate(CuaDriver(session), 1, 2, "https://example.com/")
        assert result.status == "fallback"
        assert [name for name, _ in session.calls] == ["start_session", "get_browser_state"]

    asyncio.run(scenario())


def test_session_start_failure_falls_back_without_losing_direct_route():
    async def scenario():
        session = Session([refusal("driver_unavailable")])
        result = await structured_navigate(CuaDriver(session), 1, 2, "https://example.com/")
        assert result.status == "fallback"
        assert [name for name, _ in session.calls] == ["start_session"]

    asyncio.run(scenario())


def test_user_decline_skips_prepare_and_allows_ax_fallback():
    async def scenario():
        session = Session([{"status": "ok"}, refusal()])
        result = await structured_navigate(
            CuaDriver(session), 1, 2, "https://example.com/", allow_prepare=False
        )
        assert result.status == "fallback"
        assert [name for name, _ in session.calls] == ["start_session", "get_browser_state"]

    asyncio.run(scenario())


def test_browser_requires_setup_still_starts_official_prepare():
    async def scenario():
        session = Session(
            [
                {"status": "ok"},
                refusal("browser_requires_setup"),
                {"status": "ok"},
                {"target_id": "t1", "tab_id": "tab1", "url": "https://example.com/"},
                {"status": "ok"},
                {"target_id": "t1", "tab_id": "tab1", "url": "https://example.com/"},
            ]
        )
        result = await structured_navigate(CuaDriver(session), 1, 2, "https://example.com/")
        assert result.status == "structured"

    asyncio.run(scenario())


def test_structured_browser_provider_keeps_refs_private_and_normalizes_candidates():
    class Browser(FakeDriver):
        async def browser_state(self, pid, window_id, *, session):
            assert session == "kio-browser"
            return {
                "target_id": "t1",
                "tab_id": "tab1",
                "semantic_v2": {
                    "outline": [
                        {"ref": "p3:7", "role": "button", "name": "Compose", "actions": ["click"]},
                        {"ref": "p3:8", "role": "textbox", "name": "To", "actions": ["type"]},
                    ]
                },
            }

    async def scenario():
        provider = StructuredBrowserPerceptionProvider(Browser([{"elements": []}]))
        result = await provider.perceive(PerceptionContext("click Compose", 1, 2))
        assert [element.label for element in result.observation.elements] == ["Compose", "To"]
        element = result.observation.elements[0]
        assert element.source == "STRUCTURED_BROWSER"
        assert element.native["ref"] == "p3:7"

    asyncio.run(scenario())


def test_structured_browser_action_wrapper_uses_same_session_and_no_coordinates():
    async def scenario():
        session = Session([{"status": "ok"}])
        driver = CuaDriver(session)
        action = CandidateAction(
            "c_1",
            "s",
            Operation.CLICK,
            "Compose (button)",
            payload={
                "structured_browser": True,
                "target_id": "t1",
                "tab_id": "tab1",
                "ref": "p3:7",
                "session": "kio-browser",
            },
        )
        await driver.execute(action)
        name, arguments = session.calls[0]
        assert name == "browser_click"
        assert arguments["session"] == "kio-browser"
        assert "x" not in arguments and "y" not in arguments

    asyncio.run(scenario())


def test_structured_browser_refs_survive_candidate_construction_privately():
    from companion_agent.candidates import Element, Observation

    observation = Observation(
        "s1",
        1,
        2,
        (
            Element(
                "e1",
                "s1",
                "Compose",
                "button",
                None,
                True,
                True,
                "STRUCTURED_BROWSER",
                native={
                    "structured_browser": True,
                    "target_id": "t1",
                    "tab_id": "tab1",
                    "ref": "p3:7",
                    "session": "kio-browser",
                },
                interactive=True,
            ),
        ),
    )
    table = build_candidates(observation, "click Compose")
    action = next(item for item in table.actions.values() if item.operation == Operation.CLICK)
    assert action.payload["target_id"] == "t1"
    assert action.payload["tab_id"] == "tab1"
    assert action.payload["ref"] == "p3:7"
    assert "p3:7" not in repr(table.public_choices(Operation.CLICK))
