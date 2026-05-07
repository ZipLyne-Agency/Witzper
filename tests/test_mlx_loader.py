import sys
import types

import pytest

from flow.models.mlx_loader import (
    apply_chat_template_no_think,
    load_model_and_tokenizer,
    strip_thinking_blocks,
)


@pytest.fixture(autouse=True)
def fake_mlx_lm(monkeypatch):
    module = types.ModuleType("mlx_lm")
    monkeypatch.setitem(sys.modules, "mlx_lm", module)
    return module


def test_load_model_and_tokenizer_accepts_two_value_load(fake_mlx_lm) -> None:
    fake_mlx_lm.load = lambda model_id: ("model", "tokenizer")

    assert load_model_and_tokenizer("stub") == ("model", "tokenizer")


def test_load_model_and_tokenizer_accepts_three_value_load(fake_mlx_lm) -> None:
    fake_mlx_lm.load = lambda model_id: ("model", "tokenizer", {"quant": "4bit"})

    assert load_model_and_tokenizer("stub") == ("model", "tokenizer")


def test_load_model_and_tokenizer_rejects_unexpected_shape(fake_mlx_lm) -> None:
    fake_mlx_lm.load = lambda model_id: ("model",)

    with pytest.raises(RuntimeError, match="unexpected return"):
        load_model_and_tokenizer("stub")


def test_apply_chat_template_no_think_uses_supported_flag() -> None:
    calls = {}

    class Tokenizer:
        def apply_chat_template(self, messages, **kwargs):
            calls.update(kwargs)
            return "PROMPT"

    assert apply_chat_template_no_think(
        Tokenizer(), [{"role": "user", "content": "hi"}], add_generation_prompt=True
    ) == "PROMPT"
    assert calls["enable_thinking"] is False


def test_strip_thinking_blocks_removes_complete_trace() -> None:
    assert strip_thinking_blocks("<think>hidden</think>\nFinal text.") == "Final text."


def test_strip_thinking_blocks_drops_incomplete_trace() -> None:
    assert strip_thinking_blocks("Final text.\n<think>unfinished") == "Final text."
