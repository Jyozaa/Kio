"""Locally constructed, bounded and single-use action capabilities."""

import hashlib
import json
import os
import re
import uuid
from collections.abc import Mapping
from dataclasses import dataclass, field, replace
from difflib import SequenceMatcher
from enum import StrEnum
from types import MappingProxyType

from .driver import DriverError, DriverObservation
from .metrics import timed


class Operation(StrEnum):
    CLICK = "CLICK"
    TYPE_TEXT = "TYPE_TEXT"
    SELECT = "SELECT"
    SCROLL_UP = "SCROLL_UP"
    SCROLL_DOWN = "SCROLL_DOWN"
    WAIT = "WAIT"
    DONE = "DONE"
    BLOCKED = "BLOCKED"
    REOBSERVE = "REOBSERVE"


@dataclass(frozen=True)
class Element:
    id: str
    snapshot_id: str
    label: str
    role: str
    value: str | None
    enabled: bool
    visible: bool
    source: str
    selected: bool | None = None
    checked: bool | None = None
    expanded: bool | None = None
    native: Mapping = field(default_factory=dict, repr=False, compare=False)
    sources: tuple[str, ...] = ()
    confidence: float = 1.0
    interactive: bool | None = None
    capture_id: str | None = None


@dataclass(frozen=True)
class Observation:
    snapshot_id: str
    pid: int
    window_id: int
    elements: tuple[Element, ...]
    title: str = ""

    def fingerprint(self) -> str:
        state = [
            (
                e.role,
                e.label,
                e.value,
                e.enabled,
                e.visible,
                e.selected,
                e.checked,
                e.expanded,
                dict(e.native.get("frame", {})),
            )
            for e in self.elements
        ]
        return hashlib.sha256(
            json.dumps([self.pid, self.window_id, state], sort_keys=True).encode()
        ).hexdigest()


def normalize(observation: DriverObservation) -> Observation:
    elements = []
    window_frame = next(
        (c.native.get("frame", {}) for c in observation.controls if c.role == "AXWindow"), {}
    )
    web_scoped = any(c.native.get("in_web_content") for c in observation.controls)
    dialog_roots = {
        c.native.get("element_index")
        for c in observation.controls
        if c.role in {"AXSheet", "AXDialog", "AXAlert", "AXFileChooser"}
        and type(c.native.get("element_index")) is int
    }
    # Some ordinary macOS/browser alerts are exposed as a small AXWindow instead of
    # AXAlert/AXSheet. Recognize the compact, text-and-button-only window shape
    # generically; this grants no new execution primitive, only fresh-token routing.
    by_index = {
        c.native.get("element_index"): c
        for c in observation.controls
        if type(c.native.get("element_index")) is int
    }
    allowed_dialog_roles = {
        "AXWindow",
        "AXHeading",
        "AXStaticText",
        "AXButton",
        "AXTextField",
        "AXTextArea",
        "AXImage",
        "AXGroup",
    }
    for control in observation.controls:
        if control.role != "AXWindow" or type(control.native.get("element_index")) is not int:
            continue
        frame = control.native.get("frame", {})
        root = control.native["element_index"]
        descendants = {root}
        changed = True
        while changed:
            changed = False
            for index, child in by_index.items():
                if index not in descendants and child.native.get("parent_index") in descendants:
                    descendants.add(index)
                    changed = True
        subtree = [by_index[index] for index in descendants if index in by_index]
        if (
            frame.get("w", float("inf")) <= 700
            and frame.get("h", float("inf")) <= 500
            and len(subtree) <= 12
            and any(child.role == "AXButton" for child in subtree)
            and all(child.role in allowed_dialog_roles for child in subtree)
            and not any(child.role in {"AXWebArea", "AXScrollArea"} for child in subtree)
        ):
            dialog_roots.add(root)
    dialog_descendants = set(dialog_roots)
    changed = True
    while changed:
        changed = False
        for index, control in by_index.items():
            if index in dialog_descendants:
                continue
            if control.native.get("parent_index") in dialog_descendants:
                dialog_descendants.add(index)
                changed = True
    for control in observation.controls:
        chrome_label = control.label.casefold().strip()
        browser_chrome = control.role in CLICK_ROLES | TYPE_ROLES and bool(
            re.search(
                r"\b(?:address|location|search or enter|new tab|back|forward|reload|refresh|stop loading)\b",
                chrome_label,
            )
        )
        if (
            web_scoped
            and not control.native.get("in_web_content")
            and control.role != "AXWindow"
            and control.native.get("element_index") not in dialog_descendants
            and not browser_chrome
            and not (
                control.role == "AXMenuItem" and control.native.get("frame", {}).get("h", 0) > 1
            )
        ):
            continue
        native = control.native
        frame = native.get("frame", {})
        visible = native.get("visible")
        if not isinstance(visible, bool):
            visible = frame.get("w", 0) > 1 and frame.get("h", 0) > 1
        if visible and frame and window_frame.get("w", 0) > 1 and window_frame.get("h", 0) > 1:
            visible = (
                frame.get("x", 0) < window_frame.get("x", 0) + window_frame["w"]
                and frame.get("y", 0) < window_frame.get("y", 0) + window_frame["h"]
                and frame.get("x", 0) + frame.get("w", 0) > window_frame.get("x", 0)
                and frame.get("y", 0) + frame.get("h", 0) > window_frame.get("y", 0)
            )
        normalized_native = dict(native)
        if native.get("element_index") in dialog_descendants:
            normalized_native["in_system_dialog"] = True
        checked = native.get("checked")
        if type(checked) is not bool and "checkbox" in control.role.casefold():
            raw_value = native.get("value", control.value)
            if type(raw_value) is bool:
                checked = raw_value
            elif type(raw_value) in (int, float) and raw_value in (0, 1):
                checked = bool(raw_value)
            elif isinstance(raw_value, str) and raw_value.strip().casefold() in {
                "0",
                "1",
                "true",
                "false",
            }:
                checked = raw_value.strip().casefold() in {"1", "true"}
        elements.append(
            Element(
                control.local_id,
                observation.snapshot_id,
                control.label,
                control.role,
                control.value,
                native.get("enabled", True) is True,
                visible,
                control.source,
                native.get("selected"),
                checked,
                native.get("expanded"),
                MappingProxyType(normalized_native),
                sources=(control.source,),
            )
        )
    title = next((e.label for e in elements if e.role == "AXWindow"), "")
    return Observation(
        observation.snapshot_id, observation.pid, observation.window_id, tuple(elements), title
    )


def is_actionable_geometry(element: Element) -> bool:
    """Reject clipped AX menu fragments that cannot identify a distinct control."""
    if element.role == "AXMenuItem":
        frame = element.native.get("frame", {})
        if isinstance(frame, dict) and frame.get("h", 10) < 10:
            return False
    return True


@dataclass(frozen=True)
class SemanticTargetIdentity:
    """Stable semantic description used only to re-ground fresh execution authority."""

    operation: str
    object_type: str
    canonical_label: str
    role_family: str
    parent_context: str = ""
    region_context: str = ""
    nearby_context: tuple[str, ...] = ()
    selected_state: bool | None = None
    checked_state: bool | None = None
    semantic_scope: str = ""


@dataclass(frozen=True)
class CandidateAction:
    id: str
    snapshot_id: str
    operation: Operation
    description: str
    element_id: str | None = None
    payload: Mapping = field(default_factory=dict, repr=False, compare=False)
    target_identity: SemanticTargetIdentity | None = field(default=None, repr=False, compare=False)


@dataclass(frozen=True)
class ExecutionResult:
    status: str
    changed: bool = False


class CandidateTable:
    def __init__(self, observation: Observation, candidates: list[CandidateAction]):
        self.observation = observation
        self._consumed = False
        if len({c.id for c in candidates}) != len(candidates):
            raise DriverError("duplicate_candidate")
        if any(c.snapshot_id != observation.snapshot_id for c in candidates):
            raise DriverError("stale_state")
        self.actions = MappingProxyType({c.id: c for c in candidates})

    def discard(self) -> None:
        self._consumed = True

    def validate(self, candidate_id: str, snapshot_id: str) -> CandidateAction:
        if self._consumed or snapshot_id != self.observation.snapshot_id:
            raise DriverError("stale_state")
        if candidate_id not in self.actions:
            raise DriverError("unknown_candidate")
        return self.actions[candidate_id]

    def take(self, ids: list[str], snapshot_id: str) -> CandidateAction:
        # All invalid execution attempts also destroy this capability table.
        try:
            if len(ids) != 1 or len(set(ids)) != len(ids):
                raise DriverError("duplicate_candidate")
            return self.validate(ids[0], snapshot_id)
        finally:
            self.discard()

    def public_choices(self, operation: Operation) -> dict[str, str]:
        return {c.id: c.description for c in self.actions.values() if c.operation == operation}


CLICK_ROLES = {
    "AXButton",
    "AXCheckBox",
    "AXRadioButton",
    "AXLink",
    "AXMenuItem",
    "AXTab",
    "option",
    "button",
    "link",
    "checkbox",
    "radio",
}
TYPE_ROLES = {"AXTextField", "AXTextArea", "AXSearchField", "textbox", "searchbox"}
SELECT_ROLES = {"AXPopUpButton", "AXComboBox", "combobox", "listbox"}


@timed("candidate_build")
def build_candidates(
    observation: Observation,
    goal: str,
    max_targets: int | None = None,
    *,
    visual_frame=None,
    allowed_operations: set[Operation] | None = None,
    semantic_step=None,
    diagnostic_unbounded: bool = False,
) -> CandidateTable:
    if type(diagnostic_unbounded) is not bool:
        raise ValueError("diagnostic_unbounded must be a boolean")
    if allowed_operations is not None and (
        not isinstance(allowed_operations, set)
        or any(not isinstance(operation, Operation) for operation in allowed_operations)
    ):
        raise ValueError("allowed_operations must contain only validated operations")
    cap = int(os.environ.get("MAX_TARGET_CANDIDATES", "8")) if max_targets is None else max_targets
    if not 1 <= cap <= 100:
        raise ValueError("MAX_TARGET_CANDIDATES must be between 1 and 100")
    cap = min(max(1, len(observation.elements)), 304) if diagnostic_unbounded else min(cap, 8)
    words = set(re.findall(r"\w+", goal.casefold()))
    action_words = {
        "click",
        "press",
        "open",
        "reach",
        "choose",
        "select",
        "the",
        "a",
        "an",
        "button",
        "then",
        "and",
    }
    target_words = words - action_words
    eligible = [e for e in observation.elements if e.enabled and e.visible and e.label.strip()]
    semantic_operation = getattr(getattr(semantic_step, "operation", None), "value", "")
    semantic_label = str(getattr(semantic_step, "object_label", "")).casefold()
    semantic_object = getattr(getattr(semantic_step, "object_type", None), "value", "")
    desired_state = str(getattr(getattr(semantic_step, "desired_state", None), "value", ""))
    visual_words = set(target_words)
    if semantic_operation == "SEARCH":
        # Search OCR labels such as "Search videos" can ground a click-to-focus
        # action. Typing still requires a new, structured editable token.
        visual_words.add("search")
    if semantic_operation == "SET_STATE" and semantic_object == "MEDIA_PLAYBACK":
        media_terms = {"play", "resume", "start"} if desired_state == "PLAYING" else {"pause"}
        visual_words.update(media_terms)
        candidates = [
            e
            for e in eligible
            if e.role in CLICK_ROLES and set(re.findall(r"\w+", e.label.casefold())) & media_terms
        ]
        contextual = [e for e in candidates if _has_primary_media_context(e)]
        # A lone Play/Pause label can belong to an album row or preview. Require
        # observed transport context before offering a persistent playback action.
        eligible = contextual
        cap = min(cap, 10)
    elif semantic_operation == "CAPTURE" and semantic_object == "PHOTO":
        capture_terms = {"take", "capture", "shutter"}
        visual_words.update(capture_terms)
        eligible = [
            e
            for e in eligible
            if e.role in CLICK_ROLES and set(re.findall(r"\w+", e.label.casefold())) & capture_terms
        ]
        cap = min(cap, 10)
    elif semantic_operation == "CREATE":
        create_terms = {
            "create",
            "new",
            "note",
            "document",
            "email",
            "mail",
            "message",
            "folder",
            "compose",
        }
        visual_words.update(create_terms)
        grounded = [
            e
            for e in eligible
            if e.role in CLICK_ROLES and set(re.findall(r"\w+", e.label.casefold())) & create_terms
        ]
        if grounded:
            eligible = grounded
        cap = min(cap, 10)
    elif semantic_operation == "NEW_TAB":
        visual_words.update({"new", "tab"})
        grounded = [
            e
            for e in eligible
            if e.role in CLICK_ROLES
            and set(re.findall(r"\w+", e.label.casefold())) & {"new", "tab"}
        ]
        if grounded:
            eligible = grounded
        cap = min(cap, 10)
    if semantic_operation == "SET_STATE" and semantic_label == "microphone":
        matching = [
            e
            for e in eligible
            if e.role in CLICK_ROLES
            and re.search(
                r"\b(?:mute|muted|unmute|microphone|mic|audio input)\b",
                e.label,
                re.IGNORECASE,
            )
        ]
        if matching:
            eligible = matching
    elif semantic_operation == "SEARCH":
        search_fields = [e for e in eligible if is_site_search_field(e)]
        if allowed_operations == {Operation.TYPE_TEXT}:
            eligible = search_fields
        elif allowed_operations == {Operation.CLICK}:
            eligible = [
                e
                for e in eligible
                if (
                    e.role in CLICK_ROLES
                    and re.search(r"\b(?:search|submit|go)\b", e.label, re.IGNORECASE)
                )
                or (
                    e.source in {"OCR", "VISUAL"}
                    and re.search(r"\bsearch\b", e.label, re.IGNORECASE)
                )
            ]
    elif semantic_operation == "ACTIVATE_CONTROL_ONCE":
        target_terms = set(re.findall(r"\w+", semantic_label))
        if target_terms:
            relevant = [
                e
                for e in eligible
                if (e.role in CLICK_ROLES or e.source in {"OCR", "VISUAL"})
                and _activation_target_match(e, target_terms)
            ]
            eligible = relevant
    # Relevance first, original layout order as stable tie-break; never model filtering.
    # A visible matching text field removes unrelated navigation for an explicit
    # fill subgoal; Laya still chooses the operation and may abstain.
    if re.match(r"^(enter|type|fill|write)\b", goal.strip(), re.IGNORECASE):
        matching_fields = [
            e for e in eligible if e.role in TYPE_ROLES and e.label.casefold() in goal.casefold()
        ]
        if matching_fields:
            eligible = matching_fields
    if re.match(r"^(choose|select)\b", goal.strip(), re.IGNORECASE):
        options = [
            e for e in eligible if e.role in {"AXMenuItem", "option"} and is_actionable_geometry(e)
        ]
        selectors = [e for e in eligible if e.role in SELECT_ROLES]
        if options:
            asks_named_option = bool(re.search(r"\boption\s+[\w-]+", goal, re.IGNORECASE))
            named = [e for e in options if set(re.findall(r"\w+", e.label.casefold())) <= words]
            # An AX menu often exposes only the currently selected item while closed.
            # Never turn that mismatched value into the requested selection target.
            eligible = (named if named else selectors) if asks_named_option else options
        elif selectors:
            eligible = selectors
    if re.match(r"^(click|press|open|reach)\b", goal.strip(), re.IGNORECASE):
        meaningful = words - {"the", "a", "an", "button", "state"}
        relevant = [
            e
            for e in eligible
            if e.role in CLICK_ROLES and set(re.findall(r"\w+", e.label.casefold())) <= meaningful
        ]
        if relevant:
            eligible = relevant
    eligible.sort(
        key=lambda e: _semantic_candidate_score(e, words, goal),
        reverse=True,
    )
    # A merged semantic observation can describe the same control through AX and
    # CUA Perception. Keep both authorities as separate choices; the selected
    # candidate, not the window route, determines how it executes.
    if visual_frame is not None and visual_frame.native_capture_id:
        expanded = []
        for element in eligible:
            expanded.append(element)
            if (
                element.source == "AX"
                and element.capture_id == visual_frame.capture_id
                and {"OCR", "VISUAL"} & set(element.sources)
            ):
                expanded.append(
                    replace(
                        element,
                        id=f"{element.id}_visual",
                        source="VISUAL",
                        sources=("VISUAL",),
                    )
                )
        eligible = expanded
    prefix = "c_" + uuid.uuid4().hex[:12] + "_"
    actions = []
    selecting = bool(re.match(r"^(choose|select)\b", goal.strip(), re.IGNORECASE))
    option_roles = {"AXMenuItem", "option"}
    for operation, roles in (
        (Operation.CLICK, CLICK_ROLES - option_roles if selecting else CLICK_ROLES),
        (Operation.TYPE_TEXT, TYPE_ROLES),
        (Operation.SELECT, SELECT_ROLES | option_roles if selecting else SELECT_ROLES),
    ):
        if allowed_operations is not None and operation not in allowed_operations:
            continue
        seen = set()
        count = 0
        for element in eligible:
            if element.snapshot_id != observation.snapshot_id:
                raise DriverError("stale_state")
            visual = element.source in {"OCR", "VISUAL"}
            if visual:
                if (
                    operation != Operation.CLICK
                    or visual_frame is None
                    or not visual_frame.native_capture_id
                    or element.capture_id != visual_frame.capture_id
                    or element.snapshot_id != visual_frame.observation_id
                    or element.confidence < 0.5
                    or not (
                        re.match(
                            r"^(click|press|open|reach|choose|select)\b",
                            goal.strip(),
                            re.IGNORECASE,
                        )
                        or semantic_operation
                        in {
                            "SET_STATE",
                            "SET_FIELD",
                            "TYPE",
                            "CREATE",
                            "CAPTURE",
                            "NEW_TAB",
                            "ACTIVATE_CONTROL_ONCE",
                            "SEARCH",
                        }
                    )
                    or not _visual_goal_match(element.label, visual_words)
                ):
                    continue
                box = element.native.get("frame", {})
                bounds = visual_frame.window_bounds
                try:
                    bx, by, bw, bh = (float(box[k]) for k in ("x", "y", "w", "h"))
                    inside = (
                        bw > 0
                        and bh > 0
                        and bx >= bounds.x
                        and by >= bounds.y
                        and bx + bw <= bounds.x + bounds.width
                        and by + bh <= bounds.y + bounds.height
                    )
                    point_x = round((bx - bounds.x + bw / 2) * visual_frame.width / bounds.width)
                    point_y = round((by - bounds.y + bh / 2) * visual_frame.height / bounds.height)
                    point_valid = (
                        inside
                        and bw * visual_frame.width / bounds.width >= 2
                        and bh * visual_frame.height / bounds.height >= 2
                        and 0 <= point_x < visual_frame.width
                        and 0 <= point_y < visual_frame.height
                    )
                except (KeyError, TypeError, ValueError, ZeroDivisionError):
                    point_valid = False
                if not point_valid:
                    continue
            elif element.role not in roles:
                continue
            if operation == Operation.TYPE_TEXT:
                from .policy import literal_text

                supplied = literal_text(goal)
                if supplied is not None and element.value == supplied:
                    continue

            frame = element.native.get("frame", {})
            # Same label at different positions is NOT the same control.
            key = (
                element.role,
                element.label.casefold().strip(),
                element.value,
                tuple(round(frame.get(k, 0) / 2) for k in ("x", "y", "w", "h")),
                "VISUAL"
                if visual
                else "STRUCTURED_BROWSER"
                if element.native.get("structured_browser") is True
                else "ACCESSIBILITY",
            )
            if key in seen:
                continue
            seen.add(key)
            payload_data = {
                "pid": observation.pid,
                "window_id": observation.window_id,
                "element_token": element.native.get("element_token"),
                "element_index": element.native.get("element_index"),
                "role": element.role,
                "in_web_content": element.native.get("in_web_content") is True,
                "in_system_dialog": element.native.get("in_system_dialog") is True,
            }
            # Structured browser refs are CUA-issued, task-scoped authority.
            # Keep them private to the execution payload; public model choices
            # contain only the locally generated candidate ID and description.
            if element.native.get("structured_browser") is True:
                for key in ("structured_browser", "target_id", "tab_id", "ref", "session"):
                    value = element.native.get(key)
                    if isinstance(value, str) and value:
                        payload_data[key] = value
            if visual:
                payload_data.update(
                    {
                        "visual": True,
                        "authority": "VISUAL",
                        "capture_id": visual_frame.native_capture_id,
                        "frame_digest": visual_frame.digest,
                        "observation_id": visual_frame.observation_id,
                        "frame_width": visual_frame.width,
                        "frame_height": visual_frame.height,
                        "x": point_x,
                        "y": point_y,
                        # Canonical local goal token lets progress tracking tolerate OCR
                        # spelling noise without exposing authority to the chooser.
                        "goal_target": _visual_goal_target(element.label, visual_words),
                    }
                )
            elif element.native.get("structured_browser") is True:
                payload_data["authority"] = "STRUCTURED_BROWSER"
            else:
                payload_data["authority"] = "ACCESSIBILITY"
            payload = MappingProxyType(payload_data)
            checked_description = (
                f"; checked={'checked' if element.checked else 'unchecked'}"
                if element.checked is not None and "checkbox" in element.role.casefold()
                else ""
            )
            context_labels = []
            for context_key in (
                "parent_label",
                "region_label",
                "container_label",
                "row_label",
                "nearby_labels",
            ):
                context_value = element.native.get(context_key)
                if isinstance(context_value, str) and context_value.strip():
                    context_labels.append(context_value.strip())
                elif isinstance(context_value, (list, tuple)):
                    context_labels.extend(
                        str(value).strip() for value in context_value if str(value).strip()
                    )
            context_suffix = (
                f"; context={' / '.join(context_labels[:3])[:100]}" if context_labels else ""
            )
            description = (
                f"{element.label[:160]} (visual text; position={_position_bucket(box, visual_frame)})"
                if visual
                else f"{element.label[:160]} ({element.role}; value={str(element.value or '')[:100]}{checked_description}{context_suffix})"
            )
            actions.append(
                CandidateAction(
                    prefix + str(len(actions)),
                    observation.snapshot_id,
                    operation,
                    description,
                    element.id,
                    payload,
                    semantic_target_identity(element, operation, semantic_step),
                )
            )
            count += 1
            if count >= cap:
                break
    scroll_target = next(
        (
            e
            for role in ("AXScrollArea", "AXWebArea", "AXWindow")
            for e in observation.elements
            if e.role == role and e.visible and e.native.get("element_token")
        ),
        None,
    )
    for operation in (
        Operation.SCROLL_UP,
        Operation.SCROLL_DOWN,
        Operation.WAIT,
        Operation.DONE,
        Operation.BLOCKED,
        Operation.REOBSERVE,
    ):
        if (
            allowed_operations is not None
            and operation in {Operation.SCROLL_UP, Operation.SCROLL_DOWN}
            and operation not in allowed_operations
        ):
            continue
        actions.append(
            CandidateAction(
                prefix + str(len(actions)),
                observation.snapshot_id,
                operation,
                operation.value,
                scroll_target.id
                if scroll_target and operation in {Operation.SCROLL_UP, Operation.SCROLL_DOWN}
                else None,
                MappingProxyType(
                    {
                        "pid": observation.pid,
                        "window_id": observation.window_id,
                        "element_token": scroll_target.native.get("element_token"),
                    }
                )
                if scroll_target and operation in {Operation.SCROLL_UP, Operation.SCROLL_DOWN}
                else MappingProxyType({}),
                semantic_target_identity(scroll_target, operation, semantic_step)
                if scroll_target and operation in {Operation.SCROLL_UP, Operation.SCROLL_DOWN}
                else None,
            )
        )
    return CandidateTable(observation, actions)


def semantic_target_identity(element, operation, semantic_step=None):
    """Construct a deterministic target identity from observed candidate data."""
    native = element.native

    def context_value(key):
        value = native.get(key, "")
        if isinstance(value, (list, tuple)):
            return tuple(str(item).strip().casefold() for item in value if str(item).strip())
        return tuple(part.strip().casefold() for part in str(value).split(" / ") if part.strip())

    role = element.role.casefold()
    role_family = (
        "field"
        if role in {value.casefold() for value in TYPE_ROLES}
        else "selector"
        if role in {value.casefold() for value in SELECT_ROLES}
        else "control"
        if role in {value.casefold() for value in CLICK_ROLES}
        else role
    )
    scope = "web" if native.get("in_web_content") is True else "app"
    if isinstance(native.get("tab_id"), str):
        scope += ":tab=" + native["tab_id"]
    if isinstance(native.get("target_id"), str):
        scope += ":target=" + native["target_id"]
    return SemanticTargetIdentity(
        operation.value if isinstance(operation, Operation) else str(operation),
        str(getattr(getattr(semantic_step, "object_type", None), "value", "")),
        re.sub(r"\W+", " ", element.label.casefold()).strip(),
        role_family,
        " / ".join(context_value("parent_label")),
        " / ".join(
            context_value("region_label")
            or context_value("container_label")
            or context_value("row_label")
        ),
        tuple(dict.fromkeys((*context_value("ancestor_labels"), *context_value("nearby_labels"))))[
            :6
        ],
        element.selected,
        element.checked,
        scope,
    )


def rebind_semantic_target(old_action, replacement_table):
    """Return one fresh candidate for the same semantic target, or refuse ambiguity."""
    identity = old_action.target_identity
    if identity is None:
        if old_action.operation in {Operation.SCROLL_UP, Operation.SCROLL_DOWN}:
            safe = [
                candidate
                for candidate in replacement_table.actions.values()
                if candidate.operation == old_action.operation
                and candidate.element_id is None
                and candidate.target_identity is None
            ]
            return safe[0] if len(safe) == 1 else None
        return None
    candidates = [
        candidate
        for candidate in replacement_table.actions.values()
        if candidate.operation == old_action.operation and candidate.target_identity is not None
    ]
    exact = [candidate for candidate in candidates if candidate.target_identity == identity]
    if not exact:
        # Context and state can legitimately change as a page refreshes. Require
        # exact label, compatible role/scope, and enough retained context to make
        # this a unique local re-grounding.
        relaxed = []
        for candidate in candidates:
            fresh = candidate.target_identity
            if (
                fresh.canonical_label != identity.canonical_label
                or fresh.role_family != identity.role_family
                or fresh.semantic_scope.split(":")[0] != identity.semantic_scope.split(":")[0]
            ):
                continue
            old_context = {
                identity.parent_context,
                identity.region_context,
                *identity.nearby_context,
            } - {""}
            new_context = {fresh.parent_context, fresh.region_context, *fresh.nearby_context} - {""}
            if old_context and new_context and old_context.isdisjoint(new_context):
                continue
            relaxed.append(candidate)
        exact = relaxed
    if len(exact) > 1:
        old_authority = str(old_action.payload.get("authority", ""))
        same_authority = [
            candidate for candidate in exact if candidate.payload.get("authority") == old_authority
        ]
        if len(same_authority) == 1:
            return same_authority[0]
        return None
    return exact[0] if exact else None


def _position_bucket(frame_box, visual_frame):
    if visual_frame is None:
        return "unknown"
    bounds = visual_frame.window_bounds
    x = (frame_box["x"] + frame_box["w"] / 2 - bounds.x) / bounds.width
    y = (frame_box["y"] + frame_box["h"] / 2 - bounds.y) / bounds.height
    vertical = "upper" if y < 1 / 3 else "lower" if y > 2 / 3 else "middle"
    horizontal = "left" if x < 1 / 3 else "right" if x > 2 / 3 else "center"
    return f"{vertical}-{horizontal}"


def _semantic_candidate_score(element, goal_words, goal):
    """Deterministic intent hints improve ordering without inventing targets."""
    label_words = set(re.findall(r"\w+", element.label.casefold()))
    score = 10 * len(goal_words & label_words)
    folded = goal.casefold()
    wants_play = bool(re.search(r"\b(?:play|resume|start)\b", folded))
    wants_pause = bool(re.search(r"\bpause\b", folded))
    if wants_play:
        if label_words & {"play", "resume", "start"}:
            score += 80
        if label_words & {"pause", "stop"}:
            score -= 80
        if label_words & {"settings", "profile", "search", "close", "menu"}:
            score -= 30
    if wants_pause:
        if "pause" in label_words:
            score += 90
        if label_words & {"play", "resume", "start"}:
            score -= 80
    if re.search(r"\b(?:search|find|look\s+up)\b", folded) and label_words & {
        "search",
        "find",
        "address",
        "website",
    }:
        score += 50
    if re.search(r"\b(?:send|submit|apply)\b", folded) and label_words & {
        "send",
        "submit",
        "apply",
    }:
        score += 50
    if re.search(r"\b(?:mute|unmute|microphone|mic)\b", folded) and label_words & {
        "mute",
        "muted",
        "unmute",
        "microphone",
        "mic",
    }:
        score += 90 if "checkbox" in element.role.casefold() else 45
    # Keep deterministic layout order for equivalent labels.
    frame = element.native.get("frame", {})
    return score, -float(frame.get("y", 0)), -float(frame.get("x", 0))


def is_site_search_field(element):
    if element.role not in {"AXSearchField", "searchbox", *TYPE_ROLES}:
        return False
    if re.search(
        r"\b(?:address|location|website|url|smart search|search or enter)\b",
        element.label,
        re.IGNORECASE,
    ):
        return False
    return element.role in {"AXSearchField", "searchbox"} or bool(
        re.search(r"\bsearch\b", element.label, re.IGNORECASE)
    )


def _has_primary_media_context(element):
    values = []
    for key in (
        "parent_label",
        "ancestor_labels",
        "nearby_labels",
        "region_label",
        "container_label",
        "group_label",
        "row_label",
    ):
        value = element.native.get(key)
        if isinstance(value, str):
            values.append(value.casefold())
        elif isinstance(value, (list, tuple)):
            values.extend(str(item).casefold() for item in value)
    if element.native.get("is_primary_media_control") is True:
        return True
    return bool(
        re.search(
            r"\b(?:transport|media|playback|now playing|player|track controls)\b",
            " ".join(values),
        )
    )


def _visual_goal_match(label, target_words):
    return _visual_goal_target(label, target_words) is not None


def _activation_target_match(element, target_terms):
    observed = set(re.findall(r"\w+", element.label.casefold()))
    if target_terms & observed:
        return True
    if "selected" in target_terms and element.selected is True:
        return True
    opposites = {
        "mute": "unmute",
        "unmute": "mute",
        "play": "pause",
        "pause": "play",
        "enable": "disable",
        "disable": "enable",
        "open": "close",
        "close": "open",
        "start": "stop",
        "stop": "start",
        "check": "uncheck",
        "uncheck": "check",
    }
    if any(opposites.get(term) in observed for term in target_terms):
        return False
    return element.source in {"OCR", "VISUAL"} and _visual_goal_match(element.label, target_terms)


def _visual_goal_target(label, target_words):
    observed = re.findall(r"\w+", label.casefold())
    matches = sorted(
        (
            (SequenceMatcher(None, wanted, found).ratio(), wanted)
            for wanted in target_words
            for found in observed
            if len(wanted) > 2 and SequenceMatcher(None, wanted, found).ratio() >= 0.75
        ),
        key=lambda row: (-row[0], row[1]),
    )
    return matches[0][1] if matches else None
