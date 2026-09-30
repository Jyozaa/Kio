"""Reproducible same-input Torch/MLX decision benchmark; never connects to CUA."""

import argparse
import hashlib
import json
import math
import platform
import resource
import statistics
import sys
import time
from pathlib import Path

from .backends import MLXLayaBackend, TorchLayaBackend
from .benchmark import candidate_recall, case_table, dataset_rows, ece
from .candidates import Operation
from .chooser import HEADS, MODEL_REVISION, format_state, operation_question, validated_answer
from .decision_protocol import render_candidate_options


def _environment(backend_name):
    versions = {
        "python": sys.version.split()[0],
        "os": platform.platform(),
        "machine": platform.machine(),
    }
    from importlib.metadata import version

    versions["laya"] = version("laya")
    if backend_name == "mlx":
        versions["laya_mlx"] = version("laya-mlx")
        versions["mlx"] = version("mlx")
        versions["mlx_metal"] = version("mlx-metal")
    else:
        versions["torch"] = version("torch")
    return versions


def prepare(cases_path, output, split):
    cases = json.loads(cases_path.read_text())
    selected = [case for case in cases if case["split"] == split]
    payload = {
        "schema_version": 1,
        "source_sha256": hashlib.sha256(cases_path.read_bytes()).hexdigest(),
        "split": split,
        "cases": selected,
        "legacy_rows": dataset_rows(selected),
    }
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2))
    return payload


def _new_result(backend, case, model_path=None):
    table = case_table(case)
    state = format_state(case["goal"], table, case.get("history", []))
    if case["expected_operation"] == "DONE":
        # This fixture's Success marker is a deterministic verifier fact. The
        # production loop exits here without asking either backend.
        return {
            "id": case["id"],
            "operation_correct": True,
            "target_correct": True,
            "correct": True,
            "has_target": False,
            "confidence": 1.0,
            "seconds": 0.0,
            "operation": "DONE_VERIFIED",
            "candidate_count": len(table.actions),
            "predictions": {"operation": {"choice": "DONE_VERIFIED", "confidence": 1.0}},
        }
    started = time.perf_counter()
    operation_question_data = operation_question(table)
    result = backend.predict(state, operation_question_data)
    answers = result.get("answers", {})
    operation, op_confidence = validated_answer(
        answers.get("operation"), operation_question_data["operation"]["criteria"]
    )
    selected_operation = Operation(operation)
    predicted = {
        "operation": {
            "choice": operation,
            "confidence": op_confidence,
            "probabilities": answers["operation"]["probabilities"],
        }
    }
    target_confidence = 1.0
    head = HEADS.get(selected_operation)
    candidate_id = None
    if head:
        choices, reverse = render_candidate_options(table, selected_operation)
        question = {
            head: {
                "type": "choice",
                "instructions": f"Which observed control should receive {operation}? Select one supplied ID.",
                "criteria": choices,
            }
        }
        target_result = backend.predict(state, question)
        target_answer = target_result.get("answers", {}).get(head)
        opaque_id, target_confidence = validated_answer(target_answer, choices)
        candidate_id = reverse[opaque_id]
        predicted[head] = {
            "choice": opaque_id,
            "confidence": target_confidence,
            "probabilities": target_answer["probabilities"],
        }
    elapsed = time.perf_counter() - started
    candidate = table.actions.get(candidate_id) if candidate_id else None
    target_correct = not case.get("expected_label") or bool(
        candidate and candidate.description.startswith(case["expected_label"] + " (")
    )
    op_correct = operation == case["expected_operation"]
    return {
        "id": case["id"],
        "operation_correct": op_correct,
        "target_correct": target_correct,
        "correct": op_correct and target_correct,
        "has_target": bool(case.get("expected_label")),
        "confidence": min(op_confidence, target_confidence),
        "seconds": elapsed,
        "operation": operation,
        "candidate_count": len(table.actions),
        "predictions": predicted,
    }


def _legacy_result(backend, case, row):
    table = case_table(case)
    started = time.perf_counter()
    result = backend.predict(row["state"], row["questions"])
    elapsed = time.perf_counter() - started
    answers = result.get("answers", {})
    predicted = {}
    correct = True
    confidences = []
    for head, expected in row["expected"].items():
        question = row["questions"][head]
        choice, confidence = validated_answer(answers.get(head), question["criteria"])
        predicted[head] = {
            "choice": choice,
            "confidence": confidence,
            "probabilities": answers[head]["probabilities"],
        }
        correct &= choice == expected
        confidences.append(confidence)
    operation = answers["operation"]["choice"]
    operation_correct = operation == case["expected_operation"]
    target_head = HEADS.get(Operation(case["expected_operation"]))
    target_correct = (
        target_head not in row["expected"]
        or predicted[target_head]["choice"] == row["expected"][target_head]
    )
    return {
        "id": case["id"],
        "operation_correct": operation_correct,
        "target_correct": target_correct,
        "correct": correct,
        "has_target": bool(case.get("expected_label")),
        "confidence": min(confidences) if confidences else 0.0,
        "seconds": elapsed,
        "operation": operation,
        "candidate_count": len(table.actions),
        "predictions": predicted,
    }


def _load_backend(
    backend_name, model_path, *, compile_model=False, cache_prompts=False, batch_size=8
):
    if backend_name == "mlx":
        return MLXLayaBackend.load(
            model_path,
            compile=compile_model,
            cache_prompts=cache_prompts,
            batch_size=batch_size,
        )
    if compile_model or cache_prompts:
        raise ValueError("compile_and_prompt_cache_are_mlx_only")
    return TorchLayaBackend.load(model_path)


def run(
    inputs_path,
    backend_name,
    representation,
    output,
    model_path=None,
    *,
    compile_model=False,
    cache_prompts=False,
    batch_size=8,
):
    payload = json.loads(inputs_path.read_text())
    if payload.get("schema_version") != 1:
        raise ValueError("unsupported_benchmark_input")
    if model_path is None:
        from huggingface_hub import snapshot_download

        model_path = Path(
            snapshot_download(
                "convaiinnovations/laya",
                revision=MODEL_REVISION,
                allow_patterns=[
                    "model.safetensors",
                    "rl_agent_config.json",
                    "encoder/*",
                    "tokenizer/*",
                ],
            )
        )
    started = time.perf_counter()
    backend = _load_backend(
        backend_name,
        model_path,
        compile_model=compile_model,
        cache_prompts=cache_prompts,
        batch_size=batch_size,
    )
    cold_load = time.perf_counter() - started
    cases = payload["cases"]
    legacy_rows = payload["legacy_rows"]
    first_started = time.perf_counter()
    if cases:
        warm_state = legacy_rows[0]["state"]
        warm_questions = {"operation": legacy_rows[0]["questions"]["operation"]}
        backend.predict(warm_state, warm_questions)
    first_inference = time.perf_counter() - first_started
    if representation == "legacy":
        results = [_legacy_result(backend, case, row) for case, row in zip(cases, legacy_rows)]
    else:
        results = [_new_result(backend, case) for case in cases]
    times = sorted(row["seconds"] for row in results[1:]) or [results[0]["seconds"]]
    target_rows = [row for row in results if row["has_target"]]
    scored_operations = [
        row for row, case in zip(results, cases) if case["expected_operation"] != "DONE"
    ]
    report = {
        "schema_version": 1,
        "backend": backend.name,
        "backend_revision": "laya-mlx-0.2.0" if backend.name == "mlx" else "laya-0.3.20",
        "environment": _environment(backend_name),
        "model": f"convaiinnovations/laya@{MODEL_REVISION}",
        "checkpoint_revision": "55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851",
        "representation": representation,
        "options": {
            "compile": compile_model,
            "cache_prompts": cache_prompts,
            "batch_size": batch_size if backend_name == "mlx" else None,
            "dtype": "float16" if backend_name == "mlx" else None,
        },
        "split": payload["split"],
        "fixture_sha256": payload["source_sha256"],
        "cold_load_seconds": cold_load,
        "first_inference_seconds": first_inference,
        "warm_median_seconds": statistics.median(times),
        "warm_p90_seconds": times[max(0, math.ceil(0.9 * len(times)) - 1)],
        "peak_rss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**2,
        "operation_accuracy": statistics.mean(
            row["operation_correct"] for row in scored_operations
        ),
        "operation_accuracy_all_rows": statistics.mean(row["operation_correct"] for row in results),
        "operation_rows_scored": len(scored_operations),
        "target_accuracy": statistics.mean(row["target_correct"] for row in target_rows)
        if target_rows
        else None,
        "combined_accuracy": statistics.mean(row["correct"] for row in results),
        "false_high_confidence_errors": sum(
            not row["correct"] and row["confidence"] >= 0.8 for row in results
        ),
        "ece": ece(
            [{"confidence": row["confidence"], "correct": row["correct"]} for row in results]
        ),
        "candidate_recall": candidate_recall(cases),
        "rows": results,
    }
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    return report


def profile(
    backend_name,
    model_path=None,
    *,
    repeats=12,
    compile_model=False,
    cache_prompts=False,
    batch_size=8,
):
    """Measure typed query shapes plus diagnostic 8/30-choice heads on one loaded model."""
    if model_path is None:
        from huggingface_hub import snapshot_download

        model_path = Path(
            snapshot_download(
                "convaiinnovations/laya",
                revision=MODEL_REVISION,
                allow_patterns=[
                    "model.safetensors",
                    "rl_agent_config.json",
                    "encoder/*",
                    "tokenizer/*",
                ],
            )
        )
    started = time.perf_counter()
    backend = _load_backend(
        backend_name,
        model_path,
        compile_model=compile_model,
        cache_prompts=cache_prompts,
        batch_size=batch_size,
    )
    cold_load = time.perf_counter() - started
    state = json.dumps(
        {
            "schema": "KioDecisionStateV1",
            "task": "Open the requested app",
            "application": "Chrome",
            "history": [],
        }
    )
    operation = {
        "operation": {
            "type": "choice",
            "instructions": "What semantic operation should Kio perform next?",
            "criteria": {
                "OPEN_APP": "Open an application",
                "NAVIGATE": "Navigate to a URL",
                "SEARCH": "Search the web",
                "WAIT": "Wait for a transition",
                "REOBSERVE": "Refresh the observation",
            },
        }
    }
    five = {
        **operation,
        "click_target": {
            "type": "choice",
            "instructions": "Which observed control should receive ACTIVATE?",
            "criteria": {f"c_{i}": f"Open target {i} | button | toolbar" for i in range(8)},
        },
        "type_target": {
            "type": "choice",
            "instructions": "Which observed field should receive TYPE_TEXT?",
            "criteria": {f"c_{i}": f"Text field {i} | editable | main window" for i in range(8)},
        },
        "select_target": {
            "type": "choice",
            "instructions": "Which option should receive SELECT?",
            "criteria": {f"c_{i}": f"Option {i} | menu item | current menu" for i in range(8)},
        },
        "goal_state": {
            "type": "choice",
            "instructions": "Is the requested goal proven?",
            "criteria": {
                "SATISFIED": "All requested effects are verified",
                "NOT_SATISFIED": "At least one required effect is absent",
                "UNCERTAIN": "The current observation cannot prove the goal",
            },
        },
    }
    questions = {
        "one_question": operation,
        "operation_plus_target": {**operation, "click_target": five["click_target"]},
        "five_question_batch": five,
        "eight_choice_target": {"click_target": five["click_target"]},
        "thirty_choice_diagnostic_only": {
            "click_target": {
                "type": "choice",
                "instructions": "Which observed control advances the goal?",
                "criteria": {
                    f"c_{i}": f"Candidate {i} | button | diagnostic control group"
                    for i in range(30)
                },
            }
        },
    }
    timings = {}
    first_inference = None
    for name, batch in questions.items():
        backend.predict(state, batch)
        if first_inference is None:
            first_inference = time.perf_counter() - started - cold_load
        samples = []
        selected = []
        for _ in range(repeats):
            tick = time.perf_counter()
            result = backend.predict(state, batch)
            samples.append(time.perf_counter() - tick)
            selected.append(
                {key: answer.get("choice") for key, answer in result.get("answers", {}).items()}
            )
        ordered = sorted(samples)
        timings[name] = {
            "median_seconds": statistics.median(samples),
            "p90_seconds": ordered[max(0, math.ceil(0.9 * len(ordered)) - 1)],
            "repeats": repeats,
            "choice_sets_identical": all(item == selected[0] for item in selected),
            "selected": selected[0],
        }
    return {
        "backend": backend.name,
        "backend_revision": "laya-mlx-0.2.0" if backend.name == "mlx" else "laya-0.3.20",
        "environment": _environment(backend_name),
        "checkpoint_revision": MODEL_REVISION,
        "model": f"convaiinnovations/laya@{MODEL_REVISION}",
        "options": {
            "compile": compile_model,
            "cache_prompts": cache_prompts,
            "batch_size": batch_size if backend_name == "mlx" else None,
            "dtype": "float16" if backend_name == "mlx" else None,
        },
        "cold_load_seconds": cold_load,
        "first_inference_seconds": first_inference,
        "peak_rss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**2,
        "measurements": timings,
        "note": "30 choices is a diagnostic model-input profile; Kio production candidate generation remains bounded to at most 8 ordinary targets.",
    }


def compare(torch_path, mlx_path):
    torch_report = json.loads(torch_path.read_text())
    mlx_report = json.loads(mlx_path.read_text())
    if (torch_report["representation"], torch_report["split"], torch_report["fixture_sha256"]) != (
        mlx_report["representation"],
        mlx_report["split"],
        mlx_report["fixture_sha256"],
    ):
        raise ValueError("backend_inputs_do_not_match")
    torch_rows = {row["id"]: row for row in torch_report["rows"]}
    mlx_rows = {row["id"]: row for row in mlx_report["rows"]}
    exact_choices = total_choices = 0
    max_probability_delta = 0.0
    deltas = []
    for row_id, torch_row in torch_rows.items():
        mlx_row = mlx_rows[row_id]
        for question, torch_answer in torch_row["predictions"].items():
            mlx_answer = mlx_row["predictions"].get(question)
            if mlx_answer is None:
                continue
            exact_choices += torch_answer["choice"] == mlx_answer["choice"]
            total_choices += 1
            left, right = torch_answer.get("probabilities", {}), mlx_answer.get("probabilities", {})
            for label in set(left) & set(right):
                delta = abs(float(left[label]) - float(right[label]))
                max_probability_delta = max(max_probability_delta, delta)
                deltas.append(delta)
    return {
        "representation": torch_report["representation"],
        "split": torch_report["split"],
        "fixture_sha256": torch_report["fixture_sha256"],
        "matching_choices": exact_choices,
        "total_choices": total_choices,
        "choice_parity": exact_choices / total_choices if total_choices else None,
        "max_probability_delta": max_probability_delta,
        "mean_probability_delta": statistics.mean(deltas) if deltas else None,
        "within_0_02_tolerance": max_probability_delta <= 0.02,
    }


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    prepare_parser = sub.add_parser("prepare")
    prepare_parser.add_argument("--cases", type=Path, required=True)
    prepare_parser.add_argument("--split", choices=["validation", "test"], required=True)
    prepare_parser.add_argument("--output", type=Path, required=True)
    run_parser = sub.add_parser("run")
    run_parser.add_argument("--inputs", type=Path, required=True)
    run_parser.add_argument("--backend", choices=["torch", "mlx"], required=True)
    run_parser.add_argument("--representation", choices=["legacy", "v1"], required=True)
    run_parser.add_argument("--model", type=Path)
    run_parser.add_argument("--compile", action="store_true")
    run_parser.add_argument("--cache-prompts", action="store_true")
    run_parser.add_argument("--batch-size", type=int, default=8)
    run_parser.add_argument("--output", type=Path, required=True)
    profile_parser = sub.add_parser("profile")
    profile_parser.add_argument("--backend", choices=["torch", "mlx"], required=True)
    profile_parser.add_argument("--model", type=Path)
    profile_parser.add_argument("--repeats", type=int, default=12)
    profile_parser.add_argument("--compile", action="store_true")
    profile_parser.add_argument("--cache-prompts", action="store_true")
    profile_parser.add_argument("--batch-size", type=int, default=8)
    profile_parser.add_argument("--output", type=Path, required=True)
    compare_parser = sub.add_parser("compare")
    compare_parser.add_argument("--torch", type=Path, required=True)
    compare_parser.add_argument("--mlx", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        report = prepare(args.cases, args.output, args.split)
        print(json.dumps({"cases": len(report["cases"]), "sha256": report["source_sha256"]}))
    elif args.command == "run":
        report = run(
            args.inputs,
            args.backend,
            args.representation,
            args.output,
            args.model,
            compile_model=args.compile,
            cache_prompts=args.cache_prompts,
            batch_size=args.batch_size,
        )
        print(json.dumps({key: value for key, value in report.items() if key != "rows"}))
    elif args.command == "profile":
        report = profile(
            args.backend,
            args.model,
            repeats=args.repeats,
            compile_model=args.compile,
            cache_prompts=args.cache_prompts,
            batch_size=args.batch_size,
        )
        args.output.write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    else:
        print(json.dumps(compare(args.torch, args.mlx), indent=2))


if __name__ == "__main__":
    main()
