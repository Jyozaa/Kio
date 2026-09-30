import asyncio
import uuid
from types import SimpleNamespace

import pytest

from companion_agent.driver import (
    CuaDriver,
    DriverError,
    FakeDriver,
    classify_error,
    mcp_launch_spec,
    normalize_window,
    wait_for_unix_socket,
)


@pytest.mark.parametrize(
    "upstream,expected",
    [
        ("permissions_pending", "permission_missing"),
        ("TCC denied", "permission_missing"),
        ("stale element token", "stale_state"),
        ("window_id_not_found", "target_missing"),
        ("window_owner_pid_mismatch", "target_missing"),
        ("browser_requires_setup", "unsupported"),
        ("connection closed", "driver_unavailable"),
        ("MCP request timed out", "request_timeout"),
    ],
)
def test_errors(upstream, expected):
    assert classify_error(upstream) == expected


def test_normalized_native_identity_is_private():
    data = {
        "elements": [
            {
                "element_index": 7,
                "role": "AXButton",
                "label": "Help",
                "element_token": "private-token",
                "value": None,
            }
        ]
    }
    first = normalize_window(data, 1, 2)
    second = normalize_window(data, 1, 2)
    assert first.snapshot_id != second.snapshot_id
    assert "private-token" not in repr(first)
    assert first.controls[0].native["element_token"] == "private-token"


def test_fake_observation_and_permissions():
    async def scenario():
        driver = FakeDriver(
            [{"elements": [{"element_index": 0, "role": "AXButton", "label": "OK"}]}]
        )
        assert (await driver.health())["overall"] == "ok"
        assert (await driver.observe(1, 2)).controls[0].label == "OK"
        driver.error = "permission_missing"
        with pytest.raises(DriverError, match="permission_missing"):
            await driver.observe(1, 2)

    asyncio.run(scenario())


class Session:
    def __init__(self, data=None, error=None):
        self.data = data
        self.error = error
        self.calls = []

    async def call_tool(self, name, arguments):
        self.calls.append((name, arguments))
        return SimpleNamespace(
            isError=bool(self.error),
            structuredContent=self.data,
            content=[SimpleNamespace(text=self.error or "")],
        )


def test_real_adapter_contract_without_private_capture():
    async def scenario():
        session = Session({"elements": [{"element_index": 0, "role": "AXButton", "label": "OK"}]})
        driver = CuaDriver(session)
        assert (await driver.observe(1, 2)).controls[0].label == "OK"
        name, args = session.calls[0]
        assert name == "get_window_state"
        assert args["include_screenshot"] is False
        assert "screenshot_out_file" not in args
        with pytest.raises(DriverError, match="unsupported"):
            await driver._read("exec", {})

    asyncio.run(scenario())


def test_permission_error_and_missing_health_checks_fail_closed():
    async def scenario():
        for session in [
            Session(error="permissions_pending: private detail"),
            Session({"schema_version": "1", "overall": "ok", "checks": []}),
        ]:
            with pytest.raises(DriverError, match="^permission_missing$"):
                await CuaDriver(session).health()

    asyncio.run(scenario())


def test_embedded_proxy_uses_private_socket_and_does_not_inherit_keys():
    spec = mcp_launch_spec(
        environ={
            "KIO_CUA_SOCKET": "/tmp/Kio/driver-42/mcp.sock",
            "KIO_CUA_DRIVER_EXECUTABLE": "/Kio.app/Contents/Helpers/cua-driver",
            "KIO_CUA_HOST_BUNDLE_ID": "local.companion.dev",
            "GEMINI_API_KEY": "must-not-cross-boundary",
            "HOME": "/Users/example",
        }
    )
    assert spec.arguments == (
        "mcp",
        "--embedded",
        "--socket",
        "/tmp/Kio/driver-42/mcp.sock",
        "--host-bundle-id",
        "local.companion.dev",
    )
    assert spec.environment["CUA_DRIVER_EMBEDDED"] == "1"
    assert spec.environment["HOME"] == "/Users/example"
    assert "GEMINI_API_KEY" not in spec.environment


def test_embedded_proxy_configuration_fails_closed_without_external_fallback():
    with pytest.raises(DriverError, match="^driver_unavailable$"):
        mcp_launch_spec(
            executable="/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
            environ={"KIO_CUA_SOCKET": "", "KIO_CUA_DRIVER_EXECUTABLE": ""},
        )


def test_wait_for_unix_socket_checks_acceptance(tmp_path):
    async def scenario():
        import socket

        path = f"/tmp/kio-driver-test-{uuid.uuid4().hex}.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(path)
            server.listen(1)
            await wait_for_unix_socket(path, timeout=0.1)
            connection, _ = server.accept()
            connection.close()
        finally:
            server.close()
            from pathlib import Path

            Path(path).unlink(missing_ok=True)

    asyncio.run(scenario())


def test_wait_for_unix_socket_times_out_for_stale_endpoint(tmp_path):
    async def scenario():
        with pytest.raises(DriverError, match="^runtime_unavailable$") as error:
            await wait_for_unix_socket(str(tmp_path / "missing.sock"), timeout=0.01)
        assert not error.value.transport_failure

    asyncio.run(scenario())


def test_mcp_request_timeout_is_task_failure_not_transport_loss():
    class Session:
        async def call_tool(self, name, arguments):
            raise TimeoutError("MCP request timed out")

    async def scenario():
        with pytest.raises(DriverError, match="^request_timeout$") as error:
            await CuaDriver(Session())._read("click", {})
        assert not error.value.transport_failure

    asyncio.run(scenario())


def test_embedded_health_requires_kio_responsibility_chain(monkeypatch):
    class EmbeddedSession:
        def __init__(self, identity, permissions):
            self.identity = identity
            self.permissions = permissions
            self.calls = []

        async def call_tool(self, name, arguments):
            self.calls.append((name, arguments))
            data = self.identity if name == "health_report" else self.permissions
            return SimpleNamespace(isError=False, structuredContent=data, content=[])

    async def scenario():
        monkeypatch.setenv("KIO_CUA_SOCKET", "/tmp/Kio/driver-42/mcp.sock")
        monkeypatch.setenv("KIO_CUA_HOST_BUNDLE_ID", "local.companion.dev")
        identity = {
            "schema_version": "1",
            "overall": "ok",
            "checks": [
                {
                    "name": "bundle_identity",
                    "status": "pass",
                    "data": {"bundle_identifier": "local.companion.dev"},
                }
            ],
        }
        permissions = {
            "accessibility": True,
            "screen_recording": True,
            "source": {"attribution": "host", "host_bundle_id": "local.companion.dev"},
        }
        session = EmbeddedSession(identity, permissions)
        await CuaDriver(session).health()
        assert session.calls == [
            ("health_report", {"include": ["bundle_identity"]}),
            ("check_permissions", {"prompt": False}),
        ]

        session = EmbeddedSession(identity, {**permissions, "source": {"attribution": "caller"}})
        with pytest.raises(DriverError, match="^driver_unavailable$"):
            await CuaDriver(session).health()

        session = EmbeddedSession(
            identity,
            {**permissions, "source": {"attribution": "host", "host_bundle_id": "other.app"}},
        )
        with pytest.raises(DriverError, match="^driver_unavailable$"):
            await CuaDriver(session).health()

    asyncio.run(scenario())


def test_invalid_snapshot_fails():
    with pytest.raises(DriverError, match="unsupported"):
        normalize_window({}, 1, 2)


def test_select_uses_fresh_menu_token_and_fixed_foreground_action():
    from companion_agent.candidates import CandidateAction, Operation

    async def scenario():
        session = Session({"ok": True})
        action = CandidateAction(
            "c",
            "snapshot",
            Operation.SELECT,
            "Option B",
            payload={
                "pid": 1,
                "window_id": 2,
                "element_token": "fresh-menu-token",
                "role": "AXMenuItem",
            },
        )
        await CuaDriver(session).execute(action)
        assert session.calls == [
            (
                "click",
                {
                    "pid": 1,
                    "window_id": 2,
                    "element_token": "fresh-menu-token",
                    "action": "pick",
                    "delivery_mode": "foreground",
                },
            )
        ]

    asyncio.run(scenario())


def test_web_typing_uses_cua_foreground_token_without_coordinates():
    from companion_agent.candidates import CandidateAction, Operation

    async def scenario():
        session = Session({"effect": "unverifiable"})
        action = CandidateAction(
            "c",
            "obs",
            Operation.TYPE_TEXT,
            "Message",
            payload={"pid": 1, "window_id": 2, "element_token": "fresh", "in_web_content": True},
        )
        await CuaDriver(session).execute(action, text="fixture text")
        name, args = session.calls[0]
        assert name == "type_text" and args["delivery_mode"] == "foreground"
        assert args["element_token"] == "fresh" and "x" not in args and "y" not in args

    asyncio.run(scenario())


def test_native_dialog_actions_use_exact_foreground_token():
    from companion_agent.candidates import CandidateAction, Operation

    async def scenario():
        session = Session({"effect": "unverifiable"})
        action = CandidateAction(
            "c",
            "obs",
            Operation.CLICK,
            "Cancel",
            payload={
                "pid": 1,
                "window_id": 2,
                "element_token": "fresh-dialog-token",
                "role": "AXButton",
                "in_system_dialog": True,
            },
        )
        await CuaDriver(session).execute(action)
        name, args = session.calls[0]
        assert name == "click"
        assert args == {
            "pid": 1,
            "window_id": 2,
            "element_token": "fresh-dialog-token",
            "delivery_mode": "foreground",
        }

    asyncio.run(scenario())
