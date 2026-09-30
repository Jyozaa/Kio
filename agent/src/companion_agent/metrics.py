"""Opt-in, bounded timing only. Never captures arguments, goals, images or secrets."""

import contextvars
import functools
import inspect
import math
import statistics
import time
from collections import defaultdict
from contextlib import contextmanager

_active = contextvars.ContextVar("kio_metrics", default=None)


def record(stage, seconds):
    """Add a bounded stage sample when opt-in collection is active."""
    metrics = _active.get()
    if metrics is not None:
        metrics.add(stage, seconds)


class Measurements:
    def __init__(self):
        self.samples = defaultdict(list)

    def add(self, stage, seconds):
        if len(self.samples[stage]) < 2000:
            self.samples[stage].append(seconds)

    @contextmanager
    def collect(self):
        token = _active.set(self)
        try:
            yield self
        finally:
            _active.reset(token)

    def summary(self):
        result = {}
        for stage, values in self.samples.items():
            ordered = sorted(values)
            warm = values[1:]
            result[stage] = {
                "count": len(values),
                "median_ms": statistics.median(values) * 1000,
                "p90_ms": ordered[math.ceil(len(ordered) * 0.9) - 1] * 1000,
                "first_ms": values[0] * 1000,
                "warm_median_ms": statistics.median(warm) * 1000 if warm else None,
            }
        return result


def timed(stage):
    def decorate(function):
        if inspect.iscoroutinefunction(function):

            @functools.wraps(function)
            async def asynchronous(*args, **kwargs):
                metrics = _active.get()
                started = time.perf_counter()
                try:
                    return await function(*args, **kwargs)
                finally:
                    if metrics is not None:
                        metrics.add(stage, time.perf_counter() - started)

            return asynchronous

        @functools.wraps(function)
        def synchronous(*args, **kwargs):
            metrics = _active.get()
            started = time.perf_counter()
            try:
                return function(*args, **kwargs)
            finally:
                if metrics is not None:
                    metrics.add(stage, time.perf_counter() - started)

        return synchronous

    return decorate
