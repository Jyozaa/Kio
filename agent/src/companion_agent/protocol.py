"""Strict, bounded NDJSON envelopes; no model-specific data crosses this boundary."""

import json
import re
from dataclasses import asdict, dataclass

from . import PROTOCOL_VERSION

MAX_LINE_BYTES = 65536
KINDS = {
    "command",
    "event",
    "confirmation_required",
    "result",
    "answer",
    "error",
    "cancel",
    "health",
    "approve",
}


@dataclass(frozen=True)
class Message:
    kind: str
    task_id: str
    text: str = ""
    status: str = ""
    version: int = PROTOCOL_VERSION
    target: str = ""
    approval_id: str = ""  # Deprecated input compatibility only; never grants authority.
    answer: dict | None = None
    error_code: str = ""

    def encode(self) -> str:
        data = asdict(self)
        if not self.approval_id:
            data.pop("approval_id")
        if self.answer is None:
            data.pop("answer")
        if not self.error_code:
            data.pop("error_code")
        return json.dumps(data, ensure_ascii=False) + "\n"


def decode(line: str) -> Message:
    if len(line.encode()) > MAX_LINE_BYTES:
        raise ValueError("message_too_large")

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate_field")
            result[key] = value
        return result

    data = json.loads(line, object_pairs_hook=unique)
    if not isinstance(data, dict) or set(data) - {
        "version",
        "kind",
        "task_id",
        "text",
        "status",
        "target",
        "approval_id",
        "answer",
        "error_code",
    }:
        raise ValueError("invalid_envelope")
    if type(data.get("version")) is not int or data["version"] != PROTOCOL_VERSION:
        raise ValueError("unsupported_version")
    if data.get("kind") not in KINDS:
        raise ValueError("invalid_kind")
    if not isinstance(data.get("task_id"), str) or not 1 <= len(data["task_id"]) <= 128:
        raise ValueError("invalid_task_id")
    if any(
        not isinstance(data.get(key, ""), str)
        for key in ("text", "status", "target", "approval_id")
    ):
        raise ValueError("invalid_payload")
    if len(data.get("approval_id", "")) > 128 or (
        data["kind"] == "approve" and not data.get("approval_id")
    ):
        raise ValueError("invalid_approval")
    error_code = data.get("error_code", "")
    if (
        not isinstance(error_code, str)
        or len(error_code) > 80
        or (error_code and (data["kind"] != "error" or not re.fullmatch(r"[a-z0-9_]+", error_code)))
    ):
        raise ValueError("invalid_error_code")
    answer = data.get("answer")
    if (data["kind"] == "answer") != (answer is not None):
        raise ValueError("invalid_answer")
    if answer is not None:
        if not isinstance(answer, dict) or set(answer) != {
            "answer",
            "confidence",
            "source_app",
            "source_window",
            "evidence",
        }:
            raise ValueError("invalid_answer")
        if (
            data["status"] != "answered"
            or answer["answer"] != data["text"]
            or not isinstance(answer["answer"], str)
            or not 1 <= len(answer["answer"]) <= 500
            or type(answer["confidence"]) not in (int, float)
            or not 0 <= answer["confidence"] <= 1
            or any(
                not isinstance(answer[key], str) or len(answer[key]) > 200
                for key in ("source_app", "source_window")
            )
            or not isinstance(answer["evidence"], list)
            or len(answer["evidence"]) > 8
            or any(not isinstance(item, str) or len(item) > 200 for item in answer["evidence"])
        ):
            raise ValueError("invalid_answer")
    return Message(**data)
