"""Explicit-target harmless local loop smoke; no implicit frontmost-window choice."""

import argparse
import asyncio
import json
import resource
from dataclasses import asdict
from pathlib import Path

from .chooser import LayaChooser
from .driver import CuaDriver
from .loop import AgentLoop
from .metrics import Measurements
from .system2 import MockSystem2
from .trajectories import TrajectoryRecorder


async def run(args):
    chooser = await asyncio.to_thread(LayaChooser)
    async with CuaDriver.connect() as driver:
        await driver.health()
        loop = AgentLoop(
            driver,
            chooser,
            recorder=(
                TrajectoryRecorder(args.goal, root=args.trajectory_root) if args.record else None
            ),
            system2=MockSystem2() if args.mock_system2 else None,
            emit=lambda status, text: print(json.dumps({"event": status}), flush=True),
        )
        cancelled = asyncio.Event()
        timer = None
        if args.stop_after is not None:
            timer = asyncio.get_running_loop().call_later(args.stop_after, cancelled.set)
        metrics = Measurements()
        try:
            with metrics.collect():
                result = await loop.run(args.goal, args.pid, args.window_id, cancelled)
        finally:
            if timer:
                timer.cancel()
        if args.metrics:
            args.metrics.parent.mkdir(parents=True, exist_ok=True)
            args.metrics.write_text(
                json.dumps(
                    {
                        "stages": metrics.summary(),
                        "cold_model_seconds": chooser.cold_load_seconds,
                        "status": result.status,
                        "actions": result.steps,
                        "gemini_calls": result.gemini_calls,
                        "peak_rss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
                        / 1024**2,
                    },
                    indent=2,
                )
            )
        print(json.dumps(asdict(result)), flush=True)
        return result.status == ("cancelled" if args.stop_after is not None else "completed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--window-id", type=int, required=True)
    parser.add_argument("--goal", required=True)
    parser.add_argument("--mock-system2", action="store_true")
    parser.add_argument("--metrics", type=Path)
    parser.add_argument(
        "--stop-after", type=float, help="Live cancellation fault injection after seconds"
    )
    parser.add_argument(
        "--record", action="store_true", help="Opt in to sanitized structured trajectory storage"
    )
    parser.add_argument(
        "--trajectory-root",
        type=Path,
        help="Optional destination for the opt-in sanitized trajectory (requires --record)",
    )
    args = parser.parse_args()
    if args.trajectory_root and not args.record:
        parser.error("--trajectory-root requires --record")
    raise SystemExit(0 if asyncio.run(run(args)) else 1)


if __name__ == "__main__":
    main()
