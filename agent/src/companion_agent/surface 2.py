"""Per-observation surface identity, capabilities, target selection and routing."""

import re
from dataclasses import dataclass, field
from enum import StrEnum

from .candidates import CLICK_ROLES, SELECT_ROLES, TYPE_ROLES, Observation
from .capabilities import DriverCapabilities
from .driver import DriverError


class SurfaceKind(StrEnum):
    NATIVE_WINDOW = "NATIVE_WINDOW"
    BROWSER_PAGE = "BROWSER_PAGE"
    ELECTRON_PAGE = "ELECTRON_PAGE"
    VISUAL_WINDOW = "VISUAL_WINDOW"
    DESKTOP = "DESKTOP"
    TRANSIENT_WINDOW = "TRANSIENT_WINDOW"
    SYSTEM_DIALOG = "SYSTEM_DIALOG"
    UNKNOWN = "UNKNOWN"


class SurfaceRoute(StrEnum):
    STRUCTURED_BROWSER = "structured_browser"
    ACCESSIBILITY = "accessibility"
    VISUAL = "visual"
    DESKTOP = "desktop"
    UNSUPPORTED = "unsupported"


@dataclass(frozen=True)
class SurfaceIdentity:
    pid: int | None
    window_id: int | None
    app_name: str = ""
    bundle_id: str = ""
    title: str = ""
    observation_id: str = ""
    generation: int = 0
    frame: tuple[float, float, float, float] | None = None


@dataclass(frozen=True)
class SurfaceCapabilities:
    accessibility: bool = False
    structured_browser: bool = False
    screenshot: bool = False
    capture_bound_pixels: bool = False
    background_click: bool = False
    background_type: bool = False
    native_menu: bool = False


@dataclass(frozen=True)
class Surface:
    kind: SurfaceKind
    identity: SurfaceIdentity
    capabilities: SurfaceCapabilities
    observation: Observation | None = field(default=None, repr=False, compare=False)
    browser_actions_ready: bool = False
    visual_ready: bool = False
    desktop_fallback_allowed: bool = False


@dataclass(frozen=True)
class WindowResolution:
    window: dict | None
    reason: str
    scores: tuple[tuple[int, int], ...] = ()


class SurfaceResolver:
    """Infer surface kind from live evidence; never identify apps by a fixed list."""

    def resolve(
        self,
        observation: Observation | None,
        *,
        app: dict | None = None,
        window: dict | None = None,
        driver: DriverCapabilities | None = None,
        browser_actions_ready: bool = False,
        visual_result=None,
        desktop_fallback_allowed: bool = False,
    ) -> Surface:
        driver = driver or DriverCapabilities()
        app = app or {}
        window = window or {}
        elements = observation.elements if observation else ()
        roles = {e.role for e in elements if e.visible}
        title = str(window.get("title") or (observation.title if observation else ""))
        bounds = window.get("bounds", {})
        frame = None
        try:
            frame = tuple(float(bounds[k]) for k in ("x", "y", "width", "height"))
        except (KeyError, TypeError, ValueError):
            pass
        usable_ax = any(
            e.visible
            and e.enabled
            and e.label.strip()
            and e.role in CLICK_ROLES | SELECT_ROLES | TYPE_ROLES
            for e in elements
        ) or any(
            e.visible
            and e.role in {"AXScrollArea", "AXWebArea"}
            and isinstance(e.native.get("element_token"), str)
            and bool(e.native["element_token"])
            for e in elements
        )
        has_page = (
            any(e.native.get("in_web_content") is True for e in elements) or "AXWebArea" in roles
        )
        kind_hint = str(app.get("surface_kind") or app.get("kind") or "").casefold()
        has_dialog = bool(
            roles & {"AXSheet", "AXDialog", "AXAlert", "AXFileChooser"}
            or any(e.native.get("in_system_dialog") is True for e in elements)
        )
        is_transient = (
            bool(window.get("is_transient"))
            or bool(roles & {"AXPopover", "AXMenu", "AXMenuItem"})
            or window.get("layer", 0) > 0
        )
        if desktop_fallback_allowed and observation is None:
            kind = SurfaceKind.DESKTOP
        elif has_dialog:
            kind = SurfaceKind.SYSTEM_DIALOG
        elif is_transient:
            kind = SurfaceKind.TRANSIENT_WINDOW
        elif kind_hint in {"electron", "webview", "hybrid"} and has_page:
            kind = SurfaceKind.ELECTRON_PAGE
        elif has_page or browser_actions_ready or self._has_browser_chrome(elements):
            kind = SurfaceKind.BROWSER_PAGE
        elif visual_result is not None and getattr(visual_result, "used_visual", False):
            kind = SurfaceKind.VISUAL_WINDOW
        elif observation is not None:
            kind = SurfaceKind.NATIVE_WINDOW
        else:
            kind = SurfaceKind.UNKNOWN

        visual_frame = getattr(visual_result, "frame", None)
        visual_ready = bool(
            visual_frame and visual_frame.native_capture_id and driver.capture_bound_pixels
        )
        caps = SurfaceCapabilities(
            accessibility=usable_ax and driver.accessibility_tokens,
            structured_browser=driver.structured_browser and browser_actions_ready,
            screenshot=driver.screenshot,
            capture_bound_pixels=driver.capture_bound_pixels,
            background_click=driver.background_actions,
            background_type=driver.background_type,
            native_menu=driver.native_menu,
        )
        identity = SurfaceIdentity(
            observation.pid if observation else window.get("pid"),
            observation.window_id if observation else window.get("window_id"),
            str(app.get("name") or window.get("app_name") or ""),
            str(app.get("bundle_id") or ""),
            title,
            observation.snapshot_id if observation else "",
            0,
            frame,
        )
        return Surface(
            kind,
            identity,
            caps,
            observation,
            browser_actions_ready,
            visual_ready,
            desktop_fallback_allowed,
        )

    @staticmethod
    def _has_browser_chrome(elements):
        for element in elements:
            if element.role in TYPE_ROLES and re.search(
                r"address|search.*bar|website", element.label, re.IGNORECASE
            ):
                return True
        return False

    @staticmethod
    def resolve_window(windows, goal: str, *, last_target_window_id: int | None = None):
        """Prefer exact task, active and key windows before title evidence."""
        eligible = [
            w
            for w in windows
            if w.get("is_on_screen")
            and w.get("on_current_space", True)
            and w.get("layer", 0) == 0
            and w.get("bounds", {}).get("width", 100) >= 100
            and w.get("bounds", {}).get("height", 80) >= 80
        ]
        if not eligible:
            return WindowResolution(None, "no_visible_content_window")
        exact = [w for w in eligible if w.get("window_id") == last_target_window_id]
        if len(exact) == 1:
            return WindowResolution(exact[0], "exact_task_window")
        if len(eligible) == 1:
            return WindowResolution(eligible[0], "single_visible_content_window")
        active = [
            w
            for w in eligible
            if w.get("active") is True or w.get("is_key") is True or w.get("is_main") is True
        ]
        if len(active) == 1:
            return WindowResolution(active[0], "active_content_window")
        tokens = set(re.findall(r"[\w]+", goal.casefold())) - {
            "open",
            "click",
            "type",
            "enter",
            "in",
            "the",
            "a",
            "and",
            "then",
            "please",
            "window",
            "app",
            "application",
        }
        scored = []
        for item in eligible:
            title_tokens = set(re.findall(r"[\w]+", str(item.get("title", "")).casefold()))
            overlap = len(tokens & title_tokens)
            score = (
                (30 if item.get("active") is True else 0)
                + (25 if item.get("is_key") is True else 0)
                + (20 if item.get("is_main") is True else 0)
                + (10 if item.get("is_on_screen") is True else 0)
                + overlap * 10
            )
            scored.append((score, item))
        scored.sort(key=lambda pair: (-pair[0], pair[1].get("window_id", 0)))
        ranks = tuple((int(window.get("window_id", 0)), score) for score, window in scored)
        if scored[0][0] >= 10 and scored[0][0] - scored[1][0] >= 10:
            return WindowResolution(scored[0][1], "unique_strong_window_evidence", ranks)
        return WindowResolution(None, "ambiguous_visible_windows", ranks)


class CapabilityRouter:
    """Pick a route anew for each fresh surface observation."""

    def route(self, surface: Surface) -> SurfaceRoute:
        caps = surface.capabilities
        if surface.kind == SurfaceKind.DESKTOP:
            return (
                SurfaceRoute.DESKTOP
                if surface.desktop_fallback_allowed
                else SurfaceRoute.UNSUPPORTED
            )
        if caps.structured_browser and surface.browser_actions_ready:
            return SurfaceRoute.STRUCTURED_BROWSER
        if caps.accessibility:
            return SurfaceRoute.ACCESSIBILITY
        if caps.capture_bound_pixels and surface.visual_ready:
            return SurfaceRoute.VISUAL
        return SurfaceRoute.UNSUPPORTED

    def require_route(self, surface: Surface) -> SurfaceRoute:
        route = self.route(surface)
        if route == SurfaceRoute.UNSUPPORTED:
            raise DriverError("unsupported")
        return route
