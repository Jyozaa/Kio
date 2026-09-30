"""Opt-in real-observation safety checks; deliberately never execute desktop actions."""

import argparse
import asyncio
import json
from dataclasses import replace

from .candidates import Operation
from .chooser import MockChooser
from .driver import CuaDriver
from .loop import AgentLoop
from .system2 import MockSystem2


class GuardedDriver:
    def __init__(self, driver, *, inject_change=False):
        self.driver = driver
        self.observations = 0
        self.executions = 0
        self.inject_change = inject_change

    async def observe(self, pid, window_id):
        observation = await self.driver.observe(pid, window_id)
        self.observations += 1
        if self.inject_change and self.observations == 2:
            # Fault injection at the observation boundary, not a fabricated live result.
            controls = tuple(
                replace(e, value="injected observation change") if e.role == "AXWindow" else e
                for e in observation.controls
            )
            observation = replace(observation, controls=controls)
        return observation

    async def execute(self, action, *, text=None):
        self.executions += 1
        raise AssertionError("Safety scenario attempted an action")


async def run(args):
    async with CuaDriver.connect() as native:
        await native.health()
        for name in ("consequential", "stale_observation", "low_confidence", "stop", "false_done"):
            driver = GuardedDriver(native, inject_change=name == "stale_observation")
            cancelled = asyncio.Event()
            system2 = MockSystem2() if name == "low_confidence" else None
            if name == "consequential":
                goal, choices = "Click Buy now", [(Operation.CLICK, "Buy now", 0.99)]
                expected = "needs_user"
            else:
                goal = 'Enter "safety check" into Message field'
                choices = [(Operation.TYPE_TEXT, "Message", 0.1)] * 2
                expected = "needs_user"
                if name == "stale_observation":
                    choices[0] = (Operation.TYPE_TEXT, "Message", 0.99)
                if name == "stop":
                    choices = [(Operation.TYPE_TEXT, "Message", 0.99)]
                    expected = "cancelled"
                if name == "false_done":
                    goal = "Reach Success"
                    choices = [(Operation.DONE, "", 0.99)] * 2
            chooser = MockChooser(choices)
            if name == "stop":
                choose = chooser.choose
                event_loop = asyncio.get_running_loop()

                def stop_during_choice(
                    *values, event_loop=event_loop, cancelled=cancelled, choose=choose
                ):
                    event_loop.call_soon_threadsafe(cancelled.set)
                    return choose(*values)

                chooser.choose = stop_during_choice
            result = await AgentLoop(driver, chooser, system2=system2).run(
                goal, args.pid, args.window_id, cancelled
            )
            assert result.status == expected, (name, result)
            assert driver.executions == 0
            if name == "stale_observation":
                assert driver.observations >= 3 and chooser.calls == 2
            if name == "low_confidence":
                assert system2.calls == 1 and chooser.calls == 2
            if name == "false_done":
                assert any(e.kind == "marker" and e.observed is None for e in result.evidence)
            print(
                json.dumps(
                    {
                        "check": name,
                        "status": result.status,
                        "executions": driver.executions,
                        "gemini_calls": result.gemini_calls,
                    }
                ),
                flush=True,
            )
        observation = await native.observe(args.pid, args.window_id)
        assert any(e.label == "Purchase action has not run" for e in observation.controls)
        assert not any("FAIL: purchase" in e.label for e in observation.controls)
        print(json.dumps({"purchase_handler": "not run", "passed": 5}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--window-id", type=int, required=True)
    asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    main()
