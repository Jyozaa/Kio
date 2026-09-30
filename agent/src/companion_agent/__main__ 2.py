"""Versioned NDJSON helper; --demo is explicitly inert, default uses the real runtime."""

import argparse
import asyncio
import logging
import re
import sys
from dataclasses import asdict

from .protocol import MAX_LINE_BYTES, Message, decode


def emit(message: Message) -> None:
    print(message.encode(), end="", flush=True)


def user_facing_driver_error(code: str) -> str:
    return {
        "permission_missing": "Kio needs Accessibility permission to use that app.",
        "driver_unavailable": "Kio couldn't complete that computer-use step. Try again.",
        "runtime_unavailable": "The computer-use runtime isn't ready yet. Try again in a moment.",
        "runtime_transport_lost": "Kio lost its connection to the computer-use runtime. Retry after it reconnects.",
        "request_timeout": "That computer-use request took too long. I couldn't confirm its result.",
        "stale_state": "The app changed while Kio was working. Try again.",
        "target_missing": "I couldn't find a usable window in that app.",
        "window_off_space": "I couldn't bring that app window forward. Try selecting it and asking again.",
        "ambiguous_target": "I couldn't tell which app window you meant.",
        "process_ambiguous": "I couldn't tell which running instance of that app you meant.",
        "foreground_unverified": "I couldn't bring that app window forward. Try again.",
        "unsupported": "That interaction isn't available in this app yet.",
        "chooser_unavailable": "I couldn't identify the right control. Try again.",
        "invalid_decision": "I couldn't identify the right control. Try again.",
        "model_missing": "The local action model isn't ready. Open Kio Setup to repair it.",
        "action_failed": "Kio couldn't complete that step. Try again.",
    }.get(code, "Kio couldn't complete that request. Try again.")


async def demo(task_id: str) -> None:
    try:
        emit(Message("event", task_id, "Looking at the page… (demo)", "observing"))
        await asyncio.sleep(2)
        emit(Message("event", task_id, "Finishing demo…", "working"))
        await asyncio.sleep(1)
        emit(Message("result", task_id, "Done. (demo; no computer actions)", "completed"))
    except asyncio.CancelledError:
        emit(Message("result", task_id, "Stopped.", "cancelled"))


async def serve(demo_mode: bool = True) -> None:
    from .driver import DriverError
    from .runtime import Runtime

    runtime = None if demo_mode else Runtime()
    cancelled = asyncio.Event()

    async def run_task(message):
        try:
            result = await runtime.run(
                message.text,
                message.target,
                cancelled,
                lambda status, text: emit(Message("event", message.task_id, text, status)),
            )
            if result.answer is not None:
                emit(
                    Message(
                        "answer",
                        message.task_id,
                        result.answer.answer,
                        "answered",
                        answer=asdict(result.answer),
                    )
                )
            elif result.status == "error":
                code = (
                    result.reason
                    if re.fullmatch(r"[a-z][a-z0-9_]{0,79}", result.reason)
                    else "action_failed"
                )
                emit(
                    Message(
                        "error",
                        message.task_id,
                        user_facing_driver_error(code),
                        "error",
                        error_code=code,
                    )
                )
            else:
                emit(Message("result", message.task_id, result.reason, result.status))
        except DriverError as error:
            code = "runtime_transport_lost" if error.transport_failure else error.code
            emit(
                Message(
                    "error",
                    message.task_id,
                    user_facing_driver_error(code),
                    "error",
                    error_code=code,
                )
            )
        except Exception:  # noqa: BLE001 -- protocol boundary must not leak private provider errors
            emit(
                Message(
                    "error",
                    message.task_id,
                    "Kio couldn't complete that request. Try again.",
                    "error",
                    error_code="runtime_unavailable",
                )
            )

    active: asyncio.Task | None = None
    active_id = ""
    used: set[str] = set()
    try:
        while True:
            line = await asyncio.to_thread(sys.stdin.buffer.readline, MAX_LINE_BYTES + 1)
            if not line:
                break
            if len(line) > MAX_LINE_BYTES or not line.endswith(b"\n"):
                emit(
                    Message(
                        "error", "protocol", "Oversized or incomplete message.", "protocol_error"
                    )
                )
                break
            try:
                message = decode(line.decode("utf-8"))
            except (ValueError, UnicodeError, TypeError):
                emit(Message("error", "protocol", "Malformed protocol message.", "protocol_error"))
                continue
            if message.kind == "health":
                emit(
                    Message(
                        "health",
                        message.task_id,
                        "Demo helper ready." if demo_mode else "Agent health check.",
                        "ready" if demo_mode else await runtime.health(),
                    )
                )
            elif message.kind == "approve":
                emit(
                    Message(
                        "error",
                        message.task_id,
                        "Approval messages are deprecated and unsupported.",
                        "unsupported",
                    )
                )
            elif message.kind == "cancel":
                if active and not active.done() and active_id == message.task_id:
                    cancelled.set()
                    if demo_mode:
                        active.cancel()
                        await active
            elif message.kind == "command":
                if active and not active.done():
                    emit(Message("error", message.task_id, "A task is already running.", "busy"))
                elif message.task_id in used:
                    emit(
                        Message(
                            "error", message.task_id, "Duplicate task identifier.", "duplicate_task"
                        )
                    )
                elif not message.text.strip():
                    emit(Message("error", message.task_id, "Enter a goal.", "invalid_goal"))
                else:
                    used.add(message.task_id)
                    active_id = message.task_id
                    cancelled.clear()
                    active = asyncio.create_task(
                        demo(active_id) if demo_mode else run_task(message)
                    )
            else:
                emit(
                    Message(
                        "error", message.task_id, "Unexpected inbound message.", "protocol_error"
                    )
                )
    finally:
        if active and not active.done():
            cancelled.set()
            if demo_mode:
                active.cancel()
            await active
        if runtime is not None:
            await runtime.close()


def main() -> None:
    from .storage import application_support

    application_support()
    logging.basicConfig(level=logging.WARNING)
    logging.getLogger("companion_agent").setLevel(logging.INFO)
    parser = argparse.ArgumentParser()
    parser.add_argument("--demo", action="store_true", help="Run the phase-2 inert helper")
    args = parser.parse_args()
    asyncio.run(serve(demo_mode=args.demo))


if __name__ == "__main__":
    main()
