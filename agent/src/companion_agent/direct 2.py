"""Deterministic literal parsing and native opening. Models never enter this module."""

import asyncio
import ipaddress
import re
from dataclasses import dataclass
from difflib import SequenceMatcher
from urllib.parse import quote_plus, urlsplit, urlunsplit

from .driver import CuaDriver, DriverError
from .goal_compiler import normalize_spoken_goal
from .metrics import timed


@dataclass(frozen=True)
class DirectCommand:
    kind: str
    value: str = ""
    application_name: str | None = None


def normalize_url(value: str) -> str | None:
    if not value or len(value) > 4096 or any(c.isspace() or ord(c) < 32 for c in value):
        return None
    if "\\" in value:
        return None
    if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", value):
        value = "https://" + value
    try:
        parsed = urlsplit(value)
        host = parsed.hostname
        if parsed.scheme not in {"https", "http"} or not host or parsed.username or parsed.password:
            return None
        port = parsed.port
        try:
            ipaddress.ip_address(host)
        except ValueError:
            host = host.encode("idna").decode("ascii").lower()
            if host != "localhost" and (
                "." not in host
                or not all(
                    re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                    for label in host.split(".")
                )
            ):
                return None
        netloc = f"[{host}]" if ":" in host else host
        if port:
            netloc += f":{port}"
        return urlunsplit(
            (parsed.scheme, netloc, parsed.path or "/", parsed.query, parsed.fragment)
        )
    except (ValueError, UnicodeError):
        return None


def site_homepage(name: str) -> str | None:
    """Resolve an explicitly named search site to a conservative hostname."""
    value = str(name or "").strip().strip(" .")
    if not value:
        return None
    if re.fullmatch(r"[\w.-]+\.[A-Za-z]{2,63}(?:/[^\s]*)?", value):
        return normalize_url(value)
    # A single spoken site name is commonly its registrable label (for example,
    # "YouTube"). Do not guess a domain for arbitrary multi-word names.
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9-]{1,62}", value):
        return normalize_url(value.casefold() + ".com")
    return None


def destination_matches(expected: str, observed: str) -> bool:
    wanted = normalize_url(expected)
    observed_value = observed
    if wanted and "://" not in observed_value:
        observed_value = f"{urlsplit(wanted).scheme}://{observed_value}"
    actual = normalize_url(observed_value)
    if wanted is None or actual is None:
        return False
    if wanted == actual:
        return True
    # Chrome's address field omits Google's www prefix; retain exact scheme/path/query.
    a, b = urlsplit(wanted), urlsplit(actual)
    google = {"google.com", "www.google.com"}
    return (
        a.hostname in google
        and b.hostname in google
        and a.path == b.path == "/search"
        and a.scheme == b.scheme
        and a.port == b.port
        and a.query == b.query
        and a.fragment == b.fragment
    )


@timed("direct_routing")
def parse_direct(goal: str) -> DirectCommand | None:
    goal = normalize_spoken_goal(goal)
    if goal.casefold() in {"stop", "cancel"}:
        return DirectCommand("cancel")
    search = re.fullmatch(
        r"search\s+google\s+for\s+(.+?)\s+(?:in|using)\s+([\w .-]+)",
        goal,
        flags=re.IGNORECASE,
    )
    if search:
        return DirectCommand(
            "url",
            "https://www.google.com/search?q=" + quote_plus(search[1].rstrip(".,!?")),
            search[2].strip(),
        )
    search = re.fullmatch(
        r"open\s+([\w .-]+?)\s+and\s+search\s+for\s+(.+)",
        goal,
        flags=re.IGNORECASE,
    )
    if search:
        return DirectCommand(
            "url",
            "https://www.google.com/search?q=" + quote_plus(search[2].rstrip(".,!?")),
            search[1].strip(),
        )
    search = re.fullmatch(r"search\s+google\s+for\s+(.+)", goal, flags=re.IGNORECASE)
    if search:
        return DirectCommand(
            "url", "https://www.google.com/search?q=" + quote_plus(search[1].rstrip(".,!?"))
        )
    search = re.fullmatch(r"google\s+(?:search\s+)?(.+\s+.+)", goal, flags=re.IGNORECASE)
    if search:
        return DirectCommand(
            "url", "https://www.google.com/search?q=" + quote_plus(search[1].rstrip(".,!?"))
        )
    search = re.fullmatch(
        r"(?:google\s+search|search(?:\s+for)?|look\s+up)\s+(.+)",
        goal,
        flags=re.IGNORECASE,
    )
    if search:
        return DirectCommand(
            "url", "https://www.google.com/search?q=" + quote_plus(search[1].rstrip(".,!?"))
        )
    selected = re.fullmatch(
        r"(?:open|go\s+to)\s+(.+?)\s+(?:in|using)\s+([\w .-]+)",
        goal,
        flags=re.IGNORECASE,
    )
    if selected:
        url = normalize_url(selected[1].strip())
        if url:
            return DirectCommand("url", url, selected[2].strip())
    match = re.fullmatch(r"(open|go to)\s+(.+)", goal, flags=re.IGNORECASE)
    if match:
        value = match[2].strip()
        url = normalize_url(value)
        if url:
            return DirectCommand("url", url)
        app_name = value.rstrip(".,!?")
        if re.search(
            r"\s+(?:and\s+then|then|and)\s+(?=(?:open|launch|start|bring|show|go\s+to|"
            r"play|pause|search|look\s+up|create|draft|write|type|enter|select|click|press)\b)",
            app_name,
            re.IGNORECASE,
        ):
            return None
        if match[1].casefold() == "open" and re.fullmatch(r"[\w -]{1,100}", app_name) and app_name:
            return DirectCommand("app", app_name)
    return None


def resolve_app(name: str, apps: list[dict]) -> dict | None:
    query = re.sub(r"[^\w]+", " ", str(name).casefold()).strip()
    query_key = query.replace(" ", "")
    if not query_key:
        return None

    def score(app):
        label = str(app.get("name", "")).strip()
        label_tokens = re.findall(r"\w+", label.casefold())
        label_key = "".join(label_tokens)
        if not label_tokens or not app.get("bundle_id"):
            return -1
        if not (app.get("running") or str(app.get("launch_path", "")).endswith(".app")):
            return -1
        if label_key == query_key:
            return 100
        if label_tokens[-1] == query_key:
            return 92
        query_tokens = query.split()
        if set(query_tokens) == set(label_tokens):
            return 90
        if len(query_tokens) > 1:
            prefix_initials = "".join(token[0] for token in label_tokens[: len(query_tokens)])
            if any(token == prefix_initials for token in ("".join(query_tokens), query_tokens[0])):
                remaining = query_tokens[1:]
                if all(token in label_tokens for token in remaining):
                    return 88
        if query_tokens and all(token in label_tokens for token in query_tokens):
            return 84
        # Short task words such as "new" must never fuzzy-match an unrelated
        # installed app (for example, "new" -> "News"). Exact names and exact
        # final tokens above still support short app names such as TV.
        if any(len(token) < 4 for token in query_tokens):
            return -1
        ratios = [
            max(SequenceMatcher(None, token, candidate).ratio() for candidate in label_tokens)
            for token in query_tokens
        ]
        return 70 + min(ratios) * 10 if ratios and min(ratios) >= 0.78 else -1

    scored = [(score(app), app) for app in apps]
    scored = [(value, app) for value, app in scored if value >= 0]
    if not scored:
        return None
    best_score = max(value for value, _ in scored)
    matches = [app for value, app in scored if value == best_score]
    if len(matches) > 1:
        # A running active instance is safe only when the app identity itself is
        # unambiguous; otherwise the caller must ask rather than guess.
        active = [app for app in matches if app.get("running") and app.get("active") is True]
        if len(active) == 1:
            return active[0]
        return None
    selected_app = matches[0]
    bundle_id = str(selected_app["bundle_id"])
    instances = [app for _, app in scored if str(app.get("bundle_id")) == bundle_id]

    active = [app for app in instances if app.get("running") and app.get("active") is True]
    running = [app for app in instances if app.get("running")]
    if len(active) == 1:
        return active[0]
    if len(running) == 1:
        return running[0]
    return selected_app if len(instances) == 1 else None


async def open_url(url: str, *, application: dict | None = None) -> None:
    normalized = normalize_url(url)
    if normalized is None:
        raise DriverError("invalid_url")
    # Fixed OS entry point and argv; no shell interpolation or model-generated code.
    command = ["/usr/bin/open"]
    if application:
        if not application.get("bundle_id"):
            raise DriverError("target_missing")
        command.extend(("-b", application["bundle_id"]))
    command.append(normalized)
    process = await asyncio.create_subprocess_exec(
        *command,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        code = await asyncio.wait_for(process.wait(), 10)
    except TimeoutError:
        process.kill()
        await process.wait()
        raise DriverError("action_failed") from None
    if code:
        raise DriverError("target_missing")


async def activate_app_via_launch_services(bundle_id: str) -> None:
    """Ask macOS Launch Services to activate an existing app by its exact bundle ID."""
    if not isinstance(bundle_id, str) or not bundle_id or len(bundle_id) > 256:
        raise DriverError("target_missing")
    process = await asyncio.create_subprocess_exec(
        "/usr/bin/open",
        "-b",
        bundle_id,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        code = await asyncio.wait_for(process.wait(), 2)
    except TimeoutError:
        process.kill()
        await process.wait()
        raise DriverError("foreground_unverified") from None
    if code:
        raise DriverError("target_missing")


def _usable_windows(windows: list[dict]) -> list[dict]:
    """Return plausible content windows, including windows awaiting Space activation."""
    eligible = [
        window
        for window in windows
        if window.get("layer", 0) == 0
        and window.get("bounds", {}).get("width", 100) >= 100
        and window.get("bounds", {}).get("height", 80) >= 80
    ]
    return sorted(
        eligible,
        key=lambda w: (
            w.get("active") is True or w.get("is_key") is True or w.get("is_main") is True,
            w.get("on_current_space", True) is True,
            w.get("is_on_screen") is True,
            int(w.get("z_index", 0)),
        ),
        reverse=True,
    )


def _preferred_window(app: dict, windows: list[dict]) -> dict | None:
    eligible = _usable_windows(windows)
    if not eligible:
        return None
    exact = [window for window in eligible if window.get("window_id") == app.get("window_id")]
    if len(exact) == 1:
        return exact[0]
    active = [
        window
        for window in eligible
        if window.get("active") is True
        or window.get("is_key") is True
        or window.get("is_main") is True
    ]
    if len(active) == 1:
        return active[0]
    current_visible = [
        window
        for window in eligible
        if window.get("on_current_space", True) is True and window.get("is_on_screen") is True
    ]
    if len(current_visible) == 1:
        return current_visible[0]
    if len(eligible) == 1:
        return eligible[0]
    ranked = sorted(
        eligible,
        key=lambda window: int(window.get("z_index", 0)),
        reverse=True,
    )
    if ranked[0].get("z_index") is not None and int(ranked[0].get("z_index", 0)) > int(
        ranked[1].get("z_index", 0)
    ):
        return ranked[0]
    return None


async def ensure_app_ready(app: dict, driver, cancelled, *, timeout=5.0) -> dict:
    """Reuse, activate, then rediscover one usable instance and window."""
    bundle_id = app.get("bundle_id")
    pid = app.get("pid")
    if not bundle_id:
        raise DriverError("target_missing")
    loop = asyncio.get_running_loop()
    deadline = loop.time() + max(0.0, timeout)
    launched = False
    activation_attempted = False
    launch_services_attempted = False
    activation_result = None
    activation_window_id = None
    last_reason = "window_not_ready"

    async def activate(target_window_id):
        nonlocal activation_attempted, activation_result, activation_window_id
        nonlocal launch_services_attempted
        if activation_attempted:
            return
        activation_attempted = True
        activation_window_id = target_window_id
        bring = getattr(driver, "bring_to_front", None)
        try:
            activation_result = (
                await bring(pid, target_window_id) if callable(bring) else {"status": "refused"}
            )
        except DriverError as error:
            if error.transport_failure:
                raise
            # A bounded foreground request can fail after macOS has begun
            # presenting the app. Treat ordinary tool refusal/timeout as an
            # activation miss, ask Launch Services once, then keep polling.
            activation_result = {"status": "refused", "error": error.code}
        if activation_result.get("status") == "refused" and not launch_services_attempted:
            launch_services_attempted = True
            try:
                await activate_app_via_launch_services(bundle_id)
            except DriverError as error:
                if error.transport_failure:
                    raise

    while asyncio.get_running_loop().time() < deadline:
        if cancelled.is_set():
            return {"status": "cancelled"}
        instances = [
            item
            for item in (await driver.apps()).get("apps", [])
            if item.get("bundle_id") == bundle_id
            and item.get("running") is True
            and isinstance(item.get("pid"), int)
            and item.get("pid") > 0
        ]
        exact = [item for item in instances if item.get("pid") == pid] if pid else []
        active = [item for item in instances if item.get("active") is True]
        live = (
            exact[0]
            if len(exact) == 1
            else active[0]
            if len(active) == 1
            else instances[0]
            if len(instances) == 1
            else None
        )
        if len(instances) > 1 and live is None:
            raise DriverError("process_ambiguous")
        if live:
            pid = live["pid"]
            if not callable(getattr(driver, "windows", None)):
                return {
                    "status": "completed",
                    "pid": pid,
                    "window_id": None,
                    "reused": not launched,
                }
            windows = (await driver.windows(pid)).get("windows", [])
            usable = _usable_windows(windows)
            selected = _preferred_window(app, windows)
            if selected is None or selected not in usable:
                last_reason = "ambiguous_windows" if usable else "no_usable_window"
                if not activation_attempted:
                    await activate(None)
            else:
                window_id = selected.get("window_id")
                on_current_space = selected.get("on_current_space", True) is True
                on_screen = selected.get("is_on_screen") is True
                key_or_main = any(
                    selected.get(flag) is True for flag in ("active", "is_key", "is_main")
                )
                if on_current_space and on_screen and key_or_main:
                    return {
                        "status": "completed",
                        "pid": pid,
                        "window_id": window_id,
                        "reused": not launched,
                    }
                last_reason = "window_not_ready"
                if not activation_attempted:
                    await activate(window_id)
                elif (
                    (activation_window_id is None or activation_window_id == window_id)
                    and on_current_space
                    and on_screen
                    and activation_result
                    and (activation_result.get("status") != "refused" or launch_services_attempted)
                ):
                    return {
                        "status": "completed",
                        "pid": pid,
                        "window_id": window_id,
                        "reused": not launched,
                    }
                elif (not on_current_space or not on_screen) and not launch_services_attempted:
                    # The driver accepted the exact-window request but macOS has
                    # not moved the Space yet. Try Launch Services once, then
                    # keep observing until the bounded deadline.
                    launch_services_attempted = True
                    await activate_app_via_launch_services(bundle_id)
        if live is None and not launched:
            launched = True
            launch = await driver.launch_app(bundle_id)
            if not callable(getattr(driver, "windows", None)):
                process_running = launch.get("launch_state", {}).get("process_running") is True
                return {
                    "status": "completed" if process_running else "needs_user",
                    "pid": launch.get("pid") or pid,
                    "window_id": None,
                    "reused": False,
                }
        remaining = deadline - loop.time()
        if remaining > 0:
            try:
                await asyncio.wait_for(cancelled.wait(), timeout=min(0.15, remaining))
            except TimeoutError:
                pass
    return {"status": "needs_user", "reason": last_reason}


@timed("direct_execution")
async def execute_direct(
    command: DirectCommand,
    driver: CuaDriver,
    cancelled: asyncio.Event,
    *,
    allow_browser_prepare: bool = True,
) -> dict:
    if cancelled.is_set() or command.kind == "cancel":
        return {"status": "cancelled", "path": "direct", "gemini_calls": 0}
    if command.kind == "url":
        from .candidates import Observation
        from .verification import Expectation, GoalVerifier, VerificationState, VerificationStatus

        app = None
        target_pid = None
        if command.application_name:
            app = resolve_app(command.application_name, (await driver.apps()).get("apps", []))
            if app is None:
                return {"status": "needs_user", "path": "direct", "gemini_calls": 0}
        if app:
            ready = await ensure_app_ready(app, driver, cancelled)
            if ready.get("status") != "completed":
                return {
                    "status": ready.get("status", "needs_user"),
                    "path": "direct",
                    "gemini_calls": 0,
                }
            # An explicitly selected browser gets first chance at CUA's
            # structured route.  The helper coordinates only the official
            # browser_prepare flow; it never manufactures a selector or click.
            browser_route = None
            if (
                isinstance(ready.get("pid"), int)
                and isinstance(ready.get("window_id"), int)
                and callable(getattr(driver, "browser_state", None))
                and callable(getattr(driver, "browser_prepare", None))
                and callable(getattr(driver, "browser_navigate", None))
            ):
                from .browser import structured_navigate

                browser_route = await structured_navigate(
                    driver,
                    ready["pid"],
                    ready["window_id"],
                    command.value,
                    allow_prepare=allow_browser_prepare,
                )
                if browser_route.status == "consent_required":
                    return {
                        "status": "browser_authorization_required",
                        "path": "direct",
                        "gemini_calls": 0,
                        "pid": ready["pid"],
                        "window_id": ready["window_id"],
                    }
                if browser_route.status == "structured":
                    return {
                        "status": "completed",
                        "path": "direct_structured_browser",
                        "gemini_calls": 0,
                        "url": command.value,
                        "evidence": (f"structured_url={browser_route.observed_url}",),
                        "pid": ready["pid"],
                        "window_id": ready["window_id"],
                    }
                if browser_route.status == "needs_user":
                    return {
                        "status": "needs_user",
                        "path": "direct_structured_browser",
                        "gemini_calls": 0,
                        "pid": ready["pid"],
                        "window_id": ready["window_id"],
                    }
            await open_url(command.value, application=app)
        else:
            await open_url(command.value)
        if app:
            target = next(
                (
                    candidate
                    for candidate in (await driver.apps()).get("apps", [])
                    if candidate.get("bundle_id") == app.get("bundle_id")
                    and candidate.get("running")
                ),
                None,
            )
            target_pid = target.get("pid") if target else None
            if target_pid is None:
                return {"status": "needs_user", "path": "direct", "gemini_calls": 0}
        observed = await driver.observed_url(command.value, pid=target_pid)
        state = VerificationState(Observation("direct", 0, 0, ()), url=observed)
        proof = await GoalVerifier([Expectation("url", expected=command.value)]).verify(
            "", state, state, []
        )
        return {
            "status": "cancelled"
            if cancelled.is_set()
            else "completed"
            if proof.status == VerificationStatus.VERIFIED
            else "needs_user",
            "path": "direct",
            "gemini_calls": 0,
            "url": command.value,
            "evidence": proof.evidence,
        }
    if command.kind == "app":
        app = resolve_app(command.value, (await driver.apps()).get("apps", []))
        if app is None:
            return {"status": "needs_user", "path": "direct", "gemini_calls": 0}
        if cancelled.is_set():
            return {"status": "cancelled", "path": "direct", "gemini_calls": 0}
        result = await ensure_app_ready(app, driver, cancelled)
        if result.get("status") != "completed":
            return {
                "status": result.get("status", "needs_user"),
                "path": "direct",
                "gemini_calls": 0,
            }
        from .candidates import Observation
        from .verification import Expectation, GoalVerifier, VerificationState, VerificationStatus

        running = tuple(
            a["name"] for a in (await driver.apps()).get("apps", []) if a.get("running")
        )
        state = VerificationState(
            Observation("direct", result["pid"], result.get("window_id") or 0, ()),
            app_names=running,
        )
        proof = await GoalVerifier([Expectation("app", expected=app["name"])]).verify(
            "", state, state, []
        )
        return {
            "status": "cancelled"
            if cancelled.is_set()
            else "completed"
            if proof.status == VerificationStatus.VERIFIED
            else "needs_user",
            "path": "direct",
            "gemini_calls": 0,
            "pid": result["pid"],
            "window_id": result.get("window_id"),
            "evidence": proof.evidence,
        }
    raise DriverError("unsupported")
