"""Hot-path LLM cleanup via MLX-LM with persistent prompt caching.

Uses Qwen3-30B-A3B-Instruct by default: 30B MoE with ~3B active params.

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
import time
from dataclasses import dataclass

from rapidfuzz.distance import Levenshtein
from rich.console import Console

from flow.config import CleanupCfg

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
        try:
            from mlx_lm import load
        except ImportError as e:
            raise RuntimeError("pip install mlx-lm") from e
        self.model, self.tokenizer = load(cfg.model)

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
            from mlx_lm.models.cache import make_prompt_cache
            from mlx_lm import stream_generate
            import mlx.core as mx
        except ImportError:
            return

        prefix_str = self.tokenizer.apply_chat_template(
            self._prefix_messages(), tokenize=False, add_generation_prompt=False
        )
        prefix_ids = self.tokenizer.encode(prefix_str)
        self._prefix_token_count = len(prefix_ids)

        cache = make_prompt_cache(self.model)
        t0 = time.perf_counter()
        # Run a 1-token generation to fully prefill the cache for the prefix.
        for _ in stream_generate(
            self.model,
            self.tokenizer,
            prompt=mx.array(prefix_ids),
            max_tokens=1,
            prompt_cache=cache,
        ):
            pass
        # The 1 generated token is now in the cache too — account for it.
        self._prefix_token_count += 1
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
        messages = self._build_messages(
            raw_transcript=raw_transcript,
            alt_hypotheses=alt_hypotheses or [],
            app_context=app_context,
            dictionary_boost=dictionary_boost or [],
            few_shots=few_shots or [],
            style_instruction=style_instruction,
        )
        cleaned = self._generate(messages)
        if self._hallucinated(raw_transcript, cleaned):
            return raw_transcript
        return cleaned

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
        from mlx_lm import stream_generate
        import mlx.core as mx

        prompt_str = self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        full_ids = self.tokenizer.encode(prompt_str)

        # Try to reuse the prefix cache: only feed the suffix (new tokens) to
        # the model. The cache already contains KV for the static prefix.
        cache = None
        prompt_ids = full_ids
        if self._prefix_cache_snapshot is not None and len(full_ids) > self._prefix_token_count:
            # Verify the prefix actually matches what we cached. If it doesn't
            # (e.g. tokenizer changed something), fall back to the full prompt.
            prefix_check = self.tokenizer.apply_chat_template(
                self._prefix_messages(), tokenize=False, add_generation_prompt=False
            )
            cached_ids = self.tokenizer.encode(prefix_check)
            if full_ids[: len(cached_ids)] == cached_ids:
                cache = _pycopy.deepcopy(self._prefix_cache_snapshot)
                # Skip prefix tokens — but keep the 1 extra token we generated
                # during prefill (it represents the "next" token after the prefix
                # so the cache state corresponds to position prefix_token_count).
                prompt_ids = full_ids[self._prefix_token_count - 1 :]

        out_pieces: list[str] = []
        for resp in stream_generate(
            self.model,
            self.tokenizer,
            prompt=mx.array(prompt_ids),
            max_tokens=self.cfg.max_tokens,
            prompt_cache=cache,
        ):
            out_pieces.append(resp.text)
        return "".join(out_pieces).strip()

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
