"""Bounded request understanding and structured task plans.

The deterministic tier handles explicit, low-risk language and extracts exact
user literals.  Ambiguous intent can be classified by the already-loaded local
Laya chooser, but model output is restricted to project-owned enums and never
contains executable computer-use authority.
"""

import hashlib
import re
from dataclasses import dataclass, field, replace
from enum import StrEnum
from typing import Protocol

from .goal_compiler import normalize_spoken_goal


class RequestMode(StrEnum):
    ANSWER_ONLY = "ANSWER_ONLY"
    OBSERVE_AND_ANSWER = "OBSERVE_AND_ANSWER"
    ACT = "ACT"


class SemanticOperation(StrEnum):
    OPEN = "OPEN"
    CREATE = "CREATE"
    EDIT = "EDIT"
    FIND = "FIND"
    LOCATE = "LOCATE"
    DESCRIBE = "DESCRIBE"
    READ = "READ"
    SEARCH = "SEARCH"
    ACTIVATE_CONTROL_ONCE = "ACTIVATE_CONTROL_ONCE"
    NAVIGATE = "NAVIGATE"
    SET_STATE = "SET_STATE"
    SET_FIELD = "SET_FIELD"
    CAPTURE = "CAPTURE"
    TYPE = "TYPE"
    SELECT = "SELECT"
    COPY = "COPY"
    MOVE = "MOVE"
    RENAME = "RENAME"
    DELETE = "DELETE"
    SAVE = "SAVE"
    SEND = "SEND"
    ATTACH = "ATTACH"
    CALCULATE = "CALCULATE"
    NEW_TAB = "NEW_TAB"
    CLOSE = "CLOSE"
    CUSTOM = "CUSTOM"
    # Compatibility name used by the original bounded planner.
    CUSTOM_UI_GOAL = "CUSTOM"


class ObjectType(StrEnum):
    APP = "APP"
    CONTROL = "CONTROL"
    EMAIL = "EMAIL"
    EMAIL_DRAFT = "EMAIL_DRAFT"
    MESSAGE = "MESSAGE"
    DOCUMENT = "DOCUMENT"
    NOTE = "NOTE"
    FILE = "FILE"
    FOLDER = "FOLDER"
    MEDIA_PLAYBACK = "MEDIA_PLAYBACK"
    PHOTO = "PHOTO"
    SETTING = "SETTING"
    WEB_PAGE = "WEB_PAGE"
    TAB = "TAB"
    FORM = "FORM"
    FIELD = "FIELD"
    GENERIC_UI_OBJECT = "GENERIC_UI_OBJECT"
    GENERIC = "GENERIC_UI_OBJECT"


class DesiredState(StrEnum):
    OPEN = "OPEN"
    CLOSED = "CLOSED"
    ENABLED = "ENABLED"
    DISABLED = "DISABLED"
    PLAYING = "PLAYING"
    PAUSED = "PAUSED"
    MUTED = "MUTED"
    UNMUTED = "UNMUTED"
    CHECKED = "CHECKED"
    UNCHECKED = "UNCHECKED"
    DRAFT = "DRAFT"
    SENT = "SENT"


class LiteralKind(StrEnum):
    EMAIL = "EMAIL"
    URL = "URL"
    QUOTED = "QUOTED"
    PATH = "PATH"
    FILENAME = "FILENAME"
    NUMBER = "NUMBER"
    DATE = "DATE"
    TIME = "TIME"


@dataclass(frozen=True)
class SemanticLiteral:
    kind: LiteralKind
    value: str


@dataclass(frozen=True)
class SemanticStep:
    operation: SemanticOperation
    application_hint: str = ""
    object_type: ObjectType = ObjectType.GENERIC_UI_OBJECT
    object_label: str = ""
    parameters: dict[str, str] = field(default_factory=dict)
    desired_state: DesiredState | None = None
    constraints: tuple[str, ...] = ()
    completion_conditions: tuple[str, ...] = ()
    step_id: str = ""
    source_clause: str = ""

    def __post_init__(self):
        if not self.step_id:
            stable = "|".join(
                (
                    self.operation.value,
                    self.application_hint.casefold(),
                    self.object_type.value,
                    self.object_label.casefold(),
                    repr(sorted(self.parameters.items())),
                    self.desired_state.value if self.desired_state else "",
                    repr(self.constraints),
                    repr(self.completion_conditions),
                    self.source_clause.casefold(),
                )
            )
            object.__setattr__(
                self, "step_id", "s_" + hashlib.sha256(stable.encode()).hexdigest()[:16]
            )


@dataclass(frozen=True)
class SemanticTaskPlan:
    request_mode: RequestMode
    original_text: str
    normalized_text: str
    target_application: str
    steps: tuple[SemanticStep, ...]
    literals: tuple[SemanticLiteral, ...] = ()
    constraints: tuple[str, ...] = ()
    completion_conditions: tuple[str, ...] = ()
    confidence: float = 1.0
    interpretation_tier: str = "deterministic"
    unresolved: bool = False

    @property
    def original(self) -> str:
        """Compatibility with the original planner result fields."""
        return self.original_text

    @property
    def normalized(self) -> str:
        return self.normalized_text

    @property
    def needs_reasoning(self) -> bool:
        return self.unresolved


class BoundedSemanticReasoner(Protocol):
    def classify_semantic(
        self, text: str, field: str, choices: dict[str, str]
    ) -> tuple[str, float]: ...


_EMAIL = re.compile(r"(?<![\w.+-])([\w.+-]+@[\w.-]+\.[A-Za-z]{2,})(?![\w.-])")
_URL = re.compile(r"\bhttps?://[^\s\"'<>]+", re.IGNORECASE)
_QUOTED = re.compile(r'"([^"\n]{1,2000})"|“([^”\n]{1,2000})”')
_PATH = re.compile(r"(?<!\w)(?:~?/|\.\.?/)(?:[^\s\"']+/)*[^\s\"']+")
_FILENAME = re.compile(
    r"(?<![\w.-])([\w .()'-]+\.(?:pdf|txt|docx?|xlsx?|pptx?|rtf|csv|png|jpe?g|md))(?!\w)",
    re.IGNORECASE,
)


def extract_literals(text: str) -> tuple[SemanticLiteral, ...]:
    """Extract exact literals before normalization or semantic interpretation."""
    found: list[tuple[int, SemanticLiteral]] = []
    for pattern, kind, group in (
        (_EMAIL, LiteralKind.EMAIL, 1),
        (_URL, LiteralKind.URL, 0),
        (_QUOTED, LiteralKind.QUOTED, 0),
        (_PATH, LiteralKind.PATH, 0),
        (_FILENAME, LiteralKind.FILENAME, 1),
    ):
        for match in pattern.finditer(text):
            value = next((part for part in match.groups() if part is not None), match.group(0))
            if kind == LiteralKind.URL:
                value = value.rstrip(".,!?)")
            found.append((match.start(), SemanticLiteral(kind, value)))
    for match in re.finditer(
        r"\b(?:today|tomorrow|yesterday|\d{4}-\d{2}-\d{2})\b", text, re.IGNORECASE
    ):
        found.append((match.start(), SemanticLiteral(LiteralKind.DATE, match.group(0))))
    for match in re.finditer(r"\b\d{1,2}:\d{2}(?:\s*[ap]m)?\b", text, re.IGNORECASE):
        found.append((match.start(), SemanticLiteral(LiteralKind.TIME, match.group(0))))
    for match in re.finditer(r"(?<!\w)\d+(?:\.\d+)?(?!\w)", text):
        found.append((match.start(), SemanticLiteral(LiteralKind.NUMBER, match.group(0))))
    unique: dict[tuple[LiteralKind, str], tuple[int, SemanticLiteral]] = {}
    for position, item in found:
        unique.setdefault((item.kind, item.value), (position, item))
    return tuple(item for _, item in sorted(unique.values(), key=lambda value: value[0]))


def _normalize_preserving_quotes(text: str) -> str:
    quoted = []

    def hold(match):
        quoted.append(match.group(0))
        return f"__KIO_LITERAL_{len(quoted) - 1}__"

    protected = _QUOTED.sub(hold, text)
    normalized = normalize_spoken_goal(protected)
    for index, value in enumerate(quoted):
        normalized = normalized.replace(f"__KIO_LITERAL_{index}__", value)
    return normalized


def classify_request_mode(text: str) -> RequestMode:
    """High precision request mode: observations outrank action-like nouns."""
    normalized = _normalize_preserving_quotes(text)
    # Quoted content is data, not an instruction. This prevents a message body
    # such as "delete the account" from turning a read-only request into ACT.
    folded = _without_quoted(normalized).casefold().strip()
    if not folded:
        return RequestMode.ANSWER_ONLY
    if re.fullmatch(
        r"(?:https?://)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?:/[^\s]*)?",
        folded,
    ):
        return RequestMode.ACT
    if re.match(r"^(?:don't|do not|never)\s+(?:prevent|stop|keep|ensure)\b", folded):
        return RequestMode.ANSWER_ONLY
    if re.search(
        r"\b(?:what is|calculate)\s+[-+]?\d[\d., ]*\s*(?:[+*/-]|plus|minus|times|multiplied by|divided by)\s*[-+]?\d",
        folded,
    ):
        return RequestMode.ANSWER_ONLY
    if re.search(r"\b(?:what|where|which|who|why|how)\b", folded) and re.search(
        r"\b(?:window|screen|button|control|field|checkbox|toggle|tab|bar|options?|warning|error|dialog|visible|muted|enabled|selected|currently|this)\b",
        folded,
    ):
        return RequestMode.OBSERVE_AND_ANSWER
    if re.search(
        r"\b(?:am i|is (?:the|this|it|my)|are (?:the|these|they))\b", folded
    ) and re.search(
        r"\b(?:muted|enabled|disabled|checked|selected|open|playing|paused|on|off|visible)\b",
        folded,
    ):
        return RequestMode.OBSERVE_AND_ANSWER
    if re.search(
        r"\b(?:without|don't|do not|never)\s+(?:click|change|open|press|select)\b", folded
    ):
        return RequestMode.OBSERVE_AND_ANSWER
    # "Can you mute me?" requests a state change; "Can you tell me where ...?"
    # remains a question.  Check the first verb after the polite prefix.
    polite_action = re.match(
        r"^(?:please\s+)?(?:can|could|would)\s+you\s+"
        r"(?:open|launch|mute|unmute|silence|pause|play|enable|disable|turn|create|draft|write|put|call|name|send|delete|move|rename|save|select|choose|click|press|search|look\s+up|find|copy|attach|prevent|stop|keep|make sure)\b",
        folded,
    )
    if polite_action:
        return RequestMode.ACT
    if re.match(r"^google\s+(?:search\s+)?\S+\s+\S+", folded):
        return RequestMode.ACT
    if folded.endswith("?") and re.match(
        r"^(?:what|where|which|who|why|how|is|are|am|can you tell|could you tell)\b", folded
    ):
        return (
            RequestMode.ANSWER_ONLY
            if not _looks_like_ui_question(folded)
            else RequestMode.OBSERVE_AND_ANSWER
        )
    if _looks_like_ui_question(folded):
        return RequestMode.OBSERVE_AND_ANSWER
    if _field_assignment(normalized):
        return RequestMode.ACT
    if _looks_like_explicit_action(folded):
        return RequestMode.ACT
    return RequestMode.ANSWER_ONLY


def _looks_like_ui_question(text: str) -> bool:
    return bool(
        re.search(
            r"\b(?:where(?:'s| is| are| do i)|which (?:button|control|tab|option)|"
            r"what (?:tab|options|button|control|warning|error)|"
            r"what is (?:this|that|the) (?:button|control|checkbox|toggle|tab|warning|error|dialog|window)|"
            r"am i (?:muted|on)|is (?:the|this|my)|are (?:the|these)|"
            r"tell me where|show me where|point (?:out|me to) where|"
            r"read (?:this|the)|what does this)\b",
            text,
        )
    )


def _without_quoted(text: str) -> str:
    return _QUOTED.sub(" ", text)


def _task_constraints(text: str) -> tuple[str, ...]:
    """Extract a small set of explicit prohibitions independently of intent."""
    folded = _without_quoted(text).casefold()
    constraints = []
    for verbs, name in (
        (r"send|submit", "do_not_send"),
        (r"delete|remove|erase", "do_not_delete"),
        (r"publish|post", "do_not_publish"),
        (r"upload", "do_not_upload"),
    ):
        if re.search(rf"\b(?:don't|do not|never)\s+(?:\w+\s+){{0,2}}(?:{verbs})\b", folded):
            constraints.append(name)
    return tuple(constraints)


def _looks_like_explicit_action(text: str) -> bool:
    return bool(
        re.match(
            r"^(?:please\s+|hey\s+kio[, ]*)?(?:open|launch|start|bring|show|go\s+(?:to|into)|prevent|stop|keep|ensure|"
            r"google\s+(?:search\s+)?\S+\s+\S+|create|make|draft|compose|write|put|call|name|edit|find|search|look\s+up|navigate|turn|mute|unmute|"
            r"enable|disable|pause|play|resume|type|enter|select|choose|copy|move|rename|capture|take|"
            r"delete|save|send|attach|calculate|close|click|press|set)\b",
            text,
        )
        or re.match(
            r"^(?:i want|i need)\s+(?:you\s+to\s+)?(?:open|create|make|draft|write|find|search|move|delete|save|send|attach|pause|mute|turn|start)\b",
            text,
        )
        or re.match(
            r"^(?:i want|i need)\s+(?:you\s+to\s+)?(?:an?\s+)?(?:email|mail)\s+(?:draft|written|composed|created)\b",
            text,
        )
        or re.search(
            r"\b(?:mute me|silence (?:my )?mic(?:rophone)?|turn (?:my )?mic(?:rophone)? off|disable my mic|pause whatever)\b",
            text,
        )
        or re.search(
            r"\b(?:create|edit|find|search|look\s+up|navigate|type|put|call|name|select|choose|copy|move|rearrange|rename|delete|save|send|attach|close|prevent|stop|keep|ensure)\b",
            text,
        )
        or re.search(r"\b(?:take|capture)\s+(?:a\s+)?(?:picture|photo|photograph)\b", text)
    )


def _requests_microphone_mute(text: str) -> bool:
    """Recognize clear requests to stop microphone capture as a local mute intent."""
    folded = _without_quoted(text).casefold()
    if re.search(r"\b(?:don't|do not|never)\s+(?:\w+\s+){0,3}(?:prevent|stop|keep)\b", folded):
        return False
    return bool(
        re.search(
            r"\b(?:prevent|stop|keep)\b.{0,48}\b(?:my\s+)?(?:mic|microphone|audio input)\s+"
            r"(?:from\s+)?(?:transmit\w*|record\w*|captur\w*|listen\w*|pick up|send\w*|broadcast\w*)\b",
            folded,
        )
    )


def _literal(text: str, pattern: str, group: int = 1) -> str:
    match = re.search(pattern, text, re.IGNORECASE)
    return match[group].strip().strip('"“”') if match else ""


def _application_hint(text: str) -> str:
    new_tab = re.search(r"\bnew\s+tab\b", text, re.IGNORECASE)
    if new_tab:
        suffix = text[new_tab.end() :]
        browser = re.match(
            r"\s+(?:in|on|using)\s+(.+?)(?=\s+(?:and\s+(?:then\s+)?(?:go|open|search|look)"
            r"|then\s+(?:go|open|search|look))\b|[,;!?]|$)",
            suffix,
            re.IGNORECASE,
        )
        if browser:
            value = re.sub(r"\s+(?:browser|app|application)$", "", browser[1], flags=re.IGNORECASE)
            return value.strip(" .")
        return ""

    match = re.search(
        r"\b(?:open|launch|bring|show|go\s+(?:into|to))\s+(?:up\s+)?(?:(?:the|a|an)\s+)?"
        r"([A-Za-z][\w .&'’-]*?)(?=\s+(?:up\s+)?(?:and|then|to|for|so|before)\b|[,.!?]|$)",
        text,
        re.IGNORECASE,
    )
    value = match[1].strip() if match else ""
    if match and match[0].casefold().startswith("show "):
        value = re.sub(r"^me\s+", "", value, flags=re.IGNORECASE)
    value = re.sub(r"\s+up$", "", value, flags=re.IGNORECASE).strip()
    value = re.split(r"['’]s\b", value, maxsplit=1, flags=re.IGNORECASE)[0].strip()
    if value.casefold() in {"a new tab", "new tab"} or "://" in value:
        return ""
    if value:
        # The installed app catalog, not capitalization, is authoritative. The
        # lookahead above already separates common follow-up action clauses.
        value = re.sub(r"\s+(?:app|application)$", "", value, flags=re.IGNORECASE)
        value = re.sub(r"['’]s$", "", value).strip()
    if not value:
        match = re.search(
            r"\b(?:in|within|on)\s+(?:the\s+)?([A-Z][\w .&'’-]{1,50}?)(?=\s+(?:window|app)\b|[,.!?]|$)",
            text,
        )
        value = match[1].strip() if match else ""
    if not value:
        value = _named_search_site(text)
    return value.strip(" .")


def _named_search_site(text: str) -> str:
    """Extract an explicitly named site from a site-search request."""
    match = re.search(
        r"\b(?:search|look\s+up)\s+(?:the\s+)?(.+?)\s+for\s+(.+?)"
        r"(?:\s+(?:and\s+(?:then\s+)?(?:open|click|select)\b)|[.!?]|$)",
        _without_quoted(text),
        re.IGNORECASE,
    )
    if not match:
        match = re.search(
            r"\b(?:search|look\s+up)\s+(?:for\s+)?(.+?)\s+(?:on|in)\s+"
            r"(?:the\s+)?(.+?)(?:[.!?]|$)",
            _without_quoted(text),
            re.IGNORECASE,
        )
        if not match:
            return ""
        site = match[2]
    else:
        site = match[1]
    site = re.sub(r"\s+(?:website|site)$", "", site, flags=re.IGNORECASE).strip(" .")
    if site.casefold() in {"google", "the web", "the internet", "current site", "current page"}:
        return ""
    # A literal hostname or a single named site label can be opened safely by
    # the browser resolver. Multiword arbitrary phrases remain query text.
    if re.fullmatch(r"[\w.-]+\.[A-Za-z]{2,63}(?:/[\w./-]*)?", site) or re.fullmatch(
        r"[A-Za-z][A-Za-z0-9-]{1,62}", site
    ):
        return site
    return ""


def _action_source_clause(text: str, action: str) -> str:
    """Return the user's concise source-language clause for a planned step."""
    patterns = {
        "new_tab": r"\bopen\s+(?:a\s+)?new\s+tab\b|\bnew\s+tab\b",
        "navigate": r"\b(?:go\s+to|navigate\s+to|visit)\s+"
        r"(?:https?://)?[\w.-]+\.[A-Za-z]{2,63}(?:/[^\s,;]*)?",
        "search": r"\b(?:search|look\s+up)\b|\bgoogle(?:\s+search)?\b",
    }
    match = re.search(patterns[action], text, re.IGNORECASE)
    if not match:
        return ""
    start = match.start()
    end = len(text)
    # A search clause ends before a later, separately requested UI action.
    tail = text[match.end() :]
    later_action = re.search(
        r"(?:,\s*(?:and\s+)?|\s+(?:and\s+then|then|and)\s+)"
        r"(?=(?:open|go\s+to|navigate|visit|search|look\s+up|click|press|tap|select)\b)",
        tail,
        re.IGNORECASE,
    )
    punctuation = re.search(r"[.!?]", tail)
    if later_action:
        end = match.end() + later_action.start()
    elif punctuation:
        end = match.end() + punctuation.start()
    clause = text[start:end].strip(" ,;.")
    if action == "new_tab":
        clause = re.sub(r"\s+(?:in|on|using)\s+.+$", "", clause, flags=re.IGNORECASE)
    return clause


def _search_details(text: str, app: str) -> tuple[str, str]:
    """Extract the search query and whether the user named a site or page."""
    clause = _action_source_clause(text, "search")
    folded_clause = clause.casefold()
    current = re.match(
        r"(?:search|look\s+up)\s+(?:the\s+)?(?:current\s+)?(?:site|page)\s+for\s+(.+)$",
        clause,
        re.IGNORECASE,
    )
    if current:
        return _clean_search_query(current[1]), "CURRENT_SITE"

    site_for = re.match(
        r"(?:search|look\s+up)\s+(?:the\s+)?(.+?)\s+for\s+(.+)$",
        clause,
        re.IGNORECASE,
    )
    if site_for:
        site, query = site_for[1].strip(), _clean_search_query(site_for[2])
        if site.casefold() in {"google", "the web", "the internet"}:
            return query, "GLOBAL_WEB"
        return query, "NAMED_SITE"

    query_on_site = re.match(
        r"(?:search|look\s+up)\s+(?:for\s+)?(.+?)\s+(?:on|in)\s+(?:the\s+)?(.+)$",
        clause,
        re.IGNORECASE,
    )
    if query_on_site:
        site = query_on_site[2].strip()
        if site.casefold() in {"current site", "current page"}:
            return _clean_search_query(query_on_site[1]), "CURRENT_SITE"
        if site.casefold() in {"google", "the web", "the internet"}:
            return _clean_search_query(query_on_site[1]), "GLOBAL_WEB"
        return _clean_search_query(query_on_site[1]), "NAMED_SITE"

    # Google is a provider, not an application or a named content site.
    google = re.match(
        r"(?:google(?:\s+search)?|search\s+google)\s+(?:for\s+)?(.+)$",
        clause,
        re.IGNORECASE,
    )
    if google:
        return _clean_search_query(google[1]), "GLOBAL_WEB"

    generic = re.match(r"(?:search|look\s+up)\s+(?:for\s+)?(.+)$", clause, re.IGNORECASE)
    query = _clean_search_query(generic[1]) if generic else ""
    if not query:
        return "", "GLOBAL_WEB"

    if re.search(r"\b(?:current\s+)?(?:site|page)\b", folded_clause):
        return query, "CURRENT_SITE"
    if _spoken_compound_destination(text):
        return query, "CURRENT_SITE"
    if app and re.match(r"^(?:open|launch|bring|show|go\s+(?:to|into))\b", text, re.IGNORECASE):
        return query, "CURRENT_SITE" if not _is_browser_hint(app) else "GLOBAL_WEB"
    return query, "GLOBAL_WEB"


def _clean_search_query(query: str) -> str:
    return re.sub(r"\s+(?:please|for\s+me)$", "", query.strip().strip(" .!?"), flags=re.IGNORECASE)


def _is_browser_hint(app: str) -> bool:
    """Recognize generic browser names while leaving app resolution to inventory."""
    return app.casefold().strip() in {
        "browser",
        "web browser",
        "chrome",
        "google chrome",
        "safari",
        "firefox",
        "mozilla firefox",
        "edge",
        "microsoft edge",
        "brave",
        "opera",
    }


def _field_assignment(text: str) -> tuple[str, str] | None:
    """Extract a literal field/value pair without asking a model to invent it."""
    cleaned = text.strip().rstrip(".!?").strip()
    cleaned = re.sub(
        r"^(?:(?:inside|in)\s+(?:this|the)\s+(?:new\s+)?(?:note|document)\s*[,;:]?\s*)?"
        r"(?:let['’]s\s+)?",
        "",
        cleaned,
        flags=re.IGNORECASE,
    )
    patterns = (
        (
            "title",
            (
                r"^(?:make|set)\s+(?:(?:its|the\s+(?:new\s+)?(?:note|document)['’]s?)\s+)?"
                r"(?:the\s+)?title(?:\s+field)?\s+(?:(?:say|to|as)\s+)?(.+)$"
            ),
        ),
        (
            "title",
            (
                r"^(?:call|name)\s+(?:(?:it|this|that)|(?:the\s+)?(?:new\s+)?(?:note|document))\s+"
                r"(?:(?:say|to|as)\s+)?(.+)$"
            ),
        ),
        (
            "title",
            (
                r"^title\s+(?:it|(?:the\s+)?(?:new\s+)?(?:note|document))\s+"
                r"(?:(?:say|to|as)\s+)?(.+)$"
            ),
        ),
        ("subject", r"^set\s+(?:the\s+)?subject(?:\s+field)?\s+to\s+(.+)$"),
        (
            "recipient",
            r"^(?:enter|put|set)\s+(.+?)\s+(?:in|into)\s+(?:the\s+)?recipient(?:\s+field)?$",
        ),
        (
            "body",
            r"^(?:write|put|type|enter)\s+(.+?)\s+(?:inside\s+(?:it|this|that)|in(?:to)?\s+(?:the\s+)?(?:body|note|document))$",
        ),
    )
    for field_name, pattern in patterns:
        match = re.fullmatch(pattern, cleaned, re.IGNORECASE)
        if not match:
            continue
        value = match[1].strip()
        if value.startswith(('"', "“")) and value.endswith(('"', "”")):
            value = value[1:-1]
        value = re.sub(r"\s+for\s+me$", "", value, flags=re.IGNORECASE).strip()
        if value and len(value) <= 2000:
            return field_name, value
    return None


def _spoken_destination(text: str) -> str:
    candidate = text.strip()
    candidate = re.sub(r"^(?:open|go\s+to|visit)\s+", "", candidate, flags=re.IGNORECASE)
    if not re.fullmatch(
        r"(?:https?://)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
        r"[a-z]{2,63}(?::\d{1,5})?(?:/[^\s]*)?",
        candidate,
        re.IGNORECASE,
    ):
        return ""
    from .direct import normalize_url

    return normalize_url(candidate) or ""


def _spoken_compound_destination(text: str) -> str:
    """Find a literal URL in a multi-step spoken request."""
    match = re.search(
        r"\b(?:go\s+to|navigate\s+to|visit)\s+"
        r"((?:https?://)?[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
        r"(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+"
        r"(?::\d{1,5})?(?:/[^\s,;]*)?)",
        text,
        re.IGNORECASE,
    )
    if not match:
        return ""
    from .direct import normalize_url

    return normalize_url(match[1].rstrip(".!?")) or ""


def _quoted_body(text: str) -> str:
    match = _QUOTED.search(text)
    return next((value for value in match.groups() if value is not None), "") if match else ""


def _step(
    operation,
    *,
    app="",
    object_type=ObjectType.GENERIC_UI_OBJECT,
    label="",
    parameters=None,
    desired=None,
    constraints=(),
    completion=(),
    source_clause="",
):
    return SemanticStep(
        operation,
        app,
        object_type,
        label,
        parameters or {},
        desired,
        tuple(constraints),
        tuple(completion),
        source_clause=source_clause,
    )


class NaturalLanguageInterpreter:
    """High-confidence structured extraction for common requests."""

    def interpret(self, utterance: str) -> SemanticTaskPlan:
        return SemanticTaskPlanner().plan(utterance)


class SemanticTaskPlanner:
    """Fast deterministic tier plus a bounded, re-used Laya classification tier."""

    def plan(
        self, utterance: str, reasoner: BoundedSemanticReasoner | None = None
    ) -> SemanticTaskPlan:
        original = str(utterance or "")
        normalized = _normalize_preserving_quotes(original)
        literals = extract_literals(original)
        mode = classify_request_mode(original)
        app = _application_hint(normalized)
        step_clause = self._after_app_open(normalized, app) if app else normalized
        steps: list[SemanticStep] = []
        constraints: list[str] = list(_task_constraints(original))
        completion: list[str] = []
        lowered = _without_quoted(normalized).casefold()
        tier = "deterministic"
        confidence = 0.98
        unresolved = False
        refinement_text = normalized

        if mode == RequestMode.ANSWER_ONLY and re.fullmatch(
            r"(?:thanks|thank you|thanks a lot|that's all|that is all)[.!?]*",
            lowered,
        ):
            return SemanticTaskPlan(
                mode, original, normalized, app, (), literals, tuple(constraints), (), 1.0, tier
            )

        if mode == RequestMode.OBSERVE_AND_ANSWER:
            operation = self._observation_operation(lowered)
            label = self._observation_subject(normalized)
            steps.append(
                _step(
                    operation,
                    app=app,
                    object_type=ObjectType.CONTROL,
                    label=label,
                    parameters={"question": original},
                    completion=("answer_from_observed_state",),
                )
            )
            completion.append("answer_from_observed_state")
            return SemanticTaskPlan(
                mode,
                original,
                normalized,
                app,
                tuple(steps),
                literals,
                tuple(constraints),
                tuple(completion),
                confidence,
                tier,
            )

        destination = _spoken_destination(normalized)
        if destination:
            condition = f"url={destination}"
            step = _step(
                SemanticOperation.NAVIGATE,
                object_type=ObjectType.WEB_PAGE,
                parameters={"url": destination},
                completion=(condition,),
            )
            return SemanticTaskPlan(
                RequestMode.ACT,
                original,
                normalized,
                "",
                (step,),
                literals,
                tuple(constraints),
                (condition,),
                confidence,
                tier,
            )

        if mode == RequestMode.ANSWER_ONLY:
            expression = self._arithmetic_expression(normalized)
            if expression:
                steps.append(
                    _step(
                        SemanticOperation.CALCULATE,
                        object_type=ObjectType.GENERIC_UI_OBJECT,
                        parameters={"expression": expression},
                        completion=("answer_calculated",),
                    )
                )
                completion.append("answer_calculated")
            elif re.search(
                r"\b(?:current time|what time is it|today's date|what date is it)\b", lowered
            ):
                steps.append(
                    _step(
                        SemanticOperation.READ,
                        object_type=ObjectType.GENERIC_UI_OBJECT,
                        parameters={"query": normalized},
                        completion=("answer_local_context",),
                    )
                )
                completion.append("answer_local_context")
            # Unknown language is sent through the shared local chooser for a
            # bounded mode decision. Known local answers stay on the fast path.
            if not steps and reasoner is not None:
                interpreted_mode, mode_confidence = self._classify_mode(original, reasoner)
                if mode_confidence >= 0.60:
                    if interpreted_mode == RequestMode.OBSERVE_AND_ANSWER:
                        return self._observation_plan(
                            original,
                            normalized,
                            app,
                            literals,
                            interpreted_mode,
                            mode_confidence,
                            "laya_bounded",
                            reasoner=reasoner,
                        )
                    if interpreted_mode == RequestMode.ACT:
                        mode = interpreted_mode
                        tier = "laya_bounded"
                        confidence = mode_confidence
                    else:
                        return SemanticTaskPlan(
                            interpreted_mode,
                            original,
                            normalized,
                            app,
                            (),
                            literals,
                            tuple(constraints),
                            (),
                            mode_confidence,
                            "laya_bounded",
                            unresolved=False,
                        )
            if mode == RequestMode.ANSWER_ONLY:
                return SemanticTaskPlan(
                    mode,
                    original,
                    normalized,
                    app,
                    tuple(steps),
                    literals,
                    tuple(constraints),
                    tuple(completion),
                    confidence,
                    tier,
                    unresolved=not bool(steps) and reasoner is None,
                )

        if mode == RequestMode.OBSERVE_AND_ANSWER:
            return self._observation_plan(
                original,
                normalized,
                app,
                literals,
                mode,
                confidence,
                tier,
                constraints=tuple(constraints),
            )

        # A clearly requested app is a safe prerequisite and remains its own step.
        if app and re.match(r"^(?:open|launch|bring|show|go\s+(?:to|into))\b", lowered):
            steps.append(
                _step(
                    SemanticOperation.OPEN,
                    app=app,
                    object_type=ObjectType.APP,
                    label=app,
                    completion=("application_usable",),
                    source_clause=f"Open {app}",
                )
            )
            completion.append("application_usable")

        email = _EMAIL.search(original)
        if (
            email
            and re.search(r"\b(?:email|mail)\b", lowered)
            and re.search(r"\b(?:draft|compose|write|create|new|start)\b", lowered)
        ):
            recipient = email.group(1)
            body = _quoted_body(original)
            instruction = _without_quoted(normalized).casefold()
            explicitly_sending = bool(re.search(r"\b(?:send|submit)\b", instruction)) and not bool(
                re.search(r"\b(?:don't|do not|never)\s+send\b", instruction)
            )
            no_send = not explicitly_sending
            step_constraints = ("do_not_send",) if no_send else ()
            constraints.extend(item for item in step_constraints if item not in constraints)
            required = ["composer_open"]
            steps.append(
                _step(
                    SemanticOperation.CREATE,
                    app=app,
                    object_type=ObjectType.EMAIL_DRAFT,
                    label="email draft",
                    constraints=step_constraints,
                    completion=required,
                )
            )
            completion.extend(required)
            steps.append(
                _step(
                    SemanticOperation.TYPE,
                    app=app,
                    object_type=ObjectType.FIELD,
                    label="To",
                    parameters={"field": "recipient", "text": recipient},
                    constraints=step_constraints,
                    completion=(f"recipient={recipient}",),
                )
            )
            completion.append(f"recipient={recipient}")
            if body:
                steps.append(
                    _step(
                        SemanticOperation.TYPE,
                        app=app,
                        object_type=ObjectType.FIELD,
                        label="message body",
                        parameters={"field": "body", "text": body},
                        constraints=step_constraints,
                        completion=(f"body={body}",),
                    )
                )
                completion.append(f"body={body}")
            if explicitly_sending:
                steps.append(
                    _step(
                        SemanticOperation.SEND,
                        app=app,
                        object_type=ObjectType.EMAIL,
                        label="email",
                        completion=("email_sent",),
                    )
                )
                completion.append("email_sent")
            if re.search(r"\battach\b", lowered):
                file_match = _FILENAME.search(original)
                file_label = (
                    file_match.group(1)
                    if file_match
                    else "PDF"
                    if re.search(r"\bpdf\b", lowered)
                    else ""
                )
                find_constraints = tuple(
                    filter(
                        None,
                        (
                            "file_type=PDF" if "pdf" in lowered else "",
                            "downloaded=today" if "today" in lowered else "",
                        ),
                    )
                )
                steps.append(
                    _step(
                        SemanticOperation.FIND,
                        app=app,
                        object_type=ObjectType.FILE,
                        label=file_label,
                        parameters={"file": file_label},
                        constraints=find_constraints,
                        completion=("unique_file_match",),
                    )
                )
                steps.append(
                    _step(
                        SemanticOperation.ATTACH,
                        app=app,
                        object_type=ObjectType.FILE,
                        label=file_label,
                        parameters={"file": file_label},
                        constraints=("do_not_send",),
                        completion=("attachment_visible_in_draft",),
                    )
                )
                completion.extend(("unique_file_match", "attachment_visible_in_draft"))
            return SemanticTaskPlan(
                mode,
                original,
                normalized,
                app,
                tuple(steps),
                literals,
                tuple(constraints),
                tuple(completion),
                confidence,
                tier,
            )

        assignment = _field_assignment(normalized)
        if assignment:
            field_name, value = assignment
            condition = f"{field_name}={value}"
            steps.append(
                _step(
                    SemanticOperation.SET_FIELD,
                    app=app,
                    object_type=ObjectType.FIELD,
                    label="current_object",
                    parameters={"field": field_name, "text": value},
                    completion=(condition,),
                )
            )
            completion.append(condition)
            return SemanticTaskPlan(
                mode,
                original,
                normalized,
                app,
                tuple(steps),
                literals,
                tuple(constraints),
                tuple(completion),
                confidence,
                tier,
            )

        if re.search(r"\b(?:note|notes)\b", lowered) and re.search(
            r"\b(?:create|make|new)\b", lowered
        ):
            title = _literal(normalized, r"\b(?:called|named|titled)\s+[\"“]([^\"”]+)[\"”]")
            body = _quoted_body(original)
            # When both title and content are quoted, the first literal after the
            # naming cue belongs to the title, and the final one is the body.
            quoted_values = [
                next((v for v in m.groups() if v is not None), "")
                for m in _QUOTED.finditer(original)
            ]
            if title and len(quoted_values) > 1:
                body = quoted_values[-1]
            if not title:
                title = _literal(
                    normalized, r"\b(?:called|named|titled)\s+(.+?)(?:\s+and\s+|[,.;!?]|$)"
                )
            required = ["note_created"]
            steps.append(
                _step(
                    SemanticOperation.CREATE,
                    app=app,
                    object_type=ObjectType.NOTE,
                    label=title,
                    completion=required,
                )
            )
            completion.extend(required)
            if title:
                steps.append(
                    _step(
                        SemanticOperation.TYPE,
                        app=app,
                        object_type=ObjectType.FIELD,
                        label="note title",
                        parameters={"field": "title", "text": title},
                        completion=(f"title={title}",),
                    )
                )
                completion.append(f"title={title}")
            if body:
                steps.append(
                    _step(
                        SemanticOperation.TYPE,
                        app=app,
                        object_type=ObjectType.FIELD,
                        label="note body",
                        parameters={"field": "body", "text": body},
                        completion=(f"body={body}",),
                    )
                )
                completion.append(f"body={body}")
            return SemanticTaskPlan(
                mode,
                original,
                normalized,
                app,
                tuple(steps),
                literals,
                tuple(constraints),
                tuple(completion),
                confidence,
                tier,
            )

        if re.search(r"\b(?:take|capture)\b", lowered) and re.search(
            r"\b(?:picture|photo|photograph)\b", lowered
        ):
            steps.append(
                _step(
                    SemanticOperation.CAPTURE,
                    app=app,
                    object_type=ObjectType.PHOTO,
                    label="photo",
                    completion=("photo_captured",),
                )
            )
            completion.append("photo_captured")
            return SemanticTaskPlan(
                mode,
                original,
                normalized,
                app,
                tuple(steps),
                literals,
                tuple(constraints),
                tuple(completion),
                confidence,
                tier,
            )

        if re.search(r"\b(?:folder|directory)\b", lowered) and re.search(
            r"\b(?:create|make|new)\b", lowered
        ):
            name = _literal(normalized, r"\b(?:called|named|titled)\s+[\"“]([^\"”]+)[\"”]")
            if not name:
                name = _literal(
                    normalized, r"\b(?:called|named|titled)\s+(.+?)(?:\s+and\s+|[,.;!?]|$)"
                )
            steps.append(
                _step(
                    SemanticOperation.CREATE,
                    app=app,
                    object_type=ObjectType.FOLDER,
                    label=name,
                    parameters={"name": name},
                    completion=(f"folder_created={name}",),
                )
            )
            completion.append(f"folder_created={name}")
            file_match = _FILENAME.search(original)
            if file_match and re.search(r"\bmove\b", lowered):
                filename = file_match.group(1).strip()
                filename = re.sub(
                    r"^(?:(?:and|then)\s+)?(?:move|copy|attach|rename|delete|find|locate|open|select)\s+",
                    "",
                    filename,
                    flags=re.IGNORECASE,
                )
                steps.append(
                    _step(
                        SemanticOperation.MOVE,
                        app=app,
                        object_type=ObjectType.FILE,
                        label=filename,
                        parameters={"file": filename, "destination": name},
                        constraints=("source_and_destination_must_be_unique",),
                        completion=(f"file_moved={filename}", f"destination={name}"),
                    )
                )
                completion.extend((f"file_moved={filename}", f"destination={name}"))
            return SemanticTaskPlan(
                mode,
                original,
                normalized,
                app,
                tuple(steps),
                literals,
                tuple(constraints),
                tuple(completion),
                confidence,
                tier,
            )

        if re.search(r"\b(?:new\s+tab|open\s+(?:a\s+)?new\s+tab)\b", lowered):
            steps.append(
                _step(
                    SemanticOperation.NEW_TAB,
                    app=app,
                    object_type=ObjectType.TAB,
                    completion=("new_tab",),
                    source_clause=_action_source_clause(normalized, "new_tab"),
                )
            )
        compound_destination = _spoken_compound_destination(normalized)
        if compound_destination:
            condition = f"url={compound_destination}"
            steps.append(
                _step(
                    SemanticOperation.NAVIGATE,
                    app=app,
                    object_type=ObjectType.WEB_PAGE,
                    parameters={"url": compound_destination},
                    completion=(condition,),
                    source_clause=_action_source_clause(normalized, "navigate"),
                )
            )
            completion.append(condition)
        if re.search(
            r"\b(?:search|look\s+up)\b|\bgoogle(?:\s+search)?\b", lowered
        ) and not re.search(r"\bsearch\s+bar\b", lowered):
            query, search_scope = _search_details(normalized, app)
            if query:
                steps.append(
                    _step(
                        SemanticOperation.SEARCH,
                        app=app,
                        object_type=ObjectType.WEB_PAGE,
                        parameters={
                            "query": query,
                            "search_scope": search_scope,
                        },
                        completion=(f"query_visible={query}",),
                        source_clause=_action_source_clause(normalized, "search"),
                    )
                )
                completion.append(f"query_visible={query}")
                if re.search(r"\b(?:open|click|select)\b.*\bwikipedia\b", lowered):
                    steps.append(
                        _step(
                            SemanticOperation.SELECT,
                            app=app,
                            object_type=ObjectType.WEB_PAGE,
                            label="Wikipedia result",
                            parameters={"result": "Wikipedia"},
                            completion=("destination_title_contains=Wikipedia",),
                        )
                    )
                    completion.append("destination_title_contains=Wikipedia")

        activation = re.search(
            r"\b(?:press|click|tap|activate)\s+(?:the\s+)?(.+?)(?:[,.!?]|$)",
            step_clause,
            re.IGNORECASE,
        )
        if activation:
            target_phrase = re.sub(r"\s+", " ", activation[1]).strip(" .,!?")
            target_label = re.sub(r"^(?:the|a|an)\s+", "", target_phrase, flags=re.IGNORECASE)
            target_label = re.sub(r"\s+(?:button|control)$", "", target_label, flags=re.IGNORECASE)
            steps.append(
                _step(
                    SemanticOperation.ACTIVATE_CONTROL_ONCE,
                    app=app,
                    object_type=ObjectType.CONTROL,
                    label=target_label,
                    parameters={"target": target_phrase},
                    constraints=("maximum_effectful_actions=1",),
                    completion=("control_activated_once",),
                    source_clause=step_clause,
                )
            )
            completion.append("control_activated_once")
        elif re.search(r"\b(?:pause|resume|play)\b", lowered):
            desired = (
                DesiredState.PAUSED if re.search(r"\bpause\b", lowered) else DesiredState.PLAYING
            )
            steps.append(
                _step(
                    SemanticOperation.SET_STATE,
                    app=app,
                    object_type=ObjectType.MEDIA_PLAYBACK,
                    desired=desired,
                    completion=(f"media_state={desired.value}",),
                    source_clause=step_clause,
                )
            )
            completion.append(f"media_state={desired.value}")
        elif _requests_microphone_mute(lowered) or re.search(
            r"\b(?:mute me|mute myself|silence (?:my )?(?:mic|microphone)|turn (?:my )?(?:mic|microphone) off|disable my (?:mic|microphone))\b",
            lowered,
        ):
            steps.append(
                _step(
                    SemanticOperation.SET_STATE,
                    app=app,
                    object_type=ObjectType.CONTROL,
                    label="microphone",
                    desired=DesiredState.MUTED,
                    completion=("microphone_state=MUTED",),
                    source_clause=step_clause,
                )
            )
            completion.append("microphone_state=MUTED")
        elif re.search(
            r"\b(?:unmute me|turn (?:my )?(?:mic|microphone) on|enable my (?:mic|microphone))\b",
            lowered,
        ):
            steps.append(
                _step(
                    SemanticOperation.SET_STATE,
                    app=app,
                    object_type=ObjectType.CONTROL,
                    label="microphone",
                    desired=DesiredState.UNMUTED,
                    completion=("microphone_state=UNMUTED",),
                    source_clause=step_clause,
                )
            )
            completion.append("microphone_state=UNMUTED")

        has_task_step = any(step.operation != SemanticOperation.OPEN for step in steps)
        remainder = self._after_app_open(normalized, app) if app else ""
        if not has_task_step and (not steps or remainder):
            request = remainder or original
            refinement_text = request
            intent = _without_quoted(request).casefold()
            inferred_operation = self._infer_explicit_operation(intent)
            operation = inferred_operation or SemanticOperation.CUSTOM
            object_type = (
                ObjectType.FILE
                if re.search(r"\b(?:file|pdf|document)\b", intent)
                else ObjectType.GENERIC_UI_OBJECT
            )
            parameters = {"request": request}
            for index, literal in enumerate(literals[:8]):
                parameters[f"literal_{index + 1}"] = literal.value
            quoted = _quoted_body(original)
            if quoted:
                parameters["text"] = quoted
            steps.append(
                _step(
                    operation,
                    app=app,
                    object_type=object_type,
                    parameters=parameters,
                    constraints=tuple(constraints),
                    completion=("requested_state_verified",),
                )
            )
            completion.append("requested_state_verified")
            prohibited = {
                SemanticOperation.SEND: "do_not_send",
                SemanticOperation.DELETE: "do_not_delete",
                SemanticOperation.ATTACH: "do_not_upload",
            }.get(operation)
            unresolved = inferred_operation is None or prohibited in constraints
            confidence = 0.0 if unresolved else 0.88

        if unresolved and reasoner is not None:
            refined = self._refine(refinement_text, mode, reasoner)
            if refined and steps:
                operation, object_type, desired_state, score = refined
                old = steps[-1]
                prohibited = {
                    SemanticOperation.SEND: "do_not_send",
                    SemanticOperation.DELETE: "do_not_delete",
                    SemanticOperation.ATTACH: "do_not_upload",
                }.get(operation)
                if prohibited not in constraints:
                    steps[-1] = _step(
                        operation,
                        app=old.application_hint,
                        object_type=object_type,
                        label=old.object_label,
                        parameters=old.parameters,
                        desired=desired_state,
                        constraints=tuple(constraints),
                        completion=old.completion_conditions,
                    )
                    unresolved = False
                    confidence = score
                    tier = "laya_bounded"
        steps = [
            replace(
                step,
                source_clause=step.source_clause
                or (
                    f"Open {step.application_hint}"
                    if step.operation == SemanticOperation.OPEN
                    else step_clause
                ),
            )
            for step in steps
        ]
        return SemanticTaskPlan(
            mode,
            original,
            normalized,
            app,
            tuple(steps),
            literals,
            tuple(constraints),
            tuple(completion),
            confidence,
            tier,
            unresolved,
        )

    @staticmethod
    def _after_app_open(text: str, app: str) -> str:
        if not app:
            return ""
        pattern = (
            r"^(?:please\s+|hey\s+kio[, ]*)?(?:open|launch|bring|show(?:\s+me)?|go\s+(?:to|into))\s+"
            r"(?:the\s+)?" + re.escape(app) + r"\b(?:\s+(?:app|application))?(?:\s+up)?"
        )
        remainder = re.sub(pattern, "", text, count=1, flags=re.IGNORECASE).strip(" ,.!?")
        remainder = re.sub(r"^(?:and then|and|then)\s+", "", remainder, flags=re.IGNORECASE)
        remainder = re.sub(r"^['’]s\s*", "", remainder)
        return remainder.strip(" ,.!?")

    @staticmethod
    def _observation_plan(
        original,
        normalized,
        app,
        literals,
        mode,
        confidence,
        tier,
        constraints=(),
        reasoner=None,
    ) -> SemanticTaskPlan:
        lowered = _without_quoted(normalized).casefold()
        operation = SemanticTaskPlanner._observation_operation(lowered)
        if reasoner is not None:
            refined = SemanticTaskPlanner._refine(
                original, RequestMode.OBSERVE_AND_ANSWER, reasoner
            )
            if refined is not None:
                operation = refined[0]
                confidence = min(confidence, refined[3])
        label = SemanticTaskPlanner._observation_subject(normalized)
        step = _step(
            operation,
            app=app,
            object_type=ObjectType.CONTROL,
            label=label,
            parameters={"question": original},
            completion=("answer_from_observed_state",),
        )
        return SemanticTaskPlan(
            mode,
            original,
            normalized,
            app,
            (step,),
            literals,
            tuple(constraints),
            ("answer_from_observed_state",),
            confidence,
            tier,
        )

    @staticmethod
    def _observation_operation(text: str) -> SemanticOperation:
        if re.search(r"\bwhere|where's|where is\b", text) or re.search(
            r"\bwhich\s+(?:button|control)\b", text
        ):
            return SemanticOperation.LOCATE
        if re.search(
            r"\b(?:is|are|am i)\b.*\b(?:muted|enabled|disabled|checked|selected|open|playing|paused|on|off)\b",
            text,
        ):
            return SemanticOperation.READ
        if re.search(r"\b(?:read|what does .* say|what does this .* mean)\b", text):
            return SemanticOperation.READ
        if re.search(r"\b(?:which|what options|what tab)\b", text):
            return SemanticOperation.FIND
        return SemanticOperation.DESCRIBE

    @staticmethod
    def _observation_subject(text: str) -> str:
        patterns = (
            r"\b(?:where(?:'s| is| are)|which)\s+(?:is\s+)?(?:the\s+)?(.+?)(?:\s+in\s+.+)?[?.!]*$",
            r"\b(?:am i|is (?:the|this|my)|are (?:the|these))\s+(.+?)[?.!]*$",
            r"\bwhat (?:does|is|are)\s+(?:this|the)\s+(.+?)[?.!]*$",
            r"\b(?:show|tell) me\s+(.+?)[?.!]*$",
        )
        for pattern in patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                subject = re.sub(r"\s+in\s+.+$", "", match[1], flags=re.IGNORECASE).strip(" ?.,")
                break
        else:
            subject = text.strip()
        folded = subject.casefold()
        for pattern, concept in (
            (r"\b(?:mute|muted|unmute|silence|microphone|mic|audio input)\b", "microphone"),
            (r"\b(?:camera|webcam|video)\b", "camera"),
            (r"\b(?:settings|preferences|configuration)\b", "settings"),
            (r"\b(?:search|find)\b", "search"),
            (r"\b(?:deafen|headphones|audio output)\b", "deafen"),
        ):
            if re.search(pattern, folded):
                return concept
        return subject

    @staticmethod
    def _arithmetic_expression(text: str) -> str:
        match = re.search(
            r"(?<!\w)(\d+(?:\.\d+)?\s*(?:[+*/-]|plus|minus|times|multiplied by|divided by)\s*\d+(?:\.\d+)?)(?!\w)",
            text,
            re.IGNORECASE,
        )
        if not match:
            return ""
        return (
            re.sub(r"\bplus\b", "+", match[1], flags=re.IGNORECASE)
            .replace("multiplied by", "*")
            .replace("divided by", "/")
            .replace("times", "*")
            .replace("minus", "-")
        )

    @staticmethod
    def _infer_explicit_operation(text: str) -> SemanticOperation | None:
        mappings = (
            (r"\b(?:find|locate)\b", SemanticOperation.FIND),
            (r"\b(?:edit|change|update)\b", SemanticOperation.EDIT),
            (r"\b(?:delete|remove|erase)\b", SemanticOperation.DELETE),
            (r"\b(?:move)\b", SemanticOperation.MOVE),
            (r"\b(?:rename)\b", SemanticOperation.RENAME),
            (r"\b(?:copy)\b", SemanticOperation.COPY),
            (r"\b(?:attach)\b", SemanticOperation.ATTACH),
            (r"\b(?:send)\b", SemanticOperation.SEND),
            (r"\b(?:save)\b", SemanticOperation.SAVE),
            (r"\b(?:select|choose)\b", SemanticOperation.SELECT),
            (r"\b(?:type|enter|write)\b", SemanticOperation.TYPE),
            (r"\b(?:close)\b", SemanticOperation.CLOSE),
            (r"\b(?:click|press|tap|activate)\b", SemanticOperation.ACTIVATE_CONTROL_ONCE),
            (r"\b(?:perform|do)\b", SemanticOperation.CUSTOM),
            (r"\b(?:open|launch|go to|navigate)\b", SemanticOperation.NAVIGATE),
        )
        return next(
            (operation for pattern, operation in mappings if re.search(pattern, text)), None
        )

    @staticmethod
    def _classify_mode(text: str, reasoner: BoundedSemanticReasoner) -> tuple[RequestMode, float]:
        choices = {
            RequestMode.ANSWER_ONLY.value: "Answer general knowledge or calculate without inspecting or changing an app.",
            RequestMode.OBSERVE_AND_ANSWER.value: "Read-only: locate, identify, read, explain, or report the current app or screen state.",
            RequestMode.ACT.value: "Perform a computer task that changes state, such as open, click, type, create, move, or edit.",
        }
        try:
            mode, confidence = reasoner.classify_semantic(
                _without_quoted(text), "semantic_request_mode", choices
            )
            result = RequestMode(mode)
            if result == RequestMode.ACT and SemanticTaskPlanner._question_shaped(text):
                # Unknown interrogatives may be answered or inspected, but a
                # model cannot turn them into computer-use authority.
                return RequestMode.ANSWER_ONLY, 0.0
            return result, confidence
        except Exception:  # noqa: BLE001 -- invalid model output fails closed
            return RequestMode.ANSWER_ONLY, 0.0

    @staticmethod
    def _question_shaped(text: str) -> bool:
        folded = _without_quoted(text).casefold().strip()
        return bool(
            re.match(
                r"^(?:what|where|which|who|why|how|is|are|am|do you know|"
                r"(?:can|could|would) you (?:tell|say|explain|describe|let me know)|"
                r"(?:can|could|would) you show me where)\b",
                folded,
            )
        )

    @staticmethod
    def _refine(
        text: str, mode: RequestMode, reasoner: BoundedSemanticReasoner
    ) -> tuple[SemanticOperation, ObjectType, DesiredState | None, float] | None:
        groups = {
            "OBSERVE": {"LOCATE", "READ", "DESCRIBE", "FIND"},
            "CONTENT": {"CREATE", "EDIT", "TYPE", "SAVE", "SEND", "ATTACH"},
            "OBJECT": {"FIND", "SELECT", "COPY", "MOVE", "RENAME", "DELETE"},
            "NAVIGATION": {"OPEN", "SEARCH", "NAVIGATE", "NEW_TAB", "CLOSE"},
            "STATE": {"SET_STATE", "ACTIVATE_CONTROL_ONCE", "CUSTOM"},
        }
        group_descriptions = {
            "OBSERVE": "Read-only: answer where something is, what is visible, or its current state.",
            "CONTENT": "Create or change content such as an email, message, note, or document.",
            "OBJECT": "Find, select, copy, move, rearrange, rename, or delete an existing item or file.",
            "NAVIGATION": "Open, launch, search, navigate to, or close an app, page, or tab.",
            "STATE": "Change a control, setting, or media state such as mute, pause, enabled, or off.",
        }
        semantic_text = _without_quoted(text)
        try:
            group, group_score = reasoner.classify_semantic(
                semantic_text, "semantic_group", group_descriptions
            )
            candidates = groups.get(group, set())
            if mode == RequestMode.OBSERVE_AND_ANSWER:
                candidates &= groups["OBSERVE"]
            elif mode != RequestMode.ACT:
                return None
            if not candidates:
                return None
            operation_descriptions = {
                "ATTACH": "Attach a selected file to a draft or document.",
                "ACTIVATE_CONTROL_ONCE": "Press or click one observed control exactly once.",
                "COPY": "Make a copy of an existing item or file.",
                "CREATE": "Create a new item such as a message, note, document, or folder.",
                "CUSTOM": "Perform a requested UI action not represented by the other choices.",
                "DELETE": "Permanently or temporarily remove an existing item.",
                "DESCRIBE": "Describe what is visible without changing it.",
                "EDIT": "Change existing content or properties.",
                "FIND": "Locate an existing item or control.",
                "LOCATE": "Identify where a control or item appears.",
                "MOVE": "Relocate or rearrange an existing item to another place or folder.",
                "NAVIGATE": "Go to an app, page, or location.",
                "NEW_TAB": "Open a new browser tab.",
                "OPEN": "Open an installed application or existing item.",
                "READ": "Read visible content or report a current value.",
                "RENAME": "Change the name of an existing item.",
                "SAVE": "Save a draft, document, or file.",
                "SEARCH": "Search for the supplied query.",
                "SELECT": "Choose one supplied visible option or item.",
                "SEND": "Send or submit a message or form.",
                "SET_STATE": "Set a control, setting, or playback state to the requested state.",
                "TYPE": "Enter supplied text into a field or editable content area.",
                "CLOSE": "Close an app, page, tab, or item.",
            }
            choices = {
                operation: operation_descriptions.get(
                    operation, operation.replace("_", " ").lower()
                )
                for operation in sorted(candidates)
            }
            operation, score = reasoner.classify_semantic(
                semantic_text, "semantic_operation", choices
            )
            confidence = min(group_score, score)
            if confidence < 0.60:
                return None
            semantic_operation = SemanticOperation(operation)
            if mode == RequestMode.OBSERVE_AND_ANSWER:
                return semantic_operation, ObjectType.CONTROL, None, confidence

            object_groups = {
                "APP": {"APP"},
                "UI": {"CONTROL", "SETTING", "FORM", "FIELD", "GENERIC_UI_OBJECT"},
                "CONTENT": {"EMAIL", "EMAIL_DRAFT", "MESSAGE", "DOCUMENT", "NOTE"},
                "FILESYSTEM": {"FILE", "FOLDER"},
                "WEB": {"WEB_PAGE", "TAB"},
                "MEDIA": {"MEDIA_PLAYBACK"},
            }
            object_group_descriptions = {
                "APP": "An installed Mac application such as Finder, Notes, or a browser.",
                "UI": "A visible interface button, microphone control, toggle, setting, form, or field.",
                "CONTENT": "An email, draft, message, note, or document being created or edited.",
                "FILESYSTEM": "A file or folder stored in Finder or another file manager.",
                "WEB": "A browser tab, web page, or search result.",
                "MEDIA": "Music, video, or other media that is playing or paused.",
            }
            object_group, object_score = reasoner.classify_semantic(
                semantic_text, "semantic_object_group", object_group_descriptions
            )
            object_choices = object_groups.get(object_group, set())
            if not object_choices:
                return None
            if len(object_choices) == 1:
                object_type = ObjectType(next(iter(object_choices)))
            else:
                type_choices = {
                    value: value.replace("_", " ").lower() for value in sorted(object_choices)
                }
                selected_type, type_score = reasoner.classify_semantic(
                    semantic_text, "semantic_object_type", type_choices
                )
                confidence = min(confidence, object_score, type_score)
                if confidence < 0.60:
                    return None
                object_type = ObjectType(selected_type)
            confidence = min(confidence, object_score)
            if confidence < 0.60:
                return None

            desired = None
            if semantic_operation == SemanticOperation.SET_STATE:
                state_groups = {
                    "TOGGLE": {"ENABLED", "DISABLED", "MUTED", "UNMUTED"},
                    "PLAYBACK": {"PLAYING", "PAUSED"},
                    "SELECTION": {"CHECKED", "UNCHECKED"},
                    "VISIBILITY": {"OPEN", "CLOSED"},
                    "DELIVERY": {"DRAFT", "SENT"},
                }
                state_group_descriptions = {
                    "TOGGLE": (
                        "A control's on/off or enabled/disabled state. This includes privacy "
                        "requests to stop or prevent a microphone from listening, recording, "
                        "capturing, or transmitting audio, as well as mute/unmute."
                    ),
                    "PLAYBACK": "Media or music is playing, paused, or resumed.",
                    "SELECTION": "A checkbox or option is checked or unchecked.",
                    "VISIBILITY": "An app, page, tab, or item is open or closed.",
                    "DELIVERY": "A message or document is a draft or has been sent.",
                }
                state_group, state_group_score = reasoner.classify_semantic(
                    semantic_text, "semantic_state_group", state_group_descriptions
                )
                states = state_groups.get(state_group, set())
                if not states:
                    return None
                if len(states) == 1:
                    desired = DesiredState(next(iter(states)))
                    confidence = min(confidence, state_group_score)
                    if confidence < 0.60:
                        return None
                else:
                    state_choices = {value: value.lower() for value in sorted(states)}
                    selected_state, state_score = reasoner.classify_semantic(
                        semantic_text, "semantic_desired_state", state_choices
                    )
                    confidence = min(confidence, state_group_score, state_score)
                    if confidence < 0.60:
                        return None
                    desired = DesiredState(selected_state)
            return semantic_operation, object_type, desired, confidence
        except Exception:  # noqa: BLE001 -- model failures must become an unresolved plan
            return None
