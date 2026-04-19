from unittest.mock import MagicMock

from flow.config import CleanupCfg
from flow.models.cleanup import CleanupLLM


def _mk(cleanup_output: str) -> CleanupLLM:
    # passthrough_word_count=0 disables the short-utterance fast path so
    # these tests exercise the LLM guardrail directly.
    cfg = CleanupCfg(
        model="stub",
        max_tokens=128,
        temperature=0.2,
        few_shot_n=0,
        passthrough_word_count=0,
    )
    obj = CleanupLLM.__new__(CleanupLLM)
    obj.cfg = cfg
    obj.model = MagicMock()
    obj.tokenizer = MagicMock()
    obj._generate = lambda messages: cleanup_output  # type: ignore[assignment]
    return obj


def test_guardrail_rejects_long_hallucination() -> None:
    llm = _mk("this is a wildly long unrelated essay " * 50)
    result = llm.clean(raw_transcript="hello world", few_shots=[])
    assert result == "hello world"


def test_guardrail_accepts_reasonable_cleanup() -> None:
    llm = _mk("Hello world.")
    result = llm.clean(raw_transcript="hello world", few_shots=[])
    assert result == "Hello world."


def test_passthrough_skips_llm_for_short_utterance() -> None:
    cfg = CleanupCfg(model="stub", passthrough_word_count=2)
    obj = CleanupLLM.__new__(CleanupLLM)
    obj.cfg = cfg
    obj.model = MagicMock()
    obj.tokenizer = MagicMock()
    # _generate must NOT be called — raise if it is.
    called = {"n": 0}

    def _forbidden(_messages):
        called["n"] += 1
        return "UNEXPECTED"

    obj._generate = _forbidden  # type: ignore[assignment]
    assert obj.clean(raw_transcript="hello", few_shots=[]) == "Hello."
    assert obj.clean(raw_transcript="hi there", few_shots=[]) == "Hi there."
    assert called["n"] == 0


def test_passthrough_off_by_default_for_long_utterance() -> None:
    llm = _mk("Hello world, this is the cleaned version.")
    result = llm.clean(
        raw_transcript="hello world this is the transcribed version",
        few_shots=[],
    )
    assert result == "Hello world, this is the cleaned version."
