"""Opt-in explicit-browser launch and exact address-field verification smoke."""

import argparse
import asyncio
import json

from .direct import execute_direct, parse_direct
from .driver import CuaDriver, DriverError


async def run(application: str, url: str) -> int:
    command = parse_direct(f"Open {url} in {application}")
    if command is None or command.application_name is None:
        raise ValueError("invalid_browser_smoke_request")
    async with CuaDriver.connect() as driver:
        await driver.health()
        result = await execute_direct(command, driver, asyncio.Event())
    print(
        json.dumps(
            {
                "status": result["status"],
                "path": result["path"],
                "application": application,
                "evidence": [
                    {"kind": item.kind, "expected": item.expected, "observed": item.observed}
                    for item in result.get("evidence", ())
                ],
                "gemini_calls": 0,
            }
        ),
        flush=True,
    )
    return 0 if result["status"] == "completed" else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--application", required=True)
    parser.add_argument("--url", required=True)
    args = parser.parse_args()
    try:
        raise SystemExit(asyncio.run(run(args.application, args.url)))
    except DriverError as error:
        print(json.dumps({"status": "error", "reason": error.code}), flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
