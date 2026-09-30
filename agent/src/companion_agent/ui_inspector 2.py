"""Read-only semantic UI snapshots and spatial answers.

The inspector deliberately copies only descriptive facts from normalized CUA
observations.  Its controls have no CUA payload, element token, selector or
coordinate authority and are never passed to action execution.
"""

import math
import re
from dataclasses import dataclass

from .candidates import Element, Observation


@dataclass(frozen=True)
class ObservedControl:
    opaque_id: str
    label: str
    role: str
    value: str | None
    state: tuple[str, ...]
    semantic_type: str
    bounding_box: tuple[float, float, float, float] | None
    source: str
    confidence: float
    nearby_labels: tuple[str, ...] = ()


@dataclass(frozen=True)
class UIInspection:
    observation_id: str
    source_app: str
    source_window: str
    window_bounds: tuple[float, float, float, float] | None
    controls: tuple[ObservedControl, ...]
    perception_sources: tuple[str, ...]


@dataclass(frozen=True)
class ObservationAnswer:
    answer: str
    confidence: float
    source_app: str
    source_window: str
    evidence: tuple[str, ...]


def _box(mapping):
    if not isinstance(mapping, dict):
        return None
    try:
        values = tuple(float(mapping[key]) for key in ("x", "y", "w", "h"))
    except (KeyError, TypeError, ValueError):
        try:
            values = tuple(float(mapping[key]) for key in ("x", "y", "width", "height"))
        except (KeyError, TypeError, ValueError):
            return None
    if not all(math.isfinite(value) for value in values) or min(values[2:]) <= 0:
        return None
    return values


def _states(element: Element) -> tuple[str, ...]:
    values = []
    if element.enabled:
        values.append("enabled")
    else:
        values.append("disabled")
    for key, truthy, falsy in (
        ("checked", "checked", "unchecked"),
        ("selected", "selected", "unselected"),
        ("expanded", "expanded", "collapsed"),
    ):
        value = getattr(element, key)
        if isinstance(value, bool):
            values.append(truthy if value else falsy)
    pressed = element.native.get("pressed")
    if isinstance(pressed, bool):
        values.append("pressed" if pressed else "not_pressed")
    return tuple(values)


def _semantic_type(element: Element) -> str:
    role = element.role.casefold()
    if "checkbox" in role or "toggle" in role:
        return "toggle"
    if "radio" in role:
        return "choice"
    if "tab" in role:
        return "tab"
    if any(token in role for token in ("textfield", "textarea", "textbox", "searchbox")):
        return "text_input"
    if any(token in role for token in ("button", "link", "menuitem")):
        return "action_control"
    if "heading" in role or "statictext" in role:
        return "text"
    if "window" in role:
        return "window"
    return "ui_element"


class UIInspector:
    """Create a provider-neutral, bounded, non-executable UI description."""

    def inspect(self, observation: Observation, *, app: str, window: dict) -> UIInspection:
        bounds = _box(window.get("bounds", {}))
        preliminary = []
        for element in observation.elements[:500]:
            if not element.visible:
                continue
            label = " ".join((element.label or "").split())[:200]
            role = (element.role or "unknown")[:80]
            native = element.native
            sensitive = (
                "secure" in role.casefold()
                or str(native.get("type", native.get("input_type", ""))).casefold() == "password"
            )
            value = (
                None
                if sensitive or element.value is None
                else " ".join(element.value.split())[:240]
            )
            box = _box(native.get("frame", {}))
            preliminary.append(
                ObservedControl(
                    opaque_id=element.id,
                    label=label,
                    role=role,
                    value=value,
                    state=_states(element),
                    semantic_type=_semantic_type(element),
                    bounding_box=box,
                    source="+".join(element.sources or (element.source,)),
                    confidence=max(0.0, min(1.0, float(element.confidence))),
                )
            )
        output = []
        for control in preliminary:
            nearby = []
            if control.bounding_box and bounds:
                x, y, w, h = control.bounding_box
                cx, cy = x + w / 2, y + h / 2
                for other in preliminary:
                    if (
                        other.opaque_id == control.opaque_id
                        or not other.label
                        or not other.bounding_box
                    ):
                        continue
                    ox, oy, ow, oh = other.bounding_box
                    distance = math.hypot(
                        (cx - (ox + ow / 2)) / max(bounds[2], 1),
                        (cy - (oy + oh / 2)) / max(bounds[3], 1),
                    )
                    if distance <= 0.16:
                        nearby.append((distance, other.label))
            related = tuple(dict.fromkeys(label for _, label in sorted(nearby)[:3]))
            output.append(
                ObservedControl(
                    control.opaque_id,
                    control.label,
                    control.role,
                    control.value,
                    control.state,
                    control.semantic_type,
                    control.bounding_box,
                    control.source,
                    control.confidence,
                    related,
                )
            )
        sources = tuple(
            dict.fromkeys(source for item in output for source in item.source.split("+"))
        )
        return UIInspection(
            observation.snapshot_id,
            app[:120],
            str(window.get("title") or observation.title or "Current window")[:200],
            bounds,
            tuple(output),
            sources,
        )


_ALIASES = {
    "mute": {"mute", "muted", "microphone", "mic", "audio input"},
    "microphone": {"mute", "muted", "microphone", "mic", "audio input"},
    "mic": {"mute", "muted", "microphone", "mic", "audio input"},
    "settings": {"settings", "preferences", "configuration"},
    "search": {"search", "find", "search bar", "search field"},
    "camera": {"camera", "video", "webcam"},
    "deafen": {"deafen", "headphones", "audio output"},
}
_STOP = {
    "the",
    "a",
    "an",
    "is",
    "are",
    "do",
    "does",
    "i",
    "me",
    "my",
    "in",
    "of",
    "where",
    "which",
    "button",
    "control",
    "bar",
    "currently",
    "visible",
    "show",
    "tell",
    "please",
    "what",
    "tab",
    "options",
}


def _tokens(value: str) -> set[str]:
    return {token for token in re.findall(r"[\w]+", value.casefold()) if token not in _STOP}


def _expanded(tokens: set[str]) -> set[str]:
    result = set(tokens)
    for token in tuple(tokens):
        result.update(_ALIASES.get(token, ()))
    return result


def _score(query: str, control: ObservedControl) -> float:
    query_tokens = _expanded(_tokens(query))
    content = (
        f"{control.label} {control.role} {control.value or ''} {' '.join(control.nearby_labels)}"
    )
    control_tokens = _expanded(_tokens(content))
    if not query_tokens:
        return 0.0
    overlap = len(query_tokens & control_tokens) / len(query_tokens)
    label_tokens = _expanded(_tokens(control.label))
    label_overlap = len(query_tokens & label_tokens) / len(query_tokens)
    role_bonus = 0.08 if control.semantic_type == "action_control" else 0.0
    return min(1.0, 0.55 * overlap + 0.37 * label_overlap + role_bonus)


class SpatialReasoner:
    def location(self, control: ObservedControl, window_bounds) -> str | None:
        if not control.bounding_box or not window_bounds:
            return None
        x, y, width, height = control.bounding_box
        wx, wy, ww, wh = window_bounds
        if ww <= 0 or wh <= 0:
            return None
        cx = (x + width / 2 - wx) / ww
        cy = (y + height / 2 - wy) / wh
        horizontal = "left" if cx < 1 / 3 else "right" if cx > 2 / 3 else "centre"
        vertical = "top" if cy < 1 / 3 else "bottom" if cy > 2 / 3 else "middle"
        if vertical == "middle":
            return horizontal if horizontal != "centre" else "centre"
        if horizontal == "centre":
            return vertical
        return f"{vertical}-{horizontal}"

    def relation(self, control: ObservedControl) -> str:
        if control.nearby_labels:
            return "beside " + " and ".join(control.nearby_labels[:2])
        return ""


class UIQuestionAnswerer:
    """Generate concise answers only from an inspected read-only snapshot."""

    def __init__(self, spatial: SpatialReasoner | None = None):
        self.spatial = spatial or SpatialReasoner()

    def answer(self, question: str, inspection: UIInspection) -> ObservationAnswer | None:
        folded = question.casefold()
        controls = inspection.controls
        if not controls:
            return None
        if re.search(r"\bwhat options (?:are )?visible\b", folded):
            labels = [
                item.label
                for item in controls
                if item.label and item.semantic_type == "action_control"
            ]
            if not labels:
                return None
            text = "Visible controls include " + ", ".join(dict.fromkeys(labels[:8])) + "."
            return self._result(text, inspection, 0.75, tuple(labels[:8]))
        if re.search(
            r"\bwhat (?:does|is) (?:this|the) .*(?:say|mean)\b|\bread (?:this|the)", folded
        ):
            content = [
                item.label
                for item in controls
                if item.label
                and item.semantic_type == "text"
                and item.role.casefold() not in {"axwindow"}
            ]
            content = list(dict.fromkeys(content))[:4]
            if content:
                return self._result(
                    "The visible text says: " + " ".join(content), inspection, 0.72, tuple(content)
                )
        if re.search(
            r"\bwhat tab (?:am i (?:currently )?on|is (?:this|currently selected))\b", folded
        ):
            tabs = [
                item
                for item in controls
                if item.semantic_type == "tab" and "selected" in item.state
            ]
            if len(tabs) == 1:
                return self._result(
                    f"The selected tab is {tabs[0].label}.",
                    inspection,
                    0.92,
                    (f"selected_tab={tabs[0].label}",),
                )
            return None
        query = self._subject(question)
        ranked = sorted(
            ((_score(query, item), item) for item in controls if item.label),
            key=lambda pair: pair[0],
            reverse=True,
        )
        if not ranked or ranked[0][0] < 0.42:
            return None
        confidence, control = ranked[0]
        if (
            len(ranked) > 1
            and ranked[1][0] >= confidence - 0.08
            and ranked[1][1].label != control.label
        ):
            return None
        if re.search(
            r"\b(?:am i|is .*? (?:on|off|enabled|disabled|checked|muted|selected)|are .*? enabled)\b",
            folded,
        ):
            state = self._state_for(question, control)
            if state is None:
                return self._result(
                    f"I can see {control.label}, but its current state isn't exposed clearly in this window.",
                    inspection,
                    min(confidence, 0.55),
                    (f"control={control.label}", "state=unknown"),
                )
            return self._result(
                f"{control.label} is {state}.",
                inspection,
                confidence,
                (f"control={control.label}", f"state={state}"),
            )
        location = self.spatial.location(control, inspection.window_bounds)
        relation = self.spatial.relation(control)
        if location:
            where = f"at the {location} of"
        else:
            where = "in"
        suffix = f", {relation}" if relation else ""
        answer = (
            f"The {control.label} control is {where} the {inspection.source_window} window{suffix}."
        )
        evidence = (
            f"control={control.label}",
            f"role={control.role}",
            *(f"nearby={label}" for label in control.nearby_labels[:2]),
        )
        return self._result(answer, inspection, confidence, evidence)

    @staticmethod
    def _subject(question: str) -> str:
        patterns = (
            r"\bwhich\s+(?:button|control)\s+(?:opens?|shows?|changes?|turns?|disables?)\s+(.+?)[?.!]*$",
            r"\bwhere(?:'s| is| are)\s+(?:the\s+)?(.+?)(?:\s+in\s+.+)?[?.!]*$",
            r"\bwhich\s+(?:button|control|tab|option)\s+(.+?)[?.!]*$",
            r"\b(?:am i|is (?:the|this|my)|are (?:the|these))\s+(.+?)[?.!]*$",
            r"\bwhat (?:does|is)\s+(?:this|the)\s+(.+?)[?.!]*$",
            r"\bwhere do i\s+(.+?)[?.!]*$",
        )
        for pattern in patterns:
            match = re.search(pattern, question, re.IGNORECASE)
            if match:
                subject = re.sub(r"\s+in\s+.+$", "", match[1], flags=re.IGNORECASE).strip(" ?.,")
                return UIQuestionAnswerer._canonical_concept(subject)
        return UIQuestionAnswerer._canonical_concept(question)

    @staticmethod
    def _canonical_concept(subject: str) -> str:
        folded = subject.casefold()
        concepts = (
            (r"\b(?:mute|muted|unmute|microphone|mic|audio input)\b", "microphone"),
            (r"\b(?:camera|webcam|video)\b", "camera"),
            (r"\b(?:settings|preferences|configuration)\b", "settings"),
            (r"\b(?:search|find)\b", "search"),
            (r"\b(?:deafen|headphones|audio output)\b", "deafen"),
        )
        for pattern, concept in concepts:
            if re.search(pattern, folded):
                return concept
        return subject

    @staticmethod
    def _state_for(question: str, control: ObservedControl) -> str | None:
        label = control.label.casefold()
        value = (control.value or "").casefold()
        if any(
            token in value
            for token in ("muted", "enabled", "disabled", "on", "off", "checked", "unchecked")
        ):
            for state in (
                "muted",
                "unmuted",
                "enabled",
                "disabled",
                "on",
                "off",
                "checked",
                "unchecked",
            ):
                if state in value:
                    return state
        desired = "muted" if re.search(r"\bmuted\b", question, re.IGNORECASE) else None
        if desired and re.search(r"\bunmute\b", label):
            return "muted"
        if desired and "checked" in control.state:
            return "muted"
        if desired and "unchecked" in control.state and "mute" in label:
            return "unmuted"
        for state in (
            "checked",
            "unchecked",
            "enabled",
            "disabled",
            "selected",
            "unselected",
            "on",
            "off",
            "playing",
            "paused",
        ):
            if re.search(rf"\b{re.escape(state)}\b", label):
                return state
        return None

    @staticmethod
    def _result(answer, inspection, confidence, evidence):
        return ObservationAnswer(
            answer[:500],
            max(0.0, min(1.0, confidence)),
            inspection.source_app,
            inspection.source_window,
            tuple(str(item)[:200] for item in evidence[:8]),
        )
