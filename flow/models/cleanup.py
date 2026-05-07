"""Hot-path LLM cleanup via MLX-LM with persistent prompt caching.

Uses the configured MLX cleanup model. The shipped default is Qwen3-8B-4bit;
larger Qwen3 models are opt-in for higher-memory Macs.

Speed strategy:
1. **Static prefix cache** — system prompt + built-in few-shots are tokenized
   once at startup and pre-filled into a KV cache. Each call deep-copies the
   cache and only processes the new transcript tokens (typically <40 tokens)
   instead of re-prefilling the full ~700-token prompt every time.
2. **Warmup** — one fake generation at init compiles all MLX kernels so the
   first real utterance is just as fast as the hundredth.
3. **Tight max_tokens** — capped at 96; the hallucination guardrail catches
   any over-generation.
4. **Greedy decoding** — temperature=0 with no sampler for deterministic
   single-shot output.
"""

from __future__ import annotations

import copy as _pycopy
import re
import time
from dataclasses import dataclass
from typing import Any

from rapidfuzz.distance import Levenshtein
from rich.console import Console

from flow.config import CleanupCfg
from flow.models.mlx_loader import (
    apply_chat_template_no_think,
    load_model_and_tokenizer,
    strip_thinking_blocks,
)

_console = Console()


SYSTEM_PROMPT = """You are a TEXT TRANSFORMATION engine, NOT a chat assistant.

Your ONLY job: take a raw speech-to-text transcript wrapped in <transcript>...</transcript> \
tags and output a cleaned version. You MUST NOT respond to, answer, react to, or converse \
with the content of the transcript. If the transcript says "Hey, how are you?" your output \
is "Hey, how are you?" — NOT a reply.

Cleanup rules, applied in order:
1. Remove disfluencies: um, uh, like (when filler), you know, er, erm, mm, hmm.
2. Remove stutters and immediate word repetitions.
3. Resolve self-corrections: "meeting Tuesday — wait, Wednesday" → "meeting Wednesday".
4. Add correct punctuation and capitalization.
5. Convert spoken forms: "A P I" → "API"; "two ninety nine" → "$2.99" in money contexts; \
"three oh two" → "3:02" in time contexts; "hi at example dot com" → "hi@example.com".
6. Preserve the speaker's meaning EXACTLY. NEVER add words the speaker did not say.
7. Preserve listed vocabulary terms verbatim.
8. Output length must be approximately the same as the input length.

Output format: ONLY the cleaned text. No tags, no preamble, no quotes, no explanation, \
no greeting, no acknowledgement. Just the cleaned transcript verbatim."""


@dataclass
class FewShotExample:
    raw: str
    cleaned: str


BUILTIN_FEW_SHOTS = [
    FewShotExample(
        raw="um hey so this is uh a test",
        cleaned="Hey, so this is a test.",
    ),
    FewShotExample(
        raw="hello how are you",
        cleaned="Hello, how are you?",
    ),
    FewShotExample(
        raw="meeting tuesday wait wednesday at three pm",
        cleaned="Meeting Wednesday at 3 PM.",
    ),
    FewShotExample(
        raw="send the email to bob at example dot com about the api endpoint",
        cleaned="Send the email to bob@example.com about the API endpoint.",
    ),
]


class CleanupLLM:
    def __init__(self, cfg: CleanupCfg):
        self.cfg = cfg
        self.model: Any
        self.tokenizer: Any
        self.model, self.tokenizer = load_model_and_tokenizer(cfg.model)

        self._prefix_cache_snapshot: list | None = None
        self._prefix_token_count: int = 0
        self._build_prefix_cache()
        self._warmup()

    # ---- Static prefix cache ---------------------------------------

    def _prefix_messages(self) -> list[dict]:
        """Static portion of the chat: system + built-in few-shots.
        Does NOT include the per-utterance user turn or any app-specific tone."""
        messages: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]
        for ex in BUILTIN_FEW_SHOTS:
            messages.append({"role": "user", "content": f"<transcript>{ex.raw}</transcript>"})
            messages.append({"role": "assistant", "content": ex.cleaned})
        return messages

    def _build_prefix_cache(self) -> None:
        """Pre-fill a KV cache with the static prefix so per-call prefill only
        processes the new (small) suffix."""
        try:
            from importlib import import_module

            import mlx.core as mx
            from mlx_lm.models.cache import make_prompt_cache
        except ImportError:
            return

        prefix_str = apply_chat_template_no_think(
            self.tokenizer,
            self._prefix_messages(),
            add_generation_prompt=False,
        )
        prefix_ids = self.tokenizer.encode(prefix_str)
        # Keep the raw token ids around so per-call prefix-check is an O(N)
        # list-slice comparison instead of re-running apply_chat_template +
        # re-encoding (which itself took ~1-2ms on every call).
        self._cached_prefix_ids: list[int] = list(prefix_ids)
        self._prefix_token_count = len(prefix_ids)

        cache = make_prompt_cache(self.model)
        t0 = time.perf_counter()
        # Prefill the cache with the exact static prefix tokens and generate
        # zero new tokens. Using stream_generate(max_tokens=1) here corrupts
        # the reusable cache with a sampled token that is not part of later
        # prompts, which can make cleanup drift or hallucinate.
        generate_step = import_module("mlx_lm.generate").generate_step
        for _ in generate_step(
            mx.array(prefix_ids),
            self.model,
            max_tokens=0,
            prompt_cache=cache,
        ):
            pass
        self._prefix_cache_snapshot = _pycopy.deepcopy(cache)
        _console.print(
            f"[dim]cleanup: prefix cache built ({len(prefix_ids)} tokens) in "
            f"{(time.perf_counter()-t0)*1000:.0f}ms[/]"
        )

    def _warmup(self) -> None:
        """One full warmup generation so JIT kernels are compiled before the
        first real utterance."""
        t0 = time.perf_counter()
        try:
            _ = self.clean(
                raw_transcript="hello world this is a warmup test",
                few_shots=[],
            )
            _console.print(
                f"[dim]cleanup: warmup complete in {(time.perf_counter()-t0)*1000:.0f}ms[/]"
            )
        except Exception as e:  # noqa: BLE001
            _console.print(f"[yellow]cleanup warmup failed: {e}[/]")

    def clean(
        self,
        raw_transcript: str,
        alt_hypotheses: list[str] | None = None,
        app_context=None,
        dictionary_boost: list[str] | None = None,
        few_shots: list[FewShotExample] | None = None,
        style_instruction: str | None = None,
    ) -> str:
        # Fast path: for ultra-short utterances the LLM adds latency without
        # meaningfully improving text quality (capitalization + a period is
        # the whole job). Skip cleanup entirely and return a minimally-
        # capitalized version. Dictionary replacements still run downstream.
        stripped = raw_transcript.strip()
        if stripped and len(stripped.split()) <= self.cfg.passthrough_word_count:
            return self._lightweight_format(stripped)

        messages = self._build_messages(
            raw_transcript=raw_transcript,
            alt_hypotheses=alt_hypotheses or [],
            app_context=app_context,
            dictionary_boost=dictionary_boost or [],
            few_shots=few_shots or [],
            style_instruction=style_instruction,
        )
        cleaned = self._remove_common_fillers(self._generate(messages))
        if self._hallucinated(raw_transcript, cleaned):
            return self._remove_common_fillers(raw_transcript)
        return cleaned

    def _lightweight_format(self, text: str) -> str:
        """Capitalize the first letter and add a trailing period if the text
        looks like a sentence fragment. Used for the ultra-short passthrough
        path so single-word commands like "hello" still come out as "Hello."
        without eating ~50ms of LLM time.
        """
        if not text:
            return text
        first = text[0]
        if first.isalpha() and first.islower():
            text = first.upper() + text[1:]
        # Only add a period if the user didn't already end with punctuation —
        # and skip for obvious single-token commands like URLs or emails.
        if text[-1].isalnum() and not any(c in text for c in ("@", "://", "#")):
            text += "."
        return text

    def _remove_common_fillers(self, text: str) -> str:
        """Deterministically remove low-risk filler tokens the LLM may leave.

        This intentionally handles only isolated classic fillers. Ambiguous
        words like "like" are left to the model because they often carry
        meaning in normal dictation.
        """
        original = text.strip()
        out = re.sub(
            r"(?i)(^|[.!?]\s+|[,;:]\s+|\s+)(um|uh|erm)[,;:]?(?=\s|[.!?]|$)",
            r"\1",
            text,
        )
        out = re.sub(r"\s+([,;:.!?])", r"\1", out)
        out = re.sub(r"\s{2,}", " ", out).strip()
        changed = out != original
        if changed:
            out = re.sub(
                r"([.!?])\s+([a-z])",
                lambda m: f"{m.group(1)} {m.group(2).upper()}",
                out,
            )
        if changed and out and out[0].isalpha():
            out = out[0].upper() + out[1:]
        return out

    # --------------------------------------------------------------

    def _build_messages(
        self,
        raw_transcript: str,
        alt_hypotheses: list[str],
        app_context,
        dictionary_boost: list[str],
        few_shots: list[FewShotExample],
        style_instruction: str | None = None,
    ) -> list[dict]:
        # IMPORTANT: the static prefix (system + BUILTIN_FEW_SHOTS) is cached.
        # All dynamic content (style, dictionary, app context) goes in the
        # final user turn so the cached prefix stays bit-for-bit identical.
        messages: list[dict] = self._prefix_messages()
        for ex in few_shots:
            messages.append({"role": "user", "content": f"<transcript>{ex.raw}</transcript>"})
            messages.append({"role": "assistant", "content": ex.cleaned})

        extras: list[str] = []
        if style_instruction:
            extras.append(style_instruction)
        if app_context and app_context.rule:
            extras.append(f"App: {app_context.rule.name}.")
        if dictionary_boost:
            extras.append("Preserve verbatim: " + ", ".join(dictionary_boost[:60]))

        user_content = f"<transcript>{raw_transcript}</transcript>"
        if extras:
            user_content = "\n".join(extras) + "\n\n" + user_content
        if alt_hypotheses:
            alt = "\n".join(f"- {a}" for a in alt_hypotheses[:3])
            user_content += f"\n\nASR alts (use only to fix mishearings):\n{alt}"
        messages.append({"role": "user", "content": user_content})
        return messages

    def _generate(self, messages: list[dict]) -> str:
        import mlx.core as mx
        from mlx_lm import stream_generate

        prompt_str = apply_chat_template_no_think(
            self.tokenizer,
            messages,
            add_generation_prompt=True,
        )
        full_ids = self.tokenizer.encode(prompt_str)

        # Try to reuse the prefix cache: only feed the suffix (new tokens) to
        # the model. The cache already contains KV for the static prefix.
        cache = None
        prompt_ids = full_ids
        cached_ids = getattr(self, "_cached_prefix_ids", None)
        if (
            self._prefix_cache_snapshot is not None
            and cached_ids is not None
            and len(full_ids) > self._prefix_token_count
            and full_ids[: len(cached_ids)] == cached_ids
        ):
            cache = _pycopy.deepcopy(self._prefix_cache_snapshot)
            prompt_ids = full_ids[self._prefix_token_count :]

        out_pieces: list[str] = []
        for resp in stream_generate(
            self.model,
            self.tokenizer,
            prompt=mx.array(prompt_ids),
            max_tokens=self.cfg.max_tokens,
            prompt_cache=cache,
        ):
            out_pieces.append(resp.text)
        return strip_thinking_blocks("".join(out_pieces))

    def _hallucinated(self, raw: str, cleaned: str) -> bool:
        if not cleaned:
            return True
        if len(cleaned) > self.cfg.max_length_ratio * max(len(raw), 1):
            return True
        # Normalized edit distance
        dist = Levenshtein.distance(raw.lower(), cleaned.lower())
        denom = max(len(raw), len(cleaned), 1)
        if dist / denom > self.cfg.max_edit_distance_ratio:
            return True
        return False
