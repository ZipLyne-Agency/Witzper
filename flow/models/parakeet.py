"""Parakeet TDT 0.6B v3 via parakeet-mlx — speed-mode ASR."""

from __future__ import annotations

import numpy as np

from flow.models.asr_base import ASRResult


class ParakeetASR:
    """Thin wrapper around senstella/parakeet-mlx.

    Note: Parakeet does not accept arbitrary text context; it's a pure acoustic
    model. The `context_prompt` arg is accepted but only the boost-terms portion
    is usable, by passing them into the hotword biasing API if available.
    """

    def __init__(self, model_id: str):
        try:
            from parakeet_mlx import from_pretrained
        except ImportError as e:
            raise RuntimeError("pip install parakeet-mlx") from e
        self._model = from_pretrained(model_id)

    def transcribe(
        self,
        audio: np.ndarray,
        sample_rate: int,
        context_prompt: str | None = None,
    ) -> ASRResult:
        if audio.size == 0:
            return ASRResult(text="")
        result = self._model.transcribe(audio)
        # parakeet-mlx returns an object with .text; alternatives not directly exposed.
        text = getattr(result, "text", str(result)).strip()
        return ASRResult(text=text, alternatives=[], language=None)
