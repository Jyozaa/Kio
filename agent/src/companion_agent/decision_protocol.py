"""Versioned, bounded inputs for Kio-owned typed decisions."""

import json
import re
from dataclasses import asdict, dataclass
from enum import StrEnum

from .candidates import CandidateTable, Element, Operation
from .policy import SECRETS

STATE_SCHEMA = "KioDecisionStateV1"
CANDIDATE_SCHEMA = "KioCandidateFormatV1"
TRAINING_SCHEMA = "kio-decision-v1"


class DecisionFamily(StrEnum):
    NEXT_OPERATION = "NEXT_OPERATION"
    TARGET = "TARGET"
    GOAL_STATE = "GOAL_STATE"
    RECOVERY = "RECOVERY"


class SemanticOperation(StrEnum):
    OPEN_APP = "OPEN_APP"
    FOCUS_APP = "FOCUS_APP"
    CREATE = "CREATE"
    ACTIVATE = "ACTIVATE"
    SET_STATE = "SET_STATE"
    SET_FIELD = "SET_FIELD"
    TYPE_TEXT = "TYPE_TEXT"
    SEARCH = "SEARCH"
    NAVIGATE = "NAVIGATE"
    SELECT = "SELECT"
    CAPTURE = "CAPTURE"
    WAIT = "WAIT"
    READ = "READ"
    FIND = "FIND"
    CLOSE = "CLOSE"
    DONE = "DONE"
    REOBSERVE = "REOBSERVE"
    REPLAN = "REPLAN"
    NEEDS_USER = "NEEDS_USER"
    BLOCKED = "BLOCKED"


class GoalState(StrEnum):
    SATISFIED = "SATISFIED"
    NOT_SATISFIED = "NOT_SATISFIED"
    UNCERTAIN = "UNCERTAIN"


class RecoveryAction(StrEnum):
    WAIT_FOR_TRANSITION = "WAIT_FOR_TRANSITION"
    REOBSERVE = "REOBSERVE"
    NEEDS_USER = "NEEDS_USER"


_EMAIL = re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE)
_TOKEN = re.compile(r"\b(?:sk-[\w-]{12,}|gh[pousr]_[\w]{12,}|AIza[\w-]{20,})\b")
_PHONE = re.compile(r"(?<!\w)(?:\+?\d[\d ().-]{7,}\d)(?!\w)")


def safe_text(value, limit=240):
    """Keep useful short semantics while removing common secrets and contact data."""
    if value is None:
        return ""
    text = str(value)
    if SECRETS.search(text):
        return "[sensitive request omitted]"
    text = _TOKEN.sub("[secret]", text)
    text = _EMAIL.sub("[email]", text)
    text = _PHONE.sub("[number]", text)
    return text[:limit]


@dataclass(frozen=True)
class KioDecisionStateV1:
    task: dict
    application: dict
    conversation: dict
    ui_state: dict
    history: tuple[str, ...]
    schema: str = STATE_SCHEMA

    def render(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=False, separators=(",", ":"))

    @classmethod
    def from_observation(
        cls,
        goal,
        table: CandidateTable | None,
        history=(),
        guidance="",
        semantic_step=None,
        observation=None,
    ):
        obs = table.observation if table is not None else observation
        if obs is None:
            raise ValueError("decision_state_requires_observation")
        step_operation = getattr(getattr(semantic_step, "operation", None), "value", "")
        object_type = getattr(getattr(semantic_step, "object_type", None), "value", "")
        parameters = getattr(semantic_step, "parameters", {}) or {}
        modal = any(e.native.get("in_system_dialog") is True for e in obs.elements)
        editable = any(
            e.visible and e.enabled and e.role in {"AXTextField", "AXTextArea", "AXSearchField"}
            for e in obs.elements
        )
        selected = [
            safe_text(e.label, 80) for e in obs.elements if e.visible and e.selected is True
        ]
        goal_terms = {
            word.casefold()
            for word in re.findall(
                r"[\w-]+", f"{goal} {getattr(semantic_step, 'object_label', '')}"
            )
            if len(word) > 2
        }
        status_terms = {"success", "complete", "completed", "saved", "ready", "sent", "done"}
        summary = []
        for element in obs.elements:
            if not element.visible or element.role not in {"AXHeading", "AXStaticText"}:
                continue
            label = safe_text(element.label, 80)
            words = {word.casefold() for word in re.findall(r"[\w-]+", label)}
            if words & goal_terms or words & status_terms:
                summary.append(label)
            if len(summary) == 3:
                break
        app_name = str(getattr(semantic_step, "application_hint", "") or "")
        values = {
            str(key)[:24]: safe_text(value, 100)
            for key, value in list(parameters.items())[:5]
            if key in {"field", "query", "url", "name", "destination"}
        }
        return cls(
            task={
                "goal": safe_text(goal, 400),
                "subgoal": safe_text(
                    getattr(semantic_step, "object_label", "") or step_operation, 120
                ),
                "step_index": min(max(int(getattr(semantic_step, "step_index", 0) or 0), 0), 999),
                "operation": safe_text(step_operation, 32),
                "object_type": safe_text(object_type, 32),
                "parameters": values,
                "guidance": safe_text(guidance, 160),
            },
            application={
                "name": safe_text(app_name, 80),
                "window_title": safe_text(obs.title, 120),
                "surface_kind": "browser"
                if any(e.native.get("in_web_content") for e in obs.elements)
                else "native",
            },
            conversation={
                "current_referent": safe_text(getattr(semantic_step, "object_label", ""), 80),
                "recent_verified_steps": [safe_text(item, 100) for item in history[-3:]],
            },
            ui_state={
                "modal_present": modal,
                "editable_control_available": editable,
                "selected_object_count": len(selected),
                "goal_relevant_text": summary,
                "candidate_count": len(table.actions) if table is not None else 0,
            },
            history=tuple(safe_text(item, 120) for item in history[-4:]),
        )


@dataclass(frozen=True)
class KioCandidateFormatV1:
    """Model-visible options; execution identities remain in a separate private map."""

    options: dict[str, str]
    schema: str = CANDIDATE_SCHEMA

    def __post_init__(self):
        if (
            not isinstance(self.options, dict)
            or self.schema != CANDIDATE_SCHEMA
            or any(
                not isinstance(key, str)
                or not re.fullmatch(r"c_\d+", key)
                or not isinstance(value, str)
                or len(value) > 240
                for key, value in self.options.items()
            )
        ):
            raise ValueError("invalid_candidate_format")


def render_candidate_options(table: CandidateTable, operation: Operation):
    """Return opaque per-request IDs and compact descriptions; never expose authority."""
    elements = {element.id: element for element in table.observation.elements}
    candidates = [
        candidate for candidate in table.actions.values() if candidate.operation == operation
    ]
    options = {}
    reverse = {}
    for index, candidate in enumerate(candidates):
        option_id = f"c_{index}"
        element = elements.get(candidate.element_id)
        description = _candidate_description(element, candidate.description)
        options[option_id] = description
        reverse[option_id] = candidate.id
    return KioCandidateFormatV1(options).options, reverse


def _candidate_description(element: Element | None, fallback: str) -> str:
    if element is None:
        return safe_text(fallback, 180)
    label = safe_text(element.label, 100) or "unnamed control"
    roles = {
        "AXButton": "button",
        "AXCheckBox": "checkbox",
        "AXRadioButton": "radio button",
        "AXLink": "link",
        "AXMenuItem": "menu item",
        "AXTab": "tab",
        "AXTextField": "text field",
        "AXTextArea": "text area",
        "AXSearchField": "search field",
        "AXPopUpButton": "dropdown",
        "AXComboBox": "combo box",
    }
    role = roles.get(element.role, safe_text(element.role, 32) or "control")
    native = element.native
    context = []
    for key, context_label in (
        ("parent_label", "parent"),
        ("region_label", "region"),
        ("container_label", "container"),
        ("row_label", "row"),
    ):
        value = native.get(key)
        if isinstance(value, str) and value.strip():
            context.append(f"{context_label}: {safe_text(value, 50)}")
    nearby = native.get("nearby_labels")
    if isinstance(nearby, (list, tuple)) and nearby:
        context.append("nearby: " + ", ".join(safe_text(value, 32) for value in nearby[:3]))
    if native.get("in_system_dialog") is True:
        surface = "system dialog"
    elif native.get("in_web_content") is True or native.get("structured_browser") is True:
        surface = "browser page"
    elif element.source in {"VISUAL", "OCR"}:
        surface = "visible page text"
    else:
        surface = "native interface"
    state = ""
    if element.checked is not None:
        state = "; " + ("checked" if element.checked else "unchecked")
    elif element.selected is not None:
        state = "; " + ("selected" if element.selected else "not selected")
    suffix = " | " + " | ".join([surface, *context]) if context else f" | {surface}"
    return f"{label} | {role}{state}{suffix}"[:240]


def training_row(
    family,
    state,
    question,
    expected,
    *,
    task_group,
    trajectory_id=None,
    step_index=0,
    app_family="unknown",
    provenance="fixture",
):
    """Validate and build the versioned, upstream-compatible training row."""
    if family not in {value.value for value in DecisionFamily}:
        raise ValueError("invalid_decision_family")
    if not task_group or not isinstance(question, dict) or question.get("type") != "choice":
        raise ValueError("invalid_training_row")
    criteria = question.get("criteria")
    if not isinstance(criteria, dict) or not criteria or expected not in criteria:
        raise ValueError("invalid_training_label")
    return {
        "schema_version": TRAINING_SCHEMA,
        "decision_state_schema": STATE_SCHEMA,
        "candidate_format_schema": CANDIDATE_SCHEMA,
        "decision_family": family,
        "state": state,
        "questions": {family: question},
        "expected": {family: expected},
        "task_group": task_group,
        "app_family": app_family,
        "trajectory_id": trajectory_id or task_group,
        "step_index": step_index,
        "provenance": provenance,
        "split_group": task_group,
    }
