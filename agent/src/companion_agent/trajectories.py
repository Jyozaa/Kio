"""Opt-in sanitized trajectory records. Offline replay has no execution entry point."""

import argparse
import hashlib
import json
import os
import re
import uuid
from dataclasses import asdict
from pathlib import Path

from .candidates import CandidateAction, CandidateTable, Element, Observation, Operation
from .chooser import HEADS, format_state, operation_question
from .decision_protocol import render_candidate_options, training_row
from .policy import SECRETS
from .storage import application_support

SCHEMA_VERSION = 1


def sanitize(value):
    if isinstance(value, dict):
        return {
            k: sanitize(v)
            for k, v in value.items()
            if k
            not in {
                "image",
                "audio",
                "clipboard",
                "payload",
                "element_token",
                "api_key",
                "password",
                "token",
            }
        }
    if isinstance(value, (list, tuple)):
        return [sanitize(v) for v in value]
    if not isinstance(value, str):
        return value
    if SECRETS.search(value):
        return "[REDACTED sensitive content]"
    value = re.sub(
        r"\b(?:AIza[\w-]{20,}|sk-[\w-]{12,}|gh[pousr]_[\w]{12,}|Bearer\s+\S+)", "[SECRET]", value
    )
    value = re.sub(
        r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", "[EMAIL]", value, flags=re.IGNORECASE
    )
    value = re.sub(r"(?:/Users/|/home/|[A-Z]:\\Users\\)[^\s\"']+", "[LOCAL_PATH]", value)
    value = re.sub(r"\b(?:\+?\d[\s().-]*){9,16}\b", "[NUMBER]", value)
    return value[:16000]


def write_new(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(sanitize(data), stream, ensure_ascii=False, indent=2, allow_nan=False)


class TrajectoryRecorder:
    def __init__(self, goal, root=None, *, run_id=None, task_id=None):
        self.root = root or application_support() / "trajectories"
        self.run_id = run_id or uuid.uuid4().hex
        self.task_id = task_id or self.run_id
        if not re.fullmatch(r"[\w-]{1,100}", self.run_id):
            raise ValueError("invalid_run_id")
        self.data = {
            "trajectory_schema_version": SCHEMA_VERSION,
            "run_id": self.run_id,
            "task": {"id": self.task_id, "goal": sanitize(goal)},
            "steps": [],
            "outcome": None,
        }
        self.closed = False

    def observe(self, observation, verification):
        if self.data["steps"]:
            last = self.data["steps"][-1]
            if last["action"]["status"] == "executed":
                last["state_changed"] = (
                    observation.fingerprint() != last["observation"]["fingerprint"]
                )
                last["verification"] = asdict(verification)

    def decision(self, goal, table, decision, history, guidance, perception, timings):
        if len(self.data["steps"]) >= 500:
            raise ValueError("trajectory_step_limit")
        obs = table.observation
        candidate_element_ids = {c.element_id for c in table.actions.values() if c.element_id}
        elements = [
            {
                "id": e.id,
                "snapshot_id": obs.snapshot_id,
                "label": e.label,
                "role": e.role,
                "value": None,
                "enabled": e.enabled,
                "visible": e.visible,
                "source": e.source,
                "sources": list(e.sources),
            }
            for e in obs.elements
            if e.id in candidate_element_ids
        ]
        row = {
            "index": len(self.data["steps"]),
            "goal": goal,
            "observation": {
                "id": obs.snapshot_id,
                "fingerprint": obs.fingerprint(),
                "title": "",
                "elements": elements[:40],
            },
            "candidates": [
                {
                    "id": c.id,
                    "operation": c.operation.value,
                    "description": c.description,
                    "element_id": c.element_id,
                }
                for c in table.actions.values()
            ],
            "decision": asdict(decision),
            "history": history[-6:],
            "guidance": guidance,
            "action": {"status": "not_executed"},
            "state_changed": None,
            "verification": None,
            "latencies": {**timings, "laya": decision.latency_seconds},
            "perception_sources": sorted({e.source for e in obs.elements}),
            "ocr_used": perception.used_visual,
            "gemini_used": bool(guidance),
        }
        self.data["steps"].append(sanitize(row))

    def used_gemini(self):
        if self.data["steps"]:
            self.data["steps"][-1]["gemini_used"] = True

    def acted(self, seconds=0):
        if self.data["steps"]:
            self.data["steps"][-1]["action"] = {"status": "executed"}
            self.data["steps"][-1]["latencies"]["action"] = seconds

    def finish(self, status, reason, verification, gemini_calls):
        if self.closed:
            return
        self.data["outcome"] = {
            "status": status,
            "reason": reason,
            "gemini_calls": gemini_calls,
            "verification": asdict(verification) if verification else None,
        }
        write_new(self.root / (self.run_id + ".json"), self.data)
        self.closed = True


def load(path):
    if path.stat().st_size > 16_000_000:
        raise ValueError("trajectory_too_large")
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or data.get("trajectory_schema_version") != SCHEMA_VERSION:
        raise ValueError("unsupported_trajectory_version")
    if set(data) != {"trajectory_schema_version", "run_id", "task", "steps", "outcome"}:
        raise ValueError("invalid_trajectory")
    if not isinstance(data["steps"], list) or len(data["steps"]) > 500:
        raise ValueError("invalid_trajectory")
    for step in data["steps"]:
        table_from_step(step).discard()
    return data


def table_from_step(step):
    observation = step["observation"]
    elements = tuple(Element(**e) for e in observation["elements"])
    obs = Observation(observation["id"], 0, 0, elements, observation["title"])
    candidates = [
        CandidateAction(
            c["id"], obs.snapshot_id, Operation(c["operation"]), c["description"], c["element_id"]
        )
        for c in step["candidates"]
    ]
    if len(candidates) > 310:
        raise ValueError("candidate_limit")
    table = CandidateTable(obs, candidates)
    table.validate(step["decision"]["candidate_id"], obs.snapshot_id)
    return table


def replay(data, chooser):
    results = []
    for step in data["steps"]:
        table = table_from_step(step)
        try:
            choice = chooser.choose(step["goal"], table, step["history"], step["guidance"])
            results.append(
                {
                    "step": step["index"],
                    "original": step["decision"]["candidate_id"],
                    "current": choice.candidate_id,
                    "same": choice.candidate_id == step["decision"]["candidate_id"],
                    "confidence": choice.confidence,
                }
            )
        finally:
            table.discard()
    return results  # Never calls a Driver, even when historical action status is executed.


def correct(path, step_index, candidate_id, corrections_root):
    data = load(path)
    if not 0 <= step_index < len(data["steps"]):
        raise ValueError("invalid_correction_step")
    step = data["steps"][step_index]
    table = table_from_step(step)
    table.validate(candidate_id, table.observation.snapshot_id)
    record = {
        "correction_schema_version": 1,
        "trajectory_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "run_id": data["run_id"],
        "step": step_index,
        "candidate_id": candidate_id,
    }
    write_new(corrections_root / (uuid.uuid4().hex + ".json"), record)


def split_for(task_id, seed=42):
    bucket = int(hashlib.sha256(f"{seed}:{task_id}".encode()).hexdigest()[:8], 16) % 10
    return "test" if bucket == 0 else "validation" if bucket == 1 else "train"


def export(paths, corrections_root, output, seed=42):
    corrections = [json.loads(p.read_text()) for p in sorted(corrections_root.glob("*.json"))]
    if any(c.get("correction_schema_version") != 1 for c in corrections):
        raise ValueError("unsupported_correction_version")
    rows = {"train": [], "validation": [], "test": []}
    for path in sorted(paths):
        data = load(path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        for step in data["steps"]:
            matched = [
                c
                for c in corrections
                if c["trajectory_sha256"] == digest and c["step"] == step["index"]
            ]
            verified = (
                step.get("action", {}).get("status") == "executed"
                and step.get("state_changed") is True
                and step.get("verification", {}).get("status") == "VERIFIED"
                and data.get("outcome", {}).get("status") == "completed"
            )
            if not matched and not verified:
                continue
            labels = {c["candidate_id"] for c in matched}
            if len(labels) > 1:
                raise ValueError("conflicting_corrections")
            table = table_from_step(step)
            selected_id = next(iter(labels)) if labels else step["decision"]["candidate_id"]
            selected = table.validate(selected_id, table.observation.snapshot_id)
            group = hashlib.sha256(data["task"]["id"].encode()).hexdigest()[:16]
            state = format_state(step["goal"], table, step["history"], step["guidance"])
            op_question = operation_question(table)["operation"]
            op_row = training_row(
                "NEXT_OPERATION",
                state,
                op_question,
                selected.operation.value,
                task_group=group,
                trajectory_id=group,
                step_index=step["index"],
                app_family="native-or-browser",
                provenance="corrected" if matched else "verified_live",
            )
            rows[split_for(data["task"]["id"], seed)].append(sanitize(op_row))
            head = HEADS.get(selected.operation)
            if head:
                options, reverse = render_candidate_options(table, selected.operation)
                option_id = next(key for key, value in reverse.items() if value == selected.id)
                target_question = {
                    "type": "choice",
                    "instructions": (
                        "Choose the observed semantic control for the selected operation. "
                        "Select only a supplied opaque candidate ID."
                    ),
                    "criteria": options,
                }
                target_row = training_row(
                    "TARGET",
                    state,
                    target_question,
                    option_id,
                    task_group=group,
                    trajectory_id=group,
                    step_index=step["index"],
                    app_family="native-or-browser",
                    provenance="corrected" if matched else "verified_live",
                )
                rows[split_for(data["task"]["id"], seed)].append(sanitize(target_row))
    output.mkdir(parents=True, exist_ok=True)
    for split, items in rows.items():
        with (output / (split + ".jsonl")).open("x") as stream:
            for row in items:
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
    return {k: len(v) for k, v in rows.items()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["inspect", "replay", "correct", "export"])
    parser.add_argument("path", type=Path)
    parser.add_argument("--step", type=int, default=0)
    parser.add_argument("--candidate")
    parser.add_argument("--corrections", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.command == "inspect":
        print(json.dumps(sanitize(load(args.path)), indent=2))
    elif args.command == "replay":
        from .chooser import LayaChooser

        print(json.dumps({"results": replay(load(args.path), LayaChooser()), "cua_actions": 0}))
    elif args.command == "correct":
        if args.corrections is None or not args.candidate:
            parser.error("correct requires --corrections and --candidate")
        correct(args.path, args.step, args.candidate, args.corrections)
    else:
        if args.corrections is None or args.output is None:
            parser.error("export requires --corrections and --output")
        print(json.dumps(export(list(args.path.glob("*.json")), args.corrections, args.output)))


if __name__ == "__main__":
    main()
