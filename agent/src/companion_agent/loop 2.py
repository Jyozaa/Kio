"""Bounded observe/decide/verify/act loop with no model-supplied execution authority."""

import asyncio
import math
import os
import re
import time
from collections import Counter
from dataclasses import dataclass

from .candidates import (
    Operation,
    build_candidates,
    is_site_search_field,
    normalize,
    rebind_semantic_target,
)
from .chooser import Chooser
from .driver import DriverError
from .metrics import record, timed
from .objectives import EffectClass, EffectLedger, current_objective
from .perception import (
    CompositePerceptionProvider,
    CuaVisualPerceptionProvider,
    PerceptionContext,
    StructuredBrowserPerceptionProvider,
    StructuredPerceptionProvider,
)
from .policy import ActionPolicy, Disposition, PolicyContext, literal_text
from .surface import CapabilityRouter, SurfaceResolver
from .system2 import validate_response
from .ui_inspector import ObservationAnswer
from .verification import Evidence, GoalVerifier, VerificationStatus, semantic_expectations


@dataclass(frozen=True)
class LoopResult:
    status: str
    reason: str
    steps: int
    path: str = "laya_loop"
    gemini_calls: int = 0
    evidence: tuple[Evidence, ...] = ()
    answer: ObservationAnswer | None = None


def _effect_for_step(semantic_step, operation, observation=None):
    semantic_operation = str(getattr(getattr(semantic_step, "operation", None), "value", ""))
    if semantic_operation == "ACTIVATE_CONTROL_ONCE":
        return EffectClass.EDGE_TRIGGERED_ONCE
    if semantic_operation == "SET_STATE":
        return EffectClass.STATE_TRANSITION
    if semantic_operation in {"CREATE", "COPY"}:
        return EffectClass.OBJECT_CREATE
    if semantic_operation in {"OPEN", "NAVIGATE", "NEW_TAB"}:
        return EffectClass.NAVIGATION
    if semantic_operation in {"SEND", "ATTACH"}:
        return EffectClass.EXTERNAL_COMMIT
    if semantic_operation in {"DELETE", "CLOSE"}:
        return EffectClass.DESTRUCTIVE
    if semantic_operation in {"EDIT", "MOVE", "RENAME", "SAVE", "TYPE", "SET_FIELD"}:
        return EffectClass.CONTENT_WRITE
    if semantic_operation in {"FIND", "LOCATE", "DESCRIBE", "READ", "CALCULATE"}:
        return EffectClass.READ_ONLY
    if semantic_operation == "SELECT":
        return EffectClass.STATE_TRANSITION
    if semantic_operation == "CAPTURE":
        return EffectClass.EDGE_TRIGGERED_ONCE
    if semantic_operation == "SEARCH":
        if operation == Operation.TYPE_TEXT:
            return EffectClass.CONTENT_WRITE
        query = str((getattr(semantic_step, "parameters", {}) or {}).get("query", "")).casefold()
        query_entered = observation and any(
            element.visible
            and is_site_search_field(element)
            and (element.value or "").casefold() == query
            for element in observation.elements
        )
        return EffectClass.NAVIGATION if query_entered else EffectClass.STATE_TRANSITION
    return None


def success_proven(goal, observation, text):
    return (
        GoalVerifier(generated_text=text).check(goal, observation, observation, []).status
        == VerificationStatus.VERIFIED
    )


async def active_dialog_window(driver, pid: int, base_window_id: int) -> int:
    """Follow a compact foreground native dialog, then return to the content window."""
    list_windows = getattr(driver, "windows", None)
    if not callable(list_windows):
        return base_window_id
    try:
        windows_result = await list_windows(pid)
    except DriverError as error:
        if error.transport_failure:
            raise
        return base_window_id
    windows = windows_result.get("windows", [])
    base = next((w for w in windows if w.get("window_id") == base_window_id), None)
    if not base:
        return base_window_id
    base_bounds = base.get("bounds", {})
    base_area = max(1.0, base_bounds.get("width", 0) * base_bounds.get("height", 0))
    base_z = base.get("z_index", -1)
    candidates = sorted(
        (
            w
            for w in windows
            if w.get("window_id") != base_window_id
            and w.get("is_on_screen") is True
            and w.get("on_current_space") is True
            and w.get("z_index", -1) > base_z
            and w.get("bounds", {}).get("width", float("inf")) <= 700
            and w.get("bounds", {}).get("height", float("inf")) <= 500
            and w.get("bounds", {}).get("width", 0) * w.get("bounds", {}).get("height", 0)
            < base_area * 0.5
        ),
        key=lambda w: w.get("z_index", -1),
        reverse=True,
    )[:8]
    for window in candidates:
        try:
            observation = normalize(await driver.observe(pid, window["window_id"]))
        except DriverError as error:
            if error.transport_failure:
                raise
            continue
        if any(e.native.get("in_system_dialog") is True for e in observation.elements):
            return window["window_id"]
    return base_window_id


def deterministic_capture_action(table, semantic_step):
    """Use an exact typed capture request only when AX exposes one shutter control."""
    operation = str(getattr(getattr(semantic_step, "operation", None), "value", ""))
    object_type = str(getattr(getattr(semantic_step, "object_type", None), "value", ""))
    if operation != "CAPTURE" or object_type != "PHOTO":
        return None
    candidates = [
        action
        for action in table.actions.values()
        if action.operation == Operation.CLICK and action.payload.get("visual") is not True
    ]
    if len(candidates) != 1:
        return None
    element = next(
        (item for item in table.observation.elements if item.id == candidates[0].element_id), None
    )
    if element is None:
        return None
    words = set(re.findall(r"\w+", element.label.casefold()))
    if not (words & {"take", "capture", "shutter"}) or not (
        words & {"photo", "picture", "photograph", "shutter"}
    ):
        return None
    return candidates[0]


class AgentLoop:
    def __init__(
        self,
        driver,
        chooser: Chooser,
        *,
        min_confidence=None,
        max_steps=None,
        emit=None,
        system2=None,
        perception=None,
        recorder=None,
    ):
        structured = StructuredPerceptionProvider(driver)
        if callable(getattr(driver, "browser_state", None)):
            structured = StructuredBrowserPerceptionProvider(
                driver, structured, probe_non_browser=False
            )
        self.perception = perception or CompositePerceptionProvider(
            structured,
            CuaVisualPerceptionProvider(driver) if hasattr(driver, "capture") else None,
        )
        self.recorder = recorder
        self.surface_resolver = SurfaceResolver()
        self.capability_router = CapabilityRouter()
        self.system2 = system2
        self.driver = driver
        self.chooser = chooser
        self.min_confidence = (
            float(os.getenv("DECISION_MIN_CONFIDENCE", "0.55"))
            if min_confidence is None
            else min_confidence
        )
        self.max_steps = (
            int(os.getenv("MAX_ACTION_STEPS", "50")) if max_steps is None else max_steps
        )
        if (
            not math.isfinite(self.min_confidence)
            or not 0 <= self.min_confidence <= 1
            or not 1 <= self.max_steps <= 500
        ):
            raise ValueError("Invalid loop configuration")
        self.emit = emit or (lambda status, text: None)

    async def close(self):
        """Release task-scoped provider sessions without touching user state."""
        close = getattr(self.perception.structured, "close", None)
        if callable(close):
            await close()

    @timed("task_total")
    async def run(
        self,
        goal: str,
        pid: int,
        window_id: int,
        cancelled: asyncio.Event,
        *,
        semantic_step=None,
        task_constraints=(),
        effect_ledger: EffectLedger | None = None,
    ) -> LoopResult:
        history = []
        seen = Counter()
        semantic_operation = str(getattr(getattr(semantic_step, "operation", None), "value", ""))
        parameters = getattr(semantic_step, "parameters", {}) or {}
        text = (
            str(parameters.get("query", ""))
            if semantic_operation == "SEARCH" and parameters.get("query")
            else literal_text(goal)
        )
        effect_ledger = effect_ledger or EffectLedger()
        step_id = str(getattr(semantic_step, "step_id", "task"))
        steps = 0
        guidance = ""
        initial = None
        failed_done = 0
        recovery_decisions = 0
        verification = None
        perception_result = None
        recovery_used = False
        local_recovery_used = False
        system2_start_calls = self.system2.calls if self.system2 else 0

        def finish(status, reason):
            calls = (self.system2.calls - system2_start_calls) if self.system2 else 0
            if self.recorder:
                self.recorder.finish(status, reason, verification, calls)
            return LoopResult(
                status,
                reason,
                steps,
                gemini_calls=calls,
                evidence=verification.evidence if verification else (),
            )

        async def recover(observation):
            nonlocal recovery_used, guidance
            if not self.system2 or recovery_used:
                return False
            recovery_used = True
            if self.recorder:
                self.recorder.used_gemini()
            self.emit("deciding", "Requesting one high-level hint…")
            data = await self.system2.guide(
                goal, [e.label for e in observation.elements if e.visible and e.enabled][:10]
            )
            guidance = validate_response(data, "guidance")["focus"]
            seen.clear()
            return True

        for _ in range(self.max_steps):
            if cancelled.is_set():
                return finish("cancelled", "Stopped.")
            self.emit("observing", "Looking at the page…")
            observed_at = time.perf_counter()
            active_window_id = await active_dialog_window(self.driver, pid, window_id)
            perception_result = await self.perception.perceive(
                PerceptionContext(goal, pid, active_window_id, semantic_step=semantic_step)
            )
            perception_seconds = time.perf_counter() - observed_at
            observation = perception_result.observation
            surface = self.surface_resolver.resolve(
                observation,
                driver=getattr(self.driver, "capabilities", None),
                browser_actions_ready=any(
                    e.source == "STRUCTURED_BROWSER" for e in observation.elements
                ),
                visual_result=perception_result,
            )
            route = self.capability_router.route(surface)
            if cancelled.is_set():
                return finish("cancelled", "Stopped.")
            if initial is None:
                initial = observation
            verification = await GoalVerifier(
                semantic_expectations(semantic_step), generated_text=text
            ).verify(goal, initial, observation, history)
            if self.recorder:
                self.recorder.observe(observation, verification)
            if verification.status == VerificationStatus.VERIFIED:
                return finish("completed", "Verified the requested state.")
            claimed_effect = _effect_for_step(semantic_step, Operation.CLICK)
            if semantic_operation == "ACTIVATE_CONTROL_ONCE" and effect_ledger.attempted(
                step_id, EffectClass.EDGE_TRIGGERED_ONCE
            ):
                return finish(
                    "completed",
                    "Activated the requested control once; the resulting state could not be independently verified.",
                )
            if (
                claimed_effect
                and claimed_effect != EffectClass.READ_ONLY
                and effect_ledger.attempted(step_id, claimed_effect)
                and not (
                    semantic_operation == "SEARCH"
                    and claimed_effect == EffectClass.STATE_TRANSITION
                )
            ):
                return finish(
                    "needs_user",
                    "The action was performed once, but its requested result could not be verified.",
                )
            if semantic_operation == "CAPTURE" and steps:
                return finish("needs_user", "I couldn't verify that a photo was captured.")
            seen[observation.fingerprint()] += 1
            if seen[observation.fingerprint()] >= 3:
                choose_recovery = getattr(self.chooser, "choose_recovery", None)
                if recovery_decisions == 0 and callable(choose_recovery):
                    recovery_decisions += 1
                    try:
                        recovery, confidence = await asyncio.to_thread(
                            choose_recovery,
                            goal,
                            observation,
                            history[-6:],
                            "same_observation_repeated",
                        )
                    except DriverError:
                        recovery, confidence = "NEEDS_USER", 0.0
                    if confidence >= self.min_confidence and recovery in {
                        "WAIT_FOR_TRANSITION",
                        "REOBSERVE",
                    }:
                        history.append(f"Laya recovery hint: {recovery}.")
                        seen.clear()
                        if recovery == "WAIT_FOR_TRANSITION":
                            try:
                                await asyncio.wait_for(cancelled.wait(), 0.2)
                            except TimeoutError:
                                pass
                        continue
                try:
                    if await recover(observation):
                        continue
                except DriverError as error:
                    code = "runtime_transport_lost" if error.transport_failure else error.code
                    return finish("error" if error.transport_failure else "needs_user", code)
                return finish("needs_user", "No progress after repeated observations.")
            objective = current_objective(goal, observation, history[-6:])
            allowed_operations = {
                "SET_STATE": {Operation.CLICK},
                "ACTIVATE_CONTROL_ONCE": {Operation.CLICK},
                "TYPE": {Operation.TYPE_TEXT},
                "SET_FIELD": {Operation.TYPE_TEXT},
                "SELECT": {Operation.SELECT},
                "CREATE": {Operation.CLICK},
                "CAPTURE": {Operation.CLICK},
                "NEW_TAB": {Operation.CLICK},
                "SEND": {Operation.CLICK},
                "DELETE": {Operation.CLICK},
            }.get(semantic_operation)
            if semantic_operation == "SEARCH":
                query = str(parameters.get("query", "")).casefold()
                search_fields = [
                    element
                    for element in observation.elements
                    if element.visible and element.enabled and is_site_search_field(element)
                ]
                query_is_entered = any(
                    (element.value or "").casefold() == query for element in search_fields
                )
                if (
                    effect_ledger.attempted(step_id, EffectClass.STATE_TRANSITION)
                    and not query_is_entered
                    and not search_fields
                ):
                    return finish(
                        "needs_user",
                        "The visually focused search control did not expose a fresh editable field; I did not type without structured authority.",
                    )
                if effect_ledger.attempted(step_id, EffectClass.NAVIGATION):
                    return finish(
                        "needs_user",
                        "The search submission was attempted once, but the results could not be independently verified.",
                    )
                if query_is_entered:
                    allowed_operations = {Operation.CLICK}
                elif search_fields:
                    allowed_operations = {Operation.TYPE_TEXT}
                else:
                    allowed_operations = {Operation.CLICK}
            table = build_candidates(
                observation,
                objective,
                visual_frame=perception_result.frame,
                allowed_operations=allowed_operations,
                semantic_step=semantic_step,
            )
            self.emit("deciding", "Choosing the next bounded action…")
            effect = None
            try:
                if cancelled.is_set():
                    return finish("cancelled", "Stopped.")
                action = deterministic_capture_action(table, semantic_step)
                decision = None
                if (
                    action is None
                    and semantic_step is not None
                    and callable(getattr(self.chooser, "choose_structured", None))
                ):
                    decision = await asyncio.to_thread(
                        self.chooser.choose_structured,
                        objective,
                        table,
                        history[-6:],
                        guidance,
                        semantic_step,
                    )
                elif action is None:
                    if self.chooser is None:
                        return finish(
                            "needs_user", "I couldn't reliably identify the right control."
                        )
                    decision = await asyncio.to_thread(
                        self.chooser.choose, objective, table, history[-6:], guidance
                    )
                if action is None:
                    if cancelled.is_set():
                        return finish("cancelled", "Stopped.")
                    action = table.validate(decision.candidate_id, decision.snapshot_id)
                if self.recorder and decision is not None:
                    self.recorder.decision(
                        objective,
                        table,
                        decision,
                        history[-6:],
                        guidance,
                        perception_result,
                        {"perception": perception_seconds},
                    )
                if decision is not None:
                    if (
                        action.operation != decision.operation
                        or type(decision.confidence) not in (int, float)
                        or not math.isfinite(decision.confidence)
                        or not 0 <= decision.confidence <= 1
                    ):
                        raise DriverError("invalid_decision")
                    if decision.confidence < self.min_confidence:
                        if await recover(observation):
                            continue
                        if not recovery_used and not local_recovery_used:
                            local_recovery_used = True
                            history.append(
                                "The first selection was below the confidence threshold; refresh state and rebuild the semantic candidates once."
                            )
                            self.emit("observing", "Checking the window again…")
                            continue
                        return finish(
                            "needs_user",
                            "I couldn't reliably identify the right control after a fresh check.",
                        )
                policy = ActionPolicy().evaluate(
                    PolicyContext(
                        goal,
                        action,
                        observation,
                        history=tuple(history),
                        semantic_constraints=tuple(task_constraints)
                        + tuple(getattr(semantic_step, "constraints", ())),
                    )
                )
                if policy.disposition == Disposition.BLOCK:
                    return finish("needs_user", policy.reason)
                if action.operation == Operation.DONE:
                    failed_done += 1
                    if verification.status == VerificationStatus.NOT_VERIFIED and failed_done < 3:
                        history.append("DONE rejected: requested outcome is not yet observed.")
                        continue
                    if verification.status == VerificationStatus.UNKNOWN:
                        choose_goal_state = getattr(self.chooser, "choose_goal_state", None)
                        if callable(choose_goal_state):
                            try:
                                goal_state, _ = await asyncio.to_thread(
                                    choose_goal_state,
                                    goal,
                                    table,
                                    history[-6:],
                                    verification.status.value,
                                )
                            except DriverError:
                                goal_state = "UNCERTAIN"
                            # Model confidence is never completion evidence. A
                            # NOT_SATISFIED hint may justify one fresh observation.
                            if goal_state == "NOT_SATISFIED" and failed_done < 3:
                                history.append(
                                    "Laya goal-state hint: NOT_SATISFIED; verifier remains UNKNOWN."
                                )
                                continue
                    if verification.status == VerificationStatus.UNKNOWN and await recover(
                        observation
                    ):
                        continue
                    return finish("needs_user", "Completion could not be independently verified.")
                if action.operation == Operation.BLOCKED:
                    return finish("needs_user", "The local chooser could not proceed.")
                if action.operation in {Operation.WAIT, Operation.REOBSERVE}:
                    self.emit("waiting", "Waiting for fresh state…")
                    try:
                        await asyncio.wait_for(cancelled.wait(), 0.2)
                    except TimeoutError:
                        pass
                    continue
                if action.operation == Operation.TYPE_TEXT and text is None:
                    if self.system2 is None or not re.search(
                        r"\b(write|compose|draft|generate)\b", goal, re.IGNORECASE
                    ):
                        return finish("needs_user", "Text generation needs Gemini configuration.")
                    if self.recorder:
                        self.recorder.used_gemini()
                    generated = await self.system2.generate(goal, action.description[:100])
                    text = validate_response(generated, "generated_text")["text"]
                    # Reobserve and decide again after generation; never retain stale authority.
                    continue
                # Reobserve immediately before execution. Rebind the same target
                # semantically and use only authority from this fresh observation.
                current_window_id = await active_dialog_window(self.driver, pid, window_id)
                if current_window_id != active_window_id:
                    history.append(
                        "Foreground dialog changed before execution; discarded decision."
                    )
                    continue
                fresh_result = await self.perception.perceive(
                    PerceptionContext(goal, pid, active_window_id, semantic_step=semantic_step)
                )
                if (fresh_result.observation.pid, fresh_result.observation.window_id) != (
                    observation.pid,
                    observation.window_id,
                ):
                    history.append(
                        "The target app or window changed before execution; discarded the decision."
                    )
                    continue
                if action.payload.get("visual") is True and (
                    fresh_result.frame is None
                    or not fresh_result.frame.native_capture_id
                    or fresh_result.frame.native_capture_id == action.payload.get("capture_id")
                ):
                    history.append(
                        "Fresh visual capture was unavailable; discarded the stale region."
                    )
                    continue
                fresh = fresh_result.observation
                replacement = build_candidates(
                    fresh,
                    objective,
                    visual_frame=fresh_result.frame,
                    allowed_operations=allowed_operations,
                    semantic_step=semantic_step,
                )
                rebound = rebind_semantic_target(action, replacement)
                if rebound is None:
                    replacement.discard()
                    raise DriverError("stale_state")
                if cancelled.is_set():
                    replacement.discard()
                    return finish("cancelled", "Stopped.")
                fresh_policy = ActionPolicy().evaluate(
                    PolicyContext(
                        goal,
                        rebound,
                        fresh,
                        history=tuple(history),
                        semantic_constraints=tuple(task_constraints)
                        + tuple(getattr(semantic_step, "constraints", ())),
                    )
                )
                if fresh_policy.disposition == Disposition.BLOCK:
                    replacement.discard()
                    return finish("needs_user", fresh_policy.reason)
                execution = replacement.take([rebound.id], fresh.snapshot_id)
                self.emit(
                    "typing" if action.operation == Operation.TYPE_TEXT else "clicking",
                    "Typing…"
                    if action.operation == Operation.TYPE_TEXT
                    else "Activating a verified control…",
                )
                action_started = time.perf_counter()
                effect = _effect_for_step(semantic_step, execution.operation, fresh)
                if (
                    effect
                    and effect != EffectClass.READ_ONLY
                    and not effect_ledger.claim(step_id, effect, maximum=1)
                ):
                    return finish(
                        "completed" if effect == EffectClass.EDGE_TRIGGERED_ONCE else "needs_user",
                        "The effect limit for this semantic step has already been reached.",
                    )
                await self.driver.execute(execution, text=text)
                if effect and effect != EffectClass.READ_ONLY:
                    effect_ledger.finish(step_id, effect, "dispatched")
                action_seconds = time.perf_counter() - action_started
                record(f"{route.value}_action", action_seconds)
                if self.recorder:
                    self.recorder.acted(action_seconds)
                steps += 1
                progress_target = action.payload.get("goal_target")
                history.append(
                    f"{action.operation.value}: {progress_target} (visual OCR target)"
                    if action.payload.get("visual") is True
                    and isinstance(progress_target, str)
                    and progress_target
                    else f"{action.operation.value}: {action.description[:120]}"
                )
                if cancelled.is_set():
                    return finish("cancelled", "Stopped.")
            except DriverError as error:
                if error.code == "stale_state":
                    if effect is not None:
                        effect_ledger.release_not_dispatched(step_id, effect)
                    continue
                code = "runtime_transport_lost" if error.transport_failure else error.code
                return finish("error", code)
            finally:
                table.discard()
        return finish("needs_user", "Action step limit reached.")

    @timed("fresh_observation")
    async def _fresh(self, goal, pid, window_id):
        return (await self.perception.perceive(PerceptionContext(goal, pid, window_id))).observation
