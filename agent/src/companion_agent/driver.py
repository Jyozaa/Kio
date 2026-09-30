"""Read-only official CUA MCP adapter. No model-facing tool dispatch exists."""

import asyncio
import base64
import errno
import json
import os
import re
import shutil
import socket
import struct
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field, replace
from datetime import timedelta
from typing import Protocol

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from .capabilities import DriverCapabilities
from .metrics import timed


class DriverError(Exception):
    def __init__(self, code: str, detail: dict | None = None, *, transport_failure: bool = False):
        self.code = code
        self.detail = detail or {}
        self.transport_failure = transport_failure
        super().__init__(code)


class BrowserConsentRequired(DriverError):
    """CUA requires the host's explicit browser-profile authorization."""

    def __init__(self, detail: dict | None = None):
        super().__init__("browser_consent_required", detail)


@dataclass(frozen=True)
class MCPLaunchSpec:
    executable: str
    arguments: tuple[str, ...]
    environment: dict[str, str] | None
    socket_path: str | None = None


def mcp_launch_spec(executable: str | None = None, environ: dict[str, str] | None = None):
    """Build a bounded proxy command; embedded mode never falls back externally."""
    environ = os.environ if environ is None else environ
    if "KIO_CUA_SOCKET" in environ:
        socket_path = environ.get("KIO_CUA_SOCKET", "")
        embedded_executable = environ.get("KIO_CUA_DRIVER_EXECUTABLE", "")
        host_bundle_id = environ.get("KIO_CUA_HOST_BUNDLE_ID", "")
        if (
            not socket_path.startswith("/")
            or len(os.fsencode(socket_path)) >= 100
            or not embedded_executable.startswith("/")
            or not host_bundle_id
        ):
            raise DriverError("driver_unavailable")
        safe_environment = {
            key: environ[key]
            for key in ("HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE")
            if key in environ
        }
        safe_environment.update(
            {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CUA_DRIVER_EMBEDDED": "1",
                "CUA_DRIVER_HOST_BUNDLE_ID": host_bundle_id,
            }
        )
        return MCPLaunchSpec(
            embedded_executable,
            ("mcp", "--embedded", "--socket", socket_path, "--host-bundle-id", host_bundle_id),
            safe_environment,
            socket_path,
        )

    executable = executable or shutil.which("cua-driver")
    if not executable:
        installed = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
        if os.path.isfile(installed) and os.access(installed, os.X_OK):
            executable = installed
    if not executable:
        raise DriverError("driver_unavailable")
    # API keys and other credentials are needed by the Kio helper only. Do not
    # copy them into a separate CUA process environment.
    safe_environment = {
        key: value
        for key, value in environ.items()
        if not any(secret in key.upper() for secret in ("KEY", "TOKEN", "PASSWORD", "SECRET"))
    }
    return MCPLaunchSpec(executable, ("mcp",), safe_environment)


async def wait_for_unix_socket(path: str, timeout: float = 10.0) -> None:
    """Wait for a local daemon endpoint to accept a connection, without launching it."""
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if client.connect_ex(path) == 0:
                return
        except OSError:
            pass
        finally:
            client.close()
        await asyncio.sleep(0.05)
    # The host process can still be starting or the endpoint may be unavailable
    # without the supervisor daemon having exited.  Do not turn a startup
    # timeout into a restart request; the supervisor owns process recovery.
    raise DriverError("runtime_unavailable")


def classify_error(text: str) -> str:
    text = text.lower()
    if any(marker in text for marker in ("timed out", "timeout", "deadline exceeded")):
        return "request_timeout"
    if "browser_consent_required" in text:
        return "browser_consent_required"
    # Keep the historical classifier contract for generic setup refusals.  A
    # structured refusal with this exact code is preserved by _read below so
    # the browser route can still initiate the documented preparation flow.
    if "browser_requires_setup" in text:
        return "unsupported"
    if "authorization_declined" in text or "authorization_canceled" in text:
        return "browser_authorization_declined"
    if "same_pid_keyboard_ambiguity" in text:
        return "ambiguous_target"
    if any(word in text for word in ("permission", "accessibility denied", "tcc")):
        return "permission_missing"
    if any(
        word in text
        for word in (
            "stale",
            "expired",
            "invalid_element_token",
            "capture_generation_mismatch",
            "capture_not_found",
            "capture_frame_mismatch",
            "capture_target_mismatch",
        )
    ):
        return "stale_state"
    if any(
        word in text for word in ("window_id_not_found", "target_missing", "owner_pid_mismatch")
    ):
        return "target_missing"
    if any(word in text for word in ("unsupported", "requires_setup", "unknown tool")):
        return "unsupported"
    return "driver_unavailable"


def is_transport_failure(error: Exception) -> bool:
    if isinstance(error, (BrokenPipeError, ConnectionError, EOFError)):
        return True
    if isinstance(error, OSError):
        return error.errno in {
            errno.EPIPE,
            errno.ECONNRESET,
            errno.ECONNABORTED,
            errno.ENOTCONN,
            errno.ESHUTDOWN,
        }
    name = type(error).__name__.casefold()
    text = str(error).casefold()
    return name in {
        "brokenresourceerror",
        "closedresourceerror",
        "endofstream",
        "transportclosed",
    } or any(
        marker in text
        for marker in (
            "broken pipe",
            "connection closed",
            "connection reset",
            "end of stream",
            "transport closed",
            "client is not connected",
        )
    )


@dataclass(frozen=True)
class AccessibleControl:
    local_id: str
    role: str
    label: str
    value: str | None
    source: str = "AX"
    native: dict = field(default_factory=dict, repr=False, compare=False)


@dataclass(frozen=True)
class DriverObservation:
    snapshot_id: str
    pid: int
    window_id: int
    controls: tuple[AccessibleControl, ...]
    degraded_reason: str | None = None


class ComputerDriver(Protocol):
    async def health(self) -> dict: ...
    async def apps(self) -> dict: ...
    async def windows(self, pid: int) -> dict: ...
    async def observe(self, pid: int, window_id: int) -> DriverObservation: ...


def normalize_window(data: dict, pid: int, window_id: int) -> DriverObservation:
    elements = data.get("elements")
    if not isinstance(elements, list):
        raise DriverError("unsupported")
    controls = []
    for index, row in enumerate(elements):
        if not isinstance(row, dict) or not isinstance(row.get("element_index"), int):
            raise DriverError("unsupported")
        native = dict(row)
        if not isinstance(native.get("frame"), dict):
            native["frame"] = {}
        controls.append(
            AccessibleControl(
                local_id=f"e_{index:04d}",
                role=str(row.get("role", "")),
                label=str(row.get("label", "")),
                value=None if row.get("value") is None else str(row["value"]),
                native=native,
            )
        )
    return DriverObservation(
        uuid.uuid4().hex, pid, window_id, tuple(controls), data.get("degraded_reason")
    )


class CuaDriver:
    """Persistent MCP transport preserves Driver session/snapshot identity."""

    def __init__(self, session: ClientSession):
        self._session = session
        self.capabilities = DriverCapabilities()

    @classmethod
    @asynccontextmanager
    async def connect(cls, executable: str | None = None):
        launch = mcp_launch_spec(executable)
        try:
            # App-daemon proxy only: never --direct, bare serve or permission bypass.
            if launch.socket_path:
                await wait_for_unix_socket(launch.socket_path)
            with open(os.devnull, "w") as errors:  # noqa: ASYNC230 -- local null device only
                async with (
                    stdio_client(
                        StdioServerParameters(
                            command=launch.executable,
                            args=list(launch.arguments),
                            env=launch.environment,
                        ),
                        errlog=errors,
                    ) as (reader, writer),
                    ClientSession(
                        reader, writer, read_timeout_seconds=timedelta(seconds=20)
                    ) as session,
                ):
                    await session.initialize()
                    driver = cls(session)
                    await driver.discover_capabilities()
                    yield driver
        except DriverError:
            raise
        except Exception as error:  # noqa: BLE001 -- sanitize the external provider boundary
            # Upstream exceptions may contain private content; expose only our stable code.
            transport_failure = is_transport_failure(error)
            code = "runtime_transport_lost" if transport_failure else classify_error(str(error))
            raise DriverError(code, transport_failure=transport_failure) from None

    async def discover_capabilities(self) -> DriverCapabilities:
        """Read the connected server's schema; never infer support from its version."""
        try:
            response = await self._session.list_tools()
            tools = [tool.model_dump(mode="json", exclude_none=True) for tool in response.tools]
            # An incomplete/paginated list cannot prove missing or paired contracts.
            if response.nextCursor:
                self.capabilities = DriverCapabilities()
            else:
                self.capabilities = DriverCapabilities.from_tools(tools)
        except Exception:  # noqa: BLE001 -- optional discovery fails closed
            self.capabilities = DriverCapabilities()
        return self.capabilities

    async def _read(self, name: str, arguments: dict) -> dict:
        if name not in {
            "health_report",
            "check_permissions",
            "list_apps",
            "list_windows",
            "get_window_state",
            "get_browser_state",
            "start_session",
            "end_session",
            "browser_prepare",
            "browser_navigate",
            "browser_click",
            "browser_type",
            "browser_pointer",
            "browser_dialog",
            "browser_set_input_files",
            "browser_download",
            "parse_visual_regions",
            "launch_app",
            "click",
            "type_text",
            "scroll",
            "bring_to_front",
        }:
            raise DriverError("unsupported")
        try:
            result = await self._session.call_tool(name, arguments)
        except Exception as error:  # noqa: BLE001 -- sanitize the external provider boundary
            transport_failure = is_transport_failure(error)
            code = "runtime_transport_lost" if transport_failure else classify_error(str(error))
            raise DriverError(code, transport_failure=transport_failure) from None
        # CUA reports a truthful, bounded foreground result as a partial tool
        # error when another ordinary window remains frontmost.  Preserve that
        # structured status so callers can verify the exact target instead of
        # treating it as a transport outage.
        if result.isError and not (
            isinstance(result.structuredContent, dict)
            and result.structuredContent.get("status") == "partial"
        ):
            text = " ".join(getattr(block, "text", "") for block in result.content)
            if is_transport_failure(RuntimeError(text)):
                raise DriverError("runtime_transport_lost", transport_failure=True)
            raise DriverError(classify_error(text))
        data = result.structuredContent
        if data is None:
            for block in result.content:
                try:
                    candidate = json.loads(getattr(block, "text", ""))
                    if isinstance(candidate, dict):
                        data = candidate
                        break
                except (ValueError, TypeError):
                    continue
        if not isinstance(data, dict):
            raise DriverError("unsupported")
        if data.get("status") == "refused" or data.get("refusal"):
            refusal = data.get("refusal", {})
            detail = refusal.get("detail", {}) if isinstance(refusal, dict) else {}
            code = refusal.get("code") if isinstance(refusal, dict) else None
            code = code if isinstance(code, str) else classify_error(str(refusal or "unsupported"))
            if code == "browser_consent_required":
                raise BrowserConsentRequired(detail if isinstance(detail, dict) else {})
            raise DriverError(code, detail if isinstance(detail, dict) else {})
        if data.get("error"):
            raise DriverError(classify_error(str(data["error"])))
        return data

    async def health(self) -> dict:
        embedded_socket = os.environ.get("KIO_CUA_SOCKET")
        if embedded_socket is not None:
            report = await self._read("health_report", {"include": ["bundle_identity"]})
        else:
            report = await self._read("health_report", {})
        if report.get("schema_version") != "1":
            raise DriverError("unsupported")
        if report.get("overall") != "ok":
            raise DriverError("driver_unavailable")
        if embedded_socket is not None:
            expected_bundle = os.environ.get("KIO_CUA_HOST_BUNDLE_ID")
            identity = next(
                (
                    item
                    for item in report.get("checks", [])
                    if item.get("name") == "bundle_identity"
                ),
                {},
            )
            identity_data = identity.get("data", {})
            if (
                identity.get("status") != "pass"
                or not expected_bundle
                or identity_data.get("bundle_identifier") != expected_bundle
            ):
                raise DriverError("driver_unavailable")
            permissions = await self._read("check_permissions", {"prompt": False})
            source = permissions.get("source", {})
            if (
                source.get("attribution") != "host"
                or source.get("host_bundle_id") != expected_bundle
            ):
                raise DriverError("driver_unavailable")
            if not permissions.get("accessibility") or not permissions.get("screen_recording"):
                raise DriverError("permission_missing")
            return report

        checks = {item.get("name"): item.get("status") for item in report.get("checks", [])}
        if any(
            checks.get(name) != "pass" for name in ("tcc_accessibility", "tcc_screen_recording")
        ):
            raise DriverError("permission_missing")
        return report

    async def apps(self) -> dict:
        return await self._read("list_apps", {})

    async def windows(self, pid: int) -> dict:
        return await self._read("list_windows", {"pid": pid})

    @timed("cua_observation")
    async def observe(self, pid: int, window_id: int) -> DriverObservation:
        data = await self._read(
            "get_window_state",
            {
                "pid": pid,
                "window_id": window_id,
                "include_screenshot": False,
                "max_elements": 500,
                "max_depth": 25,
            },
        )
        return normalize_window(data, pid, window_id)

    @timed("screenshot_capture")
    async def capture(self, pid: int, window_id: int):
        from .perception import BBox, PerceptionFrame

        result = await self._session.call_tool(
            "get_window_state",
            {
                "pid": pid,
                "window_id": window_id,
                "include_screenshot": True,
                "max_elements": 500,
                "max_depth": 25,
            },
        )
        data = result.structuredContent or {}
        if (
            result.isError
            or data.get("pid") != pid
            or data.get("window_id") != window_id
            or not data.get("screenshot_frame_valid")
        ):
            raise DriverError("capture_unavailable")
        image_block = next(
            (b for b in result.content if b.type == "image" and b.mimeType == "image/png"), None
        )
        if image_block is None or len(image_block.data) > 45_000_000:
            raise DriverError("capture_unavailable")
        try:
            image = base64.b64decode(image_block.data, validate=True)
            if image[:8] != b"\x89PNG\r\n\x1a\n" or len(image) < 24:
                raise ValueError("invalid PNG")
            width, height = struct.unpack(">II", image[16:24])
            if width != data["screenshot_width"] or height != data["screenshot_height"]:
                raise ValueError("invalid frame")
            bounds = data["window_bounds"]
            observation = normalize_window(data, pid, window_id)
            frame = PerceptionFrame.create(
                image,
                observation.snapshot_id,
                pid,
                window_id,
                width,
                height,
                BBox(bounds["x"], bounds["y"], bounds["width"], bounds["height"]),
                native_capture_id=data.get("capture_id"),
            )
            return observation, frame
        except (ValueError, KeyError, TypeError):
            raise DriverError("capture_unavailable") from None

    async def parse_visual_regions(self, capture_id: str, options: dict | None = None) -> dict:
        if not self.capabilities.visual_regions_contract:
            self.capabilities = replace(self.capabilities, visual_regions=False)
            raise DriverError("unsupported")
        try:
            data = await self._read(
                "parse_visual_regions", {"capture_id": capture_id, "options": options or {}}
            )
        except DriverError as error:
            if error.code in {"unsupported", "driver_unavailable"}:
                self.capabilities = replace(self.capabilities, visual_regions=False)
                # Keep extension absence explicit without exposing vendor details.
                raise DriverError("unsupported") from None
            raise
        regions = data.get("regions")
        if not isinstance(regions, list):
            self.capabilities = replace(self.capabilities, visual_regions=False)
            raise DriverError("unsupported")
        self.capabilities = replace(self.capabilities, visual_regions=True)
        return data

    @timed("cua_action")
    async def execute(self, action, *, text: str | None = None) -> dict:
        from .candidates import Operation

        payload = dict(action.payload)
        if payload.get("structured_browser") is True:
            target_id = payload.get("target_id")
            tab_id = payload.get("tab_id")
            ref = payload.get("ref")
            session = payload.get("session", "kio-browser")
            if not all(
                isinstance(value, str) and value for value in (target_id, tab_id, ref, session)
            ):
                raise DriverError("unsupported")
            if action.operation == Operation.CLICK:
                return await self.browser_click(target_id, tab_id, ref=ref, session=session)
            if action.operation == Operation.TYPE_TEXT:
                if text is None:
                    raise DriverError("invalid_text")
                return await self.browser_type(target_id, tab_id, ref, text, session=session)
            raise DriverError("unsupported")
        if action.operation == Operation.CLICK and payload.get("visual") is True:
            capture_id = payload.get("capture_id")
            x, y = payload.get("x"), payload.get("y")
            width, height = payload.get("frame_width"), payload.get("frame_height")
            if (
                not self.capabilities.capture_bound_pixels
                or not isinstance(capture_id, str)
                or not capture_id
                or type(x) is not int
                or type(y) is not int
                or type(width) is not int
                or type(height) is not int
                or not 0 <= x < width
                or not 0 <= y < height
                or not isinstance(payload.get("frame_digest"), str)
                or not payload["frame_digest"]
                or not isinstance(payload.get("observation_id"), str)
                or not payload["observation_id"]
            ):
                raise DriverError("unsupported")
            return await self._read(
                "click",
                {
                    "pid": payload["pid"],
                    "window_id": payload["window_id"],
                    "capture_id": capture_id,
                    "x": x,
                    "y": y,
                    "button": "left",
                    "count": 1,
                    "delivery_mode": "foreground",
                },
            )
        if action.operation in {Operation.CLICK, Operation.SELECT, Operation.TYPE_TEXT}:
            if not payload.get("element_token"):
                raise DriverError("unsupported")
            args = {
                "pid": payload["pid"],
                "window_id": payload["window_id"],
                "element_token": payload["element_token"],
                "delivery_mode": "foreground"
                if payload.get("in_system_dialog") is True
                else "background",
            }
            if action.operation == Operation.TYPE_TEXT:
                if text is None:
                    raise DriverError("invalid_text")
                args["text"] = text
                if payload.get("in_web_content") is True or payload.get("in_system_dialog") is True:
                    # Current CUA documents foreground delivery for focus-sensitive web fields.
                    # CUA still validates the exact fresh token/window; no pixel fallback here.
                    args["delivery_mode"] = "foreground"
                return await self._read("type_text", args)
            if action.operation == Operation.SELECT and payload.get("role") == "AXMenuItem":
                # Safari native menu actions require the driver's foreground guard.
                # Both target and action remain locally fixed, never model-provided.
                args["action"] = "pick"
                args["delivery_mode"] = "foreground"
            return await self._read("click", args)
        if action.operation in {Operation.SCROLL_UP, Operation.SCROLL_DOWN}:
            if not payload.get("element_token"):
                raise DriverError("unsupported")
            return await self._read(
                "scroll",
                {
                    "pid": payload["pid"],
                    "window_id": payload["window_id"],
                    "element_token": payload["element_token"],
                    "direction": "up" if action.operation == Operation.SCROLL_UP else "down",
                    "by": "page",
                    "amount": 1,
                    "delivery_mode": "background",
                },
            )
        raise DriverError("unsupported")

    async def observed_url(self, expected: str, *, pid: int | None = None) -> str | None:
        from .direct import destination_matches

        # Read only an identified native address field, never infer URL from page text.
        active_apps = [
            app
            for app in (await self.apps()).get("apps", [])
            if app.get("running")
            and (app.get("pid") == pid if pid is not None else app.get("active"))
        ]
        for app in active_apps:
            for window in (await self.windows(app["pid"])).get("windows", []):
                if not window.get("is_on_screen") or not window.get("on_current_space", True):
                    continue
                observation = await self.observe(app["pid"], window["window_id"])
                for control in observation.controls:
                    if (
                        control.role == "AXTextField"
                        and not control.native.get("in_web_content")
                        and re.search(
                            r"address|smart search|search or enter|location bar|website address",
                            control.label,
                            re.IGNORECASE,
                        )
                        and control.value
                        and destination_matches(expected, control.value)
                    ):
                        return control.value
        return None

    async def launch_app(self, bundle_id: str) -> dict:
        return await self._read("launch_app", {"bundle_id": bundle_id})

    async def bring_to_front(self, pid: int, window_id: int | None = None) -> dict:
        arguments = {"pid": pid}
        if window_id is not None:
            arguments["window_id"] = window_id
        return await self._read("bring_to_front", arguments)

    async def browser_state(
        self,
        pid: int | None = None,
        window_id: int | None = None,
        *,
        target_id: str | None = None,
        tab_id: str | None = None,
        session: str = "kio-browser",
    ) -> dict:
        """Read either the exact native browser binding or a fresh tab snapshot."""
        if target_id and tab_id:
            arguments = {
                "target_id": target_id,
                "tab_id": tab_id,
                "session": session,
                "snapshot_format": "semantic_v2",
                "include_screenshot": False,
            }
        elif pid is not None and window_id is not None:
            arguments = {
                "pid": pid,
                "window_id": window_id,
                "session": session,
                "snapshot_format": "semantic_v2",
                "include_screenshot": False,
            }
        else:
            raise DriverError("target_missing")
        return await self._read("get_browser_state", arguments)

    async def start_session(self, session: str) -> dict:
        if not isinstance(session, str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", session
        ):
            raise DriverError("unsupported")
        return await self._read("start_session", {"session": session})

    async def end_session(self, session: str) -> dict:
        if not isinstance(session, str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", session
        ):
            raise DriverError("unsupported")
        return await self._read("end_session", {"session": session})

    async def browser_prepare(
        self, pid: int, window_id: int, *, session: str = "kio-browser"
    ) -> dict:
        """Start CUA's official existing-profile preparation for one exact window."""
        return await self._read(
            "browser_prepare",
            {
                "pid": pid,
                "window_id": window_id,
                "session": session,
                "strategy": {"kind": "existing_profile"},
            },
        )

    async def browser_navigate(
        self, target_id: str, tab_id: str, url: str, *, session: str = "kio-browser"
    ) -> dict:
        return await self._read(
            "browser_navigate",
            {"target_id": target_id, "tab_id": tab_id, "url": url, "session": session},
        )

    async def browser_click(
        self,
        target_id: str,
        tab_id: str,
        *,
        ref: str | None = None,
        x: int | None = None,
        y: int | None = None,
        session: str = "kio-browser",
    ) -> dict:
        arguments = {
            "target_id": target_id,
            "tab_id": tab_id,
            "input_route": "trusted",
            "session": session,
        }
        if ref:
            arguments["ref"] = ref
        elif x is not None and y is not None:
            arguments.update({"x": x, "y": y})
        else:
            raise DriverError("unsupported")
        return await self._read("browser_click", arguments)

    async def browser_type(
        self, target_id: str, tab_id: str, ref: str, text: str, *, session: str = "kio-browser"
    ) -> dict:
        return await self._read(
            "browser_type",
            {
                "target_id": target_id,
                "tab_id": tab_id,
                "ref": ref,
                "text": text,
                "session": session,
            },
        )

    async def browser_pointer(
        self,
        target_id: str,
        tab_id: str,
        *,
        ref: str | None = None,
        x: float | None = None,
        y: float | None = None,
        session: str = "kio-browser",
    ) -> dict:
        arguments = {"target_id": target_id, "tab_id": tab_id, "session": session}
        if ref:
            arguments["ref"] = ref
        elif type(x) in (int, float) and type(y) in (int, float):
            arguments.update({"x": x, "y": y})
        else:
            raise DriverError("unsupported")
        return await self._read("browser_pointer", arguments)

    async def browser_dialog(
        self, target_id: str, tab_id: str, *, session: str = "kio-browser"
    ) -> dict:
        return await self._read(
            "browser_dialog", {"target_id": target_id, "tab_id": tab_id, "session": session}
        )

    async def browser_set_input_files(
        self,
        target_id: str,
        tab_id: str,
        ref: str,
        paths: list[str],
        *,
        session: str = "kio-browser",
    ) -> dict:
        if not isinstance(ref, str) or not ref or not isinstance(paths, list) or not paths:
            raise DriverError("unsupported")
        safe_paths = []
        for value in paths:
            if not isinstance(value, str) or not value or not os.path.isabs(value):
                raise DriverError("invalid_path")
            resolved = os.path.realpath(value)
            if os.path.islink(value) or not os.path.isfile(resolved):
                raise DriverError("invalid_path")
            safe_paths.append(resolved)
        return await self._read(
            "browser_set_input_files",
            {
                "target_id": target_id,
                "tab_id": tab_id,
                "ref": ref,
                "paths": safe_paths,
                "session": session,
            },
        )

    async def browser_download(
        self, target_id: str, tab_id: str, ref: str, *, session: str = "kio-browser"
    ) -> dict:
        if not isinstance(ref, str) or not ref:
            raise DriverError("unsupported")
        return await self._read(
            "browser_download",
            {"target_id": target_id, "tab_id": tab_id, "ref": ref, "session": session},
        )


class FakeDriver:
    def __init__(self, snapshots: list[dict], error: str | None = None):
        self.snapshots = snapshots
        self.error = error
        self.observations = 0
        self.capabilities = DriverCapabilities(accessibility_tokens=True)

    async def health(self) -> dict:
        if self.error:
            raise DriverError(self.error)
        return {"overall": "ok", "schema_version": "1"}

    async def apps(self) -> dict:
        return {"apps": [{"pid": 1, "name": "Fixture"}]}

    async def windows(self, pid: int) -> dict:
        return {"windows": [{"pid": pid, "window_id": 1}]}

    async def observe(self, pid: int, window_id: int) -> DriverObservation:
        await self.health()
        row = self.snapshots[min(self.observations, len(self.snapshots) - 1)]
        self.observations += 1
        return normalize_window(row, pid, window_id)


async def smoke(pid: int | None, window_id: int | None) -> int:
    try:
        async with CuaDriver.connect() as driver:
            report = await driver.health()
            print(
                json.dumps(
                    {"health": report["overall"], "driver_version": report.get("driver_version")}
                )
            )
            if pid is not None and window_id is not None:
                observation = await driver.observe(pid, window_id)
                print(
                    json.dumps(
                        {
                            "snapshot_id": observation.snapshot_id,
                            "control_count": len(observation.controls),
                            "roles": sorted({c.role for c in observation.controls}),
                        }
                    )
                )
                if not observation.controls or observation.degraded_reason:
                    raise DriverError("unsupported")
        return 0
    except DriverError as error:
        print(json.dumps({"error": error.code}))
        return 1


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Read-only CUA smoke; never saves private content")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--window-id", type=int)
    args = parser.parse_args()
    if (args.pid is None) != (args.window_id is None):
        parser.error("--pid and --window-id must be supplied together")
    raise SystemExit(asyncio.run(smoke(args.pid, args.window_id)))


if __name__ == "__main__":
    main()
