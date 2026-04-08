"""Hot-path LLM cleanup via MLX-LM.

Uses Qwen3-30B-A3B-Instruct by default: 30B MoE with ~3B active params,
runs at ~100 tok/s on M5 Max at 8-bit. The cleanup task is structured as:

  [SYSTEM] cleanup rules + tone priming + dictionary boost terms
  [FEW-SHOT] N dynamic examples retrieved from the correction store
  [USER] raw transcript (+ optional alt hypotheses from ASR)
  [ASSISTANT] cleaned text

A hallucination guardrail compares the cleaned output to the raw transcript;
if it's too long or too different, we fall back to the raw transcript.
"""

from __future__ import annotations

from dataclasses import dataclass

from rapidfuzz.distance import Levenshtein

from flow.config import CleanupCfg


SYSTEM_PROMPT = """You are a dictation cleanup engine. You receive a raw speech-to-text \
transcript and output a polished version. Rules, in order:

1. Remove disfluencies: um, uh, like (when filler), you know, er, erm, mm, hmm.
2. Remove stutters and immediate word repetitions.
3. Resolve self-corrections: "meeting Tuesday — wait, Wednesday" → "meeting Wednesday".
4. Add correct punctuation and capitalization.
5. Convert spoken forms: "A P I" → "API", "two ninety nine" → "$2.99" in money contexts, \
"three oh two" → "3:02" in time contexts, "hi at example dot com" → "hi@example.com".
6. Preserve the speaker's meaning exactly. Never add content they did not say.
7. Preserve listed vocabulary terms verbatim (exact spelling and casing).
8. Match the requested tone for the target app.
9. Output ONLY the cleaned text — no preamble, no quotes, no explanation."""


@dataclass
class FewShotExample:
    raw: str
    cleaned: str


class CleanupLLM:
    def __init__(self, cfg: CleanupCfg):
        self.cfg = cfg
        try:
            from mlx_lm import load
        except ImportError as e:
            raise RuntimeError("pip install mlx-lm") from e
        self.model, self.tokenizer = load(cfg.model)

    def clean(
        self,
        raw_transcript: str,
        alt_hypotheses: list[str] | None = None,
        app_context=None,
        dictionary_boost: list[str] | None = None,
        few_shots: list[FewShotExample] | None = None,
    ) -> str:
        messages = self._build_messages(
            raw_transcript=raw_transcript,
            alt_hypotheses=alt_hypotheses or [],
            app_context=app_context,
            dictionary_boost=dictionary_boost or [],
            few_shots=few_shots or [],
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
    ) -> list[dict]:
        system = SYSTEM_PROMPT
        if app_context and app_context.rule:
            system += f"\n\nTarget app: {app_context.rule.name}. Tone: {app_context.rule.tone}"
        if dictionary_boost:
            # Cap to avoid exploding context
            terms = ", ".join(dictionary_boost[:100])
            system += f"\n\nPreserve these terms verbatim: {terms}"

        messages: list[dict] = [{"role": "system", "content": system}]
        for ex in few_shots:
            messages.append({"role": "user", "content": ex.raw})
            messages.append({"role": "assistant", "content": ex.cleaned})

        user_content = raw_transcript
        if alt_hypotheses:
            alt = "\n".join(f"- {a}" for a in alt_hypotheses[:4])
            user_content = f"{raw_transcript}\n\nAlternative hypotheses:\n{alt}"
        messages.append({"role": "user", "content": user_content})
        return messages

    def _generate(self, messages: list[dict]) -> str:
        from mlx_lm import generate

        prompt = self.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        out = generate(
            self.model,
            self.tokenizer,
            prompt=prompt,
            max_tokens=self.cfg.max_tokens,
            temp=self.cfg.temperature,
            verbose=False,
        )
        return out.strip()

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
