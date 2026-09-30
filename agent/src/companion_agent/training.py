"""Bounded local adaptation of the official Laya RLCD notebook; no cloud training."""

import argparse
import hashlib
import json
import random
import re
import resource
import time
from datetime import UTC, datetime
from pathlib import Path

from .chooser import MODEL_REVISION
from .decision_protocol import CANDIDATE_SCHEMA, STATE_SCHEMA, TRAINING_SCHEMA, DecisionFamily
from .policy import SECRETS

UPSTREAM_REVISION = "9d955671415fc19f069b9cc998928075c1f255ec"


def read_rows(path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows or len(rows) > 100000:
        raise ValueError("invalid_dataset_size")
    for row in rows:
        if not isinstance(row.get("state"), (str, dict)) or not isinstance(
            row.get("questions"), dict
        ):
            raise TypeError("invalid_training_row")
        if "schema_version" in row:
            if row["schema_version"] != TRAINING_SCHEMA or row.get("decision_family") not in {
                value.value for value in DecisionFamily
            }:
                raise ValueError("unsupported_training_schema")
            if (
                row.get("decision_state_schema") != STATE_SCHEMA
                or row.get("candidate_format_schema") != CANDIDATE_SCHEMA
            ):
                raise ValueError("incompatible_training_schema")
            if not isinstance(row.get("task_group"), str) or not row["task_group"]:
                raise ValueError("invalid_training_group")
            _assert_sanitized(row)
            if row["decision_family"] not in row["questions"]:
                raise ValueError("invalid_training_family")
            if row["decision_family"] not in row.get("expected", {}):
                raise ValueError("invalid_training_family")
        for key, expected in row["expected"].items():
            question = row["questions"][key]
            if question["type"] != "choice" or expected not in question["criteria"]:
                raise ValueError("invalid_training_label")
    return rows


def _assert_sanitized(value):
    forbidden_keys = {
        "image",
        "screenshot",
        "audio",
        "clipboard",
        "payload",
        "element_token",
        "api_key",
        "password",
        "token",
    }
    if isinstance(value, dict):
        for key, nested in value.items():
            if str(key).casefold() in forbidden_keys:
                raise ValueError("unsanitized_training_field")
            _assert_sanitized(nested)
    elif isinstance(value, (list, tuple)):
        for nested in value:
            _assert_sanitized(nested)
    elif isinstance(value, str) and (
        SECRETS.search(value)
        or re.search(r"\b(?:sk-[\w-]{12,}|gh[pousr]_[\w]{12,}|AIza[\w-]{20,})\b", value)
        or re.search(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", value, re.IGNORECASE)
        or re.search(r"(?:/Users/|/home/|[A-Z]:\\Users\\)", value)
    ):
        raise ValueError("unsanitized_training_content")


def assert_disjoint(*datasets):
    seen = set()
    for rows in datasets:
        groups = {r["task_group"] for r in rows}
        if groups & seen:
            raise ValueError("task_split_leakage")
        seen |= groups


def source_path():
    from huggingface_hub import snapshot_download

    return Path(
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


def load_training_model(path, device="cpu"):
    from laya.common import build_model
    from safetensors.torch import load_file
    from transformers import AutoTokenizer

    cfg = json.loads((path / "rl_agent_config.json").read_text())
    tok = AutoTokenizer.from_pretrained(path / "tokenizer", local_files_only=True)
    model = build_model(cfg, encoder_dir=str(path / "encoder"), pretrained=False)
    model.load_state_dict(load_file(str(path / "model.safetensors")), strict=True)
    return model.to(device), tok, cfg


def training_items(rows, tok, cfg):
    from laya.common import QTYPES, build_sequence

    items = []
    for row in rows:
        for name, label in row["expected"].items():
            q = row["questions"][name]
            keys = list(q["criteria"])
            ids, markers = build_sequence(
                tok,
                row["state"],
                {"t": q["type"], "ins": q["instructions"], "crit": q["criteria"]},
                cfg["max_len"],
                cfg["head_max_len"],
            )
            if len(markers) != len(keys):
                raise ValueError("truncated_training_choices")
            items.append(
                {
                    "ids": ids,
                    "markers": markers,
                    "qtype": QTYPES[q["type"]],
                    "label": keys.index(label),
                }
            )
    return items


def tensors(item, device):
    import torch

    ids = torch.tensor([item["ids"]], device=device)
    markers = torch.tensor([item["markers"]], device=device)
    mask = torch.ones_like(markers, dtype=torch.bool)
    return ids, torch.ones_like(ids), markers, mask, torch.tensor([item["qtype"]], device=device)


def save_checkpoint(model, tok, cfg, output, metadata):
    from safetensors.torch import save_file

    output.mkdir(parents=True, exist_ok=False)
    save_file(
        {k: v.detach().contiguous().cpu() for k, v in model.state_dict().items()},
        str(output / "model.safetensors"),
    )
    model.encoder.config.save_pretrained(output / "encoder")
    tok.save_pretrained(output / "tokenizer")
    (output / "rl_agent_config.json").write_text(json.dumps(cfg, indent=2))
    metadata["weights_sha256"] = hashlib.sha256(
        (output / "model.safetensors").read_bytes()
    ).hexdigest()
    (output / "kio_training.json").write_text(json.dumps(metadata, indent=2))
    if metadata.get("decision_state_schema") == STATE_SCHEMA:
        (output / "kio_model.json").write_text(
            json.dumps(
                {
                    "checkpoint_family": "kio-specialized-laya",
                    "decision_state_schema": STATE_SCHEMA,
                    "candidate_format_schema": CANDIDATE_SCHEMA,
                    "training_dataset_sha256": metadata["dataset_sha256"],
                    "upstream_laya_revision": metadata["base_revision"],
                    "mlx_conversion_revision": None,
                    "weights_sha256": metadata["weights_sha256"],
                    "training_date": datetime.now(UTC).isoformat(),
                    "validation_metrics": {},
                    "test_metrics": {},
                    "calibration_metrics": {},
                    "promotion_status": "smoke_only" if metadata.get("smoke_only") else "candidate",
                },
                indent=2,
            )
        )


def train(dataset, output, *, steps=1, device="cpu", train_encoder=False):
    import laya
    import torch
    from laya.common import proper_reward

    if not 1 <= steps <= 10000:
        raise ValueError("invalid_training_steps")
    started = time.perf_counter()
    torch.manual_seed(42)
    random.seed(42)
    torch.set_num_threads(4)
    rows = read_rows(dataset)
    if any({"validation", "test"} & set(row.get("tags", [])) for row in rows):
        raise ValueError("training_requires_train_split")
    model, tok, cfg = load_training_model(source_path(), device)
    items = training_items(rows, tok, cfg)
    if not train_encoder:
        for p in model.encoder.parameters():
            p.requires_grad_(False)
    model.head_checkpointing = True
    model.train()
    optimizer = torch.optim.AdamW(
        [p for p in model.parameters() if p.requires_grad], lr=1e-5, weight_decay=0.01
    )
    watched = model.scorer[-1].weight.detach().clone()
    losses = []
    for step in range(steps):
        item = items[step % len(items)]
        batch = tensors(item, device)
        logits, act = model(*batch)
        mask, qtype = batch[3], batch[4]
        target = torch.zeros_like(logits)
        target[0, item["label"]] = 1
        sigma = 0.4
        eps = torch.randn((4,) + logits.shape, device=device) * sigma * mask
        eps = (eps - eps.sum(-1, keepdim=True) / mask.sum(-1, keepdim=True)) * mask
        z = logits.detach().unsqueeze(0) + eps
        q = torch.softmax(z.masked_fill(~mask, -1e4), -1)
        with torch.no_grad():
            reward = proper_reward(q, target.unsqueeze(0), qtype, mask, w_sph=0.75, w_rps=1)
            adv = reward - reward.mean(0, keepdim=True)
            adv = adv / (adv.std() + 1e-6)
        logp = -(((z - logits.unsqueeze(0)) ** 2) * mask).sum(-1) / (2 * sigma**2)
        loss = (
            -(adv * logp).mean()
            - (target * torch.log_softmax(logits, -1)).sum(-1).mean()
            + 0 * act.sum()
        )
        if not torch.isfinite(loss):
            raise ValueError("nonfinite_training_loss")
        optimizer.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1)
        optimizer.step()
        losses.append(float(loss.detach().cpu()))
    changed = not torch.equal(watched, model.scorer[-1].weight.detach())
    if not changed:
        raise ValueError("training_did_not_update_weights")
    cfg["fine_tuned"] = True
    metadata = {
        "schema_version": 1,
        "base_revision": MODEL_REVISION,
        "upstream_training_revision": UPSTREAM_REVISION,
        "dataset_sha256": hashlib.sha256(dataset.read_bytes()).hexdigest(),
        "steps": steps,
        "seed": 42,
        "device": device,
        "encoder_trained": train_encoder,
        "smoke_only": steps == 1,
        "losses": losses,
        "weights_changed": changed,
        "decision_state_schema": (
            STATE_SCHEMA
            if all(row.get("schema_version") == TRAINING_SCHEMA for row in rows)
            else "legacy-laya-choice"
        ),
    }
    save_checkpoint(model, tok, cfg, output, metadata)
    del optimizer, model
    reloaded = laya.load(str(output), device=device, fast=False)
    prediction = reloaded.predict(rows[0]["state"], rows[0]["questions"])
    first_question = next(iter(rows[0]["expected"]))
    assert (
        prediction["answers"][first_question]["choice"]
        in rows[0]["questions"][first_question]["criteria"]
    )
    metadata.update(
        {
            "checkpoint_reloaded": True,
            "inference_works": True,
            "seconds": time.perf_counter() - started,
            "peak_rss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**2,
        }
    )
    (output / "kio_training.json").write_text(json.dumps(metadata, indent=2))
    return metadata


def fit_temperature(samples):
    import torch

    if not samples:
        raise ValueError("empty_calibration")
    # Deterministic NLL grid within the installed runtime's supported [0.5, 5] clamp.
    best = (float("inf"), 1.0)
    for i in range(91):
        t = 0.5 + 0.05 * i
        nll = sum(
            float(-torch.log_softmax(torch.tensor(z) / t, -1)[label]) for z, label in samples
        ) / len(samples)
        best = min(best, (nll, t))
    return best[1]


def calibrate(validation, output, *, base=None):
    import torch

    torch.set_num_threads(4)
    rows = read_rows(validation)
    if any("validation" not in r.get("tags", []) for r in rows):
        raise ValueError("calibration_requires_validation_split")
    base = base or source_path()
    model, tok, cfg = load_training_model(base)
    model.eval()
    samples = []
    with torch.no_grad():
        for item in training_items(rows, tok, cfg):
            logits, _ = model(*tensors(item, "cpu"))
            samples.append((logits[0].tolist(), item["label"]))
    t = fit_temperature(samples)
    cfg["temperature"] = [t, 1, 1]
    cfg.pop("temperature_by_options", None)  # Official notebook persistence requirement.
    metadata = {
        "schema_version": 1,
        "kind": "validation_temperature",
        "temperature": t,
        "validation_sha256": hashlib.sha256(validation.read_bytes()).hexdigest(),
        "samples": len(samples),
        "base_revision": MODEL_REVISION,
        "not_default": True,
    }
    save_checkpoint(model, tok, cfg, output, metadata)
    return metadata


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["train", "calibrate"])
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--steps", type=int, default=1)
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps", "cuda"])
    parser.add_argument("--train-encoder", action="store_true")
    args = parser.parse_args()
    result = (
        train(
            args.dataset,
            args.output,
            steps=args.steps,
            device=args.device,
            train_encoder=args.train_encoder,
        )
        if args.command == "train"
        else calibrate(args.dataset, args.output)
    )
    print(json.dumps(result))


if __name__ == "__main__":
    main()
