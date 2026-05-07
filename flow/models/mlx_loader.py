"""Compatibility helpers for MLX-LM model loading."""

from __future__ import annotations

from typing import Any, cast


def load_model_and_tokenizer(model_id: str) -> tuple[Any, Any]:
    """Return ``(model, tokenizer)`` across MLX-LM load API variants.

    Recent ``mlx_lm.load`` type hints expose either ``(model, tokenizer)`` or
    ``(model, tokenizer, config)`` depending on options/version. Witzper only
    needs the first two values, so normalize the return shape at the boundary.
    """
    try:
        from mlx_lm import load
    except ImportError as e:
        raise RuntimeError("pip install mlx-lm") from e

    loaded = cast(tuple[Any, ...], load(model_id))
    if len(loaded) < 2:
        raise RuntimeError(f"mlx_lm.load returned unexpected return shape: {len(loaded)}")
    return loaded[0], loaded[1]


def apply_chat_template_no_think(
    tokenizer: Any,
    messages: list[dict[str, str]],
    *,
    add_generation_prompt: bool,
) -> str:
    """Apply a chat template with Qwen-style thinking disabled when supported."""
    try:
        return tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=add_generation_prompt,
            enable_thinking=False,
        )
    except TypeError:
        return tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=add_generation_prompt,
        )


def strip_thinking_blocks(text: str) -> str:
    """Remove leaked Qwen ``<think>...</think>`` traces from generated text."""
    out = text.strip()
    while "<think>" in out:
        start = out.find("<think>")
        end = out.find("</think>", start)
        if end == -1:
            return out[:start].strip()
        out = (out[:start] + out[end + len("</think>") :]).strip()
    return out
