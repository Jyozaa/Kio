"""Application runtime: direct router first, explicit target, lazy reusable Laya."""

import ast
import asyncio
import math
import operator
import os
import re
import time
from contextlib import AsyncExitStack, asynccontextmanager, suppress
from dataclasses import replace

from .chooser import LayaChooser
from .direct import (
    DirectCommand,
    ensure_app_ready,
    execute_direct,
    normalize_url,
    parse_direct,
    resolve_app,
    site_homepage,
)
from .driver import CuaDriver, DriverError
from .goal_compiler import GoalCompiler, IntentKind
from .loop import AgentLoop, LoopResult
from .metrics import record, timed
from .perception import (
    CompositePerceptionProvider,
    CuaVisualPerceptionProvider,
    PerceptionContext,
    StructuredBrowserPerceptionProvider,
    StructuredPerceptionProvider,
)
from .semantic_planner import RequestMode, SemanticOperation, SemanticTaskPlanner
from .session_context import SessionContext
from .surface import SurfaceResolver
from .system2 import GeminiSystem2
from .target_resolver import TargetResolver, TaskExecutionContext
from .ui_inspector import ObservationAnswer, UIInspector, UIQuestionAnswerer

_FORCE_AX_TARGET = "__kio_force_ax__"


def _semantic_execution_plan(original: str, semantic, fallback):
    """Adapt structured semantic steps without discarding their parameters."""
    from .goal_compiler import GoalStep, TaskPlan
    from .semantic_planner import ObjectType, SemanticOperation, SemanticStep

    if not semantic.steps:
        return fallback
    steps = []
    opened = set()
    navigated_to_page = False
    normalized = semantic.normalized or original
    for item in semantic.steps:
        app = item.application_hint.strip()
        clause = item.source_clause.strip() or normalized
        if item.operation == SemanticOperation.OPEN and app:
            steps.append(
                GoalStep(
                    IntentKind.ENSURE_APP,
                    goal=item.source_clause.strip() or f"Open {app}",
                    application=app,
                    semantic_step=item,
                )
            )
            opened.add(app.casefold())
            continue
        if item.operation == SemanticOperation.NEW_TAB:
            if (
                app
                and app.casefold() not in opened
                and app.casefold()
                not in {
                    "new tab",
                    "a new tab",
                }
            ):
                steps.append(
                    GoalStep(
                        IntentKind.ENSURE_APP,
                        goal=item.source_clause.strip() or f"Open {app}",
                        application=app,
                        semantic_step=item,
                    )
                )
                opened.add(app.casefold())
            steps.append(GoalStep(IntentKind.NEW_TAB, goal="Open a new tab", semantic_step=item))
            continue
        if (
            app
            and app.casefold() not in opened
            and item.operation
            in {
                SemanticOperation.CREATE,
                SemanticOperation.SEARCH,
                SemanticOperation.SET_STATE,
                SemanticOperation.ACTIVATE_CONTROL_ONCE,
                SemanticOperation.TYPE,
                SemanticOperation.SET_FIELD,
                SemanticOperation.SELECT,
                SemanticOperation.CUSTOM_UI_GOAL,
            }
        ):
            steps.append(GoalStep(IntentKind.ENSURE_APP, goal=f"Open {app}", application=app))
            opened.add(app.casefold())
        if item.operation == SemanticOperation.SEARCH:
            query = item.parameters.get("query", "").strip()
            scope = item.parameters.get("search_scope", "GLOBAL_WEB")
            if (
                scope in {"CURRENT_SITE", "NAMED_SITE", "APP_CONTENT", "LOCAL_CONTENT"}
                or navigated_to_page
            ):
                steps.append(
                    GoalStep(
                        IntentKind.CONTINUE_UI_GOAL,
                        goal=f"Search for {query} on the current page" if query else clause,
                        semantic_step=item,
                    )
                )
            else:
                steps.append(
                    GoalStep(
                        IntentKind.WEB_SEARCH,
                        goal=f"Search Google for {query}" if query else normalized,
                        semantic_step=item,
                    )
                )
        elif item.operation == SemanticOperation.CREATE and item.object_type == "EMAIL_DRAFT":
            create_step = SemanticStep(
                SemanticOperation.CREATE,
                item.application_hint,
                ObjectType.EMAIL_DRAFT,
                item.object_label,
                {},
                constraints=item.constraints,
                completion_conditions=item.completion_conditions,
            )
            steps.append(
                GoalStep(
                    IntentKind.CONTINUE_UI_GOAL,
                    goal="Open a new email draft",
                    semantic_step=create_step,
                )
            )
        elif item.operation == SemanticOperation.CREATE and item.object_type == "NOTE":
            create_step = SemanticStep(
                SemanticOperation.CREATE,
                item.application_hint,
                ObjectType.NOTE,
                item.object_label,
                {},
                completion_conditions=item.completion_conditions,
            )
            steps.append(
                GoalStep(
                    IntentKind.CONTINUE_UI_GOAL,
                    goal="Create a new note",
                    semantic_step=create_step,
                )
            )
        elif item.operation == SemanticOperation.TYPE and item.object_type == ObjectType.FIELD:
            field_name = item.parameters.get("field", "field")
            value = item.parameters.get("text", "")
            target_name = {
                "recipient": "the To field",
                "body": "the message body",
                "title": "the note title",
            }.get(field_name, f"the {item.object_label or field_name} field")
            steps.append(
                GoalStep(
                    IntentKind.CONTINUE_UI_GOAL,
                    goal=f'Type "{value}" into {target_name}',
                    semantic_step=item,
                )
            )
        elif item.operation == SemanticOperation.SET_FIELD:
            field_name = item.parameters.get("field", "field")
            value = item.parameters.get("text", "")
            target_name = {
                "recipient": "the To field",
                "body": "the message body",
                "title": "the title field",
                "subject": "the subject field",
            }.get(field_name, f"the {field_name} field")
            steps.append(
                GoalStep(
                    IntentKind.CONTINUE_UI_GOAL,
                    goal=f'Type "{value}" into {target_name}',
                    semantic_step=item,
                )
            )
        elif item.operation == SemanticOperation.CREATE and item.object_type == ObjectType.FOLDER:
            name = item.parameters.get("name", "")
            goal = f'Create a folder named "{name}"' if name else "Create a folder"
            steps.append(GoalStep(IntentKind.CONTINUE_UI_GOAL, goal=goal, semantic_step=item))
        elif item.operation == SemanticOperation.FIND:
            if item.object_type == ObjectType.FILE:
                constraints = " and ".join(item.constraints)
                goal = f"Find {item.object_label or 'the requested file'}"
                if constraints:
                    goal += f" ({constraints})"
            else:
                goal = normalized
            steps.append(GoalStep(IntentKind.CONTINUE_UI_GOAL, goal=goal, semantic_step=item))
        elif item.operation == SemanticOperation.ATTACH:
            steps.append(
                GoalStep(
                    IntentKind.CONTINUE_UI_GOAL, goal="Attach the selected file", semantic_step=item
                )
            )
        elif item.operation == SemanticOperation.SEND:
            steps.append(
                GoalStep(IntentKind.CONTINUE_UI_GOAL, goal="Send the email", semantic_step=item)
            )
        elif item.operation == SemanticOperation.MOVE:
            filename = item.parameters.get("file", "")
            destination = item.parameters.get("destination", "")
            goal = f'Move file "{filename}" into folder "{destination}"'
            steps.append(GoalStep(IntentKind.CONTINUE_UI_GOAL, goal=goal, semantic_step=item))
        elif item.operation == SemanticOperation.SELECT and item.object_type == ObjectType.WEB_PAGE:
            steps.append(
                GoalStep(
                    IntentKind.CONTINUE_UI_GOAL,
                    goal="Open the Wikipedia result",
                    semantic_step=item,
                )
            )
        elif item.operation == SemanticOperation.NAVIGATE:
            url = item.parameters.get("url", "")
            navigated_to_page = bool(url)
            steps.append(
                GoalStep(
                    IntentKind.OPEN_URL,
                    goal=f"Open {url}" if url else normalized,
                    semantic_step=item,
                )
            )
        elif item.operation == SemanticOperation.CAPTURE:
            steps.append(
                GoalStep(
                    IntentKind.CONTINUE_UI_GOAL,
                    goal="Take a picture",
                    semantic_step=item,
                )
            )
        elif item.operation in {
            SemanticOperation.SET_STATE,
            SemanticOperation.ACTIVATE_CONTROL_ONCE,
            SemanticOperation.CUSTOM_UI_GOAL,
        }:
            goal = clause
            if item.operation == SemanticOperation.SET_STATE and item.object_label == "microphone":
                goal = (
                    "Mute the microphone"
                    if item.desired_state and item.desired_state.value == "MUTED"
                    else "Unmute the microphone"
                )
            elif (
                item.operation == SemanticOperation.SET_STATE
                and item.object_type == ObjectType.MEDIA_PLAYBACK
            ):
                goal = (
                    "Pause the song"
                    if item.desired_state and item.desired_state.value == "PAUSED"
                    else "Play the song"
                )
            elif item.operation == SemanticOperation.ACTIVATE_CONTROL_ONCE:
                target = item.parameters.get("target", item.object_label).strip()
                goal = f"Press {target}" if target else clause
            steps.append(GoalStep(IntentKind.CONTINUE_UI_GOAL, goal=goal, semantic_step=item))
        else:
            # Newly classified operations without a dedicated adapter retain
            # their typed step while using the ordinary bounded UI loop.
            steps.append(
                GoalStep(
                    IntentKind.CONTINUE_UI_GOAL,
                    goal=clause,
                    semantic_step=item,
                )
            )
    if not steps:
        return fallback
    return TaskPlan(original, normalized, tuple(steps), semantic_plan=semantic)


def _contextualize_generic_search(semantic, session_context):
    """Use a recently verified browser page for an otherwise unqualified search."""
    searches = [step for step in semantic.steps if step.operation == SemanticOperation.SEARCH]
    if len(searches) != 1:
        return semantic
    step = searches[0]
    if (
        step.application_hint
        or step.parameters.get("search_scope") != "GLOBAL_WEB"
        or re.search(
            r"\b(?:google|the web|internet|online)\b",
            semantic.original_text,
            re.IGNORECASE,
        )
    ):
        return semantic
    session_context.expire_if_stale()
    app = session_context.recent_app
    page = normalize_url(session_context.current_page)
    recent_page = session_context.recent_page
    if (
        not page
        or not session_context.current_window
        or not app
        or not app.is_browser
        or app.bundle_id != session_context.current_bundle_id
        or not recent_page
        or normalize_url(recent_page.url) != page
    ):
        return semantic
    updated_step = replace(
        step,
        parameters={**step.parameters, "search_scope": "CURRENT_SITE"},
    )
    return replace(
        semantic,
        steps=tuple(updated_step if item is step else item for item in semantic.steps),
    )


def task_windows(windows):
    """Exclude tiny tooltips and non-content layers; never guess between real windows."""
    return [
        w
        for w in windows
        if w.get("is_on_screen")
        and w.get("on_current_space", True)
        and w.get("layer", 0) == 0
        and w.get("bounds", {}).get("width", 100) >= 100
        and w.get("bounds", {}).get("height", 80) >= 80
    ]


class Runtime:
    def __init__(self):
        self.chooser = None
        self.system2 = GeminiSystem2.from_environment()
        self.last_target_window_id = None
        self.session_context = SessionContext()
        self.semantic_planner = SemanticTaskPlanner()
        self.target_resolver = TargetResolver()
        self._driver_stack: AsyncExitStack | None = None
        self._driver = None
        self._driver_lock = asyncio.Lock()
        self._chooser_load: asyncio.Task | None = None

    def _start_chooser_load(self):
        if self.chooser is None and self._chooser_load is None:
            self._chooser_load = asyncio.create_task(self._load_chooser())
            self._chooser_load.add_done_callback(self._retain_loaded_chooser)

    async def _load_chooser(self):
        started = time.perf_counter()
        try:
            return await asyncio.to_thread(LayaChooser)
        finally:
            record("laya_cold_load", time.perf_counter() - started)

    def _retain_loaded_chooser(self, task):
        if self._chooser_load is not task:
            return
        try:
            self.chooser = task.result()
            self._chooser_load = None
        except Exception:  # noqa: BLE001 -- model availability is reported only when needed
            self._chooser_load = None

    async def _get_chooser(self):
        if self.chooser is not None:
            return self.chooser
        self._start_chooser_load()
        task = self._chooser_load
        if task is None:
            raise RuntimeError("Laya load could not be started")
        chooser = await task
        if self.chooser is None:
            self.chooser = chooser
        return self.chooser

    @asynccontextmanager
    async def _connected_driver(self):
        """Reuse one MCP connection for this helper lifetime; never reuse task observations."""
        await self._driver_lock.acquire()
        try:
            if self._driver is None:
                stack = AsyncExitStack()
                try:
                    started = time.perf_counter()
                    driver = await stack.enter_async_context(CuaDriver.connect())
                    record("cua_connect", time.perf_counter() - started)
                except BaseException:
                    await stack.aclose()
                    raise
                self._driver_stack = stack
                self._driver = driver
            driver = self._driver
            try:
                yield driver
            except DriverError as error:
                if error.transport_failure and self._driver is driver:
                    stack = self._driver_stack
                    self._driver = None
                    self._driver_stack = None
                    if stack is not None:
                        with suppress(Exception):
                            await stack.aclose()
                raise
        finally:
            self._driver_lock.release()

    async def close(self):
        """Release the long-lived MCP connection when the helper shuts down."""
        async with self._driver_lock:
            stack = self._driver_stack
            self._driver = None
            self._driver_stack = None
            if stack is not None:
                await stack.aclose()

    async def _recover_task_window(self, driver, app, context, goal, cancelled):
        """Resolve one fresh same-app window after a stale/off-Space observation."""
        apps = (await driver.apps()).get("apps", [])
        live_app = TargetResolver._by_identity(
            apps, context.bundle_id, context.pid, context.window_id
        )
        if not live_app:
            return None
        pid = live_app.get("pid")
        if not isinstance(pid, int) or pid <= 0:
            return None
        windows = (await driver.windows(pid)).get("windows", [])
        selected = SurfaceResolver.resolve_window(
            windows, goal, last_target_window_id=context.window_id
        ).window
        if selected is None:
            ready = await ensure_app_ready(live_app, driver, cancelled)
            if ready.get("status") != "completed" or not isinstance(ready.get("pid"), int):
                return None
            pid = ready["pid"]
            live_app = {**live_app, "pid": pid}
            windows = (await driver.windows(pid)).get("windows", [])
            selected = next(
                (
                    window
                    for window in windows
                    if window.get("window_id") == ready.get("window_id")
                    and window.get("is_on_screen") is True
                    and window.get("on_current_space", True) is True
                ),
                None,
            )
        if selected is None:
            return None
        context.bind_app(live_app, selected.get("window_id"))
        self.session_context.record_target(live_app, selected.get("window_id"))
        return live_app, pid, selected

    @staticmethod
    def _calculate(expression: str) -> str | None:
        """Evaluate a small arithmetic grammar; never use eval or arbitrary code."""
        try:
            root = ast.parse(expression, mode="eval")
            if len(list(ast.walk(root))) > 24:
                return None

            def visit(node):
                if isinstance(node, ast.Expression):
                    return visit(node.body)
                if isinstance(node, ast.Constant) and type(node.value) in (int, float):
                    return node.value
                if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
                    value = visit(node.operand)
                    return value if isinstance(node.op, ast.UAdd) else -value
                if isinstance(node, ast.BinOp):
                    left, right = visit(node.left), visit(node.right)
                    operations = {
                        ast.Add: operator.add,
                        ast.Sub: operator.sub,
                        ast.Mult: operator.mul,
                        ast.Div: operator.truediv,
                    }
                    function = operations.get(type(node.op))
                    if function is None:
                        raise ValueError
                    return function(left, right)
                raise ValueError

            result = visit(root)
            if (
                not isinstance(result, (int, float))
                or not math.isfinite(result)
                or abs(result) > 1e15
            ):
                return None
            return str(int(result)) if int(result) == result else f"{result:.8g}"
        except (SyntaxError, ValueError, TypeError, ZeroDivisionError, OverflowError):
            return None

    @staticmethod
    def _mentioned_app(text: str, apps: list[dict]) -> dict | None:
        matches = []
        for app in apps:
            name = str(app.get("name", "")).strip()
            if not name or not app.get("bundle_id"):
                continue
            pattern = rf"(?<![\w]){re.escape(name)}(?![\w])"
            if re.search(pattern, text, re.IGNORECASE):
                matches.append((len(name), app))
        return max(matches, key=lambda value: value[0])[1] if matches else None

    async def _answer_only(self, semantic, cancelled) -> LoopResult:
        if cancelled.is_set():
            return LoopResult("cancelled", "Stopped.", 0, "answer_only")
        courtesy = GoalCompiler().compile(semantic.original_text).normalized.casefold().strip()
        if re.fullmatch(
            r"(?:thanks|thank you|thanks a lot|that's all|that is all)[.!?]*", courtesy
        ):
            answer = ObservationAnswer("You're welcome.", 1.0, "Kio", "", ("courtesy",))
            return LoopResult("answered", "You're welcome.", 0, "answer_only", answer=answer)
        step = semantic.steps[0] if semantic.steps else None
        if step and step.operation == SemanticOperation.CALCULATE:
            value = self._calculate(step.parameters.get("expression", ""))
            if value is not None:
                answer = ObservationAnswer(
                    value,
                    1.0,
                    "Kio",
                    "",
                    ("local_arithmetic", step.parameters.get("expression", "")),
                )
                return LoopResult("answered", value, 0, "answer_only", answer=answer)
        return LoopResult(
            "needs_user",
            "I can't answer that from local information yet.",
            0,
            "answer_only",
        )

    async def _inspect_and_answer(self, semantic, goal, target, cancelled, emit) -> LoopResult:
        if cancelled.is_set():
            return LoopResult("cancelled", "Stopped.", 0, "read_only_ui")
        emit("observing", "Checking the current window…")
        async with self._connected_driver() as driver:
            await driver.health()
            apps = (await driver.apps()).get("apps", [])
            app = self.target_resolver.resolve(
                semantic,
                apps,
                explicit_target=target if target != _FORCE_AX_TARGET else "",
                session_context=self.session_context,
                semantic_step=semantic.steps[0] if semantic.steps else None,
            ).app
            if not app:
                return LoopResult(
                    "needs_user",
                    "I couldn't identify which open app to inspect.",
                    0,
                    "read_only_ui",
                )
            # Read-only questions may inspect an already-running app, but must
            # never launch, activate, or foreground it as a side effect.
            if app.get("running") is not True:
                return LoopResult(
                    "needs_user",
                    f"Open {app.get('name', 'the requested app')} and ask again so I can inspect its current window.",
                    0,
                    "read_only_ui",
                )
            pid = app.get("pid")
            if not isinstance(pid, int):
                return LoopResult(
                    "needs_user", "The requested app has no inspectable window.", 0, "read_only_ui"
                )
            windows = task_windows((await driver.windows(pid)).get("windows", []))
            resolution = SurfaceResolver.resolve_window(
                windows, goal, last_target_window_id=self.last_target_window_id
            )
            if resolution.window is None:
                return LoopResult(
                    "needs_user",
                    "I couldn't identify one visible window to inspect.",
                    0,
                    "read_only_ui",
                )
            window = resolution.window
            structured = StructuredPerceptionProvider(driver)
            if callable(getattr(driver, "browser_state", None)):
                structured = StructuredBrowserPerceptionProvider(
                    driver,
                    structured,
                    probe_non_browser=False,
                    prepare_on_consent=False,
                )
            perception = CompositePerceptionProvider(
                structured,
                CuaVisualPerceptionProvider(driver) if hasattr(driver, "capture") else None,
            )
            try:
                result = await perception.perceive(
                    PerceptionContext(
                        goal,
                        pid,
                        window["window_id"],
                        semantic_step=semantic.steps[0] if semantic.steps else None,
                    )
                )
                inspection = UIInspector().inspect(
                    result.observation, app=str(app.get("name", "App")), window=window
                )
                answer = UIQuestionAnswerer().answer(goal, inspection)
            finally:
                close = getattr(structured, "close", None)
                if callable(close):
                    await close()
        if answer is None:
            app_name = str(app.get("name", "the app"))
            answer = ObservationAnswer(
                f"I can't confidently identify that in the current {app_name} window.",
                0.0,
                app_name,
                str(window.get("title", "Current window")),
                tuple(
                    f"perception_source={source}" for source in inspection.perception_sources[:4]
                ),
            )
        return LoopResult("answered", answer.answer, 0, "read_only_ui", answer=answer)

    async def _run_sequential_plan(self, plan, target, cancelled, emit):
        """Execute every validated step in order; never silently drop a tail step."""
        async with self._connected_driver() as driver:
            await driver.health()
            context = TaskExecutionContext()
            app_inventory = (await driver.apps()).get("apps", [])
            initial_resolution = self.target_resolver.resolve(
                plan.semantic_plan,
                app_inventory,
                explicit_target=target if target != _FORCE_AX_TARGET else "",
                session_context=self.session_context,
                execution_context=context,
            )
            if initial_resolution.app and initial_resolution.app.get("running") is True:
                context.bind_app(initial_resolution.app)
            final = LoopResult("completed", "Done.", 0, "sequential")
            verified_evidence = []
            for step in plan.steps:
                if cancelled.is_set():
                    return LoopResult("cancelled", "Stopped.", final.steps, "sequential")
                if step.kind == IntentKind.STOP:
                    return LoopResult("cancelled", "Stopped.", final.steps, "sequential")
                if step.kind == IntentKind.ENSURE_APP:
                    inventory = (await driver.apps()).get("apps", [])
                    resolution = self.target_resolver.resolve(
                        plan.semantic_plan,
                        inventory,
                        explicit_target=step.application,
                        session_context=self.session_context,
                        execution_context=context,
                        semantic_step=step.semantic_step,
                    )
                    requested = resolution.app
                    if not requested:
                        requested = resolve_app(step.application, inventory)
                    if not requested:
                        return LoopResult(
                            "needs_user",
                            "I couldn't find the requested app.",
                            final.steps,
                            "sequential",
                        )
                    site_url = (
                        site_homepage(step.application)
                        if resolution.source == "named_site_browser"
                        else None
                    )
                    command = (
                        DirectCommand("url", site_url, str(requested.get("name", "")))
                        if site_url
                        else DirectCommand("app", str(requested.get("name", step.application)))
                    )
                    result = await execute_direct(
                        command,
                        driver,
                        cancelled,
                    )
                    if result["status"] != "completed":
                        return LoopResult(
                            result["status"],
                            "The requested app could not be opened.",
                            final.steps,
                            "sequential",
                        )
                    verified_evidence.extend(result.get("evidence", ()))
                    apps_after = (await driver.apps()).get("apps", [])
                    app = next(
                        (item for item in apps_after if item.get("pid") == result.get("pid")),
                        None,
                    ) or resolve_app(step.application, apps_after)
                    if app:
                        context.bind_app(app, result.get("window_id"))
                        self.session_context.record_target(app, result.get("window_id"))
                        if step.semantic_step is not None:
                            self.session_context.record_semantic_step(
                                step.semantic_step, app, result.get("window_id")
                            )
                        if site_url:
                            self.session_context.record_goal(
                                step.goal,
                                "completed",
                                url=result.get("url") or site_url,
                            )
                    continue
                command = (
                    parse_direct(step.goal)
                    if step.kind in {IntentKind.WEB_SEARCH, IntentKind.OPEN_URL}
                    else None
                )
                if command:
                    if command.kind == "url" and not command.application_name:
                        inventory = (await driver.apps()).get("apps", [])
                        browser = self.target_resolver.resolve(
                            plan.semantic_plan,
                            inventory,
                            explicit_target=target if target != _FORCE_AX_TARGET else "",
                            session_context=self.session_context,
                            execution_context=context,
                            semantic_step=step.semantic_step,
                        ).app
                        if browser and self.target_resolver.is_browser(browser):
                            command = DirectCommand(
                                "url", command.value, str(browser.get("name", ""))
                            )
                    result = await execute_direct(
                        command,
                        driver,
                        cancelled,
                        allow_browser_prepare=target != _FORCE_AX_TARGET,
                    )
                    if result["status"] == "browser_authorization_required":
                        return LoopResult(
                            "needs_user",
                            "[KIO_BROWSER_ACCESS_REQUIRED] Kio needs one-time browser access to work directly with this browser.",
                            final.steps,
                            "direct",
                        )
                    if result["status"] != "completed":
                        return LoopResult(
                            result["status"],
                            "The requested step could not be completed.",
                            final.steps,
                            "sequential",
                        )
                    verified_evidence.extend(result.get("evidence", ()))
                    if isinstance(result.get("pid"), int):
                        apps_after = (await driver.apps()).get("apps", [])
                        target_app = TargetResolver._by_identity(
                            apps_after,
                            next(
                                (
                                    str(item.get("bundle_id", ""))
                                    for item in apps_after
                                    if item.get("pid") == result.get("pid")
                                ),
                                "",
                            ),
                            result.get("pid"),
                            result.get("window_id"),
                        )
                        if target_app:
                            context.bind_app(target_app, result.get("window_id"))
                    url = result.get("url", "")
                    if url:
                        self.session_context.record_goal(step.goal, "completed", url=url)
                    if step.semantic_step is not None and context.resolved_app:
                        self.session_context.record_semantic_step(
                            step.semantic_step, context.resolved_app, context.window_id
                        )
                    final = LoopResult("completed", "Done.", final.steps, "sequential")
                    continue

                apps = (await driver.apps()).get("apps", [])
                resolution = self.target_resolver.resolve(
                    plan.semantic_plan,
                    apps,
                    explicit_target=target if target != _FORCE_AX_TARGET else "",
                    session_context=self.session_context,
                    execution_context=context,
                    semantic_step=step.semantic_step,
                )
                app = resolution.app
                if not app:
                    return LoopResult(
                        "needs_user",
                        "I couldn't identify a usable app for that step.",
                        final.steps,
                        "sequential",
                    )
                same_task_app = context.bundle_id == app.get("bundle_id")
                pid = context.pid if same_task_app and context.pid is not None else app.get("pid")
                if not isinstance(pid, int) or pid <= 0:
                    return LoopResult(
                        "needs_user",
                        "I couldn't identify a live app process.",
                        final.steps,
                        "sequential",
                    )
                windows = (await driver.windows(pid)).get("windows", [])
                current = (
                    next(
                        (
                            window
                            for window in windows
                            if window.get("window_id") == context.window_id
                            and window.get("is_on_screen") is True
                            and window.get("on_current_space", True) is True
                        ),
                        None,
                    )
                    if same_task_app
                    else None
                )
                if current is None:
                    window_resolution = SurfaceResolver.resolve_window(
                        windows,
                        step.goal,
                        last_target_window_id=context.window_id if same_task_app else None,
                    )
                    selected = window_resolution.window
                    if selected is None:
                        ready = await ensure_app_ready(app, driver, cancelled)
                        if ready.get("status") != "completed":
                            return LoopResult(
                                "needs_user",
                                "I couldn't bring the requested app window forward.",
                                final.steps,
                                "sequential",
                            )
                        pid = ready.get("pid")
                        context.bind_app({**app, "pid": pid}, ready.get("window_id"))
                        windows = (await driver.windows(pid)).get("windows", []) if pid else []
                        selected = next(
                            (
                                window
                                for window in windows
                                if window.get("window_id") == ready.get("window_id")
                                and window.get("is_on_screen") is True
                                and window.get("on_current_space", True) is True
                            ),
                            None,
                        )
                    if selected is None:
                        return LoopResult(
                            "needs_user",
                            "I couldn't identify a usable content window.",
                            final.steps,
                            "sequential",
                        )
                    current = selected
                context.bind_app({**app, "pid": pid}, current.get("window_id"))
                self.session_context.record_target(app, current.get("window_id"))
                if self.chooser is None:
                    emit("deciding", "Loading local Laya…")
                    await self._get_chooser()
                for recovery_attempt in range(2):
                    loop = AgentLoop(driver, self.chooser, system2=self.system2, emit=emit)
                    try:
                        final = await loop.run(
                            step.goal,
                            pid,
                            current["window_id"],
                            cancelled,
                            semantic_step=step.semantic_step,
                            task_constraints=getattr(plan.semantic_plan, "constraints", ()),
                            effect_ledger=context.effect_ledger,
                        )
                    finally:
                        close = getattr(loop, "close", None)
                        if callable(close):
                            await close()
                    operation = str(
                        getattr(getattr(step.semantic_step, "operation", None), "value", "")
                    )
                    safe_to_replan = operation in {
                        "TYPE",
                        "SET_FIELD",
                        "SET_STATE",
                        "FIND",
                        "SEARCH",
                        "NAVIGATE",
                    }
                    if (
                        recovery_attempt == 0
                        and not cancelled.is_set()
                        and safe_to_replan
                        and final.status == "error"
                        and final.reason in {"stale_state", "target_missing", "window_off_space"}
                    ):
                        recovered = await self._recover_task_window(
                            driver, app, context, step.goal, cancelled
                        )
                        if recovered:
                            app, pid, current = recovered
                            emit("observing", "The app changed; checking its current window…")
                            continue
                    break
                if final.status != "completed":
                    return final
                verified_evidence.extend(final.evidence)
                if step.semantic_step is not None:
                    self.session_context.record_semantic_step(
                        step.semantic_step, app, current.get("window_id")
                    )
                self.session_context.record_goal(step.goal, "completed")
            return LoopResult(
                final.status,
                final.reason,
                final.steps,
                final.path,
                final.gemini_calls,
                tuple(verified_evidence),
                final.answer,
            )

    @timed("runtime_task")
    async def run(
        self,
        goal: str,
        target: str = "",
        cancelled: asyncio.Event | None = None,
        emit=None,
    ) -> LoopResult:
        cancelled = cancelled or asyncio.Event()
        emit = emit or (lambda status, text: None)
        if cancelled.is_set():
            return LoopResult("cancelled", "Stopped.", 0, "direct")
        target = target if isinstance(target, str) else ""
        force_ax_browser = target == _FORCE_AX_TARGET
        if force_ax_browser:
            target = ""
        resolved_goal, contextual_command = self.session_context.resolve(goal)
        fast_plan = GoalCompiler().compile(resolved_goal)
        parsed_direct = contextual_command or parse_direct(fast_plan.normalized or resolved_goal)
        if parsed_direct and parsed_direct.kind == "cancel":
            return LoopResult("cancelled", "Stopped.", 0, "direct")

        semantic = self.semantic_planner.plan(resolved_goal)
        if semantic.needs_reasoning and contextual_command is None:
            if self.chooser is None:
                emit("deciding", "Understanding the request…")
                try:
                    await self._get_chooser()
                except Exception:  # noqa: BLE001 -- sanitized by protocol boundary
                    return LoopResult(
                        "needs_user", "I couldn't interpret that request locally.", 0, "semantic"
                    )
            semantic = self.semantic_planner.plan(resolved_goal, reasoner=self.chooser)
            if semantic.unresolved:
                return LoopResult(
                    "needs_user", "I'm not sure what action you want me to take.", 0, "semantic"
                )
        semantic = _contextualize_generic_search(semantic, self.session_context)
        if semantic.request_mode == RequestMode.ANSWER_ONLY:
            return await self._answer_only(semantic, cancelled)
        if semantic.request_mode == RequestMode.OBSERVE_AND_ANSWER:
            return await self._inspect_and_answer(semantic, resolved_goal, target, cancelled, emit)

        # SemanticTaskPlan is authoritative. Regex direct routing only selects a
        # deterministic executor for a typed step; it never replaces the plan.
        plan = _semantic_execution_plan(resolved_goal, semantic, fast_plan)
        if contextual_command is not None and not semantic.steps:
            plan = fast_plan
        normalized_goal = plan.normalized or resolved_goal
        if plan.semantic_plan is not None and semantic.steps:
            task_target = _FORCE_AX_TARGET if force_ax_browser else target
            return await self._run_sequential_plan(plan, task_target, cancelled, emit)
        if not plan.steps:
            return LoopResult("needs_user", "I couldn't identify a safe computer-use action.", 0)

        step = plan.steps[0]
        semantic_step = step.semantic_step
        command = contextual_command
        if command is None:
            if step.kind == IntentKind.STOP:
                command = DirectCommand("cancel")
            elif step.kind == IntentKind.ENSURE_APP:
                command = DirectCommand("app", step.application)
            elif step.kind in {IntentKind.WEB_SEARCH, IntentKind.OPEN_URL}:
                command = parse_direct(step.goal)
            elif plan.semantic_plan is None:
                command = parse_direct(normalized_goal)
        if command and command.kind == "cancel":
            return LoopResult("cancelled", "Stopped.", 0, "direct")

        async with self._connected_driver() as driver:
            await driver.health()
            if cancelled.is_set():
                return LoopResult("cancelled", "Stopped.", 0)
            if command:
                if command.kind == "app":
                    inventory = (await driver.apps()).get("apps", [])
                    requested = self.target_resolver.resolve(
                        semantic,
                        inventory,
                        explicit_target=target,
                        session_context=self.session_context,
                        semantic_step=semantic_step,
                    ).app
                    if requested:
                        command = DirectCommand("app", str(requested.get("name", command.value)))
                elif command.kind == "url" and not command.application_name:
                    inventory = (await driver.apps()).get("apps", [])
                    browser = self.target_resolver.resolve(
                        semantic,
                        inventory,
                        explicit_target=target,
                        session_context=self.session_context,
                        semantic_step=semantic_step,
                    ).app
                    if browser and self.target_resolver.is_browser(browser):
                        command = DirectCommand("url", command.value, str(browser.get("name", "")))
                emit(
                    "opening_app" if command.kind == "app" else "navigating",
                    "Opening app…" if command.kind == "app" else "Opening the requested page…",
                )
                result = await execute_direct(
                    command,
                    driver,
                    cancelled,
                    allow_browser_prepare=not force_ax_browser,
                )
                if result["status"] == "browser_authorization_required":
                    return LoopResult(
                        "needs_user",
                        "[KIO_BROWSER_ACCESS_REQUIRED] Kio needs one-time browser access to work directly with this browser.",
                        0,
                        "direct",
                    )
                apps_after = (await driver.apps()).get("apps", [])
                app = None
                if result["status"] == "completed" and command.kind == "app":
                    app = TargetResolver._by_identity(
                        apps_after,
                        next(
                            (
                                str(item.get("bundle_id", ""))
                                for item in apps_after
                                if item.get("name", "").casefold() == command.value.casefold()
                            ),
                            "",
                        ),
                        result.get("pid"),
                        result.get("window_id"),
                    ) or resolve_app(command.value, apps_after)
                elif result["status"] == "completed" and command.application_name:
                    app = resolve_app(command.application_name, apps_after)
                if app:
                    app = {**app, "pid": result.get("pid") or app.get("pid")}
                    self.session_context.record_target(app, result.get("window_id"))
                    self.last_target_window_id = result.get("window_id")
                if result["status"] == "completed" and semantic_step is not None and app:
                    self.session_context.record_semantic_step(
                        semantic_step, app, result.get("window_id")
                    )
                self.session_context.record_goal(goal, result["status"], url=result.get("url", ""))
                return LoopResult(
                    result["status"],
                    "Done."
                    if result["status"] == "completed"
                    else "I couldn't complete that step.",
                    0,
                    "direct",
                    evidence=result.get("evidence", ()),
                )

            apps = (await driver.apps()).get("apps", [])
            resolution = self.target_resolver.resolve(
                semantic,
                apps,
                explicit_target=target,
                session_context=self.session_context,
                semantic_step=semantic_step,
            )
            app = resolution.app
            if not app:
                reason = (
                    "I couldn't find the app you named."
                    if resolution.reason
                    in {"explicit_app_unavailable", "explicit_target_unavailable"}
                    else "I couldn't tell which open app or window you meant."
                )
                return LoopResult("needs_user", reason, 0, "target_resolution")
            pid = app.get("pid") if app.get("running") else None
            context = TaskExecutionContext()
            if not isinstance(pid, int) or pid <= 0:
                ready = await ensure_app_ready(app, driver, cancelled)
                if ready.get("status") != "completed":
                    return LoopResult(
                        "needs_user",
                        "I couldn't open a usable window for that app.",
                        0,
                        "target_resolution",
                    )
                pid = ready.get("pid")
                context.bind_app({**app, "pid": pid}, ready.get("window_id"))
            windows = (await driver.windows(pid)).get("windows", []) if isinstance(pid, int) else []
            selected = next(
                (
                    window
                    for window in windows
                    if context.window_id is not None
                    and window.get("window_id") == context.window_id
                    and window.get("is_on_screen") is True
                    and window.get("on_current_space", True) is True
                ),
                None,
            )
            if selected is None:
                window_resolution = SurfaceResolver.resolve_window(
                    windows,
                    step.goal,
                    last_target_window_id=(
                        self.session_context.current_window
                        if self.session_context.current_bundle_id == app.get("bundle_id")
                        else self.last_target_window_id
                    ),
                )
                selected = window_resolution.window
            if selected is None:
                ready = await ensure_app_ready(app, driver, cancelled)
                if ready.get("status") == "completed" and isinstance(ready.get("pid"), int):
                    pid = ready["pid"]
                    windows = (await driver.windows(pid)).get("windows", [])
                    selected = next(
                        (
                            window
                            for window in windows
                            if window.get("window_id") == ready.get("window_id")
                            and window.get("is_on_screen") is True
                            and window.get("on_current_space", True) is True
                        ),
                        None,
                    )
            if selected is None or not isinstance(pid, int):
                return LoopResult(
                    "needs_user", "I couldn't identify a usable app window.", 0, "target_resolution"
                )
            context.bind_app({**app, "pid": pid}, selected.get("window_id"))
            self.session_context.record_target(app, selected.get("window_id"))
            self.last_target_window_id = selected.get("window_id")
            if self.chooser is None:
                emit("deciding", "Loading local Laya…")
                await self._get_chooser()
            if cancelled.is_set():
                return LoopResult("cancelled", "Stopped.", 0)
            from .trajectories import TrajectoryRecorder

            recorder = (
                TrajectoryRecorder(goal) if os.getenv("KIO_RECORD_TRAJECTORIES") == "1" else None
            )
            loop = AgentLoop(
                driver, self.chooser, system2=self.system2, emit=emit, recorder=recorder
            )
            result = await loop.run(
                step.goal,
                pid,
                selected["window_id"],
                cancelled,
                semantic_step=semantic_step,
                task_constraints=getattr(semantic, "constraints", ()),
            )
            close = getattr(loop, "close", None)
            if callable(close):
                await close()
            if result.status == "completed":
                self.session_context.record_semantic_step(
                    semantic_step, app, selected.get("window_id")
                ) if semantic_step is not None else None
                self.last_target_window_id = selected.get("window_id")
            self.session_context.record_goal(goal, result.status)
            return result

    async def health(self):
        try:
            async with self._connected_driver() as driver:
                await driver.health()
            # The installed host starts health on launch. Warm one local model
            # only when the app supplied its verified manifest; never block
            # direct actions or create a second instance while loading.
            if os.environ.get("KIO_MODEL_MANIFEST"):
                self._start_chooser_load()
            return "ready"
        except DriverError as error:
            return error.code
