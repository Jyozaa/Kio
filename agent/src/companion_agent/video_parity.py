"""Offline replay of the user-supplied reference utterances; no desktop actions."""

import argparse
import json
from pathlib import Path

from .direct import parse_direct
from .goal_compiler import normalize_spoken_goal
from .semantic_planner import SemanticTaskPlanner


def evaluate_case(case):
    normalized = normalize_spoken_goal(case["utterance"])
    plan = SemanticTaskPlanner().plan(normalized)
    direct = parse_direct(normalized)
    step = plan.steps[0] if plan.steps else None
    operation = str(getattr(getattr(step, "operation", None), "value", "")) or None
    object_type = str(getattr(getattr(step, "object_type", None), "value", "")) or None
    parameters = getattr(step, "parameters", {}) if step else {}
    checks = {}
    if "expected_direct" in case:
        checks["direct"] = (direct.kind if direct else None) == case["expected_direct"]
    if "expected_semantic" in case:
        checks["semantic"] = operation == case["expected_semantic"]
    if "expected_object" in case:
        checks["object"] = object_type == case["expected_object"]
    if "expected_app" in case:
        actual_app = str(getattr(step, "application_hint", "")) if step else ""
        checks["app"] = case["expected_app"].casefold() in actual_app.casefold()
    if "expected_parameters" in case:
        checks["parameters"] = all(
            parameters.get(key) == value for key, value in case["expected_parameters"].items()
        )
    if "expected_request_mode" in case:
        checks["request_mode"] = plan.request_mode.value == case["expected_request_mode"]
        checks["no_action"] = not plan.steps and not plan.unresolved
    if "expected_url" in case:
        checks["url"] = bool(
            step
            and parameters.get("url", "").rstrip("/").casefold()
            == case["expected_url"].rstrip("/").casefold()
        )
    return {
        "utterance": case["utterance"],
        "normalized": normalized,
        "direct": direct.kind if direct else None,
        "semantic": operation,
        "object": object_type,
        "app": str(getattr(step, "application_hint", "")) if step else "",
        "parameters": parameters,
        "checks": checks,
        "passed": all(checks.values()),
        "needs_reasoning": plan.needs_reasoning,
    }


def evaluate(canonical_path, variants_path):
    canonical = json.loads(canonical_path.read_text())
    variants = json.loads(variants_path.read_text())
    if (
        canonical.get("training_eligible") is not False
        or variants.get("training_eligible") is not False
    ):
        raise ValueError("parity_fixtures_must_remain_held_out")
    canonical_rows = [evaluate_case(case) for case in canonical["steps"]]
    variant_rows = [evaluate_case(case) for case in variants["variants"]]
    return {
        "canonical_passed": sum(row["passed"] for row in canonical_rows),
        "canonical_total": len(canonical_rows),
        "variant_passed": sum(row["passed"] for row in variant_rows),
        "variant_total": len(variant_rows),
        "live_actions": 0,
        "physical_voice_tested": False,
        "canonical": canonical_rows,
        "variants": variant_rows,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--canonical", type=Path, default=Path("fixtures/video_parity/canonical.json")
    )
    parser.add_argument(
        "--variants", type=Path, default=Path("fixtures/video_parity/variants.json")
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = evaluate(args.canonical, args.variants)
    rendered = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(rendered)
    print(rendered)


if __name__ == "__main__":
    main()
