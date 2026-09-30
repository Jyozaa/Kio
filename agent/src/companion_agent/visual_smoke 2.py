"""Live OCR/Laya probe against the canvas fixture; reports but never executes."""

import argparse
import asyncio
import json
import time
from pathlib import Path

from .candidates import build_candidates
from .chooser import LayaChooser
from .driver import CuaDriver
from .metrics import Measurements
from .perception import CuaVisualPerceptionProvider, PerceptionContext
from .verification import GoalVerifier, VerificationStatus


async def run(args):
    async with CuaDriver.connect() as driver:
        await driver.health()
        visual = CuaVisualPerceptionProvider(driver)
        started = time.perf_counter()
        measurements = Measurements()
        if not 1 <= args.repeats <= 10:
            raise ValueError("repeats must be 1–10")
        with measurements.collect():
            for _ in range(args.repeats):
                result = await visual.perceive(
                    PerceptionContext("Click Settings", args.pid, args.window_id)
                )
        assert result.used_visual and result.regions
        assert result.frame.native_capture_id is not None
        assert all(not e.interactive for e in result.observation.elements if e.source == "VISUAL")
        table = build_candidates(result.observation, "Click Settings", visual_frame=result.frame)
        assert len(table.actions) <= 96
        visual_candidates = [
            candidate for candidate in table.actions.values() if candidate.payload.get("visual")
        ]
        assert visual_candidates, "OCR did not produce a goal-matched, capture-bound candidate"
        chooser = await asyncio.to_thread(LayaChooser)
        decision = await asyncio.to_thread(chooser.choose, "Click Settings", table, [])
        chosen = table.validate(decision.candidate_id, decision.snapshot_id)
        assert decision.operation == chosen.operation
        assert chosen.operation == "CLICK" and chosen.payload.get("visual")
        verification = GoalVerifier().check(
            "Click Settings", result.observation, result.observation, []
        )
        assert verification.status != VerificationStatus.VERIFIED
        if args.metrics:
            args.metrics.write_text(
                json.dumps(
                    {
                        "stages": measurements.summary(),
                        "regions": len(result.regions),
                        "candidates": len(table.actions),
                        "visual_candidates": len(visual_candidates),
                        "laya_seconds": decision.latency_seconds,
                        "actions": 0,
                        "gemini_calls": 0,
                        "capture_bound_available": driver.capabilities.capture_bound_pixels,
                        "execution": "not_attempted: visual candidate probe only",
                    },
                    indent=2,
                )
            )
        print(
            json.dumps(
                {
                    **visual.metrics,
                    "candidates": len(table.actions),
                    "visual_candidates": len(visual_candidates),
                    "operation": decision.operation,
                    "laya_seconds": decision.latency_seconds,
                    "elapsed_seconds": time.perf_counter() - started,
                    "capture_bound_available": driver.capabilities.capture_bound_pixels,
                    "execution": "not_attempted: visual candidate probe only",
                    "completion_verified": False,
                    "actions": 0,
                    "gemini_calls": 0,
                }
            )
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--window-id", type=int, required=True)
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--metrics", type=Path)
    asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    main()
