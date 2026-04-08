"""Qwen3-ASR via its MLX port — accuracy-mode ASR with context prompt injection.

This wraps the community `qwen3-asr-mlx` package. Because Qwen3-ASR is an
audio-language model, it accepts a text prompt alongside audio — this is where
we inject the focused-app context and dictionary boost terms for
context-conditioned recognition.

If the MLX port package isn't installed yet, the wrapper raises on construction
and the orchestrator will fall back to Parakeet. Install instructions are in
scripts/download_models.sh.
"""

from __future__ import annotations

import numpy as np

from flow.models.asr_base import ASRResult


class Qwen3ASR:
    def __init__(self, model_id: str):
        try:
            # Placeholder import — the community MLX port is still stabilizing.
            # Once the package is published, `from qwen3_asr_mlx import Qwen3ASRModel`.
            from qwen3_asr_mlx import Qwen3ASRModel  # type: ignore
        except ImportError as e:
            raise RuntimeError(
                "Qwen3-ASR MLX port not installed. See scripts/download_models.sh "
                "for the community build instructions, or set asr.mode = 'speed' "
                "in your config to use Parakeet only."
            ) from e
        self._model = Qwen3ASRModel.from_pretrained(model_id)

    def transcribe(
        self,
        audio: np.ndarray,
        sample_rate: int,
        context_prompt: str | None = None,
    ) -> ASRResult:
        if audio.size == 0:
            return ASRResult(text="")
        out = self._model.generate(
            audio=audio,
            sample_rate=sample_rate,
            prompt=context_prompt or "",
            return_alternatives=5,
        )
        return ASRResult(
            text=out.text.strip(),
            alternatives=[a.strip() for a in getattr(out, "alternatives", [])],
            language=getattr(out, "language", None),
        )
