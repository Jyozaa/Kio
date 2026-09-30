import asyncio
from types import SimpleNamespace

from companion_agent.capabilities import DriverCapabilities
from companion_agent.driver import CuaDriver, classify_error


def tool(name, **fields):
    return {
        "name": name,
        "inputSchema": {"properties": {k: {"type": v} for k, v in fields.items()}},
    }


def contracts():
    return [
        tool("get_window_state", pid="integer", window_id="integer", include_screenshot="boolean"),
        tool(
            "click",
            pid="integer",
            window_id="integer",
            element_token="string",
            capture_id="string",
            x="number",
            y="number",
        ),
        tool("get_browser_state", pid="integer", window_id="integer"),
        tool("browser_click", target_id="string", tab_id="string", ref="string"),
        tool("browser_type", target_id="string", tab_id="string", ref="string"),
    ]


def test_capabilities_require_matching_typed_contracts():
    result = DriverCapabilities.from_tools(contracts())
    assert result.accessibility_tokens and result.capture_bound_pixels and result.structured_browser
    assert not result.visual_regions and not result.visual_regions_contract
    assert not result.background_actions
    assert not DriverCapabilities.from_tools(contracts()[:-1]).structured_browser
    older = contracts()
    del older[1]["inputSchema"]["properties"]["capture_id"]
    assert not DriverCapabilities.from_tools(older).capture_bound_pixels


def test_unknown_duplicate_and_malformed_contracts_fail_closed():
    assert DriverCapabilities.from_tools([]) == DriverCapabilities()
    assert DriverCapabilities.from_tools(contracts() + [contracts()[0]]) == DriverCapabilities()
    assert DriverCapabilities.from_tools([{"name": "click"}]) == DriverCapabilities()
    wrong = contracts()
    wrong[1]["inputSchema"]["properties"]["capture_id"]["type"] = "number"
    assert not DriverCapabilities.from_tools(wrong).capture_bound_pixels


def test_discovery_failure_and_incomplete_list_do_not_grant_authority():
    class Session:
        async def list_tools(self):
            return SimpleNamespace(tools=[], nextCursor="next")

    async def scenario():
        driver = CuaDriver(Session())
        assert await driver.discover_capabilities() == DriverCapabilities()
        driver._session = object()
        assert await driver.discover_capabilities() == DriverCapabilities()

    asyncio.run(scenario())


def test_capture_refusals_are_stale_and_never_request_unbound_retry():
    for code in (
        "capture_generation_mismatch",
        "capture_expired",
        "capture_not_found",
        "capture_frame_mismatch",
        "capture_target_mismatch",
    ):
        assert classify_error(code) == "stale_state"


def test_actual_pinned_release_schema_and_live_discovery():
    import json
    from pathlib import Path

    from mcp.types import Tool

    path = Path(__file__).parents[2] / "fixtures/driver/cua-0.30.2-capabilities.json"
    tools = [Tool.model_validate(t) for t in json.loads(path.read_text())]

    class Session:
        async def list_tools(self):
            return SimpleNamespace(tools=tools, nextCursor=None)

    result = asyncio.run(CuaDriver(Session()).discover_capabilities())
    assert result.accessibility_tokens
    assert result.structured_browser
    assert result.capture_bound_pixels
    assert result.desktop_capture
    assert result.background_actions
    assert result.screenshot
    assert result.bounded_observation
    assert not result.background_type
    assert not result.native_menu
    assert not result.visual_regions
    assert result.visual_regions_contract


def test_extension_only_becomes_active_after_successful_parse():
    from companion_agent.driver import DriverError

    class Session:
        def __init__(self, error=None):
            self.error = error

        async def list_tools(self):
            tools = [
                {
                    "name": "parse_visual_regions",
                    "inputSchema": {"properties": {"capture_id": {"type": "string"}}},
                }
            ]
            return SimpleNamespace(
                tools=[SimpleNamespace(model_dump=lambda **_: tools[0])], nextCursor=None
            )

        async def call_tool(self, name, arguments):
            return SimpleNamespace(
                isError=self.error is not None,
                structuredContent={"code": self.error, "message": "optional parser unavailable"}
                if self.error
                else {"regions": []},
                content=[],
            )

    async def scenario():
        driver = CuaDriver(Session(error="not_installed"))
        await driver.discover_capabilities()
        assert driver.capabilities.visual_regions_contract
        assert not driver.capabilities.visual_regions
        try:
            await driver.parse_visual_regions("one-use-capture")
        except DriverError as error:
            assert error.code == "unsupported"
        else:
            raise AssertionError("missing parser must fail closed")
        assert not driver.capabilities.visual_regions
        driver._session = Session()
        assert (await driver.parse_visual_regions("fresh-capture"))["regions"] == []
        assert driver.capabilities.visual_regions

    asyncio.run(scenario())


def test_window_capture_identity_is_preserved_as_driver_authority():
    import base64

    # Minimal PNG header with a 1x1 IHDR; Driver validates dimensions and signature.
    png = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489")

    class Session:
        async def call_tool(self, name, arguments):
            assert name == "get_window_state"
            assert arguments["include_screenshot"] is True
            image = SimpleNamespace(
                type="image", mimeType="image/png", data=base64.b64encode(png).decode()
            )
            data = {
                "pid": 10,
                "window_id": 20,
                "screenshot_frame_valid": True,
                "screenshot_width": 1,
                "screenshot_height": 1,
                "capture_id": "native-one-use-capture",
                "window_bounds": {"x": 0.0, "y": 0.0, "width": 0.5, "height": 0.5},
                "elements": [],
            }
            return SimpleNamespace(isError=False, structuredContent=data, content=[image])

    async def scenario():
        _, frame = await CuaDriver(Session()).capture(10, 20)
        assert frame.native_capture_id == "native-one-use-capture"
        assert frame.width == frame.height == 1

    asyncio.run(scenario())
