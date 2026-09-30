"""Resolve a computer-use target from the live app catalog and task context."""

from __future__ import annotations

import plistlib
import re
from dataclasses import dataclass, field
from pathlib import Path

from .direct import resolve_app, site_homepage
from .objectives import EffectLedger


@dataclass
class TaskExecutionContext:
    """Verified target identity carried across the steps of one task."""

    resolved_app: dict | None = None
    bundle_id: str = ""
    pid: int | None = None
    window_id: int | None = None
    surface_identity: str = ""
    browser_session: str | None = None
    created_objects: dict[str, dict] = field(default_factory=dict)
    selected_objects: dict[str, dict] = field(default_factory=dict)
    effect_ledger: EffectLedger = field(default_factory=EffectLedger)

    def bind_app(self, app: dict, window_id: int | None = None) -> None:
        self.resolved_app = dict(app)
        self.bundle_id = str(app.get("bundle_id", ""))
        self.pid = app.get("pid") if isinstance(app.get("pid"), int) else None
        self.window_id = window_id if isinstance(window_id, int) else None
        self.surface_identity = (
            f"{self.bundle_id}:{self.pid}:{self.window_id}"
            if self.bundle_id and self.pid is not None
            else ""
        )

    def bind_window(self, window_id: int | None) -> None:
        self.window_id = window_id if isinstance(window_id, int) else None
        self.surface_identity = (
            f"{self.bundle_id}:{self.pid}:{self.window_id}"
            if self.bundle_id and self.pid is not None and self.window_id is not None
            else ""
        )


@dataclass(frozen=True)
class TargetResolution:
    app: dict | None
    source: str
    reason: str = ""


class TargetResolver:
    """Use semantic intent first, then live foreground and bounded session refs."""

    def resolve(
        self,
        semantic_plan,
        apps: list[dict],
        *,
        explicit_target: str = "",
        session_context=None,
        execution_context: TaskExecutionContext | None = None,
        semantic_step=None,
    ) -> TargetResolution:
        step = semantic_step or next(
            (item for item in getattr(semantic_plan, "steps", ()) if item is not None), None
        )
        hint = str(
            getattr(step, "application_hint", "")
            or getattr(semantic_plan, "target_application", "")
            or ""
        ).strip()
        if hint:
            app = (
                self._browser_target(apps)
                if hint.casefold() in {"browser", "web browser", "the browser"}
                else resolve_app(hint, apps)
            )
            if app and execution_context and execution_context.bundle_id == app.get("bundle_id"):
                app = (
                    self._by_identity(
                        apps,
                        execution_context.bundle_id,
                        execution_context.pid,
                        execution_context.window_id,
                    )
                    or app
                )
            if app:
                return TargetResolution(app, "semantic_app")
            transcript = str(getattr(semantic_plan, "original_text", ""))
            mentioned = self.mentioned_app(transcript, apps)
            if mentioned:
                return TargetResolution(mentioned, "installed_app_mention")
            if explicit_target.strip():
                explicit = resolve_app(explicit_target, apps)
                if explicit:
                    return TargetResolution(explicit, "explicit_override")
            semantic_steps = tuple(getattr(semantic_plan, "steps", ()))
            opens_named_target = any(
                str(getattr(getattr(item, "operation", None), "value", "")) == "OPEN"
                and str(getattr(item, "application_hint", "")).casefold() == hint.casefold()
                for item in semantic_steps
            )
            named_site = site_homepage(hint) is not None and any(
                str(getattr(getattr(item, "operation", None), "value", "")) == "SEARCH"
                and str((getattr(item, "parameters", {}) or {}).get("search_scope", ""))
                in {"NAMED_SITE", "CURRENT_SITE"}
                and str(getattr(item, "application_hint", "")).casefold() == hint.casefold()
                and (
                    str((getattr(item, "parameters", {}) or {}).get("search_scope", ""))
                    == "NAMED_SITE"
                    or opens_named_target
                )
                for item in semantic_steps
            )
            if named_site:
                browser = self._browser_target(apps)
                if browser:
                    return TargetResolution(browser, "named_site_browser")
            return TargetResolution(None, "semantic_app", "explicit_app_unavailable")

        transcript = str(getattr(semantic_plan, "original_text", ""))
        mentioned = self.mentioned_app(transcript, apps)
        if mentioned:
            return TargetResolution(mentioned, "installed_app_mention")

        if explicit_target.strip():
            app = resolve_app(explicit_target, apps)
            return TargetResolution(
                app, "explicit_override", "" if app else "explicit_target_unavailable"
            )

        if execution_context and execution_context.bundle_id:
            app = self._by_identity(
                apps,
                execution_context.bundle_id,
                execution_context.pid,
                execution_context.window_id,
            )
            if app:
                return TargetResolution(app, "task_context")

        if session_context:
            recent_object = getattr(session_context, "recent_object", None)
            current_object = bool(
                step
                and (
                    getattr(step, "object_label", "").casefold() in {"current_object", "it", "that"}
                    or getattr(getattr(step, "object_type", None), "value", "") == "FIELD"
                )
            )
            if recent_object and current_object:
                recent_app = getattr(recent_object, "app", None)
                app = self._by_identity(
                    apps,
                    getattr(recent_object, "bundle_id", "") or getattr(recent_app, "bundle_id", ""),
                    getattr(recent_object, "pid", None) or getattr(recent_app, "pid", None),
                    getattr(recent_object, "window_id", None),
                )
                if app:
                    return TargetResolution(app, "recent_object")

        operation = str(getattr(getattr(step, "operation", None), "value", ""))
        object_type = str(getattr(getattr(step, "object_type", None), "value", ""))
        web_related = operation in {"SEARCH", "NAVIGATE", "NEW_TAB"} or object_type in {
            "WEB_PAGE",
            "TAB",
        }
        active = [
            app
            for app in apps
            if app.get("running") is True
            and app.get("active") is True
            and self._usable_instance(app)
            and (not web_related or self.is_browser(app))
        ]
        if len(active) == 1:
            return TargetResolution(active[0], "frontmost")
        if len(active) > 1:
            return TargetResolution(None, "ambiguous_frontmost", "multiple_active_apps")

        if session_context:
            transcript = str(getattr(semantic_plan, "original_text", ""))
            session_name = session_context.contextual_target(transcript, apps)
            current_session_app = self._by_identity(
                apps,
                getattr(session_context, "current_bundle_id", ""),
                getattr(session_context, "current_pid", None),
                getattr(session_context, "current_window", None),
            )
            if (
                not session_name
                and web_related
                and current_session_app
                and self.is_browser(current_session_app)
            ):
                session_name = str(current_session_app.get("name", ""))
            session_app = current_session_app if session_name else None
            if session_app and (not web_related or self.is_browser(session_app)):
                return TargetResolution(session_app, "session_app")
            recent = getattr(session_context, "recent_target_apps", ())
            for name in recent:
                candidate = resolve_app(name, apps)
                if candidate and (not web_related or self.is_browser(candidate)):
                    return TargetResolution(candidate, "recent_session_app")

        if execution_context and execution_context.bundle_id:
            app = self._by_identity(
                apps,
                execution_context.bundle_id,
                execution_context.pid,
                execution_context.window_id,
            )
            if app:
                return TargetResolution(app, "task_context")

        if web_related:
            browsers = [app for app in apps if self._usable_instance(app) and self.is_browser(app)]
            running = [app for app in browsers if app.get("running") is True]
            if len(running) == 1:
                return TargetResolution(running[0], "browser_inventory")
            if len(browsers) == 1:
                return TargetResolution(browsers[0], "browser_inventory")
            if len(running) > 1:
                ordered = sorted(
                    running,
                    key=lambda app: str(app.get("last_used") or ""),
                    reverse=True,
                )
                if ordered[0].get("last_used") and ordered[0].get("last_used") != ordered[1].get(
                    "last_used"
                ):
                    return TargetResolution(ordered[0], "most_recent_browser")

        return TargetResolution(None, "unresolved", "no_usable_target_evidence")

    @staticmethod
    def mentioned_app(text: str, apps: list[dict]) -> dict | None:
        matches = []
        for app in apps:
            name = str(app.get("name", "")).strip()
            if name and re.search(rf"(?<![\w]){re.escape(name)}(?![\w])", text, re.IGNORECASE):
                matches.append((len(name), app))
        return max(matches, key=lambda item: item[0])[1] if matches else None

    @staticmethod
    def _usable_instance(app: dict) -> bool:
        return app.get("running") is True or str(app.get("launch_path", "")).endswith(".app")

    @classmethod
    def _by_identity(
        cls,
        apps: list[dict],
        bundle_id: str,
        pid: int | None,
        window_id: int | None,
    ) -> dict | None:
        if not bundle_id:
            return None
        matches = [
            app for app in apps if app.get("bundle_id") == bundle_id and cls._usable_instance(app)
        ]
        if pid is not None:
            exact = [app for app in matches if app.get("pid") == pid]
            if len(exact) == 1:
                return exact[0]
        if window_id is not None:
            owns_window = [
                app
                for app in matches
                if any(
                    window.get("window_id") == window_id
                    for window in app.get("windows", ())
                    if isinstance(window, dict)
                )
            ]
            if len(owns_window) == 1:
                return owns_window[0]
        active = [app for app in matches if app.get("running") and app.get("active") is True]
        if len(active) == 1:
            return active[0]
        running = [app for app in matches if app.get("running") is True]
        if len(running) == 1:
            return running[0]
        return matches[0] if len(matches) == 1 else None

    @staticmethod
    def is_browser(app: dict) -> bool:
        if app.get("is_browser") is True or str(app.get("category", "")).casefold() in {
            "browser",
            "internet",
            "web browser",
        }:
            return True
        launch_path = str(app.get("launch_path", ""))
        if not launch_path.endswith(".app"):
            return False
        info = Path(launch_path) / "Contents" / "Info.plist"
        try:
            with info.open("rb") as stream:
                metadata = plistlib.load(stream)
        except (OSError, plistlib.InvalidFileException, ValueError):
            return False
        schemes = {
            str(scheme).casefold()
            for entry in metadata.get("CFBundleURLTypes", ())
            if isinstance(entry, dict)
            for scheme in entry.get("CFBundleURLSchemes", ())
            if isinstance(scheme, str)
        }
        if not ({"http", "https"} & schemes):
            return False
        # Many desktop apps accept links without being browsers. Require either
        # explicit CUA browser metadata above or native HTML document handling.
        for entry in metadata.get("CFBundleDocumentTypes", ()):
            if not isinstance(entry, dict):
                continue
            extensions = {
                str(extension).casefold()
                for extension in entry.get("CFBundleTypeExtensions", ())
                if isinstance(extension, str)
            }
            content_types = {
                str(content_type).casefold()
                for content_type in entry.get("LSItemContentTypes", ())
                if isinstance(content_type, str)
            }
            if extensions & {"html", "htm", "xhtml"} or content_types & {
                "public.html",
                "public.xhtml",
            }:
                return True
        return False

    @classmethod
    def _browser_target(cls, apps: list[dict]) -> dict | None:
        candidates = [app for app in apps if cls._usable_instance(app) and cls.is_browser(app)]
        running = [app for app in candidates if app.get("running") is True]
        active = [app for app in running if app.get("active") is True]
        if len(active) == 1:
            return active[0]
        if len(running) == 1:
            return running[0]
        if len(candidates) == 1:
            return candidates[0]
        most_recent = sorted(
            candidates,
            key=lambda app: str(app.get("last_used") or ""),
            reverse=True,
        )
        if len(most_recent) == 1 or (
            len(most_recent) > 1
            and most_recent[0].get("last_used")
            and most_recent[0].get("last_used") != most_recent[1].get("last_used")
        ):
            return most_recent[0]
        return None
