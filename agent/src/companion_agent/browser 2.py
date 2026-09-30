"""Bounded structured-browser preparation and verification.

CUA remains the authority for browser attachment and actions.  This module
only coordinates the documented prepare/retry sequence and extracts typed
metadata from CUA responses; it never invents selectors or coordinates.
"""

from dataclasses import dataclass
from typing import Any

from .direct import destination_matches
from .driver import BrowserConsentRequired, DriverError


@dataclass(frozen=True)
class BrowserRoute:
    status: str
    target_id: str | None = None
    tab_id: str | None = None
    observed_url: str | None = None
    action_attempted: bool = False


@dataclass(frozen=True)
class BrowserSession:
    """One task-scoped CUA browser identity; IDs never cross this boundary."""

    name: str = "kio-browser"
    target_id: str | None = None
    tab_id: str | None = None

    def bind(self, state: dict) -> "BrowserSession":
        binding = browser_binding(state)
        if binding is None:
            raise DriverError("unsupported")
        return BrowserSession(self.name, *binding)


def _walk(value: Any):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk(child)


def browser_binding(state: dict) -> tuple[str, str] | None:
    """Return CUA-issued target/tab IDs, never locally generated identities."""
    for row in _walk(state):
        target = row.get("target_id")
        tab = row.get("tab_id")
        if isinstance(target, str) and target and isinstance(tab, str) and tab:
            return target, tab
    return None


def browser_url(state: dict) -> str | None:
    for row in _walk(state):
        for key in ("url", "current_url"):
            value = row.get(key)
            if isinstance(value, str) and value.startswith(("http://", "https://")):
                return value
    return None


async def _state(driver, *args, session: str, **kwargs):
    try:
        return await driver.browser_state(*args, session=session, **kwargs)
    except TypeError as error:
        # Small contract-test/fallback drivers from older Kio builds may not
        # expose session yet. The real CUA adapter always does.
        if "session" not in str(error):
            raise
        return await driver.browser_state(*args, **kwargs)


async def _prepare(driver, pid: int, window_id: int, session: str):
    try:
        return await driver.browser_prepare(pid, window_id, session=session)
    except TypeError as error:
        if "session" not in str(error):
            raise
        return await driver.browser_prepare(pid, window_id)


async def _start(driver, session: str):
    """Start the documented task-scoped session when the driver advertises it.

    Older contract-test drivers do not have this method.  The real CUA adapter
    does; unsupported is deliberately treated as a compatibility result rather
    than silently switching to a different session.
    """
    starter = getattr(driver, "start_session", None)
    if not callable(starter):
        return
    try:
        await starter(session)
    except TypeError as error:
        if "session" not in str(error):
            raise
    except DriverError as error:
        if error.code != "unsupported":
            raise


async def _end(driver, session: str):
    ender = getattr(driver, "end_session", None)
    if not callable(ender):
        return
    try:
        await ender(session)
    except TypeError as error:
        if "session" not in str(error):
            raise
    except DriverError as error:
        # The daemon may have restarted as part of browser authorization.
        # Ending an already gone session is not an execution failure.
        if error.transport_failure:
            raise
        if error.code not in {"unsupported", "target_missing", "driver_unavailable"}:
            raise


async def _navigate(driver, target_id: str, tab_id: str, url: str, session: str):
    try:
        return await driver.browser_navigate(target_id, tab_id, url, session=session)
    except TypeError as error:
        if "session" not in str(error):
            raise
        return await driver.browser_navigate(target_id, tab_id, url)


async def structured_navigate(
    driver, pid: int, window_id: int, url: str, *, allow_prepare: bool = True
) -> BrowserRoute:
    """Prepare/retry one browser binding, then navigate and reobserve it.

    A consent refusal is surfaced separately so the host can show its one-time
    access action.  Other preparation failures deliberately return ``fallback``
    so the caller can use its existing AX route.
    """
    session = BrowserSession()
    try:
        await _start(driver, session.name)
    except BrowserConsentRequired:
        return BrowserRoute("consent_required" if allow_prepare else "fallback")
    except DriverError as error:
        if error.code in {"browser_requires_setup", "browser_consent_required"}:
            return BrowserRoute("consent_required" if allow_prepare else "fallback")
        if error.transport_failure:
            raise
        return BrowserRoute("fallback")
    try:
        state = await _state(driver, pid, window_id, session=session.name)
    except (BrowserConsentRequired, DriverError) as initial_error:
        if isinstance(initial_error, DriverError) and initial_error.transport_failure:
            raise
        if not isinstance(initial_error, BrowserConsentRequired) and initial_error.code not in {
            "browser_requires_setup",
            "browser_consent_required",
        }:
            return BrowserRoute("fallback")
        if not allow_prepare:
            return BrowserRoute("fallback")
        try:
            await _prepare(driver, pid, window_id, session.name)
        except BrowserConsentRequired:
            return BrowserRoute("consent_required")
        except DriverError as error:
            if error.transport_failure:
                raise
            return BrowserRoute("fallback")
        try:
            state = await _state(driver, pid, window_id, session=session.name)
        except BrowserConsentRequired:
            return BrowserRoute("consent_required")
        except DriverError as error:
            if error.transport_failure:
                raise
            return BrowserRoute("fallback")

    try:
        session = session.bind(state)
    except DriverError as error:
        if error.transport_failure:
            raise
        return BrowserRoute("fallback")
    try:
        await _navigate(driver, session.target_id, session.tab_id, url, session.name)
    except BrowserConsentRequired:
        return BrowserRoute(
            "consent_required", session.target_id, session.tab_id, action_attempted=False
        )
    except DriverError as error:
        if error.transport_failure:
            raise
        # No CUA action was accepted; AX may safely attempt the same goal.
        return BrowserRoute("fallback", session.target_id, session.tab_id)
    try:
        fresh = await _state(
            driver,
            target_id=session.target_id,
            tab_id=session.tab_id,
            session=session.name,
        )
    except DriverError as error:
        if error.transport_failure:
            raise
        await _end(driver, session.name)
        return BrowserRoute("needs_user", session.target_id, session.tab_id, action_attempted=True)
    observed = browser_url(fresh)
    if observed and destination_matches(url, observed):
        await _end(driver, session.name)
        return BrowserRoute(
            "structured", session.target_id, session.tab_id, observed, action_attempted=True
        )
    await _end(driver, session.name)
    return BrowserRoute(
        "needs_user", session.target_id, session.tab_id, observed, action_attempted=True
    )
