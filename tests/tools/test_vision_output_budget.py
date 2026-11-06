"""Budgets for the aux vision LLM: wall-clock deadline, analysis cap, reasoning fallback cap.

A ``vision_analyze`` call used to have no total budget: the aux client retries internally, so a
stalled route ran until the 420s concurrent-batch guard killed it with an opaque timeout, and a
reasoning-only answer arrived as hundreds of KB of chain-of-thought. These tests pin the three
contracts that stop that (t_81c23360).
"""
from __future__ import annotations

import asyncio
import json
import time

import pytest

from tools import vision_tools_output_budget as budget
from tools.vision_tools import vision_analyze_tool

VALID_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc```\x00\x00"
    b"\x00\x04\x00\x01\xf6\x178U\x00\x00\x00\x00IEND\xaeB`\x82"
)


def _image(tmp_path):
    path = tmp_path / "shot.png"
    path.write_bytes(VALID_PNG)
    return str(path)


def _content_response(text: str) -> dict:
    return {"choices": [{"message": {"content": text}}]}


def _config(monkeypatch, **vision) -> None:
    monkeypatch.setattr(
        "hermes_cli.config.load_config",
        lambda: {"auxiliary": {"vision": vision}},
    )


async def _analyze(tmp_path, prompt="describe this"):
    return json.loads(await vision_analyze_tool(_image(tmp_path), prompt, "test/model"))


class TestConfigKnobs:
    def test_budget_keys_are_settable_through_hermes_config(self):
        """The knobs are documented under `auxiliary.vision`; `hermes config set` must accept them."""
        from hermes_cli.config import _validate_config_key

        for key in ("auxiliary.vision.deadline", "auxiliary.vision.video_deadline",
                    "auxiliary.vision.max_analysis_chars", "auxiliary.vision.max_reasoning_chars"):
            assert _validate_config_key(key) == (True, None), key

    def test_defaults_and_invalid_values(self, monkeypatch):
        _config(monkeypatch)
        assert budget.resolve_deadline("image") == 240.0
        assert budget.resolve_deadline("video") == 360.0
        assert budget.resolve_max_analysis_chars() == 80_000
        assert budget.resolve_max_reasoning_chars() == 8_000

        _config(monkeypatch, deadline="nonsense", max_analysis_chars="x", max_reasoning_chars="x")
        assert budget.resolve_deadline("image") == 240.0
        assert budget.resolve_max_analysis_chars() == 80_000
        assert budget.resolve_max_reasoning_chars() == 8_000

    def test_video_falls_back_to_the_image_deadline(self, monkeypatch):
        _config(monkeypatch, deadline=90)
        assert budget.resolve_deadline("image") == 90.0
        assert budget.resolve_deadline("video") == 90.0

        _config(monkeypatch, deadline=90, video_deadline=30)
        assert budget.resolve_deadline("image") == 90.0
        assert budget.resolve_deadline("video") == 30.0

    def test_non_positive_deadline_disables_the_cap(self, monkeypatch):
        _config(monkeypatch, deadline=0)
        assert budget.resolve_deadline("image") is None


class TestAnalysisCap:
    def test_cap_appends_an_inline_truncation_note(self, monkeypatch):
        _config(monkeypatch, max_analysis_chars=1_000)
        text = "A" * 5_000
        capped, original, truncated = budget.cap_analysis("image", text)

        assert truncated is True
        assert original == 5_000
        assert capped.startswith("A" * 1_000)
        assert "[output truncated" in capped
        assert "5,000 characters" in capped
        assert len(capped) < 1_500

    def test_short_analysis_is_returned_unchanged(self, monkeypatch):
        _config(monkeypatch)
        capped, original, truncated = budget.cap_analysis("image", "A short answer")
        assert (capped, original, truncated) == ("A short answer", 14, False)

    @pytest.mark.asyncio
    async def test_tool_result_reports_truncation(self, tmp_path, monkeypatch):
        _config(monkeypatch, max_analysis_chars=1_000)
        response = _content_response("B" * 40_000)
        monkeypatch.setattr("tools.vision_tools.async_call_llm", _async_return(response))

        result = await _analyze(tmp_path)

        assert result["success"] is True
        assert result["truncated"] is True
        assert result["analysis_chars"] == 40_000
        assert "[output truncated" in result["analysis"]


class TestReasoningFallback:
    @pytest.mark.asyncio
    async def test_reasoning_only_response_is_bounded(self, tmp_path, monkeypatch):
        """A reasoning model that never emits content must not return its chain-of-thought."""
        from agent.auxiliary_client import extract_content_or_reasoning

        _config(monkeypatch, max_reasoning_chars=1_200)
        response = {"choices": [{"message": {"content": None, "reasoning": "r" * 50_000}}]}
        monkeypatch.setattr("tools.vision_tools.async_call_llm", _async_return(response))
        monkeypatch.setattr("tools.vision_tools.extract_content_or_reasoning", extract_content_or_reasoning)

        result = await _analyze(tmp_path)

        assert result["success"] is True
        assert len(result["analysis"]) == 1_200
        assert set(result["analysis"]) == {"r"}


class TestDeadline:
    @pytest.mark.asyncio
    async def test_stalled_call_ends_at_the_deadline_with_a_typed_error(self, tmp_path, monkeypatch):
        _config(monkeypatch, deadline=0.2)

        async def stall(**_kwargs):
            # health: allow HX013 -- the hang is the behaviour under test: the deadline must end this await
            await asyncio.sleep(30)
            return _content_response("never returned")

        monkeypatch.setattr("tools.vision_tools.async_call_llm", stall)

        started = time.monotonic()
        result = await _analyze(tmp_path)
        elapsed = time.monotonic() - started

        assert elapsed < 5, f"deadline did not fire: {elapsed:.1f}s"
        assert result["success"] is False
        assert result["error_type"] == "vision_deadline_exceeded"
        assert result["retryable"] is True
        assert result["timeout_s"] == pytest.approx(0.2, abs=0.01)
        assert "did not finish within" in result["analysis"]

    @pytest.mark.asyncio
    async def test_provider_timeout_is_typed_but_not_a_deadline(self, tmp_path, monkeypatch):
        _config(monkeypatch)

        async def timeout(**_kwargs):
            raise TimeoutError("Request timed out.")

        monkeypatch.setattr("tools.vision_tools.async_call_llm", timeout)

        result = await _analyze(tmp_path)

        assert result["success"] is False
        assert result["error_type"] == "vision_timeout"
        assert result["retryable"] is True

    @pytest.mark.asyncio
    async def test_deadline_disabled_lets_a_slow_call_finish(self, tmp_path, monkeypatch):
        _config(monkeypatch, deadline=0)

        async def slow(**_kwargs):
            # health: allow HX013 -- a slow-but-valid call is the behaviour under test (deadline 0 = unbounded)
            await asyncio.sleep(0.3)
            return _content_response("finished slowly")

        monkeypatch.setattr("tools.vision_tools.async_call_llm", slow)

        result = await _analyze(tmp_path)

        assert result["success"] is True
        assert result["analysis"] == "finished slowly"


def _async_return(value):
    async def _call(**_kwargs):
        return value

    return _call
