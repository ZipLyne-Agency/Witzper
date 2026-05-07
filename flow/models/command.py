"""Command mode: rewrite-as-email, restructure, translate.

Reuses the configured command/cleanup-class LLM so there's no extra RAM when
the selected command model matches the cleanup model. Loaded on demand via a
separate hotkey. Not in the hot path of normal dictation.
"""

from __future__ import annotations

from typing import Any

from flow.config import CommandCfg
from flow.models.mlx_loader import (
    apply_chat_template_no_think,
    load_model_and_tokenizer,
    strip_thinking_blocks,
)

COMMAND_SYSTEM_PROMPT = """You are a text transformation engine. You receive a dictated \
instruction along with a block of source text (selected by the user or the last \
dictated paragraph). Produce the transformed output ONLY — no preamble, no quotes, \
no explanation. Preserve tone unless the instruction says otherwise."""


class CommandLLM:
    def __init__(self, cfg: CommandCfg):
        self.cfg = cfg
        self._model: Any | None = None
        self._tokenizer: Any | None = None

    def _lazy_load(self) -> None:
        if self._model is not None:
            return
        self._model, self._tokenizer = load_model_and_tokenizer(self.cfg.model)

    def run(self, instruction: str, source_text: str) -> str:
        self._lazy_load()
        from mlx_lm import generate
        from mlx_lm.sample_utils import make_sampler

        if self._model is None or self._tokenizer is None:
            raise RuntimeError("Command model failed to load")

        messages = [
            {"role": "system", "content": COMMAND_SYSTEM_PROMPT},
            {
                "role": "user",
                "content": f"Instruction: {instruction}\n\nSource:\n{source_text}",
            },
        ]
        prompt = apply_chat_template_no_think(
            self._tokenizer, messages, add_generation_prompt=True
        )
        out = generate(
            self._model,
            self._tokenizer,
            prompt=prompt,
            max_tokens=self.cfg.max_tokens,
            sampler=make_sampler(temp=0.3),
            verbose=False,
        )
        return strip_thinking_blocks(out)
