#!/usr/bin/python3
"""Privacy-limited lifecycle hook. Never persists prompts, transcript paths, or tool input."""
import json
import os
import pathlib
import sys
import tempfile
import time
import uuid

PROVIDER = sys.argv[1] if len(sys.argv) > 1 else ""
HOOK_EVENT = sys.argv[2] if len(sys.argv) > 2 else ""

def emit(payload):
    if PROVIDER not in {"claude", "codex", "cursor", "openCode"}:
        return
    event_name = (HOOK_EVENT or payload.get("hook_event_name") or payload.get("type") or payload.get("event") or "").lower()
    notification = str(payload.get("notification_type", "")).lower()
    status = None
    if "permission" in event_name or "action_required" in event_name or notification == "permission_prompt":
        status = "needsInput"
    elif "failure" in event_name or "failed" in event_name or "error" in event_name:
        status = "failed"
    elif "stop" in event_name or "finished" in event_name or "turn_complete" in event_name:
        status = "finished"
    elif "idle" in event_name:
        status = "idle"
    elif "sessionstart" in event_name or "session.created" in event_name or "thread.started" in event_name:
        status = "started"
    elif "sessionend" in event_name or "session.deleted" in event_name:
        status = "ended"
    elif "in_progress" in event_name or "running" in event_name:
        status = "activity"
    if status is None:
        return

    nested = payload.get("properties") if isinstance(payload.get("properties"), dict) else payload
    session_id = str(nested.get("session_id") or nested.get("sessionID") or nested.get("conversation_id")
                     or nested.get("thread_id") or nested.get("id") or "")[:160]
    if not session_id:
        return
    directory = str(nested.get("cwd") or nested.get("workspace_root") or nested.get("project_dir")
                    or nested.get("directory") or "")[:1024]
    workspace_roots = nested.get("workspace_roots")
    if not directory and isinstance(workspace_roots, list) and workspace_roots:
        directory = str(workspace_roots[0])[:1024]
    project = pathlib.Path(directory).name if directory else "Project"
    event_id = str(nested.get("event_id") or nested.get("generation_id") or nested.get("turn_id")
                   or f"{session_id}:{event_name}:{int(time.time())}:{uuid.uuid4().hex[:8]}")[:180]
    safe = {"provider": PROVIDER, "event": status, "session_id": session_id,
            "event_id": event_id, "project_name": project[:80], "cwd": directory,
            "timestamp": time.time()}
    root = pathlib.Path.home() / "Library" / "Application Support" / "Kio" / "Sessions" / "Inbox"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    inbox_events = sorted((item for item in root.glob("*.json") if item.is_file()), key=lambda item: item.stat().st_mtime)
    for expired in inbox_events[:-299]:
        try:
            expired.unlink()
        except OSError:
            pass
    fd, temp_name = tempfile.mkstemp(prefix=".event-", suffix=".tmp", dir=str(root))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(safe, out, separators=(",", ":"))
        os.replace(temp_name, root / f"{uuid.uuid4().hex}.json")
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass

try:
    raw = sys.stdin.read(1_000_000)
    body = json.loads(raw) if raw else {}
    if isinstance(body, dict):
        emit(body)
except Exception:
    pass
