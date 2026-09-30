"""Small deterministic goal compiler for conversational Kio commands.

This module only normalizes user language and creates a bounded task plan.  It
does not choose controls, construct selectors or grant computer-use authority.
"""

import re
from dataclasses import dataclass
from enum import StrEnum


class IntentKind(StrEnum):
    ENSURE_APP = "ENSURE_APP"
    ACTIVATE_APP = "ACTIVATE_APP"
    OPEN_URL = "OPEN_URL"
    WEB_SEARCH = "WEB_SEARCH"
    PLAY = "PLAY"
    NEW_TAB = "NEW_TAB"
    CONTINUE_UI_GOAL = "CONTINUE_UI_GOAL"
    STOP = "STOP"


@dataclass(frozen=True)
class GoalStep:
    kind: IntentKind
    goal: str = ""
    application: str = ""
    semantic_step: object | None = None


@dataclass(frozen=True)
class TaskPlan:
    original: str
    normalized: str
    steps: tuple[GoalStep, ...]
    semantic_plan: object | None = None


_WAKE = re.compile(r"^(?:hey|okay|ok|hi)\s+kio(?:[,:;.!?]\s*|\s+)", re.IGNORECASE)
_FILLER_PREFIX = re.compile(
    r"^(?:(?:and\s*[,;:]?\s*)?(?:once\s+you['’]re\s+there\b[,;:]?\s*)|"
    r"(?:alright|okay|ok|now|then)\b[,;:]?\s*)",
    re.IGNORECASE,
)
_POLITE_PREFIX = re.compile(
    r"^(?:please\s+|can\s+you\s+|could\s+you\s+|would\s+you\s+|will\s+you\s+|i\s+want\s+you\s+to\s+)+",
    re.IGNORECASE,
)
_POLITE_SUFFIX = re.compile(r"(?:\s+please|\s+for\s+me)[.!?]*$", re.IGNORECASE)
_PRAISE_PREFIX = re.compile(r"^(?:(?:great|nice|awesome|cool)\b[,;.!]?\s*)+", re.IGNORECASE)
_MOVE_ON_PREFIX = re.compile(
    r"^(?:let['’]s\s+move\s+on|move\s+on)(?:\s+and)?\s*[,;:.!?]?\s*", re.IGNORECASE
)
_AND_POLITE_PREFIX = re.compile(
    r"^and\s+(?=(?:then\s+)?(?:can\s+you|could\s+you|would\s+you|will\s+you|inside\b|in\b|let['’]s\b|let\s+us\b|open\b|go\b|take\b|create\b|search\b))",
    re.IGNORECASE,
)
_LETS_PREFIX = re.compile(
    r"^(?:let['’]s|let\s+us)\s+(?=(?:open|go|bring|show|launch|search|click|press|type|enter|choose|select|write|create|make|take|capture|play|pause|resume|mute|rename|copy|start)\b)",
    re.IGNORECASE,
)
_ACTION_START = re.compile(
    r"(?:open|go\s+to|bring|show|launch|perform|calculate|play|pause|search|click|press|type|enter|choose|select|reach|write|create|draft|send|rename|copy|start|new)\b",
    re.IGNORECASE,
)


def _split_compound(text: str) -> list[str]:
    """Split only before a second action clause, outside quoted literals."""
    separators = re.compile(r"\s+(?:and\s+then|then|and)\s+(?=[a-z])", re.IGNORECASE)
    parts = []
    start = 0
    quote = None
    index = 0
    while index < len(text):
        char = text[index]
        if char in '"“”':
            quote = None if quote else char
        if quote is None:
            match = separators.match(text, index)
            if match:
                tail = text[match.end() :]
                if _ACTION_START.match(tail):
                    parts.append(text[start:index].strip())
                    start = match.end()
                    index = match.end()
                    continue
        index += 1
    parts.append(text[start:].strip())
    return [part for part in parts if part]


def normalize_spoken_goal(goal: str) -> str:
    if not isinstance(goal, str):
        return ""
    text = " ".join(goal.strip().split())
    while True:
        updated = _PRAISE_PREFIX.sub("", text, count=1)
        updated = _MOVE_ON_PREFIX.sub("", updated, count=1)
        updated = _AND_POLITE_PREFIX.sub("", updated, count=1)
        updated = _WAKE.sub("", updated, count=1)
        updated = _FILLER_PREFIX.sub("", updated, count=1)
        updated = _POLITE_PREFIX.sub("", updated, count=1)
        updated = _LETS_PREFIX.sub("", updated, count=1)
        if updated == text:
            break
        text = updated.strip()
    text = _POLITE_SUFFIX.sub("", text).strip()
    text = text.rstrip(".!?").strip()
    text = re.sub(r"\bopen\s+up\b", "open", text, flags=re.IGNORECASE)
    return _spoken_domain(text)


def _spoken_domain(text: str) -> str:
    """Normalize spoken domain punctuation only in a clear web-destination form."""
    domain_words = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    spoken = re.compile(
        rf"\b(?P<host>{domain_words}(?:\s+dot\s+{domain_words})*)"
        rf"\s+dot\s+(?P<tld>[A-Za-z]{{2,63}})"
        rf"(?P<path>\s+slash\s+[A-Za-z0-9._~!$&'()*+,;=:@%/-]+)?\b",
        re.IGNORECASE,
    )
    cue = bool(
        re.match(
            r"^(?:(?:open|go\s+to|visit)\s+(?:up\s+)?|(?:website|domain|url)\s*(?:is|:)?\s*)",
            text,
            re.IGNORECASE,
        )
    )
    exact_domain = bool(
        re.fullmatch(
            rf"{domain_words}(?:\s+dot\s+{domain_words})*\s+dot\s+"
            rf"(?:com|org|net|edu|gov|mil|int|io|ai|app|dev|co|uk|ca|au|nz|ie|de|fr|jp|me|tv|info|biz|xyz)(?:\s+slash\s+.+)?",
            text,
            re.IGNORECASE,
        )
    )
    if not cue and not exact_domain:
        return text

    def replace(match):
        host = re.sub(r"\s+dot\s+", ".", match.group("host"), flags=re.IGNORECASE)
        path = match.group("path") or ""
        path = re.sub(r"^\s+slash\s+", "/", path, flags=re.IGNORECASE)
        return f"{host}.{match.group('tld')}{path}"

    return spoken.sub(replace, text)


def _app_open_clause(clause: str) -> str | None:
    match = re.fullmatch(
        r"(?:open|launch|start|bring|show)\s+(?:up\s+)?(?:the\s+)?(.+?)(?:\s+up)?[.!?]*",
        clause,
        re.IGNORECASE,
    )
    if not match:
        return None
    value = match[1].strip()
    value = re.sub(r"\s+up$", "", value, flags=re.IGNORECASE).strip()
    value = re.sub(r"\s+app$", "", value, flags=re.IGNORECASE).strip()
    if not value or len(value) > 120 or any(ord(char) < 32 for char in value):
        return None
    return value


def _compile_clause(clause: str) -> GoalStep:
    folded = clause.casefold()
    if folded in {"stop", "cancel", "stop kio"}:
        return GoalStep(IntentKind.STOP, goal=clause)
    # NEW_TAB must precede the generic "open <app>" grammar.  Otherwise
    # "open a new tab" is incorrectly treated as an application name.
    if re.match(r"^(?:new\s+tab|open\s+(?:a\s+)?new\s+tab)\b", clause, re.IGNORECASE):
        return GoalStep(IntentKind.NEW_TAB, goal=clause)
    app = _app_open_clause(clause)
    if app:
        return GoalStep(IntentKind.ENSURE_APP, application=app, goal=clause)
    if re.match(r"^(?:search|look\s+up)\b", clause, re.IGNORECASE):
        return GoalStep(IntentKind.WEB_SEARCH, goal=clause)
    if re.match(r"^(?:play|resume|start)\b", clause, re.IGNORECASE):
        return GoalStep(IntentKind.PLAY, goal=clause)
    return GoalStep(IntentKind.CONTINUE_UI_GOAL, goal=clause)


class GoalCompiler:
    """Compile natural wrappers into at most one app prelude and one UI goal."""

    def compile(self, goal: str, apps=()) -> TaskPlan:
        normalized = normalize_spoken_goal(goal)
        if not normalized:
            return TaskPlan(goal if isinstance(goal, str) else "", "", ())
        clauses = _split_compound(normalized)
        steps: list[GoalStep] = []
        for clause in clauses:
            step = _compile_clause(clause)
            if step.kind == IntentKind.ENSURE_APP and len(clauses) > 1:
                steps.append(step)
                continue
            steps.append(step)
        if len(steps) == 1 and steps[0].kind == IntentKind.PLAY:
            match = re.fullmatch(r"(.+?)\s+on\s+(.+)", steps[0].goal, re.IGNORECASE)
            if match:
                steps = [
                    GoalStep(
                        IntentKind.ENSURE_APP,
                        goal=f"open {match[2].strip()}",
                        application=match[2].strip(),
                    ),
                    GoalStep(IntentKind.PLAY, goal=match[1].strip()),
                ]
        # Resolve only a supplied installed-app inventory.  The compiler never
        # invents an application and leaves ambiguous names unchanged for the
        # runtime to reject safely.
        if apps:
            from .direct import resolve_app

            resolved = []
            for step in steps:
                if step.kind == IntentKind.ENSURE_APP:
                    app = resolve_app(step.application, list(apps))
                    if app:
                        resolved.append(
                            GoalStep(step.kind, step.goal, str(app.get("name", step.application)))
                        )
                        continue
                resolved.append(step)
            steps = resolved
        return TaskPlan(goal if isinstance(goal, str) else "", normalized, tuple(steps))
