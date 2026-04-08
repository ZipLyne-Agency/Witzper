"""OpenAI Whisper via mlx-whisper — alternative ASR backend.

Slower than Parakeet but supports 100+ languages. Auto-selected when the
configured model id contains 'whisper'.
"""

from __future__ import annotations

import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

from flow.models.asr_base import ASRResult


class WhisperASR:
    def __init__(self, model_id: str):
        try:
            import mlx_whisper  # noqa: F401
        except ImportError as e:
            raise RuntimeError("pip install mlx-whisper") from e
        self._model_id = model_id
        self._tmpdir = Path(tempfile.mkdtemp(prefix="flow-whisper-"))

    def transcribe(
        self,
        audio: np.ndarray,
        sample_rate: int,
        context_prompt: str | None = None,
    ) -> ASRResult:
        if audio.size == 0:
            return ASRResult(text="")
        import mlx_whisper

        wav_path = self._tmpdir / "utterance.wav"
        sf.write(wav_path, audio, sample_rate, subtype="PCM_16")
        result = mlx_whisper.transcribe(
            str(wav_path),
            path_or_hf_repo=self._model_id,
            initial_prompt=context_prompt or "",
            verbose=False,
        )
        text = result.get("text", "").strip()
        language = result.get("language")
        return ASRResult(text=text, alternatives=[], language=language)
