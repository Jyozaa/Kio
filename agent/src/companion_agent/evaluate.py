"""Offline fixture evaluation with real local Laya; no desktop actions or paid APIs."""

import argparse
import json
import statistics
from pathlib import Path

from .candidates import build_candidates, normalize
from .chooser import MODEL_REVISION, LayaChooser
from .driver import normalize_window


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--device", default=None)
    args = parser.parse_args()
    chooser = LayaChooser(args.device)
    rows = []
    for case in json.loads(args.corpus.read_text()):
        controls = [("AXButton", label, "") for label in case.get("buttons", [])]
        controls += [("AXTextField", label, value) for label, value in case.get("fields", [])]
        controls += [("AXPopUpButton", label, "A") for label in case.get("selects", [])]
        controls += [("AXStaticText", case.get("text", ""), "")]
        data = {
            "elements": [
                {
                    "element_index": i,
                    "role": role,
                    "label": label,
                    "value": value,
                    "enabled": True,
                    "visible": True,
                    "frame": {"x": 10, "y": i * 45, "w": 100, "h": 30},
                }
                for i, (role, label, value) in enumerate(controls)
            ]
        }
        table = build_candidates(normalize(normalize_window(data, 1, 1)), case["goal"])
        decision = chooser.choose(case["goal"], table, [])
        action = table.actions[decision.candidate_id]
        correct = (
            decision.operation.value == case["expected_operation"]
            and case.get("expected_label", "") in action.description
        )
        rows.append(
            {
                "goal": case["goal"],
                "correct": correct,
                "operation": decision.operation.value,
                "target": action.description,
                "confidence": decision.confidence,
                "latency_seconds": decision.latency_seconds,
            }
        )
        print(json.dumps(rows[-1]), flush=True)
    score = sum(row["correct"] for row in rows) / len(rows)
    print(
        json.dumps(
            {
                "accuracy": score,
                "cold_load_seconds": chooser.cold_load_seconds,
                "warm_median_seconds": statistics.median(
                    row["latency_seconds"] for row in rows[1:]
                ),
                "device": chooser.device,
                "model_revision": MODEL_REVISION,
            }
        ),
        flush=True,
    )
    raise SystemExit(0 if score >= 0.8 else 1)


if __name__ == "__main__":
    main()
