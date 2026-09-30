"""Deterministic action policy. Model guidance cannot override a local block."""

import re
from dataclasses import dataclass
from enum import StrEnum

from .candidates import CandidateAction, Operation, is_actionable_geometry


class Disposition(StrEnum):
    ALLOW = "ALLOW"
    BLOCK = "BLOCK"


@dataclass(frozen=True)
class PolicyResult:
    disposition: Disposition
    reason: str


@dataclass(frozen=True)
class PolicyContext:
    goal: str
    action: CandidateAction
    observation: object = None
    app: str = ""
    url: str = ""
    history: tuple = ()
    semantic_constraints: tuple[str, ...] = ()


SECRETS = re.compile(
    r"\b(password|passcode|2fa|one.time.code|recovery.code|credit.card|card.number|cvv|api.key|api.token|authentication.token|auth.token|private.key|private.cryptographic|secret|credential)\b",
    re.IGNORECASE,
)
FINANCIAL = re.compile(
    r"\b(buy(?: now)?|purchase|pay(?: now)?|place order|confirm order|complete checkout|transfer money|withdraw|deposit)\b",
    re.IGNORECASE,
)
# An external side effect needs explicit task scope, not another approval.
SCOPED_ACTIONS = (
    (r"send|reply|forward", r"send|reply|forward"),
    (r"submit", r"submit|send|apply|create.*(?:issue|task|event)|file.*(?:issue|report)"),
    (r"publish|post", r"publish|post"),
    (r"delete|erase|remove|empty trash", r"delete|erase|remove|empty trash"),
    (r"upload|attach", r"upload|attach"),
)


class ActionPolicy:
    def evaluate(self, context: PolicyContext):
        action = context.action
        if action.operation in {
            Operation.WAIT,
            Operation.REOBSERVE,
            Operation.DONE,
            Operation.BLOCKED,
        }:
            return PolicyResult(Disposition.ALLOW, "Non-executing decision.")
        element = (
            next((e for e in context.observation.elements if e.id == action.element_id), None)
            if context.observation
            else None
        )
        label = element.label if element else action.description.split(" (")[0]
        role = element.role if element else action.payload.get("role", "")
        native = element.native if element else {}
        field_type = str(native.get("type", native.get("input_type", "")))
        if action.operation == Operation.TYPE_TEXT and (
            "secure" in role.casefold()
            or field_type.casefold() == "password"
            or SECRETS.search(label)
            or SECRETS.search(context.goal)
        ):
            return PolicyResult(Disposition.BLOCK, "Sensitive text must be entered manually.")
        if native.get("security_sensitive") is True:
            return PolicyResult(
                Disposition.BLOCK, "Security-sensitive action requires manual completion."
            )
        if "do_not_send" in context.semantic_constraints and re.search(
            r"\b(?:send|submit|publish|post)\b", label, re.IGNORECASE
        ):
            return PolicyResult(
                Disposition.BLOCK,
                "This task requires keeping the draft unsent.",
            )
        if context.observation and element:
            indistinguishable = [
                e
                for e in context.observation.elements
                if e.enabled
                and e.visible
                and is_actionable_geometry(e)
                and e.role == element.role
                and e.label.casefold().strip() == label.casefold().strip()
            ]
            contextual_keys = []
            for candidate in indistinguishable:
                native = candidate.native
                context_values = []
                for key in (
                    "parent_label",
                    "ancestor_labels",
                    "region_label",
                    "container_label",
                    "row_label",
                    "nearby_labels",
                    "group_label",
                ):
                    value = native.get(key)
                    if isinstance(value, str) and value.strip():
                        context_values.append(value.strip().casefold())
                    elif isinstance(value, (list, tuple)):
                        context_values.extend(
                            str(item).strip().casefold() for item in value if str(item).strip()
                        )
                contextual_keys.append(tuple(dict.fromkeys(context_values)))
            contexts_distinguish = (
                len(indistinguishable) > 1
                and all(contextual_keys)
                and len(set(contextual_keys)) == len(contextual_keys)
            )
            if len(indistinguishable) > 1 and not contexts_distinguish:
                return PolicyResult(
                    Disposition.BLOCK, "Target is ambiguous; specify a unique control."
                )
        if action.operation == Operation.TYPE_TEXT:
            return PolicyResult(Disposition.ALLOW, "Ordinary text entry.")
        if action.operation in {Operation.SCROLL_UP, Operation.SCROLL_DOWN}:
            return PolicyResult(Disposition.ALLOW, "Viewport movement only.")
        # Navigation/product selection does not itself make a financial commitment.
        if role in {"AXLink", "link", "AXTab"} and re.fullmatch(
            r"checkout|drafts?|account|shop|products", label.strip(), re.IGNORECASE
        ):
            return PolicyResult(Disposition.ALLOW, "Navigation only.")
        if FINANCIAL.search(label) or native.get("financial_commitment") is True:
            return PolicyResult(
                Disposition.BLOCK, "Final financial commitment requires manual completion."
            )
        if label.casefold().strip() in {
            "confirm",
            "place order",
            "complete payment",
        } and FINANCIAL.search(context.goal):
            return PolicyResult(
                Disposition.BLOCK, "Final financial commitment requires manual completion."
            )
        for action_words, goal_words in SCOPED_ACTIONS:
            if re.search(r"\b(?:" + action_words + r")\b", label, re.IGNORECASE):
                if not re.search(r"\b(?:" + goal_words + r")\b", context.goal, re.IGNORECASE):
                    return PolicyResult(
                        Disposition.BLOCK, "External action is outside the active goal."
                    )
                if re.search(
                    r"\b(?:don't|do not|never)\s+(?:" + action_words + r")\b",
                    context.goal,
                    re.IGNORECASE,
                ):
                    return PolicyResult(Disposition.BLOCK, "The goal excludes this action.")
        return PolicyResult(Disposition.ALLOW, "Grounded action within the active goal.")


def literal_text(goal: str) -> str | None:
    match = re.search(r'(?:enter|type|fill|write)\s+["“]([^"”]*)["”]', goal, re.IGNORECASE)
    if match:
        return match[1]
    match = re.fullmatch(
        r"(?:enter|type)\s+(.+?)\s+(?:into|in)\s+(?:the\s+)?[\w ]+(?:field|textbox)",
        goal.strip(),
        re.IGNORECASE,
    )
    return match[1] if match else None
