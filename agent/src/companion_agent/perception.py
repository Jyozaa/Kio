"""Provider-neutral perception; descriptions never confer execution authority."""

import asyncio
import hashlib
import math
import re
from dataclasses import dataclass, field, replace
from enum import StrEnum
from typing import Protocol

from .candidates import (
    CLICK_ROLES,
    SELECT_ROLES,
    TYPE_ROLES,
    Element,
    Observation,
    is_site_search_field,
    normalize,
)
from .driver import BrowserConsentRequired, DriverError
from .metrics import record, timed


class PerceptionSource(StrEnum):
    DOM = "DOM"
    STRUCTURED_BROWSER = "STRUCTURED_BROWSER"
    AX = "AX"
    OCR = "OCR"
    VISUAL = "VISUAL"
    GEMINI_HINT = "GEMINI_HINT"


@dataclass(frozen=True)
class BBox:
    x: float
    y: float
    width: float
    height: float

    def __post_init__(self):
        if (
            not all(math.isfinite(v) for v in (self.x, self.y, self.width, self.height))
            or min(self.width, self.height) <= 0
        ):
            raise ValueError("invalid_bbox")

    def overlap(self, other):
        area = max(0, min(self.x + self.width, other.x + other.width) - max(self.x, other.x)) * max(
            0, min(self.y + self.height, other.y + other.height) - max(self.y, other.y)
        )
        return area / min(self.width * self.height, other.width * other.height)


@dataclass(frozen=True)
class PerceptionFrame:
    capture_id: str
    observation_id: str
    pid: int
    window_id: int
    width: int
    height: int
    window_bounds: BBox
    digest: str
    image: bytes = field(repr=False, compare=False)
    native_capture_id: str | None = None

    @classmethod
    def create(
        cls, image, observation_id, pid, window_id, width, height, bounds, native_capture_id=None
    ):
        if (
            not image
            or not 0 < width <= 16384
            or not 0 < height <= 16384
            or width * height > 80_000_000
        ):
            raise ValueError("invalid_frame")
        digest = hashlib.sha256(image).hexdigest()
        identity = hashlib.sha256(
            f"{observation_id}:{pid}:{window_id}:{width}:{height}:{bounds}:{digest}".encode()
        ).hexdigest()
        return cls(
            identity,
            observation_id,
            pid,
            window_id,
            width,
            height,
            bounds,
            digest,
            image,
            native_capture_id,
        )


@dataclass(frozen=True)
class VisualRegion:
    id: str
    kind: str
    text: str
    bbox: BBox
    confidence: float
    observation_id: str
    capture_id: str
    source: PerceptionSource = PerceptionSource.OCR

    def __post_init__(self):
        if (
            not self.text.strip()
            or not math.isfinite(self.confidence)
            or not 0 <= self.confidence <= 1
        ):
            raise ValueError("invalid_region")


ObservedElement = Element  # Extend the working normalized type; do not duplicate its authority.


@dataclass(frozen=True)
class PerceptionContext:
    goal: str
    pid: int
    window_id: int
    observation: Observation | None = None
    frame: PerceptionFrame | None = None
    semantic_step: object | None = None


@dataclass(frozen=True)
class PerceptionResult:
    observation: Observation
    regions: tuple[VisualRegion, ...] = ()
    frame: PerceptionFrame | None = None
    warnings: tuple[str, ...] = ()
    used_visual: bool = False


class PerceptionProvider(Protocol):
    async def perceive(self, context: PerceptionContext) -> PerceptionResult: ...


class StructuredPerceptionProvider:
    def __init__(self, driver):
        self.driver = driver

    @timed("structured_observation")
    async def perceive(self, context):
        # A DOM provider must explicitly advertise a supported normalized contract.
        # Native AX containing web content is never mislabeled DOM.
        if getattr(self.driver, "supports_normalized_dom", False):
            try:
                started = asyncio.get_running_loop().time()
                observation = await self.driver.observe_dom(context.pid, context.window_id)
                record("dom_observation", asyncio.get_running_loop().time() - started)
                return PerceptionResult(normalize(observation))
            except DriverError as error:
                if error.code not in {"unsupported", "target_missing"}:
                    raise
        started = asyncio.get_running_loop().time()
        observation = await self.driver.observe(context.pid, context.window_id)
        record("ax_observation", asyncio.get_running_loop().time() - started)
        return PerceptionResult(normalize(observation))


class StructuredBrowserPerceptionProvider:
    """Expose a fresh CUA semantic browser snapshot as normalized elements.

    CUA refs and session IDs remain private native payload. Laya receives only
    locally generated candidate IDs and bounded descriptions.
    """

    def __init__(
        self,
        driver,
        fallback: StructuredPerceptionProvider | None = None,
        *,
        probe_non_browser: bool = True,
        prepare_on_consent: bool = True,
    ):
        self.driver = driver
        self.fallback = fallback or StructuredPerceptionProvider(driver)
        self.session = "kio-browser"
        self._started = False
        self._prepare_attempted: set[tuple[int, int]] = set()
        self._bound_target: tuple[int, int] | None = None
        self.probe_non_browser = probe_non_browser
        self.prepare_on_consent = prepare_on_consent

    @staticmethod
    def _likely_browser_goal(goal: str) -> bool:
        return bool(
            re.search(
                r"https?://|\b(?:browser|chrome|safari|firefox|edge|website|webpage|url|"
                r"new\s+tab|search|look\s+up|address\s+bar)\b",
                goal,
                re.IGNORECASE,
            )
        )

    async def _start(self):
        if self._started:
            return
        starter = getattr(self.driver, "start_session", None)
        if callable(starter):
            try:
                await starter(self.session)
            except DriverError as error:
                if error.code != "unsupported":
                    raise
        self._started = True

    async def close(self):
        if not self._started:
            return
        ender = getattr(self.driver, "end_session", None)
        self._started = False
        if callable(ender):
            try:
                await ender(self.session)
            except DriverError as error:
                if error.transport_failure:
                    raise
                if error.code not in {"unsupported", "target_missing", "driver_unavailable"}:
                    raise

    @staticmethod
    def _rows(value):
        if isinstance(value, dict):
            yield value
            for child in value.values():
                yield from StructuredBrowserPerceptionProvider._rows(child)
        elif isinstance(value, list):
            for child in value:
                yield from StructuredBrowserPerceptionProvider._rows(child)

    @staticmethod
    def _role(value):
        role = str(value or "").casefold()
        return {
            "button": "button",
            "link": "link",
            "checkbox": "checkbox",
            "radio": "radio",
            "tab": "tab",
            "option": "option",
            "textbox": "textbox",
            "searchbox": "searchbox",
            "combobox": "combobox",
            "listbox": "listbox",
        }.get(role)

    async def perceive(self, context):
        base = await self.fallback.perceive(context)
        if (
            not self.probe_non_browser
            and self._bound_target != (context.pid, context.window_id)
            and not self._likely_browser_goal(context.goal)
        ):
            return base
        await self._start()
        try:
            state = await self.driver.browser_state(
                context.pid, context.window_id, session=self.session
            )
        except BrowserConsentRequired:
            # An explicit browser task may start the official preparation
            # route automatically.  The driver remains the authority for any
            # genuine host consent; Kio never fabricates a browser action.
            target = (context.pid, context.window_id)
            if not self.prepare_on_consent:
                return replace(base, warnings=(*base.warnings, "browser_consent_required"))
            if target in self._prepare_attempted:
                return replace(base, warnings=(*base.warnings, "browser_consent_required"))
            self._prepare_attempted.add(target)
            preparer = getattr(self.driver, "browser_prepare", None)
            if not callable(preparer):
                return replace(base, warnings=(*base.warnings, "browser_consent_required"))
            try:
                await preparer(context.pid, context.window_id, session=self.session)
                state = await self.driver.browser_state(
                    context.pid, context.window_id, session=self.session
                )
            except BrowserConsentRequired:
                return replace(base, warnings=(*base.warnings, "browser_consent_required"))
            except DriverError as error:
                if error.transport_failure:
                    raise
                return base
        except DriverError as error:
            if error.transport_failure:
                raise
            return base
        bindings = []
        seen = set()
        target_id, tab_id = None, None
        for row in self._rows(state):
            target = row.get("target_id")
            tab = row.get("tab_id")
            if isinstance(target, str) and target and isinstance(tab, str) and tab:
                target_id, tab_id = target, tab
            ref = row.get("ref")
            role = self._role(row.get("role"))
            label = row.get("name", row.get("label", row.get("text", "")))
            if not isinstance(ref, str) or not ref or role is None or not isinstance(label, str):
                continue
            actions = row.get("actions", ())
            if not isinstance(actions, list) or not actions:
                continue
            key = (ref, role, label)
            if key in seen:
                continue
            seen.add(key)
            bindings.append((ref, role, label.strip(), row))
        from urllib.parse import quote

        from .browser import browser_url

        observed_url = browser_url(state)
        title = base.observation.title
        if tab_id:
            title += f"|kio_tab_id={tab_id}"
        if observed_url:
            title += "|kio_url=" + quote(observed_url, safe=":/?&=%#[]@!$'()*+,;~-._")
        if not bindings or not target_id or not tab_id:
            if title == base.observation.title:
                return base
            return replace(base, observation=replace(base.observation, title=title))
        self._bound_target = (context.pid, context.window_id)
        extra = []
        for index, (ref, role, label, row) in enumerate(bindings):
            if not label:
                continue
            native = {
                "structured_browser": True,
                "target_id": target_id,
                "tab_id": tab_id,
                "ref": ref,
                "session": self.session,
            }
            extra.append(
                Element(
                    f"sb_{index}_{re.sub(r'[^A-Za-z0-9_-]', '_', ref)[:40]}",
                    base.observation.snapshot_id,
                    label[:1000],
                    role,
                    row.get("value") if isinstance(row.get("value"), str) else None,
                    row.get("disabled") is not True,
                    row.get("visible") is not False,
                    PerceptionSource.STRUCTURED_BROWSER.value,
                    selected=row.get("selected") if isinstance(row.get("selected"), bool) else None,
                    checked=row.get("checked") if isinstance(row.get("checked"), bool) else None,
                    expanded=row.get("expanded") if isinstance(row.get("expanded"), bool) else None,
                    native=native,
                    sources=(PerceptionSource.STRUCTURED_BROWSER.value,),
                    interactive=True,
                )
            )
        if not extra:
            return replace(base, observation=replace(base.observation, title=title))
        return replace(
            base,
            observation=replace(
                base.observation,
                title=title,
                elements=merge_elements((*base.observation.elements, *extra)),
            ),
        )


class VisualPerceptionProvider:
    """Explicit stub until a local provider is installed; never fabricates detections."""

    async def perceive(self, context):
        if context.observation is None:
            raise DriverError("unsupported")
        return PerceptionResult(context.observation, warnings=("visual_perception_unavailable",))


class CuaVisualPerceptionProvider:
    """Use the installed, capture-bound CUA visual parser.

    The parser is an optional CUA extension.  Kio never treats its advertised
    schema as authority: a fresh screenshot capture, an exact capture id and a
    parser response bound to that same capture are all required before any
    visual element is exposed to candidate construction.
    """

    def __init__(self, driver, *, min_confidence=0.5, limit=300):
        self.driver = driver
        self.min_confidence = min_confidence
        self.limit = limit
        self.metrics = {}

    @staticmethod
    def _screen_box(row, frame, screenshot_width, screenshot_height):
        bounds = row.get("bounds")
        if not isinstance(bounds, dict):
            raise TypeError("invalid_bbox")
        values = tuple(bounds.get(key) for key in ("x", "y", "width", "height"))
        if any(type(value) not in (int, float) or not math.isfinite(value) for value in values):
            raise ValueError("invalid_bbox")
        x, y, width, height = values
        if (
            x < 0
            or y < 0
            or width <= 0
            or height <= 0
            or x + width > screenshot_width
            or y + height > screenshot_height
        ):
            raise ValueError("invalid_bbox")
        return BBox(
            frame.window_bounds.x + x * frame.window_bounds.width / screenshot_width,
            frame.window_bounds.y + y * frame.window_bounds.height / screenshot_height,
            width * frame.window_bounds.width / screenshot_width,
            height * frame.window_bounds.height / screenshot_height,
        )

    def _regions(self, data, frame):
        capture = data.get("capture")
        if not isinstance(capture, dict):
            raise DriverError("unsupported")
        if capture.get("capture_id") != frame.native_capture_id:
            raise DriverError("stale_state")
        source = capture.get("source", {})
        screenshot = capture.get("screenshot", {})
        if (
            source.get("pid") != frame.pid
            or source.get("window_id") != frame.window_id
            or screenshot.get("width") != frame.width
            or screenshot.get("height") != frame.height
        ):
            raise DriverError("stale_state")
        # The digest is evidence that the parser saw the same bytes.  If a
        # provider omits it, the capture id still binds the CUA action.
        digest = screenshot.get("sha256")
        if digest is not None and digest != frame.digest:
            raise DriverError("stale_state")
        rows = data.get("regions")
        if not isinstance(rows, list):
            raise DriverError("unsupported")
        result = []
        for row in rows[:2000]:
            if not isinstance(row, dict):
                continue
            kind = row.get("kind")
            if kind not in {"text", "icon"}:
                continue
            confidence = row.get("confidence")
            if (
                type(confidence) not in (int, float)
                or not math.isfinite(confidence)
                or not self.min_confidence <= confidence <= 1
            ):
                continue
            text = row.get("text") if kind == "text" else row.get("label")
            if not isinstance(text, str) or not text.strip() or len(text) > 1000:
                continue
            try:
                box = self._screen_box(row, frame, frame.width, frame.height)
            except ValueError:
                continue
            if any(
                old.text.casefold() == text.strip().casefold()
                and old.kind == kind
                and old.bbox.overlap(box) > 0.7
                for old in result
            ):
                continue
            result.append(
                VisualRegion(
                    f"r_{len(result)}",
                    kind,
                    text.strip(),
                    box,
                    float(confidence),
                    frame.observation_id,
                    frame.capture_id,
                    PerceptionSource.VISUAL,
                )
            )
        return tuple(sorted(result, key=lambda r: (r.bbox.y, r.bbox.x))[: self.limit])

    @timed("visual_perception")
    async def perceive(self, context):
        if not context.observation or not getattr(self.driver, "capabilities", None):
            raise DriverError("unsupported")
        if not self.driver.capabilities.visual_regions_contract:
            raise DriverError("unsupported")
        started = asyncio.get_running_loop().time()
        native_observation, frame = await self.driver.capture(context.pid, context.window_id)
        self.metrics["capture_seconds"] = asyncio.get_running_loop().time() - started
        if not frame.native_capture_id:
            raise DriverError("unsupported")
        started = asyncio.get_running_loop().time()
        parsed = await self.driver.parse_visual_regions(frame.native_capture_id)
        self.metrics["parser_seconds"] = asyncio.get_running_loop().time() - started
        regions = self._regions(parsed, frame)
        started = asyncio.get_running_loop().time()
        observation = normalize(native_observation)
        visual = []
        # Icon classifications remain provenance only.  Without a semantic
        # label they are never converted into clickable candidates.
        for region in regions:
            box = region.bbox
            # An icon becomes actionable only when CUA Perception supplies a
            # human-readable semantic label.  Detector class IDs and unlabeled
            # glyphs remain descriptive regions, never guessed controls.
            interactive = region.kind == "icon" and bool(region.text.strip())
            visual.append(
                Element(
                    region.id,
                    observation.snapshot_id,
                    region.text,
                    "AXButton" if interactive else "AXStaticText",
                    region.text,
                    True,
                    True,
                    PerceptionSource.VISUAL.value,
                    native={"frame": {"x": box.x, "y": box.y, "w": box.width, "h": box.height}},
                    sources=(PerceptionSource.VISUAL.value,),
                    confidence=region.confidence,
                    interactive=interactive,
                    capture_id=frame.capture_id,
                )
            )
        elements = merge_elements((*observation.elements, *visual))
        self.metrics["merge_seconds"] = asyncio.get_running_loop().time() - started
        self.metrics["region_count"] = len(regions)
        return PerceptionResult(
            replace(observation, elements=elements),
            regions,
            frame,
            warnings=("cua_visual_perception",),
            used_visual=True,
        )


@dataclass(frozen=True)
class FallbackConfig:
    min_labelled_controls: int = 1
    min_goal_coverage: float = 0.15


DEFAULT_FALLBACK = FallbackConfig()


def _element_context(element):
    values = []
    for key in (
        "parent_label",
        "ancestor_labels",
        "region_label",
        "container_label",
        "group_label",
        "row_label",
        "nearby_labels",
    ):
        value = element.native.get(key)
        if isinstance(value, str) and value.strip():
            values.append(value.strip().casefold())
        elif isinstance(value, (list, tuple)):
            values.extend(str(item).strip().casefold() for item in value if str(item).strip())
    return tuple(values)


def _primary_media_context(element):
    if element.native.get("is_primary_media_control") is True:
        return True
    return bool(
        re.search(
            r"\b(?:transport|media|playback|now playing|player|track controls)\b",
            " ".join(_element_context(element)),
        )
    )


def needs_visual_perception(observation, goal, config=DEFAULT_FALLBACK, semantic_step=None):
    from .verification import GoalVerifier, VerificationStatus, semantic_expectations

    # Completion markers can be sufficient structured evidence even with no controls.
    if (
        GoalVerifier(semantic_expectations(semantic_step))
        .check(goal, observation, observation, [])
        .status
        == VerificationStatus.VERIFIED
    ):
        return False
    if re.match(r"^\s*scroll\b", goal, re.IGNORECASE) and any(
        e.visible
        and e.role in {"AXScrollArea", "AXWebArea"}
        and isinstance(e.native.get("element_token"), str)
        and bool(e.native["element_token"])
        for e in observation.elements
    ):
        # A fresh Driver scroll token is sufficient structure; OCR would add image
        # jitter to the fingerprint without granting any additional scroll authority.
        return False
    controls = [
        e
        for e in observation.elements
        if e.visible
        and e.enabled
        and e.label.strip()
        and e.role in CLICK_ROLES | TYPE_ROLES | SELECT_ROLES
    ]
    if semantic_step is None and any(
        e.role in TYPE_ROLES and e.label.casefold() in goal.casefold() for e in controls
    ):
        return False
    semantic_operation = str(getattr(getattr(semantic_step, "operation", None), "value", ""))
    semantic_object = str(getattr(getattr(semantic_step, "object_type", None), "value", ""))
    if semantic_step is not None:
        if semantic_operation == "SET_STATE" and semantic_object == "MEDIA_PLAYBACK":
            desired = str(getattr(getattr(semantic_step, "desired_state", None), "value", ""))
            terms = {"play", "resume", "start"} if desired == "PLAYING" else {"pause"}
            grounded = [
                e
                for e in controls
                if e.role in CLICK_ROLES and set(re.findall(r"\w+", e.label.casefold())) & terms
            ]
            contextual = [e for e in grounded if _primary_media_context(e)]
            return len(contextual) != 1
        if semantic_operation == "ACTIVATE_CONTROL_ONCE":
            target = str(getattr(semantic_step, "object_label", "")).casefold()
            terms = set(re.findall(r"\w+", target))
            grounded = [
                e
                for e in controls
                if e.role in CLICK_ROLES
                and (
                    terms & set(re.findall(r"\w+", e.label.casefold()))
                    or ("selected" in terms and e.selected is True)
                )
            ]
            if len(grounded) == 1:
                return False
            if len(grounded) > 1:
                contexts = [tuple(_element_context(e)) for e in grounded]
                return len(set(contexts)) < len(contexts)
            return True
        if semantic_operation == "SEARCH":
            search_fields = [e for e in controls if is_site_search_field(e)]
            return len(search_fields) != 1
        if semantic_operation == "CAPTURE" and semantic_object == "PHOTO":
            terms = {"capture", "shutter", "photo", "picture", "photograph"}
            return not any(set(re.findall(r"\w+", e.label.casefold())) & terms for e in controls)
        if semantic_operation == "CREATE":
            create_terms = {
                "new",
                "create",
                "note",
                "document",
                "email",
                "mail",
                "message",
                "folder",
                "compose",
            }
            return not any(
                e.role in CLICK_ROLES and set(re.findall(r"\w+", e.label.casefold())) & create_terms
                for e in controls
            )
        if semantic_operation == "NEW_TAB":
            return not any(
                e.role in CLICK_ROLES
                and set(re.findall(r"\w+", e.label.casefold())) & {"new", "tab"}
                for e in controls
            )
        if semantic_operation in {"TYPE", "SET_FIELD"}:
            field_name = str(getattr(semantic_step, "parameters", {}).get("field", ""))
            field_terms = {
                "title": {"title", "name"},
                "body": {"body", "message", "note", "content"},
                "recipient": {"to", "recipient"},
                "subject": {"subject"},
            }.get(field_name, {field_name})
            return not any(
                e.role in TYPE_ROLES and set(re.findall(r"\w+", e.label.casefold())) & field_terms
                for e in controls
            )
    words = set(re.findall(r"\w+", goal.casefold())) - {
        "the",
        "a",
        "an",
        "click",
        "press",
        "open",
        "enter",
        "type",
        "in",
        "into",
        "then",
        "and",
        "field",
        "button",
        "to",
        "reach",
    }
    represented = set(
        re.findall(r"\w+", " ".join(e.label for e in observation.elements if e.visible).casefold())
    )
    coverage = len(words & represented) / max(1, len(words))
    return len(controls) < config.min_labelled_controls or (
        bool(words) and coverage < config.min_goal_coverage
    )


def element_box(element):
    frame = element.native.get("frame", {})
    try:
        return BBox(frame["x"], frame["y"], frame["w"], frame["h"])
    except (KeyError, ValueError, TypeError):
        return None


@timed("perception_merge")
def merge_elements(elements):
    precedence = {
        "DOM": 0,
        "STRUCTURED_BROWSER": 0,
        "AX": 1,
        "VISUAL": 2,
        "OCR": 3,
        "GEMINI_HINT": 4,
    }
    result = []
    for item in sorted(elements, key=lambda e: precedence.get(e.source, 9)):
        matches = []
        for index, current in enumerate(result):
            if item.snapshot_id != current.snapshot_id:
                raise DriverError("stale_state")
            identity = item.native.get("element_token")
            same_native = identity is not None and identity == current.native.get("element_token")
            a, b = element_box(item), element_box(current)
            text_equal = re.sub(r"\W+", "", item.label.casefold()) == re.sub(
                r"\W+", "", current.label.casefold()
            ) and bool(item.label.strip())
            # Semantic agreement AND substantial overlap; repeated labels stay distinct.
            spatial = bool(
                a
                and b
                and a.overlap(b) >= 0.7
                and text_equal
                and (item.role == current.role or item.source in {"OCR", "VISUAL"})
            )
            if same_native or spatial:
                matches.append(index)
        if len(matches) == 1:
            i = matches[0]
            sources = tuple(
                dict.fromkeys((*result[i].sources, result[i].source, *item.sources, item.source))
            )
            result[i] = replace(result[i], sources=sources)
            if item.source in {"VISUAL", "OCR"} and result[i].capture_id is None:
                result[i] = replace(result[i], capture_id=item.capture_id)
            # If a structured/AX element already carries a capture-bound
            # visual authority, preserve it when a higher-authority duplicate
            # is merged.  Losing this token would turn a safe visual candidate
            # into an unexecutable or, worse, unbound one.
            if result[i].capture_id is None and item.capture_id is not None:
                result[i] = replace(result[i], capture_id=item.capture_id)
        else:
            result.append(replace(item, sources=item.sources or (item.source,)))
    return tuple(result)


class CompositePerceptionProvider:
    def __init__(self, structured, visual=None, *, timeout=20, config=DEFAULT_FALLBACK):
        self.structured = structured
        self.visual = visual
        self.timeout = timeout
        self.config = config

    async def perceive(self, context):
        try:
            result = await asyncio.wait_for(self.structured.perceive(context), self.timeout)
        except TimeoutError:
            raise DriverError("perception_timeout") from None
        if self.visual is None or not needs_visual_perception(
            result.observation, context.goal, self.config, context.semantic_step
        ):
            return result
        try:
            visual = await asyncio.wait_for(
                self.visual.perceive(replace(context, observation=result.observation)), self.timeout
            )
            if (
                visual.frame is None
                and visual.observation.snapshot_id != result.observation.snapshot_id
            ):
                raise DriverError("stale_state")
            if visual.frame and (
                visual.frame.observation_id != visual.observation.snapshot_id
                or visual.frame.pid != context.pid
                or visual.frame.window_id != context.window_id
            ):
                raise DriverError("stale_state")
            if visual.regions and (
                visual.frame is None
                or any(
                    region.observation_id != visual.frame.observation_id
                    or region.capture_id != visual.frame.capture_id
                    for region in visual.regions
                )
            ):
                raise DriverError("stale_state")
            elements = merge_elements(
                visual.observation.elements
                if visual.frame
                else (*result.observation.elements, *visual.observation.elements)
            )
            return replace(visual, observation=replace(visual.observation, elements=elements))
        except DriverError as error:
            if error.transport_failure:
                raise
            return replace(result, warnings=(*result.warnings, "visual_perception_failed"))
        except Exception:  # noqa: BLE001 -- optional provider errors are sanitized
            return replace(result, warnings=(*result.warnings, "visual_perception_failed"))
