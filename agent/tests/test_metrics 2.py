import asyncio

import pytest

from companion_agent.metrics import Measurements, record, timed


def test_metrics_bound_thread_propagation_and_no_arguments():
    @timed("local")
    def work(secret):
        return 42

    async def run():
        with Measurements().collect() as metrics:
            assert await asyncio.to_thread(work, "private-secret") == 42
            for _ in range(2005):
                work("private-secret")
        assert metrics.summary()["local"]["count"] == 2000
        assert "secret" not in str(metrics.summary())
        work("outside scope")
        assert metrics.summary()["local"]["count"] == 2000

    asyncio.run(run())


def test_route_specific_stage_recording_is_opt_in_and_reports_distribution():
    metrics = Measurements()
    record("accessibility_action", 99)
    with metrics.collect():
        record("accessibility_action", 0.1)
        record("accessibility_action", 0.2)
        record("dom_observation", 0.05)
    summary = metrics.summary()
    result = summary["accessibility_action"]
    assert result["count"] == 2
    assert result["median_ms"] == pytest.approx(150.0)
    assert result["p90_ms"] == pytest.approx(200.0)
    assert result["first_ms"] == pytest.approx(100.0)
    assert result["warm_median_ms"] == pytest.approx(200.0)
    assert summary["dom_observation"]["count"] == 1
    assert "99" not in str(summary)
