"""Frozen offline Kio decision benchmark. Never connects to CUA."""

import argparse
import hashlib
import json
import math
import resource
import statistics
from pathlib import Path

from .candidates import Element, Observation, Operation, build_candidates
from .chooser import HEADS, LayaChooser, format_state_legacy, questions_for


def case_table(case, *, prune=True, full_candidates=False):
    elements = tuple(
        Element(
            f"e{i}",
            case["id"],
            e["label"],
            e["role"],
            e.get("value", ""),
            True,
            True,
            e.get("source", "AX"),
            native={"frame": {"x": 10, "y": 40 * i, "w": 100, "h": 30}},
        )
        for i, e in enumerate(case["elements"])
    )
    return build_candidates(
        Observation(case["id"], 0, 0, elements, "Local evaluation fixture"),
        case["goal"] if prune else "",
        diagnostic_unbounded=full_candidates,
    )


def candidate_recall(cases):
    """Separate raw observation, exhaustive builder, and production-cap recall."""
    rows = []
    for case in cases:
        label = case.get("expected_label", "")
        if not label:
            continue
        raw = any(element["label"].startswith(label) for element in case["elements"])
        operation = Operation(case["expected_operation"])
        exhaustive = case_table(case, prune=False, full_candidates=True)
        final = case_table(case, prune=True)

        def has_gold(table, label=label, operation=operation):
            return any(
                candidate.operation == operation and candidate.description.startswith(label + " (")
                for candidate in table.actions.values()
            )

        rows.append(
            {
                "id": case["id"],
                "raw_observation": raw,
                "candidate_builder": has_gold(exhaustive),
                "production_candidate_set": has_gold(final),
                "final_candidate_count": len(final.public_choices(operation)),
                "exhaustive_candidate_count": len(exhaustive.public_choices(operation)),
            }
        )
        exhaustive.discard()
        final.discard()
    denominator = len(rows)
    return {
        "target_rows": denominator,
        "perception_recall": sum(row["raw_observation"] for row in rows) / denominator
        if denominator
        else None,
        "candidate_builder_recall": sum(row["candidate_builder"] for row in rows) / denominator
        if denominator
        else None,
        "production_candidate_recall": sum(row["production_candidate_set"] for row in rows)
        / denominator
        if denominator
        else None,
        "rows": rows,
    }


def dataset_rows(cases):
    rows = []
    for case in cases:
        table = case_table(case)
        operation = Operation(case["expected_operation"])
        expected = {"operation": operation.value}
        if operation in HEADS:
            candidates = [
                c
                for c in table.actions.values()
                if c.operation == operation
                and c.description.startswith(case["expected_label"] + " (")
            ]
            if len(candidates) != 1:
                raise ValueError("ambiguous_benchmark_label")
            expected[HEADS[operation]] = candidates[0].id
        questions = questions_for(table)
        # Stable IDs make the frozen corpus reproducible independent of UUID generation.
        mapping = {c: f"c_{i}" for i, c in enumerate(table.actions)}
        for head in HEADS.values():
            if head in questions:
                questions[head]["criteria"] = {
                    mapping[k]: v for k, v in questions[head]["criteria"].items()
                }
                if head in expected:
                    expected[head] = mapping[expected[head]]
        rows.append(
            {
                "state": format_state_legacy(case["goal"], table, case.get("history", [])),
                "questions": questions,
                "expected": expected,
                "task_group": case["id"],
                "tags": [case["split"], case["category"]],
                "language": "en",
            }
        )
    return rows


def ece(rows, bins=10):
    error = 0
    for i in range(bins):
        group = [
            r
            for r in rows
            if i / bins <= r["confidence"] < (i + 1) / bins
            or (i == bins - 1 and r["confidence"] == 1)
        ]
        if group:
            error += (
                len(group)
                / len(rows)
                * abs(
                    statistics.mean(r["confidence"] for r in group)
                    - statistics.mean(r["correct"] for r in group)
                )
            )
    return error


def benchmark(cases, chooser, *, prune=True, history=True):
    rows = []
    for case in cases:
        table = case_table(case, prune=prune)
        decision = chooser.choose(case["goal"], table, case.get("history", []) if history else [])
        action = table.actions[decision.candidate_id]
        op_ok = action.operation.value == case["expected_operation"]
        target_ok = not case.get("expected_label") or action.description.startswith(
            case["expected_label"] + " ("
        )
        rows.append(
            {
                "id": case["id"],
                "operation_correct": op_ok,
                "target_correct": target_ok,
                "has_target": bool(case.get("expected_label")),
                "correct": op_ok and target_ok,
                "confidence": decision.confidence,
                "seconds": decision.latency_seconds,
                "operation": decision.operation.value,
                "candidate_count": len(table.actions),
            }
        )
    targets = [r for r in rows if r["has_target"]]
    times = sorted(r["seconds"] for r in rows[1:]) or [rows[0]["seconds"]]
    return {
        "rows": rows,
        "operation_accuracy": statistics.mean(r["operation_correct"] for r in rows),
        "target_accuracy": statistics.mean(r["target_correct"] for r in targets)
        if targets
        else None,
        "combined_accuracy": statistics.mean(r["correct"] for r in rows),
        "false_high_confidence_errors": sum(
            not r["correct"] and r["confidence"] >= 0.8 for r in rows
        ),
        "ece": ece(rows),
        "candidate_recall": candidate_recall(cases),
        "cold_load_seconds": chooser.cold_load_seconds,
        "first_inference_seconds": rows[0]["seconds"],
        "warm_median_seconds": statistics.median(times),
        "warm_p90_seconds": times[max(0, math.ceil(0.9 * len(times)) - 1)],
        "peak_rss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**2,
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--cases", type=Path, required=True)
    p.add_argument("--report", type=Path, required=True)
    p.add_argument("--model", type=Path)
    p.add_argument("--split", choices=["validation", "test"], default="test")
    p.add_argument("--no-prune", action="store_true")
    p.add_argument("--no-history", action="store_true")
    args = p.parse_args()
    cases = [c for c in json.loads(args.cases.read_text()) if c["split"] == args.split]
    chooser = LayaChooser(model_path=args.model)
    result = benchmark(
        cases,
        chooser,
        prune=not args.no_prune,
        history=not args.no_history,
    )
    result.update(
        {
            "corpus_sha256": hashlib.sha256(args.cases.read_bytes()).hexdigest(),
            "split": args.split,
            "model": Path(chooser.model_path).name if chooser.specialized else "generic",
            "pruning": not args.no_prune,
            "history": not args.no_history,
        }
    )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k != "rows"}))


if __name__ == "__main__":
    main()
