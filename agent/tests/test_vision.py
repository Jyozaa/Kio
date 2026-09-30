import asyncio
import json

import httpx
import pytest

from companion_agent.driver import DriverError
from companion_agent.system2 import GeminiSystem2, validate_response


def guidance(**changes):
    return {"kind": "guidance", "focus": "Choose the requested next step.", **changes}


@pytest.mark.parametrize(
    "changes",
    [
        {"focus": "click 100, 200"},
        {"focus": "x=50 y=20"},
        {"focus": "Use document.querySelector"},
        {"focus": "Use XPath //button"},
        {"focus": "Run bash"},
        {"focus": "cua-driver click"},
        {"shell": "do something"},
        {"focus": ""},
    ],
)
def test_text_guidance_contract_rejects_execution_authority(changes):
    with pytest.raises(DriverError):
        validate_response(guidance(**changes), "guidance")


def test_text_guidance_has_no_image_parts_or_tool_schema():
    def handle(request):
        body = json.loads(request.content)
        parts = body["contents"][0]["parts"]
        assert len(parts) == 1 and "inlineData" not in parts[0]
        assert "tools" not in body
        return httpx.Response(
            200, json={"candidates": [{"content": {"parts": [{"text": json.dumps(guidance())}]}}]}
        )

    adapter = GeminiSystem2("secret", "model", transport=httpx.MockTransport(handle))
    assert asyncio.run(adapter.guide("Settings", ["Settings"])) == guidance()
    assert adapter.calls == 1


@pytest.mark.parametrize(
    "parts",
    [
        [{"text": json.dumps(guidance()), "functionCall": {"name": "click"}}],
        [{"text": "not JSON"}],
        [{"text": json.dumps(guidance(focus="x" * 501))}],
    ],
)
def test_invalid_provider_parts(parts):
    adapter = GeminiSystem2(
        "secret",
        "model",
        transport=httpx.MockTransport(
            lambda _: httpx.Response(200, json={"candidates": [{"content": {"parts": parts}}]})
        ),
    )
    with pytest.raises(DriverError, match="invalid_system2_response"):
        asyncio.run(adapter.guide("Settings", ["Settings"]))


def test_missing_key_and_vision_settings_are_not_supported(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_MODEL", raising=False)
    assert GeminiSystem2.from_environment() is None


@pytest.mark.parametrize("failure", ["timeout", "rate_limit", "oversize"])
def test_text_transport_failures_are_bounded(failure):
    def handle(request):
        if failure == "timeout":
            raise httpx.ReadTimeout("sensitive detail")
        return httpx.Response(429 if failure == "rate_limit" else 200, content=b"x" * 40000)

    adapter = GeminiSystem2("private-key", "model", transport=httpx.MockTransport(handle))
    with pytest.raises(DriverError) as error:
        asyncio.run(adapter.guide("Settings", ["Settings"]))
    assert "private-key" not in str(error.value) and "sensitive" not in str(error.value)
