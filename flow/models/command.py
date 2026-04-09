"""Command mode: rewrite-as-email, restructure, translate.

Reuses the cleanup LLM (Qwen3-30B-A3B by default) so there's no extra RAM
cost. Loaded on demand via a separate hotkey. Not in the hot path of normal
dictation.
"""

from __future__ import annotations

from flow.config import CommandCfg


COMMAND_SYSTEM_PROMPT = """You are a text transformation engine. You receive a dictated \
instruction along with a block of source text (selected by the user or the last \
dictated paragraph). Produce the transformed output ONLY — no preamble, no quotes, \
no explanation. Preserve tone unless the instruction says otherwise."""


class CommandLLM:
    def __init__(self, cfg: CommandCfg):
        self.cfg = cfg
        self._model = None
        self._tokenizer = None

    def _lazy_load(self) -> None:
        if self._model is not None:
            return
        from mlx_lm import load

        self._model, self._tokenizer = load(self.cfg.model)

    def run(self, instruction: str, source_text: str) -> str:
        self._lazy_load()
        from mlx_lm import generate

        messages = [
            {"role": "system", "content": COMMAND_SYSTEM_PROMPT},
            {
                "role": "user",
                "content": f"Instruction: {instruction}\n\nSource:\n{source_text}",
            },
        ]
        prompt = self._tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        out = generate(
            self._model,
            self._tokenizer,
            prompt=prompt,
            max_tokens=self.cfg.max_tokens,
            temp=0.3,
            verbose=False,
        )
        return out.strip()
