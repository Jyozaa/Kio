import json
import subprocess
import sys

import pytest

from companion_agent.protocol import Message, decode


@pytest.mark.parametrize(
    "line",
    [
        "{}",
        "[]",
        "null",
        "not json",
        '{"version":1,"version":1}',
        Message("invalid", "a").encode(),
        Message("command", "").encode(),
        Message("command", "a", version=2).encode(),
        '{"version":true,"kind":"command","task_id":"x"}',
        '{"version":1,"kind":"command","task_id":"x","text":{}}',
        "x" * 65537,
    ],
)
def test_reject_malformed(line):
    with pytest.raises((ValueError, TypeError)):
        decode(line)


def test_roundtrip_unicode():
    msg = Message("command", "test", "你好\nhello")
    assert decode(msg.encode()) == msg


def test_error_code_is_structured_and_restricted_to_error_messages():
    message = Message(
        "error",
        "task",
        "The app changed while Kio was working. Try again.",
        "error",
        error_code="stale_state",
    )
    assert decode(message.encode()) == message
    data = json.loads(message.encode())
    data["error_code"] = "private text"
    with pytest.raises(ValueError, match="invalid_error_code"):
        decode(json.dumps(data))
    data["error_code"] = "stale_state"
    data["kind"] = "event"
    with pytest.raises(ValueError, match="invalid_error_code"):
        decode(json.dumps(data))


def test_answer_message_is_typed_and_bounded():
    answer = {
        "answer": "The mute control is at the bottom-left.",
        "confidence": 0.92,
        "source_app": "Discord",
        "source_window": "Discord",
        "evidence": ["control=Mute", "role=AXButton"],
    }
    message = Message("answer", "task", answer["answer"], "answered", answer=answer)
    assert decode(message.encode()) == message
    answer["confidence"] = 1.5
    with pytest.raises(ValueError, match="invalid_answer"):
        decode(Message("answer", "task", "x", "answered", answer=answer).encode())
    with pytest.raises(ValueError, match="invalid_answer"):
        decode(Message("answer", "task", "x", "answered").encode())


def helper():
    return subprocess.Popen(
        [sys.executable, "-m", "companion_agent", "--demo"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def test_stream_completion():
    proc = helper()
    try:
        proc.stdin.write(Message("command", "complete", "hello").encode())
        proc.stdin.flush()
        assert decode(proc.stdout.readline()).kind == "event"
        assert decode(proc.stdout.readline()).kind == "event"
        assert decode(proc.stdout.readline()).status == "completed"
    finally:
        proc.communicate(timeout=5)
    assert proc.returncode == 0


def test_cancel_and_malformed_recovery():
    proc = helper()
    try:
        proc.stdin.write("bad json\n" + Message("command", "cancel-me", "hello").encode())
        proc.stdin.flush()
        assert decode(proc.stdout.readline()).kind == "error"
        assert decode(proc.stdout.readline()).kind == "event"
        proc.stdin.write(Message("cancel", "cancel-me").encode())
        proc.stdin.flush()
        assert decode(proc.stdout.readline()).status == "cancelled"
    finally:
        proc.communicate(timeout=5)
    assert proc.returncode == 0


def test_unknown_payload_field():
    data = json.loads(Message("command", "a").encode())
    data["shell"] = "anything"
    with pytest.raises(ValueError):
        decode(json.dumps(data))


def test_approval_envelope():
    message = Message("approve", "task", approval_id="once")
    assert decode(message.encode()) == message
    with pytest.raises(ValueError):
        decode(Message("approve", "task").encode())
