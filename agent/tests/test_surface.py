import pytest

from companion_agent.candidates import Element, Observation
from companion_agent.capabilities import DriverCapabilities
from companion_agent.driver import DriverError
from companion_agent.surface import (
    CapabilityRouter,
    SurfaceKind,
    SurfaceResolver,
    SurfaceRoute,
)


def element(role, label, *, web=False, source="AX", interactive=True, frame=None):
    return Element(
        id=label,
        snapshot_id="obs",
        label=label,
        role=role,
        value=None,
        enabled=True,
        visible=True,
        source=source,
        native={"in_web_content": web, **({"frame": frame} if frame else {})},
        interactive=interactive,
        capture_id="cap" if source in {"OCR", "VISUAL"} else None,
    )


def obs(*items, pid=10, window=20):
    return Observation("obs", pid, window, tuple(items), "Fixture")


def test_router_prefers_structured_browser_then_rechecks_ax_visual():
    resolver, router = SurfaceResolver(), CapabilityRouter()
    browser = resolver.resolve(
        obs(element("AXButton", "Continue", web=True)),
        driver=DriverCapabilities(accessibility_tokens=True, structured_browser=True),
        browser_actions_ready=True,
    )
    assert browser.kind == SurfaceKind.BROWSER_PAGE
    assert router.route(browser) == SurfaceRoute.STRUCTURED_BROWSER

    native = resolver.resolve(
        obs(element("AXButton", "Continue")),
        driver=DriverCapabilities(accessibility_tokens=True, structured_browser=True),
    )
    assert router.route(native) == SurfaceRoute.ACCESSIBILITY

    class Frame:
        native_capture_id = "native-capture"
        observation_id = "obs"

    class VisualResult:
        used_visual = True
        frame = Frame()

    visual = resolver.resolve(
        obs(element("AXStaticText", "Continue", source="OCR", interactive=False)),
        driver=DriverCapabilities(capture_bound_pixels=True),
        visual_result=VisualResult(),
    )
    assert visual.kind == SurfaceKind.VISUAL_WINDOW
    assert router.route(visual) == SurfaceRoute.VISUAL
    assert router.route(native) == SurfaceRoute.ACCESSIBILITY


def test_missing_capture_authority_does_not_select_visual_or_desktop():
    resolver, router = SurfaceResolver(), CapabilityRouter()

    class Frame:
        native_capture_id = None
        observation_id = "obs"

    class VisualResult:
        used_visual = True
        frame = Frame()

    surface = resolver.resolve(
        obs(element("AXStaticText", "icon", source="OCR", interactive=False)),
        driver=DriverCapabilities(),
        visual_result=VisualResult(),
    )
    assert router.route(surface) == SurfaceRoute.UNSUPPORTED
    desktop = resolver.resolve(None, desktop_fallback_allowed=True)
    assert router.route(desktop) == SurfaceRoute.DESKTOP
    with pytest.raises(DriverError, match="unsupported"):
        router.require_route(resolver.resolve(None))


def test_accessibility_elements_do_not_confer_missing_driver_authority():
    surface = SurfaceResolver().resolve(
        obs(element("AXButton", "Continue")), driver=DriverCapabilities()
    )
    assert not surface.capabilities.accessibility
    assert CapabilityRouter().route(surface) == SurfaceRoute.UNSUPPORTED


def test_fresh_scroll_area_token_is_a_safe_accessibility_route():
    scroll = Element(
        id="scroll",
        snapshot_id="obs",
        label="Scrollable information",
        role="AXScrollArea",
        value=None,
        enabled=True,
        visible=True,
        source="AX",
        native={"element_token": "fresh-scroll-token"},
        interactive=False,
    )
    surface = SurfaceResolver().resolve(
        obs(scroll), driver=DriverCapabilities(accessibility_tokens=True)
    )
    assert surface.capabilities.accessibility
    assert CapabilityRouter().route(surface) == SurfaceRoute.ACCESSIBILITY


def test_scroll_area_without_native_token_does_not_grant_route():
    scroll = element("AXScrollArea", "Scrollable information", interactive=False)
    surface = SurfaceResolver().resolve(
        obs(scroll), driver=DriverCapabilities(accessibility_tokens=True)
    )
    assert not surface.capabilities.accessibility
    assert CapabilityRouter().route(surface) == SurfaceRoute.UNSUPPORTED


def test_native_dialog_and_transient_surface_are_reclassified_per_observation():
    resolver = SurfaceResolver()
    browser = resolver.resolve(
        obs(element("AXButton", "Upload", web=True)),
        driver=DriverCapabilities(accessibility_tokens=True),
    )
    dialog = resolver.resolve(
        Observation(
            "obs-dialog",
            10,
            20,
            (element("AXButton", "Open"), element("AXSheet", "Open file")),
            "Fixture",
        ),
        driver=DriverCapabilities(accessibility_tokens=True),
    )
    popover = resolver.resolve(
        obs(element("AXMenuItem", "Sort by")),
        window={"layer": 4},
        driver=DriverCapabilities(accessibility_tokens=True),
    )
    assert browser.kind == SurfaceKind.BROWSER_PAGE
    assert dialog.kind == SurfaceKind.SYSTEM_DIALOG
    assert popover.kind == SurfaceKind.TRANSIENT_WINDOW
    assert browser.identity.observation_id != dialog.identity.observation_id


def test_window_target_resolves_strong_goal_match_and_rejects_ambiguity():
    windows = [
        {
            "window_id": 1,
            "is_on_screen": True,
            "bounds": {"width": 800, "height": 600},
            "title": "Draft notes",
        },
        {
            "window_id": 2,
            "is_on_screen": True,
            "bounds": {"width": 800, "height": 600},
            "title": "Project plan",
        },
        {
            "window_id": 3,
            "is_on_screen": True,
            "bounds": {"width": 66, "height": 20},
            "title": "Window",
        },
    ]
    picked = SurfaceResolver.resolve_window(windows, "Open Project plan")
    assert picked.window["window_id"] == 2
    assert picked.reason == "unique_strong_window_evidence"
    ambiguous = SurfaceResolver.resolve_window(windows, "Open the note")
    assert ambiguous.window is None and ambiguous.reason == "ambiguous_visible_windows"
    last = SurfaceResolver.resolve_window(windows, "Continue", last_target_window_id=1)
    assert last.window["window_id"] == 1


def test_browser_chrome_is_inferred_without_app_allowlist():
    resolver = SurfaceResolver()
    surface = resolver.resolve(
        obs(
            element("AXWebArea", "Page", web=True),
            element("AXTextField", "Address and search bar"),
        ),
        app={"name": "Unlisted Browser", "bundle_id": "org.example.browser"},
        driver=DriverCapabilities(accessibility_tokens=True),
    )
    assert surface.kind == SurfaceKind.BROWSER_PAGE
    assert surface.identity.bundle_id == "org.example.browser"
