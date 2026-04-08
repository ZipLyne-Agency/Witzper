"""Parakeet TDT 0.6B v3 via parakeet-mlx — speed-mode ASR."""

from __future__ import annotations

import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

from flow.models.asr_base import ASRResult


class ParakeetASR:
    """Thin wrapper around senstella/parakeet-mlx.

    parakeet-mlx's `transcribe` API takes a file path. We write the audio
    buffer to a temp wav file each call. (Cheap — float32 PCM, sub-ms.)
    """

    def __init__(self, model_id: str):
        try:
            from parakeet_mlx import from_pretrained
        except ImportError as e:
            raise RuntimeError("pip install parakeet-mlx") from e
        self._model = from_pretrained(model_id)
        self._tmpdir = Path(tempfile.mkdtemp(prefix="flow-parakeet-"))

    def transcribe(
        self,
        audio: np.ndarray,
        sample_rate: int,
        context_prompt: str | None = None,
    ) -> ASRResult:
        if audio.size == 0:
            return ASRResult(text="")
        wav_path = self._tmpdir / "utterance.wav"
        sf.write(wav_path, audio, sample_rate, subtype="PCM_16")
        result = self._model.transcribe(str(wav_path))
        text = getattr(result, "text", str(result)).strip()
        return ASRResult(text=text, alternatives=[], language=None)
