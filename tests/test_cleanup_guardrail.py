from unittest.mock import MagicMock

from flow.config import CleanupCfg
from flow.models.cleanup import CleanupLLM


def _mk(cleanup_output: str) -> CleanupLLM:
    cfg = CleanupCfg(model="stub", max_tokens=128, temperature=0.2, few_shot_n=0)
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
