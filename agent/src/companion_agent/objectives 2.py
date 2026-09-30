"""Deterministic progress facts for explicitly ordered user instructions."""

import re
from dataclasses import dataclass, field
from enum import StrEnum

from .policy import literal_text


class EffectClass(StrEnum):
    READ_ONLY = "READ_ONLY"
    EDGE_TRIGGERED_ONCE = "EDGE_TRIGGERED_ONCE"
    # Kept as an enum alias for callers that used the shorter earlier name.
    EDGE_TRIGGERED = "EDGE_TRIGGERED_ONCE"
    STATE_TRANSITION = "STATE_TRANSITION"
    CONTENT_WRITE = "CONTENT_WRITE"
    OBJECT_CREATE = "OBJECT_CREATE"
    NAVIGATION = "NAVIGATION"
    EXTERNAL_COMMIT = "EXTERNAL_COMMIT"
    DESTRUCTIVE = "DESTRUCTIVE"


@dataclass
class EffectLedger:
    """Task-local record of attempted effects, including outcomes that timed out."""

    attempts: dict[tuple[str, str], int] = field(default_factory=dict)
    outcomes: dict[tuple[str, str], str] = field(default_factory=dict)

    def claim(self, step_id: str, effect: EffectClass, *, maximum: int = 1) -> bool:
        key = (step_id or "task", effect.value)
        count = self.attempts.get(key, 0)
        if count >= maximum:
            return False
        self.attempts[key] = count + 1
        self.outcomes[key] = "dispatched_or_uncertain"
        return True

    def finish(self, step_id: str, effect: EffectClass, outcome: str) -> None:
        self.outcomes[(step_id or "task", effect.value)] = outcome

    def release_not_dispatched(self, step_id: str, effect: EffectClass) -> None:
        """Release a claim only when the driver proved it rejected the stale target."""
        key = (step_id or "task", effect.value)
        if self.outcomes.get(key) == "dispatched_or_uncertain":
            self.attempts.pop(key, None)
            self.outcomes.pop(key, None)

    def attempted(self, step_id: str, effect: EffectClass) -> bool:
        return self.attempts.get((step_id or "task", effect.value), 0) > 0


def clauses(goal: str) -> list[str]:
    # Split only explicit sequencing outside quoted literal text.
    quote = None
    protected = set()
    for index, char in enumerate(goal):
        if char in '"“”':
            quote = None if quote else char
            protected.add(index)
        elif quote:
            protected.add(index)
    parts = []
    start = 0
    pattern = r",\s*(?:then\s+)?(?=(?:enter|type|choose|select|click|reach)\b)|\s+then\s+"
    for match in re.finditer(pattern, goal, re.IGNORECASE):
        if any(i in protected for i in range(match.start(), match.end())):
            continue
        parts.append(goal[start : match.start()].strip())
        start = match.end()
    parts.append(goal[start:].strip())
    return [part for part in parts if part]


def current_objective(goal: str, observation, history=()) -> str:
    parts = clauses(goal)
    for part in parts:
        click = re.fullmatch(
            r"(?:click|press)\s+(?:the\s+)?(.+?)(?:\s+button)?", part, re.IGNORECASE
        )
        if click:
            label = click[1].casefold().strip()
            acted = any(h.casefold().startswith("click: " + label + " (") for h in history)
            still_actionable = any(
                e.visible and e.enabled and e.label.casefold().strip() == label
                for e in observation.elements
            )
            if acted and not still_actionable:
                continue
        literal = literal_text(part)
        if literal is not None:
            fields = [
                e
                for e in observation.elements
                if e.visible and e.role in {"AXTextField", "AXTextArea", "textbox"}
            ]
            mentioned = [e for e in fields if e.label and e.label.casefold() in part.casefold()]
            matched = mentioned if mentioned else fields if len(fields) == 1 else []
            if len(matched) == 1 and matched[0].value == literal:
                continue
        option = re.search(r"\b(?:choose|select)\s+option\s+([\w-]+)", part, re.IGNORECASE)
        if option:
            selects = [
                e
                for e in observation.elements
                if e.visible and e.role in {"AXPopUpButton", "AXComboBox", "combobox", "listbox"}
            ]
            if len(selects) == 1 and (selects[0].value or "").casefold() in {
                option[1].casefold(),
                "option " + option[1].casefold(),
            }:
                continue
        return part
    return goal
