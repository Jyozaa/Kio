import asyncio
from dataclasses import replace

import pytest

from companion_agent.candidates import Element, Observation
from companion_agent.driver import (
    AccessibleControl,
    BrowserConsentRequired,
    DriverError,
    DriverObservation,
)
from companion_agent.perception import (
    BBox,
    CompositePerceptionProvider,
    CuaVisualPerceptionProvider,
    PerceptionContext,
    PerceptionFrame,
    PerceptionResult,
    StructuredBrowserPerceptionProvider,
    StructuredPerceptionProvider,
    VisualPerceptionProvider,
    VisualRegion,
    merge_elements,
    needs_visual_perception,
)


def element(source="AX", label="Continue", x=10, role="AXButton", identity=None):
    return Element(
        "e",
        "obs",
        label,
        role,
        None,
        True,
        True,
        source,
        native={
            "frame": {"x": x, "y": 10, "w": 100, "h": 30},
            **({"element_token": identity} if identity else {}),
        },
    )


def observation(*elements):
    return Observation("obs", 1, 2, elements)


@pytest.mark.parametrize("source", ["AX", "DOM"])
def test_structured_source(source):
    class Driver:
        supports_normalized_dom = source == "DOM"

        async def observe(self, pid, window):
            return DriverObservation(
                "obs",
                pid,
                window,
                (AccessibleControl("e", "AXButton", "Continue", None, source, {"visible": True}),),
            )

        observe_dom = observe

    result = asyncio.run(
        StructuredPerceptionProvider(Driver()).perceive(PerceptionContext("click Continue", 1, 2))
    )
    assert result.observation.elements[0].source == source


@pytest.mark.parametrize("sources", [("DOM", "AX"), ("AX", "OCR"), ("VISUAL", "OCR")])
def test_precedence_and_provenance(sources):
    items = [
        element(source=s, role="AXStaticText" if s == "OCR" else "AXButton")
        for s in reversed(sources)
    ]
    merged = merge_elements(items)
    assert len(merged) == 1 and merged[0].source == sources[0]
    assert set(merged[0].sources) == set(sources)


def test_repeated_label_at_different_positions_remains_distinct():
    assert len(merge_elements([element(x=0), element(source="OCR", x=300)])) == 2


def test_native_identity_merges_and_stale_identity_rejected():
    assert (
        len(
            merge_elements(
                [
                    element("DOM", identity="native"),
                    element("AX", label="different", identity="native"),
                ]
            )
        )
        == 1
    )


def test_ocr_provenance_and_capture_bind_survive_ax_text_merge():
    ax = element("AX", role="AXStaticText")
    ocr = replace(
        element("OCR", role="AXStaticText"),
        capture_id="capture-digest",
        confidence=0.92,
    )
    merged = merge_elements([ax, ocr])
    assert len(merged) == 1
    assert merged[0].source == "AX" and "OCR" in merged[0].sources
    assert merged[0].capture_id == "capture-digest"
    with pytest.raises(DriverError, match="stale_state"):
        merge_elements([element(), replace(element(), snapshot_id="other")])


def test_visual_provenance_and_capture_bind_survive_ax_merge():
    ax = element("AX", role="AXStaticText")
    visual = replace(
        element("VISUAL", role="AXStaticText"),
        capture_id="visual-capture",
        confidence=0.9,
    )
    merged = merge_elements([ax, visual])
    assert len(merged) == 1
    assert merged[0].source == "AX" and "VISUAL" in merged[0].sources
    assert merged[0].capture_id == "visual-capture"


@pytest.mark.parametrize("box", [(0, 0, 0, 1), (0, 0, 1, -1), (float("nan"), 0, 1, 1)])
def test_invalid_bbox(box):
    with pytest.raises(ValueError):
        BBox(*box)


def test_capture_identity_binds_bytes_geometry_generation_and_target():
    args = (b"image", "obs", 1, 2, 100, 100, BBox(0, 0, 100, 100))
    first = PerceptionFrame.create(*args)
    assert first == PerceptionFrame.create(*args)
    for index, value in [
        (0, b"other"),
        (1, "new"),
        (2, 3),
        (3, 4),
        (4, 200),
        (6, BBox(1, 0, 100, 100)),
    ]:
        changed = list(args)
        changed[index] = value
        assert first.capture_id != PerceptionFrame.create(*changed).capture_id
    assert first.native_capture_id is None and b"image" not in repr(first).encode()


def test_fallback_sufficient_and_missing_goal():
    assert not needs_visual_perception(observation(element()), "Click Continue")
    assert needs_visual_perception(observation(element()), "Click Settings")
    assert needs_visual_perception(observation(element(role="AXGroup")), "Click Continue")
    assert not needs_visual_perception(
        observation(element(label="Message", role="AXTextField")), 'Enter "hello" into Message'
    )


def test_media_visual_fallback_requires_primary_transport_context():
    from companion_agent.semantic_planner import SemanticTaskPlanner

    step = SemanticTaskPlanner().plan("Play the song").steps[0]
    unrelated = [element(label=f"Navigation Item {index}") for index in range(45)]
    assert needs_visual_perception(observation(*unrelated), "Advance playback", semantic_step=step)
    assert needs_visual_perception(
        observation(*unrelated, element(label="Play", role="AXButton")),
        "Advance playback",
        semantic_step=step,
    )
    transport = replace(
        element(label="Play", role="AXButton"),
        native={"region_label": "Now Playing transport controls"},
    )
    assert not needs_visual_perception(
        observation(*unrelated, transport), "Advance playback", semantic_step=step
    )


class Provider:
    def __init__(self, result=None, error=False, delay=0):
        self.result = result
        self.error = error
        self.delay = delay
        self.calls = 0

    async def perceive(self, context):
        self.calls += 1
        await asyncio.sleep(self.delay)
        if self.error:
            raise ValueError("private error")
        return self.result


def test_visual_only_and_fallback_suppressed():
    async def scenario():
        structured = Provider(PerceptionResult(observation(element())))
        visual = Provider(
            PerceptionResult(
                observation(element("OCR", label="Settings", role="AXStaticText")), used_visual=True
            )
        )
        provider = CompositePerceptionProvider(structured, visual)
        result = await provider.perceive(PerceptionContext("Click Continue", 1, 2))
        assert visual.calls == 0 and not result.used_visual
        result = await provider.perceive(PerceptionContext("Click Settings", 1, 2))
        assert visual.calls == 1 and result.used_visual and len(result.observation.elements) == 2
        stub = await VisualPerceptionProvider().perceive(
            PerceptionContext("goal", 1, 2, observation())
        )
        assert stub.warnings == ("visual_perception_unavailable",)

    asyncio.run(scenario())


def test_fresh_scrollable_ax_token_suppresses_unnecessary_ocr():
    scroll_area = element(
        label="Scrollable information", role="AXWebArea", identity="fresh-scroll-token"
    )
    assert not needs_visual_perception(observation(scroll_area), "Scroll down to Success")


def test_browser_chrome_controls_survive_web_content_normalization():
    from companion_agent.candidates import normalize

    raw = DriverObservation(
        "browser-obs",
        1,
        2,
        (
            AccessibleControl(
                "window", "AXWindow", "Browser", None, "AX", {"frame": {"w": 900, "h": 700}}
            ),
            AccessibleControl("web", "AXWebArea", "Page", None, "AX", {"in_web_content": True}),
            AccessibleControl(
                "address", "AXTextField", "Address and search", None, "AX", {"visible": True}
            ),
            AccessibleControl("new-tab", "AXButton", "New tab", None, "AX", {"visible": True}),
            AccessibleControl(
                "toolbar", "AXButton", "Unrelated toolbar item", None, "AX", {"visible": True}
            ),
        ),
    )
    labels = {item.label for item in normalize(raw).elements}
    assert {"Address and search", "New tab", "Page"} <= labels
    assert "Unrelated toolbar item" not in labels


def test_browser_url_metadata_survives_when_page_has_no_structured_controls():
    class Driver:
        async def observe(self, pid, window):
            return DriverObservation("obs", pid, window, ())

        async def browser_state(self, pid, window, *, session):
            return {
                "target_id": "target-1",
                "tab_id": "tab-1",
                "url": "https://www.youtube.com/results?search_query=Minecraft",
                "elements": [],
            }

    async def scenario():
        provider = StructuredBrowserPerceptionProvider(Driver())
        result = await provider.perceive(PerceptionContext("Search YouTube", 1, 2))
        assert "|kio_tab_id=tab-1" in result.observation.title
        assert "https%3A" not in result.observation.title
        from companion_agent.verification import _observation_url

        assert _observation_url(result.observation) == (
            "https://www.youtube.com/results?search_query=Minecraft"
        )
        await provider.close()

    asyncio.run(scenario())


def test_semantic_search_escalates_when_only_address_field_is_available():
    from companion_agent.semantic_planner import SemanticTaskPlanner

    step = SemanticTaskPlanner().plan("Search the current site for Minecraft").steps[0]
    address = element(label="Address and search", role="AXTextField")
    assert needs_visual_perception(observation(address), "Search for Minecraft", semantic_step=step)


def test_one_shot_activation_escalates_when_control_is_not_in_ax():
    from companion_agent.semantic_planner import SemanticTaskPlanner

    step = SemanticTaskPlanner().plan("Press the mute button").steps[0]
    assert needs_visual_perception(observation(), "Press the mute button", semantic_step=step)


def test_media_action_escalates_for_uncontextualized_play_row():
    from companion_agent.semantic_planner import SemanticTaskPlanner

    step = SemanticTaskPlanner().plan("Play the song").steps[0]
    row_button = element(label="Play", role="AXButton")
    assert needs_visual_perception(observation(row_button), "Play the song", semantic_step=step)


def test_scroll_without_fresh_token_does_not_suppress_perception_fallback():
    scroll_area = element(label="Scrollable information", role="AXWebArea")
    assert needs_visual_perception(observation(scroll_area), "Scroll down to Success")


@pytest.mark.parametrize("mode", ["error", "timeout", "stale"])
def test_optional_provider_failure_is_safe(mode):
    async def scenario():
        structured = Provider(PerceptionResult(observation()))
        visual = Provider(
            PerceptionResult(replace(observation(), snapshot_id="other")),
            error=mode == "error",
            delay=0.1 if mode == "timeout" else 0,
        )
        result = await CompositePerceptionProvider(structured, visual, timeout=0.01).perceive(
            PerceptionContext("goal", 1, 2)
        )
        assert result.warnings == ("visual_perception_failed",) and not result.observation.elements

    asyncio.run(scenario())


def test_structured_timeout_fails_closed():
    async def scenario():
        with pytest.raises(DriverError, match="perception_timeout"):
            await CompositePerceptionProvider(Provider(delay=1), timeout=0.01).perceive(
                PerceptionContext("goal", 1, 2)
            )

    asyncio.run(scenario())


def test_visual_transport_loss_propagates_as_runtime_failure():
    class TransportLoss(Provider):
        async def perceive(self, context):
            raise DriverError("runtime_transport_lost", transport_failure=True)

    async def scenario():
        structured = Provider(PerceptionResult(observation(element(role="AXGroup"))))
        visual = TransportLoss()
        with pytest.raises(DriverError) as error:
            await CompositePerceptionProvider(structured, visual).perceive(
                PerceptionContext("Click Settings", 1, 2, semantic_step=None)
            )
        assert error.value.transport_failure

    asyncio.run(scenario())


def test_read_only_browser_probe_never_starts_authorization_flow():
    class Driver:
        prepare_calls = 0

        async def observe(self, pid, window):
            return DriverObservation("obs", pid, window, ())

        async def start_session(self, session):
            return None

        async def browser_state(self, pid, window, *, session):
            raise BrowserConsentRequired({"next_action": "browser_prepare"})

        async def browser_prepare(self, pid, window, *, session):
            self.prepare_calls += 1

    async def scenario():
        driver = Driver()
        provider = StructuredBrowserPerceptionProvider(driver, prepare_on_consent=False)
        result = await provider.perceive(PerceptionContext("Where is the search bar?", 1, 2))
        assert "browser_consent_required" in result.warnings
        assert driver.prepare_calls == 0
        await provider.close()

    asyncio.run(scenario())


def test_region_validation():
    with pytest.raises(ValueError):
        VisualRegion("r", "text", "", BBox(0, 0, 1, 1), 0.8, "obs", "capture")


def test_verified_structured_marker_skips_ocr_but_false_done_does_not():
    done = observation(element(label="Success", role="AXStaticText"))
    assert not needs_visual_perception(done, "Reach Success")
    absent = observation(element(label="Not complete", role="AXStaticText"))
    assert needs_visual_perception(absent, "Reach Success")


def test_cua_visual_provider_requires_exact_capture_and_preserves_icon_regions():
    class Driver:
        capabilities = type("Capabilities", (), {"visual_regions_contract": True})()

        async def capture(self, pid, window_id):
            from companion_agent.driver import DriverObservation

            native = DriverObservation("native-obs", pid, window_id, ())
            frame = PerceptionFrame.create(
                b"fixture",
                "native-obs",
                pid,
                window_id,
                200,
                100,
                BBox(10, 20, 400, 200),
                native_capture_id="native-cap",
            )
            return native, frame

        async def parse_visual_regions(self, capture_id):
            assert capture_id == "native-cap"
            return {
                "capture": {
                    "capture_id": capture_id,
                    "source": {"pid": 1, "window_id": 2},
                    "screenshot": {"width": 200, "height": 100},
                },
                "regions": [
                    {
                        "id": "vendor-text",
                        "kind": "text",
                        "text": "Continue",
                        "bounds": {"x": 20, "y": 10, "width": 50, "height": 20},
                        "confidence": 0.9,
                    },
                    {
                        "id": "vendor-icon",
                        "kind": "icon",
                        "label": "Settings",
                        "bounds": {"x": 100, "y": 10, "width": 20, "height": 20},
                        "confidence": 0.9,
                    },
                    {
                        "kind": "text",
                        "text": "bad",
                        "bounds": {"x": 199, "y": 0, "width": 3, "height": 4},
                        "confidence": 0.9,
                    },
                ],
            }

    async def scenario():
        result = await CuaVisualPerceptionProvider(Driver()).perceive(
            PerceptionContext("Click Continue", 1, 2, observation())
        )
        assert result.used_visual and result.frame.native_capture_id == "native-cap"
        assert [region.kind for region in result.regions] == ["text", "icon"]
        assert result.regions[0].source.value == "VISUAL"
        assert any(element.source == "VISUAL" for element in result.observation.elements)
        assert any(
            element.label == "Settings" and element.role == "AXButton" and element.interactive
            for element in result.observation.elements
        )
        assert all(region.capture_id == result.frame.capture_id for region in result.regions)

    asyncio.run(scenario())


def test_cua_visual_provider_fails_closed_without_native_capture_or_contract():
    class Driver:
        capabilities = type("Capabilities", (), {"visual_regions_contract": True})()

        async def capture(self, pid, window_id):
            from companion_agent.driver import DriverObservation

            return DriverObservation("obs", pid, window_id, ()), PerceptionFrame.create(
                b"fixture", "obs", pid, window_id, 2, 2, BBox(0, 0, 2, 2)
            )

    async def scenario():
        with pytest.raises(DriverError, match="unsupported"):
            await CuaVisualPerceptionProvider(Driver()).perceive(
                PerceptionContext("goal", 1, 2, observation())
            )
        driver = Driver()
        driver.capabilities = type("Capabilities", (), {"visual_regions_contract": False})()
        with pytest.raises(DriverError, match="unsupported"):
            await CuaVisualPerceptionProvider(driver).perceive(
                PerceptionContext("goal", 1, 2, observation())
            )

    asyncio.run(scenario())
