import asyncio
import json

import httpx
import pytest

from companion_agent.candidates import Operation
from companion_agent.chooser import MockChooser
from companion_agent.driver import DriverError, FakeDriver
from companion_agent.loop import AgentLoop
from companion_agent.system2 import GeminiSystem2, MockSystem2, validate_response


class FieldDriver(FakeDriver):
    def __init__(self):
        super().__init__(
            [
                {
                    "elements": [
                        {
                            "element_index": 0,
                            "element_token": "s00000000:0",
                            "role": "AXTextField",
                            "label": "Message",
                            "value": "",
                            "visible": True,
                        }
                    ]
                }
            ]
        )
        self.actions = []

    async def execute(self, action, *, text=None):
        self.actions.append(action)
        self.snapshots[0]["elements"][0]["value"] = text


def test_literal_zero_calls_and_generation_one_call():
    async def scenario():
        for goal, expected_calls in [
            ('Enter "hello world" into the Message field', 0),
            ("Write a friendly greeting in the Message field", 1),
        ]:
            driver = FieldDriver()
            system2 = MockSystem2()
            chooser = MockChooser([(Operation.TYPE_TEXT, "Message", 0.9)] * 3)
            result = await AgentLoop(driver, chooser, system2=system2).run(
                goal, 1, 2, asyncio.Event()
            )
            assert result.status == "completed"
            assert system2.calls == expected_calls == result.gemini_calls
            assert len(driver.actions) == 1

    asyncio.run(scenario())


def test_bounded_recovery_reobserves_and_guidance_is_passed():
    async def scenario():
        driver = FieldDriver()
        system2 = MockSystem2()

        class RecordingChooser(MockChooser):
            def choose(self, goal, table, history, guidance=""):
                if self.calls:
                    assert guidance == system2.focus
                return super().choose(goal, table, history, guidance)

        chooser = RecordingChooser([(Operation.TYPE_TEXT, "Message", 0.2)] * 3)
        result = await AgentLoop(driver, chooser, system2=system2).run(
            'Enter "hello" into Message field', 1, 2, asyncio.Event()
        )
        assert result.status == "needs_user"
        assert system2.calls == 1 and chooser.calls == 2 and driver.observations == 2
        assert not driver.actions

    asyncio.run(scenario())


@pytest.mark.parametrize("system2", [None, MockSystem2(malformed=True)])
def test_no_key_or_malformed_generation_executes_nothing(system2):
    async def scenario():
        driver = FieldDriver()
        result = await AgentLoop(
            driver, MockChooser([(Operation.TYPE_TEXT, "Message", 0.99)]), system2=system2
        ).run("Write a greeting in Message field", 1, 2, asyncio.Event())
        assert result.status in {"needs_user", "error"}
        assert not driver.actions

    asyncio.run(scenario())


@pytest.mark.parametrize(
    "data",
    [
        {"kind": "guidance", "focus": "ok", "shell": "bad"},
        {"kind": "guidance", "focus": "click coordinates 20, 40"},
        {"kind": "guidance", "focus": ""},
        {"kind": "generated_text", "text": "x" * 4001},
    ],
)
def test_schema_rejects(data):
    with pytest.raises(DriverError):
        validate_response(data, data["kind"])


@pytest.mark.parametrize(
    "status,body,expected",
    [
        (429, {}, "system2_rate_limited"),
        (500, {}, "system2_unavailable"),
        (200, {}, "invalid_system2_response"),
    ],
)
def test_http_failures_do_not_expose_key(status, body, expected):
    adapter = GeminiSystem2(
        "test-secret",
        "test-model",
        transport=httpx.MockTransport(lambda request: httpx.Response(status, json=body)),
    )
    with pytest.raises(DriverError, match=expected) as error:
        asyncio.run(adapter.generate("greeting", "Message"))
    assert "test-secret" not in str(error.value)


def test_success_schema_and_minimal_context():
    def handle(request):
        assert request.headers["x-goog-api-key"] == "test-secret"
        assert "test-secret" not in str(request.url)
        data = json.loads(request.content)
        assert "tools" not in data
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {"content": {"parts": [{"text": '{"kind":"generated_text","text":"Hello!"}'}]}}
                ]
            },
        )

    adapter = GeminiSystem2("test-secret", "test-model", transport=httpx.MockTransport(handle))
    assert asyncio.run(adapter.generate("greeting", "Message"))["text"] == "Hello!"


def test_timeout_and_response_size():
    def timeout(request):
        raise httpx.ReadTimeout("private detail")

    for transport, expected in [
        (httpx.MockTransport(timeout), "system2_timeout"),
        (
            httpx.MockTransport(lambda request: httpx.Response(200, content=b"x" * 40000)),
            "invalid_system2_response",
        ),
    ]:
        adapter = GeminiSystem2("secret", "model", transport=transport)
        with pytest.raises(DriverError, match=expected):
            asyncio.run(adapter.generate("greeting", "Message"))
