"""Small deterministic conversational context; never grants execution authority."""

import re
import time
from dataclasses import dataclass, field

from .direct import DirectCommand, normalize_url
from .policy import literal_text

_MAX_ENTITIES = 8
_MAX_RECENT_URLS = 5
_CONTEXT_TTL_SECONDS = 600


@dataclass
class RecentAppRef:
    name: str
    bundle_id: str
    pid: int | None = None
    window_id: int | None = None
    is_browser: bool = False


@dataclass
class RecentWindowRef:
    app: RecentAppRef
    window_id: int
    title: str = ""


@dataclass
class RecentObjectRef:
    type: str
    app: RecentAppRef
    window_id: int | None
    semantic_label: str = ""
    creation_step_id: str = ""
    validity: str = "verified"


@dataclass
class RecentPageRef:
    url: str
    app: RecentAppRef | None = None
    window_id: int | None = None


@dataclass
class RecentFileRef:
    path: str
    app: RecentAppRef | None = None


@dataclass
class SessionContext:
    current_app: str = ""
    current_bundle_id: str = ""
    current_pid: int | None = None
    current_window: int | None = None
    current_page: str = ""
    last_completed_goal: str = ""
    last_created_object_type: str = ""
    last_selected_object: str = ""
    last_entered_text: str = ""
    recent_named_entities: list[str] = field(default_factory=list)
    recent_urls: list[str] = field(default_factory=list)
    recent_target_apps: list[str] = field(default_factory=list)
    recent_app: RecentAppRef | None = None
    recent_window: RecentWindowRef | None = None
    recent_object: RecentObjectRef | None = None
    recent_page: RecentPageRef | None = None
    recent_file: RecentFileRef | None = None
    updated_at: float = field(default_factory=time.monotonic)

    def reset(self) -> None:
        self.__dict__.update(SessionContext().__dict__)

    def expire_if_stale(self, now: float | None = None) -> None:
        current = time.monotonic() if now is None else now
        if current - self.updated_at > _CONTEXT_TTL_SECONDS:
            self.reset()
            self.updated_at = current

    def validate_target(self, apps: list[dict], now: float | None = None) -> bool:
        """Forget app/window semantics if the remembered target has closed."""
        self.expire_if_stale(now)
        if not self.current_bundle_id:
            return False
        live = any(
            item.get("bundle_id") == self.current_bundle_id
            and item.get("running") is True
            and (self.current_pid is None or item.get("pid") == self.current_pid)
            for item in apps
        )
        if not live:
            self.current_app = self.current_bundle_id = self.current_page = ""
            self.current_pid = self.current_window = None
            self.recent_app = self.recent_window = None
            if self.recent_object is not None:
                self.recent_object.validity = "needs_regrounding"
                self.recent_object.window_id = None
            else:
                self.last_created_object_type = ""
            self.last_selected_object = ""
            self.last_entered_text = ""
            if self.recent_page is not None:
                self.recent_page.window_id = None
        return live

    def contextual_target(self, goal: str, apps: list[dict], now: float | None = None) -> str:
        if not self.validate_target(apps, now):
            return ""
        folded = goal.casefold().strip()
        last_opened_current_app = bool(
            re.fullmatch(
                rf"open\s+{re.escape(self.current_app)}[.!]?",
                self.last_completed_goal,
                re.IGNORECASE,
            )
        )
        needs_context = (
            bool(re.search(r"\b(it|that|this|there|one|new one)\b", folded))
            or bool(re.fullmatch(r"search\s+.+", folded))
            or bool(re.fullmatch(r"(?:call|name)\s+it\s+.+", folded))
            or last_opened_current_app
        )
        return self.current_app if needs_context else ""

    def resolve(self, goal: str) -> tuple[str, DirectCommand | None]:
        """Resolve only common references from this bounded context."""
        self.expire_if_stale()
        text = goal.strip()
        folded = text.casefold()
        if re.fullmatch(
            r"(?:start over|new topic|forget (?:that|this)|reset context)[.!]?", folded
        ):
            self.reset()
            return text, None

        page_reference = re.fullmatch(
            r"(?:open|go(?:\s+to)?|return to)\s+(?:there|that page|this page)[.!]?",
            text,
            re.IGNORECASE,
        )
        if page_reference and self.current_page:
            return text, DirectCommand("url", self.current_page, self.current_app or None)

        naming = re.fullmatch(r"(?:call|name)\s+it\s+(.+?)\s*[.!]?", text, re.IGNORECASE)
        if naming and self.last_created_object_type:
            name = naming[1].strip().strip("\"“”'")
            if name and len(name) <= 160:
                return f'Type "{name}" into Title field', None

        if self.last_created_object_type:
            typed_reference = re.compile(
                rf"\b(?:this|that)\s+(?:new\s+)?{re.escape(self.last_created_object_type)}\b",
                re.IGNORECASE,
            )
            text, typed_count = typed_reference.subn(
                f"the most recently created {self.last_created_object_type}", text
            )
            reference = re.compile(r"\b(it|that|this|the new one)\b", re.IGNORECASE)
            if typed_count or reference.search(text):
                noun = self.last_created_object_type
                text = reference.sub(f"the most recently created {noun}", text)
                current_app_explicit = bool(
                    self.current_app
                    and re.search(rf"\b{re.escape(self.current_app)}\b", text, re.IGNORECASE)
                )
                if (
                    self.recent_object is not None
                    and self.recent_object.app is not None
                    and self.recent_object.app.name
                    and self.recent_object.app.name.casefold() != self.current_app.casefold()
                    and self.recent_object.app.name.casefold() not in text.casefold()
                    and not current_app_explicit
                ):
                    text = f"{text} in {self.recent_object.app.name}"
        return text, None

    def record_target(self, app: dict, window_id: int | None = None) -> None:
        new_bundle = str(app.get("bundle_id", ""))
        if self.current_bundle_id and new_bundle != self.current_bundle_id:
            self.current_page = ""
        self.current_app = str(app.get("name", ""))[:100]
        self.current_bundle_id = new_bundle[:256]
        self.current_pid = app.get("pid") if isinstance(app.get("pid"), int) else None
        self.current_window = window_id
        self.recent_app = RecentAppRef(
            self.current_app,
            self.current_bundle_id,
            self.current_pid,
            window_id,
            _is_browser_app(app),
        )
        self.recent_window = (
            RecentWindowRef(self.recent_app, window_id) if isinstance(window_id, int) else None
        )
        if self.current_app:
            self.recent_target_apps = _push(self.recent_target_apps, self.current_app, 5)
        self.updated_at = time.monotonic()

    def record_semantic_step(self, step, app: dict, window_id: int | None) -> None:
        """Record bounded typed referents only after orchestration verified a step."""
        from .semantic_planner import SemanticOperation

        self.record_target(app, window_id)
        operation = getattr(step, "operation", None)
        object_type = str(getattr(getattr(step, "object_type", None), "value", ""))
        label = str(getattr(step, "object_label", ""))[:160]
        if operation == SemanticOperation.CREATE and object_type in {
            "NOTE",
            "DOCUMENT",
            "EMAIL_DRAFT",
            "FOLDER",
            "FILE",
        }:
            self.recent_object = RecentObjectRef(
                object_type,
                self.recent_app,
                window_id,
                label,
                str(getattr(step, "step_id", "")),
            )
            self.last_created_object_type = object_type.casefold()
        elif operation == SemanticOperation.SELECT:
            self.last_selected_object = label
        elif operation == SemanticOperation.NAVIGATE:
            url = str(getattr(step, "parameters", {}).get("url", ""))
            normalized = normalize_url(url)
            if normalized:
                self.recent_page = RecentPageRef(normalized, self.recent_app, window_id)
        elif operation == SemanticOperation.SEARCH:
            query = str(getattr(step, "parameters", {}).get("query", ""))
            self.last_entered_text = query[:200]

    def record_goal(self, goal: str, status: str, *, url: str = "") -> None:
        if status == "completed":
            self.last_completed_goal = goal[:400]
            created = re.search(
                r"\b(?:make|create|new)\s+(?:a\s+)?(?:new\s+)?(note|document|event|reminder)\b",
                goal,
                re.IGNORECASE,
            )
            if created:
                self.last_created_object_type = created[1].casefold()
            selected = re.search(r"\b(?:choose|select)\s+(.+?)(?:[.!?]|$)", goal, re.IGNORECASE)
            if selected:
                self.last_selected_object = selected[1][:120].strip()
        entered = literal_text(goal)
        if entered is not None:
            self.last_entered_text = entered[:200]
        for entity in re.findall(r'["“]([^"”]{1,120})["”]', goal):
            self.recent_named_entities = _push(self.recent_named_entities, entity, _MAX_ENTITIES)
        normalized = normalize_url(url)
        if normalized:
            self.current_page = normalized
            self.recent_page = RecentPageRef(normalized, self.recent_app, self.current_window)
            self.recent_urls = _push(self.recent_urls, normalized, _MAX_RECENT_URLS)
        self.updated_at = time.monotonic()


def _push(items: list[str], value: str, limit: int) -> list[str]:
    result = [item for item in items if item.casefold() != value.casefold()]
    result.insert(0, value)
    return result[:limit]


def _is_browser_app(app: dict) -> bool:
    if app.get("is_browser") is True or str(app.get("category", "")).casefold() in {
        "browser",
        "internet",
        "web browser",
    }:
        return True
    from .target_resolver import TargetResolver

    return TargetResolver.is_browser(app)
